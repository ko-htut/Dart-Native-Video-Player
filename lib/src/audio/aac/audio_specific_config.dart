import 'dart:typed_data';

/// MPEG-4 AudioSpecificConfig as carried by MP4 `esds` metadata.
///
/// The parser intentionally exposes only the fields needed to configure the
/// pure-Dart AAC decoder. Unsupported object types remain parseable so callers
/// can reject them with a useful error instead of guessing a configuration.
final class AudioSpecificConfig {
  AudioSpecificConfig({
    required Uint8List bytes,
    required this.audioObjectType,
    required this.samplingFrequency,
    required this.samplingFrequencyIndex,
    required this.channelConfiguration,
    required this.frameLengthFlag,
    this.extensionAudioObjectType,
    this.extensionSamplingFrequency,
  }) : bytes = Uint8List.fromList(bytes) {
    if (audioObjectType <= 0) {
      throw ArgumentError.value(audioObjectType, 'audioObjectType');
    }
    if (samplingFrequency <= 0) {
      throw ArgumentError.value(samplingFrequency, 'samplingFrequency');
    }
    if (channelConfiguration < 0 || channelConfiguration > 15) {
      throw ArgumentError.value(channelConfiguration, 'channelConfiguration');
    }
  }

  factory AudioSpecificConfig.parse(Uint8List bytes) {
    if (bytes.length < 2) {
      throw const FormatException(
        'AudioSpecificConfig requires at least two bytes',
      );
    }

    final reader = _AudioBitReader(bytes);
    var objectType = _readAudioObjectType(reader);
    var frequency = _readSamplingFrequency(reader);
    var frequencyIndex = frequency.index;
    final channelConfiguration = reader.readBits(4);

    int? extensionObjectType;
    int? extensionFrequency;
    if (objectType == 5 || objectType == 29) {
      extensionObjectType = objectType;
      final extension = _readSamplingFrequency(reader);
      extensionFrequency = extension.hz;
      objectType = _readAudioObjectType(reader);
      if (objectType == 22) {
        // extensionChannelConfiguration. The decoder currently rejects ER
        // BSAC, but consuming it keeps parsing aligned and diagnostics exact.
        reader.readBits(4);
      }
    }

    var frameLengthFlag = false;
    if (_usesGaSpecificConfig(objectType)) {
      frameLengthFlag = reader.readBit() != 0;
      final dependsOnCoreCoder = reader.readBit() != 0;
      if (dependsOnCoreCoder) reader.readBits(14);
      reader.readBit(); // extensionFlag
    }

    return AudioSpecificConfig(
      bytes: bytes,
      audioObjectType: objectType,
      samplingFrequency: frequency.hz,
      samplingFrequencyIndex: frequencyIndex,
      channelConfiguration: channelConfiguration,
      frameLengthFlag: frameLengthFlag,
      extensionAudioObjectType: extensionObjectType,
      extensionSamplingFrequency: extensionFrequency,
    );
  }

  /// Original decoder configuration bytes, defensively copied at creation.
  final Uint8List bytes;

  /// Effective core MPEG-4 audio object type (AAC-LC is 2).
  final int audioObjectType;
  final int samplingFrequency;

  /// Standard table index, or 15 when an explicit frequency was signalled.
  final int samplingFrequencyIndex;
  final int channelConfiguration;
  final bool frameLengthFlag;

  /// Outer SBR/PS object type and rate when object type 5 or 29 wraps the core.
  final int? extensionAudioObjectType;
  final int? extensionSamplingFrequency;

  int get samplesPerFrame => frameLengthFlag ? 960 : 1024;
  bool get isAacLc => audioObjectType == 2;

  /// Channel count for the standard configurations understood by AAC-LC.
  /// Null means that a Program Config Element or an uncommon layout must be
  /// inspected by the decoder.
  int? get channelCount => switch (channelConfiguration) {
    1 => 1,
    2 => 2,
    3 => 3,
    4 => 4,
    5 => 5,
    6 => 6,
    7 => 8,
    _ => null,
  };
}

const List<int> aacSamplingFrequencies = <int>[
  96000,
  88200,
  64000,
  48000,
  44100,
  32000,
  24000,
  22050,
  16000,
  12000,
  11025,
  8000,
  7350,
];

({int hz, int index}) _readSamplingFrequency(_AudioBitReader reader) {
  final index = reader.readBits(4);
  if (index == 15) {
    final explicit = reader.readBits(24);
    if (explicit == 0) {
      throw const FormatException('AAC explicit sampling frequency is zero');
    }
    return (hz: explicit, index: index);
  }
  if (index >= aacSamplingFrequencies.length) {
    throw FormatException('Reserved AAC samplingFrequencyIndex=$index');
  }
  return (hz: aacSamplingFrequencies[index], index: index);
}

int _readAudioObjectType(_AudioBitReader reader) {
  var value = reader.readBits(5);
  if (value == 31) value = 32 + reader.readBits(6);
  if (value == 0) {
    throw const FormatException('AAC audioObjectType 0 is reserved');
  }
  return value;
}

bool _usesGaSpecificConfig(int objectType) {
  return switch (objectType) {
    1 || 2 || 3 || 4 || 6 || 7 || 17 || 19 || 20 || 21 || 22 || 23 => true,
    _ => false,
  };
}

final class _AudioBitReader {
  _AudioBitReader(this.bytes);

  final Uint8List bytes;
  int _bitOffset = 0;

  int readBit() => readBits(1);

  int readBits(int count) {
    if (count < 0 || count > 31) {
      throw RangeError.range(count, 0, 31, 'count');
    }
    if (_bitOffset + count > bytes.length * 8) {
      throw const FormatException('Truncated AudioSpecificConfig');
    }

    var value = 0;
    for (var i = 0; i < count; i++) {
      final byte = bytes[_bitOffset >> 3];
      value = (value << 1) | ((byte >> (7 - (_bitOffset & 7))) & 1);
      _bitOffset++;
    }
    return value;
  }
}
