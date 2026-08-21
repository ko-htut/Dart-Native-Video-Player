int mostProbableIntra4x4Mode({
  required bool leftAvail,
  required bool topAvail,
  required int leftMode,
  required int topMode,
}) {
  // H.264 8.3.1.1: if either neighbouring sample location is unavailable,
  // use DC. Available Intra8x8 neighbours contribute the mode of the 8x8
  // block containing the neighbouring 4x4 location.
  if (!leftAvail || !topAvail) return 2;
  return leftMode < topMode ? leftMode : topMode; // min(left, top)
}

/// Maps a 4x4 luma-block location inside a macroblock to its containing 8x8
/// luma block for cross-transform Intra prediction-mode derivation.
int intra8x8BlockIndexForIntra4x4Neighbour({
  required int blockX,
  required int blockY,
}) {
  if (blockX < 0 || blockX > 3) {
    throw RangeError.range(blockX, 0, 3, 'blockX');
  }
  if (blockY < 0 || blockY > 3) {
    throw RangeError.range(blockY, 0, 3, 'blockY');
  }
  return (blockY >> 1) * 2 + (blockX >> 1);
}

enum Intra8x8NeighbourSide { left, top }

/// Selects the facing 4x4 luma mode when an Intra8x8 block derives its most
/// probable mode from an Intra4x4 neighbour macroblock.
int intra4x4BlockIndexForIntra8x8Neighbour({
  required int blockX,
  required int blockY,
  required Intra8x8NeighbourSide side,
}) {
  if (blockX < 0 || blockX > 1) {
    throw RangeError.range(blockX, 0, 1, 'blockX');
  }
  if (blockY < 0 || blockY > 1) {
    throw RangeError.range(blockY, 0, 1, 'blockY');
  }
  final block4x4X = blockX * 2 + (side == Intra8x8NeighbourSide.left ? 1 : 0);
  final block4x4Y = blockY * 2 + (side == Intra8x8NeighbourSide.top ? 1 : 0);
  return block4x4Y * 4 + block4x4X;
}

/// Given MPM and rem(0..7), map to final mode:
/// mode = (rem < mpm) ? rem : rem + 1
int mapRemToMode(int mpm, int rem) => (rem < mpm) ? rem : (rem + 1);
