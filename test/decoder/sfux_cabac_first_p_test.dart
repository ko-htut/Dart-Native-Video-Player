import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

void main() {
  test('decodes the exact sfux first P picture as 3510 P_Skip MBs', () {
    // Exact compact P VCL extracted from 250_00000.ts. FFmpeg independently
    // reconstructs this picture as uniform Y=32, Cb=Cr=127. The preceding
    // IDR is Y=16, and this header's explicit +16 luma offset accounts for
    // that result without any coded partition, MVD, or residual syntax.
    final sps = parseSpsNal(
      _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
    );
    final pps = parsePpsNal(
      _hex('68e9b9cb22c0'),
      chromaFormatIdc: sps.chromaFormatIdc,
    );
    final header = parseSliceHeader(
      _hex(
        '419a226e810108fffa580000030000030000030000030000030000030000030000030356',
      ),
      ppsById: <int, PpsInfo>{pps.ppsId: pps},
      spsById: <int, SpsInfo>{sps.spsId: sps},
    );

    expect(header.firstMbInSlice, 0);
    expect(header.sliceType, H264SliceType.p);
    expect(header.frameNum, 1);
    expect(header.picOrderCntLsb, 4);
    expect(header.sliceQpY, 17);
    expect(header.cabacInitIdc, 0);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 1);
    expect(header.dataBitOffset, 52);
    expect(header.reader.bitLength, 216);
    final weights = header.predictionWeightTable!;
    expect(weights.lumaLog2WeightDenom, 0);
    expect(weights.list0.single.lumaWeight, 1);
    expect(weights.list0.single.lumaOffset, 16);
    expect(weights.list0.single.chromaWeights, <int>[1, 1]);
    expect(weights.list0.single.chromaOffsets, <int>[0, 0]);
    expect(16 * weights.list0.single.lumaWeight + 16, 32);
    expect(127 * weights.list0.single.chromaWeights.first, 127);

    expect(readCabacAlignmentOneBits(header.reader), 4);
    expect(header.reader.bitPos, 56);
    final arithmetic = H264CabacDecoder.initialize(header.reader);
    expect(arithmetic.offset, 500);
    expect(arithmetic.bitPosition, 65);
    final syntax = H264CabacSliceDataDecoder.fromArithmetic(
      decoder: arithmetic,
      contexts: H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.p,
        sliceQpY: header.sliceQpY,
        cabacInitIdc: header.cabacInitIdc!,
      ),
    );

    const widthInMacroblocks = 78;
    const heightInMacroblocks = 45;
    const macroblockCount = widthInMacroblocks * heightInMacroblocks;
    final states = List<CabacMacroblockNeighbor?>.filled(macroblockCount, null);
    var skippedMacroblocks = 0;
    var inferredSkipPartitions = 0;
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
        inferredSkipPartitions++;
        expect(start.type.kind, CabacMacroblockKind.skip);
        expect(start.type.sliceType, H264CabacSliceType.p);
        states[address] = const CabacMacroblockNeighbor(skipped: true);
      } else {
        // These remain explicit counters so this regression proves the
        // absence of every downstream syntax family, rather than merely not
        // calling those decoders accidentally.
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
    expect(inferredSkipPartitions, 3510);
    expect(explicitMbTypes, 0);
    expect(explicitPartitions, 0);
    expect(referenceIndexSyntaxCount, 0);
    expect(mvdSyntaxCount, 0);
    expect(transform8x8SyntaxCount, 0);
    expect(residualBlockSyntaxCount, 0);
    expect(finalMacroblockAddress, 3509);
    expect(firstSkipBitPosition, 66);
    expect(firstSkipRange, 350);
    expect(firstSkipOffset, 331);
    expect(firstEndBitPosition, 66);
    expect(arithmetic.isTerminated, isTrue);
    expect(arithmetic.bitPosition, 215);
    expect(arithmetic.range, 427);
    expect(arithmetic.offset, 427);
    expect(header.reader.peekBitsStr(header.reader.bitsLeft), '0');
  });
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
