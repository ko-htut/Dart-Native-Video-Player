import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

void main() {
  test('decodes all 3510 CABAC macroblocks in the exact sfux first IDR', () {
    // Extracted without modification from 250_00000.ts at
    // sfux-ext.sfux.info/hls/chapter/105/1588724110 on 2026-08-20.
    final sps = parseSpsNal(
      _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
    );
    final pps = parsePpsNal(
      _hex('68e9b9cb22c0'),
      chromaFormatIdc: sps.chromaFormatIdc,
    );
    final header = parseSliceHeader(
      _hex(
        '6588840037fffedb5bf32cadd193c46d4b1c85777972cd4ee8ca19da792f53300000030000030000030000030086bdc12f77f11557152000000300001fc0002a60005f40013300055c001920009d0003e8002380010d000b600068800440000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003000003001011',
      ),
      ppsById: <int, PpsInfo>{pps.ppsId: pps},
      spsById: <int, SpsInfo>{sps.spsId: sps},
    );

    expect(header.firstMbInSlice, 0);
    expect(header.sliceType, H264SliceType.i);
    expect(header.sliceQpY, 12);
    expect(header.dataBitOffset, 34);
    expect(header.reader.bitLength, 1320);
    expect(readCabacAlignmentOneBits(header.reader), 6);
    expect(header.reader.bitPos, 40);

    final arithmetic = H264CabacDecoder.initialize(header.reader);
    expect(arithmetic.offset, 509);
    expect(arithmetic.bitPosition, 49);
    final syntax = H264CabacSliceDataDecoder.fromArithmetic(
      decoder: arithmetic,
      contexts: H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.i,
        sliceQpY: header.sliceQpY,
      ),
    );

    const widthInMacroblocks = 78;
    const heightInMacroblocks = 45;
    const macroblockCount = widthInMacroblocks * heightInMacroblocks;
    final states = List<_IdrMacroblockState?>.filled(macroblockCount, null);
    final typeCounts = <int, int>{};
    var codedLumaDcCount = 0;
    var codedChromaDcCount = 0;
    var nonzeroQpDeltaCount = 0;
    var firstMbTypeEnd = -1;
    var finalMacroblockAddress = -1;
    List<int>? firstLumaDc;
    List<int>? firstCbDc;
    List<int>? firstCrDc;

    for (var address = 0; address < macroblockCount; address++) {
      final x = address % widthInMacroblocks;
      final y = address ~/ widthInMacroblocks;
      final left = x == 0 ? null : states[address - 1];
      final top = y == 0 ? null : states[address - widthInMacroblocks];
      final neighbors = CabacMacroblockNeighbors(
        left: left?.macroblock ?? const CabacMacroblockNeighbor.unavailable(),
        top: top?.macroblock ?? const CabacMacroblockNeighbor.unavailable(),
      );

      final type = syntax.decodeMbType(neighbors: neighbors);
      if (address == 0) firstMbTypeEnd = arithmetic.bitPosition;
      expect(type.kind, CabacMacroblockKind.intra16x16, reason: 'mb=$address');
      final code = type.codeNum!;
      typeCounts[code] = (typeCounts[code] ?? 0) + 1;
      final intraCode = code - 1;
      final lumaCbp = intraCode >= 12 ? 15 : 0;
      final chromaCbp = (intraCode % 12) ~/ 4;

      final chromaMode = syntax.decodeIntraChromaPredictionMode(
        neighbors: neighbors,
      );
      if (syntax.decodeMbQpDelta() != 0) nonzeroQpDeltaCount++;
      final lumaDc = syntax.decodeResidualBlock(
        category: CabacResidualCategory.lumaDc16x16,
        currentMacroblockIntra: true,
        left: _codedNeighbor(left?.lumaDc),
        top: _codedNeighbor(top?.lumaDc),
      );
      if (lumaDc.coded) {
        codedLumaDcCount++;
        firstLumaDc ??= lumaDc.coefficients;
      }

      var cbDc = false;
      var crDc = false;
      if (chromaCbp != 0) {
        final cbBlock = syntax.decodeResidualBlock(
          category: CabacResidualCategory.chromaDc420,
          currentMacroblockIntra: true,
          left: _codedNeighbor(left?.cbDc),
          top: _codedNeighbor(top?.cbDc),
        );
        final crBlock = syntax.decodeResidualBlock(
          category: CabacResidualCategory.chromaDc420,
          currentMacroblockIntra: true,
          left: _codedNeighbor(left?.crDc),
          top: _codedNeighbor(top?.crDc),
        );
        cbDc = cbBlock.coded;
        crDc = crBlock.coded;
        if (cbDc) {
          codedChromaDcCount++;
          firstCbDc ??= cbBlock.coefficients;
        }
        if (crDc) {
          codedChromaDcCount++;
          firstCrDc ??= crBlock.coefficients;
        }
      }
      // Every sfux IDR mb_type in this fixture has CodedBlockPatternLuma=0
      // and CodedBlockPatternChroma<=1, so no AC block syntax is present.
      expect(lumaCbp, 0, reason: 'mb=$address');
      expect(chromaCbp, lessThanOrEqualTo(1), reason: 'mb=$address');

      states[address] = _IdrMacroblockState(
        macroblock: CabacMacroblockNeighbor(
          intra16x16: true,
          codedBlockPatternLuma: lumaCbp,
          codedBlockPatternChroma: chromaCbp,
          intraChromaPredictionMode: chromaMode,
        ),
        lumaDc: lumaDc.coded,
        cbDc: cbDc,
        crDc: crDc,
      );

      if (syntax.decodeEndOfSliceFlag()) {
        finalMacroblockAddress = address;
        break;
      }
    }

    // These values independently agree with FFmpeg's decoded constant frame:
    // Y=16 and Cb/Cr=127 across the full 1248x720 coded picture.
    expect(firstMbTypeEnd, 61);
    expect(finalMacroblockAddress, 3509);
    expect(typeCounts, <int, int>{7: 1, 3: 77, 1: 3432});
    expect(nonzeroQpDeltaCount, 0);
    expect(codedLumaDcCount, 1);
    expect(codedChromaDcCount, 2);
    expect(firstLumaDc, <int>[-717, ...List<int>.filled(15, 0)]);
    expect(firstCbDc, <int>[-3, 0, 0, 0]);
    expect(firstCrDc, <int>[-3, 0, 0, 0]);
    expect(arithmetic.isTerminated, isTrue);
    expect(arithmetic.bitPosition, 1316);
    expect(arithmetic.range, 256);
    expect(arithmetic.offset, 257);
    expect(header.reader.peekBitsStr(header.reader.bitsLeft), '0001');
  });
}

final class _IdrMacroblockState {
  const _IdrMacroblockState({
    required this.macroblock,
    required this.lumaDc,
    required this.cbDc,
    required this.crDc,
  });

  final CabacMacroblockNeighbor macroblock;
  final bool lumaDc;
  final bool cbDc;
  final bool crDc;
}

CabacCodedBlockNeighbor _codedNeighbor(bool? coded) => coded == null
    ? const CabacCodedBlockNeighbor.unavailable()
    : CabacCodedBlockNeighbor(coded: coded);

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
