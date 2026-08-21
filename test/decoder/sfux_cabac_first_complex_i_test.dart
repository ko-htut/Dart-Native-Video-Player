import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

const _blockX = <int>[0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3];
const _blockY = <int>[0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3];

void main() {
  test('decodes the first complex sfux I picture through termination', () {
    // Exact fourth decode-order picture from 250_00000.ts: after IDR POC 0,
    // P POC 4, and B POC 2. This non-IDR I picture is presented at POC 6.
    // Independent FFmpeg cropped-I420 SHA-256 (first luma byte is 38):
    // 73e0d49ef1d4887bfe605a2a3f6ac4c11e9f60581d9f3c944ccbe56d183a7be0
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '418890c0bffed469f32ca27368115265a2d6f7edd518142f837196656b52000003000003000003000003003308f90b4bf88aab8a9000000300000fc00018e0003d8a17a001040003f00015000085000348001e2000e1000880006880044000000300000300000301b93ceee05530acfff671c7ec000ded800026e2a0000003000026c0bcdf815074023214bb7216cc2800a25927353a874219353d2c2f7000002799a0f70a000dab9ddd8c9ef00006952d2b7e977400023f3502c074bfd9018cfb2212a80000bb4a62baa5d90e9bb13c0001bf0087f335b0ed55c800000300000300000300000300000300000300000300000300000300000300000300000300000300000300000300000300000300000300000300016f',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(vcl, hasLength(279));
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.sliceType, H264SliceType.i);
    expect(header.frameNum, 2);
    expect(header.picOrderCntLsb, 6);
    expect(header.sliceQpY, 14);
    expect(header.dataBitOffset, 32);
    expect(header.reader.bitLength, 2000);
    expect(pps.transform8x8ModeFlag, isTrue);
    final alignment = readCabacAlignmentOneBits(header.reader);
    expect(alignment, 0);
    expect(header.reader.bitPos, 32);
    final arithmetic = H264CabacDecoder.initialize(header.reader);
    expect(arithmetic.startBitPosition, 32);
    expect(arithmetic.bitPosition, 41);
    expect(arithmetic.range, 510);
    expect(arithmetic.offset, 509);
    final syntax = H264CabacSliceDataDecoder.fromArithmetic(
      decoder: arithmetic,
      contexts: H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.i,
        sliceQpY: header.sliceQpY,
      ),
    );
    const width = 78;
    const count = 3510;
    final states = List<_Mb?>.filled(count, null);
    final types = <int, int>{};
    final cbps = <int, int>{};
    final qpDeltas = <int, int>{};
    final nonzeroQpDeltas = <int, int>{};
    final nxnAddresses = <int>[];
    final transform8Addresses = <int>[];
    final chromaModes = <int, int>{};
    var intra8Predicted = 0;
    var intra8Remaining = 0;
    final lumaDcFootprint = <int, List<int>>{};
    final cbDcFootprint = <int, List<int>>{};
    final crDcFootprint = <int, List<int>>{};
    var nxn = 0;
    var i16 = 0;
    var transform8 = 0;
    var lumaCodedBlocks = 0;
    var cbCodedBlocks = 0;
    var crCodedBlocks = 0;
    var lumaCoefficients = 0;
    var cbCoefficients = 0;
    var crCoefficients = 0;
    var eosAddress = -1;

    for (var address = 0; address < count; address++) {
      final x = address % width;
      final y = address ~/ width;
      final left = x == 0 ? null : states[address - 1];
      final top = y == 0 ? null : states[address - width];
      final neighbors = CabacMacroblockNeighbors(
        left: left?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
        top: top?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
      );
      final type = syntax.decodeMbType(neighbors: neighbors);
      final code = type.codeNum!;
      types[code] = (types[code] ?? 0) + 1;
      if (type.kind == CabacMacroblockKind.pcm) {
        fail('PCM at $address is not supported by probe');
      }
      final isI16 = type.kind == CabacMacroblockKind.intra16x16;
      final isNxn = type.kind == CabacMacroblockKind.intraNxN;
      expect(isI16 || isNxn, isTrue, reason: 'mb=$address type=$code');
      if (isI16) i16++;
      if (isNxn) {
        nxn++;
        nxnAddresses.add(address);
      }

      var use8 = false;
      if (isNxn && pps.transform8x8ModeFlag) {
        use8 = syntax.decodeTransformSize8x8Flag(neighbors: neighbors);
      }
      if (use8) {
        transform8++;
        transform8Addresses.add(address);
      }
      if (isNxn) {
        for (var block = 0; block < (use8 ? 4 : 16); block++) {
          if (use8) {
            final mode = syntax.decodeIntra8x8Mode();
            if (mode.usesPredictedMode) {
              intra8Predicted++;
            } else {
              intra8Remaining++;
            }
          } else {
            syntax.decodeIntra4x4Mode();
          }
        }
      }
      final chromaMode = syntax.decodeIntraChromaPredictionMode(
        neighbors: neighbors,
      );
      chromaModes[chromaMode] = (chromaModes[chromaMode] ?? 0) + 1;
      final cbp = isI16
          ? type.intra16x16CodedBlockPattern!
          : syntax.decodeCodedBlockPattern(neighbors: neighbors);
      cbps[cbp.packed] = (cbps[cbp.packed] ?? 0) + 1;
      var qpDelta = 0;
      if (isI16 || cbp.packed != 0) {
        qpDelta = syntax.decodeMbQpDelta();
      } else {
        syntax.noteMacroblockWithoutQpDelta();
      }
      qpDeltas[qpDelta] = (qpDeltas[qpDelta] ?? 0) + 1;
      if (qpDelta != 0) nonzeroQpDeltas[address] = qpDelta;

      final state = _Mb(
        neighbor: CabacMacroblockNeighbor(
          intra16x16: isI16,
          codedBlockPatternLuma: cbp.luma,
          codedBlockPatternChroma: cbp.chroma,
          intraChromaPredictionMode: chromaMode,
          transformSize8x8: use8,
        ),
        isI16: isI16,
        transform8: use8,
      );

      if (isI16) {
        final dc = syntax.decodeResidualBlock(
          category: CabacResidualCategory.lumaDc16x16,
          currentMacroblockIntra: true,
          left: _lumaDc(left),
          top: _lumaDc(top),
        );
        state.lumaDcCoded = dc.coded;
        lumaCodedBlocks += dc.coded ? 1 : 0;
        lumaCoefficients += dc.totalCoefficients;
        if (dc.coded) {
          lumaDcFootprint[address] = dc.coefficients;
        }
      }

      if (cbp.luma != 0) {
        if (use8) {
          for (var group = 0; group < 4; group++) {
            if ((cbp.luma & (1 << group)) == 0) continue;
            final block = syntax.decodeResidualBlock(
              category: CabacResidualCategory.luma8x8,
              currentMacroblockIntra: true,
              codedBlockFlagPresent: false,
            );
            state.luma8x8Coded[group] = block.coded;
            lumaCodedBlocks += block.coded ? 1 : 0;
            lumaCoefficients += block.totalCoefficients;
            if (block.coded) {
              fail(
                'Unexpected coded luma8x8 block at mb=$address group=$group',
              );
            }
          }
        } else {
          final category = isI16
              ? CabacResidualCategory.lumaAc16x16
              : CabacResidualCategory.luma4x4;
          for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
            final group = syntaxBlock >> 2;
            if ((cbp.luma & (1 << group)) == 0) continue;
            final bx = _blockX[syntaxBlock];
            final by = _blockY[syntaxBlock];
            final block = syntax.decodeResidualBlock(
              category: category,
              currentMacroblockIntra: true,
              left: bx > 0
                  ? _lumaBlock(state, bx - 1, by, isI16: isI16)
                  : _lumaBlock(left, 3, by, isI16: isI16),
              top: by > 0
                  ? _lumaBlock(state, bx, by - 1, isI16: isI16)
                  : _lumaBlock(top, bx, 3, isI16: isI16),
            );
            final raster = by * 4 + bx;
            state.lumaCoded[raster] = block.coded;
            lumaCodedBlocks += block.coded ? 1 : 0;
            lumaCoefficients += block.totalCoefficients;
            if (block.coded) {
              fail(
                'Unexpected coded ${isI16 ? 'I16 AC' : 'luma4x4'} block '
                'at mb=$address raster=$raster',
              );
            }
          }
        }
      }

      if (cbp.chroma != 0) {
        final cbDc = syntax.decodeResidualBlock(
          category: CabacResidualCategory.chromaDc420,
          currentMacroblockIntra: true,
          left: _chromaDc(left, cb: true),
          top: _chromaDc(top, cb: true),
        );
        final crDc = syntax.decodeResidualBlock(
          category: CabacResidualCategory.chromaDc420,
          currentMacroblockIntra: true,
          left: _chromaDc(left, cb: false),
          top: _chromaDc(top, cb: false),
        );
        state.cbDcCoded = cbDc.coded;
        state.crDcCoded = crDc.coded;
        cbCodedBlocks += cbDc.coded ? 1 : 0;
        crCodedBlocks += crDc.coded ? 1 : 0;
        cbCoefficients += cbDc.totalCoefficients;
        crCoefficients += crDc.totalCoefficients;
        if (cbDc.coded) {
          cbDcFootprint[address] = cbDc.coefficients;
        }
        if (crDc.coded) {
          crDcFootprint[address] = crDc.coefficients;
        }
      }
      if (cbp.chroma == 2) {
        for (var plane = 0; plane < 2; plane++) {
          for (var blockIndex = 0; blockIndex < 4; blockIndex++) {
            final bx = blockIndex & 1;
            final by = blockIndex >> 1;
            final block = syntax.decodeResidualBlock(
              category: CabacResidualCategory.chromaAc420,
              currentMacroblockIntra: true,
              left: bx > 0
                  ? _chromaAc(state, blockIndex - 1, cb: plane == 0)
                  : _chromaAc(left, by * 2 + 1, cb: plane == 0),
              top: by > 0
                  ? _chromaAc(state, blockIndex - 2, cb: plane == 0)
                  : _chromaAc(top, blockIndex + 2, cb: plane == 0),
            );
            final target = plane == 0 ? state.cbCoded : state.crCoded;
            target[blockIndex] = block.coded;
            if (plane == 0) {
              cbCodedBlocks += block.coded ? 1 : 0;
              cbCoefficients += block.totalCoefficients;
            } else {
              crCodedBlocks += block.coded ? 1 : 0;
              crCoefficients += block.totalCoefficients;
            }
            if (block.coded) {
              fail(
                'Unexpected coded ${plane == 0 ? 'Cb' : 'Cr'} AC block '
                'at mb=$address block=$blockIndex',
              );
            }
          }
        }
      }
      states[address] = state;
      if (syntax.decodeEndOfSliceFlag()) {
        eosAddress = address;
        break;
      }
    }

    expect(eosAddress, 3509);
    expect(types, <int, int>{7: 1, 3: 77, 1: 3416, 2: 14, 0: 2});
    expect(i16, 3508);
    expect(nxn, 2);
    expect(nxnAddresses, <int>[1350, 1656]);
    expect(transform8, 2);
    expect(transform8Addresses, <int>[1350, 1656]);
    expect(intra8Predicted, 3);
    expect(intra8Remaining, 5);
    expect(chromaModes, <int, int>{0: 3510});
    expect(cbps, <int, int>{16: 1, 0: 3509});
    expect(qpDeltas, <int, int>{
      0: 3485,
      -4: 1,
      5: 1,
      -2: 7,
      14: 1,
      -9: 3,
      3: 2,
      2: 1,
      8: 1,
      -10: 2,
      10: 1,
      -12: 1,
      11: 2,
      -8: 1,
      18: 1,
    });
    expect(nonzeroQpDeltas, <int, int>{
      319: -4,
      1344: 5,
      1352: -2,
      1404: -2,
      1480: -2,
      1654: 14,
      1655: -9,
      1661: -2,
      1664: 3,
      1704: -2,
      1734: 2,
      1740: 8,
      1741: -10,
      1895: 10,
      1896: -12,
      1973: 3,
      1976: -2,
      2049: 11,
      2050: -9,
      2053: -2,
      2129: 11,
      2130: -10,
      2205: -8,
      2206: 18,
      2207: -9,
    });

    // Only I_16x16 luma DC and macroblock-zero chroma DC are coded. The
    // coefficient arrays below remain in CABAC scan order, not raster order.
    expect(lumaCodedBlocks, 16);
    expect(cbCodedBlocks, 1);
    expect(crCodedBlocks, 1);
    expect(lumaCoefficients, 34);
    expect(cbCoefficients, 1);
    expect(crCoefficients, 1);
    expect(lumaDcFootprint, <int, List<int>>{
      0: _dc16(<int>[-443]),
      1344: _dc16(<int>[9]),
      1654: _dc16(<int>[2, 2]),
      1664: _dc16(<int>[9]),
      1734: _dc16(<int>[5, 5]),
      1740: _dc16(<int>[-2, 2]),
      1818: _dc16(<int>[-6, -6]),
      1895: _dc16(<int>[-1, 1, 1, 0, -1]),
      1973: _dc16(<int>[-5, -5]),
      2049: _dc16(<int>[-1, 1, 1, 0, -1]),
      2050: _dc16(<int>[-5, 0, -5]),
      2052: _dc16(<int>[10]),
      2129: _dc16(<int>[3, 1, 1, 0, -1]),
      2130: _dc16(<int>[-6, 0, -6]),
      2206: _dc16(<int>[2, 0, 2]),
      2207: _dc16(<int>[-5, -5]),
    });
    expect(cbDcFootprint, <int, List<int>>{
      0: <int>[-2, 0, 0, 0],
    });
    expect(crDcFootprint, <int, List<int>>{
      0: <int>[-2, 0, 0, 0],
    });

    expect(arithmetic.isTerminated, isTrue);
    expect(arithmetic.bitPosition, 2000);
    expect(arithmetic.range, 367);
    expect(arithmetic.offset, 367);
    expect(header.reader.bitsLeft, 0);
  });
}

final class _Mb {
  _Mb({required this.neighbor, required this.isI16, required this.transform8});
  final CabacMacroblockNeighbor neighbor;
  final bool isI16;
  final bool transform8;
  bool lumaDcCoded = false;
  bool cbDcCoded = false;
  bool crDcCoded = false;
  final lumaCoded = List<bool>.filled(16, false);
  final luma8x8Coded = List<bool>.filled(4, false);
  final cbCoded = List<bool>.filled(4, false);
  final crCoded = List<bool>.filled(4, false);
}

CabacCodedBlockNeighbor _lumaDc(_Mb? mb) {
  if (mb == null) return const CabacCodedBlockNeighbor.unavailable();
  if (!mb.isI16) return const CabacCodedBlockNeighbor.blockUnavailable();
  return CabacCodedBlockNeighbor(coded: mb.lumaDcCoded);
}

CabacCodedBlockNeighbor _lumaBlock(
  _Mb? mb,
  int bx,
  int by, {
  required bool isI16,
}) {
  if (mb == null) return const CabacCodedBlockNeighbor.unavailable();
  if (mb.isI16 != isI16 || mb.transform8) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  final group = ((by >> 1) << 1) | (bx >> 1);
  if ((mb.neighbor.codedBlockPatternLuma & (1 << group)) == 0) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  return CabacCodedBlockNeighbor(coded: mb.lumaCoded[by * 4 + bx]);
}

CabacCodedBlockNeighbor _chromaDc(_Mb? mb, {required bool cb}) {
  if (mb == null) return const CabacCodedBlockNeighbor.unavailable();
  if (mb.neighbor.codedBlockPatternChroma == 0) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  return CabacCodedBlockNeighbor(coded: cb ? mb.cbDcCoded : mb.crDcCoded);
}

CabacCodedBlockNeighbor _chromaAc(_Mb? mb, int block, {required bool cb}) {
  if (mb == null) return const CabacCodedBlockNeighbor.unavailable();
  if (mb.neighbor.codedBlockPatternChroma != 2) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  return CabacCodedBlockNeighbor(coded: (cb ? mb.cbCoded : mb.crCoded)[block]);
}

List<int> _dc16(List<int> prefix) => <int>[
  ...prefix,
  ...List<int>.filled(16 - prefix.length, 0),
];

Uint8List _bytes(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
