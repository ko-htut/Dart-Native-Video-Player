import '../bitreader.dart';
import 'cabac_context.dart';
import 'cabac_tables.dart';

/// Normative H.264 CABAC binary arithmetic decoder.
///
/// This implements only the arithmetic engine in clauses 9.3.3.2.1 through
/// 9.3.3.2.3. Syntax-element binarization and context-index derivation remain
/// the responsibility of the slice decoder that will integrate this class.
final class H264CabacDecoder {
  H264CabacDecoder._({
    required BitReader reader,
    required int startBitPosition,
    required int offset,
  }) : _reader = reader,
       _startBitPosition = startBitPosition,
       _offset = offset;

  /// Initializes `codIRange` to 510 and reads the nine-bit `codIOffset`.
  ///
  /// The reader must already point to the first CABAC arithmetic payload bit,
  /// after the slice header's repeated `cabac_alignment_one_bit` values.
  factory H264CabacDecoder.initialize(BitReader reader) {
    final start = reader.bitPos;
    final offset = reader.readBits(9);
    if (offset >= 510) {
      throw BitstreamFormatException(
        'CABAC codIOffset must be less than 510, got $offset',
        start,
      );
    }
    return H264CabacDecoder._(
      reader: reader,
      startBitPosition: start,
      offset: offset,
    );
  }

  final BitReader _reader;
  final int _startBitPosition;

  int _range = 510;
  int _offset;
  bool _terminated = false;

  int get range => _range;
  int get offset => _offset;
  bool get isTerminated => _terminated;
  int get startBitPosition => _startBitPosition;
  int get bitPosition => _reader.bitPos;
  int get bitsConsumed => _reader.bitPos - _startBitPosition;

  /// Decodes one regular bin and updates [context] in place.
  int decodeBin(CabacContextModel context) {
    _requireActive();

    final stateIndex = context.probabilityStateIndex;
    final qCodIRangeIdx = (_range >> 6) & 3;
    final rangeLps = h264CabacRangeLps[stateIndex][qCodIRangeIdx];
    final rangeMps = _range - rangeLps;

    late final int bin;
    if (_offset >= rangeMps) {
      bin = context.mostProbableSymbol ^ 1;
      _offset -= rangeMps;
      _range = rangeLps;
      context.updateForLps();
    } else {
      bin = context.mostProbableSymbol;
      _range = rangeMps;
      context.updateForMps();
    }

    _renormalize();
    assert(_range >= 256 && _range <= 510);
    assert(_offset >= 0 && _offset < _range);
    return bin;
  }

  /// Decodes one equiprobable bypass bin without changing a context model.
  int decodeBypass() {
    _requireActive();
    _offset = (_offset << 1) | _reader.readBit();
    if (_offset >= _range) {
      _offset -= _range;
      assert(_offset >= 0 && _offset < _range);
      return 1;
    }
    assert(_offset >= 0 && _offset < _range);
    return 0;
  }

  /// Decodes one end-of-slice terminating bin.
  ///
  /// A returned one permanently terminates this arithmetic-decoder instance.
  int decodeTerminate() {
    _requireActive();
    _range -= 2;
    if (_offset >= _range) {
      _terminated = true;
      return 1;
    }
    _renormalize();
    assert(_range >= 256 && _range <= 510);
    assert(_offset >= 0 && _offset < _range);
    return 0;
  }

  void _renormalize() {
    while (_range < 256) {
      _range <<= 1;
      _offset = (_offset << 1) | _reader.readBit();
    }
  }

  void _requireActive() {
    if (_terminated) {
      throw StateError('Cannot decode CABAC bins after a terminating bin');
    }
  }
}
