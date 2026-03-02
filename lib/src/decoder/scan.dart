/// H.264 4x4 zigzag scan (spec-style)
/// Maps scan index -> coefficient index in 4x4 raster (y*4+x)
const List<int> zigzag4x4 = <int>[
  0,
  1,
  4,
  8,
  5,
  2,
  3,
  6,
  9,
  12,
  13,
  10,
  7,
  11,
  14,
  15,
];

/// Chroma DC 2x2 scan (simple)
const List<int> scan2x2 = <int>[0, 1, 2, 3];
