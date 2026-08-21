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
  test('decodes exact sfux first Intra4x4 P POC 26 through termination', () {
    // Fourteenth decode-order/presentation picture, POC 26. Reproduced from
    // /tmp/sfux-audit.N51PSH/250_00000.ts with:
    // /private/tmp/ndvy-ffmpeg/ffmpeg -hide_banner -loglevel error -threads 1
    // -i /tmp/sfux-audit.N51PSH/250_00000.ts -map 0:v:0 -an
    // -f framehash -hash sha256 -
    // Frame n=13 cropped-I420 SHA-256:
    // 60050f2a440f023b484b8a7d4ea7876026b2d36c10becce5a70ff5a662b9123c
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419b2d44784210fa5a2170540dd0540e400084fffc8400000300000300000f3efd6f7ea0a417faa3bb1987cdb30673b75bdbe26700adea8cebe618b44b657ec4fd5183c5a8bf4d9b16d616fdb1c31257d60110d28e1e3d235a8f217b074ca0fa1f3f1c2501715a6abe337364f765719f66d4b9ea4f7265b4df9569b818a8f9513964da61d71bd8e48fceb380957d11510d06ccbd699334de565ed102a119a9e4899abbd5158caeeba95fa79c677bad4a3443e9329c70ed5a1479664a1177fe0dae7716649de8e199298c2a69f5afaca891e44cc84dd1f7b9b58579f4516febce54d1c4dd43dd651300c81c1382cba3a1476ba3efecaafe17b745f8015031daf7b7862bacfa2df8f1c5b18d4e3ff11658c35217f7f182d40247bd3b6cd13aa3f633cbf2735f9b8253816eefe8037613381303ba4b2033551f346b0a2b9841fa0d4000000300019f',
    );
    expect(vcl, hasLength(327));
    expect(
      sha256.convert(vcl).toString(),
      'a7cdc66d6b923bc825e53e3e951ea1116ebf0fe74f7c8c4e67a0037d6bc546f1',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 2584);
    expect(header.sliceType, H264SliceType.p);
    expect(header.nalRefIdc, 2);
    expect(header.frameNum, 9);
    expect(header.picOrderCntLsb, 26);
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
        (0, 1),
        (1, 0),
        (0, 1),
      ],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -9);
    expect(header.sliceQpY, 16);
    expect(header.dataBitOffset, 149);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);
    final weights = header.predictionWeightTable!;
    expect(
      (weights.lumaLog2WeightDenom, weights.chromaLog2WeightDenom),
      (4, 0),
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
        (21, -27, '1,1', '0,0'),
        (21, -28, '1,1', '0,0'),
        (16, 0, '1,1', '0,0'),
        (16, 0, '1,1', '0,0'),
        (16, 0, '1,1', '0,0'),
        (16, 0, '1,1', '0,0'),
        (16, 0, '1,1', '0,0'),
        (16, 0, '1,1', '0,0'),
      ],
    );
    expect(weights.list1, isEmpty);

    const before = <H264ShortTermReference<int>>[
      H264ShortTermReference(frameNum: 3, pictureOrderCount: 10, value: 10),
      H264ShortTermReference(frameNum: 4, pictureOrderCount: 16, value: 16),
      H264ShortTermReference(frameNum: 5, pictureOrderCount: 12, value: 12),
      H264ShortTermReference(frameNum: 6, pictureOrderCount: 20, value: 20),
      H264ShortTermReference(frameNum: 7, pictureOrderCount: 22, value: 22),
      H264ShortTermReference(frameNum: 8, pictureOrderCount: 24, value: 24),
    ];
    final list0 = buildPReferenceList0<int>(
      shortTermReferences: before,
      currentFrameNum: 9,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCount: 8,
      modifications: header.refPicListModificationsL0,
    );
    expect(list0.map((r) => r.value), <int>[24, 24, 24, 22, 20, 16, 12, 10]);
    expect(
      identical(list0[0], list0[1]) && identical(list0[1], list0[2]),
      isTrue,
    );
    final current = H264ShortTermReference<int>(
      frameNum: 9,
      pictureOrderCount: 26,
      value: 26,
    );
    final marked = applyShortTermDpbMarking<int>(
      shortTermReferences: before,
      currentPicture: current,
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: 2,
      adaptiveRefPicMarkingModeFlag: false,
    );
    expect(marked.removed.map((r) => r.value), <int>[10]);
    expect(marked.references.map((r) => r.value), <int>[
      16,
      12,
      20,
      22,
      24,
      26,
    ]);
    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 3);
  expect(header.reader.bitPos, 152);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 152);
  expect(arithmetic.bitPosition, 161);
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
  final macroblockCheckpoints = <String>[];
  final chromaModes = <int, int>{};
  var eosAddress = -1;

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
      }
      for (var block = 0; block < (transform8 ? 4 : 16); block++) {
        final modeStartBit = arithmetic.bitPosition;
        final bx = transform8 ? 0 : _blockX[block];
        final by = transform8 ? 0 : _blockY[block];
        final raster = by * 4 + bx;
        final leftMode = transform8
            ? const (available: false, mode: 2)
            : bx > 0
            ? (available: true, mode: decodedIntra4Modes![raster - 1])
            : _intra4ModeNeighbor(
                left,
                bx: 3,
                by: by,
                constrainedIntra: pps.constrainedIntraPredFlag,
              );
        final topMode = transform8
            ? const (available: false, mode: 2)
            : by > 0
            ? (available: true, mode: decodedIntra4Modes![raster - 4])
            : _intra4ModeNeighbor(
                top,
                bx: bx,
                by: 3,
                constrainedIntra: pps.constrainedIntraPredFlag,
              );
        final predicted = transform8
            ? null
            : mostProbableIntra4x4Mode(
                leftAvail: leftMode.available,
                topAvail: topMode.available,
                leftMode: leftMode.mode,
                topMode: topMode.mode,
              );
        final mode = transform8
            ? syntax.decodeIntra8x8Mode()
            : syntax.decodeIntra4x4Mode(predictedMode: predicted);
        if (transform8) {
          mode.usesPredictedMode ? intra8Predicted++ : intra8Remaining++;
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
    _decodeResidual(
      syntax: syntax,
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
    if (address == 1497) {
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
  expect((skipped, nonSkipAddresses.length, inter, intra), (3403, 107, 7, 100));
  expect(typeCounts, <int, int>{
    5: 60,
    11: 3,
    7: 9,
    8: 3,
    6: 22,
    0: 6,
    10: 3,
    2: 1,
  });
  expect(macroblockHash.toRadixString(16), '2eb08d56c2be9271');
  expect(typeAddresses[0], <int>[1501, 1576, 1737, 1741, 1821, 2205]);
  expect(typeAddresses[2], <int>[1507]);
  expect(subTypeCounts, isEmpty);
  expect((mbPartitionCount, motionPartitionCount), (8, 8));
  expect(referenceCounts, <int, int>{0: 7, 1: 1});
  expect(mvdCounts, <String, int>{
    '0,0': 2,
    '2,0': 2,
    '-6,0': 1,
    '0,-64': 1,
    '11,0': 1,
    '8,8': 1,
  });
  expect(motionRecords, <String>[
    '1501:0:0:r0:0,0',
    '1507:0:0:r0:2,0',
    '1507:1:0:r0:-6,0',
    '1576:0:0:r0:0,-64',
    '1737:0:0:r1:0,0',
    '1741:0:0:r0:11,0',
    '1821:0:0:r0:2,0',
    '2205:0:0:r0:8,8',
  ]);
  expect(motionHash.toRadixString(16), '6b1274b6ef7b05dd');
  expect(chromaModes, <int, int>{0: 86, 1: 10, 2: 4});
  expect(
    (intra8Predicted, intra8Remaining, intra4Predicted, intra4Remaining),
    (179, 57, 14, 2),
  );
  expect(intraModeHash.toRadixString(16), '-568ffbf908463f2f');
  expect(intra4Addresses, <int>[1497]);
  expect(intra4Records, <String>[
    '1497:s0:r0:L1/2:T1/2:mpm2:prev0:rem0:mode0:bits981>985',
    '1497:s1:r1:L1/0:T1/2:mpm0:prev0:rem0:mode1:bits985>988',
    '1497:s2:r4:L1/2:T1/0:mpm0:prev1:rem-1:mode0:bits988>989',
    '1497:s3:r5:L1/0:T1/1:mpm0:prev1:rem-1:mode0:bits989>989',
    '1497:s4:r2:L1/1:T1/2:mpm1:prev1:rem-1:mode1:bits989>990',
    '1497:s5:r3:L1/1:T1/2:mpm1:prev1:rem-1:mode1:bits990>990',
    '1497:s6:r6:L1/0:T1/1:mpm0:prev1:rem-1:mode0:bits990>991',
    '1497:s7:r7:L1/0:T1/1:mpm0:prev1:rem-1:mode0:bits991>991',
    '1497:s8:r8:L1/2:T1/0:mpm0:prev1:rem-1:mode0:bits991>991',
    '1497:s9:r9:L1/0:T1/0:mpm0:prev1:rem-1:mode0:bits991>992',
    '1497:s10:r12:L1/2:T1/0:mpm0:prev1:rem-1:mode0:bits992>992',
    '1497:s11:r13:L1/0:T1/0:mpm0:prev1:rem-1:mode0:bits992>992',
    '1497:s12:r10:L1/0:T1/0:mpm0:prev1:rem-1:mode0:bits992>992',
    '1497:s13:r11:L1/0:T1/0:mpm0:prev1:rem-1:mode0:bits992>993',
    '1497:s14:r14:L1/0:T1/0:mpm0:prev1:rem-1:mode0:bits993>993',
    '1497:s15:r15:L1/0:T1/0:mpm0:prev1:rem-1:mode0:bits993>993',
  ]);
  expect(macroblockCheckpoints, <String>[
    '1497:start978:afterStart980:afterPred994:afterCbp999:afterQp1004:afterResidual1021:afterEos1021:eos0',
  ]);
  expect(cbpCounts, <int, int>{
    5: 3,
    0: 60,
    4: 5,
    16: 11,
    12: 1,
    15: 1,
    1: 13,
    27: 1,
    24: 1,
    17: 1,
    18: 1,
    19: 1,
    10: 1,
    11: 3,
    8: 1,
    6: 1,
    3: 2,
  });
  expect(nonzeroCbp[1497], 1);
  expect(transform8Addresses, isNot(contains(1497)));
  expect(transform8Addresses, hasLength(62));
  expect(qpDeltaCounts, <int, int>{
    9: 8,
    0: 60,
    3: 1,
    -3: 2,
    2: 4,
    -2: 3,
    -7: 2,
    7: 1,
    -8: 7,
    6: 1,
    10: 2,
    -10: 2,
    11: 2,
    -9: 5,
    -4: 2,
    8: 3,
    4: 1,
    -14: 1,
  });
  expect(nonzeroQp[1497], -2);
  expect(residual.codedBlocks, <String, int>{
    'luma8x8': 55,
    'chromaDc420': 18,
    'lumaDc16x16': 24,
    'luma4x4': 1,
  });
  expect(residual.coefficients, <String, int>{
    'luma8x8': 57,
    'chromaDc420': 20,
    'lumaDc16x16': 62,
    'luma4x4': 1,
  });
  expect(residual.footprint.where((item) => item.startsWith('1497:')), <String>[
    '1497:luma4x4:0:0:2',
  ]);
  expect(residual.hash.toRadixString(16), '236abf91c9284487');
  expect(arithmetic.isTerminated, isTrue);
  expect(
    (
      arithmetic.bitPosition,
      arithmetic.range,
      arithmetic.offset,
      header.reader.bitsLeft,
    ),
    (2584, 414, 415, 0),
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
    mode: mb.usesIntra4x4 ? mb.intra4Modes[by * 4 + bx] : 2,
  );
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
