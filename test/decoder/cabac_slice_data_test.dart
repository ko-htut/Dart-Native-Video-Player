import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/bitreader.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';

void main() {
  group('CABAC alignment', () {
    test('consumes every repeated cabac_alignment_one_bit', () {
      final reader = _bitReader('00011111');
      reader.seekBit(3);

      expect(readCabacAlignmentOneBits(reader), 5);
      expect(reader.bitPos, 8);
    });

    test('rejects a zero at its exact alignment position', () {
      final reader = _bitReader('00011011');
      reader.seekBit(3);

      expect(
        () => readCabacAlignmentOneBits(reader),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.bitPosition,
            'bitPosition',
            5,
          ),
        ),
      );
    });
  });

  group('macroblock flags and types', () {
    test('end_of_slice_flag uses the terminating decoder path', () {
      final bins = _ScriptedBins(terminates: <int>[1]);
      expect(
        _decoder(H264CabacSliceType.p, bins).decodeEndOfSliceFlag(),
        isTrue,
      );
      bins.expectComplete(terminateCount: 1);
    });

    test('P and B skip flags derive contexts from non-skipped neighbors', () {
      final pBins = _ScriptedBins(decisions: <int>[1]);
      final p = _decoder(H264CabacSliceType.p, pBins);
      expect(
        p.decodeMbSkipFlag(
          neighbors: const CabacMacroblockNeighbors(
            left: CabacMacroblockNeighbor(skipped: false),
            top: CabacMacroblockNeighbor(skipped: true),
          ),
        ),
        isTrue,
      );
      pBins.expectComplete(decisionContexts: <int>[12]);

      final bBins = _ScriptedBins(decisions: <int>[0]);
      final b = _decoder(H264CabacSliceType.b, bBins);
      expect(
        b.decodeMbSkipFlag(
          neighbors: const CabacMacroblockNeighbors(
            left: CabacMacroblockNeighbor(),
            top: CabacMacroblockNeighbor(),
          ),
        ),
        isFalse,
      );
      bBins.expectComplete(decisionContexts: <int>[26]);
    });

    test('I16x16 branch uses neighbor, CBP, and prediction contexts', () {
      final bins = _ScriptedBins(
        decisions: <int>[1, 1, 1, 1, 1, 1],
        terminates: <int>[0],
      );
      final decoder = _decoder(H264CabacSliceType.i, bins);

      final type = decoder.decodeMbType(
        neighbors: const CabacMacroblockNeighbors(
          left: CabacMacroblockNeighbor(intra16x16: true),
          top: CabacMacroblockNeighbor(pcm: true),
        ),
      );

      expect(type.codeNum, 24);
      expect(type.kind, CabacMacroblockKind.intra16x16);
      expect(type.intra16x16PredictionMode, 3);
      expect(type.intra16x16CodedBlockPattern?.luma, 15);
      expect(type.intra16x16CodedBlockPattern?.chroma, 2);
      bins.expectComplete(
        decisionContexts: <int>[5, 6, 7, 8, 9, 10],
        terminateCount: 1,
      );
    });

    test('I_PCM is selected by terminate and exposes typed classification', () {
      final bins = _ScriptedBins(decisions: <int>[1], terminates: <int>[1]);
      final type = _decoder(H264CabacSliceType.i, bins).decodeMbType();

      expect(type.codeNum, 25);
      expect(type.kind, CabacMacroblockKind.pcm);
      bins.expectComplete(decisionContexts: <int>[3], terminateCount: 1);
    });

    test('P inter and intra-NxN binarizations retain Table 7-13 values', () {
      final interBins = _ScriptedBins(decisions: <int>[0, 1, 0]);
      final inter = _decoder(H264CabacSliceType.p, interBins).decodeMbType();
      expect(inter.codeNum, 2);
      expect(inter.kind, CabacMacroblockKind.inter);
      interBins.expectComplete(decisionContexts: <int>[14, 15, 17]);

      final intraBins = _ScriptedBins(decisions: <int>[1, 0]);
      final intra = _decoder(H264CabacSliceType.p, intraBins).decodeMbType();
      expect(intra.codeNum, 5);
      expect(intra.kind, CabacMacroblockKind.intraNxN);
      intraBins.expectComplete(decisionContexts: <int>[14, 17]);
    });

    test('B 8x8 and B intra-NxN branches follow Table 9-37 tree', () {
      final eightByEightBins = _ScriptedBins(
        decisions: <int>[1, 1, 1, 1, 1, 1],
      );
      final eightByEight = _decoder(
        H264CabacSliceType.b,
        eightByEightBins,
      ).decodeMbType();
      expect(eightByEight.codeNum, 22);
      eightByEightBins.expectComplete(
        decisionContexts: <int>[27, 30, 31, 32, 32, 32],
      );

      // The four-bit branch value 13 enters the ctxIdx 32 intra tree.
      final intraBins = _ScriptedBins(decisions: <int>[1, 1, 1, 1, 0, 1, 0]);
      final intra = _decoder(H264CabacSliceType.b, intraBins).decodeMbType();
      expect(intra.codeNum, 23);
      expect(intra.kind, CabacMacroblockKind.intraNxN);
      intraBins.expectComplete(
        decisionContexts: <int>[27, 30, 31, 32, 32, 32, 32],
      );
    });

    test('P and B sub-macroblock type trees use their normative contexts', () {
      final pBins = _ScriptedBins(decisions: <int>[0, 1, 1]);
      final pType = _decoder(H264CabacSliceType.p, pBins).decodeSubMbType();
      expect(pType.codeNum, 2);
      expect((pType.partitionWidth, pType.partitionHeight), (4, 8));
      expect(pType.usesList0, isTrue);
      pBins.expectComplete(decisionContexts: <int>[21, 22, 23]);

      final bBins = _ScriptedBins(decisions: <int>[1, 1, 1, 1, 1]);
      final bType = _decoder(H264CabacSliceType.b, bBins).decodeSubMbType();
      expect(bType.codeNum, 12);
      expect(bType.usesList0, isTrue);
      expect(bType.usesList1, isTrue);
      expect(bType.partitionCount, 4);
      bBins.expectComplete(decisionContexts: <int>[36, 37, 38, 39, 39]);
    });
  });

  group('transform_size_8x8_flag presence', () {
    test('I_NxN follows transform_8x8_mode_flag before CBP', () {
      final intraNxn = CabacMacroblockType.fromCode(
        sliceType: H264CabacSliceType.i,
        codeNum: 0,
      );

      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: intraNxn,
        ),
        isTrue,
      );
      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: false,
          macroblockType: intraNxn,
        ),
        isFalse,
      );
    });

    test('P_16x16 is eligible when luma CBP is nonzero', () {
      final p16x16 = CabacMacroblockType.fromCode(
        sliceType: H264CabacSliceType.p,
        codeNum: 0,
      );

      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: p16x16,
          codedBlockPattern: const CabacCodedBlockPattern(luma: 4, chroma: 0),
        ),
        isTrue,
      );
      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: p16x16,
          codedBlockPattern: const CabacCodedBlockPattern(luma: 0, chroma: 2),
        ),
        isFalse,
      );
    });

    test('P_8x8 rejects any sub-partition smaller than 8x8', () {
      final p8x8 = CabacMacroblockType.fromCode(
        sliceType: H264CabacSliceType.p,
        codeNum: 3,
      );
      final eightByEight = CabacSubMacroblockType.fromCode(
        sliceType: H264CabacSliceType.p,
        codeNum: 0,
      );
      final eightByFour = CabacSubMacroblockType.fromCode(
        sliceType: H264CabacSliceType.p,
        codeNum: 1,
      );

      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: p8x8,
          codedBlockPattern: const CabacCodedBlockPattern(luma: 1, chroma: 0),
          subMacroblockTypes: List<CabacSubMacroblockType>.filled(
            4,
            eightByEight,
          ),
        ),
        isTrue,
      );
      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: p8x8,
          codedBlockPattern: const CabacCodedBlockPattern(luma: 1, chroma: 0),
          subMacroblockTypes: <CabacSubMacroblockType>[
            eightByEight,
            eightByEight,
            eightByFour,
            eightByEight,
          ],
        ),
        isFalse,
      );
      expect(
        () => isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: p8x8,
          codedBlockPattern: const CabacCodedBlockPattern(luma: 1, chroma: 0),
        ),
        throwsArgumentError,
      );
    });

    test('B_Direct requires direct_8x8_inference_flag', () {
      final direct = CabacMacroblockType.fromCode(
        sliceType: H264CabacSliceType.b,
        codeNum: 0,
      );
      const cbp = CabacCodedBlockPattern(luma: 1, chroma: 0);

      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: direct,
          codedBlockPattern: cbp,
          direct8x8InferenceFlag: false,
        ),
        isFalse,
      );
      expect(
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: true,
          macroblockType: direct,
          codedBlockPattern: cbp,
          direct8x8InferenceFlag: true,
        ),
        isTrue,
      );
    });
  });

  group('motion syntax', () {
    test('B ref_idx excludes direct neighbors and decodes L1 unary value', () {
      final bins = _ScriptedBins(decisions: <int>[1, 1, 0]);
      final syntax = _decoder(H264CabacSliceType.b, bins).decodeReferenceIndex(
        list: CabacReferenceList.l1,
        activeReferenceCount: 3,
        left: const CabacReferenceNeighbor(referenceIndex: 2),
        top: const CabacReferenceNeighbor(referenceIndex: 2, direct: true),
      );

      expect(syntax.list, CabacReferenceList.l1);
      expect(syntax.value, 2);
      bins.expectComplete(decisionContexts: <int>[55, 58, 59]);
    });

    test('single active reference consumes no CABAC bins', () {
      final bins = _ScriptedBins();
      final syntax = _decoder(H264CabacSliceType.p, bins).decodeReferenceIndex(
        list: CabacReferenceList.l0,
        activeReferenceCount: 1,
      );
      expect(syntax.value, 0);
      bins.expectComplete();
    });

    test('MVD derives neighbor class and exercises order-3 bypass escape', () {
      final bins = _ScriptedBins(
        decisions: List<int>.filled(9, 1),
        bypasses: <int>[0, 0, 0, 1, 1],
      );
      final value = _decoder(H264CabacSliceType.p, bins).decodeMvdComponent(
        component: CabacMvdComponent.horizontal,
        left: const CabacMvdNeighbor(horizontal: 2),
        top: const CabacMvdNeighbor(horizontal: -1),
      );

      expect(value, -10);
      bins.expectComplete(
        decisionContexts: <int>[41, 43, 44, 45, 46, 46, 46, 46, 46],
        bypassCount: 5,
      );
    });

    test('vertical MVD uses the >32 neighbor context class', () {
      final bins = _ScriptedBins(decisions: <int>[0]);
      expect(
        _decoder(H264CabacSliceType.b, bins).decodeMvdComponent(
          component: CabacMvdComponent.vertical,
          left: const CabacMvdNeighbor(vertical: 33),
        ),
        0,
      );
      bins.expectComplete(decisionContexts: <int>[49]);
    });
  });

  group('intra, transform, CBP, and QP syntax', () {
    test('intra4x4 rem mode is LSB-first and reconstructs around MPM', () {
      final bins = _ScriptedBins(decisions: <int>[0, 1, 0, 1]);
      final mode = _decoder(
        H264CabacSliceType.i,
        bins,
      ).decodeIntra4x4Mode(predictedMode: 3);

      expect(mode.usesPredictedMode, isFalse);
      expect(mode.remainingMode, 5);
      expect(mode.mode, 6);
      bins.expectComplete(decisionContexts: <int>[68, 69, 69, 69]);
    });

    test('intra8x8 predicted flag returns supplied most-probable mode', () {
      final bins = _ScriptedBins(decisions: <int>[1]);
      final mode = _decoder(
        H264CabacSliceType.i,
        bins,
      ).decodeIntra8x8Mode(predictedMode: 7);

      expect(mode.usesPredictedMode, isTrue);
      expect(mode.remainingMode, isNull);
      expect(mode.mode, 7);
      bins.expectComplete(decisionContexts: <int>[68]);
    });

    test('chroma mode and transform8x8 use both available neighbors', () {
      const neighbors = CabacMacroblockNeighbors(
        left: CabacMacroblockNeighbor(
          intraChromaPredictionMode: 1,
          transformSize8x8: true,
        ),
        top: CabacMacroblockNeighbor(
          intraChromaPredictionMode: 3,
          transformSize8x8: true,
        ),
      );
      final chromaBins = _ScriptedBins(decisions: <int>[1, 1, 0]);
      expect(
        _decoder(
          H264CabacSliceType.i,
          chromaBins,
        ).decodeIntraChromaPredictionMode(neighbors: neighbors),
        2,
      );
      chromaBins.expectComplete(decisionContexts: <int>[66, 67, 67]);

      final transformBins = _ScriptedBins(decisions: <int>[1]);
      expect(
        _decoder(
          H264CabacSliceType.p,
          transformBins,
        ).decodeTransformSize8x8Flag(neighbors: neighbors),
        isTrue,
      );
      transformBins.expectComplete(decisionContexts: <int>[401]);
    });

    test('coded block pattern derives each luma and chroma context', () {
      final bins = _ScriptedBins(decisions: <int>[0, 1, 0, 1, 1, 1]);
      final pattern = _decoder(H264CabacSliceType.p, bins)
          .decodeCodedBlockPattern(
            neighbors: const CabacMacroblockNeighbors(
              left: CabacMacroblockNeighbor(
                codedBlockPatternLuma: 10,
                codedBlockPatternChroma: 2,
              ),
              top: CabacMacroblockNeighbor(
                codedBlockPatternLuma: 4,
                codedBlockPatternChroma: 1,
              ),
            ),
          );

      expect(pattern.luma, 10);
      expect(pattern.chroma, 2);
      expect(pattern.packed, 0x2a);
      bins.expectComplete(decisionContexts: <int>[73, 76, 75, 74, 80, 82]);
    });

    test('mb_qp_delta keeps and resets the previous-delta context', () {
      final bins = _ScriptedBins(decisions: <int>[1, 0, 1, 1, 0, 0]);
      final decoder = _decoder(H264CabacSliceType.p, bins);

      expect(decoder.decodeMbQpDelta(), 1);
      expect(decoder.decodeMbQpDelta(), -1);
      expect(decoder.decodeMbQpDelta(), 0);
      expect(decoder.previousMbQpDelta, 0);
      bins.expectComplete(decisionContexts: <int>[60, 62, 61, 62, 63, 61]);
    });
  });

  group('residual syntax', () {
    test('luma CBF derives symmetric cross-category neighbor state', () {
      final intra16x16 = deriveCabacLumaCodedBlockNeighbor(
        macroblockAvailable: true,
        transformSize8x8: false,
        codedBlockPatternLuma: 15,
        lumaCodedMask: 0xffff,
        blockX: 3,
        blockY: 2,
      );
      expect(
        intra16x16.availability,
        CabacCodedBlockNeighborAvailability.available,
      );
      expect(intra16x16.coded, isTrue);

      final compatibilityWrapper = deriveCabacLuma4x4CodedBlockNeighbor(
        macroblockAvailable: true,
        intra16x16: true,
        transformSize8x8: false,
        codedBlockPatternLuma: 15,
        lumaCodedMask: 1 << 11,
        blockX: 3,
        blockY: 2,
      );
      expect(
        compatibilityWrapper.availability,
        CabacCodedBlockNeighborAvailability.available,
      );
      expect(compatibilityWrapper.coded, isTrue);

      final transform8Coded = deriveCabacLumaCodedBlockNeighbor(
        macroblockAvailable: true,
        transformSize8x8: true,
        codedBlockPatternLuma: 1 << 3,
        lumaCodedMask: 0,
        blockX: 3,
        blockY: 2,
      );
      expect(
        transform8Coded.availability,
        CabacCodedBlockNeighborAvailability.available,
      );
      expect(transform8Coded.coded, isTrue);

      final transform8Uncoded = deriveCabacLumaCodedBlockNeighbor(
        macroblockAvailable: true,
        transformSize8x8: true,
        codedBlockPatternLuma: 1 << 2,
        lumaCodedMask: 0xffff,
        blockX: 3,
        blockY: 2,
      );
      expect(
        transform8Uncoded.availability,
        CabacCodedBlockNeighborAvailability.blockUnavailable,
      );
      expect(transform8Uncoded.coded, isFalse);

      final ordinary = deriveCabacLumaCodedBlockNeighbor(
        macroblockAvailable: true,
        transformSize8x8: false,
        codedBlockPatternLuma: 15,
        lumaCodedMask: 1 << 11,
        blockX: 3,
        blockY: 2,
      );
      expect(
        ordinary.availability,
        CabacCodedBlockNeighborAvailability.available,
      );
      expect(ordinary.coded, isTrue);

      final missingMacroblock = deriveCabacLumaCodedBlockNeighbor(
        macroblockAvailable: false,
        transformSize8x8: false,
        codedBlockPatternLuma: 15,
        lumaCodedMask: 0xffff,
        blockX: 3,
        blockY: 2,
      );
      expect(
        missingMacroblock.availability,
        CabacCodedBlockNeighborAvailability.macroblockUnavailable,
      );
    });

    test(
      '4x4 coded block derives CBF, significance, last, level, and sign',
      () {
        final bins = _ScriptedBins(
          decisions: <int>[1, 0, 1, 1, 0],
          bypasses: <int>[1],
        );
        final block = _decoder(H264CabacSliceType.p, bins).decodeResidualBlock(
          category: CabacResidualCategory.luma4x4,
          currentMacroblockIntra: false,
          left: const CabacCodedBlockNeighbor(coded: true),
          top: const CabacCodedBlockNeighbor(coded: false),
        );

        expect(block.coded, isTrue);
        expect(block.totalCoefficients, 1);
        expect(block.coefficients[1], -1);
        expect(block.coefficients.where((value) => value != 0), <int>[-1]);
        bins.expectComplete(
          decisionContexts: <int>[94, 134, 135, 196, 248],
          bypassCount: 1,
        );
      },
    );

    test('uncoded block returns the normative scan-length zero array', () {
      final bins = _ScriptedBins(decisions: <int>[0]);
      final block = _decoder(H264CabacSliceType.i, bins).decodeResidualBlock(
        category: CabacResidualCategory.chromaAc420,
        currentMacroblockIntra: true,
      );

      expect(block.coded, isFalse);
      expect(block.coefficients, hasLength(15));
      expect(block.totalCoefficients, 0);
      // Both unavailable neighbors default to coded for an intra macroblock.
      bins.expectComplete(decisionContexts: <int>[104]);
    });

    test('8x8 uses Table 9-43 context maps and has no CBF', () {
      final bins = _ScriptedBins(
        decisions: <int>[0, 0, 1, 1, 0],
        bypasses: <int>[0],
      );
      final block = _decoder(H264CabacSliceType.p, bins).decodeResidualBlock(
        category: CabacResidualCategory.luma8x8,
        currentMacroblockIntra: false,
      );

      expect(block.coefficients, hasLength(64));
      expect(block.coefficients[2], 1);
      expect(block.totalCoefficients, 1);
      bins.expectComplete(
        decisionContexts: <int>[402, 403, 404, 418, 427],
        bypassCount: 1,
      );
    });

    test('4:2:0 chroma DC decodes reverse coefficient levels', () {
      final bins = _ScriptedBins(
        decisions: <int>[1, 1, 0, 0, 1, 1, 1, 1, 0, 0],
        bypasses: <int>[0, 1],
      );
      final block = _decoder(H264CabacSliceType.i, bins).decodeResidualBlock(
        category: CabacResidualCategory.chromaDc420,
        currentMacroblockIntra: true,
      );

      expect(block.coefficients, <int>[-1, 0, 3, 0]);
      expect(block.totalCoefficients, 2);
      bins.expectComplete(
        decisionContexts: <int>[
          100,
          149,
          210,
          150,
          151,
          212,
          258,
          262,
          262,
          257,
        ],
        bypassCount: 2,
      );
    });

    test('coeff_abs_level_minus1 reaches bypass Exp-Golomb escape', () {
      final decisions = <int>[
        1, // coded_block_flag
        1, 1, // significant and last at scan position zero
        1, // coeff_abs_level_minus1 greater than zero
        ...List<int>.filled(13, 1), // regular level prefix through 14
      ];
      final bins = _ScriptedBins(
        decisions: decisions,
        bypasses: <int>[1, 0, 1, 0], // Exp-Golomb value 2, positive sign
      );
      final block = _decoder(H264CabacSliceType.p, bins).decodeResidualBlock(
        category: CabacResidualCategory.luma4x4,
        currentMacroblockIntra: false,
      );

      expect(block.coefficients[0], 17);
      expect(block.totalCoefficients, 1);
      bins.expectComplete(
        decisionContexts: <int>[
          93,
          134,
          195,
          248,
          ...List<int>.filled(13, 252),
        ],
        bypassCount: 4,
      );
    });

    test('level contexts track prior equal-one and greater-one counts', () {
      final bins = _ScriptedBins(
        decisions: <int>[
          1, 0, // significant position 0, not last
          1, 0, // significant position 1, not last
          1, 1, // significant position 2, last
          0, // reverse position 2: abs=1 at levelBase+1
          0, // reverse position 1: abs=1 at levelBase+2
          1, 0, // reverse position 0: abs=2, continuation base+5
        ],
        bypasses: <int>[0, 0, 0],
      );
      final block = _decoder(H264CabacSliceType.p, bins).decodeResidualBlock(
        category: CabacResidualCategory.luma4x4,
        currentMacroblockIntra: false,
        codedBlockFlagPresent: false,
      );

      expect(block.coefficients.take(3), <int>[2, 1, 1]);
      bins.expectComplete(
        decisionContexts: <int>[
          134,
          195,
          135,
          196,
          136,
          197,
          248,
          249,
          250,
          252,
        ],
        bypassCount: 3,
      );
    });

    test('CBF distinguishes missing block from missing macroblock', () {
      final bins = _ScriptedBins(decisions: <int>[0]);
      final block = _decoder(H264CabacSliceType.i, bins).decodeResidualBlock(
        category: CabacResidualCategory.luma4x4,
        currentMacroblockIntra: true,
        left: const CabacCodedBlockNeighbor.blockUnavailable(),
      );

      expect(block.coded, isFalse);
      // Left existing-MB/missing-block contributes zero; absent top MB uses
      // the intra boundary default and contributes two.
      bins.expectComplete(decisionContexts: <int>[95]);
    });
  });

  test('frame-state-free macroblock handoff retains reconstruction inputs', () {
    final residual = CabacMacroblockResidualSyntax(
      luma: <CabacResidualBlock>[
        CabacResidualBlock(
          category: CabacResidualCategory.luma4x4,
          coded: true,
          coefficients: <int>[1, 0, -2, ...List<int>.filled(13, 0)],
        ),
      ],
      chromaCb: <CabacResidualBlock>[],
      chromaCr: <CabacResidualBlock>[],
    );
    final macroblock = CabacDecodedMacroblock(
      address: 17,
      type: CabacMacroblockType.fromCode(
        sliceType: H264CabacSliceType.b,
        codeNum: 3,
      ),
      skipped: false,
      partitions: const <CabacInterPartitionSyntax>[
        CabacInterPartitionSyntax(
          partitionIndex: 0,
          usesList0: true,
          usesList1: true,
          referenceIndexL0: 0,
          referenceIndexL1: 1,
          mvdL0: CabacMotionVectorDifference(horizontal: 2, vertical: -1),
          mvdL1: CabacMotionVectorDifference(horizontal: 0, vertical: 3),
        ),
      ],
      intra: null,
      transformSize8x8: false,
      codedBlockPattern: const CabacCodedBlockPattern(luma: 1, chroma: 0),
      qpDelta: -1,
      residual: residual,
    );

    expect(macroblock.address, 17);
    expect(macroblock.partitions.single.referenceIndexL1, 1);
    expect(macroblock.residual.totalCoefficients, 2);
    expect(macroblock.direct, isFalse);
  });
}

H264CabacSliceDataDecoder _decoder(
  H264CabacSliceType type,
  _ScriptedBins bins,
) => H264CabacSliceDataDecoder(sliceType: type, bins: bins);

final class _ScriptedBins implements CabacSyntaxBinReader {
  _ScriptedBins({
    List<int> decisions = const <int>[],
    List<int> bypasses = const <int>[],
    List<int> terminates = const <int>[],
  }) : _decisions = Queue<int>.of(decisions),
       _bypasses = Queue<int>.of(bypasses),
       _terminates = Queue<int>.of(terminates);

  final Queue<int> _decisions;
  final Queue<int> _bypasses;
  final Queue<int> _terminates;
  final List<int> decisionContexts = <int>[];
  var bypassCount = 0;
  var terminateCount = 0;

  @override
  int decodeDecision(int contextIndex) {
    decisionContexts.add(contextIndex);
    if (_decisions.isEmpty) {
      throw StateError('unexpected decision ctxIdx=$contextIndex');
    }
    return _decisions.removeFirst();
  }

  @override
  int decodeBypass() {
    bypassCount++;
    if (_bypasses.isEmpty) throw StateError('unexpected bypass bin');
    return _bypasses.removeFirst();
  }

  @override
  int decodeTerminate() {
    terminateCount++;
    if (_terminates.isEmpty) throw StateError('unexpected terminate bin');
    return _terminates.removeFirst();
  }

  void expectComplete({
    List<int> decisionContexts = const <int>[],
    int bypassCount = 0,
    int terminateCount = 0,
  }) {
    expect(this.decisionContexts, decisionContexts);
    expect(this.bypassCount, bypassCount);
    expect(this.terminateCount, terminateCount);
    expect(_decisions, isEmpty, reason: 'unused decision bins');
    expect(_bypasses, isEmpty, reason: 'unused bypass bins');
    expect(_terminates, isEmpty, reason: 'unused terminate bins');
  }
}

BitReader _bitReader(String bits) {
  final bytes = Uint8List((bits.length + 7) >> 3);
  for (var index = 0; index < bits.length; index++) {
    if (bits.codeUnitAt(index) == 0x31) {
      bytes[index >> 3] |= 1 << (7 - (index & 7));
    }
  }
  return BitReader(bytes, bitLength: bits.length);
}
