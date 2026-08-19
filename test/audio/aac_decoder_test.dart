import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';
import 'package:ndvy_player/src/audio/aac/audio_specific_config.dart';
import 'package:ndvy_player/src/audio/aac/bit_reader.dart';
import 'package:ndvy_player/src/audio/aac/decoder.dart';
import 'package:ndvy_player/src/audio/aac/filterbank.dart';
import 'package:ndvy_player/src/audio/aac/huffman_tables.dart';
import 'package:ndvy_player/src/audio/aac/syntax.dart';
import 'package:ndvy_player/src/audio/pcm_timeline.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

void main() {
  group('AAC noiseless primitives', () {
    test('bit reader is MSB-first and bounds checked', () {
      final reader = AacBitReader(Uint8List.fromList(<int>[0xa6, 0x40]));
      expect(reader.readBits(3), 5);
      expect(reader.readBits(5), 6);
      expect(reader.readBits(2), 1);
      expect(reader.bitsRemaining, 6);
      expect(() => reader.readBits(7), throwsA(isA<FormatException>()));
    });

    test('contains complete scale-factor and spectral codebooks', () {
      expect(aacScaleFactorHuffman.entryCount, 121);
      const counts = <int, int>{
        1: 81,
        2: 81,
        3: 81,
        4: 81,
        5: 81,
        6: 81,
        7: 64,
        8: 64,
        9: 169,
        10: 169,
        11: 289,
      };
      for (final entry in counts.entries) {
        expect(
          aacSpectralHuffman[entry.key]!.entryCount,
          entry.value,
          reason: 'spectral codebook ${entry.key}',
        );
      }
    });
  });

  group('AAC synthesis filterbank', () {
    test('FFT IMDCT matches the defining equation for one coefficient', () {
      final spectrum = Float64List(1024)..[0] = 1.0;
      final info = AacIcsInfo(
        windowSequence: AacWindowSequence.onlyLong,
        windowShape: AacWindowShape.sine,
        maxSfb: 0,
        windowGroupLength: const <int>[1],
      );
      final actual = AacFilterbank().synthesize(spectrum, info);

      for (var n = 0; n < 1024; n += 17) {
        final imdct = math.cos((2 * math.pi / 2048) * (n + 512.5) * 0.5) / 1024;
        final window = math.sin(math.pi * (n + 0.5) / 2048);
        expect(actual[n], closeTo(imdct * window, 2e-12));
      }
    });
  });

  group('AacLcDecoder', () {
    test('matches the bundled whole-sequence AAC-LC PCM golden', () {
      final bytes = File('assets/baby_aac.mp4').readAsBytesSync();
      final track = Mp4Demux.parseAacTrack(bytes)!;
      final decoder = AacLcDecoder(track.config);
      final pcmBytes = BytesBuilder(copy: false);
      final left = <double>[];
      final right = <double>[];
      for (var index = 0; index < track.sampleSizes.length; index++) {
        final frame = decoder.decodeRawAccessUnit(
          Mp4Demux.readAudioSample(bytes, track, index),
          pts90k: track.pts[index] * 90000 ~/ track.timescale,
        );
        final rendered = ByteData(frame.samples.length * 2);
        for (var i = 0; i < frame.samples.length; i++) {
          final sample = frame.samples[i];
          rendered.setInt16(i * 2, floatSampleToPcm16(sample), Endian.little);
        }
        pcmBytes.add(rendered.buffer.asUint8List());
        if (index > 1 && index < 12) {
          for (var sample = 0; sample < frame.samplesPerChannel; sample++) {
            left.add(frame.samples[sample * 2]);
            right.add(frame.samples[sample * 2 + 1]);
          }
        }
      }

      final rendered = pcmBytes.takeBytes();
      expect(rendered, hasLength(1134592));
      final actual = ByteData.sublistView(rendered);
      const primingSamples = 1024 * 2;
      const alignedSampleCount = 565248;
      expect(rendered.length ~/ 2 - primingSamples, alignedSampleCount);

      // Independently rendered with FFmpeg and sampled across the complete
      // sequence. A tolerance is intentional: libm/window rounding can vary
      // slightly between x64 and ARM AOT builds.
      final goldenBytes = base64Decode(
        File(
          'test/audio/goldens/baby_aac_s16_stride251.base64',
        ).readAsStringSync().trim(),
      );
      final golden = ByteData.sublistView(goldenBytes);
      expect(goldenBytes, hasLength(2252 * 2));
      var goldenIndex = 0;
      var maximumDelta = 0;
      var pcmPeak = 0;
      var pcmSumSquares = 0.0;
      for (var sample = 0; sample < alignedSampleCount; sample++) {
        final value = actual.getInt16(
          (sample + primingSamples) * 2,
          Endian.little,
        );
        pcmPeak = math.max(pcmPeak, value.abs());
        pcmSumSquares += value * value;
        if (sample % 251 == 0) {
          final expected = golden.getInt16(goldenIndex * 2, Endian.little);
          maximumDelta = math.max(maximumDelta, (value - expected).abs());
          goldenIndex++;
        }
      }
      expect(goldenIndex, 2252);
      expect(maximumDelta, lessThanOrEqualTo(24));
      expect(pcmPeak, closeTo(4240, 24));
      expect(
        math.sqrt(pcmSumSquares / alignedSampleCount),
        closeTo(2311.9061663, 1.0),
      );
      expect(
        _tonePower(left, 440, 48000),
        greaterThan(10 * _tonePower(left, 660, 48000)),
      );
      expect(
        _tonePower(right, 660, 48000),
        greaterThan(10 * _tonePower(right, 440, 48000)),
      );
    });

    test('decodes a silent mono SCE to one normalized PCM frame', () {
      final config = AudioSpecificConfig.parse(
        Uint8List.fromList(<int>[0x12, 0x08]),
      );
      final payload = _silentMonoAccessUnit();
      final decoder = AacLcDecoder(config);
      final frame = decoder.decodeRawAccessUnit(payload, pts90k: 90000);

      expect(frame.sampleRate, 44100);
      expect(frame.channels, 1);
      expect(frame.samplesPerChannel, 1024);
      expect(frame.samples, hasLength(1024));
      expect(frame.samples.every((sample) => sample == 0), isTrue);
      expect(frame.pts90k, 90000);
      expect(frame.duration, const Duration(microseconds: 23219));
    });

    test('decodes a silent common-window CPE to interleaved stereo', () {
      final config = AudioSpecificConfig.parse(
        Uint8List.fromList(<int>[0x12, 0x10]),
      );
      final payload = _silentStereoAccessUnit();
      final decoder = AacLcDecoder(config);
      final frame = decoder.decode(
        AacAccessUnit(
          payload: payload,
          config: config,
          pts90k: 1234,
          sampleCount: 1024,
        ),
      );

      expect(frame.channels, 2);
      expect(frame.samples, hasLength(2048));
      expect(frame.samples.every((sample) => sample == 0), isTrue);
      expect(frame.pts90k, 1234);
    });

    test('rejects unsupported object types and 960-sample frames', () {
      expect(
        () => AacLcDecoder(
          AudioSpecificConfig(
            bytes: Uint8List.fromList(<int>[0]),
            audioObjectType: 3,
            samplingFrequency: 44100,
            samplingFrequencyIndex: 4,
            channelConfiguration: 1,
            frameLengthFlag: false,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AacLcDecoder(
          AudioSpecificConfig(
            bytes: Uint8List.fromList(<int>[0]),
            audioObjectType: 2,
            samplingFrequency: 44100,
            samplingFrequencyIndex: 4,
            channelConfiguration: 1,
            frameLengthFlag: true,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects access units without END and multiple raw blocks', () {
      final config = AudioSpecificConfig.parse(
        Uint8List.fromList(<int>[0x12, 0x08]),
      );
      final decoder = AacLcDecoder(config);
      expect(
        () => decoder.decodeRawAccessUnit(Uint8List.fromList(<int>[0])),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decoder.decode(
          AacAccessUnit(
            payload: _silentMonoAccessUnit(),
            config: config,
            pts90k: null,
            sampleCount: 2048,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

double _tonePower(List<double> samples, double frequency, int sampleRate) {
  var real = 0.0;
  var imaginary = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final phase = 2 * math.pi * frequency * i / sampleRate;
    real += samples[i] * math.cos(phase);
    imaginary -= samples[i] * math.sin(phase);
  }
  return real * real + imaginary * imaginary;
}

Uint8List _silentMonoAccessUnit() {
  final bits = _TestBitWriter()
    ..write(0, 3) // SCE
    ..write(0, 4) // element_instance_tag
    ..write(0, 8) // global_gain
    ..write(0, 1) // ics_reserved_bit
    ..write(0, 2) // ONLY_LONG_SEQUENCE
    ..write(0, 1) // sine
    ..write(0, 6) // max_sfb
    ..write(0, 1) // predictor_data_present
    ..write(0, 1) // pulse_data_present
    ..write(0, 1) // tns_data_present
    ..write(0, 1) // gain_control_data_present
    ..write(7, 3); // END
  return bits.finish();
}

Uint8List _silentStereoAccessUnit() {
  final bits = _TestBitWriter()
    ..write(1, 3) // CPE
    ..write(0, 4) // element_instance_tag
    ..write(1, 1) // common_window
    ..write(0, 1) // ics_reserved_bit
    ..write(0, 2) // ONLY_LONG_SEQUENCE
    ..write(0, 1) // sine
    ..write(0, 6) // max_sfb
    ..write(0, 1) // predictor_data_present
    ..write(0, 2) // ms_mask_present
    ..write(0, 8) // left global_gain
    ..write(0, 3) // left optional tools
    ..write(0, 8) // right global_gain
    ..write(0, 3) // right optional tools
    ..write(7, 3); // END
  return bits.finish();
}

final class _TestBitWriter {
  final List<int> _bits = <int>[];

  void write(int value, int count) {
    for (var shift = count - 1; shift >= 0; shift--) {
      _bits.add((value >> shift) & 1);
    }
  }

  Uint8List finish() {
    final result = Uint8List((_bits.length + 7) ~/ 8);
    for (var i = 0; i < _bits.length; i++) {
      result[i >> 3] |= _bits[i] << (7 - (i & 7));
    }
    return result;
  }
}
