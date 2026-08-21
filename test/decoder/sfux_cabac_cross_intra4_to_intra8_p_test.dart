import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_slice_data.dart';
import 'package:ndvy_player/src/decoder/intra4x4_mpm.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/reference_picture_list.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

const _blockX = <int>[0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3];
const _blockY = <int>[0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3];

void main() {
  test('decodes exact sfux AU19 P POC 38 through termination', () {
    // Twentieth decode-order/presentation picture, POC 38. Reproduced from
    // /tmp/sfux-audit.N51PSH/250_00000.ts with:
    // /private/tmp/ndvy-ffmpeg/ffmpeg -hide_banner -loglevel error -threads 1
    // -i /tmp/sfux-audit.N51PSH/250_00000.ts -map 0:v:0 -an
    // -f framehash -hash sha256 -
    // Frame n=19 deblocked cropped-I420 SHA-256:
    // 6c5beebf067f0f621a985fbc85c2a1dc09bc1b6b88139afdee11af0079a8e510
    // With -skip_loop_filter all, raw reconstruction SHA-256:
    // b1118dd05e2a6ce871f729210a0213c8997c85977fbe12a145e796e59f3f9ddd
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419bb344784210ffc8734051010e0408118330144045000213fffc8400000300000300000f96ff878e16895905f823e443d7c5f73a5bb8069242fbabf9fd3e5cd36dd71305148d583a8c76416758530d7ce2ee8a837c0d4109a53344fc58565ed39043e08017b349294a26820f2f861b7c14f4a75da8392784055727fcd8d0485b3ad3b5b12945aeed69120dea2095390ceb3d4db756fde5df51109f6e7f1cccb3c22d76d34d97f1290f51663c3a6b86d311592171e3c26e293c8263c5f8e9c11b89e02220038d7202edbf22f64e9d5fa8242f55d6455cceabdac4f27dc5bd3517cdae57116345baeaaffd596f3fd35ad5054202632a4fd1de603701f13cb3116c7f3847b14e159f7972ca205989af3ed8a74570786f8a6a27ecd2bfac7adacaa3a7f1e6f592bc431d9d79aa2e4334f1ae512dcad8107e895736c5f7c88f45a0ff909e17f794145869f9d838c7493ee43b563369f107878d948c01209b33573899f3a7c60ea50e8d1e9cc032302fbd2ee2f24072a6c5364a3c8e693ffe22fbf558e9655d8d9f0f0ebe5f4890240c174c9f2e15501d8ec887272868dddb4899c73f1fab43f02285472f8b43887b5f78c61cd58a96c7cb900d2bb0ccd7cf5d594498ba1c95d65176c37f40f840e90a62e085bbcfecae84a3c390bbbbcd0f0bf778c6cb272c251ffe5bed23994d9e1813131ebbcd9d69ea2c90fa5f7134bc7f8a4844fd29d27da2f89cfe45f3fca9fb926c314e7403a259f6973023c01e13cb7c1054287f6192bd087327740d2da719b260e1d01c87dd0b08f2268775d3cb2dfc601d39335a44078c3ddc7d4c06fa77a64c68ec926cebcbca3f53bb3d6a02a166770d9a4898302c13791acede57581dc0',
    );
    expect(vcl, hasLength(623));
    expect(
      sha256.convert(vcl).toString(),
      '9f8e4a134682362ebfe6259bdc9b064d3bc2fa6c77c7a4b77f9fcced90703ee4',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 4960);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.p);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 13);
    expect(header.picOrderCntLsb, 38);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 8);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(
      header.refPicListModificationsL0.map((m) => (m.idc, m.value)),
      <(int, int)>[
        (0, 0),
        (0, 15),
        (0, 15),
        (0, 0),
        (0, 0),
        (0, 0),
        (0, 0),
        (0, 0),
      ],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -9);
    expect(header.sliceQpY, 16);
    expect(header.dataBitOffset, 195);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);
    final weights = header.predictionWeightTable!;
    expect(
      (weights.lumaLog2WeightDenom, weights.chromaLog2WeightDenom),
      (6, 5),
    );
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
        (81, -33, '32,35', '0,-12'),
        (81, -34, '32,32', '0,0'),
        (64, 0, '32,32', '0,0'),
        (64, 0, '32,32', '0,0'),
        (64, 0, '32,32', '0,0'),
        (64, 0, '32,32', '0,0'),
        (64, 0, '32,32', '0,0'),
        (64, 0, '32,32', '0,0'),
      ],
    );
    expect(weights.list1, isEmpty);

    // AU14's MMCO1 removes frame_num 5/4 (POC 12/16); AU16's MMCO1
    // removes frame_num 6 (POC 20). AU15/AU17 are non-reference B pictures.
    const before = <H264ShortTermReference<int>>[
      H264ShortTermReference(frameNum: 7, pictureOrderCount: 22, value: 22),
      H264ShortTermReference(frameNum: 8, pictureOrderCount: 24, value: 24),
      H264ShortTermReference(frameNum: 9, pictureOrderCount: 26, value: 26),
      H264ShortTermReference(frameNum: 10, pictureOrderCount: 30, value: 30),
      H264ShortTermReference(frameNum: 11, pictureOrderCount: 34, value: 34),
      H264ShortTermReference(frameNum: 12, pictureOrderCount: 36, value: 36),
    ];
    final list0 = buildPReferenceList0<int>(
      shortTermReferences: before,
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
      modifications: header.refPicListModificationsL0,
    );
    expect(list0.map((r) => r.value), <int>[36, 36, 36, 34, 30, 26, 24, 22]);
    expect(
      identical(list0[0], list0[1]) && identical(list0[1], list0[2]),
      isTrue,
    );
    final current = H264ShortTermReference<int>(
      frameNum: 13,
      pictureOrderCount: 38,
      value: 38,
    );
    final marked = applyShortTermDpbMarking<int>(
      shortTermReferences: before,
      currentPicture: current,
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: 2,
      adaptiveRefPicMarkingModeFlag: false,
    );
    expect(marked.removed.map((r) => r.value), <int>[22]);
    expect(marked.references.map((r) => r.value), <int>[
      24,
      26,
      30,
      34,
      36,
      38,
    ]);
    expect(identical(marked.references.last, current), isTrue);
    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 5);
  expect(header.reader.bitPos, 200);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 200);
  expect(arithmetic.bitPosition, 209);
  expect(arithmetic.range, 510);
  expect(arithmetic.offset, 505);
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
  final qpYAtAddress = <int, int>{};
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
  final intra4Addresses = <int>[];
  final intra4Records = <String>[];
  final crossModeRecords = <String>[];
  final macroblockCheckpoints = <String>[];
  final chromaModes = <int, int>{};
  var eosAddress = -1;
  var qpY = header.sliceQpY;

  for (var address = 0; address < mbCount; address++) {
    final macroblockStartBit = arithmetic.bitPosition;
    final mbX = address % mbWidth;
    final mbY = address ~/ mbWidth;
    final left = mbX == 0 ? null : states[address - 1];
    final top = mbY == 0 ? null : states[address - mbWidth];
    final neighbors = CabacMacroblockNeighbors(
      left: left?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
      top: top?.neighbor ?? const CabacMacroblockNeighbor.unavailable(),
    );
    final start = syntax.decodeMacroblockStart(neighbors: neighbors);
    final afterStartBit = arithmetic.bitPosition;
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
    List<int>? decodedIntra4Modes;
    List<int>? decodedIntra8Modes;
    final decodedSubTypes = <CabacSubMacroblockType>[];
    if (isNxn) {
      if (isCabacTransformSize8x8FlagPresent(
        transform8x8ModeFlag: pps.transform8x8ModeFlag,
        macroblockType: type,
      )) {
        transform8 = syntax.decodeTransformSize8x8Flag(neighbors: neighbors);
      }
      if (!transform8) {
        intra4Addresses.add(address);
        decodedIntra4Modes = List<int>.filled(16, 2);
      } else {
        decodedIntra8Modes = List<int>.filled(4, 2);
      }
      for (var block = 0; block < (transform8 ? 4 : 16); block++) {
        final modeStartBit = arithmetic.bitPosition;
        final bx = transform8 ? (block & 1) * 2 : _blockX[block];
        final by = transform8 ? (block >> 1) * 2 : _blockY[block];
        final raster = by * 4 + bx;
        final leftMode = bx > 0
            ? (
                available: true,
                mode: transform8
                    ? decodedIntra8Modes![block - 1]
                    : decodedIntra4Modes![raster - 1],
              )
            : _intra4ModeNeighbor(
                left,
                bx: 3,
                by: by,
                constrainedIntra: pps.constrainedIntraPredFlag,
              );
        final topMode = by > 0
            ? (
                available: true,
                mode: transform8
                    ? decodedIntra8Modes![block - 2]
                    : decodedIntra4Modes![raster - 4],
              )
            : _intra4ModeNeighbor(
                top,
                bx: bx,
                by: 3,
                constrainedIntra: pps.constrainedIntraPredFlag,
              );
        final predicted = mostProbableIntra4x4Mode(
          leftAvail: leftMode.available,
          topAvail: topMode.available,
          leftMode: leftMode.mode,
          topMode: topMode.mode,
        );
        final mode = transform8
            ? syntax.decodeIntra8x8Mode(predictedMode: predicted)
            : syntax.decodeIntra4x4Mode(predictedMode: predicted);
        if (address >= 1341 && address <= 1343) {
          crossModeRecords.add(
            '$address:${transform8 ? 'I8' : 'I4'}:s$block:r$raster:'
            'L${leftMode.available ? 1 : 0}/${leftMode.mode}:'
            'T${topMode.available ? 1 : 0}/${topMode.mode}:'
            'mpm$predicted:prev${mode.usesPredictedMode ? 1 : 0}:'
            'rem${mode.remainingMode ?? -1}:mode${mode.mode}:'
            'bits$modeStartBit>${arithmetic.bitPosition}',
          );
        }
        if (transform8) {
          mode.usesPredictedMode ? intra8Predicted++ : intra8Remaining++;
          decodedIntra8Modes![block] = mode.mode!;
        } else {
          mode.usesPredictedMode ? intra4Predicted++ : intra4Remaining++;
          decodedIntra4Modes![raster] = mode.mode!;
          intra4Records.add(
            '$address:s$block:r$raster:'
            'L${leftMode.available ? 1 : 0}/${leftMode.mode}:'
            'T${topMode.available ? 1 : 0}/${topMode.mode}:'
            'mpm$predicted:prev${mode.usesPredictedMode ? 1 : 0}:'
            'rem${mode.remainingMode ?? -1}:mode${mode.mode}:'
            'bits$modeStartBit>${arithmetic.bitPosition}',
          );
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

    final afterPredictionBit = arithmetic.bitPosition;
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
    final afterCbpBit = arithmetic.bitPosition;
    var qpDelta = 0;
    if (isI16 || cbp.packed != 0) {
      qpDelta = syntax.decodeMbQpDelta();
    } else {
      syntax.noteMacroblockWithoutQpDelta();
    }
    qpDeltaCounts[qpDelta] = (qpDeltaCounts[qpDelta] ?? 0) + 1;
    if (qpDelta != 0) nonzeroQp[address] = qpDelta;
    qpY = (qpY + qpDelta + 52) % 52;
    if (address == 2049) qpYAtAddress[address] = qpY;
    final afterQpBit = arithmetic.bitPosition;

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
    if (decodedIntra4Modes != null) {
      state.intra4Modes.setAll(0, decodedIntra4Modes);
    }
    if (decodedIntra8Modes != null) {
      state.intra8Modes.setAll(0, decodedIntra8Modes);
    }
    _decodeResidual(
      syntax: syntax,
      arithmetic: arithmetic,
      state: state,
      left: left,
      top: top,
      address: address,
      cbp: cbp,
      summary: residual,
    );
    final afterResidualBit = arithmetic.bitPosition;
    states[address] = state;
    final end = syntax.decodeEndOfSliceFlag();
    if (address == 1815) {
      macroblockCheckpoints.add(
        '$address:start$macroblockStartBit:afterStart$afterStartBit:'
        'afterPred$afterPredictionBit:afterCbp$afterCbpBit:'
        'afterQp$afterQpBit:afterResidual$afterResidualBit:'
        'afterEos${arithmetic.bitPosition}:eos${end ? 1 : 0}',
      );
    }
    if (end) {
      eosAddress = address;
      break;
    }
  }

  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect(
    (skipped, nonSkipAddresses.length, inter, intra),
    (3356, 154, 33, 121),
  );
  expect(typeCounts, <int, int>{
    5: 93,
    7: 5,
    8: 3,
    15: 2,
    11: 3,
    6: 9,
    2: 4,
    10: 5,
    0: 28,
    12: 1,
    1: 1,
  });
  expect(macroblockHash.toRadixString(16), '8c7840189d36420');
  expect(typeAddresses[0], hasLength(28));
  expect(typeAddresses[1], hasLength(1));
  expect(typeAddresses[2], hasLength(4));
  expect(typeAddresses[3], isNull);
  expect(typeAddresses[4], isNull);
  expect(subTypeCounts, isEmpty);
  expect((mbPartitionCount, motionPartitionCount), (38, 38));
  expect(referenceCounts, <int, int>{0: 25, 1: 12, 2: 1});
  expect(mvdCounts.values.fold<int>(0, (sum, value) => sum + value), 38);
  expect(nonzeroMvdExamples, hasLength(12));
  expect(motionRecords, hasLength(38));
  expect(motionHash.toRadixString(16), '4fd1c64bc963f122');
  expect(chromaModes, <int, int>{0: 109, 1: 7, 2: 5});
  expect(
    (intra8Predicted, intra8Remaining, intra4Predicted, intra4Remaining),
    (223, 141, 28, 4),
  );
  expect(intraModeHash.toRadixString(16), '2b6763877108b500');
  expect(intra4Addresses, <int>[1342, 2049]);
  expect(intra4Records, hasLength(32));
  expect(qpYAtAddress, <int, int>{2049: 28});
  expect(macroblockCheckpoints, isEmpty);
  expect(
    crossModeRecords.where((record) => record.startsWith('1343:')),
    <String>[
      '1343:I8:s0:r0:L1/0:T1/2:mpm0:prev0:rem1:mode2:bits797>802',
      '1343:I8:s1:r2:L1/2:T1/2:mpm2:prev0:rem0:mode0:bits802>805',
      '1343:I8:s2:r8:L1/0:T1/2:mpm0:prev1:rem-1:mode0:bits805>805',
      '1343:I8:s3:r10:L1/0:T1/0:mpm0:prev1:rem-1:mode0:bits805>806',
    ],
  );
  expect(cbpCounts, <int, int>{
    0: 62,
    12: 1,
    8: 2,
    4: 8,
    5: 9,
    15: 17,
    11: 4,
    32: 3,
    16: 10,
    17: 2,
    1: 4,
    14: 5,
    2: 4,
    13: 5,
    29: 1,
    3: 3,
    10: 6,
    7: 5,
    6: 2,
    9: 1,
  });
  expect(
    (nonzeroCbp[1341], nonzeroCbp[1342], nonzeroCbp[1343]),
    (15, 11, null),
  );
  expect(transform8Addresses, containsAll(<int>[1341, 1343]));
  expect(transform8Addresses, isNot(contains(1342)));
  expect(qpDeltaCounts, <int, int>{
    0: 72,
    4: 5,
    -2: 14,
    10: 3,
    -6: 4,
    9: 5,
    -9: 2,
    2: 2,
    -3: 3,
    6: 4,
    -4: 5,
    3: 11,
    -7: 5,
    -8: 3,
    -5: 5,
    5: 3,
    -11: 1,
    8: 1,
    17: 1,
    -10: 2,
    7: 2,
    11: 1,
  });
  expect(
    nonzeroQp.keys.where((address) => address >= 1341 && address <= 1343),
    isEmpty,
  );
  expect(residual.codedBlocks, <String, int>{
    'luma8x8': 187,
    'lumaDc16x16': 11,
    'luma4x4': 7,
    'chromaDc420': 18,
    'chromaAc420': 7,
  });
  expect(residual.coefficients, <String, int>{
    'luma8x8': 269,
    'lumaDc16x16': 35,
    'luma4x4': 7,
    'chromaDc420': 36,
    'chromaAc420': 10,
  });
  expect(
    residual.footprint.where((item) {
      final address = int.parse(item.split(':').first);
      return address >= 1341 && address <= 1343;
    }),
    <String>[
      '1341:luma8x8:0:0:-1',
      '1341:luma8x8:1:0:-3,1:-3',
      '1341:luma8x8:2:1:3',
      '1341:luma8x8:3:1:-1',
      '1342:luma4x4:0:0:-4',
      '1342:luma4x4:2:1:-1',
      '1342:luma4x4:10:0:2',
      '1342:luma4x4:11:1:1',
    ],
  );
  expect(residual.checkpoints, isEmpty);
  expect(residual.hash.toRadixString(16), '1a2ba1bd56a66230');
  expect(arithmetic.isTerminated, isTrue);
  expect(
    (
      arithmetic.bitPosition,
      arithmetic.range,
      arithmetic.offset,
      header.reader.bitsLeft,
    ),
    (4954, 502, 503, 6),
  );
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
  final intra4Modes = List<int>.filled(16, 2);
  final intra8Modes = List<int>.filled(4, 2);
  bool get usesIntra4x4 => isIntra && !isI16 && !transform8;
  bool lumaDcCoded = false;
  bool cbDcCoded = false;
  bool crDcCoded = false;
  final lumaCoded = List<bool>.filled(16, false);
  final cbCoded = List<bool>.filled(4, false);
  final crCoded = List<bool>.filled(4, false);
}

({bool available, int mode}) _intra4ModeNeighbor(
  _Mb? mb, {
  required int bx,
  required int by,
  required bool constrainedIntra,
}) {
  if (mb == null || (constrainedIntra && !mb.isIntra)) {
    return (available: false, mode: 2);
  }
  return (
    available: true,
    mode: mb.usesIntra4x4
        ? mb.intra4Modes[by * 4 + bx]
        : mb.isIntra && !mb.isI16 && mb.transform8
        ? mb.intra8Modes[(by >> 1) * 2 + (bx >> 1)]
        : 2,
  );
}

final class _ResidualSummary {
  final codedBlocks = <String, int>{};
  final coefficients = <String, int>{};
  final macroblockAddresses = <int>{};
  final footprint = <String>[];
  final checkpoints = <String>[];
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
  required H264CabacDecoder arithmetic,
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
        final leftNeighbor = bx > 0
            ? _lumaBlock(state, bx - 1, by, isI16: state.isI16)
            : _lumaBlock(left, 3, by, isI16: state.isI16);
        final topNeighbor = by > 0
            ? _lumaBlock(state, bx, by - 1, isI16: state.isI16)
            : _lumaBlock(top, bx, 3, isI16: state.isI16);
        final blockStart = arithmetic.bitPosition;
        final rangeStart = arithmetic.range;
        final offsetStart = arithmetic.offset;
        final block = syntax.decodeResidualBlock(
          category: category,
          currentMacroblockIntra: state.isIntra,
          left: leftNeighbor,
          top: topNeighbor,
        );
        if (address == 1815) {
          summary.checkpoints.add(
            '$address:s$syntaxBlock:r${by * 4 + bx}:'
            'L${leftNeighbor.availability.name}/${leftNeighbor.coded ? 1 : 0}:'
            'T${topNeighbor.availability.name}/${topNeighbor.coded ? 1 : 0}:'
            '$blockStart/$rangeStart/$offsetStart>'
            '${arithmetic.bitPosition}/${arithmetic.range}/${arithmetic.offset}:'
            'coded${block.coded ? 1 : 0}:total${block.totalCoefficients}',
          );
        }
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
  if (!isI16) {
    var codedMask = 0;
    if (mb != null) {
      for (var index = 0; index < mb.lumaCoded.length; index++) {
        if (mb.lumaCoded[index]) codedMask |= 1 << index;
      }
    }
    return deriveCabacLuma4x4CodedBlockNeighbor(
      macroblockAvailable: mb != null,
      intra16x16: mb?.isI16 ?? false,
      transformSize8x8: mb?.transform8 ?? false,
      codedBlockPatternLuma: mb?.neighbor.codedBlockPatternLuma ?? 0,
      lumaCodedMask: codedMask,
      blockX: bx,
      blockY: by,
    );
  }
  if (mb == null) return const CabacCodedBlockNeighbor.unavailable();
  if (mb.isI16 != isI16) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  final group = ((by >> 1) << 1) | (bx >> 1);
  if ((mb.neighbor.codedBlockPatternLuma & (1 << group)) == 0) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  if (mb.transform8) {
    return const CabacCodedBlockNeighbor(coded: true);
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
