import 'dart:typed_data';

/// A motion vector in quarter-luma-sample units.
///
/// For 4:2:0 pictures the same integer components are eighth-chroma-sample
/// units, as required by H.264 section 8.4.2.2.
class MotionVector {
  final int x;
  final int y;

  const MotionVector(this.x, this.y);

  static const zero = MotionVector(0, 0);

  MotionVector operator +(MotionVector other) =>
      MotionVector(x + other.x, y + other.y);

  @override
  bool operator ==(Object other) =>
      other is MotionVector && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'MotionVector($x, $y)';
}

/// Motion information associated with one luma 4x4 block.
///
/// [available] is deliberately distinct from [referenceIndex]. An intra block
/// is available but has a reference index of -1, while an unavailable block
/// (outside the picture, in another slice, or not decoded yet) cannot be used
/// as neighbour C and therefore triggers the normative C-to-D substitution.
class MotionFieldEntry {
  final MotionVector vector;
  final int referenceIndex;
  final bool available;
  final int sliceId;

  const MotionFieldEntry({
    required this.vector,
    required this.referenceIndex,
    this.available = true,
    this.sliceId = 0,
  });

  const MotionFieldEntry.intra({this.sliceId = 0})
    : vector = MotionVector.zero,
      referenceIndex = -1,
      available = true;

  static const unavailable = MotionFieldEntry(
    vector: MotionVector.zero,
    referenceIndex: -1,
    available: false,
    sliceId: -1,
  );

  bool hasReference(int index) => available && referenceIndex == index;

  bool get isZeroReferenceZero =>
      available && referenceIndex == 0 && vector == MotionVector.zero;

  @override
  String toString() => available
      ? 'MotionFieldEntry(vector: $vector, ref: $referenceIndex, '
            'slice: $sliceId)'
      : 'MotionFieldEntry.unavailable';
}

/// Frame-level list-0 motion field, stored at H.264's 4x4 luma granularity.
class MotionFieldGrid {
  final int widthIn4x4;
  final int heightIn4x4;
  final List<MotionFieldEntry> _entries;

  MotionFieldGrid({required this.widthIn4x4, required this.heightIn4x4})
    : _entries = List<MotionFieldEntry>.filled(
        _checkedGridLength(widthIn4x4, heightIn4x4),
        MotionFieldEntry.unavailable,
      );

  factory MotionFieldGrid.forLumaSize({
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0 || width.isOdd || height.isOdd) {
      throw ArgumentError('Luma dimensions must be positive and even.');
    }
    if ((width & 3) != 0 || (height & 3) != 0) {
      throw ArgumentError('Motion-field dimensions must be multiples of 4.');
    }
    return MotionFieldGrid(widthIn4x4: width >> 2, heightIn4x4: height >> 2);
  }

  static int _checkedGridLength(int width, int height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Motion-field dimensions must be positive.');
    }
    return width * height;
  }

  /// Returns an unavailable entry for out-of-picture or cross-slice access.
  MotionFieldEntry entryAt4x4(int blockX, int blockY, {int? currentSliceId}) {
    if (blockX < 0 ||
        blockY < 0 ||
        blockX >= widthIn4x4 ||
        blockY >= heightIn4x4) {
      return MotionFieldEntry.unavailable;
    }
    final entry = _entries[blockY * widthIn4x4 + blockX];
    if (!entry.available ||
        (currentSliceId != null && entry.sliceId != currentSliceId)) {
      return MotionFieldEntry.unavailable;
    }
    return entry;
  }

  /// Returns the entry covering the supplied integer luma-sample coordinate.
  MotionFieldEntry entryAtLuma(int x, int y, {int? currentSliceId}) =>
      entryAt4x4(
        _floorDiv(x, 4),
        _floorDiv(y, 4),
        currentSliceId: currentSliceId,
      );

  /// Fills every 4x4 block covered by an inter partition.
  void setPartition({
    required int x,
    required int y,
    required int width,
    required int height,
    required MotionVector vector,
    required int referenceIndex,
    int sliceId = 0,
  }) {
    if (referenceIndex < 0) {
      throw ArgumentError.value(
        referenceIndex,
        'referenceIndex',
        'must be non-negative for an inter partition',
      );
    }
    _fillPartition(
      x: x,
      y: y,
      width: width,
      height: height,
      value: MotionFieldEntry(
        vector: vector,
        referenceIndex: referenceIndex,
        sliceId: sliceId,
      ),
    );
  }

  /// Marks an intra region as available while retaining refIdx = -1.
  void setIntraPartition({
    required int x,
    required int y,
    required int width,
    required int height,
    int sliceId = 0,
  }) {
    _fillPartition(
      x: x,
      y: y,
      width: width,
      height: height,
      value: MotionFieldEntry.intra(sliceId: sliceId),
    );
  }

  void _fillPartition({
    required int x,
    required int y,
    required int width,
    required int height,
    required MotionFieldEntry value,
  }) {
    _validatePartitionGeometry(x, y, width, height);
    final x4 = x >> 2;
    final y4 = y >> 2;
    final width4 = width >> 2;
    final height4 = height >> 2;
    if (x4 + width4 > widthIn4x4 || y4 + height4 > heightIn4x4) {
      throw RangeError('Motion partition extends outside the grid.');
    }
    for (var blockY = y4; blockY < y4 + height4; blockY++) {
      final row = blockY * widthIn4x4;
      for (var blockX = x4; blockX < x4 + width4; blockX++) {
        _entries[row + blockX] = value;
      }
    }
  }

  void clear() {
    _entries.fillRange(0, _entries.length, MotionFieldEntry.unavailable);
  }
}

/// Macroblock partition shapes which have special MVP selection rules.
enum InterPartitionKind {
  p16x16,
  p16x8,
  p8x16,

  /// P_8x8 and its 8x8, 8x4, 4x8, or 4x4 sub-macroblock partitions.
  subMacroblock,
}

/// Derives mvL0 prediction for a P macroblock partition.
///
/// Coordinates are absolute integer luma-sample coordinates. [partitionIndex]
/// is 0/1 for P_16x8 and P_8x16. P_8x8 subpartitions use the ordinary
/// reference-match/median rule and may leave it at zero.
MotionVector deriveMotionVectorPredictor({
  required MotionFieldGrid grid,
  required int partitionX,
  required int partitionY,
  required int partitionWidth,
  required int partitionHeight,
  required int referenceIndex,
  required InterPartitionKind partitionKind,
  int partitionIndex = 0,
  int? currentSliceId,
}) {
  _validatePartitionGeometry(
    partitionX,
    partitionY,
    partitionWidth,
    partitionHeight,
  );
  if (referenceIndex < 0) {
    throw ArgumentError.value(referenceIndex, 'referenceIndex');
  }
  if ((partitionKind == InterPartitionKind.p16x8 ||
          partitionKind == InterPartitionKind.p8x16) &&
      (partitionIndex < 0 || partitionIndex > 1)) {
    throw ArgumentError.value(partitionIndex, 'partitionIndex');
  }

  // H.264 8.4.1.3: A is immediately left of the partition's top-left
  // sample, B is directly above it, and C is above-right. D substitutes for
  // C only when C is unavailable (an available intra C does not trigger it).
  final a = grid.entryAtLuma(
    partitionX - 1,
    partitionY,
    currentSliceId: currentSliceId,
  );
  var b = grid.entryAtLuma(
    partitionX,
    partitionY - 1,
    currentSliceId: currentSliceId,
  );
  var c = grid.entryAtLuma(
    partitionX + partitionWidth,
    partitionY - 1,
    currentSliceId: currentSliceId,
  );
  if (!c.available) {
    c = grid.entryAtLuma(
      partitionX - 1,
      partitionY - 1,
      currentSliceId: currentSliceId,
    );
  }

  if (partitionKind == InterPartitionKind.p16x8) {
    final preferred = partitionIndex == 0 ? b : a;
    if (preferred.hasReference(referenceIndex)) return preferred.vector;
  } else if (partitionKind == InterPartitionKind.p8x16) {
    final preferred = partitionIndex == 0 ? a : c;
    if (preferred.hasReference(referenceIndex)) return preferred.vector;
  }

  // H.264 8.4.1.3.1 first replicates A when it is the only available
  // candidate. This matters when A's reference index differs from that of the
  // current partition: applying the ordinary reference-match rule directly
  // would incorrectly median A with two zero vectors.
  if (!b.available && !c.available && a.available) {
    b = a;
    c = a;
  }

  final aMatches = a.hasReference(referenceIndex);
  final bMatches = b.hasReference(referenceIndex);
  final cMatches = c.hasReference(referenceIndex);
  final matchCount =
      (aMatches ? 1 : 0) + (bMatches ? 1 : 0) + (cMatches ? 1 : 0);
  if (matchCount == 1) {
    if (aMatches) return a.vector;
    if (bMatches) return b.vector;
    return c.vector;
  }

  return MotionVector(
    _median3(a.vector.x, b.vector.x, c.vector.x),
    _median3(a.vector.y, b.vector.y, c.vector.y),
  );
}

/// Derives the inferred list-0 motion vector for a P_Skip macroblock.
MotionVector derivePSkipMotionVector({
  required MotionFieldGrid grid,
  required int macroblockX,
  required int macroblockY,
  int? currentSliceId,
}) {
  if ((macroblockX & 15) != 0 || (macroblockY & 15) != 0) {
    throw ArgumentError('P_Skip coordinates must be macroblock-aligned.');
  }
  final a = grid.entryAtLuma(
    macroblockX - 1,
    macroblockY,
    currentSliceId: currentSliceId,
  );
  final b = grid.entryAtLuma(
    macroblockX,
    macroblockY - 1,
    currentSliceId: currentSliceId,
  );
  if (!a.available ||
      !b.available ||
      a.isZeroReferenceZero ||
      b.isZeroReferenceZero) {
    return MotionVector.zero;
  }
  return deriveMotionVectorPredictor(
    grid: grid,
    partitionX: macroblockX,
    partitionY: macroblockY,
    partitionWidth: 16,
    partitionHeight: 16,
    referenceIndex: 0,
    partitionKind: InterPartitionKind.p16x16,
    currentSliceId: currentSliceId,
  );
}

/// A validated planar 8-bit YUV 4:2:0 picture buffer.
///
/// Strides are explicit so a cropped display frame can still use coded-picture
/// storage. [width] and [height] describe the addressable coded picture.
class Yuv420PictureBuffer {
  final int width;
  final int height;
  final int lumaStride;
  final int chromaStride;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;

  Yuv420PictureBuffer({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    int? lumaStride,
    int? chromaStride,
  }) : lumaStride = lumaStride ?? width,
       chromaStride = chromaStride ?? (width >> 1) {
    if (width <= 0 || height <= 0 || width.isOdd || height.isOdd) {
      throw ArgumentError('YUV420 dimensions must be positive and even.');
    }
    if (this.lumaStride < width || this.chromaStride < (width >> 1)) {
      throw ArgumentError('Plane stride is smaller than the picture width.');
    }
    if (y.length < this.lumaStride * height ||
        u.length < this.chromaStride * (height >> 1) ||
        v.length < this.chromaStride * (height >> 1)) {
      throw ArgumentError('A YUV420 plane is smaller than its dimensions.');
    }
  }
}

/// Returns one 8-bit luma prediction sample at quarter-pel coordinates.
///
/// The six-tap filter, intermediate precision, rounding, and edge extension
/// follow H.264 section 8.4.2.2.1.
int interpolateLumaQuarterPel({
  required Uint8List plane,
  required int width,
  required int height,
  required int xQuarter,
  required int yQuarter,
  int? stride,
}) => _LumaSampler(
  plane,
  width,
  height,
  stride ?? width,
).sample(xQuarter, yQuarter);

/// Returns one 8-bit 4:2:0 chroma prediction sample at eighth-pel coordinates.
int interpolateChromaEighthPel({
  required Uint8List plane,
  required int width,
  required int height,
  required int xEighth,
  required int yEighth,
  int? stride,
}) => _ChromaSampler(
  plane,
  width,
  height,
  stride ?? width,
).sample(xEighth, yEighth);

/// Writes a luma inter-prediction partition from a single reference picture.
void writeLumaInterPrediction({
  required Uint8List reference,
  required int referenceWidth,
  required int referenceHeight,
  required Uint8List destination,
  required int destinationWidth,
  required int destinationHeight,
  required int destinationX,
  required int destinationY,
  required int partitionWidth,
  required int partitionHeight,
  required MotionVector motionVector,
  int? referenceStride,
  int? destinationStride,
}) {
  final dstStride = destinationStride ?? destinationWidth;
  _validatePlane(reference, referenceWidth, referenceHeight, referenceStride);
  _validatePlane(destination, destinationWidth, destinationHeight, dstStride);
  _validateDestinationRegion(
    destinationX,
    destinationY,
    partitionWidth,
    partitionHeight,
    destinationWidth,
    destinationHeight,
  );
  if (motionVector.x % 4 == 0 && motionVector.y % 4 == 0) {
    _copyIntegerPrediction(
      reference: reference,
      referenceWidth: referenceWidth,
      referenceHeight: referenceHeight,
      referenceStride: referenceStride ?? referenceWidth,
      destination: destination,
      destinationStride: dstStride,
      destinationX: destinationX,
      destinationY: destinationY,
      partitionWidth: partitionWidth,
      partitionHeight: partitionHeight,
      sourceX: destinationX + motionVector.x ~/ 4,
      sourceY: destinationY + motionVector.y ~/ 4,
    );
    return;
  }
  final sampler = _LumaSampler(
    reference,
    referenceWidth,
    referenceHeight,
    referenceStride ?? referenceWidth,
  );
  final motionBaseX = _floorDiv(motionVector.x, 4);
  final motionBaseY = _floorDiv(motionVector.y, 4);
  final xFraction = motionVector.x - motionBaseX * 4;
  final yFraction = motionVector.y - motionBaseY * 4;
  final sourceX = destinationX + motionBaseX;
  final sourceY = destinationY + motionBaseY;
  final canUseUnclippedSixTap =
      sourceX >= 2 &&
      sourceY >= 2 &&
      sourceX + partitionWidth + 2 < referenceWidth &&
      sourceY + partitionHeight + 2 < referenceHeight;
  for (var y = 0; y < partitionHeight; y++) {
    final dstRow = (destinationY + y) * dstStride + destinationX;
    if (canUseUnclippedSixTap) {
      for (var x = 0; x < partitionWidth; x++) {
        destination[dstRow + x] = sampler.sampleUnclipped(
          sourceX + x,
          sourceY + y,
          xFraction,
          yFraction,
        );
      }
    } else {
      final referenceY = (destinationY + y) * 4 + motionVector.y;
      for (var x = 0; x < partitionWidth; x++) {
        destination[dstRow + x] = sampler.sample(
          (destinationX + x) * 4 + motionVector.x,
          referenceY,
        );
      }
    }
  }
}

/// Writes one Cb or Cr inter-prediction partition for a 4:2:0 picture.
///
/// Destination coordinates and sizes are expressed in luma samples. Motion
/// vector components are quarter-luma units (and thus eighth-chroma units).
void writeChromaInterPrediction({
  required Uint8List reference,
  required int referenceWidth,
  required int referenceHeight,
  required Uint8List destination,
  required int destinationWidth,
  required int destinationHeight,
  required int destinationX,
  required int destinationY,
  required int partitionWidth,
  required int partitionHeight,
  required MotionVector motionVector,
  int? referenceStride,
  int? destinationStride,
}) {
  if (destinationX.isOdd ||
      destinationY.isOdd ||
      partitionWidth.isOdd ||
      partitionHeight.isOdd) {
    throw ArgumentError('4:2:0 chroma partitions require even luma geometry.');
  }
  final dstStride = destinationStride ?? destinationWidth;
  _validatePlane(reference, referenceWidth, referenceHeight, referenceStride);
  _validatePlane(destination, destinationWidth, destinationHeight, dstStride);
  final chromaX = destinationX >> 1;
  final chromaY = destinationY >> 1;
  final chromaWidth = partitionWidth >> 1;
  final chromaHeight = partitionHeight >> 1;
  _validateDestinationRegion(
    chromaX,
    chromaY,
    chromaWidth,
    chromaHeight,
    destinationWidth,
    destinationHeight,
  );
  if (motionVector.x % 8 == 0 && motionVector.y % 8 == 0) {
    _copyIntegerPrediction(
      reference: reference,
      referenceWidth: referenceWidth,
      referenceHeight: referenceHeight,
      referenceStride: referenceStride ?? referenceWidth,
      destination: destination,
      destinationStride: dstStride,
      destinationX: chromaX,
      destinationY: chromaY,
      partitionWidth: chromaWidth,
      partitionHeight: chromaHeight,
      sourceX: chromaX + motionVector.x ~/ 8,
      sourceY: chromaY + motionVector.y ~/ 8,
    );
    return;
  }
  final refStride = referenceStride ?? referenceWidth;
  final motionBaseX = _floorDiv(motionVector.x, 8);
  final motionBaseY = _floorDiv(motionVector.y, 8);
  final xFraction = motionVector.x - motionBaseX * 8;
  final yFraction = motionVector.y - motionBaseY * 8;
  final sourceX = chromaX + motionBaseX;
  final sourceY = chromaY + motionBaseY;
  final sourceMaxX = sourceX + chromaWidth - 1 + (xFraction == 0 ? 0 : 1);
  final sourceMaxY = sourceY + chromaHeight - 1 + (yFraction == 0 ? 0 : 1);

  // Motion fractions are constant over the whole partition. Most blocks are
  // fully in-picture, so compute them once and index the planes directly
  // instead of repeating floor division and four clipped lookups per sample.
  if (sourceX >= 0 &&
      sourceY >= 0 &&
      sourceMaxX < referenceWidth &&
      sourceMaxY < referenceHeight) {
    final inverseX = 8 - xFraction;
    final inverseY = 8 - yFraction;
    for (var y = 0; y < chromaHeight; y++) {
      final dstRow = (chromaY + y) * dstStride + chromaX;
      final sourceRow = (sourceY + y) * refStride + sourceX;
      if (yFraction == 0) {
        for (var x = 0; x < chromaWidth; x++) {
          final offset = sourceRow + x;
          destination[dstRow + x] =
              (inverseX * reference[offset] +
                  xFraction * reference[offset + 1] +
                  4) >>
              3;
        }
      } else if (xFraction == 0) {
        final nextRow = sourceRow + refStride;
        for (var x = 0; x < chromaWidth; x++) {
          destination[dstRow + x] =
              (inverseY * reference[sourceRow + x] +
                  yFraction * reference[nextRow + x] +
                  4) >>
              3;
        }
      } else {
        final nextRow = sourceRow + refStride;
        for (var x = 0; x < chromaWidth; x++) {
          final offset = sourceRow + x;
          destination[dstRow + x] =
              (inverseX * inverseY * reference[offset] +
                  xFraction * inverseY * reference[offset + 1] +
                  inverseX * yFraction * reference[nextRow + x] +
                  xFraction * yFraction * reference[nextRow + x + 1] +
                  32) >>
              6;
        }
      }
    }
    return;
  }

  final sampler = _ChromaSampler(
    reference,
    referenceWidth,
    referenceHeight,
    refStride,
  );
  for (var y = 0; y < chromaHeight; y++) {
    final dstRow = (chromaY + y) * dstStride + chromaX;
    final referenceY = (chromaY + y) * 8 + motionVector.y;
    for (var x = 0; x < chromaWidth; x++) {
      destination[dstRow + x] = sampler.sample(
        (chromaX + x) * 8 + motionVector.x,
        referenceY,
      );
    }
  }
}

/// Copies an integer-sample prediction region with normative edge extension.
///
/// Most skip/direct partitions in ordinary video use integer motion. Handling
/// those rows as typed-data ranges avoids constructing a sampler and doing
/// coordinate division/clipping for every pixel. Border-crossing partitions
/// retain the exact per-sample edge-extension behaviour.
void _copyIntegerPrediction({
  required Uint8List reference,
  required int referenceWidth,
  required int referenceHeight,
  required int referenceStride,
  required Uint8List destination,
  required int destinationStride,
  required int destinationX,
  required int destinationY,
  required int partitionWidth,
  required int partitionHeight,
  required int sourceX,
  required int sourceY,
}) {
  final sourceInsideHorizontally =
      sourceX >= 0 && sourceX + partitionWidth <= referenceWidth;
  for (var row = 0; row < partitionHeight; row++) {
    final clippedSourceY = _clipCoordinate(sourceY + row, referenceHeight);
    final sourceRow = clippedSourceY * referenceStride;
    final destinationStart =
        (destinationY + row) * destinationStride + destinationX;
    if (sourceInsideHorizontally) {
      destination.setRange(
        destinationStart,
        destinationStart + partitionWidth,
        reference,
        sourceRow + sourceX,
      );
      continue;
    }
    for (var column = 0; column < partitionWidth; column++) {
      final clippedSourceX = _clipCoordinate(sourceX + column, referenceWidth);
      destination[destinationStart + column] =
          reference[sourceRow + clippedSourceX];
    }
  }
}

/// Writes luma, Cb, and Cr prediction for one P-slice partition.
void writeInterPrediction420({
  required Yuv420PictureBuffer reference,
  required Yuv420PictureBuffer destination,
  required int x,
  required int y,
  required int width,
  required int height,
  required MotionVector motionVector,
}) {
  writeLumaInterPrediction(
    reference: reference.y,
    referenceWidth: reference.width,
    referenceHeight: reference.height,
    referenceStride: reference.lumaStride,
    destination: destination.y,
    destinationWidth: destination.width,
    destinationHeight: destination.height,
    destinationStride: destination.lumaStride,
    destinationX: x,
    destinationY: y,
    partitionWidth: width,
    partitionHeight: height,
    motionVector: motionVector,
  );
  writeChromaInterPrediction(
    reference: reference.u,
    referenceWidth: reference.width >> 1,
    referenceHeight: reference.height >> 1,
    referenceStride: reference.chromaStride,
    destination: destination.u,
    destinationWidth: destination.width >> 1,
    destinationHeight: destination.height >> 1,
    destinationStride: destination.chromaStride,
    destinationX: x,
    destinationY: y,
    partitionWidth: width,
    partitionHeight: height,
    motionVector: motionVector,
  );
  writeChromaInterPrediction(
    reference: reference.v,
    referenceWidth: reference.width >> 1,
    referenceHeight: reference.height >> 1,
    referenceStride: reference.chromaStride,
    destination: destination.v,
    destinationWidth: destination.width >> 1,
    destinationHeight: destination.height >> 1,
    destinationStride: destination.chromaStride,
    destinationX: x,
    destinationY: y,
    partitionWidth: width,
    partitionHeight: height,
    motionVector: motionVector,
  );
}

class _LumaSampler {
  final Uint8List plane;
  final int width;
  final int height;
  final int stride;

  _LumaSampler(this.plane, this.width, this.height, this.stride) {
    _validatePlane(plane, width, height, stride);
  }

  int sample(int xQuarter, int yQuarter) {
    final x = _floorDiv(xQuarter, 4);
    final y = _floorDiv(yQuarter, 4);
    final xFraction = xQuarter - x * 4;
    final yFraction = yQuarter - y * 4;

    if (xFraction == 0 && yFraction == 0) return _full(x, y);

    if (yFraction == 0) {
      final half = _horizontalHalf(x, y);
      if (xFraction == 2) return half;
      return xFraction == 1
          ? _average(_full(x, y), half)
          : _average(half, _full(x + 1, y));
    }

    if (xFraction == 0) {
      final half = _verticalHalf(x, y);
      if (yFraction == 2) return half;
      return yFraction == 1
          ? _average(_full(x, y), half)
          : _average(half, _full(x, y + 1));
    }

    if (xFraction == 2 && yFraction == 2) {
      return _diagonalHalf(x, y);
    }

    if (xFraction == 2) {
      final diagonal = _diagonalHalf(x, y);
      return yFraction == 1
          ? _average(_horizontalHalf(x, y), diagonal)
          : _average(diagonal, _horizontalHalf(x, y + 1));
    }

    if (yFraction == 2) {
      final diagonal = _diagonalHalf(x, y);
      return xFraction == 1
          ? _average(_verticalHalf(x, y), diagonal)
          : _average(diagonal, _verticalHalf(x + 1, y));
    }

    // The four positions for which both components are quarter-sample offsets
    // average the closest horizontal and vertical half-samples (e, g, p, r in
    // Figure 8-4), not the diagonal half-sample.
    final horizontal = _horizontalHalf(x, yFraction == 1 ? y : y + 1);
    final vertical = _verticalHalf(xFraction == 1 ? x : x + 1, y);
    return _average(horizontal, vertical);
  }

  /// Samples an interior location whose complete six-tap footprint is known
  /// to be in-picture.
  int sampleUnclipped(int x, int y, int xFraction, int yFraction) {
    if (yFraction == 0) {
      final half = _horizontalHalfUnclipped(x, y);
      if (xFraction == 2) return half;
      return xFraction == 1
          ? _average(_fullUnclipped(x, y), half)
          : _average(half, _fullUnclipped(x + 1, y));
    }

    if (xFraction == 0) {
      final half = _verticalHalfUnclipped(x, y);
      if (yFraction == 2) return half;
      return yFraction == 1
          ? _average(_fullUnclipped(x, y), half)
          : _average(half, _fullUnclipped(x, y + 1));
    }

    if (xFraction == 2 && yFraction == 2) {
      return _diagonalHalfUnclipped(x, y);
    }

    if (xFraction == 2) {
      final diagonal = _diagonalHalfUnclipped(x, y);
      return yFraction == 1
          ? _average(_horizontalHalfUnclipped(x, y), diagonal)
          : _average(diagonal, _horizontalHalfUnclipped(x, y + 1));
    }

    if (yFraction == 2) {
      final diagonal = _diagonalHalfUnclipped(x, y);
      return xFraction == 1
          ? _average(_verticalHalfUnclipped(x, y), diagonal)
          : _average(diagonal, _verticalHalfUnclipped(x + 1, y));
    }

    final horizontal = _horizontalHalfUnclipped(x, yFraction == 1 ? y : y + 1);
    final vertical = _verticalHalfUnclipped(xFraction == 1 ? x : x + 1, y);
    return _average(horizontal, vertical);
  }

  int _full(int x, int y) {
    final clippedX = _clipCoordinate(x, width);
    final clippedY = _clipCoordinate(y, height);
    return plane[clippedY * stride + clippedX];
  }

  int _fullUnclipped(int x, int y) => plane[y * stride + x];

  int _horizontalRawUnclipped(int x, int y) {
    final offset = y * stride + x;
    return plane[offset - 2] -
        5 * plane[offset - 1] +
        20 * plane[offset] +
        20 * plane[offset + 1] -
        5 * plane[offset + 2] +
        plane[offset + 3];
  }

  int _horizontalHalfUnclipped(int x, int y) =>
      _clip8((_horizontalRawUnclipped(x, y) + 16) >> 5);

  int _verticalHalfUnclipped(int x, int y) {
    final offset = y * stride + x;
    final value =
        plane[offset - 2 * stride] -
        5 * plane[offset - stride] +
        20 * plane[offset] +
        20 * plane[offset + stride] -
        5 * plane[offset + 2 * stride] +
        plane[offset + 3 * stride];
    return _clip8((value + 16) >> 5);
  }

  int _diagonalHalfUnclipped(int x, int y) {
    final value =
        _horizontalRawUnclipped(x, y - 2) -
        5 * _horizontalRawUnclipped(x, y - 1) +
        20 * _horizontalRawUnclipped(x, y) +
        20 * _horizontalRawUnclipped(x, y + 1) -
        5 * _horizontalRawUnclipped(x, y + 2) +
        _horizontalRawUnclipped(x, y + 3);
    return _clip8((value + 512) >> 10);
  }

  int _horizontalRaw(int x, int y) =>
      _full(x - 2, y) -
      5 * _full(x - 1, y) +
      20 * _full(x, y) +
      20 * _full(x + 1, y) -
      5 * _full(x + 2, y) +
      _full(x + 3, y);

  int _horizontalHalf(int x, int y) => _clip8((_horizontalRaw(x, y) + 16) >> 5);

  int _verticalHalf(int x, int y) {
    final value =
        _full(x, y - 2) -
        5 * _full(x, y - 1) +
        20 * _full(x, y) +
        20 * _full(x, y + 1) -
        5 * _full(x, y + 2) +
        _full(x, y + 3);
    return _clip8((value + 16) >> 5);
  }

  int _diagonalHalf(int x, int y) {
    final value =
        _horizontalRaw(x, y - 2) -
        5 * _horizontalRaw(x, y - 1) +
        20 * _horizontalRaw(x, y) +
        20 * _horizontalRaw(x, y + 1) -
        5 * _horizontalRaw(x, y + 2) +
        _horizontalRaw(x, y + 3);
    return _clip8((value + 512) >> 10);
  }
}

class _ChromaSampler {
  final Uint8List plane;
  final int width;
  final int height;
  final int stride;

  _ChromaSampler(this.plane, this.width, this.height, this.stride) {
    _validatePlane(plane, width, height, stride);
  }

  int sample(int xEighth, int yEighth) {
    final x = _floorDiv(xEighth, 8);
    final y = _floorDiv(yEighth, 8);
    final xFraction = xEighth - x * 8;
    final yFraction = yEighth - y * 8;
    final a = _full(x, y);
    final b = _full(x + 1, y);
    final c = _full(x, y + 1);
    final d = _full(x + 1, y + 1);
    return ((8 - xFraction) * (8 - yFraction) * a +
            xFraction * (8 - yFraction) * b +
            (8 - xFraction) * yFraction * c +
            xFraction * yFraction * d +
            32) >>
        6;
  }

  int _full(int x, int y) {
    final clippedX = _clipCoordinate(x, width);
    final clippedY = _clipCoordinate(y, height);
    return plane[clippedY * stride + clippedX];
  }
}

void _validatePlane(Uint8List plane, int width, int height, int? stride) {
  final resolvedStride = stride ?? width;
  if (width <= 0 || height <= 0 || resolvedStride < width) {
    throw ArgumentError('Invalid plane dimensions or stride.');
  }
  if (plane.length < resolvedStride * height) {
    throw ArgumentError('Plane storage is smaller than its dimensions.');
  }
}

void _validatePartitionGeometry(int x, int y, int width, int height) {
  if (x < 0 || y < 0 || width <= 0 || height <= 0) {
    throw ArgumentError('Partition geometry must be positive and in-picture.');
  }
  if ((x & 3) != 0 || (y & 3) != 0 || (width & 3) != 0 || (height & 3) != 0) {
    throw ArgumentError(
      'Motion partitions must be aligned to 4x4 luma blocks.',
    );
  }
}

void _validateDestinationRegion(
  int x,
  int y,
  int width,
  int height,
  int planeWidth,
  int planeHeight,
) {
  if (x < 0 ||
      y < 0 ||
      width <= 0 ||
      height <= 0 ||
      x + width > planeWidth ||
      y + height > planeHeight) {
    throw RangeError('Prediction partition extends outside the destination.');
  }
}

int _floorDiv(int value, int divisor) {
  final remainder = value % divisor;
  return (value - remainder) ~/ divisor;
}

int _clipCoordinate(int value, int extent) {
  if (value < 0) return 0;
  if (value >= extent) return extent - 1;
  return value;
}

int _clip8(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return value;
}

int _average(int a, int b) => (a + b + 1) >> 1;

int _median3(int a, int b, int c) =>
    a + b + c - _min3(a, b, c) - _max3(a, b, c);

int _min3(int a, int b, int c) {
  var value = a < b ? a : b;
  if (c < value) value = c;
  return value;
}

int _max3(int a, int b, int c) {
  var value = a > b ? a : b;
  if (c > value) value = c;
  return value;
}
