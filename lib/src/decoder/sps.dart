import 'dart:typed_data';

import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';
import 'scaling_list_syntax.dart';

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
  final List<H264ScalingListSyntax> scalingLists;
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
    this.scalingLists = const <H264ScalingListSyntax>[],
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

  int get bitDepthLuma => bitDepthLumaMinus8 + 8;

  int get bitDepthChroma => bitDepthChromaMinus8 + 8;

  /// Alias matching the exact SPS syntax-element name.
  bool get seqScalingMatrixPresentFlag => scalingMatrixPresent;

  /// True when no sequence-level scaling-matrix syntax overrides Flat_*_16.
  bool get usesFlatScalingMatrices => !seqScalingMatrixPresentFlag;

  bool get hasExplicitScalingLists =>
      scalingLists.any((list) => list.isExplicit);

  /// Decoder-independent geometry/bit-depth subset used by the sfux stream.
  bool get isProgressive8Bit420 =>
      chromaFormatIdc == 1 &&
      !separateColourPlaneFlag &&
      bitDepthLumaMinus8 == 0 &&
      bitDepthChromaMinus8 == 0 &&
      !qpprimeYZeroTransformBypassFlag &&
      frameMbsOnlyFlag;

  bool get isHighProfile8Bit420 => profileIdc == 100 && isProgressive8Bit420;

  int get cropLeftPixels => frameCropLeftOffset * cropUnitX;

  int get cropRightPixels => frameCropRightOffset * cropUnitX;

  int get cropTopPixels => frameCropTopOffset * cropUnitY;

  int get cropBottomPixels => frameCropBottomOffset * cropUnitY;

  bool get isSupportedBaseline420 =>
      (profileIdc == 66 || profileIdc == 77 || profileIdc == 88) &&
      isProgressive8Bit420 &&
      usesFlatScalingMatrices;
}

SpsInfo parseSpsNal(Uint8List nal) {
  if (nal.length < 2 || (nal.first & 0x80) != 0 || (nal.first & 0x1f) != 7) {
    throw const FormatException('SPS NAL is missing or has the wrong NAL type');
  }

  final rbsp = ebspToRbsp(Uint8List.sublistView(nal, 1));
  final br = BitReader(rbsp);

  final profileIdc = br.readBits(8);
  final constraintFlags = br.readBits(8);
  if ((constraintFlags & 0x03) != 0) {
    throw FormatException(
      'SPS reserved_zero_2bits must be zero, got ${constraintFlags & 0x03}',
    );
  }
  final levelIdc = br.readBits(8);
  final spsId = readUE(br);
  if (spsId > 31) {
    throw FormatException('seq_parameter_set_id=$spsId exceeds 31');
  }

  var chromaFormatIdc = 1;
  var separateColourPlaneFlag = false;
  var bitDepthLumaMinus8 = 0;
  var bitDepthChromaMinus8 = 0;
  var qpprimeYZeroTransformBypassFlag = false;
  var scalingMatrixPresent = false;
  var scalingLists = _absentScalingLists(8);

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
    if (bitDepthLumaMinus8 > 6 || bitDepthChromaMinus8 > 6) {
      throw FormatException(
        'Invalid SPS bit depth: luma=${bitDepthLumaMinus8 + 8}, '
        'chroma=${bitDepthChromaMinus8 + 8}',
      );
    }
    qpprimeYZeroTransformBypassFlag = br.readBit() == 1;
    scalingMatrixPresent = br.readBit() == 1;
    final count = chromaFormatIdc == 3 ? 12 : 8;
    scalingLists = scalingMatrixPresent
        ? _readScalingLists(br, count)
        : _absentScalingLists(count);
  }

  final log2MaxFrameNumMinus4 = readUE(br);
  if (log2MaxFrameNumMinus4 > 12) {
    throw FormatException(
      'log2_max_frame_num_minus4=$log2MaxFrameNumMinus4 exceeds 12',
    );
  }
  final picOrderCntType = readUE(br);
  var log2MaxPicOrderCntLsbMinus4 = 0;
  var deltaPicOrderAlwaysZeroFlag = false;

  if (picOrderCntType == 0) {
    log2MaxPicOrderCntLsbMinus4 = readUE(br);
    if (log2MaxPicOrderCntLsbMinus4 > 12) {
      throw FormatException(
        'log2_max_pic_order_cnt_lsb_minus4='
        '$log2MaxPicOrderCntLsbMinus4 exceeds 12',
      );
    }
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
  // Annex A derives MaxDpbFrames with an absolute maximum of 16 frame
  // pictures. Reject an invalid larger value here so it can never become an
  // unbounded retained-picture budget in a streaming decoder.
  if (maxNumRefFrames > 16) {
    throw FormatException(
      'max_num_ref_frames=$maxNumRefFrames exceeds the H.264 maximum of 16',
    );
  }
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
    scalingLists: List<H264ScalingListSyntax>.unmodifiable(scalingLists),
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
