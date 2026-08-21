import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/streaming_aac_decoder.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/hls_live_playlist.dart';
import 'package:ndvy_player/src/hls_live_session.dart';

const _fixtureRoot = 'test/fixtures/hls/butterfly';
final _playlistUri = Uri.parse('fixture:///phase2c/live.m3u8');

void main() {
  test(
    'Phase 2C refreshes, decodes, bounds PCM, and seals at ENDLIST',
    () async {
      final snapshots = <String>[
        _playlist(count: 2),
        _playlist(count: 2),
        _playlist(count: 4, endList: true),
      ];
      var playlistFetches = 0;
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async =>
            Uint8List.fromList(snapshots[playlistFetches++].codeUnits),
        initialHoldBackSegments: null,
        sleeper: (_) async {},
      );
      final session = HlsLiveRollingSession(
        playlistCoordinator: coordinator,
        fetcher: _readFixture,
        audioFromVideoSegments: true,
        prebufferSegments: 2,
        prefetchWindow: 2,
        maxAttempts: 1,
      );

      final videoDecoder = H264BaselineDecoder();
      StreamingAacPcmDecoder? audioDecoder;
      var decodedPictures = 0;
      var readyUpdates = 0;
      var sealedUpdates = 0;

      try {
        final done = session.start();
        await for (final update in session.updates) {
          final error = update.error;
          if (error != null) throw error;

          for (final accessUnit in update.videoAccessUnits) {
            final frame = videoDecoder.decodeAccessUnitOrThrow(accessUnit.nals);
            expect(frame.width, 854);
            expect(frame.height, 480);
            decodedPictures++;
          }

          if (update.audioAccessUnits.isNotEmpty) {
            final config = update.audioConfig;
            final origin = update.baseVideoPts90k;
            expect(config, isNotNull);
            expect(origin, isNotNull);
            audioDecoder ??= await StreamingAacPcmDecoder.start(
              config: config!,
              originPts90k: origin!,
              maxRetainedPcmDuration: const Duration(seconds: 2),
              maxRetainedPcmBytes: 1024 * 1024,
            );
            await audioDecoder.pushAllChunked(update.audioAccessUnits);
          }

          if (update.becameReady) readyUpdates++;
          if (update.sealed) {
            sealedUpdates++;
            await audioDecoder?.seal();
          }
        }
        await done;

        final audio = audioDecoder;
        expect(audio, isNotNull);
        final source = audio!.source;
        expect(playlistFetches, 3);
        expect(session.progress.playlistRefreshesCompleted, 3);
        expect(session.progress.videoSegmentsLoaded, 4);
        expect(session.progress.videoAccessUnitsEmitted, 226);
        expect(session.progress.audioAccessUnitsEmitted, 353);
        expect(decodedPictures, 226);
        expect(readyUpdates, 1);
        expect(sealedUpdates, 1);
        expect(session.isReady, isTrue);
        expect(session.isSealed, isTrue);

        expect(source.sampleRate, 48000);
        expect(source.channels, 2);
        expect(source.frameCount, 361472);
        expect(source.capacityFrames, 96000);
        expect(source.retainedFrameCount, 96000);
        expect(source.firstAvailableFrame, 265472);
        expect(File(source.filePath).lengthSync(), 96000 * 2 * 2);

        final tail = await source.readFrames(
          source.frameCount - 2048,
          maxFrames: 2048,
        );
        expect(tail.frameCount, 2048);
        expect(tail.samples.any((sample) => sample != 0), isTrue);

        final pcmPath = source.filePath;
        await audio.dispose(disposeSource: true);
        audioDecoder = null;
        expect(File(pcmPath).existsSync(), isFalse);
      } finally {
        await audioDecoder?.dispose(disposeSource: true);
        await session.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

String _playlist({required int count, bool endList = false}) {
  const durations = <double>[2.002, 2.002, 2.002, 1.534867];
  final output = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-TARGETDURATION:3')
    ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
  for (var index = 0; index < count; index++) {
    output
      ..writeln('#EXTINF:${durations[index]},')
      ..writeln('segment_${index.toString().padLeft(3, '0')}.ts');
  }
  if (endList) output.writeln('#EXT-X-ENDLIST');
  return output.toString();
}

Future<Uint8List> _readFixture(Uri uri) =>
    File('$_fixtureRoot/${uri.pathSegments.last}').readAsBytes();
