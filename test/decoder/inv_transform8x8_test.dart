import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/inv_transform8x8.dart';

void main() {
  group('H.264 8x8 inverse scan', () {
    final scanIndexes = List<int>.generate(64, (index) => index);

    test('frame scan matches Table 8-14', () {
      expect(inverseScan8x8(scanIndexes), <int>[
        0,
        1,
        5,
        6,
        14,
        15,
        27,
        28,
        2,
        4,
        7,
        13,
        16,
        26,
        29,
        42,
        3,
        8,
        12,
        17,
        25,
        30,
        41,
        43,
        9,
        11,
        18,
        24,
        31,
        40,
        44,
        53,
        10,
        19,
        23,
        32,
        39,
        45,
        52,
        54,
        20,
        22,
        33,
        38,
        46,
        51,
        55,
        60,
        21,
        34,
        37,
        47,
        50,
        56,
        59,
        61,
        35,
        36,
        48,
        49,
        57,
        58,
        62,
        63,
      ]);
    });

    test('field scan matches Table 8-14', () {
      expect(
        inverseScan8x8(scanIndexes, scanOrder: H264ScanOrder8x8.field),
        <int>[
          0,
          3,
          8,
          15,
          22,
          30,
          38,
          52,
          1,
          4,
          14,
          21,
          29,
          37,
          45,
          53,
          2,
          7,
          16,
          23,
          31,
          39,
          46,
          58,
          5,
          9,
          20,
          28,
          36,
          44,
          51,
          59,
          6,
          13,
          24,
          32,
          40,
          47,
          54,
          60,
          10,
          17,
          25,
          33,
          41,
          48,
          55,
          61,
          11,
          18,
          26,
          34,
          42,
          49,
          56,
          62,
          12,
          19,
          27,
          35,
          43,
          50,
          57,
          63,
        ],
      );
    });

    test('requires the normative 64 input values', () {
      expect(
        () => inverseScan8x8(List<int>.filled(63, 0)),
        throwsArgumentError,
      );
      expect(
        () => inverseScan8x8(List<int>.filled(65, 0)),
        throwsArgumentError,
      );
    });
  });

  group('H.264 8x8 scaling matrices', () {
    test('Table 7-4 intra list inverse-scans to the default matrix', () {
      final parsed = H264ScalingMatrix8x8.fromScalingList(
        h264DefaultIntraScalingList8x8,
      );
      expect(
        parsed.rasterValues,
        H264ScalingMatrix8x8.defaultIntra.rasterValues,
      );
      expect(parsed.rasterValues, <int>[
        6,
        10,
        13,
        16,
        18,
        23,
        25,
        27,
        10,
        11,
        16,
        18,
        23,
        25,
        27,
        29,
        13,
        16,
        18,
        23,
        25,
        27,
        29,
        31,
        16,
        18,
        23,
        25,
        27,
        29,
        31,
        33,
        18,
        23,
        25,
        27,
        29,
        31,
        33,
        36,
        23,
        25,
        27,
        29,
        31,
        33,
        36,
        38,
        25,
        27,
        29,
        31,
        33,
        36,
        38,
        40,
        27,
        29,
        31,
        33,
        36,
        38,
        40,
        42,
      ]);
    });

    test('Table 7-4 inter list inverse-scans to the default matrix', () {
      final parsed = H264ScalingMatrix8x8.fromScalingList(
        h264DefaultInterScalingList8x8,
      );
      expect(
        parsed.rasterValues,
        H264ScalingMatrix8x8.defaultInter.rasterValues,
      );
      expect(parsed.rasterValues, <int>[
        9,
        13,
        15,
        17,
        19,
        21,
        22,
        24,
        13,
        13,
        17,
        19,
        21,
        22,
        24,
        25,
        15,
        17,
        19,
        21,
        22,
        24,
        25,
        27,
        17,
        19,
        21,
        22,
        24,
        25,
        27,
        28,
        19,
        21,
        22,
        24,
        25,
        27,
        28,
        30,
        21,
        22,
        24,
        25,
        27,
        28,
        30,
        32,
        22,
        24,
        25,
        27,
        28,
        30,
        32,
        33,
        24,
        25,
        27,
        28,
        30,
        32,
        33,
        35,
      ]);
    });

    test('parsed custom values are validated and stored immutably', () {
      final source = List<int>.generate(64, (index) => index + 1);
      final matrix = H264ScalingMatrix8x8.fromScalingList(source);
      source[0] = 255;

      expect(matrix.weightAt(0, 0), 1);
      expect(matrix.weightAt(0, 1), 2);
      expect(matrix.weightAt(1, 0), 3);
      expect(() => matrix.rasterValues[0] = 2, throwsUnsupportedError);
      expect(
        () => H264ScalingMatrix8x8.fromRaster(List<int>.filled(63, 16)),
        throwsArgumentError,
      );
      expect(
        () => H264ScalingMatrix8x8.fromRaster(<int>[
          0,
          ...List<int>.filled(63, 16),
        ]),
        throwsRangeError,
      );
      expect(
        () => H264ScalingMatrix8x8.fromRaster(<int>[
          256,
          ...List<int>.filled(63, 16),
        ]),
        throwsRangeError,
      );
    });
  });

  group('H.264 8x8 inverse quantization', () {
    test('QP below 36 follows the rounded right-shift equation', () {
      final scaled = inverseQuantize8x8(List<int>.filled(64, 1), qp: 0);
      expect(scaled, <int>[
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        6,
        6,
        8,
        6,
        6,
        6,
        8,
        6,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
        6,
        6,
        8,
        6,
        6,
        6,
        8,
        6,
        5,
        5,
        6,
        5,
        5,
        5,
        6,
        5,
      ]);

      final signs = List<int>.filled(64, 0)
        ..[0] = 1
        ..[1] = -1;
      final signed = inverseQuantize8x8(signs, qp: 0);
      expect(signed[0], 5); // (1 * 16 * 20 + 32) >> 6
      expect(signed[1], -5); // (-1 * 16 * 19 + 32) >> 6
    });

    test('QP 36 crosses to the left-shift equation without rounding', () {
      final coefficients = List<int>.filled(64, 0)
        ..[0] = 1
        ..[1] = -1
        ..[18] = 2;
      final scaled = inverseQuantize8x8(coefficients, qp: 36);

      expect(scaled[0], 320); // 1 * weight 16 * normAdjust 20
      expect(scaled[1], -304); // -1 * weight 16 * normAdjust 19
      expect(scaled[18], 1024); // 2 * weight 16 * normAdjust 32
    });

    test('custom parsed matrix participates in LevelScale8x8', () {
      final weights = List<int>.filled(64, 16)..[0] = 7;
      final matrix = H264ScalingMatrix8x8.fromRaster(weights);
      final coefficient = List<int>.filled(64, 0)..[0] = 1;

      expect(
        inverseQuantize8x8(coefficient, qp: 0, scalingMatrix: matrix)[0],
        2,
      );
      expect(
        inverseQuantize8x8(coefficient, qp: 36, scalingMatrix: matrix)[0],
        140,
      );
    });

    test('rejects non-8-bit QP values and non-64 blocks', () {
      expect(
        () => inverseQuantize8x8(List<int>.filled(64, 0), qp: -1),
        throwsRangeError,
      );
      expect(
        () => inverseQuantize8x8(List<int>.filled(64, 0), qp: 52),
        throwsRangeError,
      );
      expect(
        () => inverseQuantize8x8(List<int>.filled(63, 0), qp: 0),
        throwsArgumentError,
      );
    });
  });

  group('H.264 8x8 inverse integer transform', () {
    test('zero and DC basis vectors define normalization', () {
      expect(
        inverseIntegerTransform8x8(List<int>.filled(64, 0)),
        everyElement(0),
      );
      expect(
        inverseIntegerTransform8x8(List<int>.filled(64, 0)..[0] = 64),
        everyElement(1),
      );
      expect(
        inverseIntegerTransform8x8(List<int>.filled(64, 0)..[0] = -64),
        everyElement(-1),
      );
    });

    test('first horizontal AC basis follows equations 8-361 through 8-409', () {
      final coefficients = List<int>.filled(64, 0)..[1] = 64;
      const expectedRow = <int>[2, 1, 1, 0, 0, -1, -1, -1];
      expect(inverseIntegerTransform8x8(coefficients), <int>[
        for (var row = 0; row < 8; row++) ...expectedRow,
      ]);
    });

    test('mixed scaled-coefficient golden vector is exact', () {
      final coefficients = List<int>.filled(64, 0);
      const entries = <int, int>{
        0: 64,
        1: 32,
        2: -16,
        3: 8,
        8: -24,
        9: 12,
        17: 7,
        18: -9,
        27: 5,
        36: -3,
        45: 2,
        63: -5,
      };
      entries.forEach((index, value) => coefficients[index] = value);

      expect(inverseIntegerTransform8x8(coefficients), <int>[
        2,
        1,
        1,
        1,
        1,
        0,
        -1,
        -2,
        2,
        1,
        1,
        1,
        1,
        0,
        -1,
        -1,
        1,
        1,
        1,
        1,
        1,
        0,
        0,
        0,
        2,
        1,
        1,
        1,
        1,
        1,
        0,
        0,
        2,
        2,
        1,
        1,
        1,
        1,
        1,
        0,
        2,
        1,
        1,
        1,
        2,
        1,
        1,
        0,
        2,
        2,
        2,
        2,
        2,
        2,
        1,
        1,
        2,
        2,
        2,
        2,
        2,
        2,
        1,
        1,
      ]);
    });

    test('combined flat-list inverse quantization and transform is golden', () {
      final coefficients = List<int>.filled(64, 0);
      for (var index = 0; index < 64; index += 9) {
        final diagonal = index ~/ 9;
        coefficients[index] = diagonal.isEven ? diagonal + 1 : -(diagonal + 1);
      }

      expect(invTransform8x8(coefficients, qp: 26), <int>[
        0,
        -1,
        -2,
        -1,
        -5,
        -1,
        -22,
        44,
        -2,
        -1,
        -1,
        -1,
        -2,
        -20,
        61,
        -22,
        -2,
        -1,
        -4,
        -2,
        -22,
        64,
        -20,
        -1,
        -1,
        -1,
        -2,
        -21,
        65,
        -22,
        -2,
        -5,
        -5,
        -2,
        -22,
        65,
        -21,
        -1,
        -1,
        -1,
        -1,
        -20,
        64,
        -22,
        -1,
        -4,
        -1,
        -2,
        -22,
        61,
        -20,
        -2,
        -1,
        -1,
        -1,
        -1,
        44,
        -22,
        -1,
        -5,
        -1,
        -2,
        -2,
        0,
      ]);
    });
  });
}
