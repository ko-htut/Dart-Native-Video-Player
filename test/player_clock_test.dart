import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/player_clock.dart';

class _Item {
  const _Item(this.id, this.ptsMs);

  final String id;
  final int ptsMs;
}

void main() {
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
