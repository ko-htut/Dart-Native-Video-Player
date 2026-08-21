import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/b_slice_motion.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/motion_compensation.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';
import 'package:ndvy_player/src/decoder/weighted_prediction.dart';

void main() {
  test('decodes the exact sfux first B picture as 3510 B_Skip MBs', () {
    // Exact compact B VCL extracted from 250_00000.ts. It is decoded after
    // IDR POC 0 and P POC 4, but presented between them at POC 2. FFmpeg's
    // uniform Y=24/Cb=Cr=127 output is the equal-weight Direct midpoint.
    final sps = parseSpsNal(
      _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
    );
    final pps = parsePpsNal(
      _hex('68e9b9cb22c0'),
      chromaFormatIdc: sps.chromaFormatIdc,
    );
    final header = parseSliceHeader(
      _hex('019e417908ff000003000003000003000003000003000003000003000004bd'),
      ppsById: <int, PpsInfo>{pps.ppsId: pps},
      spsById: <int, SpsInfo>{sps.spsId: sps},
    );

    expect(header.firstMbInSlice, 0);
    expect(header.sliceType, H264SliceType.b);
    expect(header.nalRefIdc, 0);
    expect(header.frameNum, 2);
    expect(header.picOrderCntLsb, 2);
    expect(header.directSpatialMvPredFlag, isTrue);
    expect(header.sliceQpY, 17);
    expect(header.cabacInitIdc, 0);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 1);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(header.dataBitOffset, 36);
    expect(header.reader.bitLength, 184);
    expect(pps.weightedBipredIdc, 2);
    expect(sps.direct8x8InferenceFlag, isTrue);

    expect(readCabacAlignmentOneBits(header.reader), 4);
    expect(header.reader.bitPos, 40);
    final arithmetic = H264CabacDecoder.initialize(header.reader);
    expect(arithmetic.offset, 0);
    expect(arithmetic.bitPosition, 49);
    final syntax = H264CabacSliceDataDecoder.fromArithmetic(
      decoder: arithmetic,
      contexts: H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.b,
        sliceQpY: header.sliceQpY,
        cabacInitIdc: header.cabacInitIdc!,
      ),
    );

    const widthInMacroblocks = 78;
    const heightInMacroblocks = 45;
    const macroblockCount = widthInMacroblocks * heightInMacroblocks;
    final states = List<CabacMacroblockNeighbor?>.filled(macroblockCount, null);
    var skippedMacroblocks = 0;
    var inferredDirect8x8Regions = 0;
    var explicitMbTypes = 0;
    var explicitPartitions = 0;
    var referenceIndexSyntaxCount = 0;
    var mvdSyntaxCount = 0;
    var transform8x8SyntaxCount = 0;
    var residualBlockSyntaxCount = 0;
    var finalMacroblockAddress = -1;
    var firstSkipBitPosition = -1;
    var firstSkipRange = -1;
    var firstSkipOffset = -1;
    var firstEndBitPosition = -1;

    final skippedType = H264BInterMacroblockType.skipped();
    expect(skippedType.skipped, isTrue);
    expect(skippedType.isDirect, isTrue);
    expect(skippedType.partitionCount, 4);
    expect(
      skippedType.directInferenceRegionsAt(
        macroblockX: 0,
        macroblockY: 0,
        direct8x8Inference: sps.direct8x8InferenceFlag,
      ),
      hasLength(4),
    );

    for (var address = 0; address < macroblockCount; address++) {
      final x = address % widthInMacroblocks;
      final y = address ~/ widthInMacroblocks;
      final neighbors = CabacMacroblockNeighbors(
        left: x == 0
            ? const CabacMacroblockNeighbor.unavailable()
            : states[address - 1]!,
        top: y == 0
            ? const CabacMacroblockNeighbor.unavailable()
            : states[address - widthInMacroblocks]!,
      );
      final start = syntax.decodeMacroblockStart(neighbors: neighbors);
      if (address == 0) {
        firstSkipBitPosition = arithmetic.bitPosition;
        firstSkipRange = arithmetic.range;
        firstSkipOffset = arithmetic.offset;
      }

      if (start.skipped) {
        skippedMacroblocks++;
        inferredDirect8x8Regions += 4;
        expect(start.type.kind, CabacMacroblockKind.skip);
        expect(start.type.sliceType, H264CabacSliceType.b);
        expect(start.direct, isTrue);
        // Both flags matter if a later non-skip mb_type/ref_idx context uses
        // this B_Skip macroblock as its available A or B neighbor.
        states[address] = const CabacMacroblockNeighbor(
          skipped: true,
          direct: true,
        );
      } else {
        explicitMbTypes++;
        explicitPartitions++;
        referenceIndexSyntaxCount++;
        mvdSyntaxCount++;
        transform8x8SyntaxCount++;
        residualBlockSyntaxCount++;
        fail('unexpected non-skip macroblock at address $address');
      }

      final endOfSlice = syntax.decodeEndOfSliceFlag();
      if (address == 0) firstEndBitPosition = arithmetic.bitPosition;
      if (endOfSlice) {
        finalMacroblockAddress = address;
        break;
      }
    }

    expect(skippedMacroblocks, 3510);
    expect(inferredDirect8x8Regions, 14040);
    expect(explicitMbTypes, 0);
    expect(explicitPartitions, 0);
    expect(referenceIndexSyntaxCount, 0);
    expect(mvdSyntaxCount, 0);
    expect(transform8x8SyntaxCount, 0);
    expect(residualBlockSyntaxCount, 0);
    expect(finalMacroblockAddress, 3509);
    expect(firstSkipBitPosition, 49);
    expect(firstSkipRange, 421);
    expect(firstSkipOffset, 0);
    expect(firstEndBitPosition, 49);
    expect(arithmetic.isTerminated, isTrue);
    expect(arithmetic.bitPosition, 182);
    expect(arithmetic.range, 303);
    expect(arithmetic.offset, 303);
    expect(header.reader.peekBitsStr(header.reader.bitsLeft), '01');

    // Cross-check the existing spatial-Direct and implicit-weight foundation:
    // at the unavailable top-left neighborhood, B_Skip resolves both short-
    // term list references to index zero and zero motion. POC 2 is exactly
    // halfway between IDR POC 0 and P POC 4.
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
          colocated: H264ColocatedMotion.inter(
            referenceIndex: 0,
            vector: MotionVector.zero,
          ),
          list1Reference0IsShortTerm: true,
        );
    expect(direct.effectiveMode, H264BPredictionMode.bi);
    expect(
      (direct.list0!.referenceIndex, direct.list1!.referenceIndex),
      (0, 0),
    );
    expect(direct.list0!.vector, MotionVector.zero);
    expect(direct.list1!.vector, MotionVector.zero);

    final weights = deriveImplicitBiPredictionWeights(
      currentPoc: header.picOrderCntLsb!,
      list0Poc: 0,
      list1Poc: 4,
    );
    expect((weights.list0Weight, weights.list1Weight), (32, 32));
    expect(
      implicitWeightedBiSample8(
        list0Sample: 16,
        list1Sample: 32,
        weights: weights,
      ),
      24,
    );
    expect(
      implicitWeightedBiSample8(
        list0Sample: 127,
        list1Sample: 127,
        weights: weights,
      ),
      127,
    );
  });
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
