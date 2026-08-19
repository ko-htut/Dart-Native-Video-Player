int clip8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// Very simplified inverse transform for 4x4 (not full spec-accurate scaling).
/// Good enough to see real pictures for many clips in a milestone build.
List<int> invTransform4x4(List<int> c) {
  final t = List<int>.filled(16, 0);

  // inverse hadamard-ish simplified
  for (int i = 0; i < 4; i++) {
    final a0 = c[i * 4 + 0] + c[i * 4 + 2];
    final a1 = c[i * 4 + 0] - c[i * 4 + 2];
    final a2 = (c[i * 4 + 1] >> 1) - c[i * 4 + 3];
    final a3 = c[i * 4 + 1] + (c[i * 4 + 3] >> 1);

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

/// Intra16 prediction modes:
/// 0 Vertical, 1 Horizontal, 2 DC, 3 Plane (Plane simplified)
void predictIntra16({
  required int mode,
  required int mbX,
  required int mbY,
  required int width,
  required int height,
  required List<int> pred, // output 16x16
  required List<int> yPlane, // current frame luma
}) {
  final x0 = mbX * 16;
  final y0 = mbY * 16;

  // gather top row and left col
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
    // vertical
    for (int j = 0; j < 16; j++) {
      for (int i = 0; i < 16; i++) {
        pred[j * 16 + i] = top[i];
      }
    }
  } else if (mode == 1) {
    // horizontal
    for (int j = 0; j < 16; j++) {
      for (int i = 0; i < 16; i++) {
        pred[j * 16 + i] = left[j];
      }
    }
  } else if (mode == 2) {
    // DC
    int sum = 0;
    for (int i = 0; i < 16; i++) {
      sum += top[i] + left[i];
    }
    final dc = sum ~/ 32;
    for (int k = 0; k < 256; k++) {
      pred[k] = dc;
    }
  } else {
    // Plane (simplified: average of top & left gradients)
    final base =
        ((top.reduce((a, b) => a + b) + left.reduce((a, b) => a + b)) ~/ 32);
    for (int j = 0; j < 16; j++) {
      for (int i = 0; i < 16; i++) {
        pred[j * 16 + i] = base;
      }
    }
  }
}

/// Add 4x4 residual blocks to prediction and write to frame
void writeIntra16WithResidual({
  required int mbX,
  required int mbY,
  required int width,
  required int height,
  required List<int> pred16,
  required List<List<int>> res4x4, // 16 blocks, each 16 coeff after inv
  required List<int> yPlane,
}) {
  final x0 = mbX * 16;
  final y0 = mbY * 16;

  for (int by = 0; by < 4; by++) {
    for (int bx = 0; bx < 4; bx++) {
      final block = res4x4[by * 4 + bx];
      for (int j = 0; j < 4; j++) {
        final yy = y0 + by * 4 + j;
        if (yy >= height) continue;
        final rowOff = yy * width;
        final predRow = (by * 4 + j) * 16;
        final srcOff = j * 4;
        for (int i = 0; i < 4; i++) {
          final xx = x0 + bx * 4 + i;
          if (xx >= width) continue;
          final predVal = pred16[predRow + bx * 4 + i];
          final val = predVal + block[srcOff + i];
          yPlane[rowOff + xx] = clip8(val);
        }
      }
    }
  }
}
