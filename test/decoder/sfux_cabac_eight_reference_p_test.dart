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
  test('decodes exact sfux eight-reference P POC 24 through termination', () {
    // Thirteenth decode-order/presentation picture, POC 24. Reproduced from
    // /tmp/sfux-audit.N51PSH/250_00000.ts with:
    // /private/tmp/ndvy-ffmpeg/ffmpeg -hide_banner -loglevel error -threads 1
    // -i /tmp/sfux-audit.N51PSH/250_00000.ts -map 0:v:0 -an
    // -f framehash -hash sha256 -
    // FFmpeg presentation frame n=12 cropped-I420 SHA-256:
    // 867c04741b577cb3f44687534f020448dd9846f6aa5763217a21931e222b4e05
    final spsNal = _bytes('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
    final ppsNal = _bytes('68e9b9cb22c0');
    final vcl = _bytes(
      '419b0c44784210e96b21f03902440e40880008fffa5800000300000300001d4dff0a7fba4f07a01bfa76254b333ef12e4649a7e3555f52783de18a22f31602f74e2fc697be4a769d0a9e20c4f83104dfe346cad80cdc0adbec047647e2ce66c227b1781ee49945f0e0fa3c2bfa8cb4203adb5de2e56823b650b4012ddf90a19f065f05d52b198a5a5e63247825d9b9e93280ff5605af898abc3b14156ff36e621c3ff5ac562a589211f64ec6ab07f0f97df850d283941c5e862704e0290cd3177a22a3a8fd12def3f28f3990d0512d2c8e586d9af960d2dc52c338ed1f2d67d678678ee1934fc8caae3d37e0ca1c76eefc61446cec7efd02d5d0000003000047c0',
    );
    expect(vcl, hasLength(257));
    expect(
      sha256.convert(vcl).toString(),
      '3649b4d18b2ef757af8ba53df9cde1d8878b8c062e9ab230f9ffc319e069c363',
    );
    final sps = parseSpsNal(spsNal);
    final pps = parsePpsNal(ppsNal, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      vcl,
      ppsById: {pps.ppsId: pps},
      spsById: {sps.spsId: sps},
    );
    expect(header.reader.bitLength, 2024);
    expect(header.isIdr, isFalse);
    expect(header.nalUnitType, 1);
    expect(header.sliceType, H264SliceType.p);
    expect(header.nalRefIdc, 2);
    expect(header.firstMbInSlice, 0);
    expect(header.frameNum, 8);
    expect(header.picOrderCntLsb, 24);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 8);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(
      header.refPicListModificationsL0.map((m) => (m.idc, m.value)),
      <(int, int)>[
        (0, 0),
        (0, 15),
        (0, 15),
        (0, 0),
        (0, 1),
        (1, 0),
        (0, 1),
        (0, 0),
      ],
    );
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.cabacInitIdc, 0);
    expect(header.sliceQpDelta, -7);
    expect(header.sliceQpY, 18);
    expect(header.disableDeblockingFilterIdc, 0);
    expect(header.sliceAlphaC0OffsetDiv2, 0);
    expect(header.sliceBetaOffsetDiv2, 0);
    expect(header.dataBitOffset, 151);
    expect(header.adaptiveRefPicMarkingModeFlag, isFalse);
    expect(header.memoryManagementOperations, isEmpty);

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
        (57, 18, '1,1', '0,0'),
        (57, 17, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
        (64, 0, '1,1', '0,0'),
      ],
    );
    expect(weights.list1, isEmpty);

    // AU10 is non-reference. AU11 POC 22 appends to the five references left
    // by AU9. AU12 repeats POC 22 three times in its eight logical L0 slots.
    const afterAu9 = <H264ShortTermReference<int>>[
      H264ShortTermReference(frameNum: 2, pictureOrderCount: 6, value: 6),
      H264ShortTermReference(frameNum: 3, pictureOrderCount: 10, value: 10),
      H264ShortTermReference(frameNum: 4, pictureOrderCount: 16, value: 16),
      H264ShortTermReference(frameNum: 5, pictureOrderCount: 12, value: 12),
      H264ShortTermReference(frameNum: 6, pictureOrderCount: 20, value: 20),
    ];
    final afterAu11 = applyShortTermDpbMarking<int>(
      shortTermReferences: afterAu9,
      currentPicture: const H264ShortTermReference<int>(
        frameNum: 7,
        pictureOrderCount: 22,
        value: 22,
      ),
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: 2,
      adaptiveRefPicMarkingModeFlag: false,
    );
    expect(afterAu11.removed, isEmpty);
    expect(afterAu11.references.map((reference) => reference.value), <int>[
      6,
      10,
      16,
      12,
      20,
      22,
    ]);
    final list0 = buildPReferenceList0<int>(
      shortTermReferences: afterAu11.references,
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
      modifications: header.refPicListModificationsL0,
    );
    expect(list0.map((reference) => reference.value), <int>[
      22,
      22,
      22,
      20,
      16,
      12,
      10,
      6,
    ]);
    expect(identical(list0[0], list0[1]), isTrue);
    expect(identical(list0[1], list0[2]), isTrue);
    final current = H264ShortTermReference<int>(
      frameNum: header.frameNum,
      pictureOrderCount: header.picOrderCntLsb,
      value: header.picOrderCntLsb!,
    );
    final afterAu12 = applyShortTermDpbMarking<int>(
      shortTermReferences: afterAu11.references,
      currentPicture: current,
      maxFrameNum: sps.maxFrameNum,
      maxNumRefFrames: sps.maxNumRefFrames,
      nalRefIdc: header.nalRefIdc,
      adaptiveRefPicMarkingModeFlag: header.adaptiveRefPicMarkingModeFlag,
      memoryManagementOperations: header.memoryManagementOperations,
    );
    expect(afterAu12.removed.map((reference) => reference.value), <int>[6]);
    expect(afterAu12.references.map((reference) => reference.value), <int>[
      10,
      16,
      12,
      20,
      22,
      24,
    ]);
    expect(identical(afterAu12.references.last, current), isTrue);

    _decodeSyntax(header, pps);
  });
}

void _decodeSyntax(SliceHeader header, PpsInfo pps) {
  final alignment = readCabacAlignmentOneBits(header.reader);
  expect(alignment, 1);
  expect(header.reader.bitPos, 152);
  final arithmetic = H264CabacDecoder.initialize(header.reader);
  expect(arithmetic.startBitPosition, 152);
  expect(arithmetic.bitPosition, 161);
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

  // FFmpeg `-debug mb_type` independently reports 3424 S, 47 i, 32 I,
  // four P_16x16 (`>`), and three P_8x16 (`>|`) macroblocks.
  expect(eosAddress, 3509);
  expect(states, everyElement(isNotNull));
  expect(skipped, 3424);
  expect(nonSkipAddresses, hasLength(86));
  expect(inter, 7);
  expect(intra, 79);
  expect(typeCounts, <int, int>{
    5: 47,
    6: 23,
    2: 3,
    0: 4,
    10: 1,
    7: 4,
    11: 1,
    8: 3,
  });
  expect(typeAddresses, <int, List<int>>{
    5: <int>[
      1265,
      1342,
      1343,
      1344,
      1346,
      1348,
      1350,
      1353,
      1403,
      1419,
      1422,
      1425,
      1430,
      1431,
      1497,
      1499,
      1502,
      1503,
      1506,
      1575,
      1578,
      1580,
      1581,
      1582,
      1653,
      1654,
      1659,
      1739,
      1816,
      1819,
      1820,
      1889,
      1892,
      1898,
      1966,
      1968,
      1969,
      1970,
      1971,
      1974,
      2046,
      2047,
      2052,
      2127,
      2129,
      2204,
      2206,
    ],
    6: <int>[
      1324,
      1325,
      1508,
      1509,
      1577,
      1586,
      1587,
      1656,
      1660,
      1662,
      1664,
      1734,
      1735,
      1740,
      1742,
      1743,
      1817,
      1894,
      1895,
      1897,
      1967,
      1972,
      1973,
    ],
    2: <int>[1423, 1500, 1890],
    0: <int>[1427, 1583, 1665, 1737],
    10: <int>[1584],
    7: <int>[1657, 1814, 2049, 2128],
    11: <int>[1658],
    8: <int>[2048, 2051, 2125],
  });
  expect(macroblockHash.toRadixString(16), '-691f35b2942bcf54');

  expect(subTypeCounts, isEmpty);
  expect(mbPartitionCount, 10);
  expect(motionPartitionCount, 10);
  expect(referenceCounts, <int, int>{1: 4, 0: 6});
  expect(mvdCounts, <String, int>{
    '0,0': 6,
    '3,0': 1,
    '-11,0': 1,
    '-5,0': 1,
    '31,0': 1,
  });
  expect(motionRecords, <String>[
    '1423:0:0:r1:0,0',
    '1423:1:0:r1:0,0',
    '1427:0:0:r1:0,0',
    '1500:0:0:r0:3,0',
    '1500:1:0:r0:-11,0',
    '1583:0:0:r1:0,0',
    '1665:0:0:r0:-5,0',
    '1737:0:0:r0:0,0',
    '1890:0:0:r0:0,0',
    '1890:1:0:r0:31,0',
  ]);
  expect(motionHash.toRadixString(16), '-4bef319caf42a11c');

  expect(chromaModes, <int, int>{0: 69, 2: 2, 1: 8});
  expect(intra8Predicted, 140);
  expect(intra8Remaining, 48);
  expect(intra4Predicted, 0);
  expect(intra4Remaining, 0);
  expect(intraModeHash.toRadixString(16), '-7005e02cab3f8d94');
  expect(cbpCounts, <int, int>{
    0: 58,
    5: 1,
    1: 9,
    16: 4,
    17: 3,
    15: 2,
    3: 4,
    2: 3,
    8: 1,
    6: 1,
  });
  expect(nonzeroCbp, <int, int>{
    1342: 5,
    1344: 1,
    1346: 16,
    1348: 17,
    1350: 1,
    1353: 1,
    1425: 17,
    1427: 16,
    1430: 1,
    1497: 1,
    1502: 1,
    1506: 17,
    1584: 16,
    1658: 16,
    1659: 15,
    1737: 15,
    1739: 1,
    1816: 3,
    1819: 2,
    1898: 3,
    1969: 2,
    1970: 8,
    1971: 6,
    2047: 2,
    2052: 1,
    2127: 3,
    2129: 1,
    2206: 3,
  });
  expect(transform8Addresses, <int>[
    1265,
    1342,
    1343,
    1344,
    1346,
    1348,
    1350,
    1353,
    1403,
    1419,
    1422,
    1425,
    1430,
    1431,
    1497,
    1499,
    1502,
    1503,
    1506,
    1575,
    1578,
    1580,
    1581,
    1582,
    1653,
    1654,
    1659,
    1737,
    1739,
    1816,
    1819,
    1820,
    1889,
    1892,
    1898,
    1966,
    1968,
    1969,
    1970,
    1971,
    1974,
    2046,
    2047,
    2052,
    2127,
    2129,
    2204,
    2206,
  ]);

  expect(qpDeltaCounts, <int, int>{
    0: 59,
    6: 4,
    -8: 2,
    10: 1,
    -6: 2,
    9: 1,
    -9: 1,
    11: 1,
    -11: 1,
    4: 2,
    -4: 1,
    8: 2,
    -5: 1,
    5: 1,
    -12: 1,
    -2: 1,
    2: 2,
    -10: 1,
    -3: 1,
    3: 1,
  });
  expect(nonzeroQp, <int, int>{
    1342: 6,
    1344: -8,
    1346: 10,
    1348: -8,
    1353: 6,
    1425: -6,
    1577: 6,
    1584: -6,
    1659: 9,
    1660: -9,
    1737: 11,
    1739: -11,
    1819: 4,
    1894: -4,
    1897: 8,
    1967: -5,
    1969: 4,
    1971: 5,
    1972: -12,
    1973: 8,
    2047: -2,
    2048: 2,
    2049: -10,
    2127: 2,
    2128: -3,
    2129: 3,
    2206: 6,
  });

  expect(residual.codedBlocks, <String, int>{
    'luma8x8': 36,
    'chromaDc420': 7,
    'lumaDc16x16': 6,
  });
  expect(residual.coefficients, <String, int>{
    'luma8x8': 46,
    'chromaDc420': 10,
    'lumaDc16x16': 12,
  });
  expect(residual.macroblockAddresses.toList()..sort(), <int>[
    1342,
    1344,
    1346,
    1348,
    1350,
    1353,
    1425,
    1427,
    1430,
    1497,
    1502,
    1506,
    1577,
    1584,
    1658,
    1659,
    1737,
    1739,
    1816,
    1819,
    1897,
    1898,
    1967,
    1969,
    1970,
    1971,
    1973,
    2047,
    2048,
    2049,
    2052,
    2127,
    2129,
    2206,
  ]);
  expect(residual.hash.toRadixString(16), '-41991b758a85962c');
  expect(residual.footprint, <String>[
    '1342:luma8x8:0:0:2',
    '1342:luma8x8:2:0:1',
    '1344:luma8x8:0:0:4',
    '1346:chromaDc420:1:0:2',
    '1348:luma8x8:0:0:3',
    '1348:chromaDc420:1:1:-1,2:1',
    '1350:luma8x8:0:0:1',
    '1353:luma8x8:0:0:1',
    '1425:luma8x8:0:0:1',
    '1425:chromaDc420:1:0:1',
    '1427:chromaDc420:1:0:1',
    '1430:luma8x8:0:0:3',
    '1497:luma8x8:0:0:6',
    '1502:luma8x8:0:0:1',
    '1506:luma8x8:0:0:-2',
    '1506:chromaDc420:1:1:-2,2:1',
    '1577:lumaDc16x16:0:0:-2,1:-2',
    '1584:chromaDc420:1:0:-4',
    '1658:chromaDc420:1:1:2,2:-2',
    '1659:luma8x8:0:0:4,2:-2',
    '1659:luma8x8:1:0:1',
    '1659:luma8x8:2:0:-2',
    '1659:luma8x8:3:0:-1,1:2,2:1',
    '1737:luma8x8:0:0:1,2:-1',
    '1737:luma8x8:1:0:1,2:-1',
    '1737:luma8x8:2:0:3',
    '1737:luma8x8:3:0:2,2:2',
    '1739:luma8x8:0:0:-2',
    '1816:luma8x8:0:0:-3',
    '1816:luma8x8:1:0:-2',
    '1819:luma8x8:1:0:1',
    '1897:lumaDc16x16:0:0:2',
    '1898:luma8x8:0:0:-1',
    '1898:luma8x8:1:0:-1',
    '1967:lumaDc16x16:0:0:1,1:1',
    '1969:luma8x8:1:0:1',
    '1970:luma8x8:3:0:1',
    '1971:luma8x8:1:1:1',
    '1971:luma8x8:2:0:2,2:1,3:-1,9:1,10:1',
    '1973:lumaDc16x16:0:0:-1,1:1',
    '2047:luma8x8:1:0:-2',
    '2048:lumaDc16x16:0:0:1,1:-1,2:1',
    '2049:lumaDc16x16:0:0:-2,2:-2',
    '2052:luma8x8:0:0:4',
    '2127:luma8x8:0:0:-2',
    '2127:luma8x8:1:0:-2',
    '2129:luma8x8:0:0:3',
    '2206:luma8x8:0:0:-1',
    '2206:luma8x8:1:0:1',
  ]);

  expect(arithmetic.isTerminated, isTrue);
  expect(arithmetic.bitPosition, 2018);
  expect(arithmetic.range, 287);
  expect(arithmetic.offset, 287);
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
