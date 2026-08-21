import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/reference_picture_list.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

const _blockX = <int>[0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3];
const _blockY = <int>[0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3];

void main() {
  test('decodes exact sfux weighted/MMCO P POC 20 through termination', () {
    // Tenth decode-order AU is presentation frame 11 (POC 20). Independent
    // FFmpeg cropped-I420 SHA-256:
    // d39c85e93fccf04b595e330af39e7e92494c0badbf162541d1c79ec9aa9b5437
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419aca4fa842105af21f03703440dc0c8005171ffffa580000030000030178e671c604ae3c0313a83f314c76d53d94002341000d81b86bf382ec5f7362defefde0b3f937f71e204349ce958e3aae6af09d7ddf6907a0593b3c481de55132e8ee868f11c834d13e39f3f593775b3dfaadb5d4b8081e2ea84a971f6d694826065683008433cd1faed2c1ec770a7f15e6cf5163210f7dcb895937f25c23db5cb02ef24d774e4e73e71b20ac4e72dbeb7cbf264fdedfc46f7eb91540213fb55b1b4878c2ff69ad398d5cd3580c8ccead89cba6850f5160e193cd34cf43011bcc96ee4fa517d295d7e54df25c01e94eac619cbed3a3c856ddb836eb6bdc51dbb08d8f6a081252df3d45489673a1770000030000030216',
    );
    expect(vcl, hasLength(276));
    expect(
      sha256.convert(vcl).toString(),
      '577c68e37050bddfa4f46384853193a24aeffbced8bf3ba9c259e1c4c2c7f5bf',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 2168);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.p);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 6);
    expect(header.picOrderCntLsb, 20);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 7);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(
      header.refPicListModificationsL0.map((m) => (m.idc, m.value)),
      <(int, int)>[(0, 1), (0, 15), (0, 15), (1, 0), (0, 1), (0, 0), (0, 0)],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -7);
    expect(header.sliceQpY, 18);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.dataBitOffset, 154);
    expect(header.adaptiveRefPicMarkingModeFlag, isTrue);
    expect(
      header.memoryManagementOperations.map(
        (m) => (m.operation, m.differenceOfPicNumsMinus1),
      ),
      <(int, int?)>[(1, 4)],
    );

    final weights = header.predictionWeightTable!;
    expect(weights.lumaLog2WeightDenom, 6);
    expect(weights.chromaLog2WeightDenom, 0);
    expect(
      weights.list0.map(
        (w) => (
          w.lumaWeight,
          w.lumaOffset,
          w.chromaWeights.join(','),
          w.chromaOffsets.join(','),
        ),
      ),
      <(int, int, String, String)>[
        (55, 26, '1,1', '0,0'),
        (55, 25, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
      ],
    );
    expect(weights.list1, isEmpty);

    // AU8 is non-reference. After AU7's MMCO, these are the five physical
    // references. Seven logical L0 entries are legal because modifications
    // intentionally repeat POC 16 three times.
    final before = <H264ShortTermReference<int>>[
      for (final pair in <(int, int)>[
        (1, 4),
        (2, 6),
        (3, 10),
        (4, 16),
        (5, 12),
      ])
        H264ShortTermReference<int>(
          frameNum: pair.$1,
          pictureOrderCount: pair.$2,
          value: pair.$2,
        ),
    ];
    final list0 = buildPReferenceList0<int>(
      shortTermReferences: before,
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
      modifications: header.refPicListModificationsL0,
    );
    expect(list0.map((reference) => reference.value), <int>[
      16,
      16,
      16,
      12,
      10,
      6,
      4,
    ]);
    expect(identical(list0[0], list0[1]), isTrue);
    expect(identical(list0[1], list0[2]), isTrue);
    final current = H264ShortTermReference<int>(
      frameNum: header.frameNum,
      pictureOrderCount: header.picOrderCntLsb,
      value: header.picOrderCntLsb!,
    );
    final marking = applyShortTermDpbMarking<int>(
      shortTermReferences: before,
      currentPicture: current,
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: header.nalRefIdc,
      adaptiveRefPicMarkingModeFlag: header.adaptiveRefPicMarkingModeFlag,
      memoryManagementOperations: header.memoryManagementOperations,
    );
    expect(marking.removed.map((reference) => reference.value), <int>[4]);
    expect(marking.references.map((reference) => reference.value), <int>[
      6,
      10,
      16,
      12,
      20,
    ]);
    expect(identical(marking.references.last, current), isTrue);

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
  expect(arithmetic.offset, 500);
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

  // FFmpeg `-debug mb_type` independently reports 3391 S, 92 I, 20 i,
  // six `>` P_16x16, and one `>-` P_16x8. The hash freezes address/type.
  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect(skipped, 3391);
  expect(nonSkipAddresses, hasLength(119));
  expect(inter, 7);
  expect(intra, 112);
  expect(typeCounts, <int, int>{
    6: 67,
    0: 6,
    7: 11,
    11: 5,
    5: 20,
    1: 1,
    8: 3,
    10: 5,
    9: 1,
  });
  expect(typeAddresses, <int, List<int>>{
    6: <int>[
      950,
      951,
      952,
      1023,
      1024,
      1025,
      1026,
      1027,
      1028,
      1029,
      1030,
      1101,
      1102,
      1103,
      1104,
      1105,
      1106,
      1107,
      1108,
      1178,
      1179,
      1180,
      1181,
      1182,
      1183,
      1186,
      1218,
      1219,
      1257,
      1258,
      1259,
      1260,
      1264,
      1266,
      1271,
      1412,
      1413,
      1414,
      1415,
      1416,
      1417,
      1419,
      1422,
      1426,
      1430,
      1491,
      1492,
      1493,
      1494,
      1502,
      1504,
      1508,
      1556,
      1573,
      1575,
      1734,
      1735,
      1737,
      1741,
      1742,
      1813,
      1817,
      1818,
      1893,
      1895,
      1971,
      1973,
    ],
    0: <int>[1262, 1263, 1579, 1656, 1658, 1976],
    7: <int>[1267, 1272, 1342, 1345, 1425, 1739, 1740, 1814, 1816, 1898, 1968],
    11: <int>[1268, 1269, 1348, 1424, 1427],
    5: <int>[
      1332,
      1339,
      1341,
      1344,
      1352,
      1423,
      1653,
      1654,
      1659,
      1660,
      1738,
      1889,
      1896,
      1897,
      1972,
      2049,
      2052,
      2127,
      2129,
      2206,
    ],
    1: <int>[1347],
    8: <int>[1349, 1974, 2051],
    10: <int>[1500, 1501, 1505, 1581, 1583],
    9: <int>[1665],
  });
  expect(macroblockHash.toRadixString(16), '-55431bfd4bd69e2b');

  expect(subTypeCounts, isEmpty);
  expect(mbPartitionCount, 8);
  expect(motionPartitionCount, 8);
  expect(referenceCounts, <int, int>{0: 6, 1: 2});
  expect(mvdCounts, <String, int>{
    '0,64': 1,
    '0,0': 2,
    '0,1': 1,
    '8,64': 1,
    '72,0': 1,
    '60,72': 1,
    '36,0': 1,
  });
  expect(motionRecords, <String>[
    '1262:0:0:r0:0,64',
    '1263:0:0:r1:0,0',
    '1347:0:0:r1:0,1',
    '1347:1:0:r0:0,0',
    '1579:0:0:r0:8,64',
    '1656:0:0:r0:72,0',
    '1658:0:0:r0:60,72',
    '1976:0:0:r0:36,0',
  ]);
  expect(motionHash.toRadixString(16), '3cd79e175935cd9d');

  expect(chromaModes, <int, int>{0: 103, 2: 3, 3: 1, 1: 5});
  expect(intra8Predicted, 46);
  expect(intra8Remaining, 34);
  expect(intra4Predicted, 0);
  expect(intra4Remaining, 0);
  expect(intraModeHash.toRadixString(16), '-7414a89ca2ab8563');
  expect(cbpCounts, <int, int>{0: 94, 16: 12, 1: 5, 17: 3, 2: 3, 3: 2});
  expect(nonzeroCbp, <int, int>{
    1268: 16,
    1269: 16,
    1341: 1,
    1344: 1,
    1347: 16,
    1348: 16,
    1423: 17,
    1424: 16,
    1427: 16,
    1500: 16,
    1501: 16,
    1505: 16,
    1579: 16,
    1581: 16,
    1583: 16,
    1659: 17,
    1660: 17,
    1738: 2,
    1889: 2,
    1896: 3,
    1897: 2,
    2049: 1,
    2052: 1,
    2129: 1,
    2206: 3,
  });
  expect(transform8Addresses, <int>[
    1332,
    1339,
    1341,
    1344,
    1352,
    1423,
    1653,
    1654,
    1659,
    1660,
    1738,
    1889,
    1896,
    1897,
    1972,
    2049,
    2052,
    2127,
    2129,
    2206,
  ]);

  expect(qpDeltaCounts, <int, int>{
    0: 87,
    2: 2,
    6: 4,
    -8: 4,
    7: 2,
    -7: 2,
    8: 3,
    10: 1,
    -10: 1,
    -3: 2,
    3: 1,
    4: 1,
    -4: 1,
    14: 1,
    -11: 1,
    -6: 1,
    5: 1,
    -5: 1,
    9: 1,
    -2: 1,
    -15: 1,
  });
  expect(nonzeroQp, <int, int>{
    1264: 2,
    1266: 6,
    1341: -8,
    1342: 7,
    1344: -7,
    1347: 8,
    1348: -8,
    1419: 10,
    1422: -10,
    1575: 7,
    1579: -7,
    1659: -3,
    1660: 3,
    1665: 4,
    1734: -4,
    1737: -3,
    1738: 14,
    1739: -11,
    1741: 8,
    1742: -8,
    1818: 8,
    1895: -8,
    1896: 6,
    1897: -6,
    1898: 5,
    1968: -5,
    1971: 9,
    1973: -2,
    1974: -15,
    2049: 6,
    2052: 2,
    2206: 6,
  });

  expect(residual.codedBlocks, <String, int>{
    'lumaDc16x16': 17,
    'chromaDc420': 15,
    'luma8x8': 15,
  });
  expect(residual.coefficients, <String, int>{
    'lumaDc16x16': 34,
    'chromaDc420': 18,
    'luma8x8': 17,
  });
  expect(residual.macroblockAddresses.toList()..sort(), <int>[
    1264,
    1266,
    1268,
    1269,
    1271,
    1341,
    1342,
    1344,
    1347,
    1348,
    1419,
    1423,
    1424,
    1427,
    1500,
    1501,
    1505,
    1575,
    1579,
    1581,
    1583,
    1659,
    1660,
    1665,
    1738,
    1741,
    1742,
    1818,
    1889,
    1893,
    1896,
    1897,
    1898,
    1968,
    1971,
    1973,
    2049,
    2052,
    2129,
    2206,
  ]);
  expect(residual.hash.toRadixString(16), '-4072b96e6f6f63c3');
  expect(residual.footprint, <String>[
    '1264:lumaDc16x16:0:0:1,1:1,2:-1,4:-1',
    '1266:lumaDc16x16:0:0:1,2:-1',
    '1268:chromaDc420:1:0:1',
    '1269:chromaDc420:1:0:1',
    '1271:lumaDc16x16:0:0:1,2:-1',
    '1341:luma8x8:0:0:3',
    '1342:lumaDc16x16:0:0:1,1:1',
    '1344:luma8x8:0:0:3',
    '1347:chromaDc420:1:0:1',
    '1348:lumaDc16x16:0:0:5,2:2',
    '1348:chromaDc420:1:1:-2,2:2',
    '1419:lumaDc16x16:0:1:-2',
    '1423:luma8x8:0:0:3',
    '1423:chromaDc420:1:0:3',
    '1424:chromaDc420:1:0:3',
    '1427:chromaDc420:1:1:-1,2:1',
    '1500:chromaDc420:1:0:3',
    '1501:chromaDc420:1:0:3',
    '1505:chromaDc420:1:0:3',
    '1575:lumaDc16x16:0:2:1,4:-1',
    '1579:chromaDc420:1:0:3',
    '1581:lumaDc16x16:0:0:3',
    '1581:chromaDc420:1:0:1',
    '1583:chromaDc420:1:0:-2',
    '1659:luma8x8:0:0:9',
    '1659:chromaDc420:1:1:2,2:-3',
    '1660:luma8x8:0:0:-2',
    '1660:chromaDc420:1:0:-4',
    '1665:lumaDc16x16:0:0:-1,1:1',
    '1738:luma8x8:1:0:-1',
    '1741:lumaDc16x16:0:0:1,1:-1',
    '1742:lumaDc16x16:0:0:3',
    '1818:lumaDc16x16:0:0:-1,1:1',
    '1889:luma8x8:1:0:-1',
    '1893:lumaDc16x16:0:0:1,1:1,2:1',
    '1896:luma8x8:0:0:-2',
    '1896:luma8x8:1:0:-2',
    '1897:luma8x8:1:0:1',
    '1898:lumaDc16x16:0:0:-2,1:2',
    '1968:lumaDc16x16:0:0:3',
    '1971:lumaDc16x16:0:0:3,1:-1,2:-2',
    '1973:lumaDc16x16:0:0:-1,1:1',
    '2049:luma8x8:0:0:1,2:-1,3:-1',
    '2052:luma8x8:0:0:3',
    '2129:luma8x8:0:0:3',
    '2206:luma8x8:0:0:-1',
    '2206:luma8x8:1:0:1',
  ]);

  expect(arithmetic.isTerminated, isTrue);
  expect(arithmetic.bitPosition, 2167);
  expect(arithmetic.range, 266);
  expect(arithmetic.offset, 267);
  expect(header.reader.bitsLeft, 1);
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
