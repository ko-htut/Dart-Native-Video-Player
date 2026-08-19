import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/motion_compensation.dart';

void main() {
  group('quarter-pel luma interpolation', () {
    late Uint8List horizontalRamp;

    setUp(() {
      horizontalRamp = Uint8List.fromList(<int>[
        for (var y = 0; y < 8; y++)
          for (var x = 0; x < 8; x++) x * 10,
      ]);
    });

    int sample(int xQuarter, int yQuarter) => interpolateLumaQuarterPel(
      plane: horizontalRamp,
      width: 8,
      height: 8,
      xQuarter: xQuarter,
      yQuarter: yQuarter,
    );

    test('returns full, half, and quarter horizontal samples', () {
      expect(sample(3 * 4, 3 * 4), 30);
      expect(sample(3 * 4 + 2, 3 * 4), 35);
      expect(sample(3 * 4 + 1, 3 * 4), 33);
      expect(sample(3 * 4 + 3, 3 * 4), 38);
    });

    test('applies the vertical and diagonal six-tap filters', () {
      final twoDimensionalRamp = Uint8List.fromList(<int>[
        for (var y = 0; y < 12; y++)
          for (var x = 0; x < 12; x++) x * 8 + y * 4,
      ]);

      int sample2d(int xFraction, int yFraction) => interpolateLumaQuarterPel(
        plane: twoDimensionalRamp,
        width: 12,
        height: 12,
        xQuarter: 4 * 4 + xFraction,
        yQuarter: 4 * 4 + yFraction,
      );

      expect(sample2d(0, 0), 48);
      expect(sample2d(2, 0), 52);
      expect(sample2d(0, 2), 50);
      expect(sample2d(2, 2), 54);
      expect(sample2d(1, 1), 51); // average of horizontal 52 and vertical 50
      expect(sample2d(3, 3), 57); // lower horizontal 56, right vertical 58
    });

    test('edge extension handles negative and far-positive coordinates', () {
      final constant = Uint8List.fromList(<int>[
        77,
        77,
        77,
        77,
        77,
        77,
        77,
        77,
        77,
      ]);
      expect(
        interpolateLumaQuarterPel(
          plane: constant,
          width: 3,
          height: 3,
          xQuarter: -101,
          yQuarter: -33,
        ),
        77,
      );
      expect(
        interpolateLumaQuarterPel(
          plane: constant,
          width: 3,
          height: 3,
          xQuarter: 500,
          yQuarter: 501,
        ),
        77,
      );
    });

    test('six-tap output is clipped to 8-bit range', () {
      final overshoot = Uint8List.fromList(<int>[0, 0, 255, 255, 0, 0, 0, 0]);
      expect(
        interpolateLumaQuarterPel(
          plane: overshoot,
          width: 8,
          height: 1,
          xQuarter: 2 * 4 + 2,
          yQuarter: 0,
        ),
        255,
      );
    });
  });

  group('eighth-pel chroma interpolation', () {
    final plane = Uint8List.fromList(<int>[10, 20, 30, 50]);

    test('uses the normative four bilinear weights and rounding', () {
      expect(
        interpolateChromaEighthPel(
          plane: plane,
          width: 2,
          height: 2,
          xEighth: 2,
          yEighth: 6,
        ),
        29,
      );
      expect(
        interpolateChromaEighthPel(
          plane: plane,
          width: 2,
          height: 2,
          xEighth: 4,
          yEighth: 4,
        ),
        28,
      );
    });

    test('extends picture edges before applying weights', () {
      expect(
        interpolateChromaEighthPel(
          plane: plane,
          width: 2,
          height: 2,
          xEighth: -5,
          yEighth: -3,
        ),
        10,
      );
      expect(
        interpolateChromaEighthPel(
          plane: plane,
          width: 2,
          height: 2,
          xEighth: 99,
          yEighth: 99,
        ),
        50,
      );
    });
  });

  group('motion-vector prediction', () {
    late MotionFieldGrid grid;

    setUp(() {
      grid = MotionFieldGrid(widthIn4x4: 12, heightIn4x4: 12);
    });

    void setBlock(
      int blockX,
      int blockY,
      MotionVector vector, {
      int referenceIndex = 0,
      int sliceId = 7,
    }) {
      grid.setPartition(
        x: blockX * 4,
        y: blockY * 4,
        width: 4,
        height: 4,
        vector: vector,
        referenceIndex: referenceIndex,
        sliceId: sliceId,
      );
    }

    test('uses component-wise median for P_16x16', () {
      setBlock(3, 4, const MotionVector(4, 8)); // A
      setBlock(4, 3, const MotionVector(12, 0)); // B
      setBlock(8, 3, const MotionVector(8, 4)); // C

      final prediction = deriveMotionVectorPredictor(
        grid: grid,
        partitionX: 16,
        partitionY: 16,
        partitionWidth: 16,
        partitionHeight: 16,
        referenceIndex: 0,
        partitionKind: InterPartitionKind.p16x16,
        currentSliceId: 7,
      );
      expect(prediction, const MotionVector(8, 4));
    });

    test('selects the sole neighbour with the requested reference', () {
      setBlock(3, 4, const MotionVector(40, -8), referenceIndex: 1);
      setBlock(4, 3, const MotionVector(100, 100), referenceIndex: 0);
      setBlock(8, 3, const MotionVector(-12, 20), referenceIndex: 2);

      expect(
        deriveMotionVectorPredictor(
          grid: grid,
          partitionX: 16,
          partitionY: 16,
          partitionWidth: 16,
          partitionHeight: 16,
          referenceIndex: 1,
          partitionKind: InterPartitionKind.p16x16,
          currentSliceId: 7,
        ),
        const MotionVector(40, -8),
      );
    });

    test('replicates A when B and C are both unavailable', () {
      setBlock(3, 4, const MotionVector(28, -12), referenceIndex: 1);

      expect(
        deriveMotionVectorPredictor(
          grid: grid,
          partitionX: 16,
          partitionY: 16,
          partitionWidth: 16,
          partitionHeight: 16,
          referenceIndex: 0,
          partitionKind: InterPartitionKind.p16x16,
          currentSliceId: 7,
        ),
        const MotionVector(28, -12),
      );
    });

    test('substitutes top-left D only when C is unavailable', () {
      setBlock(3, 4, const MotionVector(0, 0)); // A
      setBlock(4, 3, const MotionVector(4, 4)); // B
      setBlock(3, 3, const MotionVector(12, 12)); // D; C is unset

      expect(
        deriveMotionVectorPredictor(
          grid: grid,
          partitionX: 16,
          partitionY: 16,
          partitionWidth: 16,
          partitionHeight: 16,
          referenceIndex: 0,
          partitionKind: InterPartitionKind.p16x16,
          currentSliceId: 7,
        ),
        const MotionVector(4, 4),
      );

      grid.setIntraPartition(x: 32, y: 12, width: 4, height: 4, sliceId: 7);
      expect(
        deriveMotionVectorPredictor(
          grid: grid,
          partitionX: 16,
          partitionY: 16,
          partitionWidth: 16,
          partitionHeight: 16,
          referenceIndex: 0,
          partitionKind: InterPartitionKind.p16x16,
          currentSliceId: 7,
        ),
        MotionVector.zero,
      );
    });

    test('applies P_16x8 and P_8x16 preferred-neighbour rules', () {
      setBlock(3, 4, const MotionVector(1, 1)); // A
      setBlock(4, 3, const MotionVector(20, 2)); // B
      setBlock(8, 3, const MotionVector(30, 3)); // C for width 16
      setBlock(6, 3, const MotionVector(40, 4)); // C for width 8

      expect(
        deriveMotionVectorPredictor(
          grid: grid,
          partitionX: 16,
          partitionY: 16,
          partitionWidth: 16,
          partitionHeight: 8,
          referenceIndex: 0,
          partitionKind: InterPartitionKind.p16x8,
          partitionIndex: 0,
          currentSliceId: 7,
        ),
        const MotionVector(20, 2),
      );
      expect(
        deriveMotionVectorPredictor(
          grid: grid,
          partitionX: 16,
          partitionY: 16,
          partitionWidth: 8,
          partitionHeight: 16,
          referenceIndex: 0,
          partitionKind: InterPartitionKind.p8x16,
          partitionIndex: 1,
          currentSliceId: 7,
        ),
        const MotionVector(40, 4),
      );
    });

    test('P_Skip returns zero for unavailable/zero A or B', () {
      setBlock(4, 3, const MotionVector(8, 8)); // B; A unavailable
      expect(
        derivePSkipMotionVector(
          grid: grid,
          macroblockX: 16,
          macroblockY: 16,
          currentSliceId: 7,
        ),
        MotionVector.zero,
      );

      setBlock(3, 4, MotionVector.zero); // A explicitly zero/refIdx 0
      expect(
        derivePSkipMotionVector(
          grid: grid,
          macroblockX: 16,
          macroblockY: 16,
          currentSliceId: 7,
        ),
        MotionVector.zero,
      );
    });

    test('cross-slice motion entries are unavailable', () {
      setBlock(3, 4, const MotionVector(9, 9), sliceId: 6);
      expect(grid.entryAt4x4(3, 4, currentSliceId: 7).available, isFalse);
      expect(grid.entryAt4x4(3, 4).vector, const MotionVector(9, 9));
    });
  });

  group('partition writers', () {
    test('writes luma and both chroma planes with one motion vector', () {
      const width = 8;
      const height = 8;
      final reference = Yuv420PictureBuffer(
        width: width,
        height: height,
        y: Uint8List.fromList(<int>[
          for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++) x + y * 10,
        ]),
        u: Uint8List.fromList(<int>[
          for (var y = 0; y < 4; y++)
            for (var x = 0; x < 4; x++) 100 + x + y * 10,
        ]),
        v: Uint8List.fromList(<int>[
          for (var y = 0; y < 4; y++)
            for (var x = 0; x < 4; x++) 150 + x + y * 10,
        ]),
      );
      final destination = Yuv420PictureBuffer(
        width: width,
        height: height,
        y: Uint8List(width * height),
        u: Uint8List(width * height ~/ 4),
        v: Uint8List(width * height ~/ 4),
      );

      // Four quarter-luma units move one luma sample and half a chroma sample.
      writeInterPrediction420(
        reference: reference,
        destination: destination,
        x: 0,
        y: 0,
        width: 4,
        height: 4,
        motionVector: const MotionVector(4, 0),
      );

      expect(destination.y.sublist(0, 4), <int>[1, 2, 3, 4]);
      expect(destination.y.sublist(8, 12), <int>[11, 12, 13, 14]);
      expect(destination.u[0], 101); // average of 100 and 101, rounded up
      expect(destination.u[1], 102); // average of 101 and 102, rounded up
      expect(destination.v[0], 151);
      expect(destination.v[1], 152);
    });

    test('writer clips reference lookup at the picture border', () {
      final reference = Uint8List.fromList(<int>[10, 20, 30, 40]);
      final destination = Uint8List(4);
      writeLumaInterPrediction(
        reference: reference,
        referenceWidth: 2,
        referenceHeight: 2,
        destination: destination,
        destinationWidth: 2,
        destinationHeight: 2,
        destinationX: 0,
        destinationY: 0,
        partitionWidth: 2,
        partitionHeight: 2,
        motionVector: const MotionVector(-400, -400),
      );
      expect(destination, <int>[10, 10, 10, 10]);
    });
  });
}
