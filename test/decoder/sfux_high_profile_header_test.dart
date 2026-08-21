import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

void main() {
  final sps = parseSpsNal(
    _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
  );
  final pps = parsePpsNal(
    _hex('68e9b9cb22c0'),
    chromaFormatIdc: sps.chromaFormatIdc,
  );
  final spsById = <int, SpsInfo>{sps.spsId: sps};
  final ppsById = <int, PpsInfo>{pps.ppsId: pps};

  test('parses the exact sfux High-profile parameter-set footprint', () {
    expect(sps.profileIdc, 100);
    expect(sps.levelIdc, 40);
    expect(sps.chromaFormatIdc, 1);
    expect(sps.bitDepthLumaMinus8, 0);
    expect(sps.bitDepthChromaMinus8, 0);
    expect(sps.codedWidth, 1248);
    expect(sps.codedHeight, 720);
    expect(sps.width, 1236);
    expect(sps.height, 720);
    expect(sps.picOrderCntType, 0);
    expect(sps.maxPicOrderCntLsb, 64);
    expect(sps.maxNumRefFrames, 6);
    expect(sps.direct8x8InferenceFlag, isTrue);
    expect(pps.entropyCodingModeFlag, isTrue);
    expect(pps.weightedPredFlag, isTrue);
    expect(pps.weightedBipredIdc, 2);
    expect(pps.transform8x8ModeFlag, isTrue);
    expect(pps.picScalingMatrixPresentFlag, isFalse);
  });

  test('retains the exact explicit weighted-P header parameters', () {
    final header = parseSliceHeader(
      _hex(
        '419a226e810108fffa580000030000030000030000030000030000030000030000030356',
      ),
      ppsById: ppsById,
      spsById: spsById,
    );

    expect(header.sliceType, H264SliceType.p);
    expect(header.frameNum, 1);
    expect(header.picOrderCntLsb, 4);
    expect(header.cabacInitIdc, 0);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 1);
    expect(header.refPicListModificationsL0, isEmpty);
    final weights = header.predictionWeightTable!;
    expect(weights.lumaLog2WeightDenom, 0);
    expect(weights.chromaLog2WeightDenom, 0);
    expect(weights.list0, hasLength(1));
    expect(weights.list0.single.lumaWeight, 1);
    expect(weights.list0.single.lumaOffset, 16);
    expect(weights.list0.single.chromaWeights, <int>[1, 1]);
    expect(weights.list0.single.chromaOffsets, <int>[0, 0]);
    expect(header.dataBitOffset, 52);
  });

  test('retains sfux B direct/List1 syntax and implicit weighting mode', () {
    final header = parseSliceHeader(
      _hex('019e417908ff000003000003000003000003000003000003000003000004bd'),
      ppsById: ppsById,
      spsById: spsById,
    );

    expect(header.sliceType, H264SliceType.b);
    expect(header.nalRefIdc, 0);
    expect(header.frameNum, 2);
    expect(header.picOrderCntLsb, 2);
    expect(header.directSpatialMvPredFlag, isTrue);
    expect(header.numRefIdxL0ActiveMinus1 + 1, 1);
    expect(header.numRefIdxL1ActiveMinus1 + 1, 1);
    expect(header.refPicListModificationsL0, isEmpty);
    expect(header.refPicListModificationsL1, isEmpty);
    expect(header.predictionWeightTable, isNull);
    expect(header.cabacInitIdc, 0);
    expect(header.dataBitOffset, 36);
  });

  test('retains adaptive reference marking operation 1', () {
    final header = parseSliceHeader(
      _hex(
        '419ea664945c23fffb49ee0f9e636aa02aa70080bd4e27071dd4c919bef52af42ee70d1d8e0b6fefa3bc33128081db8c77efeba45ee62441fa73f45e9474da9ebd0a5aae4545586bbfc0085164424ca4',
      ),
      ppsById: ppsById,
      spsById: spsById,
    );

    expect(header.sliceType, H264SliceType.b);
    expect(header.nalRefIdc, 2);
    expect(header.adaptiveRefPicMarkingModeFlag, isTrue);
    expect(header.memoryManagementOperations, hasLength(1));
    expect(header.memoryManagementOperations.single.operation, 1);
    expect(
      header.memoryManagementOperations.single.differenceOfPicNumsMinus1,
      isNotNull,
    );
  });
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
