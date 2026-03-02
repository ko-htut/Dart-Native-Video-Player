import 'dart:typed_data';

class BitReader {
  final Uint8List data;
  int _bit = 0;

  BitReader(this.data);

  int get bitPos => _bit;

  bool get eof => (_bit >> 3) >= data.length;

  int readBits(int n) {
    int v = 0;
    for (int i = 0; i < n; i++) {
      final byteIndex = _bit >> 3;
      final bitIndex = 7 - (_bit & 7);
      final b = (data[byteIndex] >> bitIndex) & 1;
      v = (v << 1) | b;
      _bit++;
    }
    return v;
  }

  int readBit() => readBits(1);

  void skipBits(int n) => _bit += n;
}
