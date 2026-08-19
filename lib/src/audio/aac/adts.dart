import 'dart:typed_data';

import 'audio_specific_config.dart';

/// Fixed and variable ADTS header fields for one AAC transport frame.
final class AdtsHeader {
  const AdtsHeader({
    required this.mpegVersion,
    required this.protectionAbsent,
    required this.audioObjectType,
    required this.samplingFrequencyIndex,
    required this.samplingFrequency,
    required this.channelConfiguration,
    required this.frameLength,
    required this.headerLength,
    required this.numberOfRawDataBlocks,
  });

  static AdtsHeader parse(Uint8List bytes, {int offset = 0}) {
    if (offset < 0 || offset > bytes.length) {
      throw RangeError.range(offset, 0, bytes.length, 'offset');
    }
    if (bytes.length - offset < 7) {
      throw const FormatException('Truncated ADTS header');
    }
    if (!_isSyncWord(bytes, offset)) {
      throw FormatException('ADTS sync word missing at offset $offset');
    }

    final b1 = bytes[offset + 1];
    final layer = (b1 >> 1) & 0x03;
    if (layer != 0) {
      throw FormatException('ADTS layer must be zero, got $layer');
    }

    final protectionAbsent = (b1 & 1) != 0;
    final frequencyIndex = (bytes[offset + 2] >> 2) & 0x0f;
    if (frequencyIndex >= aacSamplingFrequencies.length) {
      throw FormatException(
        'Reserved ADTS sampling_frequency_index=$frequencyIndex',
      );
    }

    final channelConfiguration =
        ((bytes[offset + 2] & 1) << 2) | (bytes[offset + 3] >> 6);
    final frameLength =
        ((bytes[offset + 3] & 0x03) << 11) |
        (bytes[offset + 4] << 3) |
        (bytes[offset + 5] >> 5);
    final numberOfRawDataBlocks = bytes[offset + 6] & 0x03;
    final headerLength = protectionAbsent ? 7 : 9 + 2 * numberOfRawDataBlocks;
    if (frameLength < headerLength) {
      throw FormatException(
        'ADTS frame length $frameLength is smaller than header $headerLength',
      );
    }
    if (bytes.length - offset < headerLength) {
      throw const FormatException('Truncated ADTS CRC header');
    }

    return AdtsHeader(
      mpegVersion: ((b1 >> 3) & 1) == 0 ? 4 : 2,
      protectionAbsent: protectionAbsent,
      audioObjectType: ((bytes[offset + 2] >> 6) & 0x03) + 1,
      samplingFrequencyIndex: frequencyIndex,
      samplingFrequency: aacSamplingFrequencies[frequencyIndex],
      channelConfiguration: channelConfiguration,
      frameLength: frameLength,
      headerLength: headerLength,
      numberOfRawDataBlocks: numberOfRawDataBlocks,
    );
  }

  final int mpegVersion;
  final bool protectionAbsent;
  final int audioObjectType;
  final int samplingFrequencyIndex;
  final int samplingFrequency;
  final int channelConfiguration;
  final int frameLength;
  final int headerLength;
  final int numberOfRawDataBlocks;

  int get payloadLength => frameLength - headerLength;
  int get sampleCount => 1024 * (numberOfRawDataBlocks + 1);

  AudioSpecificConfig toAudioSpecificConfig() {
    if (audioObjectType > 31) {
      throw UnsupportedError(
        'ADTS object type $audioObjectType cannot use the short ASC form',
      );
    }
    final encoded = Uint8List(2);
    encoded[0] = (audioObjectType << 3) | (samplingFrequencyIndex >> 1);
    encoded[1] =
        ((samplingFrequencyIndex & 1) << 7) | (channelConfiguration << 3);
    return AudioSpecificConfig.parse(encoded);
  }
}

/// One compressed AAC raw access unit and its transport-derived timing.
final class AacAccessUnit {
  AacAccessUnit({
    required Uint8List payload,
    required this.config,
    required this.pts90k,
    required this.sampleCount,
  }) : payload = Uint8List.fromList(payload);

  final Uint8List payload;
  final AudioSpecificConfig config;

  /// Unwrapped 90 kHz MPEG PTS, or null when the source supplied no anchor.
  final int? pts90k;
  final int sampleCount;
}

/// Strict parser for a complete byte string containing only ADTS frames.
abstract final class AdtsParser {
  static List<AacAccessUnit> parse(Uint8List bytes, {int? firstPts90k}) {
    final result = <AacAccessUnit>[];
    var offset = 0;
    int? nextPts = firstPts90k;
    var durationRemainder = 0;

    while (offset < bytes.length) {
      final header = AdtsHeader.parse(bytes, offset: offset);
      if (header.numberOfRawDataBlocks != 0) {
        throw UnsupportedError(
          'ADTS frames containing multiple raw_data_blocks are not supported',
        );
      }
      final frameEnd = offset + header.frameLength;
      if (frameEnd > bytes.length) {
        throw FormatException(
          'Truncated ADTS frame at $offset: need ${header.frameLength}, '
          'have ${bytes.length - offset}',
        );
      }
      final config = header.toAudioSpecificConfig();
      result.add(
        AacAccessUnit(
          payload: bytes.sublist(offset + header.headerLength, frameEnd),
          config: config,
          pts90k: nextPts,
          sampleCount: header.sampleCount,
        ),
      );

      if (nextPts != null) {
        final numerator =
            durationRemainder + header.sampleCount * _mpegClockRate;
        nextPts += numerator ~/ header.samplingFrequency;
        durationRemainder = numerator % header.samplingFrequency;
      }
      offset = frameEnd;
    }

    return List<AacAccessUnit>.unmodifiable(result);
  }
}

/// Incremental ADTS scanner for AAC payload split across PES or TS segments.
///
/// A timestamp passed to [push] is anchored at that chunk's first byte and is
/// assigned to the first ADTS frame that starts at or after the boundary. PTS
/// values are unwrapped across the MPEG 33-bit rollover. Between anchors, exact
/// rational 90 kHz durations are accumulated without long-term rounding drift.
final class AdtsStreamParser {
  Uint8List _buffer = Uint8List(0);
  int _bufferOffset = 0;
  final List<_PtsAnchor> _anchors = <_PtsAnchor>[];
  int? _nextPts;
  int _durationRemainder = 0;

  int get bufferedByteCount => _buffer.length;

  List<AacAccessUnit> push(Uint8List chunk, {int? pts90k}) {
    final appendOffset = _bufferOffset + _buffer.length;
    if (pts90k != null) _anchors.add(_PtsAnchor(appendOffset, pts90k));
    if (chunk.isNotEmpty) {
      final joined = Uint8List(_buffer.length + chunk.length);
      joined.setRange(0, _buffer.length, _buffer);
      joined.setRange(_buffer.length, joined.length, chunk);
      _buffer = joined;
    }

    final output = <AacAccessUnit>[];
    var cursor = 0;
    while (true) {
      final sync = _findSyncWord(_buffer, cursor);
      if (sync < 0) {
        // Retain a final 0xff because it may be half of a split sync word.
        cursor = _buffer.isNotEmpty && _buffer.last == 0xff
            ? _buffer.length - 1
            : _buffer.length;
        break;
      }
      cursor = sync;
      if (_buffer.length - cursor < 7) break;
      final protectionAbsent = (_buffer[cursor + 1] & 1) != 0;
      final rawBlockCount = _buffer[cursor + 6] & 0x03;
      final minimumHeaderLength = protectionAbsent ? 7 : 9 + 2 * rawBlockCount;
      if (_buffer.length - cursor < minimumHeaderLength) break;

      late final AdtsHeader header;
      try {
        header = AdtsHeader.parse(_buffer, offset: cursor);
      } on FormatException {
        cursor++;
        continue;
      }
      if (header.numberOfRawDataBlocks != 0) {
        throw UnsupportedError(
          'ADTS frames containing multiple raw_data_blocks are not supported',
        );
      }
      if (_buffer.length - cursor < header.frameLength) break;

      final absoluteFrameOffset = _bufferOffset + cursor;
      _applyAnchorsThrough(absoluteFrameOffset);
      final frameEnd = cursor + header.frameLength;
      output.add(
        AacAccessUnit(
          payload: _buffer.sublist(cursor + header.headerLength, frameEnd),
          config: header.toAudioSpecificConfig(),
          pts90k: _nextPts,
          sampleCount: header.sampleCount,
        ),
      );
      _advanceTimestamp(header.sampleCount, header.samplingFrequency);
      cursor = frameEnd;
    }

    if (cursor > 0) {
      _buffer = Uint8List.fromList(_buffer.sublist(cursor));
      _bufferOffset += cursor;
      // Anchors in discarded resynchronization bytes belong to the next frame.
      // Keep them until a frame start at or after their offset is observed.
    }
    return List<AacAccessUnit>.unmodifiable(output);
  }

  /// Throws when the stream ended in the middle of a header or frame.
  void finish() {
    if (_buffer.isNotEmpty) {
      throw FormatException(
        'Truncated ADTS stream (${_buffer.length} buffered bytes)',
      );
    }
  }

  void reset() {
    _buffer = Uint8List(0);
    _bufferOffset = 0;
    _anchors.clear();
    _nextPts = null;
    _durationRemainder = 0;
  }

  void _applyAnchorsThrough(int frameOffset) {
    int? newest;
    var consumed = 0;
    while (consumed < _anchors.length &&
        _anchors[consumed].offset <= frameOffset) {
      newest = _anchors[consumed].pts90k;
      consumed++;
    }
    if (consumed == 0) return;
    _anchors.removeRange(0, consumed);
    _nextPts = _unwrapPts(newest!, _nextPts);
    _durationRemainder = 0;
  }

  void _advanceTimestamp(int samples, int sampleRate) {
    if (_nextPts == null) return;
    final numerator = _durationRemainder + samples * _mpegClockRate;
    _nextPts = _nextPts! + numerator ~/ sampleRate;
    _durationRemainder = numerator % sampleRate;
  }
}

final class _PtsAnchor {
  const _PtsAnchor(this.offset, this.pts90k);

  final int offset;
  final int pts90k;
}

const int _mpegClockRate = 90000;
const int _ptsModulus = 1 << 33;
const int _ptsMask = _ptsModulus - 1;
const int _ptsHalfRange = _ptsModulus >> 1;

int _unwrapPts(int value, int? reference) {
  final raw = value & _ptsMask;
  if (reference == null) return raw;
  final referenceRaw = reference & _ptsMask;
  var delta = raw - referenceRaw;
  if (delta > _ptsHalfRange) {
    delta -= _ptsModulus;
  } else if (delta < -_ptsHalfRange) {
    delta += _ptsModulus;
  }
  return reference + delta;
}

bool _isSyncWord(Uint8List bytes, int offset) {
  return offset >= 0 &&
      offset + 1 < bytes.length &&
      bytes[offset] == 0xff &&
      (bytes[offset + 1] & 0xf6) == 0xf0;
}

int _findSyncWord(Uint8List bytes, int start) {
  for (var i = start; i + 1 < bytes.length; i++) {
    if (_isSyncWord(bytes, i)) return i;
  }
  return -1;
}
