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
  final w = f.width;
  final h = f.height;
  final out = Uint8List(w * h * 4);

  int o = 0;
  for (int j = 0; j < h; j++) {
    final uvRow = (j >> 1) * (w >> 1);
    final yRow = j * w;
    for (int i = 0; i < w; i++) {
      final yVal = f.y[yRow + i];
      final uvIndex = uvRow + (i >> 1);
      final uVal = f.u[uvIndex];
      final vVal = f.v[uvIndex];

      // BT.601
      final c = yVal - 16;
      final d = uVal - 128;
      final e = vVal - 128;

      int r = ((298 * c + 409 * e + 128) >> 8);
      int g = ((298 * c - 100 * d - 208 * e + 128) >> 8);
      int b = ((298 * c + 516 * d + 128) >> 8);

      if (r < 0)
        r = 0;
      else if (r > 255)
        r = 255;
      if (g < 0)
        g = 0;
      else if (g > 255)
        g = 255;
      if (b < 0)
        b = 0;
      else if (b > 255)
        b = 255;

      out[o++] = r;
      out[o++] = g;
      out[o++] = b;
      out[o++] = 255;
    }
  }
  return out;
}
