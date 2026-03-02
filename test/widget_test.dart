import 'dart:typed_data';

Uint8List makeTestRgba(int w, int h) {
  final out = Uint8List(w * h * 4);
  int o = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out[o++] = (x * 255 ~/ w); // R gradient
      out[o++] = (y * 255 ~/ h); // G gradient
      out[o++] = 0;
      out[o++] = 255;
    }
  }
  return out;
}
