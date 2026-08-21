import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/hls.dart';
import 'package:ndvy_player/src/hls_vod_session.dart';

const _fixtureRoot = 'test/fixtures/hls/butterfly';
final _fixturePlaylistUri = Uri.parse('fixture:///media.m3u8');

void main() {
  test('start waits for the update listener before fetching', () async {
    final fixture = await _fixtureSegments();
    final fetched = <Uri>[];
    final session = HlsVodRollingSession(
      videoSegments: fixture.video,
      fetcher: (uri) async {
        fetched.add(uri);
        return _readFixture(uri);
      },
      prefetchWindow: 2,
      maxAttempts: 1,
    );
    addTearDown(session.dispose);

    final done = session.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fetched, isEmpty);
    expect(session.progress.videoSegmentsLoaded, 0);

    final updatesFuture = session.updates.toList();
    await done;
    final updates = await updatesFuture;

    expect(fetched, hasLength(4));
    expect(updates.last.sealed, isTrue);
    expect(session.isReady, isTrue);
  });

  test(
    'mid-VOD restart keeps the original video timeline and local A/V offset',
    () async {
      final fixture = await _fixtureSegments();
      final original = HlsVodRollingSession(
        videoSegments: fixture.video,
        fetcher: _readFixture,
        prefetchWindow: 1,
        maxAttempts: 1,
      );
      addTearDown(original.dispose);
      final originalUpdates = original.updates.toList();
      unawaited(original.start());
      await original.done;
      await originalUpdates;
      final timelineBase = original.baseVideoPts90k;
      expect(timelineBase, isNotNull);

      final restarted = HlsVodRollingSession(
        videoSegments: fixture.video.skip(2),
        audioSegments: fixture.audio.skip(2),
        fetcher: _readFixture,
        videoTimestampBase90k: timelineBase,
        prebufferSegments: 1,
        prefetchWindow: 1,
        maxAttempts: 1,
      );
      addTearDown(restarted.dispose);
      final restartedUpdatesFuture = restarted.updates.toList();
      unawaited(restarted.start());
      await restarted.done;
      final restartedUpdates = await restartedUpdatesFuture;
      final videoUnits = restartedUpdates
          .expand((update) => update.videoAccessUnits)
          .toList(growable: false);
      final ready = restartedUpdates.singleWhere(
        (update) => update.becameReady,
      );

      expect(videoUnits.first.hasIdr, isTrue);
      expect(videoUnits.first.ptsMs, greaterThan(0));
      expect(restarted.baseVideoPts90k, timelineBase);
      expect(restarted.firstVideoPts90k, videoUnits.first.pts90k);
      expect(restarted.firstVideoPtsMs, videoUnits.first.ptsMs);
      expect(ready.firstVideoPtsMs, videoUnits.first.ptsMs);
      expect(ready.audioVideoPtsDelta90k, isNotNull);
      expect(ready.audioVideoPtsDelta90k!.abs(), lessThanOrEqualTo(45000));
      expect(restarted.isSealed, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'delayed out-of-order fetches emit synchronized ordered rolling batches',
    () async {
      final fixture = await _fixtureSegments();
      final gates = <Uri, Completer<Uint8List>>{};
      final started = <Uri>[];

      Future<Uint8List> gatedFetch(Uri uri) {
        started.add(uri);
        final gate = Completer<Uint8List>();
        gates[uri] = gate;
        return gate.future;
      }

      final session = HlsVodRollingSession(
        // Reversed inputs prove that media sequence, not caller order, wins.
        videoSegments: fixture.video.reversed,
        audioSegments: fixture.audio.reversed,
        fetcher: gatedFetch,
        epoch: 17,
        prefetchWindow: 4,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);
      final updatesFuture = session.updates.toList();
      unawaited(session.start());

      await _waitUntil(() => started.length == 8);
      expect(started.toSet(), hasLength(8));

      // Finish both rendition windows backwards. Loader completion order is
      // deliberately unrelated to the coordinator's output order.
      for (var index = fixture.video.length - 1; index >= 0; index--) {
        gates[fixture.audio[index].uri]!.complete(
          await _readFixture(fixture.audio[index].uri),
        );
        gates[fixture.video[index].uri]!.complete(
          await _readFixture(fixture.video[index].uri),
        );
      }

      await session.done;
      final updates = await updatesFuture;
      final segmentUpdates = updates
          .where((update) => update.mediaSequence != null)
          .toList(growable: false);
      final videoUnits = updates
          .expand((update) => update.videoAccessUnits)
          .toList(growable: false);
      final audioUnits = updates
          .expand((update) => update.audioAccessUnits)
          .toList(growable: false);

      expect(
        segmentUpdates.map((update) => update.mediaSequence),
        orderedEquals(<int>[0, 1, 2, 3]),
      );
      expect(videoUnits, hasLength(226));
      expect(videoUnits.first.hasIdr, isTrue);
      expect(audioUnits, hasLength(353));

      final readyUpdates = updates
          .where((update) => update.becameReady)
          .toList(growable: false);
      expect(readyUpdates, hasLength(1));
      final ready = readyUpdates.single;
      expect(ready.mediaSequence, 1);
      expect(ready.epoch, 17);
      expect(ready.progress.videoSegmentsLoaded, 2);
      expect(ready.progress.audioSegmentsLoaded, 2);
      expect(ready.baseVideoPts90k, isNotNull);
      expect(ready.audioConfig?.isAacLc, isTrue);
      expect(ready.audioVideoPtsDelta90k, isNotNull);
      expect(ready.audioVideoPtsDelta90k!.abs(), lessThanOrEqualTo(45000));
      expect(ready.progress.audioState, HlsVodAudioState.active);

      expect(updates.last.sealed, isTrue);
      expect(updates.last.error, isNull);
      expect(updates.last.progress.videoSegmentsLoaded, 4);
      expect(updates.last.progress.audioSegmentsLoaded, 4);
      expect(updates.last.progress.loadedFraction, 1);
      expect(session.isReady, isTrue);
      expect(session.isSealed, isTrue);
      expect(session.error, isNull);
      expect(session.retainedSegmentByteCount, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('cancel unblocks loaders whose fetch futures never complete', () async {
    final video = <HlsSegment>[
      for (var index = 0; index < 6; index++)
        HlsSegment(
          uri: Uri.parse('https://video.invalid/segment_$index.ts'),
          duration: 2,
          sequence: 40 + index,
          discontinuitySequence: 9,
        ),
    ];
    final gates = <Uri, Completer<Uint8List>>{};
    final started = <Uri>[];
    final session = HlsVodRollingSession(
      videoSegments: video,
      fetcher: (uri) {
        started.add(uri);
        final gate = Completer<Uint8List>();
        gates[uri] = gate;
        return gate.future;
      },
      prefetchWindow: 3,
      maxAttempts: 1,
    );
    addTearDown(session.dispose);
    final updatesFuture = session.updates.toList();
    unawaited(session.start());

    await _waitUntil(() => started.length == 3);
    await session.cancel().timeout(const Duration(seconds: 1));
    final updates = await updatesFuture;

    expect(started, hasLength(3));
    expect(updates, hasLength(1));
    expect(updates.single.cancelled, isTrue);
    expect(updates.single.sealed, isFalse);
    expect(updates.single.error, isNull);
    expect(session.isCancelled, isTrue);
    expect(session.isSealed, isFalse);
    expect(session.retainedSegmentByteCount, 0);

    // Let ignored transport futures settle; they must not restart the loader.
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete(Uint8List(188));
    }
    await _flushAsyncWork();
    expect(started, hasLength(3));
  });

  test('paused update consumer stops the next fetch and emission', () async {
    final fixture = await _fixtureSegments();
    final started = <Uri>[];
    final session = HlsVodRollingSession(
      videoSegments: fixture.video,
      fetcher: (uri) async {
        started.add(uri);
        return _readFixture(uri);
      },
      prefetchWindow: 1,
      maxAttempts: 1,
    );
    addTearDown(session.dispose);

    final receivedSequences = <int>[];
    final firstUpdate = Completer<void>();
    final streamDone = Completer<void>();
    late final StreamSubscription<HlsVodSessionUpdate> subscription;
    subscription = session.updates.listen((update) {
      final sequence = update.mediaSequence;
      if (sequence == null) return;
      receivedSequences.add(sequence);
      if (!firstUpdate.isCompleted) {
        subscription.pause();
        firstUpdate.complete();
      }
    }, onDone: streamDone.complete);
    addTearDown(subscription.cancel);
    unawaited(session.start());

    await firstUpdate.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(started, hasLength(1));
    expect(receivedSequences, <int>[0]);

    subscription.resume();
    await session.done;
    await streamDone.future;
    expect(started, hasLength(4));
    expect(receivedSequences, <int>[0, 1, 2, 3]);
    expect(session.isSealed, isTrue);
  });

  test(
    'muxed AAC reuses video responses without duplicate downloads',
    () async {
      final fixture = await _fixtureSegments();
      final fetched = <Uri>[];
      final session = HlsVodRollingSession(
        videoSegments: fixture.video,
        audioFromVideoSegments: true,
        fetcher: (uri) async {
          fetched.add(uri);
          return _readFixture(uri);
        },
        maxAttempts: 1,
      );
      addTearDown(session.dispose);
      final updatesFuture = session.updates.toList();
      unawaited(session.start());
      await session.done;
      final updates = await updatesFuture;

      expect(fetched, hasLength(4));
      expect(fetched.toSet(), hasLength(4));
      expect(session.audioFromVideoSegments, isTrue);
      expect(session.audioState, HlsVodAudioState.active);
      expect(session.audioVideoPtsDelta90k, isNotNull);
      expect(session.progress.audioSegmentsLoaded, 4);
      expect(
        updates.expand((update) => update.videoAccessUnits),
        hasLength(226),
      );
      expect(
        updates.expand((update) => update.audioAccessUnits),
        hasLength(353),
      );
      expect(updates.last.sealed, isTrue);
    },
  );

  test(
    'muxed video-only PMT becomes ready at prebuffer before VOD end',
    () async {
      final fixture = await _fixtureSegments();
      final fetched = <Uri>[];
      final session = HlsVodRollingSession(
        videoSegments: fixture.video,
        audioFromVideoSegments: true,
        fetcher: (uri) async {
          fetched.add(uri);
          return _removeAdtsDeclaration(await _readFixture(uri));
        },
        prefetchWindow: 1,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);

      final updates = <HlsVodSessionUpdate>[];
      final readyUpdate = Completer<HlsVodSessionUpdate>();
      final streamDone = Completer<void>();
      late final StreamSubscription<HlsVodSessionUpdate> subscription;
      subscription = session.updates.listen((update) {
        updates.add(update);
        if (update.becameReady && !readyUpdate.isCompleted) {
          subscription.pause();
          readyUpdate.complete(update);
        }
      }, onDone: streamDone.complete);
      addTearDown(subscription.cancel);
      unawaited(session.start());

      final ready = await readyUpdate.future.timeout(
        const Duration(seconds: 2),
      );
      expect(ready.mediaSequence, 1);
      expect(ready.progress.videoSegmentsLoaded, 2);
      expect(ready.progress.audioState, HlsVodAudioState.downgradedVideoOnly);
      expect(ready.audioDowngradeReason, isA<HlsVodSessionFailure>());
      expect(ready.audioDowngradeReason.toString(), contains('no ADTS AAC'));
      expect(ready.audioAccessUnits, isEmpty);
      expect(session.isReady, isTrue);
      expect(session.isSealed, isFalse);
      expect(fetched, hasLength(2));

      subscription.resume();
      await session.done;
      await streamDone.future;
      expect(fetched, hasLength(4));
      expect(session.isSealed, isTrue);
      expect(session.error, isNull);
      expect(
        updates.expand((update) => update.videoAccessUnits),
        hasLength(226),
      );
      expect(updates.expand((update) => update.audioAccessUnits), isEmpty);
    },
  );

  test('audio load failure before readiness commits to video-only', () async {
    final fixture = await _fixtureSegments();
    final session = HlsVodRollingSession(
      videoSegments: fixture.video,
      audioSegments: fixture.audio,
      fetcher: _readFixture,
      audioFetcher: (uri) async {
        throw StateError('audio unavailable at ${uri.pathSegments.last}');
      },
      prefetchWindow: 2,
      maxAttempts: 1,
    );
    addTearDown(session.dispose);
    final updatesFuture = session.updates.toList();
    unawaited(session.start());
    await session.done;
    final updates = await updatesFuture;

    expect(session.isReady, isTrue);
    expect(session.isSealed, isTrue);
    expect(session.error, isNull);
    expect(session.audioState, HlsVodAudioState.downgradedVideoOnly);
    expect(session.audioDowngradeReason, isA<HlsVodSessionFailure>());
    expect(session.audioConfig, isNull);
    expect(updates.expand((update) => update.videoAccessUnits), hasLength(226));
    expect(updates.expand((update) => update.audioAccessUnits), isEmpty);
    expect(updates.where((update) => update.becameReady), hasLength(1));
    expect(updates.last.audioDowngradeReason, isNotNull);
    expect(updates.last.sealed, isTrue);
  });

  test(
    'audio load failure after readiness is terminal, never downgraded',
    () async {
      final fixture = await _fixtureSegments();
      final session = HlsVodRollingSession(
        videoSegments: fixture.video,
        audioSegments: fixture.audio,
        fetcher: _readFixture,
        audioFetcher: (uri) {
          if (uri.pathSegments.last == 'segment_002.ts') {
            throw StateError('late audio failure');
          }
          return _readFixture(uri);
        },
        prefetchWindow: 2,
        maxAttempts: 1,
      );
      addTearDown(session.dispose);
      final updatesFuture = session.updates.toList();
      unawaited(session.start());
      await session.done;
      final updates = await updatesFuture;

      expect(updates.where((update) => update.becameReady), hasLength(1));
      expect(session.isReady, isTrue);
      expect(session.isSealed, isFalse);
      expect(session.audioState, HlsVodAudioState.active);
      expect(session.audioDowngradeReason, isNull);
      expect(session.error, isA<HlsVodSessionFailure>());
      expect(session.error.toString(), contains('audio segment load'));
      expect(updates.last.error, same(session.error));
      expect(updates.last.sealed, isFalse);
      expect(
        updates.where(
          (update) =>
              update.progress.audioState ==
              HlsVodAudioState.downgradedVideoOnly,
        ),
        isEmpty,
      );
    },
  );

  test('constructor rejects multiple or unsynchronized epochs', () {
    final mixedVideo = <HlsSegment>[
      HlsSegment(
        uri: Uri.parse('https://video.invalid/0.ts'),
        duration: 2,
        sequence: 0,
        discontinuitySequence: 4,
      ),
      HlsSegment(
        uri: Uri.parse('https://video.invalid/1.ts'),
        duration: 2,
        sequence: 1,
        discontinuitySequence: 5,
      ),
    ];
    expect(
      () => HlsVodRollingSession(
        videoSegments: mixedVideo,
        fetcher: (_) async => Uint8List(0),
      ),
      throwsA(isA<HlsDiscontinuityUnsupportedException>()),
    );

    final video = <HlsSegment>[
      HlsSegment(
        uri: Uri.parse('https://video.invalid/0.ts'),
        duration: 2,
        sequence: 0,
        discontinuitySequence: 4,
      ),
    ];
    final audio = <HlsSegment>[
      HlsSegment(
        uri: Uri.parse('https://audio.invalid/0.ts'),
        duration: 2,
        sequence: 0,
        discontinuitySequence: 5,
      ),
    ];
    expect(
      () => HlsVodRollingSession(
        videoSegments: video,
        audioSegments: audio,
        fetcher: (_) async => Uint8List(0),
      ),
      throwsFormatException,
    );

    expect(
      () => HlsVodRollingSession(
        videoSegments: video,
        audioSegments: video,
        audioFromVideoSegments: true,
        fetcher: (_) async => Uint8List(0),
      ),
      throwsArgumentError,
    );
  });
}

Future<({List<HlsSegment> video, List<HlsSegment> audio})>
_fixtureSegments() async {
  final playlist = await fetchMediaPlaylist(
    _fixturePlaylistUri,
    byteFetcher: _readFixture,
  );
  List<HlsSegment> rendition(String scheme) => <HlsSegment>[
    for (final segment in playlist.segments)
      HlsSegment(
        uri: Uri(scheme: scheme, path: '/${segment.uri.pathSegments.last}'),
        duration: segment.duration,
        sequence: segment.sequence,
        discontinuitySequence: segment.discontinuitySequence,
      ),
  ];

  return (video: rendition('fixture-video'), audio: rendition('fixture-audio'));
}

Future<Uint8List> _readFixture(Uri uri) {
  final name = uri.pathSegments.last;
  return File('$_fixtureRoot/$name').readAsBytes();
}

/// Re-labels ADTS entries in each complete PMT as private data for a
/// deterministic video-only TS fixture. The production PSI parser deliberately
/// does not validate PMT CRC, so changing the stream type is sufficient while
/// leaving every H.264 packet byte-identical to the Butterfly golden.
Uint8List _removeAdtsDeclaration(Uint8List source) {
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
    cursor += 1 + bytes[cursor]; // PSI pointer field and preceding bytes.
    if (cursor + 12 > packetStart + packetSize || bytes[cursor] != 0x02) {
      continue;
    }

    final sectionLength = ((bytes[cursor + 1] & 0x0f) << 8) | bytes[cursor + 2];
    final sectionEnd = cursor + 3 + sectionLength - 4; // Exclude CRC.
    if (sectionEnd > packetStart + packetSize) continue;
    final programInfoLength =
        ((bytes[cursor + 10] & 0x0f) << 8) | bytes[cursor + 11];
    var entry = cursor + 12 + programInfoLength;
    while (entry + 5 <= sectionEnd) {
      final esInfoLength = ((bytes[entry + 3] & 0x0f) << 8) | bytes[entry + 4];
      if (bytes[entry] == 0x0f) {
        bytes[entry] = 0x06;
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

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Asynchronous condition was not reached');
}

Future<void> _flushAsyncWork() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}
