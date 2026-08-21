import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';
import 'package:ndvy_player/src/audio/audio_decode_pipeline.dart';
import 'package:ndvy_player/src/audio/pcm_source.dart';
import 'package:ndvy_player/src/audio/streaming_aac_decoder.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

void main() {
  List<AacAccessUnit> accessUnits(int count) {
    final bytes = File('assets/baby_aac.mp4').readAsBytesSync();
    final track = Mp4Demux.parseAacTrack(bytes)!;
    return List<AacAccessUnit>.generate(count, (index) {
      return AacAccessUnit(
        payload: Mp4Demux.readAudioSample(bytes, track, index),
        config: track.config,
        pts90k: _scaleTimestamp(track.pts[index], track.timescale, 90000),
        sampleCount: 1024,
      );
    }, growable: false);
  }

  test(
    'persistent worker commits split pushes byte-exactly with batch decode',
    () async {
      final units = accessUnits(12);
      final origin = units.first.pts90k!;
      final expected = decodeTransportAacToFilePcm(units, originPts90k: origin);
      addTearDown(expected.dispose);
      final decoder = await StreamingAacPcmDecoder.start(
        config: units.first.config,
        originPts90k: origin,
      );
      final source = decoder.source;
      final sourcePath = source.filePath;
      addTearDown(() => decoder.dispose(disposeSource: true));

      final firstRead = source.readFrames(0, maxFrames: 256);
      final prebuffer = source.waitForFrameCount(1024);
      await decoder.push(units.first);
      await prebuffer;
      expect((await firstRead).frameCount, 256);

      final firstBatch = decoder.pushAll(units.sublist(1, 5));
      final secondBatch = decoder.pushAll(units.sublist(5));
      await Future.wait(<Future<void>>[firstBatch, secondBatch]);
      await decoder.seal();
      await decoder.seal();

      expect(decoder.decodedAccessUnitCount, units.length);
      expect(source.state, GrowingPcmAudioState.sealed);
      expect(source.frameCount, expected.frameCount);
      final actualPcm = await source.readFrames(
        0,
        maxFrames: source.frameCount,
      );
      final expectedPcm = await expected.readFrames(
        0,
        maxFrames: expected.frameCount,
      );
      expect(actualPcm.pcm16le, expectedPcm.pcm16le);

      await decoder.dispose();
      await decoder.dispose();
      expect(File(sourcePath).existsSync(), isTrue);
      await source.dispose();
      expect(File(sourcePath).existsSync(), isFalse);
    },
  );

  test('restart source retains its absolute media-time offset', () async {
    final unit = accessUnits(1).single;
    final decoder = await StreamingAacPcmDecoder.start(
      config: unit.config,
      originPts90k: unit.pts90k!,
      basePtsUs: 62000000,
    );
    addTearDown(() => decoder.dispose(disposeSource: true));

    await decoder.push(unit);
    expect(decoder.source.basePtsUs, 62000000);
    expect(decoder.source.mediaTimeUsForFrame(0), 62000000);
    expect(decoder.source.frameCount, greaterThan(0));
  });

  test(
    'persistent decoder can rotate bounded PCM without resetting AAC',
    () async {
      final units = accessUnits(6);
      final origin = units.first.pts90k!;
      final expected = decodeTransportAacToFilePcm(units, originPts90k: origin);
      addTearDown(expected.dispose);
      final bytesPerFrame = units.first.config.channelCount! * 2;
      final decoder = await StreamingAacPcmDecoder.start(
        config: units.first.config,
        originPts90k: origin,
        maxRetainedPcmBytes: 2 * 1024 * bytesPerFrame,
      );
      addTearDown(() => decoder.dispose(disposeSource: true));

      await decoder.pushAll(units.sublist(0, 3));
      await decoder.pushAll(units.sublist(3));
      await decoder.seal();

      final source = decoder.source;
      expect(decoder.decodedAccessUnitCount, units.length);
      expect(source.capacityFrames, 2048);
      expect(source.frameCount, expected.frameCount);
      expect(source.firstAvailableFrame, expected.frameCount - 2048);
      expect(File(source.filePath).lengthSync(), 2048 * bytesPerFrame);
      final actual = await source.readFrames(
        source.firstAvailableFrame,
        maxFrames: source.retainedFrameCount,
      );
      final reference = await expected.readFrames(
        source.firstAvailableFrame,
        maxFrames: source.retainedFrameCount,
      );
      expect(actual.startFrame, reference.startFrame);
      expect(actual.pcm16le, reference.pcm16le);
    },
  );

  test(
    'decoder disposal fails tail reads without assuming source ownership',
    () async {
      final units = accessUnits(1);
      final decoder = await StreamingAacPcmDecoder.start(
        config: units.first.config,
        originPts90k: units.first.pts90k!,
      );
      final source = decoder.source;
      final path = source.filePath;
      final readExpectation = expectLater(
        source.readFrames(0, maxFrames: 1),
        throwsStateError,
      );

      await decoder.dispose();
      await readExpectation;
      expect(source.state, GrowingPcmAudioState.failed);
      expect(File(path).existsSync(), isTrue);

      await decoder.dispose(disposeSource: true);
      expect(File(path).existsSync(), isFalse);
    },
  );

  test('worker decode error becomes the source terminal error', () async {
    final units = accessUnits(1);
    final broken = AacAccessUnit(
      payload: units.first.payload.sublist(0, 1),
      config: units.first.config,
      pts90k: units.first.pts90k,
      sampleCount: units.first.sampleCount,
    );
    final decoder = await StreamingAacPcmDecoder.start(
      config: units.first.config,
      originPts90k: units.first.pts90k!,
    );
    addTearDown(() => decoder.dispose(disposeSource: true));
    final tailExpectation = expectLater(
      decoder.source.readFrames(0, maxFrames: 1),
      throwsA(isA<StreamingAacDecoderException>()),
    );

    await expectLater(
      decoder.push(broken),
      throwsA(isA<StreamingAacDecoderException>()),
    );
    await tailExpectation;
    expect(decoder.source.state, GrowingPcmAudioState.failed);
    expect(decoder.source.terminalError, isA<StreamingAacDecoderException>());
    await expectLater(decoder.push(units.first), throwsStateError);
    await decoder.fail(StateError('duplicate terminal failure'));
  });

  test(
    'one push is bounded by access-unit and compressed-byte limits',
    () async {
      final units = accessUnits(2);
      final decoder = await StreamingAacPcmDecoder.start(
        config: units.first.config,
        originPts90k: units.first.pts90k!,
        maxAccessUnitsPerPush: 1,
        maxCompressedBytesPerPush: units.fold<int>(
          0,
          (largest, unit) => unit.payload.lengthInBytes > largest
              ? unit.payload.lengthInBytes
              : largest,
        ),
      );
      addTearDown(() => decoder.dispose(disposeSource: true));

      await expectLater(decoder.pushAll(units), throwsRangeError);
      expect(decoder.source.frameCount, 0);
      expect(decoder.source.state, GrowingPcmAudioState.open);
      await decoder.pushAllChunked(units);
      expect(decoder.decodedAccessUnitCount, 2);
      await decoder.seal();
    },
  );
}

int _scaleTimestamp(int value, int sourceTimescale, int targetTimescale) {
  final product = value * targetTimescale;
  if (product >= 0) {
    return (product + sourceTimescale ~/ 2) ~/ sourceTimescale;
  }
  return -((-product + sourceTimescale ~/ 2) ~/ sourceTimescale);
}
