import 'dart:typed_data';

import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';

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
    required this.secondChromaQpIndexOffset,
  });
}

PpsInfo parsePpsNal(Uint8List nal, {int chromaFormatIdc = 1}) {
  if (nal.length < 2 || (nal.first & 0x1f) != 8) {
    throw const FormatException('PPS NAL is missing or has the wrong NAL type');
  }

  final br = BitReader(ebspToRbsp(Uint8List.sublistView(nal, 1)));
  final ppsId = readUE(br);
  final spsId = readUE(br);
  final entropyCodingModeFlag = br.readBit() == 1;
  final bottomFieldPicOrderInFramePresentFlag = br.readBit() == 1;

  final numSliceGroupsMinus1 = readUE(br);
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
  final weightedPredFlag = br.readBit() == 1;
  final weightedBipredIdc = br.readBits(2);
  final picInitQpMinus26 = readSE(br);
  final picInitQsMinus26 = readSE(br);
  final chromaQpIndexOffset = readSE(br);
  final deblockingFilterControlPresentFlag = br.readBit() == 1;
  final constrainedIntraPredFlag = br.readBit() == 1;
  final redundantPicCntPresentFlag = br.readBit() == 1;

  var transform8x8ModeFlag = false;
  var picScalingMatrixPresentFlag = false;
  var secondChromaQpIndexOffset = chromaQpIndexOffset;
  if (moreRbspData(br)) {
    transform8x8ModeFlag = br.readBit() == 1;
    picScalingMatrixPresentFlag = br.readBit() == 1;
    if (picScalingMatrixPresentFlag) {
      final count =
          6 + (transform8x8ModeFlag ? (chromaFormatIdc == 3 ? 6 : 2) : 0);
      for (var i = 0; i < count; i++) {
        if (br.readBit() == 1) {
          _skipScalingList(br, i < 6 ? 16 : 64);
        }
      }
    }
    secondChromaQpIndexOffset = readSE(br);
  }

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

void _skipScalingList(BitReader br, int size) {
  var lastScale = 8;
  var nextScale = 8;
  for (var j = 0; j < size; j++) {
    if (nextScale != 0) {
      nextScale = (lastScale + readSE(br)) & 0xff;
    }
    if (nextScale != 0) lastScale = nextScale;
  }
}
