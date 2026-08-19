import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/main.dart';

Uint8List makeTestRgba(int w, int h) {
  final out = Uint8List(w * h * 4);
  int o = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out[o++] = (x * 255 ~/ w); // R gradient
      out[o++] = (y * 255 ~/ h); // G gradient
      out[o++] = 0;
      out[o++] = 255;
    }
  }
  return out;
}

void main() {
  test('makeTestRgba creates an opaque two-axis gradient', () {
    final rgba = makeTestRgba(2, 2);

    expect(rgba, hasLength(16));
    expect(rgba.sublist(0, 4), <int>[0, 0, 0, 255]);
    expect(rgba.sublist(12, 16), <int>[127, 127, 0, 255]);
  });

  testWidgets('queue build buttons follow the entered media type', (
    tester,
  ) async {
    await tester.pumpWidget(const App());

    FilledButton hlsButton() =>
        tester.widget(find.byKey(const Key('build-hls')));
    FilledButton mp4Button() =>
        tester.widget(find.byKey(const Key('build-mp4')));

    await tester.enterText(find.byType(TextField), 'assets/butterfly_dart.mp4');
    await tester.pump();

    expect(hlsButton().onPressed, isNull);
    expect(mp4Button().onPressed, isNotNull);

    await tester.enterText(
      find.byType(TextField),
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );
    await tester.pump();

    expect(hlsButton().onPressed, isNotNull);
    expect(mp4Button().onPressed, isNull);
  });
}
