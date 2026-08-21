import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/picture_order_count.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/reference_picture_list.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

// Parameter sets and the first P/B slices from the user's 1500 kbit/s sfux
// rendition. Keeping just the NALs makes this a deterministic, offline syntax
// footprint test without checking a network host or committing a TS segment.
final _sfuxSps = _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0');
final _sfuxPps = _hex('68e9b8372c8b');
final _sfuxFirstP = _hex(
  '419a226e810109fffeb52a80000003000003000003000003000003000003000003'
  '00001eb0',
);
final _sfuxFirstB = _hex(
  '019e417909ff000003000003000003000003000003000c0838a103bfc31fd92600'
  '0003000004cd',
);
final _sfuxFirstMmcoB = _hex('419ea664945c2bff');

void main() {
  test('sfux High-profile parameter-set footprint stays explicit', () {
    final sps = parseSpsNal(_sfuxSps);
    final pps = parsePpsNal(_sfuxPps, chromaFormatIdc: sps.chromaFormatIdc);

    expect(sps.profileIdc, 100);
    expect(sps.levelIdc, 40);
    expect(sps.picOrderCntType, 0);
    expect(sps.maxPicOrderCntLsb, 64);
    expect(sps.maxFrameNum, 16);
    expect(sps.maxNumRefFrames, 6);
    expect(sps.frameMbsOnlyFlag, isTrue);
    expect((sps.codedWidth, sps.codedHeight), (1248, 720));
    expect((sps.width, sps.height), (1236, 720));

    expect(pps.entropyCodingModeFlag, isTrue);
    expect(pps.weightedPredFlag, isTrue);
    expect(pps.weightedBipredIdc, 2);
    expect(pps.transform8x8ModeFlag, isTrue);
    expect(pps.picScalingMatrixPresentFlag, isFalse);
  });

  test('sfux first P/B headers derive decode-order POC 4 then 2', () {
    final sps = parseSpsNal(_sfuxSps);
    final pps = parsePpsNal(_sfuxPps, chromaFormatIdc: sps.chromaFormatIdc);
    final maps = (
      <int, PpsInfo>{pps.ppsId: pps},
      <int, SpsInfo>{sps.spsId: sps},
    );
    final p = parseSliceHeader(_sfuxFirstP, ppsById: maps.$1, spsById: maps.$2);
    final b = parseSliceHeader(_sfuxFirstB, ppsById: maps.$1, spsById: maps.$2);

    expect(p.sliceType, H264SliceType.p);
    expect((p.frameNum, p.picOrderCntLsb, p.nalRefIdc), (1, 4, 2));
    expect(p.numRefIdxL0ActiveMinus1 + 1, 1);
    expect(p.refPicListModificationsL0, isEmpty);
    expect(p.cabacInitIdc, 0);
    expect(p.predictionWeightTable, isNotNull);
    expect(p.predictionWeightTable!.lumaLog2WeightDenom, 0);
    expect(p.predictionWeightTable!.list0.single.lumaWeight, 1);
    expect(p.predictionWeightTable!.list0.single.lumaOffset, 16);

    expect(b.sliceType, H264SliceType.b);
    expect((b.frameNum, b.picOrderCntLsb, b.nalRefIdc), (2, 2, 0));
    expect(b.directSpatialMvPredFlag, isTrue);
    expect(b.numRefIdxL0ActiveMinus1 + 1, 1);
    expect(b.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(b.refPicListModificationsL0, isEmpty);
    expect(b.refPicListModificationsL1, isEmpty);
    expect(b.predictionWeightTable, isNull); // weighted_bipred_idc == 2.
    expect(b.cabacInitIdc, 0);

    final tracker = H264PocType0Tracker();
    expect(
      tracker
          .derivePictureOrderCount(
            picOrderCntLsb: 0,
            maxPicOrderCntLsb: sps.maxPicOrderCntLsb,
            isIdr: true,
            isReference: true,
          )
          .pictureOrderCount,
      0,
    );
    expect(tracker.deriveFromHeader(p).pictureOrderCount, 4);
    expect(tracker.deriveFromHeader(b).pictureOrderCount, 2);
    expect(tracker.previousReferenceState!.picOrderCntLsb, 4);
  });

  test('sfux first adaptive marking header removes wrapped PicNum zero', () {
    final sps = parseSpsNal(_sfuxSps);
    final pps = parsePpsNal(_sfuxPps, chromaFormatIdc: sps.chromaFormatIdc);
    final header = parseSliceHeader(
      _sfuxFirstMmcoB,
      ppsById: <int, PpsInfo>{pps.ppsId: pps},
      spsById: <int, SpsInfo>{sps.spsId: sps},
    );

    expect(header.sliceType, H264SliceType.b);
    expect((header.frameNum, header.picOrderCntLsb), (5, 12));
    expect(header.nalRefIdc, 2);
    expect(header.adaptiveRefPicMarkingModeFlag, isTrue);
    expect(header.memoryManagementOperations, hasLength(1));
    expect(header.memoryManagementOperations.single.operation, 1);
    expect(
      header.memoryManagementOperations.single.differenceOfPicNumsMinus1,
      4,
    );

    final marking = applyShortTermMmco1<int>(
      shortTermReferences: <H264ShortTermReference<int>>[
        for (var frameNum = 0; frameNum < 5; frameNum++)
          H264ShortTermReference<int>(frameNum: frameNum, value: frameNum),
      ],
      currentFrameNum: header.frameNum,
      maxFrameNum: sps.maxFrameNum,
      operation: header.memoryManagementOperations.single,
    );
    expect(marking.picNumX, 0);
    expect(marking.removed.frameNum, 0);
    expect(marking.remaining.map((reference) => reference.frameNum), <int>[
      1,
      2,
      3,
      4,
    ]);
  });
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
