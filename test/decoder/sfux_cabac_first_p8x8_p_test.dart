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
  test('decodes exact sfux first P_8x8 P POC 42 through termination', () {
    // Twenty-first decode-order picture, presentation frame n=21 / POC 42.
    // Reproduced from /tmp/sfux-audit.N51PSH/250_00000.ts (278428 bytes,
    // SHA-256 810dbefb730b8658f2404106610143bb71aba2d67a7d56ee26c92af2dbb50ebe)
    // with:
    // /private/tmp/ndvy-ffmpeg/ffmpeg -hide_banner -loglevel error -threads 1
    // -i /tmp/sfux-audit.N51PSH/250_00000.ts -map 0:v:0 -an
    // -f framehash -hash sha256 -
    // Frame n=21 cropped-I420 SHA-256:
    // 06833011e7d3c7ad4b1a45fe61d8f76353a74c29a4839b7bf9f29df42de43670
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419bd54fe10ffc852c1f004060820a80a20014645c7ffa5800000300000300001eae31106a7e7879483091f65aef9381cf14a166afa459ebe79084562706599d077d7f7acaf7d9b430b1ff1b27ce8f6ae742772a295e54324b73c95d891fcca3316d079dd3be7fe1165c48e2ee5c316ddf29dfd8ac3001c8e803a7d4e354b74e86cb26f29f1c622d5ad3695a663611a2c1fe26ea79435744a6549e7b5592a21abe281eaf6cba04182440f789e26604e77d6f0e3374c701c317d61693eab344a1272b121a7adb3eb5dd1d70d3b991b8c26a60f5f18eb08bf336400f9b2ef19f3cbebc102745c6913245aa6405e4e5054690556c73cb3c1ebd0a153cdf91f64deb1b43a378de8ebb8b250b97015744396ff6b70ae5d83f7880e744b9e360790d8befe27c4690bd0e6556bd4ce1e766d27660cc39ebefda47d41df3e1bfd058e19b32abf1907a70a5b7343cd272208395956bfb42407d7c1358445a822655d01bbee06fe2325ed089e4eb1188c64e35d37b6227913f6a68d5db439c09ffc000a09feec5db5c21784b2e236cf23fca587a75d18405600eb81894bc165ae620e48fcf49439f92f7901e78b7360e882fe4481297461ff94e40cdffcb0ea68944c7900a318e39960c2f91e756945603976e564d4bbe6a12953afa1a889d92008e3ef1c47e97492d4855945ba761eb66efa482a1146a8d9fa463c4e536f35b10b0b866a9815726d27397aad2a4c0dfb4c5ac06657cdc4b231b8de5cf1675278b2fdb5d653c7e441b9d341ead727cbf801ad50df52cc31181ce9ebc2c841d4901420c8e73ea11144e8f586e5402672251e5e9fda52ed755d55b2e1e1a86317f647de58d4846e6e32d3e64d7a4b10bab9218705b2e7e970a47ce8d90645b0a8faa39d55bb69de08d019dda0ef430019a5ea255216572383adb82ca40ee52644ce942001459bdc6d73a880e67f4f90c96431b1a7d0038e6225aeba93f75b0a87165f54d381c770effc96750d09069a09269fa3bde206156b9ac23b561383e25cef683d9c68ad7ed8b7838aab44cf8a0b13f29f87b2ca33bb47b8025aa2b0f874e2c2cd22ead902ad6580f541386e777ade0c5b7790f454aa2d223784833e5512c26daedb44ba01dc07df381fc85c939a0ac4f557cef47e2a18e6c1bcf259ae2ac42042ddc7f5d1b397c3a69e18ab58f20dc4dd5d77a431fd0884e5db38aadd724345f6dd4af83ce830f23522322dc9d46dc59261db1c9b7a52d00fa32dd2673ac079cf33ea2c3a82d5fab359eeba0270f3cda004d6b04121dc0552668aee74561082cfac26adca88ce0c731310c72d292188acae373c82bed26fce968d802ab22ae81b2378e66c1eaf55a8e1bec03a55f01e277271149d8dae23496dc559d784855f3bc0822fc40882af73509024973399a60c054e2cfb13763cecad1ff5c92839d01b752cf6f840037dc75f402e93c0fed23fd36a0586bc07f3ca04f306a435bc30adb20f01f2ad9653fcd030587c5a556a49d4c1e13201be5e9a9c6b681f97517628afdfeccd8e7bfbd199e5fb0223df78aea658fbb408981066674b9fd7a08b27c54416f25a242a02379109aa9684118de2ec6da7f426b468554dd896572d2ee340df4d7e5709f0fabeef0f8d2863ee457ed069ba270b6cf76893a4988000003000008b8',
    );
    expect(vcl, hasLength(1184));
    expect(
      sha256.convert(vcl).toString(),
      'a30c700f111b13c6557a724e81f55210e2e773eea4e5c202424dac5eb11fc220',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 9440);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.p);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 14);
    expect(header.picOrderCntLsb, 42);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 7);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(
      header.refPicListModificationsL0.map((m) => (m.idc, m.value)),
      <(int, int)>[(0, 0), (0, 15), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0)],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -7);
    expect(header.sliceQpY, 18);
    expect(header.dataBitOffset, 168);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.adaptiveRefPicMarkingModeFlag, isTrue);
    expect(
      header.memoryManagementOperations.map(
        (m) => (m.operation, m.differenceOfPicNumsMinus1),
      ),
      <(int, int?)>[(1, 5), (1, 4)],
    );
    final weights = header.predictionWeightTable!;
    expect(
      (weights.lumaLog2WeightDenom, weights.chromaLog2WeightDenom),
      (4, 4),
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
        (31, -128, '16,21', '0,-40'),
        (16, 0, '16,16', '0,0'),
        (16, 0, '16,16', '0,0'),
        (16, 0, '16,16', '0,0'),
        (16, 0, '16,16', '0,0'),
        (16, 0, '16,16', '0,0'),
        (16, 0, '16,16', '0,0'),
      ],
    );
    expect(weights.list1, isEmpty);

    // AU19 appends POC 38 and sliding-window marking removes POC 22, leaving
    // six physical references. AU20 repeats POC 38 in logical L0 slots 0/1,
    // then its two MMCO1 operations remove physical POC 24 and 26.
    const before = <H264ShortTermReference<int>>[
      H264ShortTermReference(frameNum: 8, pictureOrderCount: 24, value: 24),
      H264ShortTermReference(frameNum: 9, pictureOrderCount: 26, value: 26),
      H264ShortTermReference(frameNum: 10, pictureOrderCount: 30, value: 30),
      H264ShortTermReference(frameNum: 11, pictureOrderCount: 34, value: 34),
      H264ShortTermReference(frameNum: 12, pictureOrderCount: 36, value: 36),
      H264ShortTermReference(frameNum: 13, pictureOrderCount: 38, value: 38),
    ];
    final list0 = buildPReferenceList0<int>(
      shortTermReferences: before,
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
      modifications: header.refPicListModificationsL0,
    );
    expect(list0.map((r) => r.value), <int>[38, 38, 36, 34, 30, 26, 24]);
    expect(identical(list0[0], list0[1]), isTrue);
    final current = H264ShortTermReference<int>(
      frameNum: 14,
      pictureOrderCount: 42,
      value: 42,
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
    expect(marked.removed.map((r) => r.value), <int>[24, 26]);
    expect(marked.references.map((r) => r.value), <int>[30, 34, 36, 38, 42]);
    expect(identical(marked.references.last, current), isTrue);
    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 0);
  expect(header.reader.bitPos, 168);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 168);
  expect(arithmetic.bitPosition, 177);
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
    if (address == 1420) qpYAtAddress[address] = qpY;
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
    if (address == 1420) {
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
    (3365, 145, 31, 114),
  );
  expect(typeCounts, <int, int>{
    6: 15,
    0: 23,
    5: 78,
    15: 3,
    10: 7,
    3: 1,
    8: 1,
    14: 2,
    11: 2,
    16: 2,
    12: 1,
    7: 3,
    2: 5,
    1: 2,
  });
  expect(macroblockHash.toRadixString(16), '59a8fd438985cece');

  // mb_type=3 is P_8x8. This is the first P_8x8 in the frozen segment.
  expect(typeAddresses[3], <int>[1420]);
  expect(typeAddresses[4], isNull);
  expect(subTypeCounts, <int, int>{0: 4});
  expect(subTypeRecords, <String>['1420:0,0,0,0']);
  expect((mbPartitionCount, motionPartitionCount), (41, 41));
  expect(referenceCounts, <int, int>{0: 36, 1: 4, 2: 1});
  expect(mvdCounts, <String, int>{
    '0,0': 21,
    '9,1': 1,
    '35,0': 1,
    '1,0': 3,
    '-1,0': 1,
    '0,-344': 1,
    '3,0': 2,
    '-6,0': 1,
    '-1,1': 1,
    '-3,0': 1,
    '8,6': 1,
    '-5,24': 1,
    '0,3': 1,
    '2,0': 1,
    '-4,0': 1,
    '-2,0': 1,
    '0,18': 1,
    '13,0': 1,
  });
  expect(motionRecords.where((record) => record.startsWith('1420:')), <String>[
    '1420:0:0:r1:35,0',
    '1420:1:0:r0:0,0',
    '1420:2:0:r0:1,0',
    '1420:3:0:r0:-1,0',
  ]);
  expect(motionHash.toRadixString(16), '-40952a6248ec8cb6');
  expect(chromaModes, <int, int>{0: 94, 1: 10, 2: 10});
  expect(
    (intra8Predicted, intra8Remaining, intra4Predicted, intra4Remaining),
    (147, 137, 81, 31),
  );
  expect(intraModeHash.toRadixString(16), '-7c1088f171d84945');
  expect(intra4Addresses, <int>[1658, 1659, 1660, 1815, 1816, 1971, 2049]);
  expect(intra4Records, hasLength(112));

  expect(macroblockCheckpoints, <String>[
    '1420:start1408:afterStart1410:afterPred1443:afterCbp1448:'
        'afterQp1449:afterResidual1524:afterEos1524:eos0',
  ]);
  expect(cbpCounts, <int, int>{
    0: 29,
    14: 7,
    8: 2,
    4: 6,
    13: 7,
    15: 42,
    44: 2,
    32: 7,
    16: 10,
    7: 5,
    38: 1,
    2: 4,
    37: 2,
    33: 1,
    1: 6,
    31: 2,
    11: 4,
    10: 6,
    5: 2,
  });
  expect(nonzeroCbp[1420], 14);
  expect(transform8Addresses, contains(1420));
  expect(transform8Addresses, hasLength(101));
  expect(qpDeltaCounts, <int, int>{
    8: 2,
    -5: 3,
    0: 63,
    9: 4,
    2: 9,
    -13: 3,
    3: 8,
    -7: 3,
    11: 2,
    -2: 11,
    -10: 1,
    4: 7,
    -8: 2,
    13: 2,
    -14: 2,
    6: 3,
    -11: 3,
    -15: 2,
    7: 3,
    -6: 2,
    12: 1,
    5: 2,
    -4: 3,
    14: 1,
    -17: 1,
    15: 1,
    -3: 1,
  });
  expect(nonzeroQp[1420], isNull);
  expect(qpYAtAddress[1420], 22);
  expect(residual.codedBlocks, <String, int>{
    'lumaDc16x16': 17,
    'luma8x8': 276,
    'chromaDc420': 28,
    'chromaAc420': 31,
    'luma4x4': 29,
  });
  expect(residual.coefficients, <String, int>{
    'lumaDc16x16': 39,
    'luma8x8': 946,
    'chromaDc420': 57,
    'chromaAc420': 44,
    'luma4x4': 57,
  });
  expect(residual.footprint.where((item) => item.startsWith('1420:')), <String>[
    '1420:luma8x8:1:0:-2,1:1,5:3,6:-2,7:-3',
    '1420:luma8x8:2:1:-1,3:-2,4:-4,6:3,7:3',
    '1420:luma8x8:3:0:-2,4:2,5:-1',
  ]);
  expect(residual.checkpoints, isEmpty);
  expect(residual.hash.toRadixString(16), '-23e89366bf72df67');
  expect(arithmetic.isTerminated, isTrue);
  expect(
    (
      arithmetic.bitPosition,
      arithmetic.range,
      arithmetic.offset,
      header.reader.bitsLeft,
    ),
    (9437, 279, 279, 3),
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
        if (address == 1420) {
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
