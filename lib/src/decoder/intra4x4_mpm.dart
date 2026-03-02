int mostProbableIntra4x4Mode({
  required bool leftAvail,
  required bool topAvail,
  required int leftMode,
  required int topMode,
}) {
  if (!leftAvail && !topAvail) return 2; // DC default
  if (!leftAvail) return topMode;
  if (!topAvail) return leftMode;
  return leftMode < topMode ? leftMode : topMode; // min(left, top)
}

/// Given MPM and rem(0..7), map to final mode:
/// mode = (rem < mpm) ? rem : rem + 1
int mapRemToMode(int mpm, int rem) => (rem < mpm) ? rem : (rem + 1);
