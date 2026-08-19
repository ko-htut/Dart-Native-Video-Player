import 'dart:typed_data';

import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';

/// Sequence parameter set fields required by the software decoder.
///
/// The decoder intentionally supports progressive, 8-bit, 4:2:0 AVC. Other
/// profiles are still parsed far enough to produce a precise compatibility
/// error instead of being decoded with the wrong plane geometry.
class SpsInfo {
  final int spsId;
  final int profileIdc;
  final int constraintFlags;
  final int levelIdc;
  final int chromaFormatIdc;
  final bool separateColourPlaneFlag;
  final int bitDepthLumaMinus8;
  final int bitDepthChromaMinus8;
  final bool qpprimeYZeroTransformBypassFlag;
  final bool scalingMatrixPresent;
  final int log2MaxFrameNumMinus4;
  final int picOrderCntType;
  final int log2MaxPicOrderCntLsbMinus4;
  final bool deltaPicOrderAlwaysZeroFlag;
  final int maxNumRefFrames;
  final bool gapsInFrameNumValueAllowedFlag;
  final int picWidthInMbsMinus1;
  final int picHeightInMapUnitsMinus1;
  final bool frameMbsOnlyFlag;
  final bool mbAdaptiveFrameFieldFlag;
  final bool direct8x8InferenceFlag;
  final int frameCropLeftOffset;
  final int frameCropRightOffset;
  final int frameCropTopOffset;
  final int frameCropBottomOffset;
  final int cropUnitX;
  final int cropUnitY;
  final bool vuiParametersPresentFlag;

  /// Display dimensions after applying the SPS crop rectangle.
  final int width;
  final int height;

  /// Full coded-picture dimensions used for macroblock addressing.
  final int codedWidth;
  final int codedHeight;

  const SpsInfo({
    required this.spsId,
    required this.profileIdc,
    required this.constraintFlags,
    required this.levelIdc,
    required this.chromaFormatIdc,
    required this.separateColourPlaneFlag,
    required this.bitDepthLumaMinus8,
    required this.bitDepthChromaMinus8,
    required this.qpprimeYZeroTransformBypassFlag,
    required this.scalingMatrixPresent,
    required this.log2MaxFrameNumMinus4,
    required this.picOrderCntType,
    required this.log2MaxPicOrderCntLsbMinus4,
    required this.deltaPicOrderAlwaysZeroFlag,
    required this.maxNumRefFrames,
    required this.gapsInFrameNumValueAllowedFlag,
    required this.picWidthInMbsMinus1,
    required this.picHeightInMapUnitsMinus1,
    required this.frameMbsOnlyFlag,
    required this.mbAdaptiveFrameFieldFlag,
    required this.direct8x8InferenceFlag,
    required this.frameCropLeftOffset,
    required this.frameCropRightOffset,
    required this.frameCropTopOffset,
    required this.frameCropBottomOffset,
    required this.cropUnitX,
    required this.cropUnitY,
    required this.vuiParametersPresentFlag,
    required this.width,
    required this.height,
    required this.codedWidth,
    required this.codedHeight,
  });

  int get maxFrameNum => 1 << (log2MaxFrameNumMinus4 + 4);

  int get maxPicOrderCntLsb => 1 << (log2MaxPicOrderCntLsbMinus4 + 4);

  int get cropLeftPixels => frameCropLeftOffset * cropUnitX;

  int get cropRightPixels => frameCropRightOffset * cropUnitX;

  int get cropTopPixels => frameCropTopOffset * cropUnitY;

  int get cropBottomPixels => frameCropBottomOffset * cropUnitY;

  bool get isSupportedBaseline420 =>
      (profileIdc == 66 || profileIdc == 77 || profileIdc == 88) &&
      chromaFormatIdc == 1 &&
      !separateColourPlaneFlag &&
      bitDepthLumaMinus8 == 0 &&
      bitDepthChromaMinus8 == 0 &&
      !qpprimeYZeroTransformBypassFlag &&
      !scalingMatrixPresent &&
      frameMbsOnlyFlag;
}

SpsInfo parseSpsNal(Uint8List nal) {
  if (nal.length < 2 || (nal.first & 0x1f) != 7) {
    throw const FormatException('SPS NAL is missing or has the wrong NAL type');
  }

  final rbsp = ebspToRbsp(Uint8List.sublistView(nal, 1));
  final br = BitReader(rbsp);

  final profileIdc = br.readBits(8);
  final constraintFlags = br.readBits(8);
  final levelIdc = br.readBits(8);
  final spsId = readUE(br);

  var chromaFormatIdc = 1;
  var separateColourPlaneFlag = false;
  var bitDepthLumaMinus8 = 0;
  var bitDepthChromaMinus8 = 0;
  var qpprimeYZeroTransformBypassFlag = false;
  var scalingMatrixPresent = false;

  if (_hasExtendedProfileSyntax(profileIdc)) {
    chromaFormatIdc = readUE(br);
    if (chromaFormatIdc < 0 || chromaFormatIdc > 3) {
      throw FormatException('Unsupported chroma_format_idc=$chromaFormatIdc');
    }
    if (chromaFormatIdc == 3) {
      separateColourPlaneFlag = br.readBit() == 1;
    }
    bitDepthLumaMinus8 = readUE(br);
    bitDepthChromaMinus8 = readUE(br);
    qpprimeYZeroTransformBypassFlag = br.readBit() == 1;
    scalingMatrixPresent = br.readBit() == 1;
    if (scalingMatrixPresent) {
      final count = chromaFormatIdc == 3 ? 12 : 8;
      for (var i = 0; i < count; i++) {
        if (br.readBit() == 1) {
          _skipScalingList(br, i < 6 ? 16 : 64);
        }
      }
    }
  }

  final log2MaxFrameNumMinus4 = readUE(br);
  final picOrderCntType = readUE(br);
  var log2MaxPicOrderCntLsbMinus4 = 0;
  var deltaPicOrderAlwaysZeroFlag = false;

  if (picOrderCntType == 0) {
    log2MaxPicOrderCntLsbMinus4 = readUE(br);
  } else if (picOrderCntType == 1) {
    deltaPicOrderAlwaysZeroFlag = br.readBit() == 1;
    readSE(br); // offset_for_non_ref_pic
    readSE(br); // offset_for_top_to_bottom_field
    final cycleLength = readUE(br);
    for (var i = 0; i < cycleLength; i++) {
      readSE(br); // offset_for_ref_frame[i]
    }
  } else if (picOrderCntType != 2) {
    throw FormatException('Invalid pic_order_cnt_type=$picOrderCntType');
  }

  final maxNumRefFrames = readUE(br);
  final gapsInFrameNumValueAllowedFlag = br.readBit() == 1;
  final picWidthInMbsMinus1 = readUE(br);
  final picHeightInMapUnitsMinus1 = readUE(br);
  final frameMbsOnlyFlag = br.readBit() == 1;
  var mbAdaptiveFrameFieldFlag = false;
  if (!frameMbsOnlyFlag) {
    mbAdaptiveFrameFieldFlag = br.readBit() == 1;
  }
  final direct8x8InferenceFlag = br.readBit() == 1;

  var frameCropLeftOffset = 0;
  var frameCropRightOffset = 0;
  var frameCropTopOffset = 0;
  var frameCropBottomOffset = 0;
  if (br.readBit() == 1) {
    frameCropLeftOffset = readUE(br);
    frameCropRightOffset = readUE(br);
    frameCropTopOffset = readUE(br);
    frameCropBottomOffset = readUE(br);
  }
  final vuiParametersPresentFlag = br.readBit() == 1;

  final codedWidth = (picWidthInMbsMinus1 + 1) * 16;
  final codedHeight =
      (picHeightInMapUnitsMinus1 + 1) * 16 * (frameMbsOnlyFlag ? 1 : 2);
  final chromaArrayType = separateColourPlaneFlag ? 0 : chromaFormatIdc;
  final (cropUnitX, cropUnitY) = _cropUnits(chromaArrayType, frameMbsOnlyFlag);
  final width =
      codedWidth - (frameCropLeftOffset + frameCropRightOffset) * cropUnitX;
  final height =
      codedHeight - (frameCropTopOffset + frameCropBottomOffset) * cropUnitY;

  if (width <= 0 || height <= 0) {
    throw FormatException(
      'Invalid cropped dimensions ${width}x$height from ${codedWidth}x$codedHeight',
    );
  }

  return SpsInfo(
    spsId: spsId,
    profileIdc: profileIdc,
    constraintFlags: constraintFlags,
    levelIdc: levelIdc,
    chromaFormatIdc: chromaFormatIdc,
    separateColourPlaneFlag: separateColourPlaneFlag,
    bitDepthLumaMinus8: bitDepthLumaMinus8,
    bitDepthChromaMinus8: bitDepthChromaMinus8,
    qpprimeYZeroTransformBypassFlag: qpprimeYZeroTransformBypassFlag,
    scalingMatrixPresent: scalingMatrixPresent,
    log2MaxFrameNumMinus4: log2MaxFrameNumMinus4,
    picOrderCntType: picOrderCntType,
    log2MaxPicOrderCntLsbMinus4: log2MaxPicOrderCntLsbMinus4,
    deltaPicOrderAlwaysZeroFlag: deltaPicOrderAlwaysZeroFlag,
    maxNumRefFrames: maxNumRefFrames,
    gapsInFrameNumValueAllowedFlag: gapsInFrameNumValueAllowedFlag,
    picWidthInMbsMinus1: picWidthInMbsMinus1,
    picHeightInMapUnitsMinus1: picHeightInMapUnitsMinus1,
    frameMbsOnlyFlag: frameMbsOnlyFlag,
    mbAdaptiveFrameFieldFlag: mbAdaptiveFrameFieldFlag,
    direct8x8InferenceFlag: direct8x8InferenceFlag,
    frameCropLeftOffset: frameCropLeftOffset,
    frameCropRightOffset: frameCropRightOffset,
    frameCropTopOffset: frameCropTopOffset,
    frameCropBottomOffset: frameCropBottomOffset,
    cropUnitX: cropUnitX,
    cropUnitY: cropUnitY,
    vuiParametersPresentFlag: vuiParametersPresentFlag,
    width: width,
    height: height,
    codedWidth: codedWidth,
    codedHeight: codedHeight,
  );
}

bool _hasExtendedProfileSyntax(int profileIdc) => const <int>{
  44,
  83,
  86,
  100,
  110,
  118,
  122,
  128,
  134,
  135,
  138,
  139,
  244,
}.contains(profileIdc);

(int, int) _cropUnits(int chromaArrayType, bool frameMbsOnlyFlag) {
  if (chromaArrayType == 0) {
    return (1, frameMbsOnlyFlag ? 1 : 2);
  }
  final subWidthC = chromaArrayType == 3 ? 1 : 2;
  final subHeightC = chromaArrayType == 1 ? 2 : 1;
  return (subWidthC, subHeightC * (frameMbsOnlyFlag ? 1 : 2));
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
