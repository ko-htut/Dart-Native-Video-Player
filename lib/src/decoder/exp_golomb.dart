import 'bitreader.dart';

int readUE(BitReader br) {
  int zeros = 0;
  while (true) {
    if (br.eof) {
      throw StateError('ue(v) unexpected EOF before stop bit');
    }
    final bit = br.readBit();
    if (bit == 1) {
      break;
    }
    zeros++;
    if (zeros > 31) {
      throw StateError('ue(v) too many leading zeros: $zeros');
    }
  }
  if (zeros == 0) return 0;
  if (br.bitsLeft < zeros) {
    throw StateError('ue(v) truncated suffix: need=$zeros left=${br.bitsLeft}');
  }
  final suffix = br.readBits(zeros);
  return ((1 << zeros) - 1) + suffix;
}

int readSE(BitReader br) {
  final ue = readUE(br);
  if (ue == 0) return 0;
  return (ue & 1) == 1 ? ((ue + 1) >> 1) : -(ue >> 1);
}
