import 'dart:typed_data';

const List<int> _dcDequantByQpMod6 = <int>[10, 11, 13, 14, 16, 18];

int _clip8(int value) => value.clamp(0, 255).toInt();

int _clampQp(int qp) => qp.clamp(0, 51).toInt();

/// Inverse-transforms and scales a 4:2:0 chroma DC 2x2 block.
///
/// The result contains the already-scaled DC coefficient for each chroma 4x4
/// block in raster order. Pass those coefficients to [invTransform4x4] with
/// `dcAlreadyScaled: true`; applying ordinary 4x4 dequantisation to them again
/// would double-scale the chroma DC component.
List<int> inverseChromaDc2x2(List<int> dcCoeff, {int qp = 26}) {
  final c0 = dcCoeff.isNotEmpty ? dcCoeff[0] : 0;
  final c1 = dcCoeff.length > 1 ? dcCoeff[1] : 0;
  final c2 = dcCoeff.length > 2 ? dcCoeff[2] : 0;
  final c3 = dcCoeff.length > 3 ? dcCoeff[3] : 0;

  final transformed = <int>[
    c0 + c1 + c2 + c3,
    c0 - c1 + c2 - c3,
    c0 + c1 - c2 - c3,
    c0 - c1 - c2 + c3,
  ];

  final q = _clampQp(qp);
  final qpDiv6 = q ~/ 6;
  // Baseline profile uses the flat scaling list (weight 16). LevelScale is
  // therefore normAdjust * 16.
  final levelScale = _dcDequantByQpMod6[q % 6] << 4;
  return <int>[
    for (final value in transformed) ((value * levelScale) << qpDiv6) >> 5,
  ];
}

void mergeChromaDcIntoCoeffBlocks(
  List<List<int>> coeffBlocks,
  List<int> dcOut,
) {
  final count = coeffBlocks.length < 4 ? coeffBlocks.length : 4;
  for (var i = 0; i < count; i++) {
    if (coeffBlocks[i].isNotEmpty) {
      coeffBlocks[i][0] = i < dcOut.length ? dcOut[i] : 0;
    }
  }
}

/// Produces an H.264 8-bit 4:2:0 intra chroma prediction block.
///
/// [width] and [height] are luma dimensions; [plane] is the half-resolution
/// Cb or Cr plane. Availability overrides let the slice decoder account for
/// slice boundaries and constrained intra prediction.
List<int> predictIntraChroma8x8({
  required int mode,
  required Uint8List plane,
  required int width,
  required int height,
  required int mbX,
  required int mbY,
  bool? topAvailable,
  bool? leftAvailable,
  bool? topLeftAvailable,
}) {
  if (width <= 0 || height <= 0 || width.isOdd || height.isOdd) {
    throw ArgumentError('4:2:0 luma dimensions must be positive and even.');
  }

  final chromaWidth = width >> 1;
  final chromaHeight = height >> 1;
  if (plane.length < chromaWidth * chromaHeight) {
    throw ArgumentError('The chroma plane dimensions are invalid.');
  }

  final x0 = mbX * 8;
  final y0 = mbY * 8;
  final geometryHasTop = y0 > 0 && x0 >= 0 && x0 + 7 < chromaWidth;
  final geometryHasLeft = x0 > 0 && y0 >= 0 && y0 + 7 < chromaHeight;
  final hasTop = (topAvailable ?? geometryHasTop) && geometryHasTop;
  final hasLeft = (leftAvailable ?? geometryHasLeft) && geometryHasLeft;
  final hasTopLeft =
      (topLeftAvailable ?? (hasTop && hasLeft)) && hasTop && hasLeft;

  final top = List<int>.filled(8, 128);
  final left = List<int>.filled(8, 128);
  if (hasTop) {
    final row = (y0 - 1) * chromaWidth + x0;
    for (var x = 0; x < 8; x++) {
      top[x] = plane[row + x];
    }
  }
  if (hasLeft) {
    for (var y = 0; y < 8; y++) {
      left[y] = plane[(y0 + y) * chromaWidth + x0 - 1];
    }
  }

  final output = List<int>.filled(64, 128);

  int sum4(List<int> samples, int offset) =>
      samples[offset] +
      samples[offset + 1] +
      samples[offset + 2] +
      samples[offset + 3];

  void fillQuadrant(int x0, int y0, int value) {
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        output[(y0 + y) * 8 + x0 + x] = value;
      }
    }
  }

  void predictDc() {
    final top0 = sum4(top, 0);
    final top1 = sum4(top, 4);
    final left0 = sum4(left, 0);
    final left1 = sum4(left, 4);

    final int dc00;
    final int dc01;
    final int dc10;
    final int dc11;
    if (hasTop && hasLeft) {
      dc00 = (top0 + left0 + 4) >> 3;
      dc01 = (top1 + 2) >> 2;
      dc10 = (left1 + 2) >> 2;
      dc11 = (top1 + left1 + 4) >> 3;
    } else if (hasTop) {
      dc00 = (top0 + 2) >> 2;
      dc01 = (top1 + 2) >> 2;
      dc10 = dc00;
      dc11 = dc01;
    } else if (hasLeft) {
      dc00 = (left0 + 2) >> 2;
      dc01 = dc00;
      dc10 = (left1 + 2) >> 2;
      dc11 = dc10;
    } else {
      dc00 = 128;
      dc01 = 128;
      dc10 = 128;
      dc11 = 128;
    }

    fillQuadrant(0, 0, dc00);
    fillQuadrant(4, 0, dc01);
    fillQuadrant(0, 4, dc10);
    fillQuadrant(4, 4, dc11);
  }

  switch (mode) {
    case 0: // DC
      predictDc();
      return output;
    case 1: // Horizontal
      if (!hasLeft) {
        predictDc();
        return output;
      }
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          output[y * 8 + x] = left[y];
        }
      }
      return output;
    case 2: // Vertical
      if (!hasTop) {
        predictDc();
        return output;
      }
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          output[y * 8 + x] = top[x];
        }
      }
      return output;
    case 3: // Plane
      if (!hasTop || !hasLeft || !hasTopLeft) {
        predictDc();
        return output;
      }

      final topLeft = plane[(y0 - 1) * chromaWidth + x0 - 1];
      var horizontalGradient = 0;
      var verticalGradient = 0;
      for (var i = 1; i <= 3; i++) {
        horizontalGradient += i * (top[3 + i] - top[3 - i]);
        verticalGradient += i * (left[3 + i] - left[3 - i]);
      }
      horizontalGradient += 4 * (top[7] - topLeft);
      verticalGradient += 4 * (left[7] - topLeft);

      final a = 16 * (top[7] + left[7]);
      final b = (34 * horizontalGradient + 32) >> 6;
      final c = (34 * verticalGradient + 32) >> 6;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          output[y * 8 + x] = _clip8((a + b * (x - 3) + c * (y - 3) + 16) >> 5);
        }
      }
      return output;
    default:
      predictDc();
      return output;
  }
}
