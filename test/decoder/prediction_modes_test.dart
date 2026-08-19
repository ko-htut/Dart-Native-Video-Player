import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/chroma_pred.dart';
import 'package:ndvy_player/src/decoder/intra_pred.dart';

void main() {
  group('H.264 Intra4x4 prediction', () {
    const top = <int>[10, 20, 30, 40, 50, 60, 70, 80];
    const left = <int>[90, 100, 110, 120];
    const expectedByMode = <List<int>>[
      <int>[10, 20, 30, 40, 10, 20, 30, 40, 10, 20, 30, 40, 10, 20, 30, 40],
      <int>[
        90,
        90,
        90,
        90,
        100,
        100,
        100,
        100,
        110,
        110,
        110,
        110,
        120,
        120,
        120,
        120,
      ],
      <int>[65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65],
      <int>[20, 30, 40, 50, 30, 40, 50, 60, 40, 50, 60, 70, 50, 60, 70, 78],
      <int>[50, 23, 20, 30, 83, 50, 23, 20, 100, 83, 50, 23, 110, 100, 83, 50],
      <int>[30, 15, 25, 35, 50, 23, 20, 30, 83, 30, 15, 25, 100, 50, 23, 20],
      <int>[
        70,
        50,
        23,
        20,
        95,
        83,
        70,
        50,
        105,
        100,
        95,
        83,
        115,
        110,
        105,
        100,
      ],
      <int>[15, 25, 35, 45, 20, 30, 40, 50, 25, 35, 45, 55, 30, 40, 50, 60],
      <int>[
        95,
        100,
        105,
        110,
        105,
        110,
        115,
        118,
        115,
        118,
        120,
        120,
        120,
        120,
        120,
        120,
      ],
    ];

    for (var mode = 0; mode < expectedByMode.length; mode++) {
      test('mode $mode matches the normative prediction matrix', () {
        final output = List<int>.filled(16, 0);
        predictIntra4x4(
          mode: mode,
          top: top,
          left: left,
          topLeft: 50,
          out: output,
        );
        expect(output, expectedByMode[mode]);
      });
    }

    test('DC uses only available neighbours', () {
      final output = List<int>.filled(16, 0);

      predictIntra4x4(
        mode: 2,
        top: top,
        left: left,
        topLeft: 50,
        out: output,
        leftAvailable: false,
      );
      expect(output, everyElement(25));

      predictIntra4x4(
        mode: 2,
        top: top,
        left: left,
        topLeft: 50,
        out: output,
        topAvailable: false,
      );
      expect(output, everyElement(105));

      predictIntra4x4(
        mode: 2,
        top: top,
        left: left,
        topLeft: 50,
        out: output,
        topAvailable: false,
        leftAvailable: false,
      );
      expect(output, everyElement(128));
    });

    test('unavailable top-right samples repeat the last top sample', () {
      final output = List<int>.filled(16, 0);
      predictIntra4x4(
        mode: 3,
        top: top,
        left: left,
        topLeft: 50,
        out: output,
        topRightAvailable: false,
      );
      expect(output, <int>[
        20,
        30,
        38,
        40,
        30,
        38,
        40,
        40,
        38,
        40,
        40,
        40,
        40,
        40,
        40,
        40,
      ]);
    });
  });

  group('H.264 Intra16x16 prediction', () {
    late List<int> plane;

    setUp(() {
      plane = List<int>.filled(32 * 32, 0);
      plane[15 * 32 + 15] = 5;
      for (var i = 0; i < 16; i++) {
        plane[15 * 32 + 16 + i] = 10 + i;
        plane[(16 + i) * 32 + 15] = 30 + 2 * i;
      }
    });

    List<int> predict(int mode, {bool? top, bool? left, bool? topLeft}) {
      final output = List<int>.filled(256, 0);
      predictIntra16(
        mode: mode,
        mbX: 1,
        mbY: 1,
        width: 32,
        height: 32,
        yPlane: plane,
        out16: output,
        topAvailable: top,
        leftAvailable: left,
        topLeftAvailable: topLeft,
      );
      return output;
    }

    test('vertical and horizontal modes copy their reference samples', () {
      final vertical = predict(0);
      expect(vertical.sublist(0, 16), <int>[
        for (var i = 0; i < 16; i++) 10 + i,
      ]);
      expect(vertical.sublist(15 * 16, 16 * 16), vertical.sublist(0, 16));

      final horizontal = predict(1);
      expect(horizontal.sublist(0, 16), everyElement(30));
      expect(horizontal.sublist(15 * 16, 16 * 16), everyElement(60));
    });

    test('DC honours all four availability cases', () {
      expect(predict(2), everyElement(31));
      expect(predict(2, left: false), everyElement(18));
      expect(predict(2, top: false), everyElement(45));
      expect(predict(2, top: false, left: false), everyElement(128));
    });

    test('plane mode applies horizontal and vertical gradients', () {
      final output = predict(3);
      expect(output[0], 18);
      expect(output[15], 34);
      expect(output[7 * 16 + 7], 43);
      expect(output[15 * 16], 55);
      expect(output[15 * 16 + 15], 71);
    });
  });

  group('H.264 4:2:0 chroma prediction', () {
    late Uint8List plane;

    setUp(() {
      plane = Uint8List(16 * 16);
      plane[7 * 16 + 7] = 50;
      const top = <int>[10, 20, 30, 40, 50, 60, 70, 80];
      const left = <int>[90, 100, 110, 120, 130, 140, 150, 160];
      for (var i = 0; i < 8; i++) {
        plane[7 * 16 + 8 + i] = top[i];
        plane[(8 + i) * 16 + 7] = left[i];
      }
    });

    List<int> predict(int mode, {bool? top, bool? left, bool? topLeft}) =>
        predictIntraChroma8x8(
          mode: mode,
          plane: plane,
          width: 32,
          height: 32,
          mbX: 1,
          mbY: 1,
          topAvailable: top,
          leftAvailable: left,
          topLeftAvailable: topLeft,
        );

    test('DC predicts each 4x4 quadrant independently', () {
      final output = predict(0);
      expect(output[0], 65);
      expect(output[4], 65);
      expect(output[4 * 8], 145);
      expect(output[4 * 8 + 4], 105);
    });

    test('DC honours unavailable neighbours', () {
      final topOnly = predict(0, left: false);
      expect(topOnly[0], 25);
      expect(topOnly[4], 65);
      expect(topOnly[4 * 8], 25);
      expect(topOnly[4 * 8 + 4], 65);

      final leftOnly = predict(0, top: false);
      expect(leftOnly[0], 105);
      expect(leftOnly[4], 105);
      expect(leftOnly[4 * 8], 145);
      expect(leftOnly[4 * 8 + 4], 145);

      expect(predict(0, top: false, left: false), everyElement(128));
    });

    test('horizontal and vertical copy their reference samples', () {
      final horizontal = predict(1);
      expect(horizontal.sublist(0, 8), everyElement(90));
      expect(horizontal.sublist(7 * 8, 8 * 8), everyElement(160));

      final vertical = predict(2);
      expect(vertical.sublist(0, 8), <int>[10, 20, 30, 40, 50, 60, 70, 80]);
      expect(vertical.sublist(7 * 8, 8 * 8), vertical.sublist(0, 8));
    });

    test('plane mode applies both chroma gradients', () {
      final output = predict(3);
      expect(output[0], 64);
      expect(output[7], 111);
      expect(output[7 * 8], 148);
      expect(output[7 * 8 + 7], 195);
    });
  });
}
