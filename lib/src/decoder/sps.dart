import 'dart:typed_data';
import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';

class SpsInfo {
  final int profileIdc;
  final int levelIdc;
  final int width;
  final int height;
  final int log2MaxFrameNumMinus4;

  const SpsInfo({
    required this.profileIdc,
    required this.levelIdc,
    required this.width,
    required this.height,
    required this.log2MaxFrameNumMinus4,
  });
}

SpsInfo parseSpsNal(Uint8List spsNal) {
  // spsNal[0] = NAL header, payload begins at 1
  final rbsp = ebspToRbsp(spsNal.sublist(1));
  final br = BitReader(rbsp);

  final profileIdc = br.readBits(8);
  br.readBits(8); // constraint flags + reserved
  final levelIdc = br.readBits(8);

  readUE(br); // sps_id

  // NOTE: For simplicity, we do not parse high-profile extra fields here.
  final log2MaxFrameNumMinus4 = readUE(br);

  final picOrderCntType = readUE(br);
  if (picOrderCntType == 0) {
    readUE(br);
  } else if (picOrderCntType == 1) {
    br.readBit();
    readSE(br);
    readSE(br);
    final num = readUE(br);
    for (int i = 0; i < num; i++) readSE(br);
  }

  readUE(br); // max_num_ref_frames
  br.readBit(); // gaps_in_frame_num_value_allowed_flag

  final picWidthInMbsMinus1 = readUE(br);
  final picHeightInMapUnitsMinus1 = readUE(br);

  final frameMbsOnlyFlag = br.readBit();
  if (frameMbsOnlyFlag == 0) br.readBit();

  br.readBit(); // direct_8x8_inference_flag

  final frameCroppingFlag = br.readBit();
  int cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
  if (frameCroppingFlag == 1) {
    cropLeft = readUE(br);
    cropRight = readUE(br);
    cropTop = readUE(br);
    cropBottom = readUE(br);
  }

  int width = (picWidthInMbsMinus1 + 1) * 16;
  int height =
      (picHeightInMapUnitsMinus1 + 1) * 16 * (frameMbsOnlyFlag == 1 ? 1 : 2);

  // Assume 4:2:0 crop units
  width -= (cropLeft + cropRight) * 2;
  height -= (cropTop + cropBottom) * 2 * (frameMbsOnlyFlag == 1 ? 1 : 2);

  return SpsInfo(
    profileIdc: profileIdc,
    levelIdc: levelIdc,
    width: width,
    height: height,
    log2MaxFrameNumMinus4: log2MaxFrameNumMinus4,
  );
}
