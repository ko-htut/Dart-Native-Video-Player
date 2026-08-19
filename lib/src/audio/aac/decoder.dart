import 'dart:typed_data';

import 'adts.dart';
import 'audio_specific_config.dart';
import 'bit_reader.dart';
import 'filterbank.dart';
import 'syntax.dart';
import 'tools.dart';

/// One decoded AAC frame in normalized, interleaved float PCM form.
final class PcmAudioFrame {
  PcmAudioFrame({
    required Float32List samples,
    required this.sampleRate,
    required this.channels,
    required this.samplesPerChannel,
    required this.pts90k,
  }) : samples = Float32List.fromList(samples) {
    if (channels <= 0 || samples.length != channels * samplesPerChannel) {
      throw ArgumentError('PCM buffer geometry does not match its metadata');
    }
  }

  /// Interleaved samples in `[-1.0, 1.0]` (L, R, L, R for stereo).
  final Float32List samples;
  final int sampleRate;
  final int channels;
  final int samplesPerChannel;
  final int? pts90k;

  Duration get duration => Duration(
    microseconds:
        (samplesPerChannel * Duration.microsecondsPerSecond) ~/ sampleRate,
  );
}

/// Stateful pure-Dart decoder for the AAC-LC 1024-sample GA profile.
///
/// Compressed-data parsing, noiseless decoding, stereo tools, TNS and the
/// IMDCT/filterbank are all Dart. The resulting [PcmAudioFrame] can be queued
/// to a platform PCM sink; no platform audio codec is involved.
final class AacLcDecoder {
  AacLcDecoder(this.config) {
    _validateConfig(config);
    _filterbanks = List<AacFilterbank>.generate(
      config.channelConfiguration,
      (_) => AacFilterbank(),
      growable: false,
    );
  }

  final AudioSpecificConfig config;
  late List<AacFilterbank> _filterbanks;
  final AacNoiseGenerator _noise = AacNoiseGenerator();

  PcmAudioFrame decode(AacAccessUnit accessUnit) {
    _validateCompatibleConfig(accessUnit.config);
    if (accessUnit.sampleCount != 1024) {
      throw AacDecoderException(
        'Exactly one 1024-sample raw_data_block is required; '
        'access unit advertises ${accessUnit.sampleCount} samples',
      );
    }
    return decodeRawAccessUnit(accessUnit.payload, pts90k: accessUnit.pts90k);
  }

  PcmAudioFrame decodeRawAccessUnit(Uint8List payload, {int? pts90k}) {
    if (payload.isEmpty) {
      throw const AacDecoderException('AAC access unit is empty');
    }
    final reader = AacBitReader(payload);
    final elements = <_DecodedElement>[];
    var foundEnd = false;
    while (!foundEnd) {
      if (reader.bitsRemaining < 3) {
        throw AacDecoderException(
          'AAC raw_data_block has no END element',
          bitOffset: reader.bitOffset,
        );
      }
      final id = reader.readBits(3);
      switch (id) {
        case 0: // SCE
          reader.readBits(4); // element_instance_tag
          final data = AacChannelParser(
            config.samplingFrequencyIndex,
          ).parse(reader);
          _rejectIllegalIntensity(data, leftChannel: true);
          elements.add(
            _SingleElement(
              data,
              data.reconstructSpectrum(
                samplingFrequencyIndex: config.samplingFrequencyIndex,
              ),
            ),
          );
        case 1: // CPE
          elements.add(_parsePair(reader));
        case 2:
          throw AacDecoderException(
            'Coupling channel elements (CCE) are not supported',
            bitOffset: reader.bitOffset - 3,
          );
        case 3:
          throw AacDecoderException(
            'LFE elements are outside the mono/stereo AAC-LC profile',
            bitOffset: reader.bitOffset - 3,
          );
        case 4:
          _skipDataStreamElement(reader);
        case 5:
          throw AacDecoderException(
            'Program config elements are not supported; use channel_config 1/2',
            bitOffset: reader.bitOffset - 3,
          );
        case 6:
          _skipFillElement(reader);
        case 7:
          reader.alignToByte();
          foundEnd = true;
      }
    }

    final spectralChannels = <_SpectralChannel>[];
    for (final element in elements) {
      switch (element) {
        case _SingleElement(:final data, :final spectrum):
          AacSpectralTools.applyNoiseSingle(
            spectrum: spectrum,
            data: data,
            samplingFrequencyIndex: config.samplingFrequencyIndex,
            generator: _noise,
          );
          spectralChannels.add(_SpectralChannel(data, spectrum));
        case _PairElement(
          :final leftData,
          :final rightData,
          :final left,
          :final right,
          :final commonWindow,
          :final maskMode,
          :final msUsed,
        ):
          if (commonWindow) {
            AacSpectralTools.applyMidSide(
              left: left,
              right: right,
              leftData: leftData,
              rightData: rightData,
              samplingFrequencyIndex: config.samplingFrequencyIndex,
              maskMode: maskMode,
              msUsed: msUsed,
            );
            AacSpectralTools.applyIntensity(
              left: left,
              right: right,
              leftData: leftData,
              rightData: rightData,
              samplingFrequencyIndex: config.samplingFrequencyIndex,
              maskMode: maskMode,
              msUsed: msUsed,
            );
            AacSpectralTools.applyNoisePair(
              left: left,
              right: right,
              leftData: leftData,
              rightData: rightData,
              samplingFrequencyIndex: config.samplingFrequencyIndex,
              maskMode: maskMode,
              msUsed: msUsed,
              generator: _noise,
            );
          } else {
            AacSpectralTools.applyNoiseSingle(
              spectrum: left,
              data: leftData,
              samplingFrequencyIndex: config.samplingFrequencyIndex,
              generator: _noise,
            );
            AacSpectralTools.applyNoiseSingle(
              spectrum: right,
              data: rightData,
              samplingFrequencyIndex: config.samplingFrequencyIndex,
              generator: _noise,
            );
          }
          spectralChannels
            ..add(_SpectralChannel(leftData, left))
            ..add(_SpectralChannel(rightData, right));
      }
    }

    if (spectralChannels.length != config.channelConfiguration) {
      throw AacDecoderException(
        'AAC payload contains ${spectralChannels.length} channels but '
        'AudioSpecificConfig declares ${config.channelConfiguration}',
      );
    }

    final pcmChannels = <Float64List>[];
    for (var channel = 0; channel < spectralChannels.length; channel++) {
      final decoded = spectralChannels[channel];
      AacSpectralTools.applyTns(
        spectrum: decoded.spectrum,
        data: decoded.data,
        samplingFrequencyIndex: config.samplingFrequencyIndex,
      );
      pcmChannels.add(
        _filterbanks[channel].synthesize(decoded.spectrum, decoded.data.info),
      );
    }

    final interleaved = Float32List(1024 * pcmChannels.length);
    for (var sample = 0; sample < 1024; sample++) {
      for (var channel = 0; channel < pcmChannels.length; channel++) {
        final value = pcmChannels[channel][sample];
        interleaved[sample * pcmChannels.length + channel] = value.isFinite
            ? (value / 32768.0).clamp(-1.0, 1.0).toDouble()
            : 0.0;
      }
    }
    return PcmAudioFrame(
      samples: interleaved,
      sampleRate: config.samplingFrequency,
      channels: pcmChannels.length,
      samplesPerChannel: 1024,
      pts90k: pts90k,
    );
  }

  void reset() {
    for (final filterbank in _filterbanks) {
      filterbank.reset();
    }
    _noise.reset();
  }

  _PairElement _parsePair(AacBitReader reader) {
    reader.readBits(4); // element_instance_tag
    final commonWindow = reader.readBool();
    AacIcsInfo? sharedInfo;
    var maskMode = 0;
    var msUsed = <List<bool>>[];
    if (commonWindow) {
      sharedInfo = AacIcsInfo.parse(reader, config.samplingFrequencyIndex);
      maskMode = reader.readBits(2);
      if (maskMode == 3) {
        throw AacDecoderException(
          'Reserved ms_mask_present value',
          bitOffset: reader.bitOffset - 2,
        );
      }
      if (maskMode == 1) {
        msUsed = List<List<bool>>.generate(
          sharedInfo.numberOfWindowGroups,
          (_) => List<bool>.generate(
            sharedInfo!.maxSfb,
            (_) => reader.readBool(),
            growable: false,
          ),
          growable: false,
        );
      }
    }

    final parser = AacChannelParser(config.samplingFrequencyIndex);
    final leftData = parser.parse(reader, commonInfo: sharedInfo);
    final rightData = parser.parse(reader, commonInfo: sharedInfo);
    _rejectIllegalIntensity(leftData, leftChannel: true);
    if (!commonWindow) {
      _rejectIllegalIntensity(rightData, leftChannel: false);
    }
    return _PairElement(
      leftData: leftData,
      rightData: rightData,
      left: leftData.reconstructSpectrum(
        samplingFrequencyIndex: config.samplingFrequencyIndex,
      ),
      right: rightData.reconstructSpectrum(
        samplingFrequencyIndex: config.samplingFrequencyIndex,
      ),
      commonWindow: commonWindow,
      maskMode: maskMode,
      msUsed: msUsed,
    );
  }

  static void _rejectIllegalIntensity(
    AacChannelData data, {
    required bool leftChannel,
  }) {
    for (final row in data.codebooks) {
      if (row.any(
        (codebook) => codebook == intensityHcb || codebook == intensityHcb2,
      )) {
        throw AacDecoderException(
          leftChannel
              ? 'Intensity codebooks are illegal in a first/mono channel'
              : 'Intensity stereo requires a common_window CPE',
        );
      }
    }
  }

  void _skipFillElement(AacBitReader reader) {
    var bytes = reader.readBits(4);
    if (bytes == 15) bytes += reader.readBits(8) - 1;
    if (bytes == 0) return;
    final extensionType = reader.readBits(4);
    if (extensionType == 13 || extensionType == 14) {
      throw AacDecoderException(
        'SBR/HE-AAC fill extensions are not supported',
        bitOffset: reader.bitOffset - 4,
      );
    }
    reader.skipBits(bytes * 8 - 4);
  }

  static void _skipDataStreamElement(AacBitReader reader) {
    reader.readBits(4); // element_instance_tag
    final align = reader.readBool();
    var bytes = reader.readBits(8);
    if (bytes == 255) bytes += reader.readBits(8);
    if (align) reader.alignToByte();
    reader.skipBits(bytes * 8);
  }

  void _validateCompatibleConfig(AudioSpecificConfig other) {
    if (other.audioObjectType != config.audioObjectType ||
        other.samplingFrequency != config.samplingFrequency ||
        other.samplingFrequencyIndex != config.samplingFrequencyIndex ||
        other.channelConfiguration != config.channelConfiguration ||
        other.frameLengthFlag != config.frameLengthFlag ||
        other.extensionAudioObjectType != config.extensionAudioObjectType ||
        other.extensionSamplingFrequency != config.extensionSamplingFrequency) {
      throw const AacDecoderException(
        'AAC access-unit configuration changed; create a new decoder',
      );
    }
  }

  static void _validateConfig(AudioSpecificConfig config) {
    if (!config.isAacLc) {
      throw AacDecoderException(
        'Only AAC-LC (audioObjectType 2) is supported; got '
        '${config.audioObjectType}',
      );
    }
    if (config.extensionAudioObjectType != null ||
        config.extensionSamplingFrequency != null) {
      throw const AacDecoderException('SBR/PS (HE-AAC) is not supported');
    }
    if (config.frameLengthFlag || config.samplesPerFrame != 1024) {
      throw const AacDecoderException(
        'The AAC 960-sample frameLengthFlag profile is not supported',
      );
    }
    if (config.samplingFrequencyIndex < 0 ||
        config.samplingFrequencyIndex > 11) {
      throw const AacDecoderException(
        'AAC-LC requires a standard sampling-frequency index in 0..11',
      );
    }
    if (config.channelConfiguration != 1 && config.channelConfiguration != 2) {
      throw AacDecoderException(
        'Only mono/stereo channel configurations 1 and 2 are supported; '
        'got ${config.channelConfiguration}',
      );
    }
  }
}

sealed class _DecodedElement {
  const _DecodedElement();
}

final class _SingleElement extends _DecodedElement {
  const _SingleElement(this.data, this.spectrum);
  final AacChannelData data;
  final Float64List spectrum;
}

final class _PairElement extends _DecodedElement {
  const _PairElement({
    required this.leftData,
    required this.rightData,
    required this.left,
    required this.right,
    required this.commonWindow,
    required this.maskMode,
    required this.msUsed,
  });

  final AacChannelData leftData;
  final AacChannelData rightData;
  final Float64List left;
  final Float64List right;
  final bool commonWindow;
  final int maskMode;
  final List<List<bool>> msUsed;
}

final class _SpectralChannel {
  const _SpectralChannel(this.data, this.spectrum);
  final AacChannelData data;
  final Float64List spectrum;
}
