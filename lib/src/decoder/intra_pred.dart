int clip8(int value) => value.clamp(0, 255).toInt();

void _fill(List<int> output, int count, int value) {
  for (var i = 0; i < count; i++) {
    output[i] = value;
  }
}

int _average(List<int> samples, int count, int rounding) {
  var sum = 0;
  for (var i = 0; i < count; i++) {
    sum += samples[i];
  }
  return (sum + rounding) ~/ count;
}

/// Produces an H.264 8-bit Intra_16x16 luma prediction block.
///
/// [topAvailable], [leftAvailable], and [topLeftAvailable] may be supplied by
/// the slice decoder when picture geometry alone is insufficient (for example,
/// at a slice boundary or with constrained intra prediction). When omitted,
/// availability is inferred from the macroblock position.
void predictIntra16({
  required int mode,
  required int mbX,
  required int mbY,
  required int width,
  required int height,
  required List<int> yPlane,
  required List<int> out16,
  bool? topAvailable,
  bool? leftAvailable,
  bool? topLeftAvailable,
}) {
  if (width <= 0 || height <= 0 || yPlane.length < width * height) {
    throw ArgumentError('The luma plane dimensions are invalid.');
  }
  if (out16.length < 256) {
    throw ArgumentError.value(out16.length, 'out16.length', 'must be >= 256');
  }

  final x0 = mbX * 16;
  final y0 = mbY * 16;
  final geometryHasTop = y0 > 0 && x0 >= 0 && x0 + 15 < width;
  final geometryHasLeft = x0 > 0 && y0 >= 0 && y0 + 15 < height;
  final hasTop = (topAvailable ?? geometryHasTop) && geometryHasTop;
  final hasLeft = (leftAvailable ?? geometryHasLeft) && geometryHasLeft;
  final hasTopLeft =
      (topLeftAvailable ?? (hasTop && hasLeft)) && hasTop && hasLeft;

  final top = List<int>.filled(16, 128);
  final left = List<int>.filled(16, 128);
  if (hasTop) {
    final row = (y0 - 1) * width + x0;
    for (var x = 0; x < 16; x++) {
      top[x] = yPlane[row + x];
    }
  }
  if (hasLeft) {
    for (var y = 0; y < 16; y++) {
      left[y] = yPlane[(y0 + y) * width + x0 - 1];
    }
  }

  void predictDc() {
    final int dc;
    if (hasTop && hasLeft) {
      var sum = 0;
      for (var i = 0; i < 16; i++) {
        sum += top[i] + left[i];
      }
      dc = (sum + 16) >> 5;
    } else if (hasTop) {
      dc = _average(top, 16, 8);
    } else if (hasLeft) {
      dc = _average(left, 16, 8);
    } else {
      dc = 128;
    }
    _fill(out16, 256, dc);
  }

  switch (mode) {
    case 0: // Vertical
      if (!hasTop) {
        predictDc();
        return;
      }
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          out16[y * 16 + x] = top[x];
        }
      }
      return;
    case 1: // Horizontal
      if (!hasLeft) {
        predictDc();
        return;
      }
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          out16[y * 16 + x] = left[y];
        }
      }
      return;
    case 2: // DC
      predictDc();
      return;
    case 3: // Plane
      if (!hasTop || !hasLeft || !hasTopLeft) {
        predictDc();
        return;
      }

      final topLeft = yPlane[(y0 - 1) * width + x0 - 1];
      var horizontalGradient = 0;
      var verticalGradient = 0;
      for (var i = 1; i <= 7; i++) {
        horizontalGradient += i * (top[7 + i] - top[7 - i]);
        verticalGradient += i * (left[7 + i] - left[7 - i]);
      }
      horizontalGradient += 8 * (top[15] - topLeft);
      verticalGradient += 8 * (left[15] - topLeft);

      final a = 16 * (top[15] + left[15]);
      final b = (5 * horizontalGradient + 32) >> 6;
      final c = (5 * verticalGradient + 32) >> 6;
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          out16[y * 16 + x] = clip8((a + b * (x - 7) + c * (y - 7) + 16) >> 5);
        }
      }
      return;
    default:
      // Invalid modes cannot occur in a conforming bitstream. DC provides a
      // deterministic concealment result without reading unavailable samples.
      predictDc();
  }
}

/// Produces one H.264 8-bit Intra_4x4 luma prediction block.
///
/// [top] contains A..H and [left] contains I..L. If the top-right neighbour is
/// unavailable, E..H are substituted with D as required by H.264 section
/// 8.3.1.2. Explicit availability is necessary at slice boundaries because a
/// sample value of 128 is not an availability marker.
void predictIntra4x4({
  required int mode,
  required List<int> top,
  required List<int> left,
  required int topLeft,
  required List<int> out,
  bool topAvailable = true,
  bool leftAvailable = true,
  bool topLeftAvailable = true,
  bool topRightAvailable = true,
}) {
  if (top.length < 4) {
    throw ArgumentError.value(top.length, 'top.length', 'must be >= 4');
  }
  if (left.length < 4) {
    throw ArgumentError.value(left.length, 'left.length', 'must be >= 4');
  }
  if (out.length < 16) {
    throw ArgumentError.value(out.length, 'out.length', 'must be >= 16');
  }

  final topSamples = List<int>.filled(8, 128);
  if (topAvailable) {
    for (var i = 0; i < 4; i++) {
      topSamples[i] = top[i];
    }
    for (var i = 4; i < 8; i++) {
      topSamples[i] = topRightAvailable && i < top.length
          ? top[i]
          : topSamples[3];
    }
  }
  final leftSamples = List<int>.filled(4, 128);
  if (leftAvailable) {
    for (var i = 0; i < 4; i++) {
      leftSamples[i] = left[i];
    }
  }
  final xSample = topLeftAvailable ? topLeft : 128;

  int topRef(int index) => index == -1 ? xSample : topSamples[index];
  int leftRef(int index) => index == -1 ? xSample : leftSamples[index];
  int half(int a, int b) => (a + b + 1) >> 1;
  int quarter(int a, int b, int c) => (a + 2 * b + c + 2) >> 2;

  void conceal() => _fill(out, 16, 128);

  switch (mode) {
    case 0: // Vertical
      if (!topAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          out[y * 4 + x] = topSamples[x];
        }
      }
      return;
    case 1: // Horizontal
      if (!leftAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          out[y * 4 + x] = leftSamples[y];
        }
      }
      return;
    case 2: // DC
      final int dc;
      if (topAvailable && leftAvailable) {
        var sum = 0;
        for (var i = 0; i < 4; i++) {
          sum += topSamples[i] + leftSamples[i];
        }
        dc = (sum + 4) >> 3;
      } else if (topAvailable) {
        dc = _average(topSamples, 4, 2);
      } else if (leftAvailable) {
        dc = _average(leftSamples, 4, 2);
      } else {
        dc = 128;
      }
      _fill(out, 16, dc);
      return;
    case 3: // Diagonal down-left
      if (!topAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final offset = x + y;
          out[y * 4 + x] = quarter(
            topSamples[offset],
            topSamples[offset + 1],
            offset == 6 ? topSamples[7] : topSamples[offset + 2],
          );
        }
      }
      return;
    case 4: // Diagonal down-right
      if (!topAvailable || !leftAvailable || !topLeftAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          if (x > y) {
            final offset = x - y;
            out[y * 4 + x] = quarter(
              topRef(offset - 2),
              topRef(offset - 1),
              topRef(offset),
            );
          } else if (x < y) {
            final offset = y - x;
            out[y * 4 + x] = quarter(
              leftRef(offset - 2),
              leftRef(offset - 1),
              leftRef(offset),
            );
          } else {
            out[y * 4 + x] = quarter(topSamples[0], xSample, leftSamples[0]);
          }
        }
      }
      return;
    case 5: // Vertical-right
      if (!topAvailable || !leftAvailable || !topLeftAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final z = 2 * x - y;
          final int value;
          if (z >= 0 && z.isEven) {
            final offset = x - (y >> 1);
            value = half(topRef(offset - 1), topRef(offset));
          } else if (z > 0) {
            final offset = x - (y >> 1);
            value = quarter(
              topRef(offset - 2),
              topRef(offset - 1),
              topRef(offset),
            );
          } else if (z == -1) {
            value = quarter(leftSamples[0], xSample, topSamples[0]);
          } else {
            value = quarter(leftRef(y - 1), leftRef(y - 2), leftRef(y - 3));
          }
          out[y * 4 + x] = value;
        }
      }
      return;
    case 6: // Horizontal-down
      if (!topAvailable || !leftAvailable || !topLeftAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final z = 2 * y - x;
          final int value;
          if (z >= 0 && z.isEven) {
            final offset = y - (x >> 1);
            value = half(leftRef(offset - 1), leftRef(offset));
          } else if (z > 0) {
            final offset = y - (x >> 1);
            value = quarter(
              leftRef(offset - 2),
              leftRef(offset - 1),
              leftRef(offset),
            );
          } else if (z == -1) {
            value = quarter(leftSamples[0], xSample, topSamples[0]);
          } else {
            value = quarter(topRef(x - 1), topRef(x - 2), topRef(x - 3));
          }
          out[y * 4 + x] = value;
        }
      }
      return;
    case 7: // Vertical-left
      if (!topAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final offset = x + (y >> 1);
          out[y * 4 + x] = y.isEven
              ? half(topSamples[offset], topSamples[offset + 1])
              : quarter(
                  topSamples[offset],
                  topSamples[offset + 1],
                  topSamples[offset + 2],
                );
        }
      }
      return;
    case 8: // Horizontal-up
      if (!leftAvailable) {
        conceal();
        return;
      }
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final z = x + 2 * y;
          final int value;
          if (z == 0 || z == 2 || z == 4) {
            value = half(
              leftSamples[y + (x >> 1)],
              leftSamples[y + (x >> 1) + 1],
            );
          } else if (z == 1 || z == 3) {
            final offset = y + (x >> 1);
            value = quarter(
              leftSamples[offset],
              leftSamples[offset + 1],
              leftSamples[offset + 2],
            );
          } else if (z == 5) {
            value = quarter(leftSamples[2], leftSamples[3], leftSamples[3]);
          } else {
            value = leftSamples[3];
          }
          out[y * 4 + x] = value;
        }
      }
      return;
    default:
      conceal();
  }
}
