import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/access_unit_pts.dart';
import 'package:ndvy_player/src/audio/audio_playback_controller.dart';
import 'package:ndvy_player/src/audio/fake_pcm_sink.dart';
import 'package:ndvy_player/src/audio/pcm_source.dart';
import 'package:ndvy_player/src/audio/streaming_aac_decoder.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/hls.dart';
import 'package:ndvy_player/src/hls_vod_session.dart';
import 'package:ndvy_player/src/player_clock.dart';
import 'package:ndvy_player/src/yuv.dart';

const _fixtureRoot = 'test/fixtures/hls/butterfly';
final _playlistUri = Uri.parse('fixture:///media.m3u8');

void main() {
  test(
    'rolling playback starts early, survives starvation, resumes, and seals',
    () async {
      final media = await fetchMediaPlaylist(
        _playlistUri,
        byteFetcher: _readFixture,
      );
      expect(media.segments, hasLength(4));

      final gates = <Uri, Completer<Uint8List>>{};
      final started = <Uri>[];
      var completedFetches = 0;
      Future<Uint8List> gatedFetch(Uri uri) {
        started.add(uri);
        final gate = Completer<Uint8List>();
        gates[uri] = gate;
        return gate.future.then((bytes) {
          completedFetches++;
          return bytes;
        });
      }

      final session = HlsVodRollingSession(
        videoSegments: media.segments,
        audioFromVideoSegments: true,
        fetcher: gatedFetch,
        prebufferSegments: 2,
        prefetchWindow: 1,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);

      final h264 = H264BaselineDecoder();
      final decodeErrors = <Object>[];
      final drained = Completer<void>();
      Completer<void>? capacityWaiter;
      var maximumResidentItems = 0;
      final pump = SequentialDecodePump<TimestampedAccessUnit, Yuv420Frame>(
        timestampOf: (unit) => unit.ptsMs,
        decode: (unit) => h264.decodeAccessUnitOrThrow(unit.nals),
        onLatestDecoded: (_, _) {},
        onDecodeError: (_, error, _) => decodeErrors.add(error),
        onQueueDrained: () {
          if (!drained.isCompleted) drained.complete();
        },
        onQueueCompacted: (_, _) {},
        onAppendCapacityAvailable: (_) {
          final waiter = capacityWaiter;
          capacityWaiter = null;
          if (waiter != null && !waiter.isCompleted) waiter.complete();
        },
        maxResidentItems: 160,
        retainedConsumedItems: 24,
        isDependencyBoundary: (unit) => unit.hasIdr,
      );
      addTearDown(pump.dispose);
      pump.replaceQueue(const <TimestampedAccessUnit>[], isFinal: false);

      Future<void> appendVideo(List<TimestampedAccessUnit> units) async {
        var offset = 0;
        while (offset < units.length) {
          final available = pump.remainingItemCapacity!;
          if (available == 0) {
            final waiter = Completer<void>();
            capacityWaiter = waiter;
            if (pump.remainingItemCapacity! > 0) {
              capacityWaiter = null;
              continue;
            }
            await waiter.future;
            continue;
          }
          final count = math.min(available, units.length - offset);
          pump.appendItems(units.sublist(offset, offset + count));
          offset += count;
          maximumResidentItems = math.max(
            maximumResidentItems,
            pump.residentLength,
          );
        }
      }

      final sink = FakePcmAudioSink(maxBufferedFrames: 4096);
      final audio = AudioPlaybackController(
        sink,
        framesPerChunk: 1024,
        positionPollInterval: const Duration(days: 1),
      );
      addTearDown(audio.dispose);
      final audioComplete = Completer<void>();
      final audioEvents = audio.events.listen((event) {
        if (event.type == AudioPlaybackEventType.complete &&
            !audioComplete.isCompleted) {
          audioComplete.complete();
        }
      });
      addTearDown(audioEvents.cancel);

      StreamingAacPcmDecoder? streamingAudio;
      final ready = Completer<void>();
      final consumer = () async {
        await for (final update in session.updates) {
          await appendVideo(update.videoAccessUnits);

          if (update.audioAccessUnits.isNotEmpty) {
            final config = update.audioConfig;
            final originPts90k = update.baseVideoPts90k;
            if (config == null || originPts90k == null) {
              throw StateError('AAC arrived before rolling timing metadata');
            }
            streamingAudio ??= await StreamingAacPcmDecoder.start(
              config: config,
              originPts90k: originPts90k,
            );
            await streamingAudio!.pushAll(update.audioAccessUnits);
          }

          if (update.becameReady) {
            expect(streamingAudio, isNotNull);
            await audio.load(streamingAudio!.source);
            await audio.play();
            pump.requestThrough(100000);
            if (!ready.isCompleted) ready.complete();
          }

          if (update.error != null) throw update.error!;
          if (update.sealed) {
            await streamingAudio?.seal();
            pump.closeQueue();
          }
        }
      }();
      unawaited(session.start());

      var releasedSegments = 0;
      Future<void> releaseNextSegment() async {
        await _waitUntil(() => started.length > releasedSegments);
        final uri = started[releasedSegments++];
        gates[uri]!.complete(await _readFixture(uri));
      }

      await releaseNextSegment();
      await releaseNextSegment();
      await ready.future.timeout(const Duration(seconds: 20));

      expect(session.isReady, isTrue);
      expect(session.isSealed, isFalse);
      expect(completedFetches, 2);
      expect(streamingAudio!.source.isSealed, isFalse);
      expect(pump.isQueueFinal, isFalse);

      // Drain the two-segment prebuffer while the third request stays blocked.
      await _consumeUntilTemporaryAudioTail(
        audio,
        sink,
        streamingAudio!.source,
      );
      pump.requestThrough(100000);
      await pump.waitUntilIdle();
      expect(pump.isStarved, isTrue);
      expect(audio.isPlaying, isTrue);
      expect(audioComplete.isCompleted, isFalse);

      // Network recovery must grow the same source/queue generation and resume.
      final audioGenerationAtStall = audio.generation;
      await releaseNextSegment();
      await releaseNextSegment();

      final consumeToEnd = () async {
        while (!audioComplete.isCompleted) {
          sink.consumeFrames(4096);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }();

      await session.done.timeout(const Duration(seconds: 30));
      await consumer.timeout(const Duration(seconds: 30));
      await pump.waitUntilIdle();
      await drained.future.timeout(const Duration(seconds: 30));
      await consumeToEnd.timeout(const Duration(seconds: 30));

      expect(session.isSealed, isTrue);
      expect(streamingAudio!.source.isSealed, isTrue);
      expect(streamingAudio!.decodedAccessUnitCount, 353);
      expect(streamingAudio!.source.frameCount, 361472);
      expect(audio.generation, audioGenerationAtStall);
      expect(pump.isEnded, isTrue);
      expect(decodeErrors, isEmpty);
      expect(session.progress.videoAccessUnitsEmitted, 226);
      expect(session.progress.audioAccessUnitsEmitted, 353);
      expect(maximumResidentItems, lessThanOrEqualTo(160));
      expect(pump.firstRetainedIndex, greaterThan(0));

      // Controller owns the growing file after load and removes it on dispose.
      final pcmPath = streamingAudio!.source.filePath;
      expect(File(pcmPath).existsSync(), isTrue);
      await streamingAudio!.dispose();
      await audio.dispose();
      expect(File(pcmPath).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _consumeUntilTemporaryAudioTail(
  AudioPlaybackController controller,
  FakePcmAudioSink sink,
  GrowingFilePcmAudioSource source,
) async {
  await _waitUntil(() async {
    sink.consumeFrames(4096);
    await Future<void>.delayed(Duration.zero);
    return controller.currentMediaTimeUs >= source.endPtsUs &&
        sink.bufferedFrames == 0;
  });
}

Future<Uint8List> _readFixture(Uri uri) {
  final name = uri.pathSegments.last;
  return File('$_fixtureRoot/$name').readAsBytes();
}

Future<void> _waitUntil(FutureOr<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
