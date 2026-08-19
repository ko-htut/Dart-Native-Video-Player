int mostProbableIntra4x4Mode({
  required bool leftAvail,
  required bool topAvail,
  required int leftMode,
  required int topMode,
}) {
  // H.264 8.3.1.1: if either neighbouring sample location is unavailable,
  // or its macroblock is not eligible for Intra4x4 prediction, use DC.
  if (!leftAvail || !topAvail) return 2;
  return leftMode < topMode ? leftMode : topMode; // min(left, top)
}

/// Given MPM and rem(0..7), map to final mode:
/// mode = (rem < mpm) ? rem : rem + 1
int mapRemToMode(int mpm, int rem) => (rem < mpm) ? rem : (rem + 1);
