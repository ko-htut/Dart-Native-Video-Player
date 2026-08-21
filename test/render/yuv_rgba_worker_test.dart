import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/render/yuv_rgba_worker.dart';
import 'package:ndvy_player/src/yuv.dart';

void main() {
  test('latest-wins mailbox converts only the newest queued frame', () async {
    final worker = YuvRgbaRenderWorker();
    addTearDown(worker.dispose);
    final delivered = <int>[];

    worker.submit(
      _solidFrame(640, 360, y: 32),
      onFrame: (_) => delivered.add(32),
    );
    worker.submit(
      _solidFrame(640, 360, y: 64),
      onFrame: (_) => delivered.add(64),
    );
    worker.submit(
      _solidFrame(640, 360, y: 128),
      onFrame: (rgba) {
        delivered.add(128);
        expect(rgba, hasLength(640 * 360 * 4));
        expect(rgba[3], 255);
      },
    );

    await worker.waitUntilIdle();

    expect(delivered, <int>[128]);
    expect(worker.coalescedFrameCount, 2);
  });

  test('reset invalidates a returning conversion', () async {
    final worker = YuvRgbaRenderWorker();
    addTearDown(worker.dispose);
    var delivered = false;

    worker.submit(
      _solidFrame(1280, 720, y: 90),
      onFrame: (_) => delivered = true,
    );
    worker.reset();
    await worker.waitUntilIdle();

    expect(delivered, isFalse);
    expect(worker.coalescedFrameCount, 0);
  });

  test('conversion can downscale directly to rendition display size', () async {
    final worker = YuvRgbaRenderWorker();
    addTearDown(worker.dispose);
    final delivered = Completer<Uint8List>();

    worker.submit(
      _solidFrame(1236, 720, y: 90),
      outputWidth: 426,
      outputHeight: 240,
      onFrame: delivered.complete,
    );
    final rgba = await delivered.future;

    expect(rgba, hasLength(426 * 240 * 4));
    expect(rgba[3], 255);
  });

  test('conversion leaves caller event queue responsive', () async {
    final worker = YuvRgbaRenderWorker();
    addTearDown(worker.dispose);
    final delivered = Completer<void>();
    var timerTicks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => timerTicks++,
    );

    worker.submit(
      _solidFrame(1236, 720, y: 90),
      onFrame: (_) => delivered.complete(),
    );
    await delivered.future;
    timer.cancel();

    expect(timerTicks, greaterThan(0));
  });
}

Yuv420Frame _solidFrame(int width, int height, {required int y}) {
  final chromaLength = (width ~/ 2) * (height ~/ 2);
  return Yuv420Frame(
    width: width,
    height: height,
    y: Uint8List(width * height)..fillRange(0, width * height, y),
    u: Uint8List(chromaLength)..fillRange(0, chromaLength, 128),
    v: Uint8List(chromaLength)..fillRange(0, chromaLength, 128),
  );
}
