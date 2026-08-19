import 'dart:typed_data';

import 'package:ndvy_player/src/decoder/bitreader.dart';

BitReader bitReader(String bits) {
  if (bits.contains(RegExp('[^01]'))) {
    throw ArgumentError.value(bits, 'bits', 'may contain only 0 and 1');
  }

  final bytes = Uint8List((bits.length + 7) >> 3);
  for (var index = 0; index < bits.length; index++) {
    if (bits.codeUnitAt(index) == 0x31) {
      bytes[index >> 3] |= 1 << (7 - (index & 7));
    }
  }
  return BitReader(bytes, bitLength: bits.length);
}

String unaryPrefix(int zeroCount) => '${List.filled(zeroCount, '0').join()}1';
