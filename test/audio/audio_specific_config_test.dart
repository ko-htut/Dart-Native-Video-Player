import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/audio_specific_config.dart';

void main() {
  group('AudioSpecificConfig', () {
    test('parses AAC-LC 44.1 kHz stereo', () {
      final config = AudioSpecificConfig.parse(
        Uint8List.fromList(<int>[0x12, 0x10]),
      );

      expect(config.audioObjectType, 2);
      expect(config.samplingFrequencyIndex, 4);
      expect(config.samplingFrequency, 44100);
      expect(config.channelConfiguration, 2);
      expect(config.frameLengthFlag, isFalse);
      expect(config.samplesPerFrame, 1024);
      expect(config.isAacLc, isTrue);
    });

    test('reads the 960-sample GA frame-length flag', () {
      final config = AudioSpecificConfig.parse(
        Uint8List.fromList(<int>[0x12, 0x14]),
      );

      expect(config.frameLengthFlag, isTrue);
      expect(config.samplesPerFrame, 960);
    });

    test('parses an explicit sampling frequency', () {
      final config = AudioSpecificConfig.parse(
        _packBits(<int>[
          ..._bits(2, 5),
          ..._bits(15, 4),
          ..._bits(12345, 24),
          ..._bits(1, 4),
          0,
          0,
          0,
        ]),
      );

      expect(config.samplingFrequencyIndex, 15);
      expect(config.samplingFrequency, 12345);
      expect(config.channelConfiguration, 1);
    });

    test('unwraps an SBR config while retaining extension metadata', () {
      final config = AudioSpecificConfig.parse(
        _packBits(<int>[
          ..._bits(5, 5), // SBR wrapper
          ..._bits(7, 4), // 22.05 kHz core rate
          ..._bits(2, 4),
          ..._bits(4, 4), // 44.1 kHz extension rate
          ..._bits(2, 5), // AAC-LC core
          0,
          0,
          0,
        ]),
      );

      expect(config.audioObjectType, 2);
      expect(config.samplingFrequency, 22050);
      expect(config.extensionAudioObjectType, 5);
      expect(config.extensionSamplingFrequency, 44100);
    });

    test('rejects truncated and reserved configurations', () {
      expect(
        () => AudioSpecificConfig.parse(Uint8List.fromList(<int>[0x12])),
        throwsFormatException,
      );
      expect(
        () => AudioSpecificConfig.parse(
          _packBits(<int>[
            ..._bits(2, 5),
            ..._bits(13, 4),
            ..._bits(2, 4),
            0,
            0,
            0,
          ]),
        ),
        throwsFormatException,
      );
    });
  });
}

List<int> _bits(int value, int count) => List<int>.generate(
  count,
  (index) => (value >> (count - index - 1)) & 1,
  growable: false,
);

Uint8List _packBits(List<int> bits) {
  final bytes = Uint8List((bits.length + 7) ~/ 8);
  for (var i = 0; i < bits.length; i++) {
    bytes[i >> 3] |= bits[i] << (7 - (i & 7));
  }
  return bytes;
}
