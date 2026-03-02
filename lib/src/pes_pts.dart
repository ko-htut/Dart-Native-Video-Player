import 'dart:typed_data';

class PesParsed {
  final Uint8List esPayload; // elementary stream bytes after header
  final int? pts90k; // PTS in 90kHz clock, null if missing
  PesParsed({required this.esPayload, required this.pts90k});
}

/// Parse PES packet (starting at 0x000001) and return payload + PTS (if any).
PesParsed? parsePes(Uint8List pes) {
  if (pes.length < 14) return null;
  if (!(pes[0] == 0x00 && pes[1] == 0x00 && pes[2] == 0x01)) return null;

  // pes[3] stream_id, pes[4..5] length
  final flags1 = pes[6];
  final flags2 = pes[7];
  final headerDataLen = pes[8];

  // PTS_DTS_flags are bits 7..6 of flags2
  final ptsDtsFlags = (flags2 >> 6) & 0x03;

  int? pts;
  int idx = 9;

  if (ptsDtsFlags == 0x02 || ptsDtsFlags == 0x03) {
    // PTS is 5 bytes at idx
    if (pes.length >= idx + 5) {
      pts = _readPts90k(pes, idx);
    }
  }

  final payloadStart = 9 + headerDataLen;
  if (payloadStart >= pes.length) return null;

  return PesParsed(esPayload: pes.sublist(payloadStart), pts90k: pts);
}

int _readPts90k(Uint8List b, int i) {
  // 5-byte PTS format:
  // '0010' or '0011' in high nibble, then marker bits
  final p1 = ((b[i] >> 1) & 0x07) << 30;
  final p2 = ((b[i + 1] << 8) | b[i + 2]);
  final p3 = ((b[i + 3] << 8) | b[i + 4]);

  final mid = ((p2 >> 1) & 0x7FFF) << 15;
  final low = ((p3 >> 1) & 0x7FFF);

  return p1 | mid | low;
}
