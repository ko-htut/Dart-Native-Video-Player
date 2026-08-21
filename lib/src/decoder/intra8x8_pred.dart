/// Filtered neighbouring samples used by H.264 Intra_8x8 luma prediction.
///
/// [top] contains the 16 filtered samples above the block and [left] contains
/// the eight filtered samples to its left. Unavailable entries are set to 128,
/// but callers must use the availability flags rather than treating 128 as a
/// sentinel because it is also a valid reconstructed sample value.
final class H264Intra8x8References {
  const H264Intra8x8References._({
    required this.top,
    required this.left,
    required this.topLeft,
    required this.topAvailable,
    required this.leftAvailable,
    required this.topLeftAvailable,
  });

  final List<int> top;
  final List<int> left;
  final int topLeft;
  final bool topAvailable;
  final bool leftAvailable;
  final bool topLeftAvailable;
}

/// Applies the H.264 Intra_8x8 reference-sample filtering process.
///
/// [top] contains the eight samples above the block followed by the eight
/// top-right samples when [topRightAvailable] is true. If top-right is not
/// available, the eighth top sample is substituted for all eight top-right
/// inputs before filtering, as required by section 8.3.2.2.1.
H264Intra8x8References filterIntra8x8References({
  required List<int> top,
  required List<int> left,
  required int topLeft,
  bool topAvailable = true,
  bool leftAvailable = true,
  bool topLeftAvailable = true,
  bool topRightAvailable = true,
}) {
  if (top.length < 8) {
    throw ArgumentError.value(top.length, 'top.length', 'must be >= 8');
  }
  if (left.length < 8) {
    throw ArgumentError.value(left.length, 'left.length', 'must be >= 8');
  }
  if (topAvailable && topRightAvailable && top.length < 16) {
    throw ArgumentError.value(
      top.length,
      'top.length',
      'must be >= 16 when top-right is available',
    );
  }

  final rawTop = List<int>.filled(16, 128);
  if (topAvailable) {
    for (var index = 0; index < 8; index++) {
      rawTop[index] = top[index];
    }
    if (topRightAvailable) {
      for (var index = 8; index < 16; index++) {
        rawTop[index] = top[index];
      }
    } else {
      for (var index = 8; index < 16; index++) {
        rawTop[index] = rawTop[7];
      }
    }
  }

  final rawLeft = List<int>.filled(8, 128);
  if (leftAvailable) {
    for (var index = 0; index < 8; index++) {
      rawLeft[index] = left[index];
    }
  }

  final filteredTop = List<int>.filled(16, 128);
  if (topAvailable) {
    filteredTop[0] = topLeftAvailable
        ? _quarter(topLeft, rawTop[0], rawTop[1])
        : (3 * rawTop[0] + rawTop[1] + 2) >> 2;
    for (var index = 1; index < 15; index++) {
      filteredTop[index] = _quarter(
        rawTop[index - 1],
        rawTop[index],
        rawTop[index + 1],
      );
    }
    filteredTop[15] = (rawTop[14] + 3 * rawTop[15] + 2) >> 2;
  }

  final filteredLeft = List<int>.filled(8, 128);
  if (leftAvailable) {
    filteredLeft[0] = topLeftAvailable
        ? _quarter(topLeft, rawLeft[0], rawLeft[1])
        : (3 * rawLeft[0] + rawLeft[1] + 2) >> 2;
    for (var index = 1; index < 7; index++) {
      filteredLeft[index] = _quarter(
        rawLeft[index - 1],
        rawLeft[index],
        rawLeft[index + 1],
      );
    }
    filteredLeft[7] = (rawLeft[6] + 3 * rawLeft[7] + 2) >> 2;
  }

  var filteredTopLeft = 128;
  if (topLeftAvailable) {
    if (topAvailable && leftAvailable) {
      filteredTopLeft = _quarter(rawTop[0], topLeft, rawLeft[0]);
    } else if (topAvailable) {
      filteredTopLeft = (3 * topLeft + rawTop[0] + 2) >> 2;
    } else if (leftAvailable) {
      filteredTopLeft = (3 * topLeft + rawLeft[0] + 2) >> 2;
    } else {
      filteredTopLeft = topLeft;
    }
  }

  return H264Intra8x8References._(
    top: List<int>.unmodifiable(filteredTop),
    left: List<int>.unmodifiable(filteredLeft),
    topLeft: filteredTopLeft,
    topAvailable: topAvailable,
    leftAvailable: leftAvailable,
    topLeftAvailable: topLeftAvailable,
  );
}

/// Produces one H.264 8-bit Intra_8x8 luma prediction block.
///
/// Modes 0 through 8 are vertical, horizontal, DC, diagonal-down-left,
/// diagonal-down-right, vertical-right, horizontal-down, vertical-left, and
/// horizontal-up respectively. The input references are filtered internally.
/// A directional mode whose required neighbours are unavailable produces a
/// deterministic 128 concealment block; DC follows the normative availability
/// branches.
void predictIntra8x8({
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
  if (out.length < 64) {
    throw ArgumentError.value(out.length, 'out.length', 'must be >= 64');
  }
  final references = filterIntra8x8References(
    top: top,
    left: left,
    topLeft: topLeft,
    topAvailable: topAvailable,
    leftAvailable: leftAvailable,
    topLeftAvailable: topLeftAvailable,
    topRightAvailable: topRightAvailable,
  );
  final filteredTop = references.top;
  final filteredLeft = references.left;
  final filteredTopLeft = references.topLeft;

  int topRef(int index) => index == -1 ? filteredTopLeft : filteredTop[index];
  int leftRef(int index) => index == -1 ? filteredTopLeft : filteredLeft[index];
  void conceal() => _fill(out, 128);

  switch (mode) {
    case 0: // Vertical.
      if (!topAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          out[row * 8 + column] = filteredTop[column];
        }
      }
      return;
    case 1: // Horizontal.
      if (!leftAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          out[row * 8 + column] = filteredLeft[row];
        }
      }
      return;
    case 2: // DC.
      final int dc;
      if (topAvailable && leftAvailable) {
        var sum = 0;
        for (var index = 0; index < 8; index++) {
          sum += filteredTop[index] + filteredLeft[index];
        }
        dc = (sum + 8) >> 4;
      } else if (topAvailable) {
        dc = (_sum8(filteredTop) + 4) >> 3;
      } else if (leftAvailable) {
        dc = (_sum8(filteredLeft) + 4) >> 3;
      } else {
        dc = 128;
      }
      _fill(out, dc);
      return;
    case 3: // Diagonal down-left.
      if (!topAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          final offset = row + column;
          out[row * 8 + column] = _quarter(
            filteredTop[offset],
            filteredTop[offset + 1],
            offset == 14 ? filteredTop[15] : filteredTop[offset + 2],
          );
        }
      }
      return;
    case 4: // Diagonal down-right.
      if (!topAvailable || !leftAvailable || !topLeftAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          if (column > row) {
            final offset = column - row;
            out[row * 8 + column] = _quarter(
              topRef(offset - 2),
              topRef(offset - 1),
              topRef(offset),
            );
          } else if (column < row) {
            final offset = row - column;
            out[row * 8 + column] = _quarter(
              leftRef(offset - 2),
              leftRef(offset - 1),
              leftRef(offset),
            );
          } else {
            out[row * 8 + column] = _quarter(
              filteredTop[0],
              filteredTopLeft,
              filteredLeft[0],
            );
          }
        }
      }
      return;
    case 5: // Vertical-right.
      if (!topAvailable || !leftAvailable || !topLeftAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          final z = 2 * column - row;
          final int value;
          if (z >= 0 && z.isEven) {
            final offset = column - (row >> 1);
            value = _half(topRef(offset - 1), topRef(offset));
          } else if (z > 0) {
            final offset = column - (row >> 1);
            value = _quarter(
              topRef(offset - 2),
              topRef(offset - 1),
              topRef(offset),
            );
          } else if (z == -1) {
            value = _quarter(filteredLeft[0], filteredTopLeft, filteredTop[0]);
          } else {
            final offset = row - 2 * column;
            value = _quarter(
              leftRef(offset - 1),
              leftRef(offset - 2),
              leftRef(offset - 3),
            );
          }
          out[row * 8 + column] = value;
        }
      }
      return;
    case 6: // Horizontal-down.
      if (!topAvailable || !leftAvailable || !topLeftAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          final z = 2 * row - column;
          final int value;
          if (z >= 0 && z.isEven) {
            final offset = row - (column >> 1);
            value = _half(leftRef(offset - 1), leftRef(offset));
          } else if (z > 0) {
            final offset = row - (column >> 1);
            value = _quarter(
              leftRef(offset - 2),
              leftRef(offset - 1),
              leftRef(offset),
            );
          } else if (z == -1) {
            value = _quarter(filteredLeft[0], filteredTopLeft, filteredTop[0]);
          } else {
            final offset = column - 2 * row;
            value = _quarter(
              topRef(offset - 1),
              topRef(offset - 2),
              topRef(offset - 3),
            );
          }
          out[row * 8 + column] = value;
        }
      }
      return;
    case 7: // Vertical-left.
      if (!topAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          final offset = column + (row >> 1);
          out[row * 8 + column] = row.isEven
              ? _half(filteredTop[offset], filteredTop[offset + 1])
              : _quarter(
                  filteredTop[offset],
                  filteredTop[offset + 1],
                  filteredTop[offset + 2],
                );
        }
      }
      return;
    case 8: // Horizontal-up.
      if (!leftAvailable) {
        conceal();
        return;
      }
      for (var row = 0; row < 8; row++) {
        for (var column = 0; column < 8; column++) {
          final z = column + 2 * row;
          final int value;
          if (z <= 12 && z.isEven) {
            final offset = z >> 1;
            value = _half(filteredLeft[offset], filteredLeft[offset + 1]);
          } else if (z <= 11) {
            final offset = z >> 1;
            value = _quarter(
              filteredLeft[offset],
              filteredLeft[offset + 1],
              filteredLeft[offset + 2],
            );
          } else if (z == 13) {
            value = _quarter(filteredLeft[6], filteredLeft[7], filteredLeft[7]);
          } else {
            value = filteredLeft[7];
          }
          out[row * 8 + column] = value;
        }
      }
      return;
    default:
      conceal();
  }
}

int _half(int a, int b) => (a + b + 1) >> 1;

int _quarter(int a, int b, int c) => (a + 2 * b + c + 2) >> 2;

int _sum8(List<int> values) {
  var sum = 0;
  for (var index = 0; index < 8; index++) {
    sum += values[index];
  }
  return sum;
}

void _fill(List<int> output, int value) {
  for (var index = 0; index < 64; index++) {
    output[index] = value;
  }
}
