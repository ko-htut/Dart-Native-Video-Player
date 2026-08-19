import 'dart:typed_data';

/// Bounds-checked MSB-first bit reader used by the AAC syntax decoder.
final class AacBitReader {
  AacBitReader(Uint8List bytes) : _bytes = bytes;

  final Uint8List _bytes;
  int bitOffset = 0;

  int get bitsRemaining => _bytes.length * 8 - bitOffset;
  bool get isByteAligned => (bitOffset & 7) == 0;

  int readBit() => readBits(1);

  bool readBool() => readBit() != 0;

  int readBits(int count) {
    if (count < 0 || count > 31) {
      throw RangeError.range(count, 0, 31, 'count');
    }
    if (count > bitsRemaining) {
      throw AacDecoderException(
        'Truncated AAC access unit: need $count bits, have $bitsRemaining',
        bitOffset: bitOffset,
      );
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      final byte = _bytes[bitOffset >> 3];
      value = (value << 1) | ((byte >> (7 - (bitOffset & 7))) & 1);
      bitOffset++;
    }
    return value;
  }

  void skipBits(int count) {
    if (count < 0 || count > bitsRemaining) {
      throw AacDecoderException(
        'Truncated AAC access unit while skipping $count bits',
        bitOffset: bitOffset,
      );
    }
    bitOffset += count;
  }

  void alignToByte() {
    final padding = (-bitOffset) & 7;
    skipBits(padding);
  }
}

/// A malformed or deliberately unsupported AAC syntax condition.
final class AacDecoderException implements FormatException {
  const AacDecoderException(this.message, {this.bitOffset});

  @override
  final String message;
  final int? bitOffset;

  @override
  dynamic get source => null;

  @override
  int? get offset => bitOffset;

  @override
  String toString() => bitOffset == null
      ? 'AacDecoderException: $message'
      : 'AacDecoderException at bit $bitOffset: $message';
}
