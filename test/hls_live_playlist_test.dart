import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/hls_live_playlist.dart';

final _playlistUri = Uri.parse('https://live.example.test/channel/main.m3u8');

void main() {
  test(
    'listener-gated refresh emits ordered overlap deltas near live edge',
    () async {
      final clock = _FakeClock(DateTime.utc(2026, 8, 20, 1));
      final snapshots = <String>[
        _playlist(targetDuration: 4, mediaSequence: 100, count: 6),
        _playlist(targetDuration: 4, mediaSequence: 103, count: 5),
        _playlist(
          targetDuration: 4,
          mediaSequence: 105,
          count: 4,
          endList: true,
        ),
      ];
      var fetchCount = 0;
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => _bytes(snapshots[fetchCount++]),
        epoch: 12,
        initialHoldBackSegments: 3,
        historyCapacity: 6,
        maxWindowSegments: 6,
        clock: clock.call,
        sleeper: clock.sleep,
      );
      addTearDown(coordinator.dispose);

      final done = coordinator.start();
      await _flushAsyncWork();
      expect(fetchCount, 0, reason: 'start must wait for an update listener');

      final updatesFuture = coordinator.updates.toList();
      await done;
      final updates = await updatesFuture;

      expect(fetchCount, 3);
      expect(updates, hasLength(3));
      expect(
        updates.map(
          (update) => update.newSegments
              .map((segment) => segment.sequence)
              .toList(growable: false),
        ),
        equals(<List<int>>[
          <int>[103, 104, 105],
          <int>[106, 107],
          <int>[108],
        ]),
      );
      expect(clock.delays, <Duration>[
        const Duration(seconds: 4),
        const Duration(seconds: 4),
      ]);
      expect(
        updates.map((update) => update.fetchedAt),
        orderedEquals(<DateTime>[
          DateTime.utc(2026, 8, 20, 1),
          DateTime.utc(2026, 8, 20, 1, 0, 4),
          DateTime.utc(2026, 8, 20, 1, 0, 8),
        ]),
      );

      expect(updates.first.epoch, 12);
      expect(updates.first.mediaSequence, 100);
      expect(updates.first.windowFirstSequence, 100);
      expect(updates.first.windowLastSequence, 105);
      expect(updates.first.windowSegmentCount, 6);
      expect(updates.first.targetDuration, 4);
      expect(updates.first.nextRefreshDelay, const Duration(seconds: 4));
      expect(updates.first.progress.initialSegmentsSkipped, 3);
      expect(updates.last.isEndList, isTrue);
      expect(updates.last.nextRefreshDelay, isNull);
      expect(updates.last.sealed, isTrue);
      expect(updates.last.error, isNull);
      expect(updates.last.progress.refreshesCompleted, 3);
      expect(updates.last.progress.segmentsEmitted, 6);
      expect(updates.last.progress.lastEmittedSequence, 108);
      expect(updates.last.progress.retainedHistoryCount, 6);
      expect(coordinator.retainedSegmentMetadataCount, 6);
      expect(coordinator.retainedSegmentByteCount, 0);
      expect(coordinator.state, HlsLivePlaylistState.sealed);
    },
  );

  test(
    'empty initial snapshots can later anchor at configured hold-back',
    () async {
      final snapshots = <String>[
        _playlist(targetDuration: 3, mediaSequence: 50, count: 0),
        _playlist(
          targetDuration: 3,
          mediaSequence: 50,
          count: 5,
          endList: true,
        ),
      ];
      var fetchCount = 0;
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => _bytes(snapshots[fetchCount++]),
        initialHoldBackSegments: 2,
        sleeper: (_) async {},
      );
      addTearDown(coordinator.dispose);

      final updatesFuture = coordinator.updates.toList();
      unawaited(coordinator.start());
      await coordinator.done;
      final updates = await updatesFuture;

      expect(updates, hasLength(2));
      expect(updates.first.newSegments, isEmpty);
      expect(
        updates.last.newSegments.map((segment) => segment.sequence),
        orderedEquals(<int>[53, 54]),
      );
      expect(updates.last.progress.initialSegmentsSkipped, 3);
      expect(updates.last.sealed, isTrue);
    },
  );

  test(
    'unchanged overlapping snapshots deduplicate without growing history',
    () async {
      final clock = _FakeClock(DateTime.utc(2026, 8, 20, 2));
      final unchanged = _playlist(
        targetDuration: 5,
        mediaSequence: 40,
        count: 3,
      );
      final snapshots = <String>[
        unchanged,
        unchanged,
        _playlist(
          targetDuration: 5,
          mediaSequence: 40,
          count: 3,
          endList: true,
        ),
      ];
      var fetchCount = 0;
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => _bytes(snapshots[fetchCount++]),
        initialHoldBackSegments: null,
        historyCapacity: 3,
        maxWindowSegments: 3,
        clock: clock.call,
        sleeper: clock.sleep,
      );
      addTearDown(coordinator.dispose);

      final updatesFuture = coordinator.updates.toList();
      unawaited(coordinator.start());
      await coordinator.done;
      final updates = await updatesFuture;

      expect(
        updates.map((update) => update.newSegments.length),
        orderedEquals(<int>[3, 0, 0]),
      );
      expect(
        updates.map((update) => update.progress.retainedHistoryCount),
        everyElement(3),
      );
      expect(coordinator.retainedSegmentMetadataCount, 3);
      expect(clock.delays, <Duration>[
        const Duration(seconds: 5),
        const Duration(milliseconds: 2500),
      ]);
    },
  );

  test('consumer pause prevents the next refresh sleep and fetch', () async {
    final snapshots = <String>[
      _playlist(targetDuration: 2, mediaSequence: 1, count: 2),
      _playlist(targetDuration: 2, mediaSequence: 1, count: 3, endList: true),
    ];
    var fetchCount = 0;
    var sleepCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async => _bytes(snapshots[fetchCount++]),
      sleeper: (_) async => sleepCount++,
    );
    addTearDown(coordinator.dispose);

    final firstUpdate = Completer<void>();
    final streamDone = Completer<void>();
    final received = <HlsLivePlaylistUpdate>[];
    late final StreamSubscription<HlsLivePlaylistUpdate> subscription;
    subscription = coordinator.updates.listen((update) {
      received.add(update);
      if (!firstUpdate.isCompleted) {
        subscription.pause();
        firstUpdate.complete();
      }
    }, onDone: streamDone.complete);
    addTearDown(subscription.cancel);
    unawaited(coordinator.start());

    await firstUpdate.future.timeout(const Duration(seconds: 1));
    await _flushAsyncWork();
    expect(fetchCount, 1);
    expect(sleepCount, 0);
    expect(received, hasLength(1));

    subscription.resume();
    await coordinator.done;
    await streamDone.future;
    expect(fetchCount, 2);
    expect(sleepCount, 1);
    expect(received, hasLength(2));
    expect(received.last.sealed, isTrue);
  });

  test(
    'subscription cancel inside ENDLIST update cannot replace sealed state',
    () async {
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => _bytes(
          _playlist(
            targetDuration: 4,
            mediaSequence: 10,
            count: 2,
            endList: true,
          ),
        ),
      );
      addTearDown(coordinator.dispose);

      final received = <HlsLivePlaylistUpdate>[];
      final subscriptionCancelled = Completer<void>();
      late final StreamSubscription<HlsLivePlaylistUpdate> subscription;
      subscription = coordinator.updates.listen((update) {
        received.add(update);
        if (update.sealed) {
          unawaited(
            subscription.cancel().then((_) => subscriptionCancelled.complete()),
          );
        }
      });
      addTearDown(subscription.cancel);
      unawaited(coordinator.start());

      await coordinator.done.timeout(const Duration(seconds: 1));
      await subscriptionCancelled.future.timeout(const Duration(seconds: 1));
      expect(received, hasLength(1));
      expect(received.single.sealed, isTrue);
      expect(coordinator.state, HlsLivePlaylistState.sealed);
      expect(coordinator.isCancelled, isFalse);
    },
  );

  test(
    'cancel-before-start is reentrancy-safe when listener cancels itself',
    () async {
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => throw StateError('must not fetch'),
      );
      addTearDown(coordinator.dispose);

      final received = <HlsLivePlaylistUpdate>[];
      final subscriptionCancelled = Completer<void>();
      late final StreamSubscription<HlsLivePlaylistUpdate> subscription;
      subscription = coordinator.updates.listen((update) {
        received.add(update);
        unawaited(
          subscription.cancel().then((_) => subscriptionCancelled.complete()),
        );
      });
      addTearDown(subscription.cancel);

      await coordinator.cancel().timeout(const Duration(seconds: 1));
      await subscriptionCancelled.future.timeout(const Duration(seconds: 1));
      expect(received, hasLength(1));
      expect(received.single.cancelled, isTrue);
      expect(coordinator.state, HlsLivePlaylistState.cancelled);
      expect(coordinator.isStarted, isFalse);
    },
  );

  test('cancel unblocks a delayed refresh sleeper', () async {
    final sleepStarted = Completer<void>();
    final sleepGate = Completer<void>();
    var fetchCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async {
        fetchCount++;
        return _bytes(
          _playlist(targetDuration: 6, mediaSequence: 70, count: 3),
        );
      },
      sleeper: (_) {
        sleepStarted.complete();
        return sleepGate.future;
      },
    );
    addTearDown(coordinator.dispose);
    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());

    await sleepStarted.future.timeout(const Duration(seconds: 1));
    await coordinator.cancel().timeout(const Duration(seconds: 1));
    final updates = await updatesFuture;

    expect(fetchCount, 1);
    expect(updates, hasLength(2));
    expect(updates.first.cancelled, isFalse);
    expect(updates.last.cancelled, isTrue);
    expect(updates.last.newSegments, isEmpty);
    expect(coordinator.state, HlsLivePlaylistState.cancelled);
    sleepGate.complete();
    await _flushAsyncWork();
    expect(fetchCount, 1);
  });

  test(
    'cancel unblocks a delayed playlist fetch and ignores its late error',
    () async {
      final fetchStarted = Completer<void>();
      final fetchGate = Completer<Uint8List>();
      var fetchCount = 0;
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) {
          fetchCount++;
          fetchStarted.complete();
          return fetchGate.future;
        },
        sleeper: (_) async {},
      );
      addTearDown(coordinator.dispose);
      final updatesFuture = coordinator.updates.toList();
      unawaited(coordinator.start());

      await fetchStarted.future.timeout(const Duration(seconds: 1));
      await coordinator.cancel().timeout(const Duration(seconds: 1));
      final updates = await updatesFuture;

      expect(fetchCount, 1);
      expect(updates, hasLength(1));
      expect(updates.single.cancelled, isTrue);
      expect(updates.single.mediaSequence, isNull);
      fetchGate.completeError(StateError('late transport failure'));
      await _flushAsyncWork();
      expect(fetchCount, 1);
    },
  );

  test('expired live-window gap fails with the missing sequence', () async {
    final snapshots = <String>[
      _playlist(targetDuration: 3, mediaSequence: 20, count: 2),
      _playlist(targetDuration: 3, mediaSequence: 23, count: 2, endList: true),
    ];
    var fetchCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async => _bytes(snapshots[fetchCount++]),
      initialHoldBackSegments: null,
      sleeper: (_) async {},
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(coordinator.state, HlsLivePlaylistState.failed);
    expect(updates, hasLength(2));
    final error = updates.last.error;
    expect(error, isA<HlsLivePlaylistExpiredGapException>());
    final gap = error! as HlsLivePlaylistExpiredGapException;
    expect(gap.expectedSequence, 22);
    expect(gap.playlistMediaSequence, 23);
    expect(coordinator.isSealed, isFalse);
  });

  test('media-sequence rewind is detected before duplicate emission', () async {
    final snapshots = <String>[
      _playlist(targetDuration: 3, mediaSequence: 30, count: 3),
      _playlist(targetDuration: 3, mediaSequence: 29, count: 4),
    ];
    var fetchCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async => _bytes(snapshots[fetchCount++]),
      initialHoldBackSegments: null,
      sleeper: (_) async {},
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(updates, hasLength(2));
    expect(updates.last.error, isA<HlsLivePlaylistRewindException>());
    expect(updates.first.progress.segmentsEmitted, 3);
    expect(updates.last.progress.segmentsEmitted, 3);
  });

  test(
    'shrinking high edge is detected when media sequence advances',
    () async {
      final snapshots = <String>[
        _playlist(targetDuration: 3, mediaSequence: 30, count: 4),
        _playlist(targetDuration: 3, mediaSequence: 31, count: 2),
      ];
      var fetchCount = 0;
      final coordinator = HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => _bytes(snapshots[fetchCount++]),
        initialHoldBackSegments: null,
        sleeper: (_) async {},
      );
      addTearDown(coordinator.dispose);

      final updatesFuture = coordinator.updates.toList();
      unawaited(coordinator.start());
      await coordinator.done;
      final updates = await updatesFuture;

      expect(updates, hasLength(2));
      expect(updates.last.error, isA<HlsLivePlaylistRewindException>());
      expect(updates.last.progress.segmentsEmitted, 4);
    },
  );

  test('discontinuity sequence cannot rewind without overlap', () async {
    final snapshots = <String>[
      _playlist(
        targetDuration: 3,
        mediaSequence: 1,
        count: 2,
        discontinuitySequence: 5,
      ),
      _playlist(
        targetDuration: 3,
        mediaSequence: 3,
        count: 2,
        discontinuitySequence: 4,
      ),
    ];
    var fetchCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async => _bytes(snapshots[fetchCount++]),
      initialHoldBackSegments: null,
      sleeper: (_) async {},
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(updates, hasLength(2));
    expect(
      updates.last.error,
      isA<HlsLivePlaylistDiscontinuityRewindException>(),
    );
    expect(updates.last.progress.segmentsEmitted, 2);
  });

  test('mutation of an already-seen sequence is rejected', () async {
    final snapshots = <String>[
      _playlist(targetDuration: 3, mediaSequence: 8, count: 3),
      _playlist(
        targetDuration: 3,
        mediaSequence: 8,
        count: 3,
        endList: true,
        uriForSequence: (sequence) =>
            sequence == 9 ? 'replacement_$sequence.ts' : 'segment_$sequence.ts',
      ),
    ];
    var fetchCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async => _bytes(snapshots[fetchCount++]),
      initialHoldBackSegments: null,
      historyCapacity: 3,
      maxWindowSegments: 3,
      sleeper: (_) async {},
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(updates, hasLength(2));
    final error = updates.last.error;
    expect(error, isA<HlsLivePlaylistMutationException>());
    expect((error! as HlsLivePlaylistMutationException).sequence, 9);
    expect(coordinator.retainedSegmentMetadataCount, 3);
    expect(coordinator.isSealed, isFalse);
  });

  test('refresh deadline deducts delayed fetch time', () async {
    final clock = _FakeClock(DateTime.utc(2026, 8, 20, 3));
    var fetchCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async {
        final currentFetch = fetchCount++;
        if (currentFetch == 0) clock.advance(const Duration(seconds: 2));
        return _bytes(
          _playlist(
            targetDuration: 6,
            mediaSequence: 1,
            count: currentFetch + 1,
            endList: currentFetch == 1,
          ),
        );
      },
      clock: clock.call,
      sleeper: clock.sleep,
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(fetchCount, 2);
    expect(updates.first.fetchedAt, DateTime.utc(2026, 8, 20, 3, 0, 2));
    expect(updates.first.nextRefreshDelay, const Duration(seconds: 4));
    expect(clock.delays, <Duration>[const Duration(seconds: 4)]);
    expect(updates.last.fetchedAt, DateTime.utc(2026, 8, 20, 3, 0, 6));
    expect(updates.last.sealed, isTrue);
  });

  test('invalid target duration fails instead of busy-refreshing', () async {
    var fetchCount = 0;
    var sleepCount = 0;
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async {
        fetchCount++;
        return _bytes(_playlist(targetDuration: 0, mediaSequence: 1, count: 1));
      },
      sleeper: (_) async => sleepCount++,
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(fetchCount, 1);
    expect(sleepCount, 0);
    expect(updates, hasLength(1));
    expect(updates.single.error, isA<FormatException>());
    expect(coordinator.state, HlsLivePlaylistState.failed);
  });

  test('playlist response byte cap fails before text parsing', () async {
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async => _bytes(
        _playlist(targetDuration: 4, mediaSequence: 1, count: 1, endList: true),
      ),
      maxPlaylistBytes: 16,
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(updates, hasLength(1));
    expect(updates.single.error, isA<HlsLivePlaylistFailure>());
    final failure = updates.single.error! as HlsLivePlaylistFailure;
    expect(failure.stage, 'playlist fetch/parse');
    expect(failure.cause, isA<FormatException>());
    expect(coordinator.retainedSegmentByteCount, 0);
  });

  test('snapshot segment cap rejects an oversized live window', () async {
    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: _playlistUri,
      fetcher: (_) async =>
          _bytes(_playlist(targetDuration: 4, mediaSequence: 1, count: 3)),
      historyCapacity: 2,
      maxWindowSegments: 2,
    );
    addTearDown(coordinator.dispose);

    final updatesFuture = coordinator.updates.toList();
    unawaited(coordinator.start());
    await coordinator.done;
    final updates = await updatesFuture;

    expect(updates, hasLength(1));
    expect(updates.single.error, isA<FormatException>());
    expect(coordinator.retainedSegmentMetadataCount, 0);
  });

  test('constructor enforces a mutation history covering the window bound', () {
    expect(
      () => HlsLivePlaylistCoordinator(
        playlistUri: _playlistUri,
        fetcher: (_) async => Uint8List(0),
        historyCapacity: 2,
        maxWindowSegments: 3,
      ),
      throwsArgumentError,
    );
  });
}

String _playlist({
  required int targetDuration,
  required int mediaSequence,
  required int count,
  bool endList = false,
  int discontinuitySequence = 0,
  String Function(int sequence)? uriForSequence,
}) {
  final output = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:3')
    ..writeln('#EXT-X-TARGETDURATION:$targetDuration')
    ..writeln('#EXT-X-MEDIA-SEQUENCE:$mediaSequence')
    ..writeln('#EXT-X-DISCONTINUITY-SEQUENCE:$discontinuitySequence');
  for (var offset = 0; offset < count; offset++) {
    final sequence = mediaSequence + offset;
    output
      ..writeln('#EXTINF:${targetDuration.toDouble()},')
      ..writeln(uriForSequence?.call(sequence) ?? 'segment_$sequence.ts');
  }
  if (endList) output.writeln('#EXT-X-ENDLIST');
  return output.toString();
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Future<void> _flushAsyncWork() async {
  for (var index = 0; index < 4; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _FakeClock {
  _FakeClock(this.now);

  DateTime now;
  final List<Duration> delays = <Duration>[];

  DateTime call() => now;

  void advance(Duration duration) {
    now = now.add(duration);
  }

  Future<void> sleep(Duration delay) async {
    delays.add(delay);
    advance(delay);
  }
}
