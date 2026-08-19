/// H.264 4x4 inverse-quantisation normalisation adjustments for a flat scaling
/// list. Entries are `(even,even)`, mixed parity, and `(odd,odd)` respectively.
const List<List<int>> _dequantByQpMod6 = <List<int>>[
  <int>[10, 13, 16],
  <int>[11, 14, 18],
  <int>[13, 16, 20],
  <int>[14, 18, 23],
  <int>[16, 20, 25],
  <int>[18, 23, 29],
];

int _clampQp(int qp) => qp.clamp(0, 51).toInt();

int _dequantMultiplier(int row, int column, int qpMod6) {
  if (row.isEven && column.isEven) {
    return _dequantByQpMod6[qpMod6][0];
  }
  if (row.isOdd && column.isOdd) {
    return _dequantByQpMod6[qpMod6][2];
  }
  return _dequantByQpMod6[qpMod6][1];
}

/// Inverse-quantises and inverse-transforms one H.264 4x4 residual block.
///
/// This is the Baseline-profile, 8-bit, flat-scaling-list path. Set
/// [dcAlreadyScaled] for Intra_16x16 luma blocks and 4:2:0 chroma blocks after
/// their separate DC transform/scaling process; H.264 requires d[0][0] to be
/// copied directly in those cases.
List<int> invTransform4x4(
  List<int> coefficients, {
  int qp = 26,
  bool dcAlreadyScaled = false,
}) {
  final q = _clampQp(qp);
  final qpDiv6 = q ~/ 6;
  final qpMod6 = q % 6;
  final dequantized = List<int>.filled(16, 0);

  for (var row = 0; row < 4; row++) {
    for (var column = 0; column < 4; column++) {
      final index = row * 4 + column;
      final coefficient = index < coefficients.length ? coefficients[index] : 0;
      if (index == 0 && dcAlreadyScaled) {
        dequantized[index] = coefficient;
      } else {
        dequantized[index] =
            coefficient *
            _dequantMultiplier(row, column, qpMod6) *
            (1 << qpDiv6);
      }
    }
  }

  final horizontal = List<int>.filled(16, 0);
  for (var row = 0; row < 4; row++) {
    final offset = row * 4;
    final e0 = dequantized[offset] + dequantized[offset + 2];
    final e1 = dequantized[offset] - dequantized[offset + 2];
    final e2 = (dequantized[offset + 1] >> 1) - dequantized[offset + 3];
    final e3 = dequantized[offset + 1] + (dequantized[offset + 3] >> 1);

    horizontal[offset] = e0 + e3;
    horizontal[offset + 1] = e1 + e2;
    horizontal[offset + 2] = e1 - e2;
    horizontal[offset + 3] = e0 - e3;
  }

  final residual = List<int>.filled(16, 0);
  for (var column = 0; column < 4; column++) {
    final g0 = horizontal[column] + horizontal[8 + column];
    final g1 = horizontal[column] - horizontal[8 + column];
    final g2 = (horizontal[4 + column] >> 1) - horizontal[12 + column];
    final g3 = horizontal[4 + column] + (horizontal[12 + column] >> 1);

    residual[column] = (g0 + g3 + 32) >> 6;
    residual[4 + column] = (g1 + g2 + 32) >> 6;
    residual[8 + column] = (g1 - g2 + 32) >> 6;
    residual[12 + column] = (g0 - g3 + 32) >> 6;
  }
  return residual;
}
