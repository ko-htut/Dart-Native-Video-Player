import 'dart:typed_data';

class PesParsed {
  final Uint8List esPayload; // elementary stream bytes after header
  final int? pts90k; // PTS in 90kHz clock, null if missing
  final int? dts90k;
  final int streamId;
  final int packetLength;

  PesParsed({
    required this.esPayload,
    required this.pts90k,
    this.dts90k,
    this.streamId = 0,
    this.packetLength = 0,
  });
}

/// Parse PES packet (starting at 0x000001) and return payload + PTS (if any).
PesParsed? parsePes(Uint8List pes) {
  if (pes.length < 9) return null;
  if (!(pes[0] == 0x00 && pes[1] == 0x00 && pes[2] == 0x01)) return null;

  final streamId = pes[3];
  final packetLength = (pes[4] << 8) | pes[5];
  final packetEnd = packetLength == 0 ? pes.length : 6 + packetLength;
  if (packetEnd > pes.length) return null;
  if ((pes[6] & 0xc0) != 0x80) return null;

  final flags2 = pes[7];
  final headerDataLen = pes[8];

  // PTS_DTS_flags are bits 7..6 of flags2
  final ptsDtsFlags = (flags2 >> 6) & 0x03;
  if (ptsDtsFlags == 0x01) return null; // forbidden by ISO/IEC 13818-1
  final payloadStart = 9 + headerDataLen;
  if (payloadStart > packetEnd) return null;
  if (ptsDtsFlags == 0x02 && headerDataLen < 5) return null;
  if (ptsDtsFlags == 0x03 && headerDataLen < 10) return null;

  int? pts;
  int? dts;
  int idx = 9;

  if (ptsDtsFlags == 0x02 || ptsDtsFlags == 0x03) {
    // PTS is 5 bytes at idx
    if (idx + 5 > packetEnd) return null;
    pts = _readPts90k(pes, idx, expectDts: false);
    if (pts == null) return null;
    idx += 5;
  }
  if (ptsDtsFlags == 0x03) {
    if (idx + 5 > packetEnd) return null;
    dts = _readPts90k(pes, idx, expectDts: true);
    if (dts == null) return null;
  }

  return PesParsed(
    esPayload: Uint8List.fromList(pes.sublist(payloadStart, packetEnd)),
    pts90k: pts,
    dts90k: dts,
    streamId: streamId,
    packetLength: packetLength,
  );
}

int? _readPts90k(Uint8List b, int i, {required bool expectDts}) {
  // 5-byte PTS format:
  // '0010' or '0011' in high nibble, then marker bits
  final prefix = b[i] >> 4;
  if (expectDts) {
    if (prefix != 0x01) return null;
  } else if (prefix != 0x02 && prefix != 0x03) {
    return null;
  }
  if ((b[i] & 1) == 0 || (b[i + 2] & 1) == 0 || (b[i + 4] & 1) == 0) {
    return null;
  }
  final p1 = ((b[i] >> 1) & 0x07) << 30;
  final p2 = ((b[i + 1] << 8) | b[i + 2]);
  final p3 = ((b[i + 3] << 8) | b[i + 4]);

  final mid = ((p2 >> 1) & 0x7FFF) << 15;
  final low = ((p3 >> 1) & 0x7FFF);

  return p1 | mid | low;
}
