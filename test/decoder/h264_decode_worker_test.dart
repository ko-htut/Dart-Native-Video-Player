import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_decode_worker.dart';

void main() {
  test(
    'persistent worker decodes, resets, fails, and remains reusable',
    () async {
      final worker = H264DecodeWorker();
      addTearDown(worker.dispose);

      final first = await worker.decodeAccessUnitOrThrow(_sfuxFirstIdr());
      expect(first.frame.width, 1236);
      expect(first.frame.height, 720);
      expect(first.frame.y, everyElement(16));
      expect(first.frame.u, everyElement(127));
      expect(first.frame.v, everyElement(127));
      expect(first.stats.frameNumber, 0);
      expect(first.stats.macroblockCount, 3510);
      expect(first.stats.intraMacroblocks, 3510);
      expect(first.stats.isReference, isTrue);

      await worker.resetAndWait();
      await expectLater(
        worker.decodeAccessUnitOrThrow(<Uint8List>[_sfuxFirstIdr().last]),
        throwsA(
          isA<H264DecodeWorkerException>().having(
            (error) => error.message,
            'message',
            contains('PPS'),
          ),
        ),
      );

      final retry = await worker.decodeAccessUnitOrThrow(_sfuxFirstIdr());
      expect(retry.frame.y, everyElement(16));
      expect(retry.stats.frameNumber, 0);
    },
  );

  test('dispose rejects future work', () async {
    final worker = H264DecodeWorker();
    worker.dispose();
    await expectLater(
      worker.decodeAccessUnitOrThrow(_sfuxFirstIdr()),
      throwsStateError,
    );
  });

  test('dispose safely cancels a worker that is still starting', () async {
    final worker = H264DecodeWorker();
    final pending = worker.decodeAccessUnitOrThrow(_sfuxFirstIdr());

    worker.dispose();

    await expectLater(pending, throwsStateError);
  });

  test(
    'reset stays ordered between an in-flight decode and its retry',
    () async {
      final worker = H264DecodeWorker();
      addTearDown(worker.dispose);

      final beforeReset = worker.decodeAccessUnitOrThrow(_sfuxFirstIdr());
      worker.reset();
      final afterReset = worker.decodeAccessUnitOrThrow(_sfuxFirstIdr());

      expect((await beforeReset).stats.frameNumber, 0);
      expect((await afterReset).stats.frameNumber, 0);
    },
  );

  test('decoding leaves the caller event queue responsive', () async {
    final worker = H264DecodeWorker();
    addTearDown(worker.dispose);
    var timerTicks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => timerTicks++,
    );

    await worker.decodeAccessUnitOrThrow(_sfuxFirstIdr());
    timer.cancel();

    expect(timerTicks, greaterThan(0));
  });
}

List<Uint8List> _sfuxFirstIdr() => <Uint8List>[
  _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
  _hex('68e9b9cb22c0'),
  _hex(
    '6588840037fffedb5bf32cadd193c46d4b1c85777972cd4ee8ca19da792f'
    '53300000030000030000030000030086bdc12f77f1155715200000030000'
    '1fc0002a60005f40013300055c001920009d0003e8002380010d000b6000'
    '688004400000030000030000030000030000030000030000030000030000'
    '030000030000030000030000030000030000030000030000030000030000'
    '030000030000030000030000030000030000030000030000030000030000'
    '03000003000003000003000003000003000003000003000003001011',
  ),
];

Uint8List _hex(String value) => Uint8List.fromList(<int>[
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);
