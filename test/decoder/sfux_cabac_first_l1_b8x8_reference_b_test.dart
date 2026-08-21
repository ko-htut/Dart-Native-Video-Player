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
  test('decodes exact sfux first L1 B_8x8 submacroblock reference B AU123', () {
    // 124th decode-order picture, presentation frame n=123 / POC 246.
    // Reproduced from /tmp/sfux-audit.N51PSH/250_00000.ts (278428 bytes,
    // SHA-256 810dbefb730b8658f2404106610143bb71aba2d67a7d56ee26c92af2dbb50ebe),
    // video PTS 501375 at 90 kHz. Authoritative FFmpeg `-f framehash
    // -hash sha256` presentation-frame n=123 SHA-256:
    // 691c9dab19386704d26a0b5cd0aa2c0b57cec9c8d290c8f19ebf5ab7154b69ae
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419e5b6594645c27ff0000030000030000ed2d289bbb7bfa8575e14f4872d7583618024bf2132a7335d9e21b7380aa0b002d0b6362d5ead6f19e8e24d424d5533b1345d55754559dd2aaea8df1dd9d7289a873782890af961afb709f2f2a91a2fa15b85c9bc7fc0d9649ace792c942acbc130281c44222400000030000030366',
    );
    expect(vcl, hasLength(128));
    expect(
      sha256.convert(vcl).toString(),
      '8583d53733326501375bb956b7ca34ce028af695a37fe59a194a688163ba25ed',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 984);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.b);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 2);
    expect(header.picOrderCntLsb, 54);
    expect(header.directSpatialMvPredFlag, isTrue);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 5);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(header.refPicListModificationsL0, isEmpty);
    expect(header.refPicListModificationsL1, isEmpty);
    expect(pps.weightedBipredIdc, 2);
    expect(header.predictionWeightTable, isNull);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -9);
    expect(header.sliceQpY, 16);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.dataBitOffset, 58);
    expect(header.adaptiveRefPicMarkingModeFlag, isTrue);
    expect(
      header.memoryManagementOperations.map(
        (operation) =>
            (operation.operation, operation.differenceOfPicNumsMinus1),
      ),
      <(int, int?)>[(1, 5), (1, 4)],
    );

    // Seed every reference-picture POC LSB through AU122. Non-reference B
    // pictures deliberately do not advance the type-0 reference state.
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
      12,
      8,
      20,
      16,
      22,
      24,
      26,
      30,
      34,
      42,
      38,
      46,
      48,
      52,
      60,
      56,
      62,
      2,
      10,
      6,
      18,
      14,
      26,
      22,
      34,
      30,
      42,
      38,
      50,
      46,
      56,
      52,
      62,
      58,
      2,
      4,
      6,
      8,
      10,
      12,
      14,
      16,
      18,
      20,
      22,
      24,
      26,
      28,
      30,
      32,
      34,
      36,
      38,
      40,
      42,
      44,
      46,
      50,
      58,
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
    expect(poc.picOrderCntMsb, 192);
    expect(poc.picOrderCntLsb, 54);
    expect(poc.pictureOrderCount, 246);

    final reference232 = H264ShortTermReference<String>(
      frameNum: 12,
      pictureOrderCount: 232,
      value: 'AU116/POC232',
    );
    final reference234 = H264ShortTermReference<String>(
      frameNum: 13,
      pictureOrderCount: 234,
      value: 'AU117/POC234',
    );
    final reference236 = H264ShortTermReference<String>(
      frameNum: 14,
      pictureOrderCount: 236,
      value: 'AU118/POC236',
    );
    final reference238 = H264ShortTermReference<String>(
      frameNum: 15,
      pictureOrderCount: 238,
      value: 'AU119/POC238',
    );
    final reference242 = H264ShortTermReference<String>(
      frameNum: 0,
      pictureOrderCount: 242,
      value: 'AU120/POC242',
    );
    final reference250 = H264ShortTermReference<String>(
      frameNum: 1,
      pictureOrderCount: 250,
      value: 'AU122/POC250',
    );
    final beforeAu123 = <H264ShortTermReference<String>>[
      reference232,
      reference234,
      reference236,
      reference238,
      reference242,
      reference250,
    ];
    final lists = buildBReferenceLists<String>(
      shortTermReferences: beforeAu123,
      currentFrameNum: header.frameNum,
      currentPictureOrderCount: poc.pictureOrderCount,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCountL0: header.numRefIdxL0ActiveMinus1 + 1,
      activeReferenceCountL1: header.numRefIdxL1ActiveMinus1 + 1,
      modificationsL0: header.refPicListModificationsL0,
      modificationsL1: header.refPicListModificationsL1,
    );
    expect(lists.list0.map((reference) => reference.pictureOrderCount), <int?>[
      242,
      238,
      236,
      234,
      232,
    ]);
    expect(lists.list1.map((reference) => reference.pictureOrderCount), <int?>[
      250,
    ]);
    expect(identical(lists.list0[0], reference242), isTrue);
    expect(identical(lists.list0[1], reference238), isTrue);
    expect(identical(lists.list0[2], reference236), isTrue);
    expect(identical(lists.list0[3], reference234), isTrue);
    expect(identical(lists.list0[4], reference232), isTrue);
    expect(identical(lists.list1.single, reference250), isTrue);

    final current = H264ShortTermReference<String>(
      frameNum: 2,
      pictureOrderCount: 246,
      value: 'AU123/POC246',
    );
    final operations = header.memoryManagementOperations;
    final firstMmco = applyShortTermMmco1<String>(
      shortTermReferences: beforeAu123,
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      operation: operations[0],
    );
    expect(firstMmco.picNumX, -4);
    expect(identical(firstMmco.removed, reference232), isTrue);
    expect(
      firstMmco.remaining.map((reference) => reference.pictureOrderCount),
      <int?>[234, 236, 238, 242, 250],
    );
    final secondMmco = applyShortTermMmco1<String>(
      shortTermReferences: firstMmco.remaining,
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      operation: operations[1],
    );
    expect(secondMmco.picNumX, -3);
    expect(identical(secondMmco.removed, reference234), isTrue);
    expect(
      secondMmco.remaining.map((reference) => reference.pictureOrderCount),
      <int?>[236, 238, 242, 250],
    );
    final afterAu123 = applyShortTermDpbMarking<String>(
      shortTermReferences: beforeAu123,
      currentPicture: current,
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: header.nalRefIdc,
      adaptiveRefPicMarkingModeFlag: header.adaptiveRefPicMarkingModeFlag,
      memoryManagementOperations: header.memoryManagementOperations,
    );
    expect(afterAu123.appendedCurrentPicture, isTrue);
    expect(afterAu123.removed, <H264ShortTermReference<String>>[
      reference232,
      reference234,
    ]);
    expect(
      afterAu123.references.map((reference) => reference.pictureOrderCount),
      <int?>[236, 238, 242, 250, 246],
    );
    expect(identical(afterAu123.references[0], reference236), isTrue);
    expect(identical(afterAu123.references[1], reference238), isTrue);
    expect(identical(afterAu123.references[2], reference242), isTrue);
    expect(identical(afterAu123.references[3], reference250), isTrue);
    expect(identical(afterAu123.references[4], current), isTrue);

    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 6);
  expect(header.reader.bitPos, 64);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 64);
  expect(arithmetic.bitPosition, 73);
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
    final isTarget = code == 22;
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
  expect(skipped, 3449);
  expect(nonSkipAddresses, <int>[
    1188,
    1193,
    1267,
    1268,
    1273,
    1348,
    1349,
    1350,
    1423,
    1425,
    1427,
    1432,
    1444,
    1497,
    1501,
    1504,
    1505,
    1509,
    1574,
    1584,
    1586,
    1588,
    1652,
    1656,
    1659,
    1661,
    1662,
    1666,
    1730,
    1734,
    1736,
    1739,
    1740,
    1742,
    1813,
    1816,
    1819,
    1823,
    1832,
    1835,
    1836,
    1891,
    1892,
    1894,
    1897,
    1898,
    1972,
    1973,
    1975,
    1998,
    2002,
    2044,
    2045,
    2046,
    2049,
    2124,
    2126,
    2282,
    2283,
    2284,
    2285,
  ]);
  expect(inter, 48);
  expect(directMacroblocks, 1);
  expect(intra, 12);
  expect(typeCounts, <int, int>{
    2: 38,
    1: 5,
    4: 1,
    9: 1,
    23: 2,
    0: 1,
    11: 2,
    24: 2,
    28: 2,
    25: 5,
    29: 1,
    22: 1,
  });
  expect(typeAddresses, <int, List<int>>{
    2: <int>[
      1188,
      1267,
      1268,
      1273,
      1425,
      1427,
      1432,
      1497,
      1501,
      1504,
      1509,
      1586,
      1652,
      1656,
      1659,
      1662,
      1730,
      1734,
      1736,
      1740,
      1742,
      1816,
      1819,
      1823,
      1832,
      1835,
      1894,
      1897,
      1973,
      1975,
      2002,
      2045,
      2046,
      2049,
      2124,
      2126,
      2282,
      2285,
    ],
    1: <int>[1193, 1349, 1423, 1661, 1666],
    4: <int>[1348],
    9: <int>[1350],
    23: <int>[1444, 1574],
    0: <int>[1505],
    11: <int>[1584, 1972],
    24: <int>[1588, 1739],
    28: <int>[1813, 1891],
    25: <int>[1836, 1998, 2044, 2283, 2284],
    29: <int>[1892],
    22: <int>[1898],
  });
  expect(macroblockHash.toRadixString(16), '-949bb7b90df9681');

  // Normalized from FFmpeg's independent -debug mb_type map for
  // presentation frame n=123. Every address/category matches; the full-map
  // FNV-1a hash is 5cd236a55bf6b613.
  expect(ffmpegSymbolCounts, <String, int>{
    'd': 3449,
    '<': 38,
    '>': 5,
    '>-': 1,
    'X|': 3,
    'i': 2,
    'D': 1,
    'I': 10,
    'X+': 1,
  });
  expect(ffmpegMacroblockMapHash.toRadixString(16), '5cd236a55bf6b613');

  expect(subTypeCounts, <int, int>{0: 3, 2: 1});
  expect(subTypeRecords, <String>[
    '1898:0:0',
    '1898:1:2',
    '1898:2:0',
    '1898:3:0',
  ]);
  expect(mbPartitionCount, 56);
  expect(motionPartitionCount, 52);
  expect(referenceCounts, <String, int>{'l1:0': 42, 'l0:0': 10});
  expect(referenceRecords, <String>[
    '1188:0:l1:0',
    '1193:0:l0:0',
    '1267:0:l1:0',
    '1268:0:l1:0',
    '1273:0:l1:0',
    '1348:0:l0:0',
    '1348:1:l0:0',
    '1349:0:l0:0',
    '1350:0:l0:0',
    '1350:1:l1:0',
    '1423:0:l0:0',
    '1425:0:l1:0',
    '1427:0:l1:0',
    '1432:0:l1:0',
    '1497:0:l1:0',
    '1501:0:l1:0',
    '1504:0:l1:0',
    '1509:0:l1:0',
    '1584:1:l0:0',
    '1584:0:l1:0',
    '1586:0:l1:0',
    '1652:0:l1:0',
    '1656:0:l1:0',
    '1659:0:l1:0',
    '1661:0:l0:0',
    '1662:0:l1:0',
    '1666:0:l0:0',
    '1730:0:l1:0',
    '1734:0:l1:0',
    '1736:0:l1:0',
    '1740:0:l1:0',
    '1742:0:l1:0',
    '1816:0:l1:0',
    '1819:0:l1:0',
    '1823:0:l1:0',
    '1832:0:l1:0',
    '1835:0:l1:0',
    '1894:0:l1:0',
    '1897:0:l1:0',
    '1898:1:l1:0',
    '1972:1:l0:0',
    '1972:0:l1:0',
    '1973:0:l1:0',
    '1975:0:l1:0',
    '2002:0:l1:0',
    '2045:0:l1:0',
    '2046:0:l1:0',
    '2049:0:l1:0',
    '2124:0:l1:0',
    '2126:0:l1:0',
    '2282:0:l1:0',
    '2285:0:l1:0',
  ]);
  expect(mvdCounts, <String, int>{
    'l1:-1,0': 1,
    'l0:0,0': 7,
    'l1:0,0': 33,
    'l0:0,1': 2,
    'l0:0,27': 1,
    'l1:0,1': 3,
    'l1:-7,0': 1,
    'l1:0,-1': 1,
    'l1:1,0': 3,
  });
  expect(motionRecords, <String>[
    '1188:0:0:l1:r0:-1,0',
    '1193:0:0:l0:r0:0,0',
    '1267:0:0:l1:r0:0,0',
    '1268:0:0:l1:r0:0,0',
    '1273:0:0:l1:r0:0,0',
    '1348:0:0:l0:r0:0,1',
    '1348:1:0:l0:r0:0,0',
    '1349:0:0:l0:r0:0,1',
    '1350:0:0:l0:r0:0,27',
    '1350:1:0:l1:r0:0,0',
    '1423:0:0:l0:r0:0,0',
    '1425:0:0:l1:r0:0,0',
    '1427:0:0:l1:r0:0,0',
    '1432:0:0:l1:r0:0,0',
    '1497:0:0:l1:r0:0,0',
    '1501:0:0:l1:r0:0,1',
    '1504:0:0:l1:r0:0,0',
    '1509:0:0:l1:r0:0,0',
    '1584:1:0:l0:r0:0,0',
    '1584:0:0:l1:r0:0,0',
    '1586:0:0:l1:r0:0,0',
    '1652:0:0:l1:r0:0,0',
    '1656:0:0:l1:r0:0,0',
    '1659:0:0:l1:r0:0,0',
    '1661:0:0:l0:r0:0,0',
    '1662:0:0:l1:r0:0,0',
    '1666:0:0:l0:r0:0,0',
    '1730:0:0:l1:r0:-7,0',
    '1734:0:0:l1:r0:0,0',
    '1736:0:0:l1:r0:0,0',
    '1740:0:0:l1:r0:0,0',
    '1742:0:0:l1:r0:0,0',
    '1816:0:0:l1:r0:0,0',
    '1819:0:0:l1:r0:0,0',
    '1823:0:0:l1:r0:0,-1',
    '1832:0:0:l1:r0:0,1',
    '1835:0:0:l1:r0:0,1',
    '1894:0:0:l1:r0:1,0',
    '1897:0:0:l1:r0:0,0',
    '1898:1:0:l1:r0:0,0',
    '1972:1:0:l0:r0:0,0',
    '1972:0:0:l1:r0:0,0',
    '1973:0:0:l1:r0:0,0',
    '1975:0:0:l1:r0:0,0',
    '2002:0:0:l1:r0:1,0',
    '2045:0:0:l1:r0:0,0',
    '2046:0:0:l1:r0:0,0',
    '2049:0:0:l1:r0:0,0',
    '2124:0:0:l1:r0:0,0',
    '2126:0:0:l1:r0:0,0',
    '2282:0:0:l1:r0:1,0',
    '2285:0:0:l1:r0:0,0',
  ]);
  expect(nonzeroMvdExamples, <String>[
    '1188:0:0:l1:r0:-1,0',
    '1348:0:0:l0:r0:0,1',
    '1349:0:0:l0:r0:0,1',
    '1350:0:0:l0:r0:0,27',
    '1501:0:0:l1:r0:0,1',
    '1730:0:0:l1:r0:-7,0',
    '1823:0:0:l1:r0:0,-1',
    '1832:0:0:l1:r0:0,1',
    '1835:0:0:l1:r0:0,1',
    '1894:0:0:l1:r0:1,0',
    '2002:0:0:l1:r0:1,0',
    '2282:0:0:l1:r0:1,0',
  ]);
  expect(motionHash.toRadixString(16), '-2f912c85de9c9f19');
  expect(targetCheckpoints, <String>[
    '1898:start=760/261/237:type22=764/263/247',
    '1898:prediction=775/297/2',
    '1898:cbp0=776/506/4',
    '1898:transform0=776/506/4',
    '1898:qp0/qpy16=776/506/4',
    '1898:residual=776/506/4',
    '1898:eos0=776/504/4',
  ]);

  expect(chromaModes, <int, int>{0: 5, 2: 3, 1: 4});
  expect(intra8Predicted, 8);
  expect(intra8Remaining, 0);
  expect(intra4Predicted, 0);
  expect(intra4Remaining, 0);
  expect(intraModeHash.toRadixString(16), '3d7bc8d80291cce1');
  expect(transform8Addresses, <int>[1444, 1574]);

  expect(cbpCounts, <int, int>{0: 56, 16: 5});
  expect(nonzeroCbp, <int, int>{
    1350: 16,
    1505: 16,
    1813: 16,
    1891: 16,
    1892: 16,
  });
  expect(qpDeltaCounts, <int, int>{0: 59, 9: 1, -9: 1});
  expect(nonzeroQp, <int, int>{1350: 9, 1588: -9});
  expect(qpYAtAddress, <int, int>{
    1188: 16,
    1193: 16,
    1267: 16,
    1268: 16,
    1273: 16,
    1348: 16,
    1349: 16,
    1350: 25,
    1423: 25,
    1425: 25,
    1427: 25,
    1432: 25,
    1444: 25,
    1497: 25,
    1501: 25,
    1504: 25,
    1505: 25,
    1509: 25,
    1574: 25,
    1584: 25,
    1586: 25,
    1588: 16,
    1652: 16,
    1656: 16,
    1659: 16,
    1661: 16,
    1662: 16,
    1666: 16,
    1730: 16,
    1734: 16,
    1736: 16,
    1739: 16,
    1740: 16,
    1742: 16,
    1813: 16,
    1816: 16,
    1819: 16,
    1823: 16,
    1832: 16,
    1835: 16,
    1836: 16,
    1891: 16,
    1892: 16,
    1894: 16,
    1897: 16,
    1898: 16,
    1972: 16,
    1973: 16,
    1975: 16,
    1998: 16,
    2002: 16,
    2044: 16,
    2045: 16,
    2046: 16,
    2049: 16,
    2124: 16,
    2126: 16,
    2282: 16,
    2283: 16,
    2284: 16,
    2285: 16,
  });

  expect(residual.codedBlocks, <String, int>{'chromaDc420': 7});
  expect(residual.coefficients, <String, int>{'chromaDc420': 12});
  expect(residual.macroblockAddresses, <int>{1350, 1505, 1813, 1891, 1892});
  expect(residual.footprint, <String>[
    '1350:chromaDc420:1:0:-1,1:-1',
    '1505:chromaDc420:1:0:-2',
    '1813:chromaDc420:0:0:1,1:1,2:-1,3:-1',
    '1891:chromaDc420:0:0:-1,1:-1',
    '1891:chromaDc420:1:0:2',
    '1892:chromaDc420:0:0:2',
    '1892:chromaDc420:1:0:-2',
  ]);
  expect(residual.hash.toRadixString(16), '334d05b36045b82e');

  expect(arithmetic.isTerminated, isTrue);
  expect(arithmetic.bitPosition, 983);
  expect(arithmetic.range, 434);
  expect(arithmetic.offset, 435);
  expect(header.reader.bitsLeft, 1);
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
