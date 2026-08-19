import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/chroma_pred.dart';
import 'package:ndvy_player/src/decoder/intra16_dc.dart';
import 'package:ndvy_player/src/decoder/inv_transform.dart';

void main() {
  group('H.264 inverse 4x4 transform', () {
    test('zero coefficients produce a zero residual', () {
      expect(invTransform4x4(List<int>.filled(16, 0), qp: 0), everyElement(0));
    });

    test('flat-list dequantisation preserves the normative QP amplitude', () {
      final dcAtQp0 = <int>[64, ...List<int>.filled(15, 0)];
      expect(invTransform4x4(dcAtQp0, qp: 0), everyElement(10));

      final dcAtQp26 = <int>[1, ...List<int>.filled(15, 0)];
      expect(invTransform4x4(dcAtQp26, qp: 26), everyElement(3));
    });

    test('mixed AC/DC vector matches the integer transform', () {
      const coefficients = <int>[
        1,
        2,
        -3,
        4,
        -2,
        1,
        0,
        -1,
        3,
        0,
        2,
        1,
        -1,
        2,
        1,
        0,
      ];
      expect(invTransform4x4(coefficients, qp: 0), <int>[
        1,
        0,
        0,
        -1,
        -1,
        0,
        1,
        -2,
        0,
        0,
        1,
        -2,
        1,
        0,
        3,
        0,
      ]);
      expect(invTransform4x4(coefficients, qp: 26), <int>[
        27,
        -2,
        10,
        -24,
        -21,
        5,
        23,
        -32,
        4,
        -1,
        13,
        -41,
        28,
        2,
        54,
        7,
      ]);
    });

    test('already-scaled DC bypasses ordinary coefficient dequantisation', () {
      final positive = <int>[64, ...List<int>.filled(15, 0)];
      final negative = <int>[-64, ...List<int>.filled(15, 0)];
      expect(
        invTransform4x4(positive, qp: 51, dcAlreadyScaled: true),
        everyElement(1),
      );
      expect(
        invTransform4x4(negative, qp: 51, dcAlreadyScaled: true),
        everyElement(-1),
      );
    });
  });

  group('Intra16x16 luma DC transform and scaling', () {
    const coefficients = <int>[
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
    ];
    const transformed = <int>[
      136,
      -16,
      0,
      -8,
      -64,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      -32,
      0,
      0,
      0,
    ];

    test('Hadamard kernel and its normalisation are exact', () {
      expect(hadamard4x4Inverse(coefficients), transformed);
      expect(hadamard4x4Forward(transformed), <int>[
        16,
        32,
        48,
        64,
        80,
        96,
        112,
        128,
        144,
        160,
        176,
        192,
        208,
        224,
        240,
        256,
      ]);
    });

    test('DC scaling matches both right-shift and left-shift QP paths', () {
      expect(scaleIntra16LumaDc(transformed, qp: 0), <int>[
        340,
        -40,
        0,
        -20,
        -160,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        -80,
        0,
        0,
        0,
      ]);
      expect(scaleIntra16LumaDc(transformed, qp: 36), <int>[
        21760,
        -2560,
        0,
        -1280,
        -10240,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        -5120,
        0,
        0,
        0,
      ]);
    });

    test('block helper replaces DC and preserves every AC coefficient', () {
      final blocks = List<List<int>>.generate(
        16,
        (index) => <int>[index + 1, ...List<int>.filled(15, 99)],
      );
      applyIntra16LumaDcHadamard(blocks, qp: 0);

      expect(
        <int>[for (final block in blocks) block[0]],
        <int>[340, -40, 0, -20, -160, 0, 0, 0, 0, 0, 0, 0, -80, 0, 0, 0],
      );
      for (final block in blocks) {
        expect(block.sublist(1), everyElement(99));
      }
    });
  });

  group('4:2:0 chroma DC transform and scaling', () {
    test('inverse 2x2 transform includes QP-dependent DC scaling', () {
      expect(inverseChromaDc2x2(<int>[1, 2, 3, 4], qp: 0), <int>[
        50,
        -10,
        -20,
        0,
      ]);
      expect(inverseChromaDc2x2(<int>[1, 2, 3, 4], qp: 26), <int>[
        1040,
        -208,
        -416,
        0,
      ]);
    });

    test('merge changes only the four block DC slots', () {
      final blocks = List<List<int>>.generate(
        4,
        (_) => <int>[0, ...List<int>.filled(15, 7)],
      );
      mergeChromaDcIntoCoeffBlocks(blocks, <int>[50, -10, -20, 0]);
      expect(
        <int>[for (final block in blocks) block[0]],
        <int>[50, -10, -20, 0],
      );
      for (final block in blocks) {
        expect(block.sublist(1), everyElement(7));
      }
    });
  });
}
