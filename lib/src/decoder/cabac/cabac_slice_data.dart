import '../bitreader.dart';
import 'cabac_context.dart';
import 'cabac_decoder.dart';

/// A binary-decision source used by the CABAC slice-syntax decoder.
///
/// Keeping syntax decoding behind this small interface makes context-index
/// derivation independently testable. [H264CabacArithmeticSyntaxReader]
/// connects it to the normative arithmetic engine.
abstract interface class CabacSyntaxBinReader {
  int decodeDecision(int contextIndex);

  int decodeBypass();

  int decodeTerminate();
}

/// Adapts [H264CabacDecoder] and a mutable context set to slice syntax.
final class H264CabacArithmeticSyntaxReader implements CabacSyntaxBinReader {
  const H264CabacArithmeticSyntaxReader({
    required H264CabacDecoder decoder,
    required H264CabacContextSet contexts,
  }) : _decoder = decoder,
       _contexts = contexts;

  final H264CabacDecoder _decoder;
  final H264CabacContextSet _contexts;

  H264CabacDecoder get arithmeticDecoder => _decoder;
  H264CabacContextSet get contexts => _contexts;

  @override
  int decodeDecision(int contextIndex) =>
      _decoder.decodeBin(_contexts[contextIndex]);

  @override
  int decodeBypass() => _decoder.decodeBypass();

  @override
  int decodeTerminate() => _decoder.decodeTerminate();
}

/// Invalid CABAC syntax or an impossible decoded value.
final class CabacSyntaxException extends FormatException {
  const CabacSyntaxException(super.message);
}

/// Consumes the repeated `cabac_alignment_one_bit` values before CABAC init.
///
/// H.264 clause 7.3.3 requires every bit up to the next byte boundary to be
/// one. The returned value is the number of consumed alignment bits.
int readCabacAlignmentOneBits(BitReader reader) {
  var count = 0;
  while ((reader.bitPos & 7) != 0) {
    final position = reader.bitPos;
    if (reader.readBit() != 1) {
      throw BitstreamFormatException(
        'cabac_alignment_one_bit must equal 1',
        position,
      );
    }
    count++;
  }
  return count;
}

enum CabacMacroblockKind { skip, direct, inter, intraNxN, intra16x16, pcm }

/// A decoded value from the slice-specific `mb_type` table.
final class CabacMacroblockType {
  const CabacMacroblockType._({
    required this.sliceType,
    required this.codeNum,
    required this.kind,
  });

  factory CabacMacroblockType.fromCode({
    required H264CabacSliceType sliceType,
    required int codeNum,
  }) {
    final maximum = switch (sliceType) {
      H264CabacSliceType.i => 25,
      H264CabacSliceType.p => 30,
      H264CabacSliceType.b => 48,
    };
    RangeError.checkValueInInterval(codeNum, 0, maximum, 'codeNum');

    final kind = switch (sliceType) {
      H264CabacSliceType.i => switch (codeNum) {
        0 => CabacMacroblockKind.intraNxN,
        25 => CabacMacroblockKind.pcm,
        _ => CabacMacroblockKind.intra16x16,
      },
      H264CabacSliceType.p => switch (codeNum) {
        <= 4 => CabacMacroblockKind.inter,
        5 => CabacMacroblockKind.intraNxN,
        30 => CabacMacroblockKind.pcm,
        _ => CabacMacroblockKind.intra16x16,
      },
      H264CabacSliceType.b => switch (codeNum) {
        0 => CabacMacroblockKind.direct,
        <= 22 => CabacMacroblockKind.inter,
        23 => CabacMacroblockKind.intraNxN,
        48 => CabacMacroblockKind.pcm,
        _ => CabacMacroblockKind.intra16x16,
      },
    };
    return CabacMacroblockType._(
      sliceType: sliceType,
      codeNum: codeNum,
      kind: kind,
    );
  }

  factory CabacMacroblockType.skipped(H264CabacSliceType sliceType) {
    if (sliceType == H264CabacSliceType.i) {
      throw ArgumentError('I slices do not carry mb_skip_flag');
    }
    return CabacMacroblockType._(
      sliceType: sliceType,
      codeNum: null,
      kind: CabacMacroblockKind.skip,
    );
  }

  final H264CabacSliceType sliceType;

  /// Table 7-11, 7-13, or 7-14 value; null for the separate skip syntax.
  final int? codeNum;
  final CabacMacroblockKind kind;

  bool get isIntra =>
      kind == CabacMacroblockKind.intraNxN ||
      kind == CabacMacroblockKind.intra16x16 ||
      kind == CabacMacroblockKind.pcm;

  /// B_Direct_16x16 and inferred B_Skip use spatial/temporal Direct motion.
  bool get isDirect =>
      kind == CabacMacroblockKind.direct ||
      (kind == CabacMacroblockKind.skip && sliceType == H264CabacSliceType.b);

  int? get _intra16x16LocalCode {
    if (kind != CabacMacroblockKind.intra16x16) return null;
    final raw = codeNum!;
    return switch (sliceType) {
      H264CabacSliceType.i => raw - 1,
      H264CabacSliceType.p => raw - 6,
      H264CabacSliceType.b => raw - 24,
    };
  }

  /// Intra16x16 prediction mode embedded in the slice-specific type value.
  int? get intra16x16PredictionMode =>
      _intra16x16LocalCode == null ? null : _intra16x16LocalCode! & 3;

  /// Intra16x16 coded block pattern embedded in the type value.
  CabacCodedBlockPattern? get intra16x16CodedBlockPattern {
    final local = _intra16x16LocalCode;
    if (local == null) return null;
    return CabacCodedBlockPattern(
      luma: local >= 12 ? 15 : 0,
      chroma: (local % 12) ~/ 4,
    );
  }
}

/// The common `mb_skip_flag` / `mb_type` prefix of one macroblock layer.
final class CabacMacroblockStartSyntax {
  const CabacMacroblockStartSyntax({required this.skipped, required this.type});

  final bool skipped;
  final CabacMacroblockType type;

  bool get direct => type.isDirect;
}

/// Macroblock state needed by neighboring CABAC context derivations.
final class CabacMacroblockNeighbor {
  const CabacMacroblockNeighbor({
    this.available = true,
    this.skipped = false,
    this.direct = false,
    this.intra16x16 = false,
    this.pcm = false,
    this.codedBlockPatternLuma = 0,
    this.codedBlockPatternChroma = 0,
    this.intraChromaPredictionMode = 0,
    this.transformSize8x8 = false,
  });

  const CabacMacroblockNeighbor.unavailable()
    : available = false,
      skipped = false,
      direct = false,
      intra16x16 = false,
      pcm = false,
      codedBlockPatternLuma = 0,
      codedBlockPatternChroma = 0,
      intraChromaPredictionMode = 0,
      transformSize8x8 = false;

  final bool available;
  final bool skipped;
  final bool direct;
  final bool intra16x16;
  final bool pcm;
  final int codedBlockPatternLuma;
  final int codedBlockPatternChroma;
  final int intraChromaPredictionMode;
  final bool transformSize8x8;
}

final class CabacMacroblockNeighbors {
  const CabacMacroblockNeighbors({
    this.left = const CabacMacroblockNeighbor.unavailable(),
    this.top = const CabacMacroblockNeighbor.unavailable(),
  });

  final CabacMacroblockNeighbor left;
  final CabacMacroblockNeighbor top;
}

enum CabacReferenceList { l0, l1 }

/// Neighbor state for `ref_idx_lX` context derivation.
final class CabacReferenceNeighbor {
  const CabacReferenceNeighbor({
    this.available = true,
    this.direct = false,
    this.pcm = false,
    this.intra = false,
    required this.referenceIndex,
  });

  const CabacReferenceNeighbor.unavailable()
    : available = false,
      direct = false,
      pcm = false,
      intra = false,
      referenceIndex = -1;

  final bool available;
  final bool direct;
  final bool pcm;
  final bool intra;
  final int referenceIndex;
}

final class CabacReferenceIndexSyntax {
  const CabacReferenceIndexSyntax({required this.list, required this.value});

  final CabacReferenceList list;
  final int value;
}

/// A decoded value from the P or B `sub_mb_type` table.
final class CabacSubMacroblockType {
  const CabacSubMacroblockType._({
    required this.sliceType,
    required this.codeNum,
    required this.direct,
    required this.usesList0,
    required this.usesList1,
    required this.partitionWidth,
    required this.partitionHeight,
    required this.partitionCount,
  });

  factory CabacSubMacroblockType.fromCode({
    required H264CabacSliceType sliceType,
    required int codeNum,
  }) {
    if (sliceType == H264CabacSliceType.i) {
      throw ArgumentError('I slices do not carry sub_mb_type');
    }
    RangeError.checkValueInInterval(
      codeNum,
      0,
      sliceType == H264CabacSliceType.p ? 3 : 12,
      'codeNum',
    );

    if (sliceType == H264CabacSliceType.p) {
      const dimensions = <(int, int)>[(8, 8), (8, 4), (4, 8), (4, 4)];
      final (width, height) = dimensions[codeNum];
      return CabacSubMacroblockType._(
        sliceType: sliceType,
        codeNum: codeNum,
        direct: false,
        usesList0: true,
        usesList1: false,
        partitionWidth: width,
        partitionHeight: height,
        partitionCount: 64 ~/ (width * height),
      );
    }

    const dimensions = <(int, int)>[
      (8, 8),
      (8, 8),
      (8, 8),
      (8, 8),
      (8, 4),
      (4, 8),
      (8, 4),
      (4, 8),
      (8, 4),
      (4, 8),
      (4, 4),
      (4, 4),
      (4, 4),
    ];
    final (width, height) = dimensions[codeNum];
    final usesList0 = switch (codeNum) {
      1 || 4 || 5 || 10 => true,
      3 || 8 || 9 || 12 => true,
      _ => false,
    };
    final usesList1 = switch (codeNum) {
      2 || 6 || 7 || 11 => true,
      3 || 8 || 9 || 12 => true,
      _ => false,
    };
    return CabacSubMacroblockType._(
      sliceType: sliceType,
      codeNum: codeNum,
      direct: codeNum == 0,
      usesList0: usesList0,
      usesList1: usesList1,
      partitionWidth: width,
      partitionHeight: height,
      partitionCount: 64 ~/ (width * height),
    );
  }

  final H264CabacSliceType sliceType;
  final int codeNum;
  final bool direct;
  final bool usesList0;
  final bool usesList1;
  final int partitionWidth;
  final int partitionHeight;
  final int partitionCount;
}

enum CabacMvdComponent { horizontal, vertical }

/// Neighbor state for motion-vector-difference context derivation.
final class CabacMvdNeighbor {
  const CabacMvdNeighbor({
    this.available = true,
    this.horizontal = 0,
    this.vertical = 0,
  });

  const CabacMvdNeighbor.unavailable()
    : available = false,
      horizontal = 0,
      vertical = 0;

  final bool available;
  final int horizontal;
  final int vertical;

  int component(CabacMvdComponent component) => switch (component) {
    CabacMvdComponent.horizontal => horizontal,
    CabacMvdComponent.vertical => vertical,
  };
}

final class CabacMotionVectorDifference {
  const CabacMotionVectorDifference({
    required this.horizontal,
    required this.vertical,
  });

  final int horizontal;
  final int vertical;
}

/// `prev_intra*_pred_mode_flag` plus its optional rem-mode value.
final class CabacIntraLumaMode {
  const CabacIntraLumaMode({
    required this.usesPredictedMode,
    required this.remainingMode,
    required this.predictedMode,
    required this.mode,
  });

  final bool usesPredictedMode;
  final int? remainingMode;
  final int? predictedMode;

  /// Reconstructed mode when a predicted mode was supplied, otherwise null.
  final int? mode;
}

final class CabacCodedBlockPattern {
  const CabacCodedBlockPattern({required this.luma, required this.chroma});

  final int luma;
  final int chroma;

  /// Conventional H.264 packed representation (`luma | chroma << 4`).
  int get packed => luma | (chroma << 4);
}

/// Whether `transform_size_8x8_flag` is present for this macroblock layer.
///
/// This captures the syntax-presence rules from H.264 clause 7.3.5 without
/// depending on prediction or frame storage. For I_NxN the flag precedes the
/// intra luma modes, so [codedBlockPattern] is not needed. Inter and Direct
/// macroblocks carry the later flag only when luma residual is present and
/// their motion subdivision permits an 8x8 transform.
bool isCabacTransformSize8x8FlagPresent({
  required bool transform8x8ModeFlag,
  required CabacMacroblockType macroblockType,
  CabacCodedBlockPattern? codedBlockPattern,
  List<CabacSubMacroblockType> subMacroblockTypes =
      const <CabacSubMacroblockType>[],
  bool direct8x8InferenceFlag = false,
}) {
  if (!transform8x8ModeFlag) return false;
  if (macroblockType.kind == CabacMacroblockKind.intraNxN) return true;

  final inter = macroblockType.kind == CabacMacroblockKind.inter;
  final direct = macroblockType.kind == CabacMacroblockKind.direct;
  if (!inter && !direct) return false;
  if (codedBlockPattern == null) {
    throw ArgumentError.notNull('codedBlockPattern');
  }
  if (codedBlockPattern.luma == 0) return false;
  if (direct && !direct8x8InferenceFlag) return false;

  final code = macroblockType.codeNum;
  final usesSubMacroblockTypes =
      (macroblockType.sliceType == H264CabacSliceType.p &&
          (code == 3 || code == 4)) ||
      (macroblockType.sliceType == H264CabacSliceType.b && code == 22);
  if (!usesSubMacroblockTypes) return true;
  if (subMacroblockTypes.length != 4) {
    throw ArgumentError.value(
      subMacroblockTypes.length,
      'subMacroblockTypes',
      'P_8x8/P_8x8ref0/B_8x8 requires four sub_mb_type values',
    );
  }
  return subMacroblockTypes.every(
    (sub) => sub.partitionCount == 1 && (!sub.direct || direct8x8InferenceFlag),
  );
}

enum CabacResidualCategory {
  lumaDc16x16,
  lumaAc16x16,
  luma4x4,
  chromaDc420,
  chromaAc420,
  luma8x8,
}

/// Neighbor state for `coded_block_flag` context derivation.
enum CabacCodedBlockNeighborAvailability {
  /// The neighboring block exists and has a decoded coded-block state.
  available,

  /// Its macroblock exists, but this residual category/block does not.
  blockUnavailable,

  /// The neighboring macroblock itself is unavailable at the slice/picture edge.
  macroblockUnavailable,
}

final class CabacCodedBlockNeighbor {
  const CabacCodedBlockNeighbor({
    this.availability = CabacCodedBlockNeighborAvailability.available,
    this.coded = false,
    this.pcm = false,
  });

  /// A picture/slice-edge neighbor. Intra macroblocks derive condTermFlag=1.
  const CabacCodedBlockNeighbor.unavailable()
    : availability = CabacCodedBlockNeighborAvailability.macroblockUnavailable,
      coded = false,
      pcm = false;

  /// An existing neighboring macroblock without this block/category.
  const CabacCodedBlockNeighbor.blockUnavailable()
    : availability = CabacCodedBlockNeighborAvailability.blockUnavailable,
      coded = false,
      pcm = false;

  final CabacCodedBlockNeighborAvailability availability;
  final bool coded;
  final bool pcm;
}

/// Derives one spatial luma coded-block neighbor across transform categories.
///
/// An Intra16x16 AC block and an ordinary transform-4x4 block at the same
/// spatial position contribute their decoded coded-block state reciprocally.
/// A coded transform-8x8 group supplies an inferred coded state for each of
/// its four constituent 4x4 positions. A group absent from the neighboring
/// macroblock's coded-block pattern has no transform block at that position.
CabacCodedBlockNeighbor deriveCabacLumaCodedBlockNeighbor({
  required bool macroblockAvailable,
  required bool transformSize8x8,
  required int codedBlockPatternLuma,
  required int lumaCodedMask,
  required int blockX,
  required int blockY,
}) {
  RangeError.checkValueInInterval(blockX, 0, 3, 'blockX');
  RangeError.checkValueInInterval(blockY, 0, 3, 'blockY');
  if (!macroblockAvailable) {
    return const CabacCodedBlockNeighbor.unavailable();
  }
  final group = ((blockY >> 1) << 1) | (blockX >> 1);
  if ((codedBlockPatternLuma & (1 << group)) == 0) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  if (transformSize8x8) {
    return const CabacCodedBlockNeighbor(coded: true);
  }
  return CabacCodedBlockNeighbor(
    coded: (lumaCodedMask & (1 << (blockY * 4 + blockX))) != 0,
  );
}

/// Source-compatible name for ordinary luma-4x4 neighbor derivation.
///
/// [intra16x16] is retained for callers that already expose macroblock type;
/// luma coded state is intentionally category-symmetric and therefore does
/// not branch on it.
CabacCodedBlockNeighbor deriveCabacLuma4x4CodedBlockNeighbor({
  required bool macroblockAvailable,
  required bool intra16x16,
  required bool transformSize8x8,
  required int codedBlockPatternLuma,
  required int lumaCodedMask,
  required int blockX,
  required int blockY,
}) => deriveCabacLumaCodedBlockNeighbor(
  macroblockAvailable: macroblockAvailable,
  transformSize8x8: transformSize8x8,
  codedBlockPatternLuma: codedBlockPatternLuma,
  lumaCodedMask: lumaCodedMask,
  blockX: blockX,
  blockY: blockY,
);

/// Quantized coefficients indexed by residual scan position.
final class CabacResidualBlock {
  CabacResidualBlock({
    required this.category,
    required this.coded,
    required List<int> coefficients,
  }) : coefficients = List<int>.unmodifiable(coefficients);

  final CabacResidualCategory category;
  final bool coded;
  final List<int> coefficients;

  int get totalCoefficients => coefficients.where((value) => value != 0).length;
}

/// One inter partition, independent of reconstruction-frame storage.
final class CabacInterPartitionSyntax {
  const CabacInterPartitionSyntax({
    required this.partitionIndex,
    required this.usesList0,
    required this.usesList1,
    this.referenceIndexL0,
    this.referenceIndexL1,
    this.mvdL0,
    this.mvdL1,
  });

  final int partitionIndex;
  final bool usesList0;
  final bool usesList1;
  final int? referenceIndexL0;
  final int? referenceIndexL1;
  final CabacMotionVectorDifference? mvdL0;
  final CabacMotionVectorDifference? mvdL1;
}

final class CabacIntraSyntax {
  CabacIntraSyntax({
    required List<CabacIntraLumaMode> lumaModes,
    required this.chromaMode,
  }) : lumaModes = List<CabacIntraLumaMode>.unmodifiable(lumaModes);

  final List<CabacIntraLumaMode> lumaModes;
  final int chromaMode;
}

final class CabacMacroblockResidualSyntax {
  CabacMacroblockResidualSyntax({
    required List<CabacResidualBlock> luma,
    required List<CabacResidualBlock> chromaCb,
    required List<CabacResidualBlock> chromaCr,
  }) : luma = List<CabacResidualBlock>.unmodifiable(luma),
       chromaCb = List<CabacResidualBlock>.unmodifiable(chromaCb),
       chromaCr = List<CabacResidualBlock>.unmodifiable(chromaCr);

  final List<CabacResidualBlock> luma;
  final List<CabacResidualBlock> chromaCb;
  final List<CabacResidualBlock> chromaCr;

  int get totalCoefficients => <CabacResidualBlock>[
    ...luma,
    ...chromaCb,
    ...chromaCr,
  ].fold(0, (sum, block) => sum + block.totalCoefficients);
}

/// Frame-state-free macroblock handoff for prediction and reconstruction.
final class CabacDecodedMacroblock {
  CabacDecodedMacroblock({
    required this.address,
    required this.type,
    required this.skipped,
    required List<CabacInterPartitionSyntax> partitions,
    required this.intra,
    required this.transformSize8x8,
    required this.codedBlockPattern,
    required this.qpDelta,
    required this.residual,
  }) : partitions = List<CabacInterPartitionSyntax>.unmodifiable(partitions);

  final int address;
  final CabacMacroblockType type;
  final bool skipped;
  final List<CabacInterPartitionSyntax> partitions;
  final CabacIntraSyntax? intra;
  final bool transformSize8x8;
  final CabacCodedBlockPattern codedBlockPattern;
  final int qpDelta;
  final CabacMacroblockResidualSyntax residual;

  bool get direct =>
      type.kind == CabacMacroblockKind.direct ||
      (skipped && type.sliceType == H264CabacSliceType.b);
}

/// Progressive 4:2:0 CABAC macroblock-syntax and residual decoder.
///
/// This class deliberately owns no picture buffers. Callers provide already
/// resolved left/top syntax state and retain the typed results above.
final class H264CabacSliceDataDecoder {
  H264CabacSliceDataDecoder({
    required this.sliceType,
    required CabacSyntaxBinReader bins,
  }) : _bins = bins;

  factory H264CabacSliceDataDecoder.fromArithmetic({
    required H264CabacDecoder decoder,
    required H264CabacContextSet contexts,
  }) {
    if (contexts.sliceType != H264CabacSliceType.i &&
        contexts.sliceType != H264CabacSliceType.p &&
        contexts.sliceType != H264CabacSliceType.b) {
      throw ArgumentError.value(contexts.sliceType, 'contexts.sliceType');
    }
    return H264CabacSliceDataDecoder(
      sliceType: contexts.sliceType,
      bins: H264CabacArithmeticSyntaxReader(
        decoder: decoder,
        contexts: contexts,
      ),
    );
  }

  final H264CabacSliceType sliceType;
  final CabacSyntaxBinReader _bins;

  int _previousMbQpDelta = 0;

  int get previousMbQpDelta => _previousMbQpDelta;

  /// Decodes `end_of_slice_flag` using the terminating arithmetic process.
  bool decodeEndOfSliceFlag() => _terminate() == 1;

  bool decodeMbSkipFlag({
    CabacMacroblockNeighbors neighbors = const CabacMacroblockNeighbors(),
  }) {
    if (sliceType == H264CabacSliceType.i) {
      throw StateError('I slices do not carry mb_skip_flag');
    }
    var context = 11;
    if (neighbors.left.available && !neighbors.left.skipped) context++;
    if (neighbors.top.available && !neighbors.top.skipped) context++;
    if (sliceType == H264CabacSliceType.b) context += 13;
    return _decision(context) == 1;
  }

  /// Decodes the slice-specific macroblock prefix without picture state.
  ///
  /// For P/B skip macroblocks this also applies the normative
  /// `last_mb_qp_delta = 0` state transition and returns a typed skip value.
  CabacMacroblockStartSyntax decodeMacroblockStart({
    CabacMacroblockNeighbors neighbors = const CabacMacroblockNeighbors(),
  }) {
    if (sliceType != H264CabacSliceType.i &&
        decodeMbSkipFlag(neighbors: neighbors)) {
      noteMacroblockWithoutQpDelta();
      return CabacMacroblockStartSyntax(
        skipped: true,
        type: CabacMacroblockType.skipped(sliceType),
      );
    }
    return CabacMacroblockStartSyntax(
      skipped: false,
      type: decodeMbType(neighbors: neighbors),
    );
  }

  CabacMacroblockType decodeMbType({
    CabacMacroblockNeighbors neighbors = const CabacMacroblockNeighbors(),
  }) {
    final codeNum = switch (sliceType) {
      H264CabacSliceType.i => _decodeIntraMbType(
        contextBase: 3,
        intraSlice: true,
        neighbors: neighbors,
      ),
      H264CabacSliceType.p => _decodePMbType(neighbors),
      H264CabacSliceType.b => _decodeBMbType(neighbors),
    };
    return CabacMacroblockType.fromCode(sliceType: sliceType, codeNum: codeNum);
  }

  /// Decodes `sub_mb_type` using Table 7-17 or 7-18 numbering.
  CabacSubMacroblockType decodeSubMbType() {
    final codeNum = switch (sliceType) {
      H264CabacSliceType.i => throw StateError(
        'I slices do not carry sub_mb_type',
      ),
      H264CabacSliceType.p => _decodePSubMbType(),
      H264CabacSliceType.b => _decodeBSubMbType(),
    };
    return CabacSubMacroblockType.fromCode(
      sliceType: sliceType,
      codeNum: codeNum,
    );
  }

  CabacReferenceIndexSyntax decodeReferenceIndex({
    required CabacReferenceList list,
    required int activeReferenceCount,
    CabacReferenceNeighbor left = const CabacReferenceNeighbor.unavailable(),
    CabacReferenceNeighbor top = const CabacReferenceNeighbor.unavailable(),
  }) {
    RangeError.checkValueInInterval(
      activeReferenceCount,
      1,
      32,
      'activeReferenceCount',
    );
    if (activeReferenceCount == 1) {
      return CabacReferenceIndexSyntax(list: list, value: 0);
    }

    bool contributes(CabacReferenceNeighbor neighbor) =>
        neighbor.available &&
        !neighbor.pcm &&
        !neighbor.intra &&
        neighbor.referenceIndex > 0 &&
        (sliceType != H264CabacSliceType.b || !neighbor.direct);

    final contextIncrement =
        (contributes(left) ? 1 : 0) + (contributes(top) ? 2 : 0);
    if (_decision(54 + contextIncrement) == 0) {
      return CabacReferenceIndexSyntax(list: list, value: 0);
    }

    var value = 1;
    while (_decision(value == 1 ? 58 : 59) == 1) {
      value++;
      if (value >= 32) {
        throw const CabacSyntaxException(
          'ref_idx_lX exceeds the H.264 maximum of 31',
        );
      }
    }
    if (value >= activeReferenceCount) {
      throw CabacSyntaxException(
        'ref_idx_lX $value is outside active reference count '
        '$activeReferenceCount',
      );
    }
    return CabacReferenceIndexSyntax(list: list, value: value);
  }

  int decodeMvdComponent({
    required CabacMvdComponent component,
    CabacMvdNeighbor left = const CabacMvdNeighbor.unavailable(),
    CabacMvdNeighbor top = const CabacMvdNeighbor.unavailable(),
  }) {
    final sum =
        (left.available ? left.component(component).abs() : 0) +
        (top.available ? top.component(component).abs() : 0);
    final contextIncrement = sum < 3 ? 0 : (sum <= 32 ? 1 : 2);
    final contextBase = component == CabacMvdComponent.horizontal ? 40 : 47;
    if (_decision(contextBase + contextIncrement) == 0) return 0;

    var suffix = 0;
    var bin = _decision(contextBase + 3);
    if (bin != 0) {
      var binPosition = 1;
      do {
        bin = _decision(contextBase + 3 + (binPosition < 3 ? binPosition : 3));
        suffix++;
        binPosition++;
      } while (bin != 0 && binPosition != 8);
      if (bin != 0) suffix += _decodeExpGolombBypass(order: 3) + 1;
    }

    final magnitude = suffix + 1;
    return _bypass() == 1 ? -magnitude : magnitude;
  }

  /// Convenience decoder for the horizontal and vertical MVD syntax pair.
  CabacMotionVectorDifference decodeMotionVectorDifference({
    CabacMvdNeighbor left = const CabacMvdNeighbor.unavailable(),
    CabacMvdNeighbor top = const CabacMvdNeighbor.unavailable(),
  }) => CabacMotionVectorDifference(
    horizontal: decodeMvdComponent(
      component: CabacMvdComponent.horizontal,
      left: left,
      top: top,
    ),
    vertical: decodeMvdComponent(
      component: CabacMvdComponent.vertical,
      left: left,
      top: top,
    ),
  );

  CabacIntraLumaMode decodeIntra4x4Mode({int? predictedMode}) =>
      _decodeIntraLumaMode(predictedMode: predictedMode);

  CabacIntraLumaMode decodeIntra8x8Mode({int? predictedMode}) =>
      _decodeIntraLumaMode(predictedMode: predictedMode);

  int decodeIntraChromaPredictionMode({
    CabacMacroblockNeighbors neighbors = const CabacMacroblockNeighbors(),
  }) {
    bool contributes(CabacMacroblockNeighbor neighbor) =>
        neighbor.available &&
        !neighbor.pcm &&
        neighbor.intraChromaPredictionMode > 0;

    final increment =
        (contributes(neighbors.left) ? 1 : 0) +
        (contributes(neighbors.top) ? 1 : 0);
    if (_decision(64 + increment) == 0) return 0;
    if (_decision(67) == 0) return 1;
    return _decision(67) == 0 ? 2 : 3;
  }

  bool decodeTransformSize8x8Flag({
    CabacMacroblockNeighbors neighbors = const CabacMacroblockNeighbors(),
  }) {
    final increment =
        (neighbors.left.available && neighbors.left.transformSize8x8 ? 1 : 0) +
        (neighbors.top.available && neighbors.top.transformSize8x8 ? 1 : 0);
    return _decision(399 + increment) == 1;
  }

  CabacCodedBlockPattern decodeCodedBlockPattern({
    CabacMacroblockNeighbors neighbors = const CabacMacroblockNeighbors(),
  }) {
    bool lumaUncoded(CabacMacroblockNeighbor neighbor, int bit) =>
        neighbor.available &&
        !neighbor.pcm &&
        (neighbor.codedBlockPatternLuma & (1 << bit)) == 0;

    final top2 = lumaUncoded(neighbors.top, 2);
    final top3 = lumaUncoded(neighbors.top, 3);
    final left1 = lumaUncoded(neighbors.left, 1);
    final left3 = lumaUncoded(neighbors.left, 3);

    final bit0 = _decision(73 + (left1 ? 1 : 0) + (top2 ? 2 : 0));
    final bit1 = _decision(73 + (bit0 == 0 ? 1 : 0) + (top3 ? 2 : 0));
    final bit2 = _decision(73 + (left3 ? 1 : 0) + (bit0 == 0 ? 2 : 0));
    final bit3 = _decision(73 + (bit2 == 0 ? 1 : 0) + (bit1 == 0 ? 2 : 0));
    final luma = bit0 | (bit1 << 1) | (bit2 << 2) | (bit3 << 3);

    bool hasChroma(CabacMacroblockNeighbor neighbor) =>
        neighbor.available &&
        (neighbor.pcm || neighbor.codedBlockPatternChroma > 0);

    final firstChromaContext =
        (hasChroma(neighbors.left) ? 1 : 0) +
        (hasChroma(neighbors.top) ? 2 : 0);
    if (_decision(77 + firstChromaContext) == 0) {
      return CabacCodedBlockPattern(luma: luma, chroma: 0);
    }

    bool hasChromaAc(CabacMacroblockNeighbor neighbor) =>
        neighbor.available &&
        (neighbor.pcm || neighbor.codedBlockPatternChroma == 2);

    final secondChromaContext =
        (hasChromaAc(neighbors.left) ? 1 : 0) +
        (hasChromaAc(neighbors.top) ? 2 : 0);
    final chroma = 1 + _decision(81 + secondChromaContext);
    return CabacCodedBlockPattern(luma: luma, chroma: chroma);
  }

  int decodeMbQpDelta({int maximumUnaryBins = 1024}) {
    RangeError.checkValueInInterval(
      maximumUnaryBins,
      1,
      1 << 20,
      'maximumUnaryBins',
    );
    if (_decision(60 + (_previousMbQpDelta != 0 ? 1 : 0)) == 0) {
      _previousMbQpDelta = 0;
      return 0;
    }

    var unaryValue = 0;
    if (_decision(62) != 0) {
      do {
        unaryValue++;
        if (unaryValue >= maximumUnaryBins) {
          throw const CabacSyntaxException(
            'mb_qp_delta unary code is too long',
          );
        }
      } while (_decision(63) != 0);
    }
    final codeNum = unaryValue + 1;
    var delta = (codeNum + 1) >> 1;
    if (codeNum.isEven) delta = -delta;
    _previousMbQpDelta = delta;
    return delta;
  }

  /// Resets `last_mb_qp_delta` after skip or a macroblock without the syntax.
  void noteMacroblockWithoutQpDelta() {
    _previousMbQpDelta = 0;
  }

  bool decodeCodedBlockFlag({
    required CabacResidualCategory category,
    required bool currentMacroblockIntra,
    CabacCodedBlockNeighbor left = const CabacCodedBlockNeighbor.unavailable(),
    CabacCodedBlockNeighbor top = const CabacCodedBlockNeighbor.unavailable(),
  }) {
    if (category == CabacResidualCategory.luma8x8) {
      throw ArgumentError('8x8 residual blocks do not carry coded_block_flag');
    }

    bool condition(CabacCodedBlockNeighbor neighbor) =>
        switch (neighbor.availability) {
          CabacCodedBlockNeighborAvailability.available =>
            neighbor.pcm || neighbor.coded,
          CabacCodedBlockNeighborAvailability.blockUnavailable => false,
          CabacCodedBlockNeighborAvailability.macroblockUnavailable =>
            currentMacroblockIntra,
        };

    final increment = (condition(left) ? 1 : 0) + (condition(top) ? 2 : 0);
    return _decision(85 + _codedBlockFlagOffsets[category.index] + increment) ==
        1;
  }

  CabacResidualBlock decodeResidualBlock({
    required CabacResidualCategory category,
    required bool currentMacroblockIntra,
    CabacCodedBlockNeighbor left = const CabacCodedBlockNeighbor.unavailable(),
    CabacCodedBlockNeighbor top = const CabacCodedBlockNeighbor.unavailable(),
    bool? codedBlockFlagPresent,
  }) {
    final hasCodedBlockFlag =
        codedBlockFlagPresent ?? category != CabacResidualCategory.luma8x8;
    if (category == CabacResidualCategory.luma8x8 && hasCodedBlockFlag) {
      throw ArgumentError('8x8 residual blocks do not carry coded_block_flag');
    }

    final maximumCoefficients = _maximumCoefficients[category.index];
    final coded =
        !hasCodedBlockFlag ||
        decodeCodedBlockFlag(
          category: category,
          currentMacroblockIntra: currentMacroblockIntra,
          left: left,
          top: top,
        );
    if (!coded) {
      return CabacResidualBlock(
        category: category,
        coded: false,
        coefficients: List<int>.filled(maximumCoefficients, 0),
      );
    }

    final significantPositions = <int>[];
    final significantBase = _significantBases[category.index];
    final lastBase = _lastBases[category.index];
    var terminatedMap = false;
    for (var position = 0; position < maximumCoefficients - 1; position++) {
      final significanceOffset = category == CabacResidualCategory.luma8x8
          ? _significant8x8ContextOffset[position]
          : position;
      if (_decision(significantBase + significanceOffset) == 0) continue;

      significantPositions.add(position);
      final lastOffset = category == CabacResidualCategory.luma8x8
          ? _last8x8ContextOffset[position]
          : position;
      if (_decision(lastBase + lastOffset) == 1) {
        terminatedMap = true;
        break;
      }
    }
    if (!terminatedMap) significantPositions.add(maximumCoefficients - 1);

    final coefficients = List<int>.filled(maximumCoefficients, 0);
    final levelOneBase = _levelOneBases[category.index];
    final levelAbsBase = _levelAbsBases[category.index];
    final maximumC2 = _maximumC2[category.index];
    var c1 = 1;
    var c2 = 0;
    for (final position in significantPositions.reversed) {
      var magnitude = 1;
      if (_decision(levelOneBase + c1) == 1) {
        magnitude = 2 + _decodeUegLevel(levelAbsBase + c2);
        c2 = c2 < maximumC2 ? c2 + 1 : maximumC2;
        c1 = 0;
      } else if (c1 != 0) {
        c1 = c1 < 4 ? c1 + 1 : 4;
      }
      coefficients[position] = _bypass() == 1 ? -magnitude : magnitude;
    }

    return CabacResidualBlock(
      category: category,
      coded: true,
      coefficients: coefficients,
    );
  }

  int _decodePMbType(CabacMacroblockNeighbors neighbors) {
    if (_decision(14) == 1) {
      return 5 +
          _decodeIntraMbType(
            contextBase: 17,
            intraSlice: false,
            neighbors: neighbors,
          );
    }
    if (_decision(15) == 1) return _decision(17) == 1 ? 1 : 2;
    return _decision(16) == 1 ? 3 : 0;
  }

  int _decodeBMbType(CabacMacroblockNeighbors neighbors) {
    final directIncrement =
        (neighbors.left.available && !neighbors.left.direct ? 1 : 0) +
        (neighbors.top.available && !neighbors.top.direct ? 1 : 0);
    if (_decision(27 + directIncrement) == 0) return 0;
    if (_decision(30) == 0) return 1 + _decision(32);

    var code = _decision(31) << 3;
    code |= _decision(32) << 2;
    code |= _decision(32) << 1;
    code |= _decision(32);
    if (code < 8) return code + 3;
    if (code == 13) {
      return 23 +
          _decodeIntraMbType(
            contextBase: 32,
            intraSlice: false,
            neighbors: neighbors,
          );
    }
    if (code == 14) return 11;
    if (code == 15) return 22;
    code = (code << 1) | _decision(32);
    return code - 4;
  }

  int _decodeIntraMbType({
    required int contextBase,
    required bool intraSlice,
    required CabacMacroblockNeighbors neighbors,
  }) {
    var stateOffset = 0;
    if (intraSlice) {
      final increment =
          (neighbors.left.available &&
                  (neighbors.left.intra16x16 || neighbors.left.pcm)
              ? 1
              : 0) +
          (neighbors.top.available &&
                  (neighbors.top.intra16x16 || neighbors.top.pcm)
              ? 1
              : 0);
      if (_decision(contextBase + increment) == 0) return 0;
      stateOffset = 2;
    } else if (_decision(contextBase) == 0) {
      return 0;
    }

    if (_terminate() == 1) return 25;
    var code = 1 + 12 * _decision(contextBase + stateOffset + 1);
    if (_decision(contextBase + stateOffset + 2) == 1) {
      final secondChromaOffset = intraSlice ? 1 : 0;
      code +=
          4 + 4 * _decision(contextBase + stateOffset + 2 + secondChromaOffset);
    }
    code += 2 * _decision(contextBase + stateOffset + 3 + (intraSlice ? 1 : 0));
    code += _decision(contextBase + stateOffset + 3 + (intraSlice ? 2 : 0));
    return code;
  }

  int _decodePSubMbType() {
    if (_decision(21) == 1) return 0;
    if (_decision(22) == 0) return 1;
    return 3 - _decision(23);
  }

  int _decodeBSubMbType() {
    if (_decision(36) == 0) return 0;
    if (_decision(37) == 0) return 1 + _decision(39);
    var type = 3;
    if (_decision(38) == 1) {
      if (_decision(39) == 1) return 11 + _decision(39);
      type += 4;
    }
    type += 2 * _decision(39);
    type += _decision(39);
    return type;
  }

  CabacIntraLumaMode _decodeIntraLumaMode({int? predictedMode}) {
    if (predictedMode != null) {
      RangeError.checkValueInInterval(predictedMode, 0, 8, 'predictedMode');
    }
    if (_decision(68) == 1) {
      return CabacIntraLumaMode(
        usesPredictedMode: true,
        remainingMode: null,
        predictedMode: predictedMode,
        mode: predictedMode,
      );
    }

    var remainingMode = _decision(69);
    remainingMode |= _decision(69) << 1;
    remainingMode |= _decision(69) << 2;
    final mode = predictedMode == null
        ? null
        : remainingMode + (remainingMode >= predictedMode ? 1 : 0);
    return CabacIntraLumaMode(
      usesPredictedMode: false,
      remainingMode: remainingMode,
      predictedMode: predictedMode,
      mode: mode,
    );
  }

  int _decodeUegLevel(int contextIndex) {
    if (_decision(contextIndex) == 0) return 0;
    var code = 0;
    var count = 1;
    var bin = 1;
    do {
      bin = _decision(contextIndex);
      code++;
      count++;
    } while (bin != 0 && count != 13);
    if (bin != 0) code += _decodeExpGolombBypass(order: 0) + 1;
    return code;
  }

  int _decodeExpGolombBypass({required int order}) {
    RangeError.checkValueInInterval(order, 0, 23, 'order');
    var prefixValue = 0;
    var currentOrder = order;
    while (_bypass() == 1) {
      if (currentOrder >= 23) {
        throw const CabacSyntaxException(
          'CABAC bypass Exp-Golomb prefix is too long',
        );
      }
      prefixValue += 1 << currentOrder;
      currentOrder++;
    }
    var suffix = 0;
    for (var index = 0; index < currentOrder; index++) {
      suffix = (suffix << 1) | _bypass();
    }
    return prefixValue + suffix;
  }

  int _decision(int contextIndex) {
    final value = _bins.decodeDecision(contextIndex);
    if (value != 0 && value != 1) {
      throw CabacSyntaxException('decision bin must be 0 or 1, got $value');
    }
    return value;
  }

  int _bypass() {
    final value = _bins.decodeBypass();
    if (value != 0 && value != 1) {
      throw CabacSyntaxException('bypass bin must be 0 or 1, got $value');
    }
    return value;
  }

  int _terminate() {
    final value = _bins.decodeTerminate();
    if (value != 0 && value != 1) {
      throw CabacSyntaxException('terminate bin must be 0 or 1, got $value');
    }
    return value;
  }
}

const List<int> _maximumCoefficients = <int>[16, 15, 16, 4, 15, 64];
const List<int> _maximumC2 = <int>[4, 4, 4, 3, 4, 4];
const List<int> _codedBlockFlagOffsets = <int>[0, 4, 8, 12, 16, 0];
const List<int> _significantBases = <int>[105, 120, 134, 149, 152, 402];
const List<int> _lastBases = <int>[166, 181, 195, 210, 213, 417];
const List<int> _levelOneBases = <int>[227, 237, 247, 257, 266, 426];
const List<int> _levelAbsBases = <int>[232, 242, 252, 262, 271, 431];

/// Table 9-43 frame-coded 8x8 significance context increments.
const List<int> _significant8x8ContextOffset = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  5,
  4,
  4,
  3,
  3,
  4,
  4,
  4,
  5,
  5,
  4,
  4,
  4,
  4,
  3,
  3,
  6,
  7,
  7,
  7,
  8,
  9,
  10,
  9,
  8,
  7,
  7,
  6,
  11,
  12,
  13,
  11,
  6,
  7,
  8,
  9,
  14,
  10,
  9,
  8,
  6,
  11,
  12,
  13,
  11,
  6,
  9,
  14,
  10,
  9,
  11,
  12,
  13,
  11,
  14,
  10,
  12,
];

/// Table 9-43 frame-coded 8x8 last-significance context increments.
const List<int> _last8x8ContextOffset = <int>[
  0,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  6,
  6,
  6,
  6,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
];
