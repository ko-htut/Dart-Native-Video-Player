import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/pure_frame_view.dart';

void main() {
  testWidgets('rapid updates stay inside one local repaint boundary', (
    tester,
  ) async {
    Widget frame(Uint8List rgba) => MaterialApp(
      home: SizedBox(
        width: 2,
        height: 1,
        child: PureFrameView(rgba: rgba, width: 2, height: 1),
      ),
    );

    await tester.pumpWidget(frame(_solidFrame(10)));
    await tester.pumpWidget(frame(_solidFrame(20)));
    await tester.pumpWidget(frame(_solidFrame(30)));
    expect(
      find.descendant(
        of: find.byType(PureFrameView),
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );

    // Disposal while the engine callback is still pending must leave no
    // mounted state for that stale result to update.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

Uint8List _solidFrame(int value) => Uint8List.fromList(<int>[
  value,
  value,
  value,
  255,
  value,
  value,
  value,
  255,
]);
