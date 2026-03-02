import 'dart:typed_data';

int _clip8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

int _roundShiftSigned(int v, int shift) {
  if (shift <= 0) return v;
  final add = 1 << (shift - 1);
  if (v >= 0) return (v + add) >> shift;
  return -(((-v) + add) >> shift);
}

List<int> inverseChromaDc2x2(List<int> dcCoeff) {
  final c0 = dcCoeff.isNotEmpty ? dcCoeff[0] : 0;
  final c1 = dcCoeff.length > 1 ? dcCoeff[1] : 0;
  final c2 = dcCoeff.length > 2 ? dcCoeff[2] : 0;
  final c3 = dcCoeff.length > 3 ? dcCoeff[3] : 0;

  final d0 = c0 + c1 + c2 + c3;
  final d1 = c0 - c1 + c2 - c3;
  final d2 = c0 + c1 - c2 - c3;
  final d3 = c0 - c1 - c2 + c3;

  return <int>[
    _roundShiftSigned(d0, 1),
    _roundShiftSigned(d1, 1),
    _roundShiftSigned(d2, 1),
    _roundShiftSigned(d3, 1),
  ];
}

void mergeChromaDcIntoCoeffBlocks(List<List<int>> coeffBlocks, List<int> dcOut) {
  final n = coeffBlocks.length < 4 ? coeffBlocks.length : 4;
  for (int i = 0; i < n; i++) {
    final b = coeffBlocks[i];
    if (b.isEmpty) continue;
    b[0] = i < dcOut.length ? dcOut[i] : 0;
  }
}

List<int> predictIntraChroma8x8({
  required int mode,
  required Uint8List plane,
  required int width,
  required int height,
  required int mbX,
  required int mbY,
}) {
  final out = List<int>.filled(64, 128);

  final cw = width >> 1;
  final ch = height >> 1;
  final x0 = mbX * 8;
  final y0 = mbY * 8;

  final topAvailable = (y0 > 0);
  final leftAvailable = (x0 > 0);

  final top = List<int>.filled(8, 128);
  final left = List<int>.filled(8, 128);
  int topLeft = 128;

  if (topAvailable) {
    final row = (y0 - 1) * cw;
    int last = 128;
    for (int i = 0; i < 8; i++) {
      final xx = x0 + i;
      if (xx < cw) {
        last = plane[row + xx];
        top[i] = last;
      } else {
        top[i] = last;
      }
    }
  }

  if (leftAvailable) {
    for (int j = 0; j < 8; j++) {
      final yy = y0 + j;
      if (yy < ch) {
        left[j] = plane[yy * cw + (x0 - 1)];
      }
    }
  }

  if (topAvailable && leftAvailable) {
    topLeft = plane[(y0 - 1) * cw + (x0 - 1)];
  }

  int modeClamped = mode;
  if (modeClamped < 0 || modeClamped > 3) modeClamped = 0;

  if (modeClamped == 1) {
    // Horizontal
    for (int y = 0; y < 8; y++) {
      final v = leftAvailable ? left[y] : 128;
      for (int x = 0; x < 8; x++) {
        out[y * 8 + x] = v;
      }
    }
    return out;
  }

  if (modeClamped == 2) {
    // Vertical
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        out[y * 8 + x] = topAvailable ? top[x] : 128;
      }
    }
    return out;
  }

  if (modeClamped == 3 && topAvailable && leftAvailable) {
    // Plane (integer approximation)
    int h = 0;
    int v = 0;
    for (int i = 1; i <= 3; i++) {
      h += i * (top[3 + i] - top[3 - i]);
      v += i * (left[3 + i] - left[3 - i]);
    }
    h += 4 * (top[7] - topLeft);
    v += 4 * (left[7] - topLeft);

    final a = 16 * (top[7] + left[7]);
    final b = (17 * h + 16) >> 5;
    final c = (17 * v + 16) >> 5;

    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        final val = (a + b * (x - 3) + c * (y - 3) + 16) >> 5;
        out[y * 8 + x] = _clip8(val);
      }
    }
    return out;
  }

  // DC mode (or fallback from unsupported plane edges)
  final top0 = top[0] + top[1] + top[2] + top[3];
  final top1 = top[4] + top[5] + top[6] + top[7];
  final left0 = left[0] + left[1] + left[2] + left[3];
  final left1 = left[4] + left[5] + left[6] + left[7];

  int dc00, dc01, dc10, dc11;
  if (topAvailable && leftAvailable) {
    dc00 = (top0 + left0 + 4) >> 3;
    dc01 = (top1 + 2) >> 2;
    dc10 = (left1 + 2) >> 2;
    dc11 = (top1 + left1 + 4) >> 3;
  } else if (topAvailable) {
    dc00 = (top0 + 2) >> 2;
    dc01 = (top1 + 2) >> 2;
    dc10 = dc00;
    dc11 = dc01;
  } else if (leftAvailable) {
    dc00 = (left0 + 2) >> 2;
    dc01 = dc00;
    dc10 = (left1 + 2) >> 2;
    dc11 = dc10;
  } else {
    dc00 = dc01 = dc10 = dc11 = 128;
  }

  for (int y = 0; y < 8; y++) {
    for (int x = 0; x < 8; x++) {
      final right = x >= 4;
      final bottom = y >= 4;
      int vPred;
      if (!right && !bottom) {
        vPred = dc00;
      } else if (right && !bottom) {
        vPred = dc01;
      } else if (!right && bottom) {
        vPred = dc10;
      } else {
        vPred = dc11;
      }
      out[y * 8 + x] = vPred;
    }
  }

  return out;
}
