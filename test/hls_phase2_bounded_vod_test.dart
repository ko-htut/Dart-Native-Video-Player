import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/access_unit_pts.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';
import 'package:ndvy_player/src/audio/aac/ts_aac_demux.dart';
import 'package:ndvy_player/src/audio/audio_decode_pipeline.dart';
import 'package:ndvy_player/src/audio/pcm_source.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/hls.dart';
import 'package:ndvy_player/src/hls_segment_loader.dart';
import 'package:ndvy_player/src/ts_h264_demux.dart';
import 'package:ndvy_player/src/ts_packets.dart';
import 'package:ndvy_player/src/ts_psi.dart';

const _fixtureRoot = 'test/fixtures/hls/butterfly';
final _playlistUri = Uri.parse('fixture:///media.m3u8');

void main() {
  test(
    'bounded Phase 2 VOD delivery preserves complete video and file PCM',
    () async {
      final media = await fetchMediaPlaylist(
        _playlistUri,
        byteFetcher: _readFixture,
      );
      expect(media.isEndList, isTrue);
      expect(media.segments, hasLength(4));

      var inFlight = 0;
      var maxInFlight = 0;
      var completedFetches = 0;
      int? completedAtFirstDelivery;
      final started = <Uri>[];
      final deliveredSequences = <int>[];

      final loader = HlsSegmentLoader(
        playlist: media,
        prefetchWindow: 2,
        fetcher: (uri) async {
          started.add(uri);
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          try {
            // Keep the fetch asynchronous so delivery and prefetch overlap in
            // the same way as the HTTP path, without using the network.
            await Future<void>.delayed(const Duration(milliseconds: 5));
            final bytes = await _readFixture(uri);
            completedFetches++;
            return bytes;
          } finally {
            inFlight--;
          }
        },
      );
      addTearDown(loader.dispose);

      final videoDemuxer = TsH264Demuxer();
      final videoUnits = <TimestampedAccessUnit>[];
      final audioUnits = <AacAccessUnit>[];
      TsAacDemuxer? audioDemuxer;
      int? previousDiscontinuitySequence;

      await for (final loaded in loader.stream) {
        completedAtFirstDelivery ??= completedFetches;
        deliveredSequences.add(loaded.sequence);

        final discontinuity =
            previousDiscontinuitySequence != null &&
            previousDiscontinuitySequence != loaded.discontinuitySequence;
        previousDiscontinuitySequence = loaded.discontinuitySequence;
        videoUnits.addAll(
          videoDemuxer.pushSegment(loaded.bytes, discontinuity: discontinuity),
        );

        final packets = parseTsPackets(loaded.bytes).toList(growable: false);
        final pat = TsPat.find(packets);
        expect(pat, isNotNull, reason: 'PAT missing in ${loaded.uri}');
        final pmt = TsPmt.find(packets, pat!.programs.values.single);
        expect(pmt, isNotNull, reason: 'PMT missing in ${loaded.uri}');
        final audioStream = findAdtsAacStream(pmt!);
        expect(audioStream, isNotNull, reason: 'AAC missing in ${loaded.uri}');
        final activeAudioDemuxer = audioDemuxer ??= TsAacDemuxer(
          pid: audioStream!.pid,
        );
        expect(audioStream!.pid, activeAudioDemuxer.pid);
        audioUnits.addAll(activeAudioDemuxer.pushPackets(packets));
      }
      await loader.done;

      videoUnits.addAll(videoDemuxer.finish());
      final activeAudioDemuxer = audioDemuxer;
      expect(activeAudioDemuxer, isNotNull);
      audioUnits.addAll(activeAudioDemuxer!.finish());

      expect(started, hasLength(4));
      expect(completedFetches, 4);
      expect(
        completedAtFirstDelivery,
        lessThan(4),
        reason: 'the first segment must be delivered before the VOD is full',
      );
      expect(maxInFlight, lessThanOrEqualTo(2));
      expect(deliveredSequences, orderedEquals(<int>[0, 1, 2, 3]));

      expect(videoUnits, hasLength(226));
      expect(videoUnits.where((unit) => unit.hasIdr), hasLength(8));
      expect(videoUnits.first.ptsMs, 0);
      expect(videoUnits.last.ptsMs, 7508);
      final ptsFingerprint = sha256.convert(
        utf8.encode(
          videoUnits.map((unit) => '${unit.pts90k}:${unit.ptsMs}').join(','),
        ),
      );
      expect(
        ptsFingerprint.toString(),
        'f81b440967562d36b2a699431a00c46a4e17589548e2a7e85de374c451db892c',
      );

      final decoder = H264BaselineDecoder();
      for (var index = 0; index < videoUnits.length; index++) {
        final frame = decoder.decodeAccessUnit(videoUnits[index].nals);
        expect(
          frame,
          isNotNull,
          reason: 'HLS picture $index failed: ${decoder.lastError}',
        );
        expect(frame!.width, 854, reason: 'picture $index width');
        expect(frame.height, 480, reason: 'picture $index height');
      }

      final videoDiagnostics = videoDemuxer.diagnostics;
      expect(videoDiagnostics.continuityErrorCount, 0);
      expect(videoDiagnostics.scrambledPacketCount, 0);
      expect(activeAudioDemuxer.continuityErrorCount, 0);
      expect(activeAudioDemuxer.scrambledPacketCount, 0);
      expect(audioUnits, hasLength(353));

      final originPts90k = videoDemuxer.basePts90k;
      expect(originPts90k, isNotNull);
      final reference = await decodeTransportAacToPcmInBackground(
        audioUnits,
        originPts90k: originPts90k!,
      );
      final FilePcmAudioSource source =
          await decodeTransportAacToFilePcmInBackground(
            audioUnits,
            originPts90k: originPts90k,
          );
      addTearDown(source.dispose);

      final pcmFile = File(source.filePath);
      final ownedDirectory = source.ownedDirectoryPath;
      expect(source.ownsFile, isTrue);
      expect(ownedDirectory, isNotNull);
      expect(pcmFile.existsSync(), isTrue);
      expect(source.sampleRate, 48000);
      expect(source.channels, 2);
      expect(source.basePtsUs, 0);
      expect(source.frameCount, 361472);
      expect(source.durationUs, 7530666);
      expect(pcmFile.lengthSync(), source.frameCount * source.channels * 2);

      expect(source.sampleRate, reference.sampleRate);
      expect(source.channels, reference.channels);
      expect(source.basePtsUs, reference.basePtsUs);
      expect(source.frameCount, reference.frameCount);
      var sawNonSilence = false;
      const framesPerRead = 4093;
      for (
        var firstFrame = 0;
        firstFrame < source.frameCount;
        firstFrame += framesPerRead
      ) {
        final chunk = await source.readFrames(
          firstFrame,
          maxFrames: framesPerRead,
        );
        final firstSample = firstFrame * source.channels;
        final lastSample = (firstFrame + chunk.frameCount) * source.channels;
        expect(
          chunk.samples,
          reference.samples.sublist(firstSample, lastSample),
          reason: 'file PCM differs at frame $firstFrame',
        );
        sawNonSilence |= chunk.samples.any((sample) => sample != 0);
      }
      expect(sawNonSilence, isTrue);

      await source.dispose();
      expect(source.isDisposed, isTrue);
      expect(pcmFile.existsSync(), isFalse);
      expect(Directory(ownedDirectory!).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<Uint8List> _readFixture(Uri uri) {
  final name = uri.pathSegments.last;
  return File('$_fixtureRoot/$name').readAsBytes();
}
