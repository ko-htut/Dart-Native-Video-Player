import 'dart:typed_data';

class PesParsed {
  final Uint8List esPayload;
  final int? pts90k;
  PesParsed({required this.esPayload, required this.pts90k});
}

PesParsed? parsePes(Uint8List pes) {
  if (pes.length < 14) return null;
  if (!(pes[0] == 0x00 && pes[1] == 0x00 && pes[2] == 0x01)) return null;

  final flags2 = pes[7];
  final headerDataLen = pes[8];

  final ptsDtsFlags = (flags2 >> 6) & 0x03;

  int? pts;
  int idx = 9;

  if (ptsDtsFlags == 0x02 || ptsDtsFlags == 0x03) {
    if (pes.length >= idx + 5) {
      pts = _readPts90k(pes, idx);
    }
  }

  final payloadStart = 9 + headerDataLen;
  if (payloadStart >= pes.length) return null;

  return PesParsed(esPayload: pes.sublist(payloadStart), pts90k: pts);
}

int _readPts90k(Uint8List b, int i) {
  final p1 = ((b[i] >> 1) & 0x07) << 30;
  final p2 = ((b[i + 1] << 8) | b[i + 2]);
  final p3 = ((b[i + 3] << 8) | b[i + 4]);

  final mid = ((p2 >> 1) & 0x7FFF) << 15;
  final low = ((p3 >> 1) & 0x7FFF);

  return p1 | mid | low;
}
