import 'dart:typed_data';
import 'bitreader.dart';

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

int _peekBit(Uint8List data, int bitPos) {
  final byteIndex = bitPos >> 3;
  final bitInByte = 7 - (bitPos & 7);
  if (byteIndex < 0 || byteIndex >= data.length) return 0;
  return (data[byteIndex] >> bitInByte) & 1;
}

bool moreRbspData(BitReader br) {
  final totalBits = br.data.length * 8;
  final pos = br.bitPos;
  if (pos >= totalBits) return false;

  // Find the last '1' bit from current position to end.
  // That last '1' is rbsp_stop_one_bit when no more payload remains.
  int lastOne = -1;
  for (int i = totalBits - 1; i >= pos; i--) {
    if (_peekBit(br.data, i) == 1) {
      lastOne = i;
      break;
    }
  }
  if (lastOne < 0) return false;
  return pos < lastOne;
}
