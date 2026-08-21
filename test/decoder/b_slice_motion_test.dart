import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/b_slice_motion.dart';
import 'package:ndvy_player/src/decoder/motion_compensation.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';
import 'package:ndvy_player/src/decoder/weighted_prediction.dart';

void main() {
  group('B macroblock type mapping', () {
    test('covers the complete Table 7-14 inter subset', () {
      const names = <String>[
        'B_Direct_16x16',
        'B_L0_16x16',
        'B_L1_16x16',
        'B_Bi_16x16',
        'B_L0_L0_16x8',
        'B_L0_L0_8x16',
        'B_L1_L1_16x8',
        'B_L1_L1_8x16',
        'B_L0_L1_16x8',
        'B_L0_L1_8x16',
        'B_L1_L0_16x8',
        'B_L1_L0_8x16',
        'B_L0_Bi_16x8',
        'B_L0_Bi_8x16',
        'B_L1_Bi_16x8',
        'B_L1_Bi_8x16',
        'B_Bi_L0_16x8',
        'B_Bi_L0_8x16',
        'B_Bi_L1_16x8',
        'B_Bi_L1_8x16',
        'B_Bi_Bi_16x8',
        'B_Bi_Bi_8x16',
        'B_8x8',
      ];
      const d = H264BPredictionMode.direct;
      const l0 = H264BPredictionMode.list0;
      const l1 = H264BPredictionMode.list1;
      const bi = H264BPredictionMode.bi;
      const expectedModes = <List<H264BPredictionMode?>>[
        <H264BPredictionMode?>[d, d, d, d],
        <H264BPredictionMode?>[l0],
        <H264BPredictionMode?>[l1],
        <H264BPredictionMode?>[bi],
        <H264BPredictionMode?>[l0, l0],
        <H264BPredictionMode?>[l0, l0],
        <H264BPredictionMode?>[l1, l1],
        <H264BPredictionMode?>[l1, l1],
        <H264BPredictionMode?>[l0, l1],
        <H264BPredictionMode?>[l0, l1],
        <H264BPredictionMode?>[l1, l0],
        <H264BPredictionMode?>[l1, l0],
        <H264BPredictionMode?>[l0, bi],
        <H264BPredictionMode?>[l0, bi],
        <H264BPredictionMode?>[l1, bi],
        <H264BPredictionMode?>[l1, bi],
        <H264BPredictionMode?>[bi, l0],
        <H264BPredictionMode?>[bi, l0],
        <H264BPredictionMode?>[bi, l1],
        <H264BPredictionMode?>[bi, l1],
        <H264BPredictionMode?>[bi, bi],
        <H264BPredictionMode?>[bi, bi],
        <H264BPredictionMode?>[null, null, null, null],
      ];

      for (var code = 0; code <= 22; code++) {
        final type = H264BInterMacroblockType.fromCode(code);
        final partitions = type.partitionsAt(macroblockX: 16, macroblockY: 32);
        expect(type.codeNum, code, reason: 'mb_type $code');
        expect(type.name, names[code], reason: 'mb_type $code');
        expect(
          partitions.map((partition) => partition.predictionMode),
          expectedModes[code],
          reason: 'mb_type $code',
        );

        if (code == 0 || code == 22) {
          expect(
            partitions.map((partition) => (partition.width, partition.height)),
            everyElement((8, 8)),
            reason: 'mb_type $code',
          );
        } else if (code <= 3) {
          expect(
            partitions.map((partition) => (partition.width, partition.height)),
            <(int, int)>[(16, 16)],
            reason: 'mb_type $code',
          );
        } else {
          final expectedSize = code.isEven ? (16, 8) : (8, 16);
          expect(
            partitions.map((partition) => (partition.width, partition.height)),
            everyElement(expectedSize),
            reason: 'mb_type $code',
          );
        }
      }

      expect(() => H264BInterMacroblockType.fromCode(23), throwsRangeError);
    });

    test('maps inferred B_Skip to Direct inference', () {
      final skipped = H264BInterMacroblockType.skipped();

      expect(skipped.codeNum, isNull);
      expect(skipped.name, 'B_Skip');
      expect(skipped.skipped, isTrue);
      expect(skipped.isDirect, isTrue);
      expect(
        skipped
            .partitionsAt(macroblockX: 0, macroblockY: 0)
            .map((partition) => partition.predictionMode),
        everyElement(H264BPredictionMode.direct),
      );
    });
  });

  group('B sub-macroblock type mapping', () {
    test('covers every Table 7-18 mode and geometry', () {
      const expected = <(H264BPredictionMode, int, int, int)>[
        (H264BPredictionMode.direct, 4, 4, 4),
        (H264BPredictionMode.list0, 1, 8, 8),
        (H264BPredictionMode.list1, 1, 8, 8),
        (H264BPredictionMode.bi, 1, 8, 8),
        (H264BPredictionMode.list0, 2, 8, 4),
        (H264BPredictionMode.list0, 2, 4, 8),
        (H264BPredictionMode.list1, 2, 8, 4),
        (H264BPredictionMode.list1, 2, 4, 8),
        (H264BPredictionMode.bi, 2, 8, 4),
        (H264BPredictionMode.bi, 2, 4, 8),
        (H264BPredictionMode.list0, 4, 4, 4),
        (H264BPredictionMode.list1, 4, 4, 4),
        (H264BPredictionMode.bi, 4, 4, 4),
      ];

      for (var code = 0; code <= 12; code++) {
        final type = H264BSubMacroblockType.fromCode(code);
        expect(
          (
            type.predictionMode,
            type.partitionCount,
            type.partitionWidth,
            type.partitionHeight,
          ),
          expected[code],
          reason: 'sub_mb_type $code (${type.name})',
        );
      }

      expect(() => H264BSubMacroblockType.fromCode(13), throwsRangeError);
    });

    test('lays out 8x4, 4x8, and 4x4 subpartitions without overlap', () {
      final horizontal = H264BSubMacroblockType.fromCode(4).partitionsAt(
        macroblockX: 16,
        macroblockY: 16,
        macroblockPartitionIndex: 3,
      );
      final vertical = H264BSubMacroblockType.fromCode(5).partitionsAt(
        macroblockX: 16,
        macroblockY: 16,
        macroblockPartitionIndex: 3,
      );
      final blocks = H264BSubMacroblockType.fromCode(12).partitionsAt(
        macroblockX: 16,
        macroblockY: 16,
        macroblockPartitionIndex: 3,
      );

      expect(horizontal.map((part) => (part.x, part.y)), <(int, int)>[
        (24, 24),
        (24, 28),
      ]);
      expect(vertical.map((part) => (part.x, part.y)), <(int, int)>[
        (24, 24),
        (28, 24),
      ]);
      expect(blocks.map((part) => (part.x, part.y)), <(int, int)>[
        (24, 24),
        (28, 24),
        (24, 28),
        (28, 28),
      ]);
    });
  });

  group('Direct inference geometry', () {
    test('SPS flag chooses 8x8 or 4x4 inference regions', () {
      final type = H264BInterMacroblockType.fromCode(0);

      final inferred8x8 = type.directInferenceRegionsAt(
        macroblockX: 16,
        macroblockY: 32,
        direct8x8Inference: true,
      );
      final inferred4x4 = type.directInferenceRegionsAt(
        macroblockX: 16,
        macroblockY: 32,
        direct8x8Inference: false,
      );

      expect(inferred8x8, hasLength(4));
      expect(
        inferred8x8.map((part) => (part.x, part.y, part.width, part.height)),
        <(int, int, int, int)>[
          (16, 32, 8, 8),
          (24, 32, 8, 8),
          (16, 40, 8, 8),
          (24, 40, 8, 8),
        ],
      );
      expect(inferred4x4, hasLength(16));
      expect(
        inferred4x4.map((part) => (part.width, part.height)),
        everyElement((4, 4)),
      );
    });

    test('maps Direct 8x8 partitions to normative co-located 4x4 samples', () {
      final regions = H264BInterMacroblockType.fromCode(0)
          .directInferenceRegionsAt(
            macroblockX: 16,
            macroblockY: 32,
            direct8x8Inference: true,
          );

      expect(
        regions.map(
          (region) => deriveDirectColocatedLumaSamplePosition(
            macroblockX: 16,
            macroblockY: 32,
            macroblockPartitionIndex: region.macroblockPartitionIndex,
            subMacroblockPartitionIndex: region.subMacroblockPartitionIndex!,
            direct8x8Inference: true,
          ),
        ),
        <({int x, int y})>[
          (x: 16, y: 32),
          (x: 28, y: 32),
          (x: 16, y: 44),
          (x: 28, y: 44),
        ],
      );
    });

    test('maps Direct 4x4 partitions to their own co-located samples', () {
      final regions = H264BInterMacroblockType.fromCode(0)
          .directInferenceRegionsAt(
            macroblockX: 16,
            macroblockY: 32,
            direct8x8Inference: false,
          );

      expect(
        regions.map(
          (region) => deriveDirectColocatedLumaSamplePosition(
            macroblockX: 16,
            macroblockY: 32,
            macroblockPartitionIndex: region.macroblockPartitionIndex,
            subMacroblockPartitionIndex: region.subMacroblockPartitionIndex!,
            direct8x8Inference: false,
          ),
        ),
        regions.map((region) => (x: region.x, y: region.y)),
      );
    });

    test('B_Direct_8x8 consolidates only when direct8x8 inference is set', () {
      final direct = H264BSubMacroblockType.fromCode(0);

      expect(
        direct.directInferenceRegionsAt(
          macroblockX: 0,
          macroblockY: 0,
          macroblockPartitionIndex: 2,
          direct8x8Inference: true,
        ),
        hasLength(1),
      );
      expect(
        direct.directInferenceRegionsAt(
          macroblockX: 0,
          macroblockY: 0,
          macroblockPartitionIndex: 2,
          direct8x8Inference: false,
        ),
        hasLength(4),
      );
    });
  });

  group('dual-list inter motion', () {
    test('derives List0 and List1 predictors independently for BiPred', () {
      final grid = H264DualMotionFieldGrid.forLumaSize(width: 64, height: 64);
      _setBiBlock(
        grid,
        x: 12,
        y: 16,
        referenceL0: 0,
        vectorL0: const MotionVector(4, 8),
        referenceL1: 1,
        vectorL1: const MotionVector(40, 80),
      );
      _setBiBlock(
        grid,
        x: 16,
        y: 12,
        referenceL0: 0,
        vectorL0: const MotionVector(8, 12),
        referenceL1: 0,
        vectorL1: const MotionVector(44, 84),
      );
      _setBiBlock(
        grid,
        x: 32,
        y: 12,
        referenceL0: 1,
        vectorL0: const MotionVector(12, 16),
        referenceL1: 0,
        vectorL1: const MotionVector(48, 88),
      );

      final motion = deriveBInterMotion(
        grid: grid,
        mode: H264BPredictionMode.bi,
        partitionX: 16,
        partitionY: 16,
        partitionWidth: 16,
        partitionHeight: 16,
        partitionShape: H264BPartitionShape.block16x16,
        referenceIndexL0: 0,
        referenceIndexL1: 0,
        differenceL0: const MotionVector(1, -2),
        differenceL1: const MotionVector(-4, 2),
      );

      expect(motion.syntaxMode, H264BPredictionMode.bi);
      expect(motion.list0!.referenceIndex, 0);
      expect(motion.list0!.vector, const MotionVector(9, 10));
      expect(motion.list1!.referenceIndex, 0);
      expect(motion.list1!.vector, const MotionVector(40, 86));
    });

    test('honours 16x8 preferred candidate and slice availability', () {
      final grid = H264DualMotionFieldGrid.forLumaSize(width: 64, height: 64);
      _setList0Block(
        grid,
        x: 12,
        y: 16,
        reference: 0,
        vector: const MotionVector(1, 1),
        sliceId: 7,
      );
      _setList0Block(
        grid,
        x: 16,
        y: 12,
        reference: 0,
        vector: const MotionVector(20, -4),
        sliceId: 7,
      );
      _setList0Block(
        grid,
        x: 32,
        y: 12,
        reference: 0,
        vector: const MotionVector(3, 3),
        sliceId: 7,
      );

      final sameSlice = deriveBInterMotion(
        grid: grid,
        mode: H264BPredictionMode.list0,
        partitionX: 16,
        partitionY: 16,
        partitionWidth: 16,
        partitionHeight: 8,
        partitionShape: H264BPartitionShape.horizontal16x8,
        referenceIndexL0: 0,
        currentSliceId: 7,
      );
      final differentSlice = deriveBInterMotion(
        grid: grid,
        mode: H264BPredictionMode.list0,
        partitionX: 16,
        partitionY: 16,
        partitionWidth: 16,
        partitionHeight: 8,
        partitionShape: H264BPartitionShape.horizontal16x8,
        referenceIndexL0: 0,
        currentSliceId: 8,
      );

      expect(sameSlice.list0!.vector, const MotionVector(20, -4));
      expect(differentSlice.list0!.vector, MotionVector.zero);
    });

    test('stores both picture-list fields at every covered 4x4 block', () {
      final grid = H264DualMotionFieldGrid.forLumaSize(width: 32, height: 16);
      final motion = H264DualListMotion.inter(
        mode: H264BPredictionMode.bi,
        list0: H264ReferenceMotion(
          referenceIndex: 1,
          vector: const MotionVector(4, -2),
        ),
        list1: H264ReferenceMotion(
          referenceIndex: 0,
          vector: const MotionVector(-8, 6),
        ),
      );
      grid.setPartition(
        x: 8,
        y: 4,
        width: 8,
        height: 8,
        motion: motion,
        sliceId: 3,
      );

      for (final block in <(int, int)>[(2, 1), (3, 1), (2, 2), (3, 2)]) {
        final stored = grid.entryAt4x4(block.$1, block.$2, currentSliceId: 3);
        expect(stored.motion!.list0!.referenceIndex, 1);
        expect(stored.motion!.list0!.vector, const MotionVector(4, -2));
        expect(stored.motion!.list1!.referenceIndex, 0);
        expect(stored.motion!.list1!.vector, const MotionVector(-8, 6));
      }
      expect(grid.entryAt4x4(2, 1, currentSliceId: 4).available, isFalse);
      expect(grid.entryAt4x4(4, 1).available, isFalse);
    });
  });

  group('spatial Direct prediction', () {
    test(
      'derives each reference list and applies colocated-zero separately',
      () {
        final grid = H264DualMotionFieldGrid.forLumaSize(width: 64, height: 64);
        _setList0Block(
          grid,
          x: 12,
          y: 16,
          reference: 2,
          vector: const MotionVector(20, 2),
        );
        _setBiBlock(
          grid,
          x: 16,
          y: 12,
          referenceL0: 1,
          vectorL0: const MotionVector(10, 1),
          referenceL1: 3,
          vectorL1: const MotionVector(30, 3),
        );
        _setList1Block(
          grid,
          x: 32,
          y: 12,
          reference: 0,
          vector: const MotionVector(5, -5),
        );

        final context = deriveSpatialDirectContext(
          grid: grid,
          macroblockX: 16,
          macroblockY: 16,
        );
        final shortTerm = context.resolve(
          colocated: H264ColocatedMotion.inter(
            referenceIndex: 0,
            vector: const MotionVector(1, -1),
          ),
          list1Reference0IsShortTerm: true,
        );
        final longTerm = context.resolve(
          colocated: H264ColocatedMotion.inter(
            referenceIndex: 0,
            vector: const MotionVector(1, -1),
          ),
          list1Reference0IsShortTerm: false,
        );

        expect((context.referenceIndexL0, context.referenceIndexL1), (1, 0));
        expect(context.predictorL0, const MotionVector(10, 1));
        expect(context.predictorL1, const MotionVector(5, -5));
        expect(shortTerm.colocatedZero, isTrue);
        expect(shortTerm.list0!.vector, const MotionVector(10, 1));
        expect(shortTerm.list1!.vector, MotionVector.zero);
        expect(shortTerm.effectiveMode, H264BPredictionMode.bi);
        expect(longTerm.colocatedZero, isFalse);
        expect(longTerm.list1!.vector, const MotionVector(5, -5));
      },
    );

    test(
      'forces both refIdx zero and both vectors zero with no neighbours',
      () {
        final context = deriveSpatialDirectContext(
          grid: H264DualMotionFieldGrid.forLumaSize(width: 32, height: 16),
          macroblockX: 0,
          macroblockY: 0,
        );
        final motion = context.resolve(
          colocated: const H264ColocatedMotion.intra(),
          list1Reference0IsShortTerm: true,
        );

        expect(context.directZeroPrediction, isTrue);
        expect((context.referenceIndexL0, context.referenceIndexL1), (0, 0));
        expect(motion.directZeroPrediction, isTrue);
        expect(motion.list0!.vector, MotionVector.zero);
        expect(motion.list1!.vector, MotionVector.zero);
      },
    );

    test('retains a single available list and colocated List0 priority', () {
      final grid = H264DualMotionFieldGrid.forLumaSize(width: 64, height: 32);
      _setList0Block(
        grid,
        x: 12,
        y: 16,
        reference: 2,
        vector: const MotionVector(7, 9),
      );
      final context = deriveSpatialDirectContext(
        grid: grid,
        macroblockX: 16,
        macroblockY: 16,
      );
      final motion = context.resolve(
        colocated: H264ColocatedMotion.inter(
          referenceIndex: 4,
          vector: const MotionVector(99, 99),
        ),
        list1Reference0IsShortTerm: true,
      );

      expect(motion.list0!.referenceIndex, 2);
      expect(motion.list0!.vector, const MotionVector(7, 9));
      expect(motion.list1, isNull);
      expect(motion.effectiveMode, H264BPredictionMode.list0);

      final colocated = H264ColocatedMotion.fromDualList(
        H264DualListMotion.inter(
          mode: H264BPredictionMode.bi,
          list0: H264ReferenceMotion(
            referenceIndex: 3,
            vector: const MotionVector(11, 12),
          ),
          list1: H264ReferenceMotion(
            referenceIndex: 0,
            vector: const MotionVector(1, 1),
          ),
        ),
      );
      expect(colocated.referenceIndex, 3);
      expect(colocated.vector, const MotionVector(11, 12));
    });
  });

  group('temporal Direct prediction', () {
    test('maps the co-located stable identity and applies POC scaling', () {
      final motion = deriveTemporalDirectMotion(
        colocated: const H264TemporalColocatedMotion.inter(
          referencePictureId: 11,
          vector: MotionVector(8, -4),
        ),
        referencePictureIdsL0: const <int>[11, 22],
        referencePictureOrderCountsL0: const <int>[0, -2],
        currentPictureOrderCount: 2,
        list1Reference0PictureOrderCount: 4,
      );

      expect(motion.derivedFromDirect, isTrue);
      expect(motion.effectiveMode, H264BPredictionMode.bi);
      expect(motion.list0!.referenceIndex, 0);
      expect(motion.list0!.vector, const MotionVector(4, -2));
      expect(motion.list1!.referenceIndex, 0);
      expect(motion.list1!.vector, const MotionVector(-4, 2));
    });

    test('uses zero motion on both lists for an intra co-located block', () {
      final motion = deriveTemporalDirectMotion(
        colocated: const H264TemporalColocatedMotion.intra(),
        referencePictureIdsL0: const <int>[7],
        referencePictureOrderCountsL0: const <int>[8],
        currentPictureOrderCount: 10,
        list1Reference0PictureOrderCount: 12,
      );

      expect(motion.directZeroPrediction, isTrue);
      expect(motion.list0!.referenceIndex, 0);
      expect(motion.list0!.vector, MotionVector.zero);
      expect(motion.list1!.referenceIndex, 0);
      expect(motion.list1!.vector, MotionVector.zero);
    });

    test('uses unscaled co-located motion when temporal distance is zero', () {
      final motion = deriveTemporalDirectMotion(
        colocated: const H264TemporalColocatedMotion.inter(
          referencePictureId: 9,
          vector: MotionVector(13, -7),
        ),
        referencePictureIdsL0: const <int>[9],
        referencePictureOrderCountsL0: const <int>[20],
        currentPictureOrderCount: 20,
        list1Reference0PictureOrderCount: 20,
      );

      expect(motion.list0!.vector, const MotionVector(13, -7));
      expect(motion.list1!.vector, MotionVector.zero);
    });

    test('rejects a co-located reference missing from current List0', () {
      expect(
        () => deriveTemporalDirectMotion(
          colocated: const H264TemporalColocatedMotion.inter(
            referencePictureId: 99,
            vector: MotionVector.zero,
          ),
          referencePictureIdsL0: const <int>[1, 2],
          referencePictureOrderCountsL0: const <int>[0, 2],
          currentPictureOrderCount: 4,
          list1Reference0PictureOrderCount: 6,
        ),
        throwsFormatException,
      );
    });
  });

  test('exact sfux first P/B headers select spatial Direct 8x8 foundation', () {
    final sps = parseSpsNal(
      _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
    );
    final pps = parsePpsNal(
      _hex('68e9b8372c8b'),
      chromaFormatIdc: sps.chromaFormatIdc,
    );
    final ppsById = <int, PpsInfo>{pps.ppsId: pps};
    final spsById = <int, SpsInfo>{sps.spsId: sps};
    final firstP = parseSliceHeader(
      _hex(
        '419a226e810109fffeb52a80000003000003000003000003000003000003000003'
        '00001eb0',
      ),
      ppsById: ppsById,
      spsById: spsById,
    );
    final firstB = parseSliceHeader(
      _hex(
        '019e417909ff000003000003000003000003000003000c0838a103bfc31fd92600'
        '0003000004cd',
      ),
      ppsById: ppsById,
      spsById: spsById,
    );

    expect((firstP.sliceType, firstP.picOrderCntLsb), (H264SliceType.p, 4));
    expect((firstB.sliceType, firstB.picOrderCntLsb), (H264SliceType.b, 2));
    expect(firstB.directSpatialMvPredFlag, isTrue);
    expect(sps.direct8x8InferenceFlag, isTrue);

    // The headers select spatial Direct and one inference result per 8x8.
    // mb_type remains CABAC slice data; when it resolves to Direct, this is
    // the exact geometry and dual-list zero vector used at an unavailable
    // top-left neighbourhood.
    final regions = H264BInterMacroblockType.fromCode(0)
        .directInferenceRegionsAt(
          macroblockX: 0,
          macroblockY: 0,
          direct8x8Inference: sps.direct8x8InferenceFlag,
        );
    final motionGrid = H264DualMotionFieldGrid.forLumaSize(
      width: 16,
      height: 16,
    );
    final direct =
        deriveSpatialDirectContext(
          grid: motionGrid,
          macroblockX: 0,
          macroblockY: 0,
        ).resolve(
          colocated: const H264ColocatedMotion.intra(),
          list1Reference0IsShortTerm: true,
        );

    expect(regions, hasLength(4));
    expect(
      regions.map((region) => (region.width, region.height)),
      everyElement((8, 8)),
    );
    expect(direct.effectiveMode, H264BPredictionMode.bi);
    expect(
      (direct.list0!.referenceIndex, direct.list1!.referenceIndex),
      (0, 0),
    );
    expect(direct.list0!.vector, MotionVector.zero);
    expect(direct.list1!.vector, MotionVector.zero);

    // Caller contract for the first B picture: retain both lists per 4x4,
    // map L0[0] to IDR POC 0 and L1[0] to weighted-P POC 4, then apply the
    // stream's implicit midpoint weights.
    for (final region in regions) {
      motionGrid.setPartition(
        x: region.x,
        y: region.y,
        width: region.width,
        height: region.height,
        motion: direct,
      );
    }
    final stored = motionGrid.entryAt4x4(3, 3).motion!;
    final midpointWeights = deriveImplicitBiPredictionWeights(
      currentPoc: firstB.picOrderCntLsb!,
      list0Poc: 0,
      list1Poc: firstP.picOrderCntLsb!,
    );
    expect(stored.usesList0, isTrue);
    expect(stored.usesList1, isTrue);
    expect(
      (midpointWeights.list0Weight, midpointWeights.list1Weight),
      (32, 32),
    );
    expect(
      implicitWeightedBiSample8(
        list0Sample: 16,
        list1Sample: 32,
        weights: midpointWeights,
      ),
      24,
    );
    expect(
      implicitWeightedBiSample8(
        list0Sample: 127,
        list1Sample: 127,
        weights: midpointWeights,
      ),
      127,
    );
  });
}

void _setList0Block(
  H264DualMotionFieldGrid grid, {
  required int x,
  required int y,
  required int reference,
  required MotionVector vector,
  int sliceId = 0,
}) {
  grid.setPartition(
    x: x,
    y: y,
    width: 4,
    height: 4,
    sliceId: sliceId,
    motion: H264DualListMotion.inter(
      mode: H264BPredictionMode.list0,
      list0: H264ReferenceMotion(referenceIndex: reference, vector: vector),
    ),
  );
}

void _setList1Block(
  H264DualMotionFieldGrid grid, {
  required int x,
  required int y,
  required int reference,
  required MotionVector vector,
  int sliceId = 0,
}) {
  grid.setPartition(
    x: x,
    y: y,
    width: 4,
    height: 4,
    sliceId: sliceId,
    motion: H264DualListMotion.inter(
      mode: H264BPredictionMode.list1,
      list1: H264ReferenceMotion(referenceIndex: reference, vector: vector),
    ),
  );
}

void _setBiBlock(
  H264DualMotionFieldGrid grid, {
  required int x,
  required int y,
  required int referenceL0,
  required MotionVector vectorL0,
  required int referenceL1,
  required MotionVector vectorL1,
  int sliceId = 0,
}) {
  grid.setPartition(
    x: x,
    y: y,
    width: 4,
    height: 4,
    sliceId: sliceId,
    motion: H264DualListMotion.inter(
      mode: H264BPredictionMode.bi,
      list0: H264ReferenceMotion(referenceIndex: referenceL0, vector: vectorL0),
      list1: H264ReferenceMotion(referenceIndex: referenceL1, vector: vectorL1),
    ),
  );
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
