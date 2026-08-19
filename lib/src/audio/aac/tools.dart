import 'dart:math' as math;
import 'dart:typed_data';

import 'bit_reader.dart';
import 'syntax.dart';

/// Deterministic generator used for AAC perceptual-noise substitution.
///
/// AAC specifies the energy and correlation of a PNS band, but deliberately
/// does not prescribe one bit-exact random-number generator. Keeping the state
/// here makes output repeatable and lets [reset] restore stream-start state.
final class AacNoiseGenerator {
  AacNoiseGenerator({int seed = 0x1f2e3d4c})
    : _initialSeed = seed & 0xffffffff,
      _state = seed & 0xffffffff;

  final int _initialSeed;
  int _state;

  void reset() => _state = _initialSeed;

  Float64List vector(int length) {
    final result = Float64List(length);
    for (var i = 0; i < length; i++) {
      _state = (_state * 1664525 + 1013904223) & 0xffffffff;
      final signed = _state >= 0x80000000 ? _state - 0x100000000 : _state;
      result[i] = signed / 2147483648.0;
    }
    return result;
  }
}

/// Applies the channel-pair and per-channel spectral tools used by AAC-LC.
abstract final class AacSpectralTools {
  /// M/S de-matrix. [maskMode] is the two-bit `ms_mask_present` value.
  static void applyMidSide({
    required Float64List left,
    required Float64List right,
    required AacChannelData leftData,
    required AacChannelData rightData,
    required int samplingFrequencyIndex,
    required int maskMode,
    required List<List<bool>> msUsed,
  }) {
    if (maskMode == 0) return;
    if (maskMode < 0 || maskMode > 2) {
      throw const AacDecoderException('Reserved ms_mask_present value');
    }
    final info = _validatePair(left, right, leftData, rightData);
    final offsets = _bandOffsets(info, samplingFrequencyIndex);
    _validateMsMask(info, maskMode, msUsed);

    var firstWindow = 0;
    for (var group = 0; group < info.numberOfWindowGroups; group++) {
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        final leftCb = leftData.codebooks[group][sfb];
        final rightCb = rightData.codebooks[group][sfb];
        final enabled = maskMode == 2 || msUsed[group][sfb];
        if (!enabled ||
            _isIntensity(rightCb) ||
            leftCb == noiseHcb ||
            rightCb == noiseHcb) {
          continue;
        }
        _forEachBandSample(info, offsets, group, sfb, firstWindow, (index) {
          final mid = left[index];
          final side = right[index];
          left[index] = mid + side;
          right[index] = mid - side;
        });
      }
      firstWindow += info.windowGroupLength[group];
    }
  }

  /// Fills PNS bands of a single-channel element.
  static void applyNoiseSingle({
    required Float64List spectrum,
    required AacChannelData data,
    required int samplingFrequencyIndex,
    required AacNoiseGenerator generator,
  }) {
    final info = data.info;
    _validateSpectrum(spectrum, info);
    final offsets = _bandOffsets(info, samplingFrequencyIndex);
    var firstWindow = 0;
    for (var group = 0; group < info.numberOfWindowGroups; group++) {
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        if (data.codebooks[group][sfb] != noiseHcb) continue;
        final energy = data.noiseEnergies[group][sfb];
        if (energy == null) {
          throw const AacDecoderException('PNS band has no noise energy');
        }
        final start = offsets[sfb];
        final end = offsets[sfb + 1];
        for (var window = 0; window < info.windowGroupLength[group]; window++) {
          final base = (firstWindow + window) * info.windowLength;
          _writeNormalisedNoise(
            spectrum,
            base + start,
            generator.vector(end - start),
            energy,
          );
        }
      }
      firstWindow += info.windowGroupLength[group];
    }
  }

  /// Fills PNS bands of a CPE, preserving the AAC shared-noise rule.
  static void applyNoisePair({
    required Float64List left,
    required Float64List right,
    required AacChannelData leftData,
    required AacChannelData rightData,
    required int samplingFrequencyIndex,
    required int maskMode,
    required List<List<bool>> msUsed,
    required AacNoiseGenerator generator,
  }) {
    final info = _validatePair(left, right, leftData, rightData);
    final offsets = _bandOffsets(info, samplingFrequencyIndex);
    _validateMsMask(info, maskMode, msUsed);
    var firstWindow = 0;
    for (var group = 0; group < info.numberOfWindowGroups; group++) {
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        final leftNoise = leftData.codebooks[group][sfb] == noiseHcb;
        final rightNoise = rightData.codebooks[group][sfb] == noiseHcb;
        if (!leftNoise && !rightNoise) continue;
        final shared =
            leftNoise &&
            rightNoise &&
            (maskMode == 2 || (maskMode == 1 && msUsed[group][sfb]));
        final start = offsets[sfb];
        final end = offsets[sfb + 1];
        final width = end - start;
        for (var window = 0; window < info.windowGroupLength[group]; window++) {
          final base = (firstWindow + window) * info.windowLength + start;
          if (shared) {
            final vector = generator.vector(width);
            _writeNormalisedNoise(
              left,
              base,
              vector,
              _noiseEnergy(leftData, group, sfb),
            );
            _writeNormalisedNoise(
              right,
              base,
              vector,
              _noiseEnergy(rightData, group, sfb),
            );
          } else {
            if (leftNoise) {
              _writeNormalisedNoise(
                left,
                base,
                generator.vector(width),
                _noiseEnergy(leftData, group, sfb),
              );
            }
            if (rightNoise) {
              _writeNormalisedNoise(
                right,
                base,
                generator.vector(width),
                _noiseEnergy(rightData, group, sfb),
              );
            }
          }
        }
      }
      firstWindow += info.windowGroupLength[group];
    }
  }

  /// Derives intensity-coded right-channel bands from the left channel.
  static void applyIntensity({
    required Float64List left,
    required Float64List right,
    required AacChannelData leftData,
    required AacChannelData rightData,
    required int samplingFrequencyIndex,
    required int maskMode,
    required List<List<bool>> msUsed,
  }) {
    final info = _validatePair(left, right, leftData, rightData);
    final offsets = _bandOffsets(info, samplingFrequencyIndex);
    _validateMsMask(info, maskMode, msUsed);
    var firstWindow = 0;
    for (var group = 0; group < info.numberOfWindowGroups; group++) {
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        final cb = rightData.codebooks[group][sfb];
        if (!_isIntensity(cb)) continue;
        final position = rightData.intensityPositions[group][sfb];
        if (position == null) {
          throw const AacDecoderException(
            'Intensity band has no intensity position',
          );
        }
        var sign = cb == intensityHcb ? 1.0 : -1.0;
        if (maskMode == 1 && msUsed[group][sfb]) sign = -sign;
        final scale = sign * math.pow(0.5, 0.25 * position).toDouble();
        _forEachBandSample(info, offsets, group, sfb, firstWindow, (index) {
          right[index] = scale * left[index];
        });
      }
      firstWindow += info.windowGroupLength[group];
    }
  }

  /// Applies Temporal Noise Shaping to one de-interleaved spectrum.
  static void applyTns({
    required Float64List spectrum,
    required AacChannelData data,
    required int samplingFrequencyIndex,
  }) {
    final windows = data.tnsWindows;
    if (windows == null) return;
    final info = data.info;
    _validateSpectrum(spectrum, info);
    if (windows.length != info.numberOfWindows) {
      throw const AacDecoderException('TNS window count is invalid');
    }
    final offsets = _bandOffsets(info, samplingFrequencyIndex);
    const longMaxBands = <int>[31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39];
    const shortMaxBands = <int>[9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14];
    final maxBands = info.isShort
        ? shortMaxBands[samplingFrequencyIndex]
        : longMaxBands[samplingFrequencyIndex];
    final maximumOrder = info.isShort ? 7 : 12;

    for (var window = 0; window < windows.length; window++) {
      var bottom = offsets.length - 1;
      for (final filter in windows[window].filters) {
        final top = bottom;
        bottom = math.max(0, top - filter.length);
        final order = math.min(filter.order, maximumOrder);
        if (order == 0) continue;
        final startBand = math.min(math.min(bottom, info.maxSfb), maxBands);
        final endBand = math.min(math.min(top, info.maxSfb), maxBands);
        final start = offsets[startBand];
        final end = offsets[endBand];
        if (end <= start) continue;
        final lpc = _tnsLpc(filter, order);
        _tnsArFilter(
          spectrum,
          window * info.windowLength + (filter.direction ? end - 1 : start),
          end - start,
          filter.direction ? -1 : 1,
          lpc,
        );
      }
    }
  }

  static AacIcsInfo _validatePair(
    Float64List left,
    Float64List right,
    AacChannelData leftData,
    AacChannelData rightData,
  ) {
    final info = leftData.info;
    final other = rightData.info;
    if (info.windowSequence != other.windowSequence ||
        info.windowShape != other.windowShape ||
        info.maxSfb != other.maxSfb ||
        !_listEquals(info.windowGroupLength, other.windowGroupLength)) {
      throw const AacDecoderException('CPE channel geometry differs');
    }
    _validateSpectrum(left, info);
    _validateSpectrum(right, info);
    return info;
  }

  static void _validateSpectrum(Float64List spectrum, AacIcsInfo info) {
    if (spectrum.length != info.numberOfWindows * info.windowLength) {
      throw const AacDecoderException('AAC spectrum length is invalid');
    }
  }

  static void _validateMsMask(
    AacIcsInfo info,
    int maskMode,
    List<List<bool>> msUsed,
  ) {
    if (maskMode == 3) {
      throw const AacDecoderException('Reserved ms_mask_present value');
    }
    if (maskMode == 1 &&
        (msUsed.length != info.numberOfWindowGroups ||
            msUsed.any((row) => row.length < info.maxSfb))) {
      throw const AacDecoderException('Truncated AAC M/S mask');
    }
  }

  static List<int> _bandOffsets(AacIcsInfo info, int samplingIndex) =>
      info.isShort
      ? shortSwbOffsets(samplingIndex)
      : longSwbOffsets(samplingIndex);

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _isIntensity(int codebook) =>
      codebook == intensityHcb || codebook == intensityHcb2;

  static int _noiseEnergy(AacChannelData data, int group, int sfb) {
    final energy = data.noiseEnergies[group][sfb];
    if (energy == null) {
      throw const AacDecoderException('PNS band has no noise energy');
    }
    return energy;
  }

  static void _writeNormalisedNoise(
    Float64List destination,
    int start,
    Float64List source,
    int energy,
  ) {
    var sumSquares = 0.0;
    for (final value in source) {
      sumSquares += value * value;
    }
    if (sumSquares <= 0 || !sumSquares.isFinite) {
      throw const AacDecoderException('AAC PNS generator produced no energy');
    }
    final scale =
        math.pow(2.0, 0.25 * energy).toDouble() / math.sqrt(sumSquares);
    for (var i = 0; i < source.length; i++) {
      destination[start + i] = source[i] * scale;
    }
  }

  static void _forEachBandSample(
    AacIcsInfo info,
    List<int> offsets,
    int group,
    int sfb,
    int firstWindow,
    void Function(int index) action,
  ) {
    final start = offsets[sfb];
    final end = offsets[sfb + 1];
    for (var window = 0; window < info.windowGroupLength[group]; window++) {
      final base = (firstWindow + window) * info.windowLength;
      for (var coefficient = start; coefficient < end; coefficient++) {
        action(base + coefficient);
      }
    }
  }

  static Float64List _tnsLpc(AacTnsFilter filter, int order) {
    final transmittedBits =
        filter.coefficientResolution - (filter.coefficientCompression ? 1 : 0);
    final mask = (1 << transmittedBits) - 1;
    final signBit = 1 << (transmittedBits - 1);
    final positiveDivisor =
        ((1 << (filter.coefficientResolution - 1)) - 0.5) / (math.pi / 2.0);
    final negativeDivisor =
        ((1 << (filter.coefficientResolution - 1)) + 0.5) / (math.pi / 2.0);
    final parcor = Float64List(order);
    for (var i = 0; i < order; i++) {
      final field = filter.coefficients[i] & mask;
      final signed = (field & signBit) == 0 ? field : field | ~mask;
      parcor[i] = math.sin(
        signed / (signed >= 0 ? positiveDivisor : negativeDivisor),
      );
    }

    final lpc = Float64List(order + 1)..[0] = 1.0;
    final scratch = Float64List(order + 1);
    for (var currentOrder = 1; currentOrder <= order; currentOrder++) {
      final reflection = parcor[currentOrder - 1];
      for (var i = 1; i < currentOrder; i++) {
        scratch[i] = lpc[i] + reflection * lpc[currentOrder - i];
      }
      for (var i = 1; i < currentOrder; i++) {
        lpc[i] = scratch[i];
      }
      lpc[currentOrder] = reflection;
    }
    return lpc;
  }

  static void _tnsArFilter(
    Float64List spectrum,
    int start,
    int size,
    int increment,
    Float64List lpc,
  ) {
    final order = lpc.length - 1;
    final history = Float64List(order);
    var index = start;
    for (var n = 0; n < size; n++) {
      var output = spectrum[index];
      for (var tap = 1; tap <= order; tap++) {
        output -= lpc[tap] * history[tap - 1];
      }
      spectrum[index] = output;
      for (var tap = order - 1; tap > 0; tap--) {
        history[tap] = history[tap - 1];
      }
      history[0] = output;
      index += increment;
    }
  }
}
