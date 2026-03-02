import 'dart:typed_data';
import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';

class SpsInfo {
  final int spsId;
  final int width;
  final int height;
  final int log2MaxFrameNumMinus4;
  final int picOrderCntType;
  final int log2MaxPicOrderCntLsbMinus4;
  final bool deltaPicOrderAlwaysZeroFlag;
  final bool frameMbsOnlyFlag;
  final int profileIdc;
  final int levelIdc;

  const SpsInfo({
    required this.spsId,
    required this.width,
    required this.height,
    required this.log2MaxFrameNumMinus4,
    required this.picOrderCntType,
    required this.log2MaxPicOrderCntLsbMinus4,
    required this.deltaPicOrderAlwaysZeroFlag,
    required this.frameMbsOnlyFlag,
    required this.profileIdc,
    required this.levelIdc,
  });
}

SpsInfo parseSpsNal(Uint8List nal) {
  // nal[0] is NAL header. SPS payload starts at nal[1]
  final rbsp = ebspToRbsp(nal.sublist(1));
  final br = BitReader(rbsp);

  final profileIdc = br.readBits(8);
  br.readBits(8); // constraint_set flags (6 bits) + reserved_zero_2bits
  final levelIdc = br.readBits(8);
  final seqParameterSetId = readUE(br);

  int chromaFormatIdc = 1; // default 4:2:0
  if (_isHighProfile(profileIdc)) {
    chromaFormatIdc = readUE(br);
    if (chromaFormatIdc == 3) {
      br.readBit(); // separate_colour_plane_flag
    }
    readUE(br); // bit_depth_luma_minus8
    readUE(br); // bit_depth_chroma_minus8
    br.readBit(); // qpprime_y_zero_transform_bypass_flag
    final scalingMatrixPresent = br.readBit();
    if (scalingMatrixPresent == 1) {
      final count = (chromaFormatIdc != 3) ? 8 : 12;
      for (int i = 0; i < count; i++) {
        final present = br.readBit();
        if (present == 1) {
          _skipScalingList(br, i < 6 ? 16 : 64);
        }
      }
    }
  }

  final log2MaxFrameNumMinus4 = readUE(br);
  final picOrderCntType = readUE(br);
  int log2MaxPicOrderCntLsbMinus4 = 0;
  bool deltaPicOrderAlwaysZeroFlag = false;

  if (picOrderCntType == 0) {
    log2MaxPicOrderCntLsbMinus4 = readUE(br);
  } else if (picOrderCntType == 1) {
    deltaPicOrderAlwaysZeroFlag = br.readBit() == 1;
    readSE(br); // offset_for_non_ref_pic
    readSE(br); // offset_for_top_to_bottom_field
    final numRefFramesInPocCycle = readUE(br);
    for (int i = 0; i < numRefFramesInPocCycle; i++) {
      readSE(br); // offset_for_ref_frame[i]
    }
  }

  readUE(br); // max_num_ref_frames
  br.readBit(); // gaps_in_frame_num_value_allowed_flag

  final picWidthInMbsMinus1 = readUE(br);
  final picHeightInMapUnitsMinus1 = readUE(br);

  final frameMbsOnlyFlagInt = br.readBit(); // 1 => frames only
  if (frameMbsOnlyFlagInt == 0) {
    br.readBit(); // mb_adaptive_frame_field_flag
  }
  br.readBit(); // direct_8x8_inference_flag

  int frameCropLeft = 0,
      frameCropRight = 0,
      frameCropTop = 0,
      frameCropBottom = 0;
  final frameCroppingFlag = br.readBit();
  if (frameCroppingFlag == 1) {
    frameCropLeft = readUE(br);
    frameCropRight = readUE(br);
    frameCropTop = readUE(br);
    frameCropBottom = readUE(br);
  }

  // Compute coded size
  final width = (picWidthInMbsMinus1 + 1) * 16;
  final heightInMapUnits = (picHeightInMapUnitsMinus1 + 1);
  final height = (2 - frameMbsOnlyFlagInt) * heightInMapUnits * 16;

  // Apply cropping (units depend on chroma format)
  final cropUnitX = _cropUnitX(chromaFormatIdc);
  final cropUnitY = _cropUnitY(chromaFormatIdc, frameMbsOnlyFlagInt);

  final displayWidth = width - (frameCropLeft + frameCropRight) * cropUnitX;
  final displayHeight = height - (frameCropTop + frameCropBottom) * cropUnitY;

  return SpsInfo(
    spsId: seqParameterSetId,
    width: displayWidth,
    height: displayHeight,
    log2MaxFrameNumMinus4: log2MaxFrameNumMinus4,
    picOrderCntType: picOrderCntType,
    log2MaxPicOrderCntLsbMinus4: log2MaxPicOrderCntLsbMinus4,
    deltaPicOrderAlwaysZeroFlag: deltaPicOrderAlwaysZeroFlag,
    frameMbsOnlyFlag: frameMbsOnlyFlagInt == 1,
    profileIdc: profileIdc,
    levelIdc: levelIdc,
  );
}

bool _isHighProfile(int profileIdc) {
  // Profiles that include chroma_format_idc etc.
  return profileIdc == 100 ||
      profileIdc == 110 ||
      profileIdc == 122 ||
      profileIdc == 244 ||
      profileIdc == 44 ||
      profileIdc == 83 ||
      profileIdc == 86 ||
      profileIdc == 118 ||
      profileIdc == 128 ||
      profileIdc == 138 ||
      profileIdc == 139 ||
      profileIdc == 134;
}

int _cropUnitX(int chromaFormatIdc) {
  // For 4:2:0 => 2, 4:2:2 => 2, 4:4:4 => 1
  switch (chromaFormatIdc) {
    case 0:
      return 1; // monochrome
    case 1:
      return 2; // 4:2:0
    case 2:
      return 2; // 4:2:2
    case 3:
      return 1; // 4:4:4
    default:
      return 2;
  }
}

int _cropUnitY(int chromaFormatIdc, int frameMbsOnlyFlag) {
  // For 4:2:0 => 2*(2-frameMbsOnlyFlag)
  // For 4:2:2 => 1*(2-frameMbsOnlyFlag)
  // For 4:4:4 => 1*(2-frameMbsOnlyFlag)
  final subH = (chromaFormatIdc == 1)
      ? 2
      : 1; // only 4:2:0 has vertical subsampling
  return subH * (2 - frameMbsOnlyFlag);
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
