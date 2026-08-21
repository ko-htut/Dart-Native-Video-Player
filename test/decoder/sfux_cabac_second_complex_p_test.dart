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
  test('decodes the second complex sfux P picture through termination', () {
    // Exact seventh decode-order picture from 250_00000.ts: P POC 16 is
    // presentation frame 9 after B pictures POC 12 and 14. Independent
    // FFmpeg cropped-I420 SHA-256:
    // 70ce91b2048835539d94b60cfd68ad17c8bbdfe10cf1fee4666bd851e622951d
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419a883c21087e43e0288215200ff80a21c0042bfffde10000e8fa387c5dcea723b039a0926d9e4aa83f1b4158361c480028597c724022031180000005adcae17896424945f894c99f64500945c7170b335a0980d5b77d45aeb01dc0cc8744f926fe77346673bcb551d71c51280234a7d32cb48ddd7699369292dc3400eaa8febc7ff7ba20aefe8c8225f62594ae9b7bd9796118c6801fcb0dd7fceb4cacbd3eaa26dea79db93e2e887bb4a1687560004ceec60fa1f65fda445992a2527a331b19dbd547a791e7475342cc5aa3560ca2d7c84adce8bd3e84684e8090043659d4532f740750499f6a1dd717960eeba6c90f7d77fdb5f44bf7a1d659e5dd65e8cd90c8034f11c0f02bdfb94cf2640c7dd1a0b0f2ae000d4c82ef6c48942bf915685bca85052c57dee659e10e7c9cd2b45b4a5a0e5b9692e2d83d7173efa8a9ab3d807651fa14dac2e1859557130b87237676a447d0e6058fcd3f2a6567c8774f09ab9da102d3002c5ddce99c1e5a74c17dcd5e53a0310d7bdd52383e428b1fef8dfa5a7f3be6f6d222e5d44c39205e9ff8d11a09e432c3cbc3622968c30540000003000195',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(vcl, hasLength(420));
    expect(header.reader.bitLength, 3344);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.p);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 4);
    expect(header.picOrderCntLsb, 16);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 6);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(
      header.refPicListModificationsL0.map(
        (modification) => (modification.idc, modification.value),
      ),
      <(int, int)>[(0, 0), (0, 15), (0, 15), (0, 0), (0, 0), (0, 0)],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -10);
    expect(header.sliceQpY, 15);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.dataBitOffset, 154);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);

    // Repeated list modification creates logical L0
    // [PicNum 3, 3, 3, 2, 1, 0] from only four distinct DPB pictures.
    final weights = header.predictionWeightTable!;
    expect(weights.lumaLog2WeightDenom, 6);
    expect(weights.chromaLog2WeightDenom, 0);
    expect(
      weights.list0
          .map(
            (weight) => (
              weight.lumaWeight,
              weight.lumaOffset,
              weight.chromaWeights.join(','),
              weight.chromaOffsets.join(','),
            ),
          )
          .toList(),
      <(int, int, String, String)>[
        (81, 8, '1,2', '0,-127'),
        (81, 7, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
      ],
    );
    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 6);
  expect(header.reader.bitPos, 160);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 160);
  expect(arithmetic.bitPosition, 169);
  expect(arithmetic.range, 510);
  expect(arithmetic.offset, 507);
  final syntax = H264CabacSliceDataDecoder.fromArithmetic(
    decoder: arithmetic,
    contexts: H264CabacContextSet.initialize(
      sliceType: H264CabacSliceType.p,
      sliceQpY: header.sliceQpY,
      cabacInitIdc: header.cabacInitIdc!,
    ),
  );
  const mbWidth = 78;
  const mbCount = 3510;
  final states = List<_Mb?>.filled(mbCount, null);
  final motion = _SyntaxMotionGrid(width4: mbWidth * 4, height4: 45 * 4);
  final typeCounts = <int, int>{};
  final typeAddresses = <int, List<int>>{};
  final subTypeCounts = <int, int>{};
  final referenceCounts = <int, int>{};
  final mvdCounts = <String, int>{};
  final cbpCounts = <int, int>{};
  final nonzeroCbp = <int, int>{};
  final qpDeltaCounts = <int, int>{};
  final nonzeroQp = <int, int>{};
  final transform8Addresses = <int>[];
  final nonSkipAddresses = <int>[];
  final nonzeroMvdExamples = <String>[];
  final motionRecords = <String>[];
  final residual = _ResidualSummary();
  var skipped = 0;
  var inter = 0;
  var intra = 0;
  var mbPartitionCount = 0;
  var motionPartitionCount = 0;
  var motionHash = _fnvOffset;
  var macroblockHash = _fnvOffset;
  var intraModeHash = _fnvOffset;
  var intra8Predicted = 0;
  var intra8Remaining = 0;
  var intra4Predicted = 0;
  var intra4Remaining = 0;
  final chromaModes = <int, int>{};
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
      macroblockHash = _hashValues(macroblockHash, <int>[address, -1]);
      skipped++;
      final state = _Mb(
        neighbor: const CabacMacroblockNeighbor(skipped: true),
        isIntra: false,
        isI16: false,
        transform8: false,
      );
      states[address] = state;
      motion.fill(
        x4: mbX * 4,
        y4: mbY * 4,
        width4: 4,
        height4: 4,
        referenceIndex: 0,
        mvd: const CabacMotionVectorDifference(horizontal: 0, vertical: 0),
      );
      if (syntax.decodeEndOfSliceFlag()) {
        eosAddress = address;
        break;
      }
      continue;
    }

    nonSkipAddresses.add(address);
    final type = start.type;
    final code = type.codeNum!;
    macroblockHash = _hashValues(macroblockHash, <int>[address, code]);
    typeCounts[code] = (typeCounts[code] ?? 0) + 1;
    typeAddresses.putIfAbsent(code, () => <int>[]).add(address);
    if (type.kind == CabacMacroblockKind.pcm) {
      fail('PCM is outside this syntax probe at mb=$address');
    }
    final isIntra = type.isIntra;
    final isI16 = type.kind == CabacMacroblockKind.intra16x16;
    final isNxn = type.kind == CabacMacroblockKind.intraNxN;
    final isInter = type.kind == CabacMacroblockKind.inter;
    if (isInter) {
      inter++;
    } else {
      intra++;
    }

    var transform8 = false;
    var chromaMode = 0;
    final decodedSubTypes = <CabacSubMacroblockType>[];
    if (isNxn) {
      if (isCabacTransformSize8x8FlagPresent(
        transform8x8ModeFlag: pps.transform8x8ModeFlag,
        macroblockType: type,
      )) {
        transform8 = syntax.decodeTransformSize8x8Flag(neighbors: neighbors);
      }
      for (var block = 0; block < (transform8 ? 4 : 16); block++) {
        final mode = transform8
            ? syntax.decodeIntra8x8Mode()
            : syntax.decodeIntra4x4Mode();
        if (transform8) {
          mode.usesPredictedMode ? intra8Predicted++ : intra8Remaining++;
        } else {
          mode.usesPredictedMode ? intra4Predicted++ : intra4Remaining++;
        }
        intraModeHash = _hashValues(intraModeHash, <int>[
          address,
          block,
          transform8 ? 8 : 4,
          mode.usesPredictedMode ? 1 : 0,
          mode.remainingMode ?? -1,
        ]);
      }
      chromaMode = syntax.decodeIntraChromaPredictionMode(neighbors: neighbors);
      chromaModes[chromaMode] = (chromaModes[chromaMode] ?? 0) + 1;
      motion.fill(
        x4: mbX * 4,
        y4: mbY * 4,
        width4: 4,
        height4: 4,
        referenceIndex: -1,
        mvd: const CabacMotionVectorDifference(horizontal: 0, vertical: 0),
        intra: true,
      );
    } else if (isI16) {
      chromaMode = syntax.decodeIntraChromaPredictionMode(neighbors: neighbors);
      chromaModes[chromaMode] = (chromaModes[chromaMode] ?? 0) + 1;
      motion.fill(
        x4: mbX * 4,
        y4: mbY * 4,
        width4: 4,
        height4: 4,
        referenceIndex: -1,
        mvd: const CabacMotionVectorDifference(horizontal: 0, vertical: 0),
        intra: true,
      );
    } else if (isInter) {
      final mbParts = <_MbPart>[];
      if (code == 0) {
        mbParts.add(_MbPart(index: 0, x: 0, y: 0, width: 16, height: 16));
      } else if (code == 1) {
        mbParts.addAll(<_MbPart>[
          _MbPart(index: 0, x: 0, y: 0, width: 16, height: 8),
          _MbPart(index: 1, x: 0, y: 8, width: 16, height: 8),
        ]);
      } else if (code == 2) {
        mbParts.addAll(<_MbPart>[
          _MbPart(index: 0, x: 0, y: 0, width: 8, height: 16),
          _MbPart(index: 1, x: 8, y: 0, width: 8, height: 16),
        ]);
      } else if (code == 3 || code == 4) {
        for (var index = 0; index < 4; index++) {
          final sub = syntax.decodeSubMbType();
          decodedSubTypes.add(sub);
          subTypeCounts[sub.codeNum] = (subTypeCounts[sub.codeNum] ?? 0) + 1;
          final part = _MbPart(
            index: index,
            x: (index & 1) * 8,
            y: (index >> 1) * 8,
            width: 8,
            height: 8,
          );
          part.addSubPartitions(sub);
          mbParts.add(part);
        }
      } else {
        fail('Unexpected P inter mb_type=$code at mb=$address');
      }
      mbPartitionCount += mbParts.length;

      for (final part in mbParts) {
        final globalX4 = mbX * 4 + part.x ~/ 4;
        final globalY4 = mbY * 4 + part.y ~/ 4;
        final ref = code == 4
            ? 0
            : syntax
                  .decodeReferenceIndex(
                    list: CabacReferenceList.l0,
                    activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
                    left: motion.referenceNeighbor(globalX4 - 1, globalY4),
                    top: motion.referenceNeighbor(globalX4, globalY4 - 1),
                  )
                  .value;
        part.referenceIndex = ref;
        referenceCounts[ref] = (referenceCounts[ref] ?? 0) + 1;
        motion.fillReference(
          x4: globalX4,
          y4: globalY4,
          width4: part.width ~/ 4,
          height4: part.height ~/ 4,
          referenceIndex: ref,
        );
      }

      for (final part in mbParts) {
        for (final sub in part.subPartitions) {
          final globalX4 = mbX * 4 + sub.x ~/ 4;
          final globalY4 = mbY * 4 + sub.y ~/ 4;
          final mvd = syntax.decodeMotionVectorDifference(
            left: motion.mvdNeighbor(globalX4 - 1, globalY4),
            top: motion.mvdNeighbor(globalX4, globalY4 - 1),
          );
          motion.fillMvd(
            x4: globalX4,
            y4: globalY4,
            width4: sub.width ~/ 4,
            height4: sub.height ~/ 4,
            mvd: mvd,
          );
          motionPartitionCount++;
          motionRecords.add(
            '$address:${part.index}:${sub.index}:r${part.referenceIndex}:'
            '${mvd.horizontal},${mvd.vertical}',
          );
          final key = '${mvd.horizontal},${mvd.vertical}';
          mvdCounts[key] = (mvdCounts[key] ?? 0) + 1;
          motionHash = _hashValues(motionHash, <int>[
            address,
            part.index,
            sub.index,
            part.referenceIndex,
            sub.x,
            sub.y,
            sub.width,
            sub.height,
            mvd.horizontal,
            mvd.vertical,
          ]);
          if ((mvd.horizontal != 0 || mvd.vertical != 0) &&
              nonzeroMvdExamples.length < 32) {
            nonzeroMvdExamples.add(
              '$address:${part.index}:${sub.index}:r${part.referenceIndex}:'
              '${mvd.horizontal},${mvd.vertical}',
            );
          }
        }
      }
    }

    final cbp = isI16
        ? type.intra16x16CodedBlockPattern!
        : syntax.decodeCodedBlockPattern(neighbors: neighbors);
    cbpCounts[cbp.packed] = (cbpCounts[cbp.packed] ?? 0) + 1;
    if (cbp.packed != 0) nonzeroCbp[address] = cbp.packed;
    if (isInter &&
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: pps.transform8x8ModeFlag,
          macroblockType: type,
          codedBlockPattern: cbp,
          subMacroblockTypes: decodedSubTypes,
        )) {
      transform8 = syntax.decodeTransformSize8x8Flag(neighbors: neighbors);
    }
    if (transform8) transform8Addresses.add(address);
    var qpDelta = 0;
    if (isI16 || cbp.packed != 0) {
      qpDelta = syntax.decodeMbQpDelta();
    } else {
      syntax.noteMacroblockWithoutQpDelta();
    }
    qpDeltaCounts[qpDelta] = (qpDeltaCounts[qpDelta] ?? 0) + 1;
    if (qpDelta != 0) nonzeroQp[address] = qpDelta;

    final state = _Mb(
      neighbor: CabacMacroblockNeighbor(
        skipped: false,
        intra16x16: isI16,
        codedBlockPatternLuma: cbp.luma,
        codedBlockPatternChroma: cbp.chroma,
        intraChromaPredictionMode: chromaMode,
        transformSize8x8: transform8,
      ),
      isIntra: isIntra,
      isI16: isI16,
      transform8: transform8,
    );
    _decodeResidual(
      syntax: syntax,
      state: state,
      left: left,
      top: top,
      address: address,
      cbp: cbp,
      summary: residual,
    );
    states[address] = state;
    final end = syntax.decodeEndOfSliceFlag();
    if (end) {
      eosAddress = address;
      break;
    }
  }

  // FFmpeg `-debug mb_type` independently reports 3094 S, 382 I, 27 i,
  // and seven `>` P_16x16 macroblocks. The hash freezes every MB address.
  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect(skipped, 3094);
  expect(nonSkipAddresses, hasLength(416));
  expect(inter, 7);
  expect(intra, 409);
  expect(typeCounts, <int, int>{
    6: 333,
    7: 35,
    5: 27,
    11: 4,
    0: 7,
    10: 5,
    9: 1,
    8: 4,
  });
  expect(typeAddresses[0], <int>[1419, 1576, 1821, 1892, 2131, 2205, 2208]);
  expect(macroblockHash.toRadixString(16), '4e7f1561f8f6a8ad');

  expect(subTypeCounts, isEmpty);
  expect(mbPartitionCount, 7);
  expect(motionPartitionCount, 7);
  expect(referenceCounts, <int, int>{0: 6, 1: 1});
  expect(mvdCounts, <String, int>{
    '0,0': 2,
    '56,-228': 1,
    '24,0': 1,
    '0,8': 1,
    '0,72': 1,
    '8,0': 1,
  });
  expect(motionRecords, <String>[
    '1419:0:0:r0:0,0',
    '1576:0:0:r0:56,-228',
    '1821:0:0:r0:24,0',
    '1892:0:0:r1:0,0',
    '2131:0:0:r0:0,8',
    '2205:0:0:r0:0,72',
    '2208:0:0:r0:8,0',
  ]);
  expect(nonzeroMvdExamples, <String>[
    '1576:0:0:r0:56,-228',
    '1821:0:0:r0:24,0',
    '2131:0:0:r0:0,8',
    '2205:0:0:r0:0,72',
    '2208:0:0:r0:8,0',
  ]);
  expect(motionHash.toRadixString(16), '622d3b1609579d36');

  expect(chromaModes, <int, int>{0: 394, 1: 10, 2: 5});
  expect(intra8Predicted, 51);
  expect(intra8Remaining, 57);
  expect(intra4Predicted, 0);
  expect(intra4Remaining, 0);
  expect(intraModeHash.toRadixString(16), '5f16b317686c0294');
  expect(cbpCounts, <int, int>{
    0: 387,
    5: 1,
    3: 1,
    1: 6,
    16: 9,
    10: 2,
    33: 1,
    15: 1,
    2: 3,
    11: 3,
    7: 1,
    14: 1,
  });
  expect(nonzeroCbp, <int, int>{
    1266: 5,
    1340: 3,
    1342: 1,
    1346: 16,
    1347: 16,
    1419: 10,
    1426: 16,
    1501: 16,
    1504: 16,
    1506: 16,
    1580: 16,
    1583: 16,
    1584: 16,
    1659: 33,
    1736: 15,
    1737: 2,
    1816: 1,
    1897: 11,
    1969: 11,
    1973: 7,
    1975: 1,
    2045: 11,
    2046: 1,
    2047: 2,
    2053: 10,
    2126: 1,
    2127: 2,
    2130: 14,
    2204: 1,
  });
  expect(transform8Addresses, <int>[
    1266,
    1340,
    1342,
    1419,
    1659,
    1731,
    1736,
    1737,
    1812,
    1816,
    1888,
    1889,
    1897,
    1969,
    1970,
    1973,
    1975,
    2045,
    2046,
    2047,
    2053,
    2124,
    2125,
    2126,
    2127,
    2130,
    2203,
    2204,
  ]);

  expect(qpDeltaCounts, <int, int>{
    0: 355,
    11: 2,
    -11: 1,
    9: 5,
    -9: 5,
    3: 1,
    5: 5,
    -5: 4,
    -2: 6,
    -7: 4,
    7: 4,
    -6: 3,
    -4: 3,
    2: 2,
    12: 2,
    10: 4,
    -12: 2,
    8: 2,
    -8: 4,
    -10: 1,
    6: 1,
  });
  expect(nonzeroQp, <int, int>{
    1266: 11,
    1273: -11,
    1274: 9,
    1275: -9,
    1340: 3,
    1342: 5,
    1343: -5,
    1344: 5,
    1345: -5,
    1348: -2,
    1352: 5,
    1354: -7,
    1419: 9,
    1421: -5,
    1425: -2,
    1498: 7,
    1499: -5,
    1503: -2,
    1575: 7,
    1577: -6,
    1581: -4,
    1584: 5,
    1585: -4,
    1654: -2,
    1659: 2,
    1665: 7,
    1666: -7,
    1736: 12,
    1737: -9,
    1738: 9,
    1739: -9,
    1742: -2,
    1815: 10,
    1816: -12,
    1818: 10,
    1820: -7,
    1890: 8,
    1893: -8,
    1895: 8,
    1899: -10,
    1969: 12,
    1971: -4,
    1972: -6,
    1973: 7,
    1975: -7,
    2045: 9,
    2046: -12,
    2047: 11,
    2048: -2,
    2049: -9,
    2053: 10,
    2054: -8,
    2126: 10,
    2127: -8,
    2128: 5,
    2129: -8,
    2130: 9,
    2202: -9,
    2204: 2,
    2206: 6,
    2207: -6,
  });

  expect(residual.codedBlocks, <String, int>{
    'luma8x8': 37,
    'lumaDc16x16': 22,
    'chromaDc420': 10,
    'chromaAc420': 2,
  });
  expect(residual.coefficients, <String, int>{
    'luma8x8': 37,
    'lumaDc16x16': 56,
    'chromaDc420': 14,
    'chromaAc420': 4,
  });
  expect(residual.macroblockAddresses.toList()..sort(), <int>[
    1266,
    1274,
    1340,
    1342,
    1344,
    1346,
    1347,
    1352,
    1419,
    1420,
    1426,
    1497,
    1498,
    1501,
    1504,
    1506,
    1575,
    1580,
    1583,
    1584,
    1659,
    1665,
    1736,
    1737,
    1738,
    1813,
    1815,
    1816,
    1818,
    1819,
    1890,
    1895,
    1897,
    1898,
    1969,
    1971,
    1973,
    1975,
    2045,
    2046,
    2047,
    2048,
    2052,
    2053,
    2126,
    2127,
    2128,
    2129,
    2130,
    2204,
    2206,
  ]);
  expect(residual.footprint, <String>[
    '1266:luma8x8:0:0:1',
    '1266:luma8x8:2:0:1',
    '1274:lumaDc16x16:0:0:2,1:2,2:-2,4:-2',
    '1340:luma8x8:0:0:-3',
    '1340:luma8x8:1:0:-2',
    '1342:luma8x8:0:0:2',
    '1344:lumaDc16x16:0:0:2,1:-2',
    '1346:chromaDc420:1:0:3',
    '1347:chromaDc420:1:0:1',
    '1352:lumaDc16x16:0:0:2,1:-5,2:-1,4:1',
    '1419:luma8x8:1:0:2',
    '1419:luma8x8:3:0:2',
    '1420:lumaDc16x16:0:0:1,1:-1,2:-1,4:1',
    '1426:chromaDc420:1:0:1,1:-2,2:2',
    '1497:lumaDc16x16:0:0:4,1:4',
    '1498:lumaDc16x16:0:0:-1,1:1,2:1,4:-1',
    '1501:chromaDc420:1:0:5',
    '1504:chromaDc420:1:0:2',
    '1506:chromaDc420:1:1:-2,2:2',
    '1575:lumaDc16x16:0:0:-2,1:-2',
    '1580:chromaDc420:1:0:-2',
    '1583:chromaDc420:1:0:-2',
    '1584:chromaDc420:1:0:-4',
    '1659:luma8x8:0:0:10',
    '1659:chromaDc420:1:0:-1,2:-1',
    '1659:chromaAc420:4:1:-1,2:-1',
    '1659:chromaAc420:5:1:-1,2:-1',
    '1665:lumaDc16x16:0:0:1,1:1',
    '1736:luma8x8:0:0:-1',
    '1736:luma8x8:1:0:1',
    '1736:luma8x8:2:0:1',
    '1736:luma8x8:3:0:1',
    '1737:luma8x8:1:0:-2',
    '1738:lumaDc16x16:0:1:1,2:-1',
    '1813:lumaDc16x16:0:0:5',
    '1815:lumaDc16x16:0:0:-1,1:1',
    '1816:luma8x8:0:0:-3',
    '1818:lumaDc16x16:0:0:-2,1:2',
    '1819:lumaDc16x16:0:0:1,1:-1',
    '1890:lumaDc16x16:0:0:-2,1:-2',
    '1895:lumaDc16x16:0:0:-1,1:1,2:1,4:-1',
    '1897:luma8x8:0:0:1',
    '1897:luma8x8:1:0:2',
    '1897:luma8x8:3:0:-1',
    '1898:lumaDc16x16:0:0:-2,1:2',
    '1969:luma8x8:0:0:1',
    '1969:luma8x8:1:0:1',
    '1969:luma8x8:3:0:-1',
    '1971:lumaDc16x16:0:0:2,2:-2',
    '1973:luma8x8:0:0:-2',
    '1973:luma8x8:1:0:-2',
    '1973:luma8x8:2:0:-1',
    '1975:luma8x8:0:0:4',
    '2045:luma8x8:0:0:-1',
    '2045:luma8x8:1:0:1',
    '2045:luma8x8:3:0:1',
    '2046:luma8x8:0:0:3',
    '2047:luma8x8:1:0:-2',
    '2048:lumaDc16x16:0:0:1,1:-1,2:1,4:1',
    '2052:lumaDc16x16:0:0:12',
    '2053:luma8x8:1:0:-3',
    '2053:luma8x8:3:0:-1',
    '2126:luma8x8:0:0:-2',
    '2127:luma8x8:1:0:-2',
    '2128:lumaDc16x16:0:0:2,2:-2',
    '2129:lumaDc16x16:0:0:5,2:5',
    '2130:luma8x8:1:0:-2',
    '2130:luma8x8:2:0:-2',
    '2130:luma8x8:3:0:-2',
    '2204:luma8x8:0:0:-4',
    '2206:lumaDc16x16:0:0:-1,1:-1,2:1,4:1',
  ]);

  expect(arithmetic.isTerminated, isTrue);
  expect(arithmetic.bitPosition, 3344);
  expect(arithmetic.range, 404);
  expect(arithmetic.offset, 405);
  expect(header.reader.bitsLeft, 0);
}

final class _MbPart {
  _MbPart({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  }) {
    subPartitions.add(
      _SubPart(index: 0, x: x, y: y, width: width, height: height),
    );
  }

  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
  final List<_SubPart> subPartitions = <_SubPart>[];
  int referenceIndex = 0;

  void addSubPartitions(CabacSubMacroblockType type) {
    subPartitions.clear();
    for (var index = 0; index < type.partitionCount; index++) {
      final localX = type.partitionWidth == 4
          ? (type.partitionHeight == 8 ? index : index & 1) * 4
          : 0;
      final localY = type.partitionHeight == 4
          ? (type.partitionWidth == 8 ? index : index >> 1) * 4
          : 0;
      subPartitions.add(
        _SubPart(
          index: index,
          x: x + localX,
          y: y + localY,
          width: type.partitionWidth,
          height: type.partitionHeight,
        ),
      );
    }
  }
}

final class _SubPart {
  const _SubPart({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
}

final class _MotionCell {
  int referenceIndex = -1;
  bool intra = false;
  bool direct = false;
  CabacMotionVectorDifference mvd = const CabacMotionVectorDifference(
    horizontal: 0,
    vertical: 0,
  );
}

final class _SyntaxMotionGrid {
  _SyntaxMotionGrid({required this.width4, required this.height4})
    : _cells = List<_MotionCell?>.filled(width4 * height4, null);

  final int width4;
  final int height4;
  final List<_MotionCell?> _cells;

  _MotionCell? _at(int x4, int y4) =>
      x4 < 0 || y4 < 0 || x4 >= width4 || y4 >= height4
      ? null
      : _cells[y4 * width4 + x4];

  CabacReferenceNeighbor referenceNeighbor(int x4, int y4) {
    final cell = _at(x4, y4);
    if (cell == null) return const CabacReferenceNeighbor.unavailable();
    return CabacReferenceNeighbor(
      direct: cell.direct,
      intra: cell.intra,
      referenceIndex: cell.referenceIndex,
    );
  }

  CabacMvdNeighbor mvdNeighbor(int x4, int y4) {
    final cell = _at(x4, y4);
    if (cell == null) return const CabacMvdNeighbor.unavailable();
    return CabacMvdNeighbor(
      horizontal: cell.mvd.horizontal,
      vertical: cell.mvd.vertical,
    );
  }

  void fill({
    required int x4,
    required int y4,
    required int width4,
    required int height4,
    required int referenceIndex,
    required CabacMotionVectorDifference mvd,
    bool intra = false,
    bool direct = false,
  }) {
    for (var y = y4; y < y4 + height4; y++) {
      for (var x = x4; x < x4 + width4; x++) {
        _cells[y * this.width4 + x] = _MotionCell()
          ..referenceIndex = referenceIndex
          ..mvd = mvd
          ..intra = intra
          ..direct = direct;
      }
    }
  }

  void fillReference({
    required int x4,
    required int y4,
    required int width4,
    required int height4,
    required int referenceIndex,
  }) {
    for (var y = y4; y < y4 + height4; y++) {
      for (var x = x4; x < x4 + width4; x++) {
        final index = y * this.width4 + x;
        final cell = _cells[index] ?? _MotionCell();
        _cells[index] = cell
          ..referenceIndex = referenceIndex
          ..intra = false
          ..direct = false;
      }
    }
  }

  void fillMvd({
    required int x4,
    required int y4,
    required int width4,
    required int height4,
    required CabacMotionVectorDifference mvd,
  }) {
    for (var y = y4; y < y4 + height4; y++) {
      for (var x = x4; x < x4 + width4; x++) {
        final index = y * this.width4 + x;
        final cell = _cells[index] ?? _MotionCell();
        _cells[index] = cell..mvd = mvd;
      }
    }
  }
}

final class _Mb {
  _Mb({
    required this.neighbor,
    required this.isIntra,
    required this.isI16,
    required this.transform8,
  });

  final CabacMacroblockNeighbor neighbor;
  final bool isIntra;
  final bool isI16;
  final bool transform8;
  bool lumaDcCoded = false;
  bool cbDcCoded = false;
  bool crDcCoded = false;
  final lumaCoded = List<bool>.filled(16, false);
  final cbCoded = List<bool>.filled(4, false);
  final crCoded = List<bool>.filled(4, false);
}

final class _ResidualSummary {
  final codedBlocks = <String, int>{};
  final coefficients = <String, int>{};
  final macroblockAddresses = <int>{};
  final footprint = <String>[];
  int hash = _fnvOffset;

  void add({
    required int address,
    required CabacResidualCategory category,
    required int blockIndex,
    required CabacResidualBlock block,
  }) {
    if (!block.coded) return;
    final key = category.name;
    codedBlocks[key] = (codedBlocks[key] ?? 0) + 1;
    coefficients[key] = (coefficients[key] ?? 0) + block.totalCoefficients;
    macroblockAddresses.add(address);
    final nonzero = <String>[];
    for (var index = 0; index < block.coefficients.length; index++) {
      final value = block.coefficients[index];
      if (value != 0) nonzero.add('$index:$value');
    }
    footprint.add('$address:${category.name}:$blockIndex:${nonzero.join(',')}');
    hash = _hashValues(hash, <int>[
      address,
      category.index,
      blockIndex,
      block.coefficients.length,
      ...block.coefficients,
    ]);
  }

  @override
  String toString() =>
      'blocks=$codedBlocks coeffs=$coefficients '
      'mbs=${macroblockAddresses.toList()..sort()} hash=${hash.toRadixString(16)}';
}

void _decodeResidual({
  required H264CabacSliceDataDecoder syntax,
  required _Mb state,
  required _Mb? left,
  required _Mb? top,
  required int address,
  required CabacCodedBlockPattern cbp,
  required _ResidualSummary summary,
}) {
  if (state.isI16) {
    final block = syntax.decodeResidualBlock(
      category: CabacResidualCategory.lumaDc16x16,
      currentMacroblockIntra: true,
      left: _lumaDc(left),
      top: _lumaDc(top),
    );
    state.lumaDcCoded = block.coded;
    summary.add(
      address: address,
      category: CabacResidualCategory.lumaDc16x16,
      blockIndex: 0,
      block: block,
    );
  }

  if (cbp.luma != 0) {
    if (state.transform8) {
      for (var group = 0; group < 4; group++) {
        if ((cbp.luma & (1 << group)) == 0) continue;
        final block = syntax.decodeResidualBlock(
          category: CabacResidualCategory.luma8x8,
          currentMacroblockIntra: state.isIntra,
          codedBlockFlagPresent: false,
        );
        summary.add(
          address: address,
          category: CabacResidualCategory.luma8x8,
          blockIndex: group,
          block: block,
        );
      }
    } else {
      final category = state.isI16
          ? CabacResidualCategory.lumaAc16x16
          : CabacResidualCategory.luma4x4;
      for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
        final group = syntaxBlock >> 2;
        if ((cbp.luma & (1 << group)) == 0) continue;
        final bx = _blockX[syntaxBlock];
        final by = _blockY[syntaxBlock];
        final block = syntax.decodeResidualBlock(
          category: category,
          currentMacroblockIntra: state.isIntra,
          left: bx > 0
              ? _lumaBlock(state, bx - 1, by, isI16: state.isI16)
              : _lumaBlock(left, 3, by, isI16: state.isI16),
          top: by > 0
              ? _lumaBlock(state, bx, by - 1, isI16: state.isI16)
              : _lumaBlock(top, bx, 3, isI16: state.isI16),
        );
        final raster = by * 4 + bx;
        state.lumaCoded[raster] = block.coded;
        summary.add(
          address: address,
          category: category,
          blockIndex: raster,
          block: block,
        );
      }
    }
  }

  if (cbp.chroma != 0) {
    final cbDc = syntax.decodeResidualBlock(
      category: CabacResidualCategory.chromaDc420,
      currentMacroblockIntra: state.isIntra,
      left: _chromaDc(left, cb: true),
      top: _chromaDc(top, cb: true),
    );
    final crDc = syntax.decodeResidualBlock(
      category: CabacResidualCategory.chromaDc420,
      currentMacroblockIntra: state.isIntra,
      left: _chromaDc(left, cb: false),
      top: _chromaDc(top, cb: false),
    );
    state.cbDcCoded = cbDc.coded;
    state.crDcCoded = crDc.coded;
    summary.add(
      address: address,
      category: CabacResidualCategory.chromaDc420,
      blockIndex: 0,
      block: cbDc,
    );
    summary.add(
      address: address,
      category: CabacResidualCategory.chromaDc420,
      blockIndex: 1,
      block: crDc,
    );
  }
  if (cbp.chroma == 2) {
    for (var plane = 0; plane < 2; plane++) {
      for (var blockIndex = 0; blockIndex < 4; blockIndex++) {
        final bx = blockIndex & 1;
        final by = blockIndex >> 1;
        final block = syntax.decodeResidualBlock(
          category: CabacResidualCategory.chromaAc420,
          currentMacroblockIntra: state.isIntra,
          left: bx > 0
              ? _chromaAc(state, blockIndex - 1, cb: plane == 0)
              : _chromaAc(left, by * 2 + 1, cb: plane == 0),
          top: by > 0
              ? _chromaAc(state, blockIndex - 2, cb: plane == 0)
              : _chromaAc(top, blockIndex + 2, cb: plane == 0),
        );
        (plane == 0 ? state.cbCoded : state.crCoded)[blockIndex] = block.coded;
        summary.add(
          address: address,
          category: CabacResidualCategory.chromaAc420,
          blockIndex: plane * 4 + blockIndex,
          block: block,
        );
      }
    }
  }
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
