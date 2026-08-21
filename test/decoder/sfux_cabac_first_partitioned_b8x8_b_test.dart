import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/picture_order_count.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/reference_picture_list.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

const _blockX = <int>[0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3];
const _blockY = <int>[0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3];

void main() {
  test('decodes exact sfux first partitioned/B_8x8 B AU34 to termination', () {
    // Thirty-fifth decode-order picture, presentation frame n=33 / POC 66.
    // Reproduced from /tmp/sfux-audit.N51PSH/250_00000.ts (278428 bytes,
    // SHA-256 810dbefb730b8658f2404106610143bb71aba2d67a7d56ee26c92af2dbb50ebe),
    // video PTS 231105 at 90 kHz. Authoritative FFmpeg `-f framehash
    // -hash sha256` presentation-frame n=33 SHA-256:
    // ebea4edd2554002c78300a049795d745aa6e2df8ab9a39eb5385c211d8cadfff
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '019ee16491ff00000300000300018d3303fdd59733069aa96716a85f807cb33ffebed44e15e4801b15dd4a96f5604e33c638e06006532a23afc00b58ea67fe708ca3e4893ad901c32fdc7b57a1757c8686c4e12ad8b92e2de2336fe32385fd678c5cd09b870c20cfacd40c0a4533105676d03b73fcde15d3c5dea2b4a237fd26b455b000c2af0deababc88542dffa624f19379d24c6e74db254231b8b0f7ef2d83049bd5d1d8348e38446773e75cfdb7281ffe5c50e786be2b81ad83445d8ac93c897880e8191d35ec3dfb95d4a5a2ba48025c4c9fd85b26ce41bdd091fb007b17a0da591af9e873233f1a4c78a5e589b494af4dda89741d03033fba179e003e6daf60ed6592d8a1e4f344635195ff1aed25020c906afd58edaecdd02feeecf0000003000003006f41',
    );
    expect(vcl, hasLength(297));
    expect(
      sha256.convert(vcl).toString(),
      '0b50884f52d65916266324c9ef22b8e982c2578696740387932a0347ce14725a',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 2336);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.b);
    expect(header.nalRefIdc, 0);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 7);
    expect(header.picOrderCntLsb, 2);
    expect(header.directSpatialMvPredFlag, isTrue);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 4);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(header.refPicListModificationsL0, isEmpty);
    expect(header.refPicListModificationsL1, isEmpty);
    expect(pps.weightedBipredIdc, 2);
    expect(header.predictionWeightTable, isNull);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -7);
    expect(header.sliceQpY, 18);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.dataBitOffset, 38);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);

    // POC type 0 must retain the previous *reference* picture across
    // non-reference B pictures. Seed the exact reference-picture LSB sequence
    // from AU0 through AU33, including the 64-count wrap at AU31.
    final pocTracker = H264PocType0Tracker();
    const referencePocLsbs = <int>[
      0,
      4,
      6,
      10,
      16,
      12,
      20,
      22,
      24,
      26,
      30,
      34,
      36,
      38,
      42,
      44,
      46,
      52,
      48,
      56,
      60,
      0,
      4,
    ];
    for (var index = 0; index < referencePocLsbs.length; index++) {
      pocTracker.derivePictureOrderCount(
        picOrderCntLsb: referencePocLsbs[index],
        maxPicOrderCntLsb: sps.maxPicOrderCntLsb,
        isIdr: index == 0,
        isReference: true,
      );
    }
    final poc = pocTracker.deriveFromHeader(header);
    expect(poc.picOrderCntMsb, 64);
    expect(poc.picOrderCntLsb, 2);
    expect(poc.pictureOrderCount, 66);

    final reference52 = H264ShortTermReference<String>(
      frameNum: 1,
      pictureOrderCount: 52,
      value: 'AU24/POC52',
    );
    final reference56 = H264ShortTermReference<String>(
      frameNum: 3,
      pictureOrderCount: 56,
      value: 'AU27/POC56',
    );
    final reference60 = H264ShortTermReference<String>(
      frameNum: 4,
      pictureOrderCount: 60,
      value: 'AU29/POC60',
    );
    final reference64 = H264ShortTermReference<String>(
      frameNum: 5,
      pictureOrderCount: 64,
      value: 'AU31/POC64',
    );
    final reference68 = H264ShortTermReference<String>(
      frameNum: 6,
      pictureOrderCount: 68,
      value: 'AU33/POC68',
    );
    final beforeAu34 = <H264ShortTermReference<String>>[
      reference52,
      reference56,
      reference60,
      reference64,
      reference68,
    ];
    final lists = buildBReferenceLists<String>(
      shortTermReferences: beforeAu34,
      currentFrameNum: header.frameNum,
      currentPictureOrderCount: poc.pictureOrderCount,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCountL0: header.numRefIdxL0ActiveMinus1 + 1,
      activeReferenceCountL1: header.numRefIdxL1ActiveMinus1 + 1,
      modificationsL0: header.refPicListModificationsL0,
      modificationsL1: header.refPicListModificationsL1,
    );
    expect(lists.list0.map((reference) => reference.pictureOrderCount), <int?>[
      64,
      60,
      56,
      52,
    ]);
    expect(lists.list1.map((reference) => reference.pictureOrderCount), <int?>[
      68,
    ]);
    expect(identical(lists.list0[0], reference64), isTrue);
    expect(identical(lists.list0[1], reference60), isTrue);
    expect(identical(lists.list0[2], reference56), isTrue);
    expect(identical(lists.list0[3], reference52), isTrue);
    expect(identical(lists.list1.single, reference68), isTrue);
    final current = H264ShortTermReference<String>(
      frameNum: 7,
      pictureOrderCount: 66,
      value: 'AU34/POC66',
    );
    final afterAu34 = applyShortTermDpbMarking<String>(
      shortTermReferences: beforeAu34,
      currentPicture: current,
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: header.nalRefIdc,
      adaptiveRefPicMarkingModeFlag: header.adaptiveRefPicMarkingModeFlag,
      memoryManagementOperations: header.memoryManagementOperations,
    );
    expect(afterAu34.appendedCurrentPicture, isFalse);
    expect(afterAu34.removed, isEmpty);
    expect(
      afterAu34.references.map((reference) => reference.pictureOrderCount),
      <int?>[52, 56, 60, 64, 68],
    );
    for (var index = 0; index < beforeAu34.length; index++) {
      expect(identical(afterAu34.references[index], beforeAu34[index]), isTrue);
    }
    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 2);
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
  final motion = _SyntaxMotionGrid(width4: mbWidth * 4, height4: 45 * 4);
  final typeCounts = <int, int>{};
  final typeAddresses = <int, List<int>>{};
  final subTypeCounts = <int, int>{};
  final referenceCounts = <String, int>{};
  final mvdCounts = <String, int>{};
  final cbpCounts = <int, int>{};
  final nonzeroCbp = <int, int>{};
  final qpDeltaCounts = <int, int>{};
  final nonzeroQp = <int, int>{};
  final qpYAtAddress = <int, int>{};
  final transform8Addresses = <int>[];
  final nonSkipAddresses = <int>[];
  final nonzeroMvdExamples = <String>[];
  final motionRecords = <String>[];
  final subTypeRecords = <String>[];
  final referenceRecords = <String>[];
  final targetCheckpoints = <String>[];
  final ffmpegSymbolCounts = <String, int>{};
  final residual = _ResidualSummary();
  var skipped = 0;
  var inter = 0;
  var directMacroblocks = 0;
  var intra = 0;
  var mbPartitionCount = 0;
  var motionPartitionCount = 0;
  var motionHash = _fnvOffset;
  var macroblockHash = _fnvOffset;
  var ffmpegMacroblockMapHash = _fnvOffset;
  var intraModeHash = _fnvOffset;
  var intra8Predicted = 0;
  var intra8Remaining = 0;
  var intra4Predicted = 0;
  var intra4Remaining = 0;
  final chromaModes = <int, int>{};
  var eosAddress = -1;
  var qpY = header.sliceQpY;

  for (var address = 0; address < mbCount; address++) {
    final mbX = address % mbWidth;
    final mbY = address ~/ mbWidth;
    final left = mbX == 0 ? null : states[address - 1];
    final top = mbY == 0 ? null : states[address - mbWidth];
    final neighbors = CabacMacroblockNeighbors(
      left: left?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
      top: top?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
    );
    final beforeStart = _arithmeticCheckpoint(arithmetic);
    final start = syntax.decodeMacroblockStart(neighbors: neighbors);
    if (start.skipped) {
      macroblockHash = _hashValues(macroblockHash, <int>[address, -1]);
      ffmpegMacroblockMapHash = _hashValues(ffmpegMacroblockMapHash, <int>[
        address,
        _ffmpegSymbolIds['d']!,
      ]);
      ffmpegSymbolCounts['d'] = (ffmpegSymbolCounts['d'] ?? 0) + 1;
      skipped++;
      final state = _Mb(
        neighbor: const CabacMacroblockNeighbor(skipped: true, direct: true),
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
        usesList0: true,
        usesList1: true,
        direct: true,
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
    final isTarget = address == 1186 || code == 22;
    if (isTarget) {
      targetCheckpoints.add(
        '$address:start=$beforeStart:type$code=${_arithmeticCheckpoint(arithmetic)}',
      );
    }
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
    final isDirect = type.kind == CabacMacroblockKind.direct;
    if (isInter) {
      inter++;
    } else if (isDirect) {
      directMacroblocks++;
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
      motion.fill(x4: mbX * 4, y4: mbY * 4, width4: 4, height4: 4, intra: true);
    } else if (isI16) {
      chromaMode = syntax.decodeIntraChromaPredictionMode(neighbors: neighbors);
      chromaModes[chromaMode] = (chromaModes[chromaMode] ?? 0) + 1;
      motion.fill(x4: mbX * 4, y4: mbY * 4, width4: 4, height4: 4, intra: true);
    } else if (isDirect || isInter) {
      final mbParts = <_MbPart>[];
      if (code == 22) {
        for (var index = 0; index < 4; index++) {
          final sub = syntax.decodeSubMbType();
          decodedSubTypes.add(sub);
          subTypeCounts[sub.codeNum] = (subTypeCounts[sub.codeNum] ?? 0) + 1;
          subTypeRecords.add('$address:$index:${sub.codeNum}');
          final part = _MbPart(
            index: index,
            x: (index & 1) * 8,
            y: (index >> 1) * 8,
            width: 8,
            height: 8,
            usesList0: sub.usesList0,
            usesList1: sub.usesList1,
            direct: sub.direct,
          );
          part.addSubPartitions(sub);
          mbParts.add(part);
        }
      } else {
        mbParts.addAll(_buildBMacroblockParts(code));
      }
      mbPartitionCount += mbParts.length;

      for (final part in mbParts) {
        motion.fill(
          x4: mbX * 4 + part.x ~/ 4,
          y4: mbY * 4 + part.y ~/ 4,
          width4: part.width ~/ 4,
          height4: part.height ~/ 4,
          usesList0: part.usesList0,
          usesList1: part.usesList1,
          direct: part.direct,
        );
      }

      for (final list in CabacReferenceList.values) {
        final activeReferenceCount = list == CabacReferenceList.l0
            ? header.numRefIdxL0ActiveMinus1 + 1
            : header.numRefIdxL1ActiveMinus1 + 1;
        for (final part in mbParts) {
          final usesList = list == CabacReferenceList.l0
              ? part.usesList0
              : part.usesList1;
          if (!usesList || part.direct) continue;
          final globalX4 = mbX * 4 + part.x ~/ 4;
          final globalY4 = mbY * 4 + part.y ~/ 4;
          final ref = syntax
              .decodeReferenceIndex(
                list: list,
                activeReferenceCount: activeReferenceCount,
                left: motion.referenceNeighbor(list, globalX4 - 1, globalY4),
                top: motion.referenceNeighbor(list, globalX4, globalY4 - 1),
              )
              .value;
          if (list == CabacReferenceList.l0) {
            part.referenceIndexL0 = ref;
          } else {
            part.referenceIndexL1 = ref;
          }
          final key = '${list.name}:$ref';
          referenceCounts[key] = (referenceCounts[key] ?? 0) + 1;
          referenceRecords.add('$address:${part.index}:${list.name}:$ref');
          motion.fillReference(
            list: list,
            x4: globalX4,
            y4: globalY4,
            width4: part.width ~/ 4,
            height4: part.height ~/ 4,
            referenceIndex: ref,
          );
        }
      }

      for (final list in CabacReferenceList.values) {
        for (final part in mbParts) {
          final usesList = list == CabacReferenceList.l0
              ? part.usesList0
              : part.usesList1;
          if (!usesList || part.direct) continue;
          final referenceIndex = list == CabacReferenceList.l0
              ? part.referenceIndexL0!
              : part.referenceIndexL1!;
          for (final sub in part.subPartitions) {
            final globalX4 = mbX * 4 + sub.x ~/ 4;
            final globalY4 = mbY * 4 + sub.y ~/ 4;
            final mvd = syntax.decodeMotionVectorDifference(
              left: motion.mvdNeighbor(list, globalX4 - 1, globalY4),
              top: motion.mvdNeighbor(list, globalX4, globalY4 - 1),
            );
            motion.fillMvd(
              list: list,
              x4: globalX4,
              y4: globalY4,
              width4: sub.width ~/ 4,
              height4: sub.height ~/ 4,
              mvd: mvd,
            );
            motionPartitionCount++;
            final record =
                '$address:${part.index}:${sub.index}:${list.name}:'
                'r$referenceIndex:${mvd.horizontal},${mvd.vertical}';
            motionRecords.add(record);
            final key = '${list.name}:${mvd.horizontal},${mvd.vertical}';
            mvdCounts[key] = (mvdCounts[key] ?? 0) + 1;
            motionHash = _hashValues(motionHash, <int>[
              address,
              part.index,
              sub.index,
              list.index,
              referenceIndex,
              sub.x,
              sub.y,
              sub.width,
              sub.height,
              mvd.horizontal,
              mvd.vertical,
            ]);
            if (mvd.horizontal != 0 || mvd.vertical != 0) {
              nonzeroMvdExamples.add(record);
            }
          }
        }
      }
    } else {
      fail('Unexpected B mb_type=$code at mb=$address');
    }

    if (isTarget) {
      targetCheckpoints.add(
        '$address:prediction=${_arithmeticCheckpoint(arithmetic)}',
      );
    }
    final ffmpegSymbol = _ffmpegMacroblockSymbol(code, decodedSubTypes);
    ffmpegMacroblockMapHash = _hashValues(ffmpegMacroblockMapHash, <int>[
      address,
      _ffmpegSymbolIds[ffmpegSymbol]!,
    ]);
    ffmpegSymbolCounts[ffmpegSymbol] =
        (ffmpegSymbolCounts[ffmpegSymbol] ?? 0) + 1;

    final cbp = isI16
        ? type.intra16x16CodedBlockPattern!
        : syntax.decodeCodedBlockPattern(neighbors: neighbors);
    if (isTarget) {
      targetCheckpoints.add(
        '$address:cbp${cbp.packed}=${_arithmeticCheckpoint(arithmetic)}',
      );
    }
    cbpCounts[cbp.packed] = (cbpCounts[cbp.packed] ?? 0) + 1;
    if (cbp.packed != 0) nonzeroCbp[address] = cbp.packed;
    if ((isInter || isDirect) &&
        isCabacTransformSize8x8FlagPresent(
          transform8x8ModeFlag: pps.transform8x8ModeFlag,
          macroblockType: type,
          codedBlockPattern: cbp,
          subMacroblockTypes: decodedSubTypes,
          direct8x8InferenceFlag: header.sps.direct8x8InferenceFlag,
        )) {
      transform8 = syntax.decodeTransformSize8x8Flag(neighbors: neighbors);
    }
    if (transform8) transform8Addresses.add(address);
    if (isTarget) {
      targetCheckpoints.add(
        '$address:transform${transform8 ? 1 : 0}='
        '${_arithmeticCheckpoint(arithmetic)}',
      );
    }
    var qpDelta = 0;
    if (isI16 || cbp.packed != 0) {
      qpDelta = syntax.decodeMbQpDelta();
    } else {
      syntax.noteMacroblockWithoutQpDelta();
    }
    qpDeltaCounts[qpDelta] = (qpDeltaCounts[qpDelta] ?? 0) + 1;
    if (qpDelta != 0) nonzeroQp[address] = qpDelta;
    qpY = (qpY + qpDelta + 52) % 52;
    qpYAtAddress[address] = qpY;
    if (isTarget) {
      targetCheckpoints.add(
        '$address:qp$qpDelta/qpy$qpY=${_arithmeticCheckpoint(arithmetic)}',
      );
    }

    final state = _Mb(
      neighbor: CabacMacroblockNeighbor(
        skipped: false,
        direct: isDirect,
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
    if (isTarget) {
      targetCheckpoints.add(
        '$address:residual=${_arithmeticCheckpoint(arithmetic)}',
      );
    }
    final end = syntax.decodeEndOfSliceFlag();
    if (isTarget) {
      targetCheckpoints.add(
        '$address:eos${end ? 1 : 0}=${_arithmeticCheckpoint(arithmetic)}',
      );
    }
    if (end) {
      eosAddress = address;
      break;
    }
  }

  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect(skipped, 3442);
  expect(nonSkipAddresses, <int>[
    1186,
    1192,
    1193,
    1194,
    1195,
    1340,
    1344,
    1345,
    1346,
    1348,
    1349,
    1350,
    1354,
    1422,
    1423,
    1425,
    1426,
    1427,
    1428,
    1432,
    1500,
    1501,
    1502,
    1503,
    1504,
    1505,
    1506,
    1507,
    1510,
    1574,
    1578,
    1579,
    1580,
    1581,
    1582,
    1583,
    1584,
    1585,
    1652,
    1656,
    1657,
    1658,
    1660,
    1661,
    1662,
    1730,
    1734,
    1735,
    1739,
    1813,
    1814,
    1816,
    1817,
    1821,
    1887,
    1891,
    1892,
    1894,
    1895,
    1972,
    1977,
    2044,
    2049,
    2054,
    2131,
    2282,
    2283,
    2284,
  ]);
  expect(inter, 22);
  expect(directMacroblocks, 17);
  expect(intra, 29);
  expect(typeCounts, <int, int>{
    11: 1,
    1: 7,
    2: 12,
    24: 10,
    23: 14,
    25: 2,
    0: 17,
    28: 1,
    44: 1,
    22: 2,
    30: 1,
  });
  expect(typeAddresses, <int, List<int>>{
    11: <int>[1186],
    1: <int>[1192, 1423, 1427, 1510, 1821, 2283, 2284],
    2: <int>[
      1193,
      1194,
      1354,
      1507,
      1574,
      1585,
      1652,
      1977,
      2044,
      2054,
      2131,
      2282,
    ],
    24: <int>[1195, 1340, 1422, 1506, 1578, 1584, 1735, 1739, 1813, 1894],
    23: <int>[
      1344,
      1348,
      1350,
      1432,
      1656,
      1657,
      1662,
      1730,
      1814,
      1816,
      1817,
      1887,
      1891,
      1892,
    ],
    25: <int>[1345, 1349],
    0: <int>[
      1346,
      1425,
      1426,
      1501,
      1502,
      1503,
      1504,
      1505,
      1579,
      1580,
      1581,
      1582,
      1660,
      1734,
      1895,
      1972,
      2049,
    ],
    28: <int>[1428],
    44: <int>[1500],
    22: <int>[1583, 1658],
    30: <int>[1661],
  });
  expect(macroblockHash.toRadixString(16), '33d96097d4bde790');

  // Normalized from FFmpeg's independent `-debug mb_type` map for the same
  // presentation frame n=33. The unsigned FNV-1a map hash is
  // 8b8191ba4f60966e; Dart renders the signed 64-bit value below.
  expect(ffmpegSymbolCounts, <String, int>{
    'd': 3442,
    'X|': 1,
    '>': 7,
    '<': 12,
    'I': 15,
    'i': 14,
    'D': 17,
    'X+': 2,
  });
  expect(ffmpegMacroblockMapHash.toRadixString(16), '-747e6e45b09f6992');

  // ref_idx is decoded once per outer MB partition, all L0 partitions before
  // all L1 partitions. MVD then follows list, mbPartIdx, subPartIdx order.
  expect(subTypeCounts, <int, int>{0: 5, 1: 3});
  expect(subTypeRecords, <String>[
    '1583:0:0',
    '1583:1:0',
    '1583:2:1',
    '1583:3:0',
    '1658:0:0',
    '1658:1:0',
    '1658:2:1',
    '1658:3:1',
  ]);
  expect(mbPartitionCount, 46);
  expect(motionPartitionCount, 24);
  expect(referenceCounts, <String, int>{'l0:0': 9, 'l1:0': 13, 'l0:1': 2});
  expect(referenceRecords, <String>[
    '1186:1:l0:0',
    '1186:0:l1:0',
    '1192:0:l0:0',
    '1193:0:l1:0',
    '1194:0:l1:0',
    '1354:0:l1:0',
    '1423:0:l0:0',
    '1427:0:l0:0',
    '1507:0:l1:0',
    '1510:0:l0:1',
    '1574:0:l1:0',
    '1583:2:l0:0',
    '1585:0:l1:0',
    '1652:0:l1:0',
    '1658:2:l0:0',
    '1658:3:l0:0',
    '1821:0:l0:0',
    '1977:0:l1:0',
    '2044:0:l1:0',
    '2054:0:l1:0',
    '2131:0:l1:0',
    '2282:0:l1:0',
    '2283:0:l0:0',
    '2284:0:l0:1',
  ]);
  expect(mvdCounts, <String, int>{
    'l0:0,0': 8,
    'l1:0,0': 8,
    'l0:-1,0': 1,
    'l1:8,0': 2,
    'l0:0,-4': 1,
    'l1:-10,0': 2,
    'l0:24,0': 1,
    'l1:-28,0': 1,
  });
  expect(motionRecords, <String>[
    '1186:1:0:l0:r0:0,0',
    '1186:0:0:l1:r0:0,0',
    '1192:0:0:l0:r0:-1,0',
    '1193:0:0:l1:r0:0,0',
    '1194:0:0:l1:r0:0,0',
    '1354:0:0:l1:r0:8,0',
    '1423:0:0:l0:r0:0,0',
    '1427:0:0:l0:r0:0,-4',
    '1507:0:0:l1:r0:0,0',
    '1510:0:0:l0:r1:0,0',
    '1574:0:0:l1:r0:-10,0',
    '1583:2:0:l0:r0:24,0',
    '1585:0:0:l1:r0:0,0',
    '1652:0:0:l1:r0:-10,0',
    '1658:2:0:l0:r0:0,0',
    '1658:3:0:l0:r0:0,0',
    '1821:0:0:l0:r0:0,0',
    '1977:0:0:l1:r0:0,0',
    '2044:0:0:l1:r0:-28,0',
    '2054:0:0:l1:r0:8,0',
    '2131:0:0:l1:r0:0,0',
    '2282:0:0:l1:r0:0,0',
    '2283:0:0:l0:r0:0,0',
    '2284:0:0:l0:r1:0,0',
  ]);
  expect(nonzeroMvdExamples, <String>[
    '1192:0:0:l0:r0:-1,0',
    '1354:0:0:l1:r0:8,0',
    '1427:0:0:l0:r0:0,-4',
    '1574:0:0:l1:r0:-10,0',
    '1583:2:0:l0:r0:24,0',
    '1652:0:0:l1:r0:-10,0',
    '2044:0:0:l1:r0:-28,0',
    '2054:0:0:l1:r0:8,0',
  ]);
  expect(motionHash.toRadixString(16), '-12c4031432469b73');
  expect(targetCheckpoints, <String>[
    '1186:start=96/404/397:type11=105/304/134',
    '1186:prediction=109/264/92',
    '1186:cbp0=111/404/369',
    '1186:transform0=111/404/369',
    '1186:qp0/qpy18=111/404/369',
    '1186:residual=111/404/369',
    '1186:eos0=111/402/369',
    '1583:start=1272/424/42:type22=1275/350/340',
    '1583:prediction=1296/460/97',
    '1583:cbp15=1301/504/339',
    '1583:transform1=1301/405/339',
    '1583:qp-4/qpy31=1308/432/131',
    '1583:residual=1337/420/112',
    '1583:eos0=1337/418/112',
    '1658:start=1432/302/39:type22=1435/340/316',
    '1658:prediction=1448/472/62',
    '1658:cbp15=1451/416/21',
    '1658:transform1=1451/335/21',
    '1658:qp11/qpy37=1459/272/44',
    '1658:residual=1486/492/477',
    '1658:eos0=1486/490/477',
  ]);

  expect(chromaModes, <int, int>{0: 20, 2: 4, 1: 5});
  expect(intra8Predicted, 30);
  expect(intra8Remaining, 10);
  expect(intra4Predicted, 56);
  expect(intra4Remaining, 8);
  expect(intraModeHash.toRadixString(16), '-2a309b0318a74e76');
  expect(transform8Addresses, <int>[
    1346,
    1348,
    1423,
    1425,
    1426,
    1427,
    1432,
    1501,
    1502,
    1503,
    1504,
    1505,
    1579,
    1580,
    1581,
    1582,
    1583,
    1657,
    1658,
    1660,
    1730,
    1734,
    1814,
    1816,
    1817,
    1887,
    1891,
    1892,
    1895,
    1972,
    2049,
  ]);

  expect(cbpCounts, <int, int>{
    0: 35,
    1: 2,
    15: 9,
    39: 1,
    3: 2,
    14: 1,
    31: 1,
    16: 2,
    47: 1,
    18: 1,
    17: 1,
    10: 1,
    21: 2,
    7: 1,
    28: 1,
    22: 1,
    26: 1,
    8: 1,
    11: 3,
    4: 1,
  });
  expect(nonzeroCbp, <int, int>{
    1344: 1,
    1346: 15,
    1348: 39,
    1350: 3,
    1423: 15,
    1425: 14,
    1426: 15,
    1427: 31,
    1428: 16,
    1500: 47,
    1501: 18,
    1502: 17,
    1503: 10,
    1504: 21,
    1505: 21,
    1579: 7,
    1580: 28,
    1581: 22,
    1582: 26,
    1583: 15,
    1657: 1,
    1658: 15,
    1660: 15,
    1661: 16,
    1662: 8,
    1734: 15,
    1814: 11,
    1816: 3,
    1891: 4,
    1892: 11,
    1895: 15,
    1972: 11,
    2049: 15,
  });
  expect(qpDeltaCounts, <int, int>{
    0: 42,
    18: 1,
    -2: 2,
    -8: 3,
    8: 2,
    9: 3,
    -4: 2,
    5: 2,
    -5: 2,
    11: 1,
    -19: 1,
    15: 1,
    3: 1,
    -18: 1,
    6: 1,
    -6: 1,
    2: 1,
    -3: 1,
  });
  expect(nonzeroQp, <int, int>{
    1346: 18,
    1348: -2,
    1349: -8,
    1350: 8,
    1422: -8,
    1423: 9,
    1500: -4,
    1501: 5,
    1506: -2,
    1578: -8,
    1579: 9,
    1583: -4,
    1657: -5,
    1658: 11,
    1661: -19,
    1662: 15,
    1734: 3,
    1735: -18,
    1813: 8,
    1814: 6,
    1816: -6,
    1891: 5,
    1892: -5,
    1895: 9,
    1972: 2,
    2049: -3,
  });
  expect(qpYAtAddress, <int, int>{
    1186: 18,
    1192: 18,
    1193: 18,
    1194: 18,
    1195: 18,
    1340: 18,
    1344: 18,
    1345: 18,
    1346: 36,
    1348: 34,
    1349: 26,
    1350: 34,
    1354: 34,
    1422: 26,
    1423: 35,
    1425: 35,
    1426: 35,
    1427: 35,
    1428: 35,
    1432: 35,
    1500: 31,
    1501: 36,
    1502: 36,
    1503: 36,
    1504: 36,
    1505: 36,
    1506: 34,
    1507: 34,
    1510: 34,
    1574: 34,
    1578: 26,
    1579: 35,
    1580: 35,
    1581: 35,
    1582: 35,
    1583: 31,
    1584: 31,
    1585: 31,
    1652: 31,
    1656: 31,
    1657: 26,
    1658: 37,
    1660: 37,
    1661: 18,
    1662: 33,
    1730: 33,
    1734: 36,
    1735: 18,
    1739: 18,
    1813: 26,
    1814: 32,
    1816: 26,
    1817: 26,
    1821: 26,
    1887: 26,
    1891: 31,
    1892: 26,
    1894: 26,
    1895: 35,
    1972: 37,
    1977: 37,
    2044: 37,
    2049: 34,
    2054: 34,
    2131: 34,
    2282: 34,
    2283: 34,
    2284: 34,
  });

  expect(residual.codedBlocks, <String, int>{
    'luma4x4': 5,
    'luma8x8': 76,
    'chromaDc420': 12,
    'chromaAc420': 3,
    'lumaDc16x16': 7,
    'lumaAc16x16': 2,
  });
  expect(residual.coefficients, <String, int>{
    'luma4x4': 10,
    'luma8x8': 116,
    'chromaDc420': 20,
    'chromaAc420': 5,
    'lumaDc16x16': 15,
    'lumaAc16x16': 2,
  });
  expect(residual.macroblockAddresses.toList()..sort(), <int>[
    1344,
    1346,
    1348,
    1349,
    1350,
    1422,
    1423,
    1425,
    1426,
    1427,
    1428,
    1500,
    1501,
    1502,
    1503,
    1504,
    1505,
    1578,
    1579,
    1580,
    1581,
    1582,
    1583,
    1657,
    1658,
    1660,
    1661,
    1662,
    1734,
    1813,
    1814,
    1816,
    1891,
    1892,
    1894,
    1895,
    1972,
    2049,
  ]);
  expect(
    residual.footprint.where(
      (record) => record.startsWith('1583:') || record.startsWith('1658:'),
    ),
    <String>[
      '1583:luma8x8:0:0:6',
      '1583:luma8x8:1:0:5',
      '1583:luma8x8:2:0:-5',
      '1583:luma8x8:3:0:6',
      '1658:luma8x8:0:0:3',
      '1658:luma8x8:1:0:2,1:1',
      '1658:luma8x8:2:0:-3',
      '1658:luma8x8:3:0:-3',
    ],
  );
  expect(residual.hash.toRadixString(16), '18555418f1d72149');

  expect(arithmetic.isTerminated, isTrue);
  expect(arithmetic.bitPosition, 2330);
  expect(arithmetic.range, 444);
  expect(arithmetic.offset, 445);
  expect(header.reader.bitsLeft, 6);
}

const _ffmpegSymbolIds = <String, int>{
  'd': 0,
  'D': 1,
  '>': 2,
  '<': 3,
  'X': 4,
  '>-': 5,
  '<-': 6,
  'X-': 7,
  '>|': 8,
  '<|': 9,
  'X|': 10,
  '>+': 11,
  '<+': 12,
  'X+': 13,
  'i': 14,
  'I': 15,
};

String _ffmpegMacroblockSymbol(
  int code,
  List<CabacSubMacroblockType> subTypes,
) {
  if (code == 0) return 'D';
  if (code == 23) return 'i';
  if (code >= 24) return 'I';

  var usesList0 = false;
  var usesList1 = false;
  String suffix;
  if (code == 22) {
    suffix = '+';
    for (final type in subTypes) {
      usesList0 |= type.usesList0 || type.direct;
      usesList1 |= type.usesList1 || type.direct;
    }
  } else {
    final parts = _buildBMacroblockParts(code);
    usesList0 = parts.any((part) => part.usesList0 || part.direct);
    usesList1 = parts.any((part) => part.usesList1 || part.direct);
    suffix = code <= 3 ? '' : (code.isEven ? '-' : '|');
  }
  final direction = usesList0 && usesList1
      ? 'X'
      : usesList0
      ? '>'
      : '<';
  return '$direction$suffix';
}

List<_MbPart> _buildBMacroblockParts(int code) {
  if (code == 0) {
    return <_MbPart>[
      _MbPart(
        index: 0,
        x: 0,
        y: 0,
        width: 16,
        height: 16,
        usesList0: false,
        usesList1: false,
        direct: true,
      ),
    ];
  }
  if (code >= 1 && code <= 3) {
    return <_MbPart>[
      _MbPart(
        index: 0,
        x: 0,
        y: 0,
        width: 16,
        height: 16,
        usesList0: code != 2,
        usesList1: code != 1,
      ),
    ];
  }
  if (code < 4 || code > 21) {
    throw ArgumentError.value(code, 'code', 'not a partitioned B mb_type');
  }

  final (firstL0, firstL1, secondL0, secondL1) = switch ((code - 4) >> 1) {
    0 => (true, false, true, false),
    1 => (false, true, false, true),
    2 => (true, false, false, true),
    3 => (false, true, true, false),
    4 => (true, false, true, true),
    5 => (false, true, true, true),
    6 => (true, true, true, false),
    7 => (true, true, false, true),
    8 => (true, true, true, true),
    _ => throw ArgumentError.value(code, 'code'),
  };
  final is16x8 = code.isEven;
  return <_MbPart>[
    _MbPart(
      index: 0,
      x: 0,
      y: 0,
      width: is16x8 ? 16 : 8,
      height: is16x8 ? 8 : 16,
      usesList0: firstL0,
      usesList1: firstL1,
    ),
    _MbPart(
      index: 1,
      x: is16x8 ? 0 : 8,
      y: is16x8 ? 8 : 0,
      width: is16x8 ? 16 : 8,
      height: is16x8 ? 8 : 16,
      usesList0: secondL0,
      usesList1: secondL1,
    ),
  ];
}

final class _MbPart {
  _MbPart({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.usesList0,
    required this.usesList1,
    this.direct = false,
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
  final bool usesList0;
  final bool usesList1;
  final bool direct;
  final List<_SubPart> subPartitions = <_SubPart>[];
  int? referenceIndexL0;
  int? referenceIndexL1;

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
  int referenceIndexL0 = -1;
  int referenceIndexL1 = -1;
  bool usesList0 = false;
  bool usesList1 = false;
  bool intra = false;
  bool direct = false;
  CabacMotionVectorDifference mvdL0 = _zeroMvd;
  CabacMotionVectorDifference mvdL1 = _zeroMvd;
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

  CabacReferenceNeighbor referenceNeighbor(
    CabacReferenceList list,
    int x4,
    int y4,
  ) {
    final cell = _at(x4, y4);
    if (cell == null) return const CabacReferenceNeighbor.unavailable();
    final usesList = list == CabacReferenceList.l0
        ? cell.usesList0
        : cell.usesList1;
    return CabacReferenceNeighbor(
      direct: cell.direct,
      intra: cell.intra,
      referenceIndex: usesList
          ? (list == CabacReferenceList.l0
                ? cell.referenceIndexL0
                : cell.referenceIndexL1)
          : -1,
    );
  }

  CabacMvdNeighbor mvdNeighbor(CabacReferenceList list, int x4, int y4) {
    final cell = _at(x4, y4);
    if (cell == null) return const CabacMvdNeighbor.unavailable();
    final usesList = list == CabacReferenceList.l0
        ? cell.usesList0
        : cell.usesList1;
    final mvd = usesList && !cell.direct && !cell.intra
        ? (list == CabacReferenceList.l0 ? cell.mvdL0 : cell.mvdL1)
        : _zeroMvd;
    return CabacMvdNeighbor(horizontal: mvd.horizontal, vertical: mvd.vertical);
  }

  void fill({
    required int x4,
    required int y4,
    required int width4,
    required int height4,
    bool usesList0 = false,
    bool usesList1 = false,
    bool intra = false,
    bool direct = false,
  }) {
    for (var y = y4; y < y4 + height4; y++) {
      for (var x = x4; x < x4 + width4; x++) {
        _cells[y * this.width4 + x] = _MotionCell()
          ..usesList0 = usesList0
          ..usesList1 = usesList1
          ..intra = intra
          ..direct = direct
          ..referenceIndexL0 = usesList0 ? 0 : -1
          ..referenceIndexL1 = usesList1 ? 0 : -1;
      }
    }
  }

  void fillReference({
    required CabacReferenceList list,
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
          ..intra = false
          ..direct = false;
        if (list == CabacReferenceList.l0) {
          cell
            ..usesList0 = true
            ..referenceIndexL0 = referenceIndex;
        } else {
          cell
            ..usesList1 = true
            ..referenceIndexL1 = referenceIndex;
        }
      }
    }
  }

  void fillMvd({
    required CabacReferenceList list,
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
        _cells[index] = cell;
        if (list == CabacReferenceList.l0) {
          cell.mvdL0 = mvd;
        } else {
          cell.mvdL1 = mvd;
        }
      }
    }
  }
}

const _zeroMvd = CabacMotionVectorDifference(horizontal: 0, vertical: 0);

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
  var codedMask = 0;
  if (mb != null) {
    for (var index = 0; index < mb.lumaCoded.length; index++) {
      if (mb.lumaCoded[index]) codedMask |= 1 << index;
    }
  }
  return deriveCabacLumaCodedBlockNeighbor(
    macroblockAvailable: mb != null,
    transformSize8x8: mb?.transform8 ?? false,
    codedBlockPatternLuma: mb?.neighbor.codedBlockPatternLuma ?? 0,
    lumaCodedMask: codedMask,
    blockX: bx,
    blockY: by,
  );
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

String _arithmeticCheckpoint(H264CabacDecoder decoder) =>
    '${decoder.bitPosition}/${decoder.range}/${decoder.offset}';

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
