import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/hls_live_playlist.dart';
import 'package:ndvy_player/src/hls_live_session.dart';

const _fixtureRoot = 'test/fixtures/hls/butterfly';
final _playlistUri = Uri.parse('fixture:///live.m3u8');

void main() {
  test(
    'listener-gated rolling muxed session consumes refresh deltas and seals',
    () async {
      final snapshots = <String>[
        _butterflyPlaylist(count: 2),
        _butterflyPlaylist(count: 4, endList: true),
      ];
      var playlistFetchCount = 0;
      final fetchedSegments = <Uri>[];
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async =>
            Uint8List.fromList(snapshots[playlistFetchCount++].codeUnits),
        epoch: 77,
        initialHoldBackSegments: null,
        sleeper: (_) async {},
      );
      final session = HlsLiveRollingSession(
        playlistCoordinator: coordinator,
        fetcher: (uri) async {
          fetchedSegments.add(uri);
          return _readFixture(uri);
        },
        audioFromVideoSegments: true,
        prebufferSegments: 2,
        prefetchWindow: 2,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);

      final done = session.start();
      await _flushAsyncWork();
      expect(playlistFetchCount, 0);
      expect(fetchedSegments, isEmpty);

      final updatesFuture = session.updates.toList();
      await done;
      final updates = await updatesFuture;
      final segmentUpdates = updates
          .where((update) => update.mediaSequence != null)
          .toList(growable: false);

      expect(playlistFetchCount, 2);
      expect(fetchedSegments, hasLength(4));
      expect(
        segmentUpdates.map((update) => update.mediaSequence),
        orderedEquals(<int>[0, 1, 2, 3]),
      );
      expect(updates.where((update) => update.playlistRefreshed), hasLength(2));
      expect(
        updates.expand((update) => update.videoAccessUnits),
        hasLength(226),
      );
      expect(
        updates.expand((update) => update.audioAccessUnits),
        hasLength(353),
      );

      final ready = updates.singleWhere((update) => update.becameReady);
      expect(ready.epoch, 77);
      expect(ready.mediaSequence, 1);
      expect(ready.progress.videoSegmentsLoaded, 2);
      expect(ready.progress.audioSegmentsLoaded, 2);
      expect(ready.progress.audioState, HlsLiveAudioState.active);
      expect(ready.audioConfig?.isAacLc, isTrue);
      expect(ready.audioVideoPtsDelta90k, isNotNull);
      expect(ready.audioVideoPtsDelta90k!.abs(), lessThanOrEqualTo(45000));

      expect(updates.last.sealed, isTrue);
      expect(updates.last.error, isNull);
      expect(updates.last.progress.endListSeen, isTrue);
      expect(updates.last.progress.playlistRefreshesCompleted, 2);
      expect(updates.last.progress.segmentsDiscovered, 4);
      expect(updates.last.progress.videoSegmentsLoaded, 4);
      expect(updates.last.progress.pendingSegmentCount, 0);
      expect(session.audioState, HlsLiveAudioState.active);
      expect(session.isReady, isTrue);
      expect(session.isSealed, isTrue);
      expect(session.retainedSegmentByteCount, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'paused refresh update prevents segment downloads until resume',
    () async {
      var segmentFetchCount = 0;
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => Uint8List.fromList(
          _butterflyPlaylist(count: 2, endList: true).codeUnits,
        ),
        initialHoldBackSegments: null,
        sleeper: (_) async {},
      );
      final session = HlsLiveRollingSession(
        playlistCoordinator: coordinator,
        fetcher: (uri) async {
          segmentFetchCount++;
          return _readFixture(uri);
        },
        prefetchWindow: 1,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);

      final refreshSeen = Completer<void>();
      final streamDone = Completer<void>();
      late final StreamSubscription<HlsLiveSessionUpdate> subscription;
      subscription = session.updates.listen((update) {
        if (update.playlistRefreshed && !refreshSeen.isCompleted) {
          subscription.pause();
          refreshSeen.complete();
        }
      }, onDone: streamDone.complete);
      addTearDown(subscription.cancel);
      unawaited(session.start());

      await refreshSeen.future.timeout(const Duration(seconds: 2));
      await _flushAsyncWork();
      expect(segmentFetchCount, 0);

      subscription.resume();
      await session.done;
      await streamDone.future;
      expect(segmentFetchCount, 2);
      expect(session.isSealed, isTrue);
    },
  );

  test('cancel promptly unblocks an in-flight segment fetch', () async {
    final fetchStarted = Completer<void>();
    final fetchGate = Completer<Uint8List>();
    var segmentFetchCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async =>
          Uint8List.fromList(_butterflyPlaylist(count: 1).codeUnits),
      initialHoldBackSegments: null,
      sleeper: (_) => Completer<void>().future,
    );
    final session = HlsLiveRollingSession(
      playlistCoordinator: coordinator,
      fetcher: (_) {
        segmentFetchCount++;
        if (!fetchStarted.isCompleted) fetchStarted.complete();
        return fetchGate.future;
      },
      maxAttempts: 1,
    );
    addTearDown(session.dispose);
    final updatesFuture = session.updates.toList();
    unawaited(session.start());

    await fetchStarted.future.timeout(const Duration(seconds: 2));
    await session.cancel().timeout(const Duration(seconds: 1));
    final updates = await updatesFuture;

    expect(segmentFetchCount, 1);
    expect(updates.first.playlistRefreshed, isTrue);
    expect(updates.last.cancelled, isTrue);
    expect(updates.last.sealed, isFalse);
    expect(updates.last.error, isNull);
    expect(session.isCancelled, isTrue);
    expect(coordinator.isCancelled, isTrue);

    fetchGate.complete(Uint8List(188));
    await _flushAsyncWork();
    expect(segmentFetchCount, 1);
  });

  test(
    'missing muxed ADTS downgrades before readiness and stays video-only',
    () async {
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => Uint8List.fromList(
          _butterflyPlaylist(count: 2, endList: true).codeUnits,
        ),
        initialHoldBackSegments: null,
        sleeper: (_) async {},
      );
      final session = HlsLiveRollingSession(
        playlistCoordinator: coordinator,
        fetcher: (uri) async => _removeAdtsDeclaration(await _readFixture(uri)),
        audioFromVideoSegments: true,
        prebufferSegments: 2,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);
      final updatesFuture = session.updates.toList();
      unawaited(session.start());
      await session.done;
      final updates = await updatesFuture;

      expect(session.isReady, isTrue);
      expect(session.isSealed, isTrue);
      expect(session.audioState, HlsLiveAudioState.downgradedVideoOnly);
      expect(session.audioDowngradeReason, isA<HlsLiveSessionFailure>());
      expect(updates.expand((update) => update.videoAccessUnits), isNotEmpty);
      expect(updates.expand((update) => update.audioAccessUnits), isEmpty);
      expect(updates.last.error, isNull);
    },
  );

  test(
    'audio failure after readiness is terminal and never switches clocks',
    () async {
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => Uint8List.fromList(
          _butterflyPlaylist(count: 4, endList: true).codeUnits,
        ),
        initialHoldBackSegments: null,
        sleeper: (_) async {},
      );
      final session = HlsLiveRollingSession(
        playlistCoordinator: coordinator,
        fetcher: (uri) async {
          final bytes = await _readFixture(uri);
          return uri.pathSegments.last == 'segment_002.ts'
              ? _changeDeclaredAdtsPid(bytes)
              : bytes;
        },
        audioFromVideoSegments: true,
        prebufferSegments: 2,
        prefetchWindow: 1,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);
      final updatesFuture = session.updates.toList();
      unawaited(session.start());
      await session.done;
      final updates = await updatesFuture;

      expect(updates.where((update) => update.becameReady), hasLength(1));
      expect(session.audioState, HlsLiveAudioState.active);
      expect(session.isReady, isTrue);
      expect(session.isSealed, isFalse);
      expect(session.error, isA<HlsLiveSessionFailure>());
      final failure = session.error! as HlsLiveSessionFailure;
      expect(failure.stage, 'audio demux');
      expect(failure.mediaSequence, 2);
      expect(failure.cause, isA<FormatException>());
      expect(updates.last.error, same(session.error));
      expect(updates.last.cancelled, isFalse);
    },
  );

  test(
    'shared discontinuity epoch rebases repeated video and AAC PTS forward',
    () async {
      final playlist = '''
#EXTM3U
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:10
#EXTINF:2.002,
segment_000.ts
#EXTINF:2.002,
segment_001.ts
#EXT-X-DISCONTINUITY
#EXTINF:2.002,
epoch_1_segment_000.ts
#EXTINF:2.002,
epoch_1_segment_001.ts
#EXT-X-ENDLIST
''';
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => Uint8List.fromList(playlist.codeUnits),
        initialHoldBackSegments: null,
        sleeper: (_) async {},
      );
      final session = HlsLiveRollingSession(
        playlistCoordinator: coordinator,
        fetcher: (uri) {
          final name = uri.pathSegments.last.replaceFirst('epoch_1_', '');
          return File('$_fixtureRoot/$name').readAsBytes();
        },
        audioFromVideoSegments: true,
        prebufferSegments: 2,
        prefetchWindow: 1,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);
      final updatesFuture = session.updates.toList();
      unawaited(session.start());
      await session.done;
      final updates = await updatesFuture;

      expect(session.error, isNull);
      expect(session.isSealed, isTrue);
      expect(session.progress.currentDiscontinuitySequence, 1);
      expect(session.progress.discontinuitiesProcessed, 1);

      final beforeVideo = <int>[];
      final afterVideo = <int>[];
      final beforeAudio = <int>[];
      final afterAudio = <int>[];
      var afterBoundary = false;
      for (final update in updates) {
        final sequence = update.mediaSequence;
        if (sequence != null && sequence >= 12) afterBoundary = true;
        final videoTarget = afterBoundary ? afterVideo : beforeVideo;
        final audioTarget = afterBoundary ? afterAudio : beforeAudio;
        videoTarget.addAll(
          update.videoAccessUnits.map((unit) => unit.pts90k).whereType<int>(),
        );
        audioTarget.addAll(
          update.audioAccessUnits.map((unit) => unit.pts90k).whereType<int>(),
        );
      }

      expect(beforeVideo, isNotEmpty);
      expect(afterVideo, isNotEmpty);
      expect(beforeAudio, isNotEmpty);
      expect(afterAudio, isNotEmpty);
      expect(afterVideo.first, greaterThan(beforeVideo.last));
      expect(afterAudio.first, greaterThan(beforeAudio.last));
      expect(<int>[...beforeVideo, ...afterVideo], _isMonotonic);
      expect(<int>[...beforeAudio, ...afterAudio], _isMonotonic);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('playlist refresh failure is contextual and terminal', () async {
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async => throw const FormatException('bad live manifest'),
      sleeper: (_) async {},
    );
    final session = HlsLiveRollingSession(
      playlistCoordinator: coordinator,
      fetcher: _readFixture,
    );
    addTearDown(session.dispose);
    final updatesFuture = session.updates.toList();
    unawaited(session.start());
    await session.done;
    final updates = await updatesFuture;

    expect(updates, hasLength(1));
    expect(updates.single.error, isA<HlsLiveSessionFailure>());
    final failure = updates.single.error! as HlsLiveSessionFailure;
    expect(failure.stage, 'playlist refresh');
    expect(failure.cause, isA<HlsLivePlaylistFailure>());
    expect(session.isSealed, isFalse);
    expect(session.isCancelled, isFalse);
  });
}

Matcher get _isMonotonic => predicate<List<int>>((values) {
  for (var index = 1; index < values.length; index++) {
    if (values[index] < values[index - 1]) return false;
  }
  return true;
}, 'contains monotonically nondecreasing timestamps');

String _butterflyPlaylist({required int count, bool endList = false}) {
  const durations = <double>[2.002, 2.002, 2.002, 1.534867];
  final buffer = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-TARGETDURATION:3')
    ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
  for (var index = 0; index < count; index++) {
    buffer
      ..writeln('#EXTINF:${durations[index]},')
      ..writeln('segment_${index.toString().padLeft(3, '0')}.ts');
  }
  if (endList) buffer.writeln('#EXT-X-ENDLIST');
  return buffer.toString();
}

Future<Uint8List> _readFixture(Uri uri) {
  final name = uri.pathSegments.last;
  return File('$_fixtureRoot/$name').readAsBytes();
}

/// Re-labels ADTS PMT entries as private data while preserving H.264 bytes.
Uint8List _removeAdtsDeclaration(Uint8List source) =>
    _editAdtsPmt(source, (bytes, entry) => bytes[entry] = 0x06);

/// Changes only the PMT-declared AAC PID, leaving AAC transport packets intact.
Uint8List _changeDeclaredAdtsPid(Uint8List source) =>
    _editAdtsPmt(source, (bytes, entry) => bytes[entry + 2] ^= 0x01);

Uint8List _editAdtsPmt(
  Uint8List source,
  void Function(Uint8List bytes, int entry) edit,
) {
  const packetSize = 188;
  final bytes = Uint8List.fromList(source);
  var changedEntries = 0;

  for (
    var packetStart = 0;
    packetStart + packetSize <= bytes.length;
    packetStart += packetSize
  ) {
    if (bytes[packetStart] != 0x47) continue;
    final payloadUnitStart = (bytes[packetStart + 1] & 0x40) != 0;
    if (!payloadUnitStart) continue;

    final adaptationControl = (bytes[packetStart + 3] >> 4) & 0x03;
    if (adaptationControl == 0 || adaptationControl == 2) continue;
    var cursor = packetStart + 4;
    if (adaptationControl == 3) {
      if (cursor >= packetStart + packetSize) continue;
      cursor += 1 + bytes[cursor];
    }
    if (cursor >= packetStart + packetSize) continue;
    cursor += 1 + bytes[cursor];
    if (cursor + 12 > packetStart + packetSize || bytes[cursor] != 0x02) {
      continue;
    }

    final sectionLength = ((bytes[cursor + 1] & 0x0f) << 8) | bytes[cursor + 2];
    final sectionEnd = cursor + 3 + sectionLength - 4;
    if (sectionEnd > packetStart + packetSize) continue;
    final programInfoLength =
        ((bytes[cursor + 10] & 0x0f) << 8) | bytes[cursor + 11];
    var entry = cursor + 12 + programInfoLength;
    while (entry + 5 <= sectionEnd) {
      final esInfoLength = ((bytes[entry + 3] & 0x0f) << 8) | bytes[entry + 4];
      if (bytes[entry] == 0x0f) {
        edit(bytes, entry);
        changedEntries++;
      }
      entry += 5 + esInfoLength;
    }
  }

  if (changedEntries == 0) {
    throw StateError('Butterfly TS fixture contained no ADTS PMT entry');
  }
  return bytes;
}

Future<void> _flushAsyncWork() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}
