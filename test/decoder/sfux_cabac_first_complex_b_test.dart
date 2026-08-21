import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

void main() {
  test('decodes the first complex sfux B picture through termination', () {
    // Exact sixth decode-order picture from 250_00000.ts: B POC 8 follows
    // the P POC 10 picture in decode order, but is presentation frame 5.
    // Independent FFmpeg cropped-I420 SHA-256:
    // 2cbe355edcd37f2ff8a4f305c3de8f233e5d730a664afbdd6c07718df4112abf
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '019e846e47ff000003000003000032f2b5cae5a30fcd3fcb5bfb026683243a1769a8f03d70b9da1832c3680ba6de8c81ec9151e093138352057069d3d3b52a49a8df2177be13a6fb2b23b44dcfa56a5f4f5a3128f21dcc34fd425af26787bfd8c1fae39202ee679e565c483898d53f4de20e0bd7199688098882880adfdf3b4c1470acd766cf9e93c4b36c454a23540485bf86d20a2bd40485bf86e44c055540485bf86e612268226c037a40c96a12268126c037a40c96a2ac1454a8090b7f0dcc5a8489a6fd8242dfc37316a2ac1a15',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );

    expect(vcl, hasLength(208));
    expect(header.reader.bitLength, 1640);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.nalRefIdc, 0);
    expect(header.firstMbInSlice, 0);
    expect(header.sliceType, H264SliceType.b);
    expect(header.frameNum, 4);
    expect(header.picOrderCntLsb, 8);
    expect(header.directSpatialMvPredFlag, isTrue);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 3);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(header.refPicListModificationsL0, isEmpty);
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.predictionWeightTable, isNull);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -7);
    expect(header.sliceQpY, 18);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.dataBitOffset, 36);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);

    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 4);
  expect(header.reader.bitPos, 40);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 40);
  expect(arithmetic.bitPosition, 49);
  expect(arithmetic.range, 510);
  expect(arithmetic.offset, 0);
  final syntax = H264CabacSliceDataDecoder.fromArithmetic(
    decoder: arithmetic,
    contexts: H264CabacContextSet.initialize(
      sliceType: H264CabacSliceType.b,
      sliceQpY: header.sliceQpY,
      cabacInitIdc: header.cabacInitIdc!,
    ),
  );

  const mbWidth = 78;
  const mbCount = 3510;
  final states = List<_Mb?>.filled(mbCount, null);
  final typeCounts = <int, int>{};
  final typeAddresses = <int, List<int>>{};
  final cbpCounts = <int, int>{};
  final qpDeltaCounts = <int, int>{};
  final chromaModes = <int, int>{};
  final transform8Addresses = <int>[];
  final residual = _ResidualSummary();
  var skippedDirect = 0;
  var intra8Predicted = 0;
  var intra8Remaining = 0;
  var macroblockHash = _fnvOffset;
  var intraModeHash = _fnvOffset;
  var eosAddress = -1;

  for (var address = 0; address < mbCount; address++) {
    final mbX = address % mbWidth;
    final mbY = address ~/ mbWidth;
    final left = mbX == 0 ? null : states[address - 1];
    final top = mbY == 0 ? null : states[address - mbWidth];
    final neighbors = CabacMacroblockNeighbors(
      left: left?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
      top: top?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
    );
    final start = syntax.decodeMacroblockStart(neighbors: neighbors);
    if (start.skipped) {
      expect(start.direct, isTrue);
      skippedDirect++;
      macroblockHash = _hashValues(macroblockHash, <int>[address, -1]);
      states[address] = _Mb(
        neighbor: const CabacMacroblockNeighbor(skipped: true, direct: true),
        isI16: false,
      );
      if (syntax.decodeEndOfSliceFlag()) {
        eosAddress = address;
        break;
      }
      continue;
    }

    final type = start.type;
    final code = type.codeNum!;
    expect(type.isIntra, isTrue, reason: 'mb=$address type=$code');
    expect(type.isDirect, isFalse, reason: 'mb=$address type=$code');
    macroblockHash = _hashValues(macroblockHash, <int>[address, code]);
    typeCounts[code] = (typeCounts[code] ?? 0) + 1;
    typeAddresses.putIfAbsent(code, () => <int>[]).add(address);

    final isI16 = type.kind == CabacMacroblockKind.intra16x16;
    final isNxn = type.kind == CabacMacroblockKind.intraNxN;
    expect(isI16 || isNxn, isTrue, reason: 'mb=$address type=$code');
    var transform8 = false;
    if (isNxn &&
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: pps.transform8x8ModeFlag,
          macroblockType: type,
        )) {
      transform8 = syntax.decodeTransformSize8x8Flag(neighbors: neighbors);
    }
    expect(isNxn && !transform8, isFalse, reason: 'mb=$address');
    if (transform8) transform8Addresses.add(address);

    if (isNxn) {
      for (var block = 0; block < 4; block++) {
        final mode = syntax.decodeIntra8x8Mode();
        if (mode.usesPredictedMode) {
          intra8Predicted++;
        } else {
          intra8Remaining++;
        }
        intraModeHash = _hashValues(intraModeHash, <int>[
          address,
          block,
          8,
          mode.usesPredictedMode ? 1 : 0,
          mode.remainingMode ?? -1,
        ]);
      }
    }
    final chromaMode = syntax.decodeIntraChromaPredictionMode(
      neighbors: neighbors,
    );
    chromaModes[chromaMode] = (chromaModes[chromaMode] ?? 0) + 1;
    final cbp = isI16
        ? type.intra16x16CodedBlockPattern!
        : syntax.decodeCodedBlockPattern(neighbors: neighbors);
    cbpCounts[cbp.packed] = (cbpCounts[cbp.packed] ?? 0) + 1;
    final qpDelta = syntax.decodeMbQpDelta();
    qpDeltaCounts[qpDelta] = (qpDeltaCounts[qpDelta] ?? 0) + 1;

    final state = _Mb(
      neighbor: CabacMacroblockNeighbor(
        intra16x16: isI16,
        codedBlockPatternLuma: cbp.luma,
        codedBlockPatternChroma: cbp.chroma,
        intraChromaPredictionMode: chromaMode,
        transformSize8x8: transform8,
      ),
      isI16: isI16,
    );
    if (isI16) {
      final block = syntax.decodeResidualBlock(
        category: CabacResidualCategory.lumaDc16x16,
        currentMacroblockIntra: true,
        left: _lumaDc(left),
        top: _lumaDc(top),
      );
      state.lumaDcCoded = block.coded;
      residual.add(address: address, blockIndex: 0, block: block);
    }
    if (cbp.luma != 0) {
      expect(transform8, isTrue, reason: 'mb=$address cbp=${cbp.packed}');
      for (var group = 0; group < 4; group++) {
        if ((cbp.luma & (1 << group)) == 0) continue;
        residual.add(
          address: address,
          blockIndex: group,
          block: syntax.decodeResidualBlock(
            category: CabacResidualCategory.luma8x8,
            currentMacroblockIntra: true,
            codedBlockFlagPresent: false,
          ),
        );
      }
    }
    expect(cbp.chroma, 0, reason: 'mb=$address');

    states[address] = state;
    if (syntax.decodeEndOfSliceFlag()) {
      eosAddress = address;
      break;
    }
  }

  // FFmpeg `-debug mb_type` independently reports 3239 inferred Direct
  // (`d`), 269 I_16x16 (`I`), and two I_8x8 (`i`) macroblocks.
  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect(skippedDirect, 3239);
  expect(typeCounts, <int, int>{25: 28, 24: 241, 23: 2});
  expect(typeAddresses[23], <int>[2129, 2282]);
  expect(macroblockHash.toRadixString(16), '-3d2fd9b6156ef46f');

  // There are no explicit B_Direct, inter partitions, reference indices, or
  // MVDs in this picture; every non-skip macroblock is intra coded.
  expect(chromaModes, <int, int>{0: 271});
  expect(transform8Addresses, <int>[2129, 2282]);
  expect(intra8Predicted, 6);
  expect(intra8Remaining, 2);
  expect(intraModeHash.toRadixString(16), '-46dd515fe9a083f6');
  expect(cbpCounts, <int, int>{0: 269, 1: 2});
  expect(qpDeltaCounts, <int, int>{0: 271});

  // Both I_8x8 macroblocks carry one DC-position coefficient in scan order;
  // all 269 I_16x16 luma-DC coded_block_flags are zero.
  expect(residual.codedBlocks, <String, int>{'luma8x8': 2});
  expect(residual.coefficients, <String, int>{'luma8x8': 2});
  expect(residual.footprint, <String>[
    '2129:luma8x8:0:0:-2',
    '2282:luma8x8:0:0:1',
  ]);

  expect(arithmetic.isTerminated, isTrue);
  expect(arithmetic.bitPosition, 1638);
  expect(arithmetic.range, 437);
  expect(arithmetic.offset, 437);
  expect(header.reader.bitsLeft, 2);
}

final class _Mb {
  _Mb({required this.neighbor, required this.isI16});

  final CabacMacroblockNeighbor neighbor;
  final bool isI16;
  bool lumaDcCoded = false;
}

final class _ResidualSummary {
  final codedBlocks = <String, int>{};
  final coefficients = <String, int>{};
  final footprint = <String>[];

  void add({
    required int address,
    required int blockIndex,
    required CabacResidualBlock block,
  }) {
    if (!block.coded) return;
    final key = block.category.name;
    codedBlocks[key] = (codedBlocks[key] ?? 0) + 1;
    coefficients[key] = (coefficients[key] ?? 0) + block.totalCoefficients;
    final nonzero = <String>[];
    for (var index = 0; index < block.coefficients.length; index++) {
      final value = block.coefficients[index];
      if (value != 0) nonzero.add('$index:$value');
    }
    footprint.add('$address:$key:$blockIndex:${nonzero.join(',')}');
  }
}

CabacCodedBlockNeighbor _lumaDc(_Mb? mb) {
  if (mb == null) return const CabacCodedBlockNeighbor.unavailable();
  if (!mb.isI16) return const CabacCodedBlockNeighbor.blockUnavailable();
  return CabacCodedBlockNeighbor(coded: mb.lumaDcCoded);
}

const _fnvOffset = 0xcbf29ce484222325;
const _fnvPrime = 0x100000001b3;
const _mask64 = 0xffffffffffffffff;

int _hashValues(int hash, List<int> values) {
  var output = hash;
  for (final value in values) {
    output = ((output ^ (value & 0xffffffff)) * _fnvPrime) & _mask64;
  }
  return output;
}

Uint8List _bytes(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
