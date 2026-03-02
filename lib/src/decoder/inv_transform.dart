const List<List<int>> _dequantCoef4x4 = <List<int>>[
  <int>[10, 13, 16],
  <int>[11, 14, 18],
  <int>[13, 16, 20],
  <int>[14, 18, 23],
  <int>[16, 20, 25],
  <int>[18, 23, 29],
];

int _dequantScaleAt(int x, int y, int qpMod6) {
  if ((x & 1) == 0 && (y & 1) == 0) return _dequantCoef4x4[qpMod6][0];
  if ((x & 1) == 1 && (y & 1) == 1) return _dequantCoef4x4[qpMod6][2];
  return _dequantCoef4x4[qpMod6][1];
}

int _roundShiftSigned(int v, int shift) {
  if (shift <= 0) return v;
  final add = 1 << (shift - 1);
  if (v >= 0) return (v + add) >> shift;
  return -(((-v) + add) >> shift);
}

List<int> invTransform4x4(List<int> c, {int qp = 26}) {
  int q = qp;
  if (q < 0) q = 0;
  if (q > 51) q = 51;

  final qpDiv6 = q ~/ 6;
  final qpMod6 = q % 6;

  final dq = List<int>.filled(16, 0);
  for (int y = 0; y < 4; y++) {
    for (int x = 0; x < 4; x++) {
      final idx = y * 4 + x;
      final coef = idx < c.length ? c[idx] : 0;
      final s = _dequantScaleAt(x, y, qpMod6);
      final scaled = coef * s;
      // Inverse quant approx:
      // d = (coef * levelScale * 2^(qp/6)) / 16
      // Use rounded right shift when qpDiv6 < 4.
      if (qpDiv6 >= 4) {
        dq[idx] = scaled << (qpDiv6 - 4);
      } else {
        dq[idx] = _roundShiftSigned(scaled, 4 - qpDiv6);
      }
    }
  }

  final t = List<int>.filled(16, 0);

  for (int i = 0; i < 4; i++) {
    final a0 = dq[i * 4 + 0] + dq[i * 4 + 2];
    final a1 = dq[i * 4 + 0] - dq[i * 4 + 2];
    final a2 = (dq[i * 4 + 1] >> 1) - dq[i * 4 + 3];
    final a3 = dq[i * 4 + 1] + (dq[i * 4 + 3] >> 1);

    t[i * 4 + 0] = a0 + a3;
    t[i * 4 + 1] = a1 + a2;
    t[i * 4 + 2] = a1 - a2;
    t[i * 4 + 3] = a0 - a3;
  }

  final out = List<int>.filled(16, 0);
  for (int i = 0; i < 4; i++) {
    final a0 = t[0 * 4 + i] + t[2 * 4 + i];
    final a1 = t[0 * 4 + i] - t[2 * 4 + i];
    final a2 = (t[1 * 4 + i] >> 1) - t[3 * 4 + i];
    final a3 = t[1 * 4 + i] + (t[3 * 4 + i] >> 1);

    out[0 * 4 + i] = (a0 + a3 + 32) >> 6;
    out[1 * 4 + i] = (a1 + a2 + 32) >> 6;
    out[2 * 4 + i] = (a1 - a2 + 32) >> 6;
    out[3 * 4 + i] = (a0 - a3 + 32) >> 6;
  }
  return out;
}
