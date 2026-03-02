int clip8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

void predictIntra16({
  required int mode,
  required int mbX,
  required int mbY,
  required int width,
  required int height,
  required List<int> yPlane,
  required List<int> out16, // 256
}) {
  final x0 = mbX * 16;
  final y0 = mbY * 16;

  final top = List<int>.filled(16, 128);
  final left = List<int>.filled(16, 128);

  if (y0 > 0) {
    final row = (y0 - 1) * width;
    for (int i = 0; i < 16; i++) {
      final xx = x0 + i;
      if (xx < width) top[i] = yPlane[row + xx];
    }
  }
  if (x0 > 0) {
    for (int j = 0; j < 16; j++) {
      final yy = y0 + j;
      if (yy < height) left[j] = yPlane[yy * width + (x0 - 1)];
    }
  }

  if (mode == 0) {
    for (int j = 0; j < 16; j++) {
      for (int i = 0; i < 16; i++) out16[j * 16 + i] = top[i];
    }
  } else if (mode == 1) {
    for (int j = 0; j < 16; j++) {
      for (int i = 0; i < 16; i++) out16[j * 16 + i] = left[j];
    }
  } else if (mode == 2) {
    int sum = 0;
    for (int i = 0; i < 16; i++) sum += top[i] + left[i];
    final dc = (sum + 16) >> 5;
    for (int k = 0; k < 256; k++) out16[k] = dc;
  } else {
    int sumTop = 0, sumLeft = 0;
    for (int i = 0; i < 16; i++) {
      sumTop += top[i];
      sumLeft += left[i];
    }
    final base = (sumTop + sumLeft + 16) >> 5;
    for (int k = 0; k < 256; k++) out16[k] = base;
  }
}

/// Intra4x4: mode 0..8
/// We sample top[0..7], left[0..3], topLeft (X). If top-right unavailable, repeat top[3].
void predictIntra4x4({
  required int mode,
  required List<int> top, // len 8
  required List<int> left, // len 4
  required int topLeft,
  required List<int> out, // len 16
}) {
  // Clamp sample fetches at frame edges (spec-style edge replication).
  int A(int i) {
    if (i < 0) return top[0];
    if (i >= top.length) return top[top.length - 1];
    return top[i];
  }

  int I(int j) {
    if (j < 0) return left[0];
    if (j >= left.length) return left[left.length - 1];
    return left[j];
  }

  // Fill helper
  void fill(int v) {
    for (int k = 0; k < 16; k++) out[k] = v;
  }

  if (mode == 0) {
    // Vertical
    for (int j = 0; j < 4; j++)
      for (int i = 0; i < 4; i++) out[j * 4 + i] = A(i);
    return;
  }
  if (mode == 1) {
    // Horizontal
    for (int j = 0; j < 4; j++)
      for (int i = 0; i < 4; i++) out[j * 4 + i] = I(j);
    return;
  }
  if (mode == 2) {
    // DC
    int sum = 0;
    for (int i = 0; i < 4; i++) sum += A(i) + I(i);
    fill((sum + 4) >> 3);
    return;
  }

  // For directional modes we need extended top samples (A..H)
  final t = List<int>.filled(8, 128);
  for (int i = 0; i < 8; i++) {
    t[i] = A(i);
  }
  int T(int i) {
    if (i < 0) return t[0];
    if (i >= t.length) return t[t.length - 1];
    return t[i];
  }

  if (mode == 3) {
    // Diagonal Down-Left
    // p[x,y] = (A[x+y] + 2*A[x+y+1] + A[x+y+2] + 2)/4
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        final k = x + y;
        final v = (T(k) + 2 * T(k + 1) + T(k + 2) + 2) >> 2;
        out[y * 4 + x] = v;
      }
    }
    return;
  }

  if (mode == 4) {
    // Diagonal Down-Right
    // uses left + top + topLeft
    int X = topLeft;
    int A0 = T(0), A1 = T(1), A2 = T(2), A3 = T(3);
    int I0 = left[0], I1 = left[1], I2 = left[2], I3 = left[3];

    out[0] = (X + 2 * A0 + A1 + 2) >> 2;
    out[1] = (A0 + 2 * A1 + A2 + 2) >> 2;
    out[2] = (A1 + 2 * A2 + A3 + 2) >> 2;
    out[3] = (A2 + 2 * A3 + A3 + 2) >> 2;

    out[4] = (I0 + 2 * X + A0 + 2) >> 2;
    out[5] = (X + 2 * A0 + A1 + 2) >> 2;
    out[6] = (A0 + 2 * A1 + A2 + 2) >> 2;
    out[7] = (A1 + 2 * A2 + A3 + 2) >> 2;

    out[8] = (I1 + 2 * I0 + X + 2) >> 2;
    out[9] = (I0 + 2 * X + A0 + 2) >> 2;
    out[10] = (X + 2 * A0 + A1 + 2) >> 2;
    out[11] = (A0 + 2 * A1 + A2 + 2) >> 2;

    out[12] = (I2 + 2 * I1 + I0 + 2) >> 2;
    out[13] = (I1 + 2 * I0 + X + 2) >> 2;
    out[14] = (I0 + 2 * X + A0 + 2) >> 2;
    out[15] = (X + 2 * A0 + A1 + 2) >> 2;
    return;
  }

  // The remaining 4 modes (5..8) are more complex; implement stable spec-style approximations.

  if (mode == 5) {
    // Vertical-Right
    // interpolate using top + topLeft + left
    final X = topLeft;
    final A0 = T(0), A1 = T(1), A2 = T(2), A3 = T(3);
    final I0 = left[0], I1 = left[1], I2 = left[2], I3 = left[3];

    out[0] = (X + A0 + 1) >> 1;
    out[1] = (A0 + A1 + 1) >> 1;
    out[2] = (A1 + A2 + 1) >> 1;
    out[3] = (A2 + A3 + 1) >> 1;

    out[4] = (I0 + 2 * X + A0 + 2) >> 2;
    out[5] = (X + 2 * A0 + A1 + 2) >> 2;
    out[6] = (A0 + 2 * A1 + A2 + 2) >> 2;
    out[7] = (A1 + 2 * A2 + A3 + 2) >> 2;

    out[8] = (I1 + I0 + 1) >> 1;
    out[9] = (I0 + 2 * X + A0 + 2) >> 2;
    out[10] = (X + 2 * A0 + A1 + 2) >> 2;
    out[11] = (A0 + 2 * A1 + A2 + 2) >> 2;

    out[12] = (I2 + I1 + 1) >> 1;
    out[13] = (I1 + I0 + 1) >> 1;
    out[14] = (I0 + 2 * X + A0 + 2) >> 2;
    out[15] = (X + 2 * A0 + A1 + 2) >> 2;
    return;
  }

  if (mode == 6) {
    // Horizontal-Down
    final X = topLeft;
    final A0 = T(0), A1 = T(1), A2 = T(2), A3 = T(3);
    final I0 = left[0], I1 = left[1], I2 = left[2], I3 = left[3];

    out[0] = (X + I0 + 1) >> 1;
    out[4] = (I0 + I1 + 1) >> 1;
    out[8] = (I1 + I2 + 1) >> 1;
    out[12] = (I2 + I3 + 1) >> 1;

    out[1] = (A0 + 2 * X + I0 + 2) >> 2;
    out[5] = (X + 2 * I0 + I1 + 2) >> 2;
    out[9] = (I0 + 2 * I1 + I2 + 2) >> 2;
    out[13] = (I1 + 2 * I2 + I3 + 2) >> 2;

    out[2] = (A1 + A0 + 1) >> 1;
    out[6] = (A0 + 2 * X + I0 + 2) >> 2;
    out[10] = (X + 2 * I0 + I1 + 2) >> 2;
    out[14] = (I0 + 2 * I1 + I2 + 2) >> 2;

    out[3] = (A2 + A1 + 1) >> 1;
    out[7] = (A1 + A0 + 1) >> 1;
    out[11] = (A0 + 2 * X + I0 + 2) >> 2;
    out[15] = (X + 2 * I0 + I1 + 2) >> 2;
    return;
  }

  if (mode == 7) {
    // Vertical-Left
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        final k = x + (y >> 1);
        final v = ((T(k) + T(k + 1) + 1) >> 1);
        out[y * 4 + x] = v;
      }
    }
    return;
  }

  if (mode == 8) {
    // Horizontal-Up
    final I0 = left[0], I1 = left[1], I2 = left[2], I3 = left[3];
    final ext = [I0, I1, I2, I3, I3, I3, I3, I3];
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        final k = y + (x >> 1);
        out[y * 4 + x] = (ext[k] + ext[k + 1] + 1) >> 1;
      }
    }
    return;
  }

  fill(128);
}
