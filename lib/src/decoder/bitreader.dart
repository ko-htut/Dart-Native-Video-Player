import 'dart:typed_data';

class BitReader {
  final Uint8List data;
  int _bit = 0;

  BitReader(this.data);

  int get bitPos => _bit;
  int get bytePos => _bit >> 3;

  bool get eof => (bytePos) >= data.length;

  int readBit() => readBits(1);

  int readBits(int n) {
    int v = 0;
    for (int i = 0; i < n; i++) {
      final bi = _bit >> 3;
      if (bi >= data.length) return v; // soft EOF
      final shift = 7 - (_bit & 7);
      final b = (data[bi] >> shift) & 1;
      v = (v << 1) | b;
      _bit++;
    }
    return v;
  }

  void byteAlign() {
    final mod = _bit & 7;
    if (mod != 0) _bit += (8 - mod);
  }

  Uint8List readBytes(int n) {
    byteAlign();
    final start = bytePos;
    final end = start + n;
    if (start >= data.length) return Uint8List(0);
    final safeEnd = end > data.length ? data.length : end;
    _bit += (safeEnd - start) * 8;
    return data.sublist(start, safeEnd);
  }
}
