import 'dart:typed_data';

List<Uint8List> splitAnnexBNals(Uint8List es) {
  final nals = <Uint8List>[];

  int start = _findStartCode(es, 0);
  while (start != -1) {
    final scLen = (es[start + 2] == 1) ? 3 : 4;
    final nalStart = start + scLen;

    final next = _findStartCode(es, nalStart);
    final nalEnd = (next == -1) ? es.length : next;

    if (nalEnd > nalStart) {
      nals.add(es.sublist(nalStart, nalEnd));
    }
    start = next;
  }

  return nals;
}

int _findStartCode(Uint8List b, int from) {
  for (int i = from; i + 3 < b.length; i++) {
    if (b[i] == 0 && b[i + 1] == 0) {
      if (b[i + 2] == 1) return i; // 00 00 01
      if (i + 4 < b.length && b[i + 2] == 0 && b[i + 3] == 1) {
        return i; // 00 00 00 01
      }
    }
  }
  return -1;
}

class NalStats {
  final Map<int, int> counts;
  final Uint8List? firstSps;

  NalStats(this.counts, this.firstSps);

  static NalStats fromNals(List<Uint8List> nals) {
    final counts = <int, int>{};
    Uint8List? sps;

    for (final nal in nals) {
      if (nal.isEmpty) continue;
      final t = nal[0] & 0x1F;
      counts[t] = (counts[t] ?? 0) + 1;
      if (t == 7 && sps == null) sps = nal;
    }
    return NalStats(counts, sps);
  }

  String toPrettyString() {
    String name(int t) => switch (t) {
      1 => 'nonIDR',
      5 => 'IDR',
      6 => 'SEI',
      7 => 'SPS',
      8 => 'PPS',
      9 => 'AUD',
      _ => 'type$t',
    };
    final keys = counts.keys.toList()..sort();
    return keys.map((k) => '${name(k)}=${counts[k]}').join(', ');
  }
}

// --------------------------
// SUPER basic SPS parsing
// (enough to estimate width/height in many streams)
// --------------------------

class SpsInfo {
  final int profileIdc;
  final int levelIdc;
  final int width;
  final int height;

  SpsInfo({
    required this.profileIdc,
    required this.levelIdc,
    required this.width,
    required this.height,
  });
}

// Remove emulation prevention bytes (0x03 after 00 00)
Uint8List _ebspToRbsp(Uint8List ebsp) {
  final out = BytesBuilder(copy: false);
  int zeros = 0;
  for (int i = 0; i < ebsp.length; i++) {
    final b = ebsp[i];
    if (zeros == 2 && b == 0x03) {
      zeros = 0;
      continue;
    }
    out.addByte(b);
    if (b == 0x00) {
      zeros++;
    } else {
      zeros = 0;
    }
  }
  return out.toBytes();
}

class _BitReader {
  final Uint8List data;
  int _bit = 0;
  _BitReader(this.data);

  int readBits(int n) {
    int v = 0;
    for (int i = 0; i < n; i++) {
      final byteIndex = _bit >> 3;
      final bitIndex = 7 - (_bit & 7);
      final bitVal = (data[byteIndex] >> bitIndex) & 1;
      v = (v << 1) | bitVal;
      _bit++;
    }
    return v;
  }

  int readBit() => readBits(1);

  int readUE() {
    int zeros = 0;
    while (readBit() == 0) {
      zeros++;
      if (zeros > 31) break;
    }
    int value = (1 << zeros) - 1;
    if (zeros > 0) value += readBits(zeros);
    return value;
  }

  int readSE() {
    final ue = readUE();
    final v = ((ue + 1) >> 1) * (ue.isOdd ? 1 : -1);
    return v;
  }
}

SpsInfo parseSpsBasic(Uint8List spsNal) {
  // spsNal includes NAL header at [0]
  final rbsp = _ebspToRbsp(spsNal.sublist(1));
  final br = _BitReader(rbsp);

  final profileIdc = rbsp[0];
  // constraint flags + reserved
  // rbsp[1]
  final levelIdc = rbsp[2];

  // Skip profile/constraints/level already in bytes; bitreader starts at rbsp[0]
  // So reset bit offset to after first 3 bytes:
  br.readBits(24);

  br.readUE(); // seq_parameter_set_id

  // Some profiles have extra fields; we handle minimal common case
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
    final chromaFormatIdc = br.readUE();
    if (chromaFormatIdc == 3) br.readBit(); // separate_colour_plane_flag
    br.readUE(); // bit_depth_luma_minus8
    br.readUE(); // bit_depth_chroma_minus8
    br.readBit(); // qpprime_y_zero_transform_bypass_flag
    final seqScalingMatrix = br.readBit();
    if (seqScalingMatrix == 1) {
      // Skip scaling lists crudely (not needed for width/height)
      // This is a simplified skip; fine for many streams.
      // In a full decoder you'd properly parse scaling lists.
      for (int i = 0; i < 8; i++) {
        final present = br.readBit();
        if (present == 1) {
          int size = (i < 6) ? 16 : 64;
          int lastScale = 8;
          int nextScale = 8;
          for (int j = 0; j < size; j++) {
            if (nextScale != 0) {
              final delta = br.readSE();
              nextScale = (lastScale + delta + 256) % 256;
            }
            lastScale = nextScale == 0 ? lastScale : nextScale;
          }
        }
      }
    }
  }

  br.readUE(); // log2_max_frame_num_minus4
  final picOrderCntType = br.readUE();
  if (picOrderCntType == 0) {
    br.readUE(); // log2_max_pic_order_cnt_lsb_minus4
  } else if (picOrderCntType == 1) {
    br.readBit(); // delta_pic_order_always_zero_flag
    br.readSE(); // offset_for_non_ref_pic
    br.readSE(); // offset_for_top_to_bottom_field
    final numRef = br.readUE();
    for (int i = 0; i < numRef; i++) {
      br.readSE();
    }
  }

  br.readUE(); // max_num_ref_frames
  br.readBit(); // gaps_in_frame_num_value_allowed_flag

  final picWidthInMbsMinus1 = br.readUE();
  final picHeightInMapUnitsMinus1 = br.readUE();

  final frameMbsOnlyFlag = br.readBit();
  if (frameMbsOnlyFlag == 0) br.readBit(); // mb_adaptive_frame_field_flag

  br.readBit(); // direct_8x8_inference_flag

  final frameCroppingFlag = br.readBit();
  int cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
  if (frameCroppingFlag == 1) {
    cropLeft = br.readUE();
    cropRight = br.readUE();
    cropTop = br.readUE();
    cropBottom = br.readUE();
  }

  // Approx dimensions (assuming 4:2:0 most common)
  int width = (picWidthInMbsMinus1 + 1) * 16;
  int height =
      (picHeightInMapUnitsMinus1 + 1) * 16 * (frameMbsOnlyFlag == 1 ? 1 : 2);

  // Crop units for 4:2:0 (most common)
  final cropUnitX = 2;
  final cropUnitY = 2 * (frameMbsOnlyFlag == 1 ? 1 : 2);

  width -= (cropLeft + cropRight) * cropUnitX;
  height -= (cropTop + cropBottom) * cropUnitY;

  return SpsInfo(
    profileIdc: profileIdc,
    levelIdc: levelIdc,
    width: width,
    height: height,
  );
}
