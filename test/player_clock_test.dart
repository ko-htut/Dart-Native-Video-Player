import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/player_clock.dart';

class _Item {
  const _Item(this.id, this.ptsMs);

  final String id;
  final int ptsMs;
}

void main() {
  group('validateSequentialDecodeDependencyWindow', () {
    bool isBoundary(_Item item) => item.id.startsWith('K');

    test('reserves the final resident slot for the next boundary', () {
      final last = validateSequentialDecodeDependencyWindow(
        items: const [
          _Item('K0', 0),
          _Item('p1', 10),
          _Item('p2', 20),
          _Item('K3', 30),
        ],
        startIndex: 0,
        previousBoundaryIndex: null,
        maximumItems: 4,
        isDependencyBoundary: isBoundary,
      );
      expect(last, 3);

      expect(
        () => validateSequentialDecodeDependencyWindow(
          items: const [
            _Item('K0', 0),
            _Item('p1', 10),
            _Item('p2', 20),
            _Item('p3', 30),
          ],
          startIndex: 0,
          previousBoundaryIndex: null,
          maximumItems: 4,
          isDependencyBoundary: isBoundary,
        ),
        throwsA(isA<SequentialDecodeDependencyWindowException>()),
      );
    });

    test('validates boundaries across incremental batches', () {
      final last = validateSequentialDecodeDependencyWindow(
        items: const [_Item('p2', 20), _Item('K3', 30)],
        startIndex: 2,
        previousBoundaryIndex: 0,
        maximumItems: 4,
        isDependencyBoundary: isBoundary,
      );
      expect(last, 3);

      expect(
        () => validateSequentialDecodeDependencyWindow(
          items: const [_Item('p0', 0)],
          startIndex: 0,
          previousBoundaryIndex: null,
          maximumItems: 4,
          isDependencyBoundary: isBoundary,
        ),
        throwsA(isA<SequentialDecodeDependencyWindowException>()),
      );
    });
  });

  group('SequentialDecodePump', () {
    test(
      'decodes every due item in order and presents only the latest',
      () async {
        final gates = <String, Completer<String>>{
          'a': Completer<String>(),
          'b': Completer<String>(),
          'c': Completer<String>(),
        };
        final decodeOrder = <String>[];
        final presented = <String>[];
        var drained = 0;

        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) {
            decodeOrder.add(item.id);
            return gates[item.id]!.future;
          },
          onLatestDecoded: (item, result) =>
              presented.add('${item.id}:$result'),
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          onQueueDrained: () => drained++,
        );
        pump.replaceQueue(const [
          _Item('a', 0),
          _Item('b', 10),
          _Item('c', 20),
        ]);

        pump.requestThrough(20);
        await Future<void>.delayed(Duration.zero);
        expect(decodeOrder, ['a']);

        // A newer clock request while a decode is pending must not skip ahead.
        pump.requestThrough(100);
        gates['a']!.complete('A');
        await Future<void>.delayed(Duration.zero);
        expect(decodeOrder, ['a', 'b']);

        gates['b']!.complete('B');
        await Future<void>.delayed(Duration.zero);
        expect(decodeOrder, ['a', 'b', 'c']);

        gates['c']!.complete('C');
        await pump.waitUntilIdle();

        expect(pump.nextIndex, 3);
        expect(presented, ['c:C']);
        expect(drained, 1);
      },
    );

    test(
      'keeps decode order while presenting B pictures in timestamp order',
      () async {
        final decoded = <String>[];
        final presented = <String>[];
        var drained = 0;
        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) {
            decoded.add(item.id);
            return item.id.toUpperCase();
          },
          onLatestDecoded: (item, result) =>
              presented.add('$result@${item.ptsMs}'),
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          onQueueDrained: () => drained++,
          presentationMayBeReordered: true,
        );
        pump.replaceQueue(const <_Item>[
          _Item('i0', 0),
          _Item('p3', 120),
          _Item('b1', 40),
          _Item('b2', 80),
          _Item('p6', 240),
          _Item('b4', 160),
          _Item('b5', 200),
        ]);

        pump.requestThrough(40);
        await pump.waitUntilIdle();
        expect(decoded, <String>['i0', 'p3', 'b1']);
        expect(presented, <String>['B1@40']);
        expect(drained, 0);

        pump.requestThrough(80);
        await pump.waitUntilIdle();
        expect(decoded, <String>['i0', 'p3', 'b1', 'b2']);
        expect(presented, <String>['B1@40', 'B2@80']);

        // P3 was decoded ahead of B1/B2 as their future reference. Advancing
        // the clock presents that retained result without decoding it twice.
        pump.requestThrough(120);
        await pump.waitUntilIdle();
        expect(decoded.where((id) => id == 'p3'), hasLength(1));
        expect(presented.last, 'P3@120');

        pump.requestThrough(160);
        await pump.waitUntilIdle();
        expect(decoded, <String>['i0', 'p3', 'b1', 'b2', 'p6', 'b4']);
        expect(presented.last, 'B4@160');

        pump.requestThrough(200);
        await pump.waitUntilIdle();
        expect(presented.last, 'B5@200');
        expect(drained, 0, reason: 'future P6 is decoded but not presented');

        pump.requestThrough(240);
        await pump.waitUntilIdle();
        expect(presented.last, 'P6@240');
        expect(drained, 1);
      },
    );

    test(
      'bounds reordered frame retention during a long catch-up drain',
      () async {
        final lastStarted = Completer<void>();
        final lastGate = Completer<String>();
        final presentedPts = <int>[];
        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) {
            if (item.ptsMs == 39) {
              lastStarted.complete();
              return lastGate.future;
            }
            return item.id;
          },
          onLatestDecoded: (item, _) => presentedPts.add(item.ptsMs),
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          presentationMayBeReordered: true,
        );
        pump.replaceQueue(<_Item>[
          for (var pts = 0; pts < 40; pts++) _Item('$pts', pts),
        ]);

        pump.requestThrough(39);
        await lastStarted.future;

        expect(pump.pendingPresentationCount, lessThanOrEqualTo(1));
        expect(presentedPts, <int>[7, 15, 23, 31]);

        lastGate.complete('39');
        await pump.waitUntilIdle();

        expect(presentedPts, <int>[7, 15, 23, 31, 39]);
        expect(pump.pendingPresentationCount, 0);
      },
    );

    test(
      'intentionally skipped items are consumed but never presented',
      () async {
        final decoded = <String>[];
        final presented = <String>[];
        final skipRequests = <String>[];
        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) {
            decoded.add(item.id);
            return item.id.toUpperCase();
          },
          shouldSkipDecode: (item, requestedThroughMs) {
            skipRequests.add('${item.id}@$requestedThroughMs');
            return item.id == 'drop';
          },
          onLatestDecoded: (item, result) =>
              presented.add('$result@${item.ptsMs}'),
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          presentationMayBeReordered: true,
          yieldBetweenDecodes: true,
        );
        pump.replaceQueue(const <_Item>[
          _Item('i0', 0),
          _Item('p2', 80),
          _Item('drop', 40),
        ]);

        pump.requestThrough(80);
        await pump.waitUntilIdle();

        expect(decoded, <String>['i0', 'p2']);
        expect(skipRequests, <String>['i0@80', 'p2@80', 'drop@80']);
        expect(presented, <String>['P2@80']);
        expect(pump.nextIndex, 3);
        expect(pump.skippedDecodeCount, 1);
      },
    );

    test('keeps a failed compressed item as the next item', () async {
      final presented = <String>[];
      final failures = <String>[];
      var drained = 0;
      final pump = SequentialDecodePump<_Item, String>(
        timestampOf: (item) => item.ptsMs,
        decode: (item) {
          if (item.id == 'bad') throw const FormatException('broken AU');
          return item.id.toUpperCase();
        },
        onLatestDecoded: (item, result) => presented.add('${item.id}:$result'),
        onDecodeError: (item, _, _) => failures.add(item.id),
        onQueueDrained: () => drained++,
      );
      pump.replaceQueue(const [_Item('ok', 0), _Item('bad', 10)]);

      pump.requestThrough(10);
      await pump.waitUntilIdle();

      expect(pump.nextIndex, 1);
      expect(presented, ['ok:OK']);
      expect(failures, ['bad']);
      expect(drained, 0);
    });

    test('drops an in-flight result after queue replacement', () async {
      final oldGate = Completer<String>();
      final newGate = Completer<String>();
      final decodeOrder = <String>[];
      final presented = <String>[];
      final pump = SequentialDecodePump<_Item, String>(
        timestampOf: (item) => item.ptsMs,
        decode: (item) {
          decodeOrder.add(item.id);
          return item.id == 'old' ? oldGate.future : newGate.future;
        },
        onLatestDecoded: (item, result) => presented.add('${item.id}:$result'),
        onDecodeError: (_, _, _) => fail('decode should not fail'),
      );

      pump.replaceQueue(const [_Item('old', 0)]);
      pump.requestThrough(0);
      await Future<void>.delayed(Duration.zero);
      pump.replaceQueue(const [_Item('new', 0)]);
      pump.requestThrough(0);

      oldGate.complete('OLD');
      await Future<void>.delayed(Duration.zero);
      expect(decodeOrder, ['old', 'new']);

      newGate.complete('NEW');
      await pump.waitUntilIdle();
      expect(presented, ['new:NEW']);
      expect(pump.nextIndex, 1);
    });

    test('waits at an open tail and resumes when items are appended', () async {
      final decoded = <String>[];
      final presented = <String>[];
      var drained = 0;
      final pump = SequentialDecodePump<_Item, String>(
        timestampOf: (item) => item.ptsMs,
        decode: (item) {
          decoded.add(item.id);
          return item.id.toUpperCase();
        },
        onLatestDecoded: (item, result) => presented.add('$result@${item.id}'),
        onDecodeError: (_, _, _) => fail('decode should not fail'),
        onQueueDrained: () => drained++,
      );

      pump.replaceQueue(const [_Item('a', 0)], isFinal: false);
      pump.requestThrough(100);
      await pump.waitUntilIdle();

      expect(decoded, ['a']);
      expect(pump.nextIndex, 1);
      expect(drained, 0);

      pump.appendItems(const [_Item('b', 10), _Item('c', 20)]);
      await pump.waitUntilIdle();

      expect(decoded, ['a', 'b', 'c']);
      expect(pump.nextIndex, 3);
      expect(drained, 0);

      pump.closeQueue();
      expect(drained, 1);
      expect(presented, ['A@a', 'C@c']);
    });

    test('rejects appends after the streaming queue is closed', () {
      final pump = SequentialDecodePump<_Item, String>(
        timestampOf: (item) => item.ptsMs,
        decode: (item) => item.id,
        onLatestDecoded: (_, _) {},
        onDecodeError: (_, _, _) => fail('decode should not fail'),
      );

      pump.replaceQueue(const <_Item>[], isFinal: false);
      pump.closeQueue();

      expect(
        () => pump.appendItems(const [_Item('late', 0)]),
        throwsStateError,
      );
    });

    test(
      'append during an awaited decode neither invalidates nor overlaps it',
      () async {
        final firstGate = Completer<String>();
        final decoded = <String>[];
        final presented = <String>[];
        var activeDecodes = 0;
        var maximumActiveDecodes = 0;
        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) async {
            activeDecodes++;
            if (activeDecodes > maximumActiveDecodes) {
              maximumActiveDecodes = activeDecodes;
            }
            decoded.add(item.id);
            final result = item.id == 'a'
                ? await firstGate.future
                : item.id.toUpperCase();
            activeDecodes--;
            return result;
          },
          onLatestDecoded: (item, result) =>
              presented.add('$result@${item.id}'),
          onDecodeError: (_, _, _) => fail('decode should not fail'),
        );

        pump.replaceQueue(const [_Item('a', 0)], isFinal: false);
        pump.requestThrough(30);
        await Future<void>.delayed(Duration.zero);
        expect(decoded, ['a']);

        pump.appendItems(const [_Item('b', 10), _Item('c', 20)]);
        firstGate.complete('A');
        await pump.waitUntilIdle();

        expect(decoded, ['a', 'b', 'c']);
        expect(presented, ['C@c']);
        expect(maximumActiveDecodes, 1);
        expect(pump.nextIndex, 3);
      },
    );

    test(
      'reports open-tail starvation, resume, and sealed EOS distinctly',
      () async {
        final states = <SequentialDecodeQueueState>[];
        var drained = 0;
        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) => item.id.toUpperCase(),
          onLatestDecoded: (_, _) {},
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          onQueueDrained: () => drained++,
          onQueueStateChanged: states.add,
        );

        pump.replaceQueue(const [_Item('a', 0)], isFinal: false);
        pump.requestThrough(10);
        await pump.waitUntilIdle();

        expect(pump.queueState, SequentialDecodeQueueState.starved);
        expect(pump.isStarved, isTrue);
        expect(drained, 0);

        pump.appendItems(const [_Item('b', 20)]);
        expect(pump.queueState, SequentialDecodeQueueState.ready);

        pump.requestThrough(20);
        await pump.waitUntilIdle();
        expect(pump.queueState, SequentialDecodeQueueState.starved);

        pump.closeQueue();
        expect(pump.queueState, SequentialDecodeQueueState.ended);
        expect(pump.isEnded, isTrue);
        expect(drained, 1);
        expect(states, [
          SequentialDecodeQueueState.starved,
          SequentialDecodeQueueState.ready,
          SequentialDecodeQueueState.starved,
          SequentialDecodeQueueState.ended,
        ]);
      },
    );

    test(
      'compaction keeps absolute indices and dependency boundary seekable',
      () async {
        final compacted = <String>[];
        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) => item.id,
          onLatestDecoded: (_, _) {},
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          maxResidentItems: 5,
          isDependencyBoundary: (item) => item.id.startsWith('K'),
          onQueueCompacted: (removed, first) =>
              compacted.add('$removed->$first'),
        );

        pump.replaceQueue(const [
          _Item('K0', 0),
          _Item('p1', 10),
          _Item('p2', 20),
          _Item('K3', 30),
          _Item('p4', 40),
        ], isFinal: false);
        pump.requestThrough(20);
        await pump.waitUntilIdle();

        // K3 is the next independent picture. The completed GOP can be
        // released while every surviving absolute index stays unchanged.
        expect(pump.firstRetainedIndex, 3);
        expect(pump.nextIndex, 3);
        expect(pump.endIndex, 5);
        expect(pump.residentLength, 2);
        expect(pump.latestDependencyBoundaryIndex, 3);
        expect(pump.itemAt(3).id, 'K3');
        expect(pump.retainedSnapshot.items.map((item) => item.id), [
          'K3',
          'p4',
        ]);
        expect(() => pump.itemAt(2), throwsRangeError);

        // Manual compaction is clamped at the dependency boundary and cannot
        // accidentally discard K3 while later P pictures depend on it.
        pump.requestThrough(40);
        await pump.waitUntilIdle();
        expect(pump.compactConsumedBefore(pump.nextIndex), 0);
        expect(pump.firstRetainedIndex, 3);

        pump.seekToIndex(3);
        expect(pump.nextIndex, 3);
        expect(() => pump.seekToIndex(2), throwsRangeError);
        expect(compacted, ['3->3']);
      },
    );

    test(
      'bounded resident policy compacts consumed items and backpressures atomically',
      () async {
        final capacity = <int>[];
        final pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) => item.id,
          onLatestDecoded: (_, _) {},
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          maxResidentItems: 4,
          retainedConsumedItems: 1,
          onAppendCapacityAvailable: capacity.add,
        );

        pump.replaceQueue(const [
          _Item('a', 0),
          _Item('b', 10),
          _Item('c', 20),
          _Item('d', 30),
        ], isFinal: false);
        expect(pump.remainingItemCapacity, 0);
        expect(pump.tryAppendItems(const [_Item('x', 40)]), isFalse);

        pump.requestThrough(20);
        await pump.waitUntilIdle();

        expect(pump.firstRetainedIndex, 2);
        expect(pump.nextIndex, 3);
        expect(pump.endIndex, 4);
        expect(pump.residentLength, 2);
        expect(pump.remainingItemCapacity, 2);
        expect(capacity, [1]);

        pump.appendItems(const [_Item('e', 40), _Item('f', 50)]);
        expect(pump.endIndex, 6);
        expect(pump.residentLength, 4);
        expect(
          () => pump.appendItems(const [_Item('g', 60)]),
          throwsA(isA<SequentialDecodeQueueCapacityException>()),
        );
        expect(pump.endIndex, 6);
        expect(pump.retainedSnapshot.items.map((item) => item.id), [
          'c',
          'd',
          'e',
          'f',
        ]);
      },
    );

    test(
      'capacity callback may synchronously refill the rolling queue',
      () async {
        late SequentialDecodePump<_Item, String> pump;
        var capacityCallbacks = 0;
        pump = SequentialDecodePump<_Item, String>(
          timestampOf: (item) => item.ptsMs,
          decode: (item) => item.id,
          onLatestDecoded: (_, _) {},
          onDecodeError: (_, _, _) => fail('decode should not fail'),
          maxResidentItems: 2,
          onAppendCapacityAvailable: (_) {
            capacityCallbacks++;
            pump.appendItems(const [_Item('c', 20)]);
          },
        );

        pump.replaceQueue(const [
          _Item('a', 0),
          _Item('b', 10),
        ], isFinal: false);
        pump.requestThrough(0);
        await pump.waitUntilIdle();

        expect(capacityCallbacks, 1);
        expect(pump.remainingItemCapacity, 0);
        expect(pump.firstRetainedIndex, 1);
        expect(pump.nextIndex, 1);
        expect(pump.endIndex, 3);
        expect(pump.retainedSnapshot.items.map((item) => item.id), ['b', 'c']);
      },
    );

    test('invalid bounded policies fail early', () {
      SequentialDecodePump<_Item, String> build({
        int? maximum,
        int retained = 0,
      }) => SequentialDecodePump<_Item, String>(
        timestampOf: (item) => item.ptsMs,
        decode: (item) => item.id,
        onLatestDecoded: (_, _) {},
        onDecodeError: (_, _, _) {},
        maxResidentItems: maximum,
        retainedConsumedItems: retained,
      );

      expect(() => build(maximum: 0), throwsArgumentError);
      expect(() => build(maximum: 3, retained: 3), throwsArgumentError);
      expect(() => build(retained: -1), throwsArgumentError);
    });
  });

  test('PlayerClock makes play and seek positions due immediately', () {
    final due = <int>[];
    final clock = PlayerClock()..onFrameDue = due.add;

    clock.play(fromMs: 123);
    expect(due, [123]);
    clock.pause();

    clock.setTime(7);
    expect(due.last, 7);
    clock.dispose();
  });

  test('PlayerClock can use an audio playback-head time source', () {
    var audioTimeMs = 400;
    final due = <int>[];
    final clock = PlayerClock()..onFrameDue = due.add;

    clock.play(fromMs: 400, timeSource: () => audioTimeMs);
    expect(clock.nowMs, 400);
    expect(due, [400]);

    audioTimeMs = 437;
    clock.pause();
    expect(clock.nowMs, 437);
    expect(due.last, 437);

    // A later video-only play must detach the previous audio clock.
    clock.play(fromMs: 12);
    expect(clock.nowMs, 12);
    clock.pause();
    clock.dispose();
  });
}
