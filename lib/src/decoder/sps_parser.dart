import 'dart:typed_data';
import 'bitreader.dart';
import 'exp_golomb.dart';

Uint8List ebspToRbsp(Uint8List ebsp) {
  final out = BytesBuilder(copy: false);
  int zeros = 0;
  for (int i = 0; i < ebsp.length; i++) {
    final b = ebsp[i];
    if (zeros == 2 && b == 0x03) {
      zeros = 0;
      continue;
    }
    out.addByte(b);
    zeros = (b == 0x00) ? (zeros + 1) : 0;
  }
  return out.toBytes();
}

class SpsInfo {
  final int profileIdc;
  final int levelIdc;
  final int width;
  final int height;
  SpsInfo(this.profileIdc, this.levelIdc, this.width, this.height);
}

SpsInfo parseSps(Uint8List spsNal) {
  // spsNal[0] is NAL header; payload starts at 1
  final rbsp = ebspToRbsp(spsNal.sublist(1));
  final br = BitReader(rbsp);

  final profileIdc = br.readBits(8);
  br.readBits(8); // constraint flags + reserved
  final levelIdc = br.readBits(8);

  readUE(br); // seq_parameter_set_id

  // Some profiles include additional fields before frame sizing.
  if (profileIdc == 100 ||
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
      profileIdc == 134) {
    final chromaFormatIdc = readUE(br);
    if (chromaFormatIdc == 3) {
      br.readBit(); // separate_colour_plane_flag
    }
    readUE(br); // bit_depth_luma_minus8
    readUE(br); // bit_depth_chroma_minus8
    br.readBit(); // qpprime_y_zero_transform_bypass_flag
    final seqScalingMatrix = br.readBit();
    if (seqScalingMatrix == 1) {
      for (int i = 0; i < 8; i++) {
        final present = br.readBit();
        if (present == 1) {
          final size = i < 6 ? 16 : 64;
          int lastScale = 8;
          int nextScale = 8;
          for (int j = 0; j < size; j++) {
            if (nextScale != 0) {
              final delta = readSE(br);
              nextScale = (lastScale + delta + 256) % 256;
            }
            lastScale = nextScale == 0 ? lastScale : nextScale;
          }
        }
      }
    }
  }

  readUE(br); // log2_max_frame_num_minus4
  final picOrderCntType = readUE(br);
  if (picOrderCntType == 0) {
    readUE(br);
  } else if (picOrderCntType == 1) {
    br.readBit();
    readSE(br);
    readSE(br);
    final num = readUE(br);
    for (int i = 0; i < num; i++) {
      readSE(br);
    }
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

  // Assume 4:2:0 crop units (common in HLS AVC streams).
  final cropUnitX = 2;
  final cropUnitY = 2 * (frameMbsOnlyFlag == 1 ? 1 : 2);
  width -= (cropLeft + cropRight) * cropUnitX;
  height -= (cropTop + cropBottom) * cropUnitY;

  return SpsInfo(profileIdc, levelIdc, width, height);
}
