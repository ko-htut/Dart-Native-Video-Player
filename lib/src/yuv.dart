import 'dart:typed_data';

class Yuv420Frame {
  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;

  Yuv420Frame({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
  });
}

Uint8List yuv420ToRgba(Yuv420Frame f) {
  return yuv420ToRgbaScaled(f, f.width, f.height);
}

/// Converts planar YUV420 directly into an RGBA buffer of [outputWidth] by
/// [outputHeight], using nearest-neighbour sampling while colors are expanded.
/// This avoids allocating a full-resolution RGBA intermediate when an HLS
/// rendition advertises a smaller display size than its encoded SPS.
Uint8List yuv420ToRgbaScaled(Yuv420Frame f, int outputWidth, int outputHeight) {
  if (outputWidth <= 0 || outputHeight <= 0) {
    throw ArgumentError('RGBA output dimensions must be positive');
  }
  final w = f.width;
  final h = f.height;
  final out = Uint8List(outputWidth * outputHeight * 4);

  int o = 0;
  for (int j = 0; j < outputHeight; j++) {
    final sourceY = j * h ~/ outputHeight;
    final uvRow = (sourceY >> 1) * (w >> 1);
    final yRow = sourceY * w;
    for (int i = 0; i < outputWidth; i++) {
      final sourceX = i * w ~/ outputWidth;
      final yVal = f.y[yRow + sourceX];
      final uvIndex = uvRow + (sourceX >> 1);
      final uVal = f.u[uvIndex];
      final vVal = f.v[uvIndex];

      final c = yVal - 16;
      final d = uVal - 128;
      final e = vVal - 128;

      int r = ((298 * c + 409 * e + 128) >> 8);
      int g = ((298 * c - 100 * d - 208 * e + 128) >> 8);
      int b = ((298 * c + 516 * d + 128) >> 8);

      if (r < 0) {
        r = 0;
      } else if (r > 255) {
        r = 255;
      }
      if (g < 0) {
        g = 0;
      } else if (g > 255) {
        g = 255;
      }
      if (b < 0) {
        b = 0;
      } else if (b > 255) {
        b = 255;
      }

      out[o++] = r;
      out[o++] = g;
      out[o++] = b;
      out[o++] = 255;
    }
  }
  return out;
}
