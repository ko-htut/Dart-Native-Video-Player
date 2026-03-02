import 'dart:typed_data';

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
    zeros = (b == 0x00) ? zeros + 1 : 0;
  }
  return out.toBytes();
}
