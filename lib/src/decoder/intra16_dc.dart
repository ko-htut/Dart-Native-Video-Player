int _roundShiftSigned(int v, int shift) {
  if (shift <= 0) return v;
  final add = 1 << (shift - 1);
  if (v >= 0) return (v + add) >> shift;
  return -(((-v) + add) >> shift);
}

List<int> _hadamard4x4Core(List<int> src) {
  final s = List<int>.filled(16, 0);
  final n = src.length < 16 ? src.length : 16;
  for (int i = 0; i < n; i++) {
    s[i] = src[i];
  }

  final t = List<int>.filled(16, 0);
  for (int r = 0; r < 4; r++) {
    final x0 = s[r * 4 + 0];
    final x1 = s[r * 4 + 1];
    final x2 = s[r * 4 + 2];
    final x3 = s[r * 4 + 3];

    final a0 = x0 + x1;
    final a1 = x0 - x1;
    final a2 = x2 + x3;
    final a3 = x2 - x3;

    t[r * 4 + 0] = a0 + a2;
    t[r * 4 + 1] = a1 + a3;
    t[r * 4 + 2] = a0 - a2;
    t[r * 4 + 3] = a1 - a3;
  }

  final out = List<int>.filled(16, 0);
  for (int c = 0; c < 4; c++) {
    final x0 = t[0 * 4 + c];
    final x1 = t[1 * 4 + c];
    final x2 = t[2 * 4 + c];
    final x3 = t[3 * 4 + c];

    final a0 = x0 + x1;
    final a1 = x0 - x1;
    final a2 = x2 + x3;
    final a3 = x2 - x3;

    out[0 * 4 + c] = a0 + a2;
    out[1 * 4 + c] = a1 + a3;
    out[2 * 4 + c] = a0 - a2;
    out[3 * 4 + c] = a1 - a3;
  }
  return out;
}

List<int> hadamard4x4Forward(List<int> src) => _hadamard4x4Core(src);

List<int> hadamard4x4Inverse(List<int> src) => _hadamard4x4Core(src);

List<int> scaleIntra16LumaDc(List<int> invDc) {
  final out = List<int>.filled(16, 0);
  for (int i = 0; i < 16; i++) {
    final v = i < invDc.length ? invDc[i] : 0;
    // Intra16 DC normalization stage (integer, rounded).
    out[i] = _roundShiftSigned(v, 2);
  }
  return out;
}

void applyIntra16LumaDcHadamard(List<List<int>> coeffBlocks) {
  if (coeffBlocks.length < 16) return;

  final dcIn = List<int>.filled(16, 0);
  for (int i = 0; i < 16; i++) {
    final block = coeffBlocks[i];
    if (block.isNotEmpty) {
      dcIn[i] = block[0];
    }
  }

  final dcInv = hadamard4x4Inverse(dcIn);
  final dcOut = scaleIntra16LumaDc(dcInv);

  for (int i = 0; i < 16; i++) {
    final block = coeffBlocks[i];
    if (block.isNotEmpty) {
      // Replace DC as required by Intra16x16 DC reconstruction path.
      block[0] = dcOut[i];
    }
  }
}
