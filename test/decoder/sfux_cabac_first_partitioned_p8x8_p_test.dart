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
  test('decodes exact sfux partitioned P_8x8 P POC 44 through termination', () {
    // Twenty-third decode-order picture, presentation frame n=22 / POC 44.
    // Reproduced from /tmp/sfux-audit.N51PSH/250_00000.ts (278428 bytes,
    // SHA-256 810dbefb730b8658f2404106610143bb71aba2d67a7d56ee26c92af2dbb50ebe)
    // with:
    // /private/tmp/ndvy-ffmpeg/ffmpeg -hide_banner -loglevel error -threads 1
    // -i /tmp/sfux-audit.N51PSH/250_00000.ts -map 0:v:0 -an
    // -f framehash -hash sha256 -
    // Frame n=22 cropped-I420 SHA-256:
    // 2e34e61cff1b489aef246b6b638ff22c20c6d42e06bf0357a6ca051b1619ba18
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419bf64fe10843fc86340ac06581020460cc0ac0670008fffa5800000300000300001eadff608a3bfcceb92b7e1690b34e3e52df0e6cf694f27c87ba920575ef7c3cdb40e528b6da983e3add5fe22eb8c9c51d8e9a339d6268a7d15e13ee74793dd5711221aa51eb9722dbec1ec78ee948a96ba05c4098918482cefe93f288263cc853b382a6df7e22cf9f0232d1f458038539da05fb09ad493680f155ad11889b0911d80d86968e28eede05d50a5c5f6d70fa246d2e6dcc75c168d06dcd32b61beae7266ce87fd9199bbf91400ea2d49602c48ab1fc6de64a4ed4de021f8919638a799f7b6212a405f34627373898e3932ee344a83e3859f010ceb04d2f5b62799b38dc8273f64dd0e04bdcb07006c3c1545c8f60fc6904ca5cfba97e2ca4fa1ff3ce49bc74f73b816362717cd44d1793f919d3fc5cdda2a7cd5a279bdc5291dc62a19cbfbf26dd46a46a4cd66785a25e6bdcf3a7d189db6ddf13da72939ad68a119e699300d33b0af6ce7fb0559d981cc56e2d4720935198cd45cee8c482d29725e7fe84c3ed3245308dc8bb7b28d35f5971a1bf275f5626ecf617c5e86d2e57f7ec925c7e86d275b71390f7f0238aafe73faf1094dfb369d6e489cff1708bb804b0953beafc3c85d804f23e7d888a54c96710064a397c57d1d61cabb7421ff63b89faca125caefbc73cad40c1a36c9f641680ebe17049d7e66c069a0e9231a03fd347376f0457812ba43c4eaa0fd38abc5174eb96fca4a444a53848a01d6c78298ec41f6d29ebdf530e90ba707551cfe787d9e9a278a35332177f042734f53ace885b55a51fb8fba011766c02ca12a3a98b7e7d0129c67a6544cc23aa92c7d143d3ff40f8fa39ef576655a568a2b2dac3a6275c873e3f5bfcc78e520e9b8442a70217cc9865e82f8427fb2cc786cd5917fd2b75281575cbab3d6c5c913c95e90df1413c5c74402187b8d78b91a29eede4d954de3d5dd290a6a0cd07c478abdf0b927074b00730dcba1701dd64756a7c03014d38a21311fb831c89b56750f5acbe8ab5902a570b3951d260ecb501b40f9931d33e615778f3d62a6edadecb60a1279f41d6f9650495b6e3c01cd21fed13204b45a7950d9ef43dbe5a6e90f753cf671117050db4d8e907a1ab0c407e0c81c9da761c686dcfe63b97c9a7fc13c76047183f8d3097ae81cc130fb0ec1fe2622ce99ccdac920278cfcb65def173e8376b6b130d00691529c35fe727e243df4aaa1a57332d03344d25ab9776575eb8fa379eddaf05c5c07244567e683d5ccbeeb11ec579d9374c430ad217bc6f68ec676c2f5e82642126e542a5571f2d81290d3982ece4de2815dc89d2690dc7c9332d73e9268f1a558fd0015bd48b9a0df437886374a1157e9511675d17a5a7c7a55c059c67b448a1c783c0cdd3badc3aa0a8e180ee1a35a10a0c6c96ba2bb69d072468874d0003f25407d9a2037fceb401632309ad39504cdd587b93f31f911ca335426ef756848f47f7fd47c8411f9d56deb346ed8b24f91f8d1c78c2c537b6002f17af3ace79eb7b24a4a7529f4aa6b491253c9d280d454abb4c39a000000300003020',
    );
    expect(vcl, hasLength(1123));
    expect(
      sha256.convert(vcl).toString(),
      '52683b310a4ad91786b93b30b04bff7a46ef61f0aa5c33bc177247f8fa6ce998',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 8952);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.p);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 15);
    expect(header.picOrderCntLsb, 44);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 7);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(
      header.refPicListModificationsL0.map((m) => (m.idc, m.value)),
      <(int, int)>[(0, 0), (0, 15), (0, 15), (0, 0), (0, 0), (0, 0), (0, 0)],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -7);
    expect(header.sliceQpY, 18);
    expect(header.dataBitOffset, 183);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);
    final weights = header.predictionWeightTable!;
    expect(
      (weights.lumaLog2WeightDenom, weights.chromaLog2WeightDenom),
      (5, 5),
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
        (43, -50, '32,35', '0,-12'),
        (43, -51, '32,32', '0,0'),
        (32, 0, '32,32', '0,0'),
        (32, 0, '32,32', '0,0'),
        (32, 0, '32,32', '0,0'),
        (32, 0, '32,32', '0,0'),
        (32, 0, '32,32', '0,0'),
      ],
    );
    expect(weights.list1, isEmpty);

    // AU20's two MMCO1 operations leave five physical references. AU21 is
    // non-reference. AU22 repeats POC 42 in logical L0 slots 0/1/2 and then
    // appends POC 44 without sliding-window eviction.
    const before = <H264ShortTermReference<int>>[
      H264ShortTermReference(frameNum: 10, pictureOrderCount: 30, value: 30),
      H264ShortTermReference(frameNum: 11, pictureOrderCount: 34, value: 34),
      H264ShortTermReference(frameNum: 12, pictureOrderCount: 36, value: 36),
      H264ShortTermReference(frameNum: 13, pictureOrderCount: 38, value: 38),
      H264ShortTermReference(frameNum: 14, pictureOrderCount: 42, value: 42),
    ];
    final list0 = buildPReferenceList0<int>(
      shortTermReferences: before,
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
      modifications: header.refPicListModificationsL0,
    );
    expect(list0.map((r) => r.value), <int>[42, 42, 42, 38, 36, 34, 30]);
    expect(
      identical(list0[0], list0[1]) && identical(list0[1], list0[2]),
      isTrue,
    );
    final current = H264ShortTermReference<int>(
      frameNum: 15,
      pictureOrderCount: 44,
      value: 44,
    );
    final marked = applyShortTermDpbMarking<int>(
      shortTermReferences: before,
      currentPicture: current,
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: header.nalRefIdc,
      adaptiveRefPicMarkingModeFlag: header.adaptiveRefPicMarkingModeFlag,
      memoryManagementOperations: header.memoryManagementOperations,
    );
    expect(marked.removed, isEmpty);
    expect(marked.references.map((r) => r.value), <int>[
      30,
      34,
      36,
      38,
      42,
      44,
    ]);
    expect(identical(marked.references.last, current), isTrue);
    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 1);
  expect(header.reader.bitPos, 184);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 184);
  expect(arithmetic.bitPosition, 193);
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
  final referenceSyntax = _SyntaxMotionGrid(
    width4: mbWidth * 4,
    height4: 45 * 4,
  );
  final typeCounts = <int, int>{};
  final typeAddresses = <int, List<int>>{};
  final subTypeCounts = <int, int>{};
  final subTypeRecords = <String>[];
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
  final p8MotionRecords = <String>[];
  final p8Cbp = <int, int>{};
  final p8Transform8 = <int, bool>{};
  final p8QpDelta = <int, int>{};
  final p8QpY = <int, int>{};
  final residual = _ResidualSummary();
  var skipped = 0;
  var inter = 0;
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
  final intra4Addresses = <int>[];
  final intra4Records = <String>[];
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
      ffmpegMacroblockMapHash = _hashValues(ffmpegMacroblockMapHash, <int>[
        address,
        -1,
      ]);
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
      referenceSyntax.fill(
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
    ffmpegMacroblockMapHash = _hashValues(ffmpegMacroblockMapHash, <int>[
      address,
      code >= 6 ? 100 : code,
    ]);
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
      referenceSyntax.fill(
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
      referenceSyntax.fill(
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
        subTypeRecords.add(
          '$address:${decodedSubTypes.map((sub) => sub.codeNum).join(',')}',
        );
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
                    left: referenceSyntax.referenceNeighbor(
                      globalX4 - 1,
                      globalY4,
                    ),
                    top: referenceSyntax.referenceNeighbor(
                      globalX4,
                      globalY4 - 1,
                    ),
                  )
                  .value;
        part.referenceIndex = ref;
        referenceCounts[ref] = (referenceCounts[ref] ?? 0) + 1;
        referenceSyntax.fillReference(
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
          motion.fill(
            x4: globalX4,
            y4: globalY4,
            width4: sub.width ~/ 4,
            height4: sub.height ~/ 4,
            referenceIndex: part.referenceIndex,
            mvd: mvd,
          );
          motionPartitionCount++;
          final motionRecord =
              '$address:${part.index}:${sub.index}:r${part.referenceIndex}:'
              '${mvd.horizontal},${mvd.vertical}';
          motionRecords.add(motionRecord);
          if (code == 3 || code == 4) p8MotionRecords.add(motionRecord);
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
    if (code == 3 || code == 4) p8Cbp[address] = cbp.packed;
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
    if (code == 3 || code == 4) p8Transform8[address] = transform8;
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
    qpYAtAddress[address] = qpY;
    if (code == 3 || code == 4) {
      p8QpDelta[address] = qpDelta;
      p8QpY[address] = qpY;
    }
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
    if (code == 3 || code == 4 || address == 1893 || address == 1974) {
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

  final p8Addresses = <int>[...?typeAddresses[3], ...?typeAddresses[4]]..sort();
  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect((skipped, nonSkipAddresses.length, inter, intra), (3363, 147, 85, 62));
  expect(typeCounts, <int, int>{
    5: 49,
    0: 50,
    2: 15,
    1: 8,
    6: 6,
    12: 1,
    7: 4,
    3: 12,
    11: 1,
    18: 1,
  });
  expect(macroblockHash.toRadixString(16), '4870bbdf54762e8b');
  // FFmpeg `-debug mb_type` decode-order frame 23 reports the same 3510
  // symbols. I16 subtypes are normalized to 100 because that view exposes
  // only `I`, not the exact H.264 mb_type code.
  expect(ffmpegMacroblockMapHash.toRadixString(16), '-5f6b74e15ded8190');

  expect(typeAddresses[3], <int>[
    1419,
    1583,
    1663,
    1737,
    1810,
    1818,
    1820,
    1890,
    2045,
    2046,
    2051,
    2204,
  ]);
  expect(typeAddresses[4], isNull);
  expect(typeAddresses[0], contains(1974));
  expect(subTypeCounts, <int, int>{0: 48});
  expect(subTypeRecords, <String>[
    '1419:0,0,0,0',
    '1583:0,0,0,0',
    '1663:0,0,0,0',
    '1737:0,0,0,0',
    '1810:0,0,0,0',
    '1818:0,0,0,0',
    '1820:0,0,0,0',
    '1890:0,0,0,0',
    '2045:0,0,0,0',
    '2046:0,0,0,0',
    '2051:0,0,0,0',
    '2204:0,0,0,0',
  ]);
  expect((mbPartitionCount, motionPartitionCount), (144, 144));
  expect(referenceCounts, <int, int>{0: 94, 1: 26, 2: 23, 3: 1});
  expect(mvdCounts, <String, int>{
    '0,0': 82,
    '0,2': 3,
    '0,-8': 1,
    '0,8': 1,
    '0,1': 7,
    '-2,0': 2,
    '0,6': 1,
    '1,0': 16,
    '0,-6': 1,
    '-1,0': 8,
    '-8,0': 1,
    '1,-1': 2,
    '0,4': 1,
    '0,-1': 6,
    '2,0': 2,
    '0,-4': 1,
    '8,17': 1,
    '-1,-4': 1,
    '5,8': 1,
    '1,-2': 1,
    '1,1': 1,
    '-1,-1': 1,
    '9,0': 1,
    '0,-3': 1,
    '10,0': 1,
  });
  expect(p8MotionRecords, <String>[
    '1419:0:0:r1:1,0',
    '1419:1:0:r0:0,0',
    '1419:2:0:r0:0,0',
    '1419:3:0:r0:0,0',
    '1583:0:0:r0:0,4',
    '1583:1:0:r0:0,0',
    '1583:2:0:r0:0,0',
    '1583:3:0:r2:0,0',
    '1663:0:0:r1:0,0',
    '1663:1:0:r0:0,0',
    '1663:2:0:r0:1,0',
    '1663:3:0:r0:-1,0',
    '1737:0:0:r1:0,1',
    '1737:1:0:r0:0,-1',
    '1737:2:0:r2:0,1',
    '1737:3:0:r1:1,0',
    '1810:0:0:r2:0,0',
    '1810:1:0:r0:0,0',
    '1810:2:0:r0:1,0',
    '1810:3:0:r0:0,0',
    '1818:0:0:r2:0,0',
    '1818:1:0:r0:0,0',
    '1818:2:0:r0:0,0',
    '1818:3:0:r0:0,0',
    '1820:0:0:r0:0,0',
    '1820:1:0:r2:0,0',
    '1820:2:0:r0:0,0',
    '1820:3:0:r0:0,-4',
    '1890:0:0:r0:0,0',
    '1890:1:0:r2:0,0',
    '1890:2:0:r1:2,0',
    '1890:3:0:r0:0,0',
    '2045:0:0:r0:0,0',
    '2045:1:0:r0:-1,-4',
    '2045:2:0:r0:0,0',
    '2045:3:0:r0:0,0',
    '2046:0:0:r1:0,0',
    '2046:1:0:r0:5,8',
    '2046:2:0:r0:0,0',
    '2046:3:0:r0:0,0',
    '2051:0:0:r0:1,0',
    '2051:1:0:r0:0,0',
    '2051:2:0:r0:0,0',
    '2051:3:0:r0:-2,0',
    '2204:0:0:r0:1,0',
    '2204:1:0:r0:0,-3',
    '2204:2:0:r0:-1,0',
    '2204:3:0:r0:0,0',
  ]);
  expect(motionRecords.where((record) => record.startsWith('1974:')), <String>[
    '1974:0:0:r0:0,0',
  ]);
  expect(motionHash.toRadixString(16), '348d83d5458af378');
  expect(chromaModes, <int, int>{0: 53, 2: 5, 1: 4});
  expect(
    (intra8Predicted, intra8Remaining, intra4Predicted, intra4Remaining),
    (125, 67, 11, 5),
  );
  expect(intraModeHash.toRadixString(16), '45285e7b0175cfb8');
  expect(intra4Addresses, <int>[1971]);
  expect(intra4Records, hasLength(16));

  expect(macroblockCheckpoints, <String>[
    '1419:start1165:afterStart1168:afterPred1185:afterCbp1188:'
        'afterQp1188:afterResidual1243:afterEos1244:eos0',
    '1583:start3179:afterStart3183:afterPred3203:afterCbp3210:'
        'afterQp3210:afterResidual3210:afterEos3210:eos0',
    '1663:start3978:afterStart3981:afterPred3999:afterCbp4006:'
        'afterQp4007:afterResidual4019:afterEos4019:eos0',
    '1737:start4525:afterStart4528:afterPred4557:afterCbp4564:'
        'afterQp4570:afterResidual4606:afterEos4606:eos0',
    '1810:start4987:afterStart4990:afterPred5005:afterCbp5007:'
        'afterQp5008:afterResidual5059:afterEos5059:eos0',
    '1818:start5287:afterStart5290:afterPred5299:afterCbp5301:'
        'afterQp5307:afterResidual5344:afterEos5344:eos0',
    '1820:start5400:afterStart5403:afterPred5419:afterCbp5422:'
        'afterQp5428:afterResidual5449:afterEos5449:eos0',
    '1890:start5674:afterStart5677:afterPred5694:afterCbp5700:'
        'afterQp5704:afterResidual5716:afterEos5716:eos0',
    '1893:start5726:afterStart5733:afterPred5733:afterCbp5733:'
        'afterQp5734:afterResidual5768:afterEos5768:eos0',
    '1974:start6604:afterStart6606:afterPred6608:afterCbp6611:'
        'afterQp6613:afterResidual6693:afterEos6694:eos0',
    '2045:start6869:afterStart6872:afterPred6890:afterCbp6893:'
        'afterQp6894:afterResidual6969:afterEos6969:eos0',
    '2046:start6969:afterStart6973:afterPred7001:afterCbp7003:'
        'afterQp7008:afterResidual7128:afterEos7128:eos0',
    '2051:start7345:afterStart7348:afterPred7364:afterCbp7368:'
        'afterQp7369:afterResidual7434:afterEos7434:eos0',
    '2204:start8459:afterStart8462:afterPred8480:afterCbp8484:'
        'afterQp8486:afterResidual8554:afterEos8554:eos0',
  ]);
  expect(cbpCounts, <int, int>{
    8: 3,
    12: 2,
    9: 3,
    0: 40,
    14: 5,
    4: 5,
    15: 32,
    16: 2,
    7: 10,
    13: 6,
    2: 4,
    37: 3,
    17: 1,
    25: 2,
    36: 1,
    5: 8,
    10: 7,
    22: 1,
    32: 1,
    21: 1,
    45: 1,
    46: 1,
    1: 3,
    11: 4,
    3: 1,
  });
  expect(p8Cbp, <int, int>{
    1419: 15,
    1583: 0,
    1663: 9,
    1737: 5,
    1810: 15,
    1818: 10,
    1820: 5,
    1890: 8,
    2045: 11,
    2046: 15,
    2051: 14,
    2204: 7,
  });
  expect(nonzeroCbp[1893], 15);
  expect(nonzeroCbp[1974], 15);
  expect(transform8Addresses, hasLength(115));
  expect(p8Transform8, <int, bool>{
    1419: true,
    1583: false,
    1663: true,
    1737: false,
    1810: true,
    1818: true,
    1820: true,
    1890: true,
    2045: true,
    2046: true,
    2051: true,
    2204: true,
  });
  expect(transform8Addresses, isNot(contains(1893)));
  expect(transform8Addresses, contains(1974));
  expect(qpDeltaCounts, <int, int>{
    2: 9,
    0: 87,
    9: 3,
    -15: 1,
    7: 3,
    -14: 1,
    12: 1,
    -4: 6,
    -2: 7,
    4: 3,
    5: 3,
    -6: 2,
    -3: 2,
    10: 1,
    -11: 1,
    -5: 3,
    3: 5,
    6: 2,
    -7: 4,
    -10: 1,
    16: 1,
    -12: 1,
  });
  expect(p8QpDelta, <int, int>{
    1419: 0,
    1583: 0,
    1663: 0,
    1737: 6,
    1810: 0,
    1818: 6,
    1820: 4,
    1890: 2,
    2045: 0,
    2046: 2,
    2051: 0,
    2204: 0,
  });
  expect(p8QpY, <int, int>{
    1419: 23,
    1583: 27,
    1663: 24,
    1737: 33,
    1810: 23,
    1818: 23,
    1820: 27,
    1890: 25,
    2045: 22,
    2046: 24,
    2051: 24,
    2204: 24,
  });
  expect(nonzeroQp[1893], isNull);
  expect(qpYAtAddress[1893], 25);
  expect(nonzeroQp[1974], isNull);
  expect(qpYAtAddress[1974], 22);
  expect(residual.codedBlocks, <String, int>{
    'luma8x8': 264,
    'chromaDc420': 14,
    'lumaDc16x16': 6,
    'chromaAc420': 21,
    'luma4x4': 32,
    'lumaAc16x16': 4,
  });
  expect(residual.coefficients, <String, int>{
    'luma8x8': 997,
    'chromaDc420': 28,
    'lumaDc16x16': 15,
    'chromaAc420': 34,
    'luma4x4': 63,
    'lumaAc16x16': 4,
  });
  expect(
    residual.footprint.where(
      (item) => p8Addresses.any((address) => item.startsWith('$address:')),
    ),
    <String>[
      '1419:luma8x8:0:0:-1,4:-1,5:1,6:2,13:-2',
      '1419:luma8x8:1:0:-1,1:1',
      '1419:luma8x8:2:1:-1',
      '1419:luma8x8:3:0:1,1:-1,4:-2,5:2',
      '1663:luma8x8:0:0:-1',
      '1663:luma8x8:3:1:2',
      '1737:luma4x4:4:0:-1,2:-1',
      '1737:luma4x4:8:0:1',
      '1737:luma4x4:9:0:1',
      '1737:luma4x4:13:0:1,2:-1',
      '1810:luma8x8:0:0:1,1:-2,4:-2',
      '1810:luma8x8:1:1:1,5:-2,6:-1',
      '1810:luma8x8:2:2:-1,4:1',
      '1810:luma8x8:3:0:-2,2:2',
      '1818:luma8x8:1:0:1,2:-2',
      '1818:luma8x8:3:0:1,1:-2,4:-2,5:-2,7:-3',
      '1820:luma8x8:0:0:1,5:-1,7:1',
      '1820:luma8x8:2:1:1',
      '1890:luma8x8:3:4:1,5:-1',
      '2045:luma8x8:0:0:-1,1:2,2:1',
      '2045:luma8x8:1:0:2,2:-2,3:1,4:-1,6:-1,7:3,8:-1,11:2',
      '2045:luma8x8:3:1:2,2:-1,6:-1,12:-1',
      '2046:luma8x8:0:0:-1,6:-2,17:2',
      '2046:luma8x8:1:1:2,3:1,5:1,7:1,8:-1,12:-1,13:1,15:1',
      '2046:luma8x8:2:0:-1,1:2,3:-1,12:2',
      '2046:luma8x8:3:0:1,1:-1,3:3,5:-1,17:-2',
      '2051:luma8x8:1:0:-1,1:1,2:-1',
      '2051:luma8x8:2:0:-1,1:1,2:1,3:1,4:-2,9:-1,12:2,13:2',
      '2051:luma8x8:3:0:-1,1:1,2:-1,6:-1,7:-1',
      '2204:luma8x8:0:0:1,1:1,2:1,5:-2,7:-1,8:-1',
      '2204:luma8x8:1:0:1,1:-1,2:-2,8:1,11:-1',
      '2204:luma8x8:2:0:1,1:-2,3:-1',
    ],
  );
  expect(residual.footprint.where((item) => item.startsWith('1974:')), <String>[
    '1974:luma8x8:0:1:-1,2:-1,4:1',
    '1974:luma8x8:1:0:1,1:-1,4:1,5:1',
    '1974:luma8x8:2:1:-1,2:-1,5:3,6:-3,7:-2,8:-3',
    '1974:luma8x8:3:4:-1,7:2,12:1',
  ]);
  expect(residual.checkpoints, <String>[
    '1893:s0:r0:LblockUnavailable/0:Tavailable/1:'
        '5741/355/79>5742/478/159:coded0:total0',
    '1893:s1:r1:Lavailable/0:Tavailable/1:'
        '5742/478/159>5742/328/159:coded0:total0',
    '1893:s2:r4:LblockUnavailable/0:Tavailable/0:'
        '5742/328/159>5742/269/159:coded0:total0',
    '1893:s3:r5:Lavailable/0:Tavailable/0:'
        '5742/269/159>5743/446/318:coded0:total0',
    '1893:s4:r2:Lavailable/0:Tavailable/1:'
        '5743/446/318>5743/323/318:coded0:total0',
    '1893:s5:r3:Lavailable/0:Tavailable/1:'
        '5743/323/318>5750/468/384:coded1:total1',
    '1893:s6:r6:Lavailable/0:Tavailable/0:'
        '5750/468/384>5750/396/384:coded0:total0',
    '1893:s7:r7:Lavailable/0:Tavailable/1:'
        '5750/396/384>5756/429/208:coded1:total1',
    '1893:s8:r8:LblockUnavailable/0:Tavailable/0:'
        '5756/429/208>5756/370/208:coded0:total0',
    '1893:s9:r9:Lavailable/0:Tavailable/0:'
        '5756/370/208>5756/322/208:coded0:total0',
    '1893:s10:r12:LblockUnavailable/0:Tavailable/0:'
        '5756/322/208>5756/277/208:coded0:total0',
    '1893:s11:r13:Lavailable/0:Tavailable/0:'
        '5756/277/208>5757/484/416:coded0:total0',
    '1893:s12:r10:Lavailable/0:Tavailable/0:'
        '5757/484/416>5757/428/416:coded0:total0',
    '1893:s13:r11:Lavailable/0:Tavailable/1:'
        '5757/428/416>5762/296/253:coded1:total1',
    '1893:s14:r14:Lavailable/0:Tavailable/0:'
        '5762/296/253>5762/264/253:coded0:total0',
    '1893:s15:r15:Lavailable/0:Tavailable/1:'
        '5762/264/253>5768/474/333:coded1:total1',
    '1971:s0:r0:LblockUnavailable/0:Tavailable/0:'
        '6391/400/331>6392/338/201:coded0:total0',
    '1971:s1:r1:Lavailable/0:Tavailable/0:'
        '6392/338/201>6393/316/42:coded0:total0',
    '1971:s2:r4:LblockUnavailable/0:Tavailable/0:'
        '6393/316/42>6400/323/315:coded1:total2',
    '1971:s3:r5:Lavailable/1:Tavailable/0:'
        '6400/323/315>6402/320/288:coded0:total0',
    '1971:s4:r2:Lavailable/0:Tavailable/0:'
        '6402/320/288>6403/316/252:coded0:total0',
    '1971:s5:r3:Lavailable/0:Tavailable/1:'
        '6403/316/252>6405/276/22:coded0:total0',
    '1971:s6:r6:Lavailable/0:Tavailable/0:'
        '6405/276/22>6416/295/275:coded1:total3',
    '1971:s7:r7:Lavailable/1:Tavailable/0:'
        '6416/295/275>6418/308/228:coded0:total0',
    '1971:s8:r8:Lavailable/1:Tavailable/1:'
        '6418/308/228>6432/381/372:coded1:total1',
    '1971:s9:r9:Lavailable/1:Tavailable/0:'
        '6432/381/372>6434/440/407:coded0:total0',
    '1971:s10:r12:Lavailable/1:Tavailable/1:'
        '6434/440/407>6436/360/229:coded0:total0',
    '1971:s11:r13:Lavailable/0:Tavailable/0:'
        '6436/360/229>6437/316/55:coded0:total0',
  ]);
  expect(residual.hash.toRadixString(16), '-4c219a08a38e21ef');
  expect(arithmetic.isTerminated, isTrue);
  expect(
    (
      arithmetic.bitPosition,
      arithmetic.range,
      arithmetic.offset,
      header.reader.bitsLeft,
    ),
    (8947, 384, 385, 5),
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
            ? _lumaBlock(state, bx - 1, by)
            : _lumaBlock(left, 3, by);
        final topNeighbor = by > 0
            ? _lumaBlock(state, bx, by - 1)
            : _lumaBlock(top, bx, 3);
        final blockStart = arithmetic.bitPosition;
        final rangeStart = arithmetic.range;
        final offsetStart = arithmetic.offset;
        final block = syntax.decodeResidualBlock(
          category: category,
          currentMacroblockIntra: state.isIntra,
          left: leftNeighbor,
          top: topNeighbor,
        );
        if (address == 1893 || address == 1971) {
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

CabacCodedBlockNeighbor _lumaBlock(_Mb? mb, int bx, int by) {
  // ctxBlockCat 1 (Intra16x16 AC) and 2 (luma 4x4) share the same
  // neighboring transform-block coded state. The neighbor macroblock type
  // does not make that luma position unavailable.
  if (mb == null) return const CabacCodedBlockNeighbor.unavailable();
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
