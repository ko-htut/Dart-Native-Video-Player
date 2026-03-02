class NcContext {
  final int mbWidth;
  final int mbHeight;
  final List<int> lumaTc; // [mb][block16]
  final List<int> lumaDcTc; // [mb] Intra16x16 DC TotalCoeff context
  final List<int> chromaTcU; // [mb][block4] U component
  final List<int> chromaTcV; // [mb][block4] V component

  NcContext({required this.mbWidth, required this.mbHeight})
    : lumaTc = List.filled(mbWidth * mbHeight * 16, 0),
      lumaDcTc = List.filled(mbWidth * mbHeight, 0),
      chromaTcU = List.filled(mbWidth * mbHeight * 4, 0),
      chromaTcV = List.filled(mbWidth * mbHeight * 4, 0);

  int _mbBase16(int mbX, int mbY) => (mbY * mbWidth + mbX) * 16;
  int _mbBase4(int mbX, int mbY) => (mbY * mbWidth + mbX) * 4;

  int getLuma(int mbX, int mbY, int blk) => lumaTc[_mbBase16(mbX, mbY) + blk];
  void setLuma(int mbX, int mbY, int blk, int tc) =>
      lumaTc[_mbBase16(mbX, mbY) + blk] = tc;
  int getLumaDc(int mbX, int mbY) => lumaDcTc[mbY * mbWidth + mbX];
  void setLumaDc(int mbX, int mbY, int tc) => lumaDcTc[mbY * mbWidth + mbX] = tc;

  // Backward-compatible aliases map to U.
  int getChroma(int mbX, int mbY, int blk) =>
      chromaTcU[_mbBase4(mbX, mbY) + blk];
  void setChroma(int mbX, int mbY, int blk, int tc) =>
      chromaTcU[_mbBase4(mbX, mbY) + blk] = tc;

  int getChromaU(int mbX, int mbY, int blk) =>
      chromaTcU[_mbBase4(mbX, mbY) + blk];
  int getChromaV(int mbX, int mbY, int blk) =>
      chromaTcV[_mbBase4(mbX, mbY) + blk];
  void setChromaU(int mbX, int mbY, int blk, int tc) =>
      chromaTcU[_mbBase4(mbX, mbY) + blk] = tc;
  void setChromaV(int mbX, int mbY, int blk, int tc) =>
      chromaTcV[_mbBase4(mbX, mbY) + blk] = tc;

  int calcNCForLuma4x4(int mbX, int mbY, int bx, int by) {
    int? left;
    int? top;

    if (bx > 0) {
      left = getLuma(mbX, mbY, by * 4 + (bx - 1));
    } else if (mbX > 0) {
      left = getLuma(mbX - 1, mbY, by * 4 + 3);
    }

    if (by > 0) {
      top = getLuma(mbX, mbY, (by - 1) * 4 + bx);
    } else if (mbY > 0) {
      top = getLuma(mbX, mbY - 1, 12 + bx);
    }

    if (left == null && top == null) return 0;
    if (left == null) return top ?? 0;
    if (top == null) return left;
    return ((left + top + 1) >> 1);
  }

  int calcNCForLuma16Dc(int mbX, int mbY) {
    int? left;
    int? top;

    if (mbX > 0) {
      left = getLumaDc(mbX - 1, mbY);
    }
    if (mbY > 0) {
      top = getLumaDc(mbX, mbY - 1);
    }

    if (left == null && top == null) return 0;
    if (left == null) return top ?? 0;
    if (top == null) return left;
    return ((left + top + 1) >> 1);
  }

  int calcNCForChroma4x4({
    required int mbX,
    required int mbY,
    required int bx,
    required int by,
    required bool isU,
  }) {
    int getTc(int x, int y, int blk) =>
        isU ? getChromaU(x, y, blk) : getChromaV(x, y, blk);

    int? left;
    int? top;

    // bx/by are in 0..1 for each 8x8 chroma MB's 4x4 sub-blocks.
    if (bx > 0) {
      left = getTc(mbX, mbY, by * 2 + (bx - 1));
    } else if (mbX > 0) {
      left = getTc(mbX - 1, mbY, by * 2 + 1);
    }

    if (by > 0) {
      top = getTc(mbX, mbY, (by - 1) * 2 + bx);
    } else if (mbY > 0) {
      top = getTc(mbX, mbY - 1, 2 + bx);
    }

    if (left == null && top == null) return 0;
    if (left == null) return top ?? 0;
    if (top == null) return left;
    return ((left + top + 1) >> 1);
  }
}
