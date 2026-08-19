import 'dart:math' as math;
import 'dart:typed_data';

import 'bit_reader.dart';
import 'syntax.dart';

const int _longTransformLength = 2048;
const int _shortTransformLength = 256;
const int _frameLength = 1024;
const int _shortWindowCount = 8;

/// Stateful AAC-LC synthesis filterbank for one channel.
final class AacFilterbank {
  AacFilterbank();

  Float64List _overlap = Float64List(_frameLength);
  AacWindowShape? _previousShape;

  void reset() {
    _overlap = Float64List(_frameLength);
    _previousShape = null;
  }

  Float64List synthesize(Float64List spectrum, AacIcsInfo info) {
    if (spectrum.length != _frameLength) {
      throw const AacDecoderException(
        'AAC filterbank requires exactly 1024 coefficients',
      );
    }
    final previousShape = _previousShape ?? info.windowShape;
    final windowed = switch (info.windowSequence) {
      AacWindowSequence.onlyLong => _longWindowed(
        spectrum,
        previousShape,
        info.windowShape,
        info.windowSequence,
      ),
      AacWindowSequence.longStart => _longWindowed(
        spectrum,
        previousShape,
        info.windowShape,
        info.windowSequence,
      ),
      AacWindowSequence.longStop => _longWindowed(
        spectrum,
        previousShape,
        info.windowShape,
        info.windowSequence,
      ),
      AacWindowSequence.eightShort => _shortWindowed(
        spectrum,
        previousShape,
        info.windowShape,
      ),
    };

    final output = Float64List(_frameLength);
    for (var i = 0; i < _frameLength; i++) {
      output[i] = windowed[i] + _overlap[i];
    }
    _overlap = Float64List.fromList(
      Float64List.sublistView(windowed, _frameLength),
    );
    _previousShape = info.windowShape;
    return output;
  }

  Float64List _longWindowed(
    Float64List spectrum,
    AacWindowShape leftShape,
    AacWindowShape rightShape,
    AacWindowSequence sequence,
  ) {
    final signal = _longImdct.transform(spectrum);
    final window = _longWindow(leftShape, rightShape, sequence);
    for (var i = 0; i < signal.length; i++) {
      signal[i] *= window[i];
    }
    return signal;
  }

  Float64List _shortWindowed(
    Float64List spectrum,
    AacWindowShape leftShape,
    AacWindowShape rightShape,
  ) {
    final result = Float64List(_longTransformLength);
    const start = (_longTransformLength - _shortTransformLength) ~/ 4;
    const hop = _shortTransformLength ~/ 2;
    for (var windowIndex = 0; windowIndex < _shortWindowCount; windowIndex++) {
      final coefficients = Float64List.sublistView(
        spectrum,
        windowIndex * 128,
        (windowIndex + 1) * 128,
      );
      final signal = _shortImdct.transform(coefficients);
      final actualLeft = windowIndex == 0 ? leftShape : rightShape;
      final left = _halfWindow(_shortTransformLength, actualLeft);
      final right = _halfWindow(_shortTransformLength, rightShape);
      final base = start + windowIndex * hop;
      for (var i = 0; i < 128; i++) {
        result[base + i] += signal[i] * left[i];
        result[base + 128 + i] += signal[128 + i] * right[127 - i];
      }
    }
    return result;
  }
}

final _ImdctPlan _longImdct = _ImdctPlan(_longTransformLength);
final _ImdctPlan _shortImdct = _ImdctPlan(_shortTransformLength);

/// O(N log N) IMDCT through a sparse length-4N complex FFT.
///
/// For M=N/2 coefficients, DCT-IV is the real part of a length-8M
/// positive-sign DFT with coefficients stored at odd input indices. The
/// remaining step unfolds that DCT-IV into the standard length-N IMDCT.
final class _ImdctPlan {
  _ImdctPlan(this.transformLength)
    : coefficientCount = transformLength ~/ 2,
      fftLength = transformLength * 4 {
    if (!_isPowerOfTwo(transformLength)) {
      throw ArgumentError.value(transformLength, 'transformLength');
    }
  }

  final int transformLength;
  final int coefficientCount;
  final int fftLength;

  Float64List transform(Float64List coefficients) {
    if (coefficients.length != coefficientCount) {
      throw const AacDecoderException('IMDCT coefficient count is invalid');
    }
    final real = Float64List(fftLength);
    final imaginary = Float64List(fftLength);
    for (var k = 0; k < coefficientCount; k++) {
      real[2 * k + 1] = coefficients[k];
    }
    _fftPositive(real, imaginary);

    final dct = Float64List(coefficientCount);
    for (var n = 0; n < coefficientCount; n++) {
      dct[n] = real[2 * n + 1];
    }

    final output = Float64List(transformLength);
    final halfM = coefficientCount ~/ 2;
    final scale = 1.0 / coefficientCount;
    for (var n = 0; n < halfM; n++) {
      output[n] = dct[halfM + n] * scale;
    }
    for (var n = halfM; n < 3 * halfM; n++) {
      output[n] = -dct[3 * halfM - 1 - n] * scale;
    }
    for (var n = 3 * halfM; n < 2 * coefficientCount; n++) {
      output[n] = -dct[n - 3 * halfM] * scale;
    }
    return output;
  }
}

void _fftPositive(Float64List real, Float64List imaginary) {
  final length = real.length;
  var reversed = 0;
  for (var i = 1; i < length; i++) {
    var bit = length >> 1;
    while ((reversed & bit) != 0) {
      reversed ^= bit;
      bit >>= 1;
    }
    reversed ^= bit;
    if (i < reversed) {
      final r = real[i];
      real[i] = real[reversed];
      real[reversed] = r;
      final im = imaginary[i];
      imaginary[i] = imaginary[reversed];
      imaginary[reversed] = im;
    }
  }

  for (var blockLength = 2; blockLength <= length; blockLength <<= 1) {
    final angle = 2.0 * math.pi / blockLength;
    final stepReal = math.cos(angle);
    final stepImaginary = math.sin(angle);
    final half = blockLength >> 1;
    for (var block = 0; block < length; block += blockLength) {
      var twiddleReal = 1.0;
      var twiddleImaginary = 0.0;
      for (var j = 0; j < half; j++) {
        final even = block + j;
        final odd = even + half;
        final oddReal =
            real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary;
        final oddImaginary =
            real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal;
        final evenReal = real[even];
        final evenImaginary = imaginary[even];
        real[even] = evenReal + oddReal;
        imaginary[even] = evenImaginary + oddImaginary;
        real[odd] = evenReal - oddReal;
        imaginary[odd] = evenImaginary - oddImaginary;

        final nextReal =
            twiddleReal * stepReal - twiddleImaginary * stepImaginary;
        twiddleImaginary =
            twiddleReal * stepImaginary + twiddleImaginary * stepReal;
        twiddleReal = nextReal;
      }
    }
  }
}

Float64List _longWindow(
  AacWindowShape leftShape,
  AacWindowShape rightShape,
  AacWindowSequence sequence,
) {
  final result = Float64List(_longTransformLength);
  final longLeft = _halfWindow(_longTransformLength, leftShape);
  final longRight = _halfWindow(_longTransformLength, rightShape);
  final shortLeft = _halfWindow(_shortTransformLength, leftShape);
  final shortRight = _halfWindow(_shortTransformLength, rightShape);

  if (sequence == AacWindowSequence.onlyLong ||
      sequence == AacWindowSequence.longStart) {
    result.setAll(0, longLeft);
  } else if (sequence == AacWindowSequence.longStop) {
    const start = (_longTransformLength - _shortTransformLength) ~/ 4;
    result.setAll(start, shortLeft);
    for (var i = start + 128; i < 1024; i++) {
      result[i] = 1.0;
    }
  }

  if (sequence == AacWindowSequence.onlyLong ||
      sequence == AacWindowSequence.longStop) {
    for (var i = 0; i < 1024; i++) {
      result[1024 + i] = longRight[1023 - i];
    }
  } else if (sequence == AacWindowSequence.longStart) {
    const start = (3 * _longTransformLength - _shortTransformLength) ~/ 4;
    for (var i = 1024; i < start; i++) {
      result[i] = 1.0;
    }
    for (var i = 0; i < 128; i++) {
      result[start + i] = shortRight[127 - i];
    }
  }
  return result;
}

final Map<(int, AacWindowShape), Float64List> _windowCache =
    <(int, AacWindowShape), Float64List>{};

Float64List _halfWindow(int transformLength, AacWindowShape shape) =>
    _windowCache.putIfAbsent((transformLength, shape), () {
      final half = transformLength ~/ 2;
      if (shape == AacWindowShape.sine) {
        return Float64List.fromList(<double>[
          for (var i = 0; i < half; i++)
            math.sin(math.pi * (i + 0.5) / transformLength),
        ]);
      }
      final alpha = transformLength == _longTransformLength ? 4.0 : 6.0;
      final kernel = Float64List(half + 1);
      final quarter = half / 2.0;
      final denominator = _besselI0(math.pi * alpha);
      var total = 0.0;
      for (var i = 0; i <= half; i++) {
        final position = (i - quarter) / quarter;
        final radicand = math.max(0.0, 1.0 - position * position);
        kernel[i] =
            _besselI0(math.pi * alpha * math.sqrt(radicand)) / denominator;
        total += kernel[i];
      }
      var running = 0.0;
      final result = Float64List(half);
      for (var i = 0; i < half; i++) {
        running += kernel[i];
        result[i] = math.sqrt(running / total);
      }
      return result;
    });

double _besselI0(double value) {
  final half = value / 2.0;
  var term = 1.0;
  var sum = 1.0;
  for (var k = 1.0; k <= 256.0; k++) {
    term *= (half / k) * (half / k);
    sum += term;
    if (term <= sum * 1e-18) break;
  }
  return sum;
}

bool _isPowerOfTwo(int value) => value > 0 && (value & (value - 1)) == 0;
