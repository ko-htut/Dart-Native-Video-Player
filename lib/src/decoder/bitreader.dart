import 'dart:typed_data';

class BitReader {
  final Uint8List data;
  int _bit = 0;

  BitReader(this.data);

  bool get eof => (_bit >> 3) >= data.length;
  int get bitPos => _bit;
  int get bitsLeft {
    final left = data.length * 8 - _bit;
    return left > 0 ? left : 0;
  }

  void seekBit(int pos) {
    if (pos < 0) {
      _bit = 0;
      return;
    }
    final maxBits = data.length * 8;
    _bit = pos > maxBits ? maxBits : pos;
  }

  int mark() => _bit;

  void rewind(int bitPos) => seekBit(bitPos);

  int readBit() => readBits(1);

  int readBits(int n) {
    int v = 0;
    for (int i = 0; i < n; i++) {
      final bi = _bit >> 3;
      if (bi >= data.length) return v;
      final shift = 7 - (_bit & 7);
      v = (v << 1) | ((data[bi] >> shift) & 1);
      _bit++;
    }
    return v;
  }

  int peekBits(int n) {
    if (n <= 0) return 0;
    final m = mark();
    final v = readBits(n);
    rewind(m);
    return v;
  }

  String peekBitsStr(int n) {
    if (n <= 0) return '';
    final m = mark();
    final take = n < bitsLeft ? n : bitsLeft;
    final sb = StringBuffer();
    for (int i = 0; i < take; i++) {
      sb.write(readBit() == 1 ? '1' : '0');
    }
    rewind(m);
    return sb.toString();
  }

  void byteAlign() {
    final mod = _bit & 7;
    if (mod != 0) _bit += (8 - mod);
  }

  Uint8List readBytes(int n) {
    byteAlign();
    final start = _bit >> 3;
    final end = start + n;
    final safeEnd = end > data.length ? data.length : end;
    _bit += (safeEnd - start) * 8;
    if (start >= data.length) return Uint8List(0);
    return data.sublist(start, safeEnd);
  }
}
