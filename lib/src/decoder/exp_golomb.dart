import 'bitreader.dart';

/// Reads an unsigned Exp-Golomb syntax element, ue(v).
int readUE(BitReader reader) {
  final startBit = reader.bitPos;
  var leadingZeroBits = 0;

  while (true) {
    if (reader.eof) {
      throw BitstreamFormatException(
        'truncated ue(v) starting at bit $startBit: missing stop bit',
        reader.bitPos,
      );
    }
    if (reader.readBit() == 1) break;

    leadingZeroBits++;
    // H.264 codeNum is limited to 32 bits (leadingZeroBits < 32).
    if (leadingZeroBits >= 32) {
      throw BitstreamFormatException(
        'invalid ue(v) starting at bit $startBit: '
        '$leadingZeroBits leading zero bits',
        reader.bitPos,
      );
    }
  }

  if (leadingZeroBits == 0) return 0;
  if (reader.bitsLeft < leadingZeroBits) {
    throw BitstreamFormatException(
      'truncated ue(v) suffix starting at bit $startBit: '
      'need $leadingZeroBits bits, have ${reader.bitsLeft}',
      reader.bitPos,
    );
  }

  final suffix = reader.readBits(leadingZeroBits);
  return ((1 << leadingZeroBits) - 1) + suffix;
}

/// Reads a signed Exp-Golomb syntax element, se(v).
int readSE(BitReader reader) {
  final codeNum = readUE(reader);
  return codeNum.isOdd ? (codeNum + 1) >> 1 : -(codeNum >> 1);
}

/// Reads a truncated Exp-Golomb syntax element, te(v), in `0..rangeMax`.
///
/// H.264 codes a two-value range as a single inverted bit. Larger ranges use
/// ue(v), while a zero range consumes no bits. Reference indices rely on this
/// distinction when exactly two list entries are active.
int readTE(BitReader reader, int rangeMax) {
  if (rangeMax < 0) {
    throw ArgumentError.value(rangeMax, 'rangeMax', 'must not be negative');
  }
  if (rangeMax == 0) return 0;
  if (rangeMax == 1) {
    if (reader.eof) {
      throw BitstreamFormatException(
        'truncated te(v) at bit ${reader.bitPos}',
        reader.bitPos,
      );
    }
    return 1 - reader.readBit();
  }

  final value = readUE(reader);
  if (value > rangeMax) {
    throw BitstreamFormatException(
      'te(v) value $value exceeds range 0..$rangeMax',
      reader.bitPos,
    );
  }
  return value;
}
