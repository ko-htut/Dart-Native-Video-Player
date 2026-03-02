import 'bitreader.dart';

int readUE(BitReader br) {
  int zeros = 0;
  while (!br.eof && br.readBit() == 0) {
    zeros++;
    if (zeros > 31) break;
  }
  int value = (1 << zeros) - 1;
  if (zeros > 0) value += br.readBits(zeros);
  return value;
}

int readSE(BitReader br) {
  final ue = readUE(br);
  final v = ((ue + 1) >> 1) * ((ue & 1) == 1 ? 1 : -1);
  return v;
}
