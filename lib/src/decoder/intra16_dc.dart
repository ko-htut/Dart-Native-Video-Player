const List<int> _dcDequantByQpMod6 = <int>[10, 11, 13, 14, 16, 18];

int _clampQp(int qp) => qp.clamp(0, 51).toInt();

/// Applies the unnormalised separable 4x4 Hadamard transform used by H.264 for
/// Intra_16x16 luma DC coefficients.
List<int> _hadamard4x4(List<int> source) {
  final input = List<int>.filled(16, 0);
  for (var i = 0; i < source.length && i < 16; i++) {
    input[i] = source[i];
  }

  final horizontal = List<int>.filled(16, 0);
  for (var row = 0; row < 4; row++) {
    final offset = row * 4;
    final a0 = input[offset] + input[offset + 1];
    final a1 = input[offset] - input[offset + 1];
    final a2 = input[offset + 2] + input[offset + 3];
    final a3 = input[offset + 2] - input[offset + 3];

    horizontal[offset] = a0 + a2;
    horizontal[offset + 1] = a0 - a2;
    horizontal[offset + 2] = a1 - a3;
    horizontal[offset + 3] = a1 + a3;
  }

  final output = List<int>.filled(16, 0);
  for (var column = 0; column < 4; column++) {
    final a0 = horizontal[column] + horizontal[4 + column];
    final a1 = horizontal[column] - horizontal[4 + column];
    final a2 = horizontal[8 + column] + horizontal[12 + column];
    final a3 = horizontal[8 + column] - horizontal[12 + column];

    output[column] = a0 + a2;
    output[4 + column] = a0 - a2;
    output[8 + column] = a1 - a3;
    output[12 + column] = a1 + a3;
  }
  return output;
}

/// Exposes the unnormalised Hadamard operation for encoder/decoder tests.
List<int> hadamard4x4Forward(List<int> source) => _hadamard4x4(source);

/// The H.264 inverse luma DC Hadamard has the same integer kernel as forward.
List<int> hadamard4x4Inverse(List<int> source) => _hadamard4x4(source);

/// Scales inverse-Hadamard Intra_16x16 DC values for the flat Baseline-profile
/// scaling list.
List<int> scaleIntra16LumaDc(List<int> inverseDc, {int qp = 26}) {
  final q = _clampQp(qp);
  final qpDiv6 = q ~/ 6;
  // With the Baseline flat scaling list, LevelScale(qp%6, 0, 0) is the
  // normalisation adjustment multiplied by the list weight 16.
  final levelScale = _dcDequantByQpMod6[q % 6] << 4;
  final output = List<int>.filled(16, 0);

  for (var i = 0; i < 16; i++) {
    final value = i < inverseDc.length ? inverseDc[i] : 0;
    if (q >= 36) {
      output[i] = (value * levelScale) << (qpDiv6 - 6);
    } else {
      final shift = 6 - qpDiv6;
      output[i] = (value * levelScale + (1 << (shift - 1))) >> shift;
    }
  }
  return output;
}

/// Replaces each luma 4x4 block's DC coefficient with its transformed and
/// already-dequantised Intra_16x16 DC value.
///
/// The blocks and the DC input are both in 4x4 raster order. Subsequent calls
/// to `invTransform4x4` must set `dcAlreadyScaled: true`.
void applyIntra16LumaDcHadamard(List<List<int>> coeffBlocks, {int qp = 26}) {
  if (coeffBlocks.length < 16) {
    throw ArgumentError.value(
      coeffBlocks.length,
      'coeffBlocks.length',
      'must be >= 16',
    );
  }

  final dcInput = List<int>.filled(16, 0);
  for (var i = 0; i < 16; i++) {
    if (coeffBlocks[i].isEmpty) {
      throw ArgumentError('coeffBlocks[$i] must not be empty.');
    }
    dcInput[i] = coeffBlocks[i][0];
  }

  final transformed = hadamard4x4Inverse(dcInput);
  final scaled = scaleIntra16LumaDc(transformed, qp: qp);
  for (var i = 0; i < 16; i++) {
    coeffBlocks[i][0] = scaled[i];
  }
}
