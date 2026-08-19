import 'dart:typed_data';

import 'bitreader.dart';

/// Removes H.264 emulation-prevention bytes from an EBSP.
///
/// Invalid unescaped start-code patterns and a `00 00 03` sequence whose next
/// byte is outside `00..03` are rejected. Silently accepting either form can
/// shift every syntax element that follows it.
Uint8List ebspToRbsp(Uint8List ebsp) {
  final output = BytesBuilder(copy: false);
  var consecutiveZeros = 0;

  for (var index = 0; index < ebsp.length; index++) {
    final byte = ebsp[index];

    if (consecutiveZeros == 2) {
      if (byte == 0x03) {
        if (index + 1 >= ebsp.length) {
          throw BitstreamFormatException(
            'emulation_prevention_three_byte at end of EBSP',
            index * 8,
          );
        }
        final next = ebsp[index + 1];
        if (next > 0x03) {
          throw BitstreamFormatException(
            'emulation_prevention_three_byte followed by '
            '0x${next.toRadixString(16).padLeft(2, '0')}',
            index * 8,
          );
        }
        consecutiveZeros = 0;
        continue;
      }

      if (byte <= 0x02) {
        throw BitstreamFormatException(
          'unescaped 00 00 '
          '${byte.toRadixString(16).padLeft(2, '0')} sequence in EBSP',
          index * 8,
        );
      }
    }

    output.addByte(byte);
    consecutiveZeros = byte == 0 ? consecutiveZeros + 1 : 0;
  }

  return output.toBytes();
}

/// Implements the H.264 `more_rbsp_data()` test without consuming bits.
///
/// The only sequence that means "no more data" is a stop-one bit followed by
/// zero padding to the end of the RBSP. An all-zero suffix is malformed data,
/// not a valid substitute for rbsp_trailing_bits, so this function reports it
/// as more data and lets the syntax parser fail at the precise field.
bool moreRbspData(BitReader reader) {
  if (reader.eof) return false;

  final saved = reader.mark();
  try {
    if (reader.readBit() == 0) return true;
    while (!reader.eof) {
      if (reader.readBit() != 0) return true;
    }
    return false;
  } finally {
    reader.rewind(saved);
  }
}

/// Consumes and validates `rbsp_trailing_bits()` for a byte-aligned RBSP.
void readRbspTrailingBits(BitReader reader) {
  final startBit = reader.bitPos;
  if (reader.eof || reader.readBit() != 1) {
    throw BitstreamFormatException(
      'rbsp_stop_one_bit is missing or zero',
      startBit,
    );
  }

  while ((reader.bitPos & 7) != 0) {
    if (reader.eof) {
      throw BitstreamFormatException(
        'truncated rbsp_alignment_zero_bit sequence',
        reader.bitPos,
      );
    }
    if (reader.readBit() != 0) {
      throw BitstreamFormatException(
        'rbsp_alignment_zero_bit is not zero',
        reader.bitPos - 1,
      );
    }
  }

  if (!reader.eof) {
    throw BitstreamFormatException(
      'data remains after rbsp_trailing_bits',
      reader.bitPos,
    );
  }
}
