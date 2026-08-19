import 'dart:typed_data';

/// A malformed or truncated bitstream.
///
/// [bitPosition] is measured from the first (most-significant) bit of the
/// first byte. Decoders should let this exception escape instead of guessing
/// missing syntax values: once a variable-length code is damaged there is no
/// reliable way to recover the following syntax elements.
class BitstreamFormatException extends FormatException {
  final int bitPosition;

  const BitstreamFormatException(String message, this.bitPosition)
    : super(message, null, bitPosition);

  @override
  String toString() => 'BitstreamFormatException at bit $bitPosition: $message';
}

/// MSB-first reader for H.264 syntax elements.
///
/// Reads are exact: attempting to consume past [bitLength] throws a
/// [BitstreamFormatException]. The optional [bitLength] is useful when the
/// final byte contains padding that is not part of the logical bitstream.
class BitReader {
  final Uint8List data;
  final int bitLength;
  int _bit = 0;

  BitReader(this.data, {int? bitLength})
    : bitLength = bitLength ?? data.length * 8 {
    RangeError.checkValueInInterval(
      this.bitLength,
      0,
      data.length * 8,
      'bitLength',
    );
  }

  bool get eof => _bit >= bitLength;
  int get bitPos => _bit;
  int get bitsLeft => bitLength - _bit;

  /// Moves to an absolute bit position.
  ///
  /// Seeking outside the logical bitstream is a programming error and is not
  /// silently clamped.
  void seekBit(int position) {
    RangeError.checkValueInInterval(position, 0, bitLength, 'position');
    _bit = position;
  }

  int mark() => _bit;

  void rewind(int bitPosition) => seekBit(bitPosition);

  int readBit() {
    _requireBits(1, 'bit');
    final byteIndex = _bit >> 3;
    final shift = 7 - (_bit & 7);
    final value = (data[byteIndex] >> shift) & 1;
    _bit++;
    return value;
  }

  int readBits(int count) {
    RangeError.checkNotNegative(count, 'count');
    _requireBits(count, '$count bits');

    var value = 0;
    for (var i = 0; i < count; i++) {
      final byteIndex = _bit >> 3;
      final shift = 7 - (_bit & 7);
      value = (value << 1) | ((data[byteIndex] >> shift) & 1);
      _bit++;
    }
    return value;
  }

  void skipBits(int count) {
    RangeError.checkNotNegative(count, 'count');
    _requireBits(count, '$count bits');
    _bit += count;
  }

  int peekBits(int count) {
    RangeError.checkNotNegative(count, 'count');
    _requireBits(count, '$count bits');
    final saved = _bit;
    try {
      return readBits(count);
    } finally {
      _bit = saved;
    }
  }

  /// Returns up to [count] remaining bits without advancing the reader.
  ///
  /// Unlike [peekBits], this is a diagnostic preview and intentionally
  /// shortens at EOF.
  String peekBitsStr(int count) {
    RangeError.checkNotNegative(count, 'count');
    final saved = _bit;
    final take = count < bitsLeft ? count : bitsLeft;
    final buffer = StringBuffer();
    try {
      for (var i = 0; i < take; i++) {
        buffer.write(readBit() == 1 ? '1' : '0');
      }
      return buffer.toString();
    } finally {
      _bit = saved;
    }
  }

  void byteAlign() {
    final aligned = (_bit + 7) & ~7;
    if (aligned > bitLength) {
      throw BitstreamFormatException(
        'truncated byte-alignment padding: need ${aligned - _bit} bits, '
        'have $bitsLeft',
        _bit,
      );
    }
    _bit = aligned;
  }

  /// Reads exactly [count] bytes after advancing to the next byte boundary.
  Uint8List readBytes(int count) {
    RangeError.checkNotNegative(count, 'count');

    final aligned = (_bit + 7) & ~7;
    final requestedBits = count * 8;
    if (aligned > bitLength || requestedBits > bitLength - aligned) {
      final available = aligned <= bitLength ? (bitLength - aligned) >> 3 : 0;
      throw BitstreamFormatException(
        'truncated byte read: need $count bytes, have $available',
        _bit,
      );
    }

    final start = aligned >> 3;
    final end = start + count;
    _bit = aligned + requestedBits;
    return Uint8List.sublistView(data, start, end);
  }

  void _requireBits(int count, String description) {
    if (count > bitsLeft) {
      throw BitstreamFormatException(
        'unexpected end of stream while reading $description: '
        'need $count bits, have $bitsLeft',
        _bit,
      );
    }
  }
}
