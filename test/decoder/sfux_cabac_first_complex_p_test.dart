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
  test('decodes the first complex sfux P picture through termination', () {
    // Exact fifth decode-order picture from 250_00000.ts: frame_num 3,
    // POC 10. It is presentation frame 6 because B POC 8 follows it in
    // decode order. Independent FFmpeg cropped-I420 oracle:
    // 65c92359e8964124a2c0dcdb2d3c1a063000e080b3d2b09719be1eef1925ab88.
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419a654be10843c86c057019d015c06900857ffde100001f2ddb48eb67eef7a7df073e26fca82e3382f7fdc025cfef6feb000876490d7fe00a1e26af9822c8e00723216c2fc12cf43000005f200d2935a981c00f27bd3c0ff1a6034d77ace5f52ca884ae73108c198b6f80b4c94f29cfa5d4000003001e2c2b503ae65a416fe807e7e11cb8dee606fdcbba238e091fc06c3bd1e2a01c2b2f69a842b9ac6994003725c8a32e1ca1aae1f1641ea3a29a3680a534f4f65007960e0315999abc5654e8d4b767ad7acfbc35ed92d4d1c3d9e3821ad405702e0160b0d6e85775a2f198331e91c75cf2e745e0b242ee6ad5381eb0b971b9e2004d946a038f29e15ea0b1bf637f3467820d8cd71e9870c0bb8bf1c964a6867e31ce3994964892f5ab13ef4f4990dc1a93a804730b47dbdf7b1527832e3dbed93fde75c8898887fbc0000003000003006ac1',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(vcl, hasLength(327));
    expect(header.reader.bitLength, 2584);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.sliceType, H264SliceType.p);
    expect(header.frameNum, 3);
    expect(header.picOrderCntLsb, 10);
    expect(header.numRefIdxL0ActiveMinus1, 4);
    expect(header.numRefIdxL1ActiveMinus1, 0);
    expect(
      header.refPicListModificationsL0.map(
        (modification) => (modification.idc, modification.value),
      ),
      <(int, int)>[(0, 0), (0, 15), (0, 15), (0, 0), (0, 0)],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -10);
    expect(header.sliceQpY, 15);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.dataBitOffset, 141);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);

    final weights = header.predictionWeightTable!;
    expect(weights.lumaLog2WeightDenom, 5);
    expect(weights.chromaLog2WeightDenom, 0);
    expect(weights.list0, hasLength(5));
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
        (87, -51, '1,1', '0,0'),
        (87, -52, '1,1', '0,0'),
        (32, 0, '1,1', '0,0'),
        (32, 0, '1,1', '0,0'),
        (32, 0, '1,1', '0,0'),
      ],
    );

    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 3);
  expect(header.reader.bitPos, 144);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 144);
  expect(arithmetic.bitPosition, 153);
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

  // FFmpeg `-debug mb_type` independently reports 3233 S, 221 i, 52 I,
  // and four `>` P_16x16 macroblocks at the same addresses. The arithmetic
  // hash additionally freezes every skipped/non-skipped address and type.
  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect(skipped, 3233);
  expect(nonSkipAddresses, hasLength(277));
  expect(inter, 4);
  expect(intra, 273);
  expect(typeCounts, <int, int>{5: 221, 7: 12, 6: 38, 0: 4, 8: 2});
  expect(typeAddresses[0], <int>[1274, 2047, 2126, 2130]);
  expect(macroblockHash.toRadixString(16), '-5ee021441bc656e');

  // All explicit inter syntax is P_L0_16x16. Although five references are
  // active in the header, the bitstream selects only ref_idx_l0 == 0.
  expect(subTypeCounts, isEmpty);
  expect(mbPartitionCount, 4);
  expect(motionPartitionCount, 4);
  expect(referenceCounts, <int, int>{0: 4});
  expect(mvdCounts, <String, int>{'0,0': 4});
  expect(nonzeroMvdExamples, isEmpty);
  expect(motionHash.toRadixString(16), '1cdbff4fb079c9e4');

  expect(chromaModes, <int, int>{0: 264, 1: 7, 2: 2});
  expect(intra8Predicted, 789);
  expect(intra8Remaining, 95);
  expect(intra4Predicted, 0);
  expect(intra4Remaining, 0);
  expect(intraModeHash.toRadixString(16), '-77abe892d24c1b62');

  expect(cbpCounts, <int, int>{
    1: 29,
    0: 233,
    4: 2,
    10: 1,
    16: 3,
    2: 6,
    5: 1,
    14: 1,
    12: 1,
  });
  expect(nonzeroCbp, <int, int>{
    319: 1,
    327: 1,
    361: 1,
    866: 1,
    872: 1,
    925: 1,
    1177: 1,
    1212: 1,
    1216: 1,
    1225: 1,
    1233: 1,
    1237: 1,
    1267: 4,
    1274: 4,
    1308: 1,
    1313: 1,
    1327: 1,
    1344: 10,
    1345: 1,
    1424: 16,
    1453: 1,
    1464: 1,
    1501: 16,
    1527: 1,
    1536: 1,
    1567: 1,
    1582: 16,
    1613: 1,
    1616: 1,
    1634: 1,
    1741: 2,
    1743: 2,
    1818: 1,
    1896: 2,
    1897: 1,
    1966: 2,
    1973: 1,
    1976: 2,
    2047: 5,
    2050: 14,
    2053: 2,
    2126: 12,
    2130: 1,
    2206: 1,
  });

  // All 221 I_NxN macroblocks are I_8x8, and the four P_16x16 blocks also
  // signal transform_size_8x8_flag = 1. Motion partition size does not gate
  // the flag for ordinary P_16x16/P_16x8/P_8x16 macroblocks.
  final expectedTransform8 = <int>[...typeAddresses[5]!, ...typeAddresses[0]!]
    ..sort();
  expect(transform8Addresses, expectedTransform8);
  expect(transform8Addresses, hasLength(225));

  expect(qpDeltaCounts, <int, int>{
    3: 2,
    0: 255,
    -3: 1,
    7: 1,
    -9: 1,
    2: 3,
    -5: 3,
    5: 2,
    -2: 2,
    4: 2,
    -4: 3,
    8: 1,
    6: 1,
  });
  expect(nonzeroQp, <int, int>{
    319: 3,
    1267: 3,
    1308: -3,
    1344: 7,
    1345: -9,
    1453: 2,
    1501: -5,
    1527: 5,
    1582: -2,
    1613: 2,
    1741: 4,
    1818: -5,
    1896: 2,
    1897: 4,
    1966: -2,
    1973: -5,
    1976: 5,
    2048: -4,
    2050: 8,
    2053: -4,
    2128: -4,
    2130: 6,
  });

  // Coefficient locations below are scan indices, not raster indices. Every
  // coded block in this synthetic frame contains exactly one coefficient.
  expect(residual.codedBlocks, <String, int>{'luma8x8': 46, 'chromaDc420': 3});
  expect(residual.coefficients, <String, int>{'luma8x8': 46, 'chromaDc420': 3});
  expect(residual.macroblockAddresses.toList()..sort(), <int>[
    319,
    327,
    361,
    866,
    872,
    925,
    1177,
    1212,
    1216,
    1225,
    1233,
    1237,
    1267,
    1274,
    1308,
    1313,
    1327,
    1344,
    1345,
    1424,
    1453,
    1464,
    1501,
    1527,
    1536,
    1567,
    1582,
    1613,
    1616,
    1634,
    1741,
    1743,
    1818,
    1896,
    1897,
    1966,
    1973,
    1976,
    2047,
    2050,
    2053,
    2126,
    2130,
    2206,
  ]);
  expect(residual.footprint, <String>[
    '319:luma8x8:0:0:3',
    '327:luma8x8:0:0:3',
    '361:luma8x8:0:0:3',
    '866:luma8x8:0:0:3',
    '872:luma8x8:0:0:3',
    '925:luma8x8:0:0:3',
    '1177:luma8x8:0:0:3',
    '1212:luma8x8:0:0:3',
    '1216:luma8x8:0:0:3',
    '1225:luma8x8:0:0:3',
    '1233:luma8x8:0:0:3',
    '1237:luma8x8:0:0:3',
    '1267:luma8x8:2:0:2',
    '1274:luma8x8:2:0:2',
    '1308:luma8x8:0:0:3',
    '1313:luma8x8:0:0:3',
    '1327:luma8x8:0:0:3',
    '1344:luma8x8:1:0:1',
    '1344:luma8x8:3:0:1',
    '1345:luma8x8:0:0:2',
    '1424:chromaDc420:1:0:4',
    '1453:luma8x8:0:0:3',
    '1464:luma8x8:0:0:3',
    '1501:chromaDc420:1:0:6',
    '1527:luma8x8:0:0:3',
    '1536:luma8x8:0:0:3',
    '1567:luma8x8:0:0:3',
    '1582:chromaDc420:1:0:-4',
    '1613:luma8x8:0:0:3',
    '1616:luma8x8:0:0:3',
    '1634:luma8x8:0:0:3',
    '1741:luma8x8:1:0:2',
    '1743:luma8x8:1:0:-2',
    '1818:luma8x8:0:0:-2',
    '1896:luma8x8:1:0:-3',
    '1897:luma8x8:0:0:2',
    '1966:luma8x8:1:0:2',
    '1973:luma8x8:0:0:-2',
    '1976:luma8x8:1:0:-2',
    '2047:luma8x8:0:0:2',
    '2047:luma8x8:2:0:2',
    '2050:luma8x8:1:0:-1',
    '2050:luma8x8:2:0:-1',
    '2050:luma8x8:3:0:-2',
    '2053:luma8x8:1:0:-2',
    '2126:luma8x8:2:0:2',
    '2126:luma8x8:3:0:2',
    '2130:luma8x8:0:0:1',
    '2206:luma8x8:0:0:-1',
  ]);

  expect(arithmetic.isTerminated, isTrue);
  expect(arithmetic.bitPosition, 2578);
  expect(arithmetic.range, 427);
  expect(arithmetic.offset, 427);
  expect(header.reader.bitsLeft, 6);
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
