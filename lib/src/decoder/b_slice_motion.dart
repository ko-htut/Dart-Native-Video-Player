import 'motion_compensation.dart';

/// H.264 reference-picture list identifier.
enum H264MotionList { list0, list1 }

/// Inter-prediction mode signalled by B macroblock and sub-macroblock tables.
enum H264BPredictionMode { direct, list0, list1, bi }

extension H264BPredictionModeProperties on H264BPredictionMode {
  bool get explicitlyUsesList0 =>
      this == H264BPredictionMode.list0 || this == H264BPredictionMode.bi;

  bool get explicitlyUsesList1 =>
      this == H264BPredictionMode.list1 || this == H264BPredictionMode.bi;
}

/// Absolute luma geometry and prediction mode for one B partition.
final class H264BPartition {
  const H264BPartition({
    required this.macroblockPartitionIndex,
    required this.subMacroblockPartitionIndex,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.predictionMode,
  });

  final int macroblockPartitionIndex;
  final int? subMacroblockPartitionIndex;
  final int x;
  final int y;
  final int width;
  final int height;

  /// Null only for an outer `B_8x8` partition whose `sub_mb_type` has not yet
  /// been applied.
  final H264BPredictionMode? predictionMode;
}

/// Derives the co-located luma sample selected for one Direct partition.
///
/// H.264 8.4.1.2.1 selects a 4x4 luma-block index independently of the
/// prediction region's upper-left sample. With `direct_8x8_inference_flag`
/// set, that index is `5 * mbPartIdx`; otherwise it is
/// `4 * mbPartIdx + subMbPartIdx`. The returned coordinates are absolute luma
/// sample coordinates, ready for a co-located motion-field lookup.
({int x, int y}) deriveDirectColocatedLumaSamplePosition({
  required int macroblockX,
  required int macroblockY,
  required int macroblockPartitionIndex,
  required int subMacroblockPartitionIndex,
  required bool direct8x8Inference,
}) {
  _validateMacroblockOrigin(macroblockX, macroblockY);
  RangeError.checkValueInInterval(
    macroblockPartitionIndex,
    0,
    3,
    'macroblockPartitionIndex',
  );
  RangeError.checkValueInInterval(
    subMacroblockPartitionIndex,
    0,
    3,
    'subMacroblockPartitionIndex',
  );

  final luma4x4BlockIndex = direct8x8Inference
      ? 5 * macroblockPartitionIndex
      : 4 * macroblockPartitionIndex + subMacroblockPartitionIndex;
  final group = luma4x4BlockIndex >> 2;
  final withinGroup = luma4x4BlockIndex & 3;
  return (
    x: macroblockX + (group & 1) * 8 + (withinGroup & 1) * 4,
    y: macroblockY + (group >> 1) * 8 + (withinGroup >> 1) * 4,
  );
}

final class _RelativeBPartition {
  const _RelativeBPartition({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.mode,
  });

  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
  final H264BPredictionMode? mode;
}

/// Table 7-14 inter subset (`B_Direct_16x16` through `B_8x8`).
final class H264BInterMacroblockType {
  H264BInterMacroblockType._({
    required this.codeNum,
    required this.name,
    required this.skipped,
    required List<_RelativeBPartition> partitions,
  }) : _partitions = List<_RelativeBPartition>.unmodifiable(partitions);

  factory H264BInterMacroblockType.fromCode(int codeNum) {
    RangeError.checkValueInInterval(codeNum, 0, 22, 'codeNum');
    return switch (codeNum) {
      0 => H264BInterMacroblockType._direct(codeNum: 0, name: 'B_Direct_16x16'),
      1 => H264BInterMacroblockType._single(
        codeNum,
        'B_L0_16x16',
        H264BPredictionMode.list0,
      ),
      2 => H264BInterMacroblockType._single(
        codeNum,
        'B_L1_16x16',
        H264BPredictionMode.list1,
      ),
      3 => H264BInterMacroblockType._single(
        codeNum,
        'B_Bi_16x16',
        H264BPredictionMode.bi,
      ),
      4 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_L0_L0_16x8',
        H264BPredictionMode.list0,
        H264BPredictionMode.list0,
      ),
      5 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_L0_L0_8x16',
        H264BPredictionMode.list0,
        H264BPredictionMode.list0,
      ),
      6 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_L1_L1_16x8',
        H264BPredictionMode.list1,
        H264BPredictionMode.list1,
      ),
      7 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_L1_L1_8x16',
        H264BPredictionMode.list1,
        H264BPredictionMode.list1,
      ),
      8 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_L0_L1_16x8',
        H264BPredictionMode.list0,
        H264BPredictionMode.list1,
      ),
      9 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_L0_L1_8x16',
        H264BPredictionMode.list0,
        H264BPredictionMode.list1,
      ),
      10 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_L1_L0_16x8',
        H264BPredictionMode.list1,
        H264BPredictionMode.list0,
      ),
      11 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_L1_L0_8x16',
        H264BPredictionMode.list1,
        H264BPredictionMode.list0,
      ),
      12 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_L0_Bi_16x8',
        H264BPredictionMode.list0,
        H264BPredictionMode.bi,
      ),
      13 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_L0_Bi_8x16',
        H264BPredictionMode.list0,
        H264BPredictionMode.bi,
      ),
      14 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_L1_Bi_16x8',
        H264BPredictionMode.list1,
        H264BPredictionMode.bi,
      ),
      15 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_L1_Bi_8x16',
        H264BPredictionMode.list1,
        H264BPredictionMode.bi,
      ),
      16 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_Bi_L0_16x8',
        H264BPredictionMode.bi,
        H264BPredictionMode.list0,
      ),
      17 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_Bi_L0_8x16',
        H264BPredictionMode.bi,
        H264BPredictionMode.list0,
      ),
      18 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_Bi_L1_16x8',
        H264BPredictionMode.bi,
        H264BPredictionMode.list1,
      ),
      19 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_Bi_L1_8x16',
        H264BPredictionMode.bi,
        H264BPredictionMode.list1,
      ),
      20 => H264BInterMacroblockType._horizontal(
        codeNum,
        'B_Bi_Bi_16x8',
        H264BPredictionMode.bi,
        H264BPredictionMode.bi,
      ),
      21 => H264BInterMacroblockType._vertical(
        codeNum,
        'B_Bi_Bi_8x16',
        H264BPredictionMode.bi,
        H264BPredictionMode.bi,
      ),
      22 => H264BInterMacroblockType._subMacroblocks(),
      _ => throw StateError('unreachable B mb_type $codeNum'),
    };
  }

  factory H264BInterMacroblockType.skipped() =>
      H264BInterMacroblockType._direct(codeNum: null, name: 'B_Skip');

  factory H264BInterMacroblockType._single(
    int codeNum,
    String name,
    H264BPredictionMode mode,
  ) => H264BInterMacroblockType._(
    codeNum: codeNum,
    name: name,
    skipped: false,
    partitions: <_RelativeBPartition>[
      _RelativeBPartition(
        index: 0,
        x: 0,
        y: 0,
        width: 16,
        height: 16,
        mode: mode,
      ),
    ],
  );

  factory H264BInterMacroblockType._horizontal(
    int codeNum,
    String name,
    H264BPredictionMode first,
    H264BPredictionMode second,
  ) => H264BInterMacroblockType._(
    codeNum: codeNum,
    name: name,
    skipped: false,
    partitions: <_RelativeBPartition>[
      _RelativeBPartition(
        index: 0,
        x: 0,
        y: 0,
        width: 16,
        height: 8,
        mode: first,
      ),
      _RelativeBPartition(
        index: 1,
        x: 0,
        y: 8,
        width: 16,
        height: 8,
        mode: second,
      ),
    ],
  );

  factory H264BInterMacroblockType._vertical(
    int codeNum,
    String name,
    H264BPredictionMode first,
    H264BPredictionMode second,
  ) => H264BInterMacroblockType._(
    codeNum: codeNum,
    name: name,
    skipped: false,
    partitions: <_RelativeBPartition>[
      _RelativeBPartition(
        index: 0,
        x: 0,
        y: 0,
        width: 8,
        height: 16,
        mode: first,
      ),
      _RelativeBPartition(
        index: 1,
        x: 8,
        y: 0,
        width: 8,
        height: 16,
        mode: second,
      ),
    ],
  );

  factory H264BInterMacroblockType._direct({
    required int? codeNum,
    required String name,
  }) => H264BInterMacroblockType._(
    codeNum: codeNum,
    name: name,
    skipped: codeNum == null,
    partitions: _four8x8(H264BPredictionMode.direct),
  );

  factory H264BInterMacroblockType._subMacroblocks() =>
      H264BInterMacroblockType._(
        codeNum: 22,
        name: 'B_8x8',
        skipped: false,
        partitions: _four8x8(null),
      );

  final int? codeNum;
  final String name;
  final bool skipped;
  final List<_RelativeBPartition> _partitions;

  bool get isDirect => skipped || codeNum == 0;
  bool get requiresSubMacroblockTypes => codeNum == 22;
  int get partitionCount => _partitions.length;

  List<H264BPartition> partitionsAt({
    required int macroblockX,
    required int macroblockY,
  }) {
    _validateMacroblockOrigin(macroblockX, macroblockY);
    return List<H264BPartition>.unmodifiable(<H264BPartition>[
      for (final partition in _partitions)
        H264BPartition(
          macroblockPartitionIndex: partition.index,
          subMacroblockPartitionIndex: null,
          x: macroblockX + partition.x,
          y: macroblockY + partition.y,
          width: partition.width,
          height: partition.height,
          predictionMode: partition.mode,
        ),
    ]);
  }

  /// Effective colocated-motion inference regions for Direct/Skip.
  ///
  /// Table 7-14 exposes four 8x8 Direct regions. With
  /// `direct_8x8_inference_flag == 0`, each is instead derived per 4x4 block.
  List<H264BPartition> directInferenceRegionsAt({
    required int macroblockX,
    required int macroblockY,
    required bool direct8x8Inference,
  }) {
    if (!isDirect) {
      throw StateError('$name is not a Direct macroblock type');
    }
    _validateMacroblockOrigin(macroblockX, macroblockY);
    final output = <H264BPartition>[];
    for (final outer in _partitions) {
      if (direct8x8Inference) {
        output.add(
          H264BPartition(
            macroblockPartitionIndex: outer.index,
            subMacroblockPartitionIndex: 0,
            x: macroblockX + outer.x,
            y: macroblockY + outer.y,
            width: 8,
            height: 8,
            predictionMode: H264BPredictionMode.direct,
          ),
        );
      } else {
        output.addAll(
          _four4x4At(
            macroblockX + outer.x,
            macroblockY + outer.y,
            macroblockPartitionIndex: outer.index,
          ),
        );
      }
    }
    return List<H264BPartition>.unmodifiable(output);
  }
}

/// Table 7-18 `B_*` sub-macroblock modes.
final class H264BSubMacroblockType {
  const H264BSubMacroblockType._({
    required this.codeNum,
    required this.name,
    required this.predictionMode,
    required this.partitionCount,
    required this.partitionWidth,
    required this.partitionHeight,
  });

  factory H264BSubMacroblockType.fromCode(int codeNum) {
    RangeError.checkValueInInterval(codeNum, 0, 12, 'codeNum');
    return _bSubMacroblockTypes[codeNum];
  }

  final int codeNum;
  final String name;
  final H264BPredictionMode predictionMode;
  final int partitionCount;
  final int partitionWidth;
  final int partitionHeight;

  bool get isDirect => predictionMode == H264BPredictionMode.direct;

  List<H264BPartition> partitionsAt({
    required int macroblockX,
    required int macroblockY,
    required int macroblockPartitionIndex,
  }) {
    _validateMacroblockOrigin(macroblockX, macroblockY);
    RangeError.checkValueInInterval(
      macroblockPartitionIndex,
      0,
      3,
      'macroblockPartitionIndex',
    );
    final originX = macroblockX + (macroblockPartitionIndex & 1) * 8;
    final originY = macroblockY + (macroblockPartitionIndex >> 1) * 8;
    final output = <H264BPartition>[];
    for (var index = 0; index < partitionCount; index++) {
      final offsetX = partitionWidth == 4 ? (index & 1) * 4 : 0;
      final offsetY = partitionHeight == 4
          ? (partitionWidth == 8 ? index : index >> 1) * 4
          : 0;
      output.add(
        H264BPartition(
          macroblockPartitionIndex: macroblockPartitionIndex,
          subMacroblockPartitionIndex: index,
          x: originX + offsetX,
          y: originY + offsetY,
          width: partitionWidth,
          height: partitionHeight,
          predictionMode: predictionMode,
        ),
      );
    }
    return List<H264BPartition>.unmodifiable(output);
  }

  List<H264BPartition> directInferenceRegionsAt({
    required int macroblockX,
    required int macroblockY,
    required int macroblockPartitionIndex,
    required bool direct8x8Inference,
  }) {
    if (!isDirect) throw StateError('$name is not Direct');
    if (!direct8x8Inference) {
      return partitionsAt(
        macroblockX: macroblockX,
        macroblockY: macroblockY,
        macroblockPartitionIndex: macroblockPartitionIndex,
      );
    }
    _validateMacroblockOrigin(macroblockX, macroblockY);
    RangeError.checkValueInInterval(
      macroblockPartitionIndex,
      0,
      3,
      'macroblockPartitionIndex',
    );
    return <H264BPartition>[
      H264BPartition(
        macroblockPartitionIndex: macroblockPartitionIndex,
        subMacroblockPartitionIndex: 0,
        x: macroblockX + (macroblockPartitionIndex & 1) * 8,
        y: macroblockY + (macroblockPartitionIndex >> 1) * 8,
        width: 8,
        height: 8,
        predictionMode: H264BPredictionMode.direct,
      ),
    ];
  }
}

/// One list-specific vector and reference index at 4x4 luma granularity.
final class H264ReferenceMotion {
  H264ReferenceMotion({required this.referenceIndex, required this.vector}) {
    if (referenceIndex < 0) {
      throw ArgumentError.value(
        referenceIndex,
        'referenceIndex',
        'must be non-negative when a list is used',
      );
    }
  }

  final int referenceIndex;
  final MotionVector vector;

  @override
  String toString() => 'H264ReferenceMotion(ref: $referenceIndex, $vector)';
}

/// Motion metadata that retains both B reference lists without collapsing Bi.
///
/// Callers should store one value for every covered 4x4 luma block. Reference
/// indices remain list-relative here; reconstruction maps them through the
/// current List0/List1, and B deblocking maps both to stable picture identities
/// before comparing neighboring motion fields.
final class H264DualListMotion {
  H264DualListMotion._({
    required this.syntaxMode,
    required this.list0,
    required this.list1,
    required this.derivedFromDirect,
    required this.directZeroPrediction,
    required this.colocatedZero,
  });

  factory H264DualListMotion.inter({
    required H264BPredictionMode mode,
    H264ReferenceMotion? list0,
    H264ReferenceMotion? list1,
  }) {
    if (mode == H264BPredictionMode.direct) {
      throw ArgumentError('Use the spatial-direct derivation for Direct mode');
    }
    _validateListPresence(mode, list0, list1);
    return H264DualListMotion._(
      syntaxMode: mode,
      list0: list0,
      list1: list1,
      derivedFromDirect: false,
      directZeroPrediction: false,
      colocatedZero: false,
    );
  }

  factory H264DualListMotion._direct({
    required H264ReferenceMotion? list0,
    required H264ReferenceMotion? list1,
    required bool directZeroPrediction,
    required bool colocatedZero,
  }) {
    if (list0 == null && list1 == null) {
      throw StateError('Direct prediction must use at least one list');
    }
    return H264DualListMotion._(
      syntaxMode: H264BPredictionMode.direct,
      list0: list0,
      list1: list1,
      derivedFromDirect: true,
      directZeroPrediction: directZeroPrediction,
      colocatedZero: colocatedZero,
    );
  }

  final H264BPredictionMode syntaxMode;
  final H264ReferenceMotion? list0;
  final H264ReferenceMotion? list1;
  final bool derivedFromDirect;
  final bool directZeroPrediction;
  final bool colocatedZero;

  bool get usesList0 => list0 != null;
  bool get usesList1 => list1 != null;

  H264BPredictionMode get effectiveMode {
    if (usesList0 && usesList1) return H264BPredictionMode.bi;
    return usesList0 ? H264BPredictionMode.list0 : H264BPredictionMode.list1;
  }

  H264ReferenceMotion? motionFor(H264MotionList list) => switch (list) {
    H264MotionList.list0 => list0,
    H264MotionList.list1 => list1,
  };
}

/// Available dual-list motion state for one luma 4x4 block.
final class H264DualMotionFieldEntry {
  const H264DualMotionFieldEntry._({
    required this.available,
    required this.intra,
    required this.motion,
    required this.sliceId,
  });

  factory H264DualMotionFieldEntry.inter({
    required H264DualListMotion motion,
    int sliceId = 0,
  }) => H264DualMotionFieldEntry._(
    available: true,
    intra: false,
    motion: motion,
    sliceId: sliceId,
  );

  const H264DualMotionFieldEntry.intra({this.sliceId = 0})
    : available = true,
      intra = true,
      motion = null;

  static const unavailable = H264DualMotionFieldEntry._(
    available: false,
    intra: false,
    motion: null,
    sliceId: -1,
  );

  final bool available;
  final bool intra;
  final H264DualListMotion? motion;
  final int sliceId;

  H264ReferenceMotion? motionFor(H264MotionList list) =>
      motion?.motionFor(list);
}

/// Progressive frame motion field retaining List0 and List1 at 4x4 granularity.
final class H264DualMotionFieldGrid {
  H264DualMotionFieldGrid({required this.widthIn4x4, required this.heightIn4x4})
    : _entries = List<H264DualMotionFieldEntry>.filled(
        _checkedGridLength(widthIn4x4, heightIn4x4),
        H264DualMotionFieldEntry.unavailable,
      );

  factory H264DualMotionFieldGrid.forLumaSize({
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0 || (width & 3) != 0 || (height & 3) != 0) {
      throw ArgumentError(
        'Luma motion-field dimensions must be multiples of 4',
      );
    }
    return H264DualMotionFieldGrid(
      widthIn4x4: width >> 2,
      heightIn4x4: height >> 2,
    );
  }

  final int widthIn4x4;
  final int heightIn4x4;
  final List<H264DualMotionFieldEntry> _entries;

  H264DualMotionFieldEntry entryAt4x4(
    int blockX,
    int blockY, {
    int? currentSliceId,
  }) {
    if (blockX < 0 ||
        blockY < 0 ||
        blockX >= widthIn4x4 ||
        blockY >= heightIn4x4) {
      return H264DualMotionFieldEntry.unavailable;
    }
    final entry = _entries[blockY * widthIn4x4 + blockX];
    if (!entry.available ||
        (currentSliceId != null && entry.sliceId != currentSliceId)) {
      return H264DualMotionFieldEntry.unavailable;
    }
    return entry;
  }

  H264DualMotionFieldEntry entryAtLuma(int x, int y, {int? currentSliceId}) =>
      entryAt4x4(
        _floorDiv(x, 4),
        _floorDiv(y, 4),
        currentSliceId: currentSliceId,
      );

  void setPartition({
    required int x,
    required int y,
    required int width,
    required int height,
    required H264DualListMotion motion,
    int sliceId = 0,
  }) {
    _fillPartition(
      x: x,
      y: y,
      width: width,
      height: height,
      value: H264DualMotionFieldEntry.inter(motion: motion, sliceId: sliceId),
    );
  }

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
      value: H264DualMotionFieldEntry.intra(sliceId: sliceId),
    );
  }

  void clear() {
    _entries.fillRange(
      0,
      _entries.length,
      H264DualMotionFieldEntry.unavailable,
    );
  }

  void _fillPartition({
    required int x,
    required int y,
    required int width,
    required int height,
    required H264DualMotionFieldEntry value,
  }) {
    _validate4x4Geometry(x, y, width, height);
    final x4 = x >> 2;
    final y4 = y >> 2;
    final width4 = width >> 2;
    final height4 = height >> 2;
    if (x4 + width4 > widthIn4x4 || y4 + height4 > heightIn4x4) {
      throw RangeError('Motion partition extends outside the dual-list grid');
    }
    for (var blockY = y4; blockY < y4 + height4; blockY++) {
      for (var blockX = x4; blockX < x4 + width4; blockX++) {
        _entries[blockY * widthIn4x4 + blockX] = value;
      }
    }
  }

  static int _checkedGridLength(int width, int height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Motion-field dimensions must be positive');
    }
    return width * height;
  }
}

enum H264BPartitionShape {
  block16x16,
  horizontal16x8,
  vertical8x16,
  subMacroblock,
}

/// Derives list-specific MVPs, adds decoded MVDs, and returns dual metadata.
H264DualListMotion deriveBInterMotion({
  required H264DualMotionFieldGrid grid,
  required H264BPredictionMode mode,
  required int partitionX,
  required int partitionY,
  required int partitionWidth,
  required int partitionHeight,
  required H264BPartitionShape partitionShape,
  int partitionIndex = 0,
  int? referenceIndexL0,
  int? referenceIndexL1,
  MotionVector differenceL0 = MotionVector.zero,
  MotionVector differenceL1 = MotionVector.zero,
  int? currentSliceId,
}) {
  if (mode == H264BPredictionMode.direct) {
    throw ArgumentError('Direct mode uses deriveSpatialDirectContext');
  }
  final needsL0 = mode.explicitlyUsesList0;
  final needsL1 = mode.explicitlyUsesList1;
  if (needsL0 != (referenceIndexL0 != null) ||
      needsL1 != (referenceIndexL1 != null)) {
    throw ArgumentError('Reference indices must match B prediction mode $mode');
  }
  H264ReferenceMotion? list0;
  H264ReferenceMotion? list1;
  if (needsL0) {
    final predictor = _deriveListMotionVectorPredictor(
      grid: grid,
      list: H264MotionList.list0,
      partitionX: partitionX,
      partitionY: partitionY,
      partitionWidth: partitionWidth,
      partitionHeight: partitionHeight,
      referenceIndex: referenceIndexL0!,
      partitionShape: partitionShape,
      partitionIndex: partitionIndex,
      currentSliceId: currentSliceId,
    );
    list0 = H264ReferenceMotion(
      referenceIndex: referenceIndexL0,
      vector: predictor + differenceL0,
    );
  }
  if (needsL1) {
    final predictor = _deriveListMotionVectorPredictor(
      grid: grid,
      list: H264MotionList.list1,
      partitionX: partitionX,
      partitionY: partitionY,
      partitionWidth: partitionWidth,
      partitionHeight: partitionHeight,
      referenceIndex: referenceIndexL1!,
      partitionShape: partitionShape,
      partitionIndex: partitionIndex,
      currentSliceId: currentSliceId,
    );
    list1 = H264ReferenceMotion(
      referenceIndex: referenceIndexL1,
      vector: predictor + differenceL1,
    );
  }
  return H264DualListMotion.inter(mode: mode, list0: list0, list1: list1);
}

/// Co-located motion selected with List0 priority as required by 8.4.1.2.1.
final class H264ColocatedMotion {
  const H264ColocatedMotion._({
    required this.referenceIndex,
    required this.vector,
  });

  const H264ColocatedMotion.intra()
    : referenceIndex = -1,
      vector = MotionVector.zero;

  factory H264ColocatedMotion.inter({
    required int referenceIndex,
    required MotionVector vector,
  }) {
    if (referenceIndex < 0) {
      throw ArgumentError.value(referenceIndex, 'referenceIndex');
    }
    return H264ColocatedMotion._(
      referenceIndex: referenceIndex,
      vector: vector,
    );
  }

  factory H264ColocatedMotion.fromDualList(H264DualListMotion? motion) {
    final selected = motion?.list0 ?? motion?.list1;
    return selected == null
        ? const H264ColocatedMotion.intra()
        : H264ColocatedMotion.inter(
            referenceIndex: selected.referenceIndex,
            vector: selected.vector,
          );
  }

  final int referenceIndex;
  final MotionVector vector;
}

/// Macroblock-wide spatial-direct reference indices and MVPs.
///
/// H.264 8.4.1.2.2 deliberately derives these from macroblock A/B/C with
/// `mbPartIdx = subMbPartIdx = 0`, so they remain common to every Direct 4x4
/// block. [resolve] applies the per-colocated-block zero decision.
final class H264SpatialDirectContext {
  const H264SpatialDirectContext._({
    required this.referenceIndexL0,
    required this.referenceIndexL1,
    required this.predictorL0,
    required this.predictorL1,
    required this.directZeroPrediction,
  });

  final int referenceIndexL0;
  final int referenceIndexL1;
  final MotionVector predictorL0;
  final MotionVector predictorL1;
  final bool directZeroPrediction;

  H264DualListMotion resolve({
    required H264ColocatedMotion colocated,
    required bool list1Reference0IsShortTerm,
  }) {
    final colocatedZero =
        list1Reference0IsShortTerm &&
        colocated.referenceIndex == 0 &&
        colocated.vector.x >= -1 &&
        colocated.vector.x <= 1 &&
        colocated.vector.y >= -1 &&
        colocated.vector.y <= 1;

    H264ReferenceMotion? resolveList(
      int referenceIndex,
      MotionVector predictor,
    ) {
      if (referenceIndex < 0) return null;
      final forceZero =
          directZeroPrediction || (referenceIndex == 0 && colocatedZero);
      return H264ReferenceMotion(
        referenceIndex: referenceIndex,
        vector: forceZero ? MotionVector.zero : predictor,
      );
    }

    return H264DualListMotion._direct(
      list0: resolveList(referenceIndexL0, predictorL0),
      list1: resolveList(referenceIndexL1, predictorL1),
      directZeroPrediction: directZeroPrediction,
      colocatedZero: colocatedZero,
    );
  }
}

/// Co-located reference identity and motion used by temporal Direct mode.
///
/// [referencePictureId] is the stable decoded-picture identity selected from
/// the co-located picture's List0 (or List1 when List0 is unavailable). It is
/// deliberately not a list-relative index: temporal Direct must map that
/// identity into the current picture's List0 before applying POC scaling.
final class H264TemporalColocatedMotion {
  const H264TemporalColocatedMotion.intra()
    : referencePictureId = null,
      vector = MotionVector.zero;

  const H264TemporalColocatedMotion.inter({
    required this.referencePictureId,
    required this.vector,
  });

  final int? referencePictureId;
  final MotionVector vector;

  bool get isIntra => referencePictureId == null;
}

/// Slice-level state shared by every temporal Direct partition.
final class H264TemporalDirectContext {
  H264TemporalDirectContext._({
    required List<int> referencePictureIdsL0,
    required List<int> referencePictureOrderCountsL0,
    required this.currentPictureOrderCount,
    required this.list1Reference0PictureOrderCount,
  }) : referencePictureIdsL0 = List<int>.unmodifiable(referencePictureIdsL0),
       referencePictureOrderCountsL0 = List<int>.unmodifiable(
         referencePictureOrderCountsL0,
       );

  final List<int> referencePictureIdsL0;
  final List<int> referencePictureOrderCountsL0;
  final int currentPictureOrderCount;
  final int list1Reference0PictureOrderCount;

  H264DualListMotion resolve(H264TemporalColocatedMotion colocated) {
    if (colocated.isIntra) {
      return H264DualListMotion._direct(
        list0: H264ReferenceMotion(
          referenceIndex: 0,
          vector: MotionVector.zero,
        ),
        list1: H264ReferenceMotion(
          referenceIndex: 0,
          vector: MotionVector.zero,
        ),
        directZeroPrediction: true,
        colocatedZero: false,
      );
    }

    final referenceIndexL0 = referencePictureIdsL0.indexOf(
      colocated.referencePictureId!,
    );
    if (referenceIndexL0 < 0) {
      throw FormatException(
        'Temporal Direct co-located reference picture '
        '${colocated.referencePictureId} is absent from current List0',
      );
    }
    final list0Poc = referencePictureOrderCountsL0[referenceIndexL0];
    final td = _clip3(-128, 127, list1Reference0PictureOrderCount - list0Poc);
    final scale = td == 0
        ? 256
        : _clip3(
            -1024,
            1023,
            (_clip3(-128, 127, currentPictureOrderCount - list0Poc) *
                        ((16384 + (td.abs() >> 1)) ~/ td) +
                    32) >>
                6,
          );
    final mvCol = colocated.vector;
    final mvL0 = MotionVector(
      (scale * mvCol.x + 128) >> 8,
      (scale * mvCol.y + 128) >> 8,
    );
    final mvL1 = MotionVector(mvL0.x - mvCol.x, mvL0.y - mvCol.y);
    return H264DualListMotion._direct(
      list0: H264ReferenceMotion(
        referenceIndex: referenceIndexL0,
        vector: mvL0,
      ),
      list1: H264ReferenceMotion(referenceIndex: 0, vector: mvL1),
      directZeroPrediction: false,
      colocatedZero: false,
    );
  }
}

/// Builds progressive short-term temporal Direct state (H.264 8.4.1.2.3).
///
/// Long-term references and field/MBAFF pictures are outside the decoder's
/// supported parameter-set envelope. Duplicate current List0 entries are
/// valid; the first entry with the co-located stable identity is selected.
H264TemporalDirectContext deriveTemporalDirectContext({
  required List<int> referencePictureIdsL0,
  required List<int> referencePictureOrderCountsL0,
  required int currentPictureOrderCount,
  required int list1Reference0PictureOrderCount,
}) {
  if (referencePictureIdsL0.isEmpty ||
      referencePictureIdsL0.length != referencePictureOrderCountsL0.length) {
    throw ArgumentError(
      'Temporal Direct requires equally sized, non-empty List0 identity and '
      'POC arrays',
    );
  }
  return H264TemporalDirectContext._(
    referencePictureIdsL0: referencePictureIdsL0,
    referencePictureOrderCountsL0: referencePictureOrderCountsL0,
    currentPictureOrderCount: currentPictureOrderCount,
    list1Reference0PictureOrderCount: list1Reference0PictureOrderCount,
  );
}

H264DualListMotion deriveTemporalDirectMotion({
  required H264TemporalColocatedMotion colocated,
  required List<int> referencePictureIdsL0,
  required List<int> referencePictureOrderCountsL0,
  required int currentPictureOrderCount,
  required int list1Reference0PictureOrderCount,
}) => deriveTemporalDirectContext(
  referencePictureIdsL0: referencePictureIdsL0,
  referencePictureOrderCountsL0: referencePictureOrderCountsL0,
  currentPictureOrderCount: currentPictureOrderCount,
  list1Reference0PictureOrderCount: list1Reference0PictureOrderCount,
).resolve(colocated);

/// Derives the progressive spatial-direct base state for one macroblock.
H264SpatialDirectContext deriveSpatialDirectContext({
  required H264DualMotionFieldGrid grid,
  required int macroblockX,
  required int macroblockY,
  int? currentSliceId,
}) {
  _validateMacroblockOrigin(macroblockX, macroblockY);
  final neighborsL0 = _motionNeighbors(
    grid: grid,
    list: H264MotionList.list0,
    partitionX: macroblockX,
    partitionY: macroblockY,
    partitionWidth: 16,
    currentSliceId: currentSliceId,
  );
  final neighborsL1 = _motionNeighbors(
    grid: grid,
    list: H264MotionList.list1,
    partitionX: macroblockX,
    partitionY: macroblockY,
    partitionWidth: 16,
    currentSliceId: currentSliceId,
  );
  var referenceIndexL0 = _minPositive3(
    neighborsL0.a.referenceIndex,
    neighborsL0.b.referenceIndex,
    neighborsL0.c.referenceIndex,
  );
  var referenceIndexL1 = _minPositive3(
    neighborsL1.a.referenceIndex,
    neighborsL1.b.referenceIndex,
    neighborsL1.c.referenceIndex,
  );
  final directZeroPrediction = referenceIndexL0 < 0 && referenceIndexL1 < 0;
  if (directZeroPrediction) {
    referenceIndexL0 = 0;
    referenceIndexL1 = 0;
  }

  MotionVector predictor(H264MotionList list, int referenceIndex) {
    if (directZeroPrediction || referenceIndex < 0) return MotionVector.zero;
    return _deriveListMotionVectorPredictor(
      grid: grid,
      list: list,
      partitionX: macroblockX,
      partitionY: macroblockY,
      partitionWidth: 16,
      partitionHeight: 16,
      referenceIndex: referenceIndex,
      partitionShape: H264BPartitionShape.block16x16,
      currentSliceId: currentSliceId,
    );
  }

  return H264SpatialDirectContext._(
    referenceIndexL0: referenceIndexL0,
    referenceIndexL1: referenceIndexL1,
    predictorL0: predictor(H264MotionList.list0, referenceIndexL0),
    predictorL1: predictor(H264MotionList.list1, referenceIndexL1),
    directZeroPrediction: directZeroPrediction,
  );
}

MotionVector _deriveListMotionVectorPredictor({
  required H264DualMotionFieldGrid grid,
  required H264MotionList list,
  required int partitionX,
  required int partitionY,
  required int partitionWidth,
  required int partitionHeight,
  required int referenceIndex,
  required H264BPartitionShape partitionShape,
  int partitionIndex = 0,
  int? currentSliceId,
}) {
  _validate4x4Geometry(partitionX, partitionY, partitionWidth, partitionHeight);
  if (referenceIndex < 0) {
    throw ArgumentError.value(referenceIndex, 'referenceIndex');
  }
  if ((partitionShape == H264BPartitionShape.horizontal16x8 ||
          partitionShape == H264BPartitionShape.vertical8x16) &&
      (partitionIndex < 0 || partitionIndex > 1)) {
    throw ArgumentError.value(partitionIndex, 'partitionIndex');
  }

  final neighbors = _motionNeighbors(
    grid: grid,
    list: list,
    partitionX: partitionX,
    partitionY: partitionY,
    partitionWidth: partitionWidth,
    currentSliceId: currentSliceId,
  );
  var a = neighbors.a;
  var b = neighbors.b;
  var c = neighbors.c;

  if (partitionShape == H264BPartitionShape.horizontal16x8) {
    final preferred = partitionIndex == 0 ? b : a;
    if (preferred.hasReference(referenceIndex)) return preferred.vector;
  } else if (partitionShape == H264BPartitionShape.vertical8x16) {
    final preferred = partitionIndex == 0 ? a : c;
    if (preferred.hasReference(referenceIndex)) return preferred.vector;
  }

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

({MotionFieldEntry a, MotionFieldEntry b, MotionFieldEntry c})
_motionNeighbors({
  required H264DualMotionFieldGrid grid,
  required H264MotionList list,
  required int partitionX,
  required int partitionY,
  required int partitionWidth,
  int? currentSliceId,
}) {
  MotionFieldEntry entry(int x, int y) {
    final dual = grid.entryAtLuma(x, y, currentSliceId: currentSliceId);
    if (!dual.available) return MotionFieldEntry.unavailable;
    final motion = dual.motionFor(list);
    return motion == null
        ? MotionFieldEntry.intra(sliceId: dual.sliceId)
        : MotionFieldEntry(
            vector: motion.vector,
            referenceIndex: motion.referenceIndex,
            sliceId: dual.sliceId,
          );
  }

  final a = entry(partitionX - 1, partitionY);
  final b = entry(partitionX, partitionY - 1);
  var c = entry(partitionX + partitionWidth, partitionY - 1);
  if (!c.available) c = entry(partitionX - 1, partitionY - 1);
  return (a: a, b: b, c: c);
}

List<_RelativeBPartition> _four8x8(H264BPredictionMode? mode) =>
    <_RelativeBPartition>[
      for (var index = 0; index < 4; index++)
        _RelativeBPartition(
          index: index,
          x: (index & 1) * 8,
          y: (index >> 1) * 8,
          width: 8,
          height: 8,
          mode: mode,
        ),
    ];

List<H264BPartition> _four4x4At(
  int x,
  int y, {
  required int macroblockPartitionIndex,
}) => <H264BPartition>[
  for (var index = 0; index < 4; index++)
    H264BPartition(
      macroblockPartitionIndex: macroblockPartitionIndex,
      subMacroblockPartitionIndex: index,
      x: x + (index & 1) * 4,
      y: y + (index >> 1) * 4,
      width: 4,
      height: 4,
      predictionMode: H264BPredictionMode.direct,
    ),
];

void _validateListPresence(
  H264BPredictionMode mode,
  H264ReferenceMotion? list0,
  H264ReferenceMotion? list1,
) {
  if (mode.explicitlyUsesList0 != (list0 != null) ||
      mode.explicitlyUsesList1 != (list1 != null)) {
    throw ArgumentError('List motion must match B prediction mode $mode');
  }
}

void _validateMacroblockOrigin(int x, int y) {
  if (x < 0 || y < 0 || (x & 15) != 0 || (y & 15) != 0) {
    throw ArgumentError(
      'Macroblock origin must be non-negative and 16-aligned',
    );
  }
}

void _validate4x4Geometry(int x, int y, int width, int height) {
  if (x < 0 ||
      y < 0 ||
      width <= 0 ||
      height <= 0 ||
      (x & 3) != 0 ||
      (y & 3) != 0 ||
      (width & 3) != 0 ||
      (height & 3) != 0) {
    throw ArgumentError('Motion geometry must be non-negative and 4-aligned');
  }
}

int _floorDiv(int value, int divisor) {
  final quotient = value ~/ divisor;
  final remainder = value % divisor;
  return remainder != 0 && value < 0 ? quotient - 1 : quotient;
}

int _median3(int a, int b, int c) =>
    a + b + c - _min3(a, b, c) - _max3(a, b, c);

int _min3(int a, int b, int c) {
  var result = a < b ? a : b;
  if (c < result) result = c;
  return result;
}

int _max3(int a, int b, int c) {
  var result = a > b ? a : b;
  if (c > result) result = c;
  return result;
}

int _clip3(int minimum, int maximum, int value) =>
    value < minimum ? minimum : (value > maximum ? maximum : value);

int _minPositive(int x, int y) =>
    x >= 0 && y >= 0 ? (x < y ? x : y) : (x > y ? x : y);

int _minPositive3(int a, int b, int c) => _minPositive(a, _minPositive(b, c));

const List<H264BSubMacroblockType> _bSubMacroblockTypes =
    <H264BSubMacroblockType>[
      H264BSubMacroblockType._(
        codeNum: 0,
        name: 'B_Direct_8x8',
        predictionMode: H264BPredictionMode.direct,
        partitionCount: 4,
        partitionWidth: 4,
        partitionHeight: 4,
      ),
      H264BSubMacroblockType._(
        codeNum: 1,
        name: 'B_L0_8x8',
        predictionMode: H264BPredictionMode.list0,
        partitionCount: 1,
        partitionWidth: 8,
        partitionHeight: 8,
      ),
      H264BSubMacroblockType._(
        codeNum: 2,
        name: 'B_L1_8x8',
        predictionMode: H264BPredictionMode.list1,
        partitionCount: 1,
        partitionWidth: 8,
        partitionHeight: 8,
      ),
      H264BSubMacroblockType._(
        codeNum: 3,
        name: 'B_Bi_8x8',
        predictionMode: H264BPredictionMode.bi,
        partitionCount: 1,
        partitionWidth: 8,
        partitionHeight: 8,
      ),
      H264BSubMacroblockType._(
        codeNum: 4,
        name: 'B_L0_8x4',
        predictionMode: H264BPredictionMode.list0,
        partitionCount: 2,
        partitionWidth: 8,
        partitionHeight: 4,
      ),
      H264BSubMacroblockType._(
        codeNum: 5,
        name: 'B_L0_4x8',
        predictionMode: H264BPredictionMode.list0,
        partitionCount: 2,
        partitionWidth: 4,
        partitionHeight: 8,
      ),
      H264BSubMacroblockType._(
        codeNum: 6,
        name: 'B_L1_8x4',
        predictionMode: H264BPredictionMode.list1,
        partitionCount: 2,
        partitionWidth: 8,
        partitionHeight: 4,
      ),
      H264BSubMacroblockType._(
        codeNum: 7,
        name: 'B_L1_4x8',
        predictionMode: H264BPredictionMode.list1,
        partitionCount: 2,
        partitionWidth: 4,
        partitionHeight: 8,
      ),
      H264BSubMacroblockType._(
        codeNum: 8,
        name: 'B_Bi_8x4',
        predictionMode: H264BPredictionMode.bi,
        partitionCount: 2,
        partitionWidth: 8,
        partitionHeight: 4,
      ),
      H264BSubMacroblockType._(
        codeNum: 9,
        name: 'B_Bi_4x8',
        predictionMode: H264BPredictionMode.bi,
        partitionCount: 2,
        partitionWidth: 4,
        partitionHeight: 8,
      ),
      H264BSubMacroblockType._(
        codeNum: 10,
        name: 'B_L0_4x4',
        predictionMode: H264BPredictionMode.list0,
        partitionCount: 4,
        partitionWidth: 4,
        partitionHeight: 4,
      ),
      H264BSubMacroblockType._(
        codeNum: 11,
        name: 'B_L1_4x4',
        predictionMode: H264BPredictionMode.list1,
        partitionCount: 4,
        partitionWidth: 4,
        partitionHeight: 4,
      ),
      H264BSubMacroblockType._(
        codeNum: 12,
        name: 'B_Bi_4x4',
        predictionMode: H264BPredictionMode.bi,
        partitionCount: 4,
        partitionWidth: 4,
        partitionHeight: 4,
      ),
    ];
