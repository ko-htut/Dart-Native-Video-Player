import 'dart:typed_data';

import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';
import 'scaling_list_syntax.dart';

class PpsInfo {
  final int ppsId;
  final int spsId;
  final bool entropyCodingModeFlag;
  final bool bottomFieldPicOrderInFramePresentFlag;
  final int numSliceGroupsMinus1;
  final int sliceGroupMapType;
  final bool sliceGroupChangeDirectionFlag;
  final int sliceGroupChangeRateMinus1;
  final int picSizeInMapUnitsMinus1;
  final int numRefIdxL0DefaultActiveMinus1;
  final int numRefIdxL1DefaultActiveMinus1;
  final bool weightedPredFlag;
  final int weightedBipredIdc;
  final int picInitQpMinus26;
  final int picInitQsMinus26;
  final int chromaQpIndexOffset;
  final bool deblockingFilterControlPresentFlag;
  final bool constrainedIntraPredFlag;
  final bool redundantPicCntPresentFlag;
  final bool transform8x8ModeFlag;
  final bool picScalingMatrixPresentFlag;
  final List<H264ScalingListSyntax> scalingLists;
  final int secondChromaQpIndexOffset;

  const PpsInfo({
    required this.ppsId,
    required this.spsId,
    required this.entropyCodingModeFlag,
    required this.bottomFieldPicOrderInFramePresentFlag,
    required this.numSliceGroupsMinus1,
    required this.sliceGroupMapType,
    required this.sliceGroupChangeDirectionFlag,
    required this.sliceGroupChangeRateMinus1,
    required this.picSizeInMapUnitsMinus1,
    required this.numRefIdxL0DefaultActiveMinus1,
    required this.numRefIdxL1DefaultActiveMinus1,
    required this.weightedPredFlag,
    required this.weightedBipredIdc,
    required this.picInitQpMinus26,
    required this.picInitQsMinus26,
    required this.chromaQpIndexOffset,
    required this.deblockingFilterControlPresentFlag,
    required this.constrainedIntraPredFlag,
    required this.redundantPicCntPresentFlag,
    required this.transform8x8ModeFlag,
    required this.picScalingMatrixPresentFlag,
    this.scalingLists = const <H264ScalingListSyntax>[],
    required this.secondChromaQpIndexOffset,
  });

  /// True when picture-level fallback rule B inherits matrices from the SPS.
  bool get inheritsSequenceScalingMatrices => !picScalingMatrixPresentFlag;

  bool get hasExplicitScalingLists =>
      scalingLists.any((list) => list.isExplicit);
}

PpsInfo parsePpsNal(Uint8List nal, {int chromaFormatIdc = 1}) {
  if (nal.length < 2 || (nal.first & 0x80) != 0 || (nal.first & 0x1f) != 8) {
    throw const FormatException('PPS NAL is missing or has the wrong NAL type');
  }
  if (chromaFormatIdc < 0 || chromaFormatIdc > 3) {
    throw ArgumentError.value(
      chromaFormatIdc,
      'chromaFormatIdc',
      'must be 0..3',
    );
  }

  final br = BitReader(ebspToRbsp(Uint8List.sublistView(nal, 1)));
  final ppsId = readUE(br);
  final spsId = readUE(br);
  if (ppsId > 255) {
    throw FormatException('pic_parameter_set_id=$ppsId exceeds 255');
  }
  if (spsId > 31) {
    throw FormatException('seq_parameter_set_id=$spsId exceeds 31');
  }
  final entropyCodingModeFlag = br.readBit() == 1;
  final bottomFieldPicOrderInFramePresentFlag = br.readBit() == 1;

  final numSliceGroupsMinus1 = readUE(br);
  if (numSliceGroupsMinus1 > 7) {
    throw FormatException(
      'num_slice_groups_minus1=$numSliceGroupsMinus1 exceeds 7',
    );
  }
  var sliceGroupMapType = 0;
  var sliceGroupChangeDirectionFlag = false;
  var sliceGroupChangeRateMinus1 = 0;
  var picSizeInMapUnitsMinus1 = 0;

  if (numSliceGroupsMinus1 > 0) {
    sliceGroupMapType = readUE(br);
    switch (sliceGroupMapType) {
      case 0:
        for (var i = 0; i <= numSliceGroupsMinus1; i++) {
          readUE(br); // run_length_minus1[i]
        }
        break;
      case 1:
        // Dispersed slice groups have no additional PPS syntax elements.
        break;
      case 2:
        for (var i = 0; i < numSliceGroupsMinus1; i++) {
          readUE(br); // top_left[i]
          readUE(br); // bottom_right[i]
        }
        break;
      case 3:
      case 4:
      case 5:
        sliceGroupChangeDirectionFlag = br.readBit() == 1;
        sliceGroupChangeRateMinus1 = readUE(br);
        break;
      case 6:
        picSizeInMapUnitsMinus1 = readUE(br);
        final bits = _ceilLog2(numSliceGroupsMinus1 + 1);
        for (var i = 0; i <= picSizeInMapUnitsMinus1; i++) {
          br.readBits(bits); // slice_group_id[i]
        }
        break;
      default:
        throw FormatException(
          'Invalid slice_group_map_type=$sliceGroupMapType',
        );
    }
  }

  final numRefIdxL0DefaultActiveMinus1 = readUE(br);
  final numRefIdxL1DefaultActiveMinus1 = readUE(br);
  if (numRefIdxL0DefaultActiveMinus1 > 31 ||
      numRefIdxL1DefaultActiveMinus1 > 31) {
    throw FormatException(
      'Default reference count exceeds 32: '
      'L0=${numRefIdxL0DefaultActiveMinus1 + 1}, '
      'L1=${numRefIdxL1DefaultActiveMinus1 + 1}',
    );
  }
  final weightedPredFlag = br.readBit() == 1;
  final weightedBipredIdc = br.readBits(2);
  if (weightedBipredIdc > 2) {
    throw FormatException('weighted_bipred_idc=$weightedBipredIdc is reserved');
  }
  final picInitQpMinus26 = readSE(br);
  final picInitQsMinus26 = readSE(br);
  final chromaQpIndexOffset = readSE(br);
  if (picInitQpMinus26 < -26 || picInitQpMinus26 > 25) {
    throw FormatException('pic_init_qp_minus26=$picInitQpMinus26 is invalid');
  }
  if (picInitQsMinus26 < -26 || picInitQsMinus26 > 25) {
    throw FormatException('pic_init_qs_minus26=$picInitQsMinus26 is invalid');
  }
  _validateChromaQpOffset(chromaQpIndexOffset, 'chroma_qp_index_offset');
  final deblockingFilterControlPresentFlag = br.readBit() == 1;
  final constrainedIntraPredFlag = br.readBit() == 1;
  final redundantPicCntPresentFlag = br.readBit() == 1;

  var transform8x8ModeFlag = false;
  var picScalingMatrixPresentFlag = false;
  var scalingLists = _absentScalingLists(6);
  var secondChromaQpIndexOffset = chromaQpIndexOffset;
  if (moreRbspData(br)) {
    transform8x8ModeFlag = br.readBit() == 1;
    picScalingMatrixPresentFlag = br.readBit() == 1;
    final count =
        6 + (transform8x8ModeFlag ? (chromaFormatIdc == 3 ? 6 : 2) : 0);
    scalingLists = picScalingMatrixPresentFlag
        ? _readScalingLists(br, count)
        : _absentScalingLists(count);
    secondChromaQpIndexOffset = readSE(br);
    _validateChromaQpOffset(
      secondChromaQpIndexOffset,
      'second_chroma_qp_index_offset',
    );
  }
  readRbspTrailingBits(br);

  return PpsInfo(
    ppsId: ppsId,
    spsId: spsId,
    entropyCodingModeFlag: entropyCodingModeFlag,
    bottomFieldPicOrderInFramePresentFlag:
        bottomFieldPicOrderInFramePresentFlag,
    numSliceGroupsMinus1: numSliceGroupsMinus1,
    sliceGroupMapType: sliceGroupMapType,
    sliceGroupChangeDirectionFlag: sliceGroupChangeDirectionFlag,
    sliceGroupChangeRateMinus1: sliceGroupChangeRateMinus1,
    picSizeInMapUnitsMinus1: picSizeInMapUnitsMinus1,
    numRefIdxL0DefaultActiveMinus1: numRefIdxL0DefaultActiveMinus1,
    numRefIdxL1DefaultActiveMinus1: numRefIdxL1DefaultActiveMinus1,
    weightedPredFlag: weightedPredFlag,
    weightedBipredIdc: weightedBipredIdc,
    picInitQpMinus26: picInitQpMinus26,
    picInitQsMinus26: picInitQsMinus26,
    chromaQpIndexOffset: chromaQpIndexOffset,
    deblockingFilterControlPresentFlag: deblockingFilterControlPresentFlag,
    constrainedIntraPredFlag: constrainedIntraPredFlag,
    redundantPicCntPresentFlag: redundantPicCntPresentFlag,
    transform8x8ModeFlag: transform8x8ModeFlag,
    picScalingMatrixPresentFlag: picScalingMatrixPresentFlag,
    scalingLists: List<H264ScalingListSyntax>.unmodifiable(scalingLists),
    secondChromaQpIndexOffset: secondChromaQpIndexOffset,
  );
}

int _ceilLog2(int value) {
  var bits = 0;
  var capacity = 1;
  while (capacity < value) {
    capacity <<= 1;
    bits++;
  }
  return bits;
}

List<H264ScalingListSyntax> _readScalingLists(BitReader reader, int count) {
  return <H264ScalingListSyntax>[
    for (var index = 0; index < count; index++)
      if (reader.readBit() == 1)
        H264ScalingListSyntax.parse(reader, size: index < 6 ? 16 : 64)
      else
        H264ScalingListSyntax.absent(index < 6 ? 16 : 64),
  ];
}

List<H264ScalingListSyntax> _absentScalingLists(int count) {
  return <H264ScalingListSyntax>[
    for (var index = 0; index < count; index++)
      H264ScalingListSyntax.absent(index < 6 ? 16 : 64),
  ];
}

void _validateChromaQpOffset(int value, String name) {
  if (value < -12 || value > 12) {
    throw FormatException('$name=$value is outside -12..12');
  }
}
