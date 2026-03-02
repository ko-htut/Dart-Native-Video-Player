import 'dart:typed_data';
import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';

class PpsInfo {
  final int ppsId;
  final int spsId;
  final bool entropyCodingModeFlag; // false => CAVLC
  final int numSliceGroupsMinus1;
  final int sliceGroupMapType;
  final bool sliceGroupChangeDirectionFlag;
  final int sliceGroupChangeRateMinus1;
  final int picSizeInMapUnitsMinus1;
  final int picInitQpMinus26;
  final int chromaQpIndexOffset;
  final bool bottomFieldPicOrderInFramePresentFlag;
  final bool deblockingFilterControlPresentFlag;
  final bool redundantPicCntPresentFlag;
  final bool transform8x8ModeFlag;

  const PpsInfo({
    required this.ppsId,
    required this.spsId,
    required this.entropyCodingModeFlag,
    required this.numSliceGroupsMinus1,
    required this.sliceGroupMapType,
    required this.sliceGroupChangeDirectionFlag,
    required this.sliceGroupChangeRateMinus1,
    required this.picSizeInMapUnitsMinus1,
    required this.picInitQpMinus26,
    required this.chromaQpIndexOffset,
    required this.bottomFieldPicOrderInFramePresentFlag,
    required this.deblockingFilterControlPresentFlag,
    required this.redundantPicCntPresentFlag,
    required this.transform8x8ModeFlag,
  });
}

PpsInfo parsePpsNal(Uint8List ppsNal) {
  final rbsp = ebspToRbsp(ppsNal.sublist(1));
  final br = BitReader(rbsp);

  final ppsId = readUE(br);
  final spsId = readUE(br);
  final entropyCodingModeFlag = br.readBit() == 1;
  final bottomFieldPicOrderInFramePresentFlag = br.readBit() == 1;

  final numSliceGroupsMinus1 = readUE(br);
  int sliceGroupMapType = 0;
  bool sliceGroupChangeDirectionFlag = false;
  int sliceGroupChangeRateMinus1 = 0;
  int picSizeInMapUnitsMinus1 = 0;
  if (numSliceGroupsMinus1 > 0) {
    sliceGroupMapType = readUE(br);
    if (sliceGroupMapType == 0) {
      for (int i = 0; i <= numSliceGroupsMinus1; i++) {
        readUE(br); // run_length_minus1[i]
      }
    } else if (sliceGroupMapType == 2) {
      for (int i = 0; i < numSliceGroupsMinus1; i++) {
        readUE(br); // top_left[i]
        readUE(br); // bottom_right[i]
      }
    } else if (sliceGroupMapType == 3 ||
        sliceGroupMapType == 4 ||
        sliceGroupMapType == 5) {
      sliceGroupChangeDirectionFlag = br.readBit() == 1;
      sliceGroupChangeRateMinus1 = readUE(br);
    } else if (sliceGroupMapType == 6) {
      picSizeInMapUnitsMinus1 = readUE(br);
      final numGroups = numSliceGroupsMinus1 + 1;
      int bits = 0;
      int t = numGroups - 1;
      while (t > 0) {
        bits++;
        t >>= 1;
      }
      for (int i = 0; i <= picSizeInMapUnitsMinus1; i++) {
        br.readBits(bits); // slice_group_id[i]
      }
    }
  }

  readUE(br); // num_ref_idx_l0_default_active_minus1
  readUE(br); // num_ref_idx_l1_default_active_minus1
  br.readBit(); // weighted_pred_flag
  br.readBits(2); // weighted_bipred_idc
  final picInitQpMinus26 = readSE(br);
  readSE(br); // pic_init_qs_minus26
  final chromaQpIndexOffset = readSE(br);
  final deblockingFilterControlPresentFlag = br.readBit() == 1;
  br.readBit(); // constrained_intra_pred_flag
  final redundantPicCntPresentFlag = br.readBit() == 1;

  bool transform8x8ModeFlag = false;
  if (_hasMoreRbspData(br)) {
    transform8x8ModeFlag = br.readBit() == 1;
    final picScalingMatrixPresentFlag = br.readBit();
    if (picScalingMatrixPresentFlag == 1) {
      final count = 6 + (transform8x8ModeFlag ? 2 : 0);
      for (int i = 0; i < count; i++) {
        final present = br.readBit();
        if (present == 1) {
          // skip pic_scaling_list_present_flag list payload (not used here)
          _skipScalingList(br, i < 6 ? 16 : 64);
        }
      }
    }
    readSE(br); // second_chroma_qp_index_offset
  }

  return PpsInfo(
    ppsId: ppsId,
    spsId: spsId,
    entropyCodingModeFlag: entropyCodingModeFlag,
    numSliceGroupsMinus1: numSliceGroupsMinus1,
    sliceGroupMapType: sliceGroupMapType,
    sliceGroupChangeDirectionFlag: sliceGroupChangeDirectionFlag,
    sliceGroupChangeRateMinus1: sliceGroupChangeRateMinus1,
    picSizeInMapUnitsMinus1: picSizeInMapUnitsMinus1,
    picInitQpMinus26: picInitQpMinus26,
    chromaQpIndexOffset: chromaQpIndexOffset,
    bottomFieldPicOrderInFramePresentFlag:
        bottomFieldPicOrderInFramePresentFlag,
    deblockingFilterControlPresentFlag: deblockingFilterControlPresentFlag,
    redundantPicCntPresentFlag: redundantPicCntPresentFlag,
    transform8x8ModeFlag: transform8x8ModeFlag,
  );
}

bool _hasMoreRbspData(BitReader br) {
  final pos = br.bitPos;
  final totalBits = br.data.length * 8;
  if (pos >= totalBits) return false;
  int lastOne = -1;
  for (int i = totalBits - 1; i >= pos; i--) {
    final byteIndex = i >> 3;
    final bitInByte = 7 - (i & 7);
    final b = (br.data[byteIndex] >> bitInByte) & 1;
    if (b == 1) {
      lastOne = i;
      break;
    }
  }
  if (lastOne < 0) return false;
  return pos < lastOne;
}

void _skipScalingList(BitReader br, int size) {
  int lastScale = 8;
  int nextScale = 8;
  for (int j = 0; j < size; j++) {
    if (nextScale != 0) {
      final deltaScale = readSE(br);
      nextScale = (lastScale + deltaScale) & 0xff;
    }
    lastScale = nextScale == 0 ? lastScale : nextScale;
  }
}
