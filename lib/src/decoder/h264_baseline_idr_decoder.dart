import 'dart:typed_data';

import '../yuv.dart';
import 'bitreader.dart';
import 'cavlc.dart';
import 'chroma_pred.dart';
import 'deblocking_filter.dart';
import 'exp_golomb.dart';
import 'intra16_dc.dart';
import 'intra4x4_mpm.dart';
import 'intra_pred.dart';
import 'inv_transform.dart';
import 'motion_compensation.dart';
import 'pps.dart';
import 'rbsp.dart';
import 'reference_picture_list.dart';
import 'slice_header.dart';
import 'sps.dart';

/// Optional low-level trace hook used by diagnostics and golden tests.
void Function(String message)? h264DecoderTrace;

class H264DecodeStats {
  final int frameNumber;
  final H264SliceType sliceType;
  final int macroblockCount;
  final int intraMacroblocks;
  final int interMacroblocks;
  final int skippedMacroblocks;
  final int sliceCount;

  const H264DecodeStats({
    required this.frameNumber,
    required this.sliceType,
    required this.macroblockCount,
    required this.intraMacroblocks,
    required this.interMacroblocks,
    required this.skippedMacroblocks,
    required this.sliceCount,
  });
}

/// Progressive 8-bit 4:2:0 H.264 decoder for Baseline/CAVLC I and P pictures.
///
/// Unsupported syntax and malformed variable-length codes fail the access unit
/// instead of guessing values and desynchronising all following macroblocks.
class H264BaselineDecoder {
  static const int defaultMaxCodedDimension = 4096;
  static const int defaultMaxLumaSamples = 4096 * 2304;

  final bool enableDeblocking;
  final int maxCodedDimension;
  final int maxLumaSamples;
  final Map<int, SpsInfo> _spsById = <int, SpsInfo>{};
  final Map<int, PpsInfo> _ppsById = <int, PpsInfo>{};
  final List<_DecodedPicture> _shortTermReferences = <_DecodedPicture>[];
  int? _previousReferenceFrameNum;
  int _pictureId = 0;

  String? lastError;
  H264DecodeStats? lastStats;

  H264BaselineDecoder({
    this.enableDeblocking = true,
    this.maxCodedDimension = defaultMaxCodedDimension,
    this.maxLumaSamples = defaultMaxLumaSamples,
  }) {
    if (maxCodedDimension <= 0) {
      throw ArgumentError.value(
        maxCodedDimension,
        'maxCodedDimension',
        'must be positive',
      );
    }
    if (maxLumaSamples <= 0) {
      throw ArgumentError.value(
        maxLumaSamples,
        'maxLumaSamples',
        'must be positive',
      );
    }
  }

  Map<int, SpsInfo> get sequenceParameterSets =>
      Map<int, SpsInfo>.unmodifiable(_spsById);
  Map<int, PpsInfo> get pictureParameterSets =>
      Map<int, PpsInfo>.unmodifiable(_ppsById);

  void reset({bool clearParameterSets = true}) {
    _shortTermReferences.clear();
    _previousReferenceFrameNum = null;
    lastError = null;
    lastStats = null;
    if (clearParameterSets) {
      _spsById.clear();
      _ppsById.clear();
    }
  }

  Yuv420Frame? decodeAccessUnit(List<Uint8List> nals) {
    try {
      final frame = decodeAccessUnitOrThrow(nals);
      lastError = null;
      return frame;
    } catch (error) {
      lastError = error.toString();
      return null;
    }
  }

  Yuv420Frame decodeAccessUnitOrThrow(List<Uint8List> nals) {
    final vclNals = <Uint8List>[];
    for (final nal in nals) {
      if (nal.isEmpty) continue;
      if ((nal.first & 0x80) != 0) {
        throw const FormatException('forbidden_zero_bit is set');
      }
      switch (nal.first & 0x1f) {
        case 1:
        case 5:
          vclNals.add(nal);
          break;
        case 7:
          final sps = parseSpsNal(nal);
          _spsById[sps.spsId] = sps;
          break;
        case 8:
          final provisional = parsePpsNal(nal);
          final sps = _spsById[provisional.spsId];
          final pps = sps == null
              ? provisional
              : parsePpsNal(nal, chromaFormatIdc: sps.chromaFormatIdc);
          _ppsById[pps.ppsId] = pps;
          break;
        default:
          break;
      }
    }
    if (vclNals.isEmpty) {
      throw const FormatException('Access unit contains no VCL slice');
    }

    final headers = <SliceHeader>[
      for (final nal in vclNals)
        parseSliceHeader(nal, ppsById: _ppsById, spsById: _spsById),
    ];
    final first = headers.first;
    _validateSupportedHeader(first);
    for (final header in headers.skip(1)) {
      _validateSupportedHeader(header);
      if (header.frameNum != first.frameNum ||
          header.sps.spsId != first.sps.spsId ||
          header.pps.ppsId != first.pps.ppsId ||
          header.nalUnitType != first.nalUnitType ||
          header.nalRefIdc != first.nalRefIdc ||
          header.idrPicId != first.idrPicId ||
          header.picOrderCntLsb != first.picOrderCntLsb ||
          header.deltaPicOrderCntBottom != first.deltaPicOrderCntBottom ||
          header.deltaPicOrderCnt0 != first.deltaPicOrderCnt0 ||
          header.deltaPicOrderCnt1 != first.deltaPicOrderCnt1 ||
          header.redundantPicCnt != first.redundantPicCnt) {
        throw const FormatException(
          'Access unit contains slices from different pictures',
        );
      }
    }

    if (first.isIdr) {
      _shortTermReferences.clear();
      _previousReferenceFrameNum = null;
    }
    final pictureUsesInterPrediction = headers.any(
      (header) => header.sliceType == H264SliceType.p,
    );
    if (pictureUsesInterPrediction && _shortTermReferences.isEmpty) {
      throw StateError('P picture has no decoded reference picture');
    }
    for (final reference in _shortTermReferences) {
      if (reference.buffer.width != first.sps.codedWidth ||
          reference.buffer.height != first.sps.codedHeight) {
        throw StateError('Reference-picture dimensions changed without an IDR');
      }
    }
    if (!first.isIdr && (pictureUsesInterPrediction || first.nalRefIdc != 0)) {
      _validateFrameNumContinuity(first);
    }

    final state = _FrameState(first.sps);
    var intraCount = 0;
    var interCount = 0;
    var skippedCount = 0;
    for (var sliceId = 0; sliceId < headers.length; sliceId++) {
      final header = headers[sliceId];
      final references = header.sliceType == H264SliceType.p
          ? _buildReferenceList0(header)
          : const <_DecodedPicture>[];
      state.referenceListsBySlice[sliceId] = references;
      state.sliceParameters[sliceId] = H264DeblockingSliceParameters(
        disableDeblockingFilterIdc: header.disableDeblockingFilterIdc,
        sliceAlphaC0OffsetDiv2: header.sliceAlphaC0OffsetDiv2,
        sliceBetaOffsetDiv2: header.sliceBetaOffsetDiv2,
      );
      final result = _decodeSlice(
        header: header,
        state: state,
        references: references,
        sliceId: sliceId,
        initialQpY: header.sliceQpY,
      );
      intraCount += result.intra;
      interCount += result.inter;
      skippedCount += result.skipped;
    }

    final missing = state.macroblocks.indexWhere((meta) => !meta.decoded);
    if (missing != -1) {
      throw FormatException('Picture is missing macroblock $missing');
    }

    if (enableDeblocking) {
      H264DeblockingFilter.apply420(
        luma: state.picture.y,
        cb: state.picture.u,
        cr: state.picture.v,
        codedWidth: first.sps.codedWidth,
        codedHeight: first.sps.codedHeight,
        macroblocks: state.buildDeblockingMetadata(),
        sliceParametersById: state.sliceParameters,
      );
    }

    final decoded = _DecodedPicture(
      pictureId: _pictureId++,
      frameNum: first.frameNum,
      buffer: state.picture,
    );
    if (first.nalRefIdc != 0) {
      _markShortTermReference(decoded, first.sps);
      _previousReferenceFrameNum = first.frameNum;
    }

    lastStats = H264DecodeStats(
      frameNumber: first.frameNum,
      sliceType: first.sliceType,
      macroblockCount: state.macroblocks.length,
      intraMacroblocks: intraCount,
      interMacroblocks: interCount,
      skippedMacroblocks: skippedCount,
      sliceCount: headers.length,
    );
    return _cropPicture(decoded.buffer, first.sps);
  }

  Yuv420Frame? decodeIdrAccessUnit(List<Uint8List> nals) =>
      decodeAccessUnit(nals);

  void _validateSupportedHeader(SliceHeader header) {
    final sps = header.sps;
    final pps = header.pps;
    if (!sps.isSupportedBaseline420) {
      throw FormatException(
        'Unsupported SPS: profile=${sps.profileIdc}, '
        'chroma=${sps.chromaFormatIdc}, bitDepth=${sps.bitDepthLumaMinus8 + 8}, '
        'frameMbsOnly=${sps.frameMbsOnlyFlag}',
      );
    }
    if (sps.codedWidth > maxCodedDimension ||
        sps.codedHeight > maxCodedDimension) {
      throw FormatException(
        'Coded dimensions ${sps.codedWidth}x${sps.codedHeight} exceed '
        'the configured limit $maxCodedDimension',
      );
    }
    final lumaSamples = sps.codedWidth * sps.codedHeight;
    if (lumaSamples > maxLumaSamples) {
      throw FormatException(
        'Coded picture has $lumaSamples luma samples; configured limit is '
        '$maxLumaSamples',
      );
    }
    if (pps.entropyCodingModeFlag) {
      throw const FormatException('CABAC slices are not supported');
    }
    if (header.sliceType == H264SliceType.p && pps.weightedPredFlag) {
      throw const FormatException('Weighted P prediction is not supported');
    }
    if ((header.redundantPicCnt ?? 0) > 0) {
      throw const FormatException('Redundant pictures are not supported');
    }
    if (header.longTermReferenceFlag) {
      throw const FormatException('Long-term IDR references are not supported');
    }
    if (pps.numSliceGroupsMinus1 != 0) {
      throw const FormatException('FMO/slice groups are not supported');
    }
    if (pps.transform8x8ModeFlag || pps.picScalingMatrixPresentFlag) {
      throw const FormatException(
        '8x8 transforms/scaling matrices unsupported',
      );
    }
    if (header.sliceType != H264SliceType.i &&
        header.sliceType != H264SliceType.p) {
      throw FormatException('Unsupported slice type ${header.sliceType.name}');
    }
    if (header.sliceType == H264SliceType.p &&
        header.numRefIdxL0ActiveMinus1 > 31) {
      throw FormatException(
        'num_ref_idx_l0_active_minus1='
        '${header.numRefIdxL0ActiveMinus1} exceeds 31',
      );
    }
    if (header.adaptiveRefPicMarkingModeFlag) {
      throw const FormatException('Adaptive reference marking is unsupported');
    }
  }

  void _validateFrameNumContinuity(SliceHeader header) {
    final previous = _previousReferenceFrameNum;
    if (previous == null) return;
    final expectedFrameNum = (previous + 1) % header.sps.maxFrameNum;
    if (header.frameNum != expectedFrameNum) {
      throw StateError(
        'Unsupported frame_num gap: expected $expectedFrameNum after '
        'reference $previous, got ${header.frameNum}',
      );
    }
  }

  List<_DecodedPicture> _buildReferenceList0(SliceHeader header) {
    return buildPReferenceList0<_DecodedPicture>(
      shortTermReferences: <H264ShortTermReference<_DecodedPicture>>[
        for (final reference in _shortTermReferences)
          H264ShortTermReference<_DecodedPicture>(
            frameNum: reference.frameNum,
            value: reference,
          ),
      ],
      currentFrameNum: header.frameNum,
      maxFrameNum: header.sps.maxFrameNum,
      activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
      modifications: header.refPicListModificationsL0,
    ).map((reference) => reference.value).toList(growable: false);
  }

  void _markShortTermReference(_DecodedPicture picture, SpsInfo sps) {
    final capacity = sps.maxNumRefFrames;
    if (capacity <= 0) {
      _shortTermReferences.clear();
      return;
    }
    while (_shortTermReferences.length >= capacity) {
      var oldestIndex = 0;
      var oldestPicNum = _shortTermPicNum(
        _shortTermReferences.first.frameNum,
        picture.frameNum,
        sps.maxFrameNum,
      );
      for (var index = 1; index < _shortTermReferences.length; index++) {
        final picNum = _shortTermPicNum(
          _shortTermReferences[index].frameNum,
          picture.frameNum,
          sps.maxFrameNum,
        );
        if (picNum < oldestPicNum) {
          oldestIndex = index;
          oldestPicNum = picNum;
        }
      }
      _shortTermReferences.removeAt(oldestIndex);
    }
    _shortTermReferences.add(picture);
  }
}

class H264IdrDecoder extends H264BaselineDecoder {}

class _DecodedPicture {
  final int pictureId;
  final int frameNum;
  final Yuv420PictureBuffer buffer;

  const _DecodedPicture({
    required this.pictureId,
    required this.frameNum,
    required this.buffer,
  });
}

int _shortTermPicNum(int frameNum, int currentFrameNum, int maxFrameNum) =>
    frameNum > currentFrameNum ? frameNum - maxFrameNum : frameNum;

class _MacroblockMeta {
  bool decoded = false;
  bool isIntra = false;
  int sliceId = -1;
  int qpY = 26;
  int qpCb = 26;
  int qpCr = 26;
  int lumaDcTotalCoeff = -1;
  bool usesIntra4x4 = false;
  final List<int> lumaTotalCoeff = List<int>.filled(16, -1);
  final List<int> cbTotalCoeff = List<int>.filled(4, -1);
  final List<int> crTotalCoeff = List<int>.filled(4, -1);
  final List<bool> lumaReconstructed = List<bool>.filled(16, false);
  final List<bool> intraModeKnown = List<bool>.filled(16, false);
}

class _FrameState {
  final SpsInfo sps;
  final int mbWidth;
  final int mbHeight;
  final Yuv420PictureBuffer picture;
  final List<_MacroblockMeta> macroblocks;
  final List<int> intra4x4Modes;
  final MotionFieldGrid motion;
  final Map<int, List<_DecodedPicture>> referenceListsBySlice =
      <int, List<_DecodedPicture>>{};
  final Map<int, H264DeblockingSliceParameters> sliceParameters =
      <int, H264DeblockingSliceParameters>{};

  _FrameState(this.sps)
    : mbWidth = sps.codedWidth >> 4,
      mbHeight = sps.codedHeight >> 4,
      picture = Yuv420PictureBuffer(
        width: sps.codedWidth,
        height: sps.codedHeight,
        y: Uint8List(sps.codedWidth * sps.codedHeight),
        u: Uint8List((sps.codedWidth >> 1) * (sps.codedHeight >> 1)),
        v: Uint8List((sps.codedWidth >> 1) * (sps.codedHeight >> 1)),
      ),
      macroblocks = List<_MacroblockMeta>.generate(
        (sps.codedWidth >> 4) * (sps.codedHeight >> 4),
        (_) => _MacroblockMeta(),
      ),
      intra4x4Modes = List<int>.filled(
        (sps.codedWidth >> 4) * (sps.codedHeight >> 4) * 16,
        2,
      ),
      motion = MotionFieldGrid.forLumaSize(
        width: sps.codedWidth,
        height: sps.codedHeight,
      ) {
    picture.y.fillRange(0, picture.y.length, 128);
    picture.u.fillRange(0, picture.u.length, 128);
    picture.v.fillRange(0, picture.v.length, 128);
  }

  _MacroblockMeta metaAt(int mbX, int mbY) => macroblocks[mbY * mbWidth + mbX];

  bool macroblockAvailable(
    int mbX,
    int mbY, {
    required int sliceId,
    required bool constrainedIntra,
  }) {
    if (mbX < 0 || mbY < 0 || mbX >= mbWidth || mbY >= mbHeight) {
      return false;
    }
    final meta = metaAt(mbX, mbY);
    return meta.decoded &&
        meta.sliceId == sliceId &&
        (!constrainedIntra || meta.isIntra);
  }

  bool lumaBlockAvailable(
    int globalBlockX,
    int globalBlockY, {
    required int currentMbAddr,
    required int sliceId,
    required bool constrainedIntra,
  }) {
    if (globalBlockX < 0 ||
        globalBlockY < 0 ||
        globalBlockX >= mbWidth * 4 ||
        globalBlockY >= mbHeight * 4) {
      return false;
    }
    final mbX = globalBlockX >> 2;
    final mbY = globalBlockY >> 2;
    final mbAddr = mbY * mbWidth + mbX;
    final meta = macroblocks[mbAddr];
    if (meta.sliceId != sliceId || (constrainedIntra && !meta.isIntra)) {
      return false;
    }
    final raster = (globalBlockY & 3) * 4 + (globalBlockX & 3);
    return mbAddr == currentMbAddr
        ? meta.lumaReconstructed[raster]
        : meta.decoded;
  }

  List<H264DeblockingMacroblock> buildDeblockingMetadata() =>
      <H264DeblockingMacroblock>[
        for (var mbAddr = 0; mbAddr < macroblocks.length; mbAddr++)
          _buildDeblockingMacroblock(mbAddr),
      ];

  H264DeblockingMacroblock _buildDeblockingMacroblock(int mbAddr) {
    final meta = macroblocks[mbAddr];
    final references = referenceListsBySlice[meta.sliceId];
    final mbX = mbAddr % mbWidth;
    final mbY = mbAddr ~/ mbWidth;
    final blocks = <H264DeblockingBlock>[];
    for (var raster = 0; raster < 16; raster++) {
      final bx = raster & 3;
      final by = raster >> 2;
      final entry = motion.entryAt4x4(mbX * 4 + bx, mbY * 4 + by);
      blocks.add(
        H264DeblockingBlock(
          totalCoeff: _nonNegative(meta.lumaTotalCoeff[raster]),
          referenceIndexL0: entry.referenceIndex,
          referencePictureId:
              entry.referenceIndex >= 0 &&
                  references != null &&
                  entry.referenceIndex < references.length
              ? references[entry.referenceIndex].pictureId
              : null,
          motionVectorL0: H264MotionVector(entry.vector.x, entry.vector.y),
        ),
      );
    }
    return H264DeblockingMacroblock(
      isIntra: meta.isIntra,
      qpY: meta.qpY,
      qpCb: meta.qpCb,
      qpCr: meta.qpCr,
      lumaBlocks: blocks,
      cbTotalCoeff: <int>[
        for (final value in meta.cbTotalCoeff) _nonNegative(value),
      ],
      crTotalCoeff: <int>[
        for (final value in meta.crTotalCoeff) _nonNegative(value),
      ],
      sliceId: meta.sliceId,
    );
  }
}

int _nonNegative(int value) => value < 0 ? 0 : value;

const List<int> _lumaBlockX = <int>[
  0,
  1,
  0,
  1,
  2,
  3,
  2,
  3,
  0,
  1,
  0,
  1,
  2,
  3,
  2,
  3,
];
const List<int> _lumaBlockY = <int>[
  0,
  0,
  1,
  1,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  2,
  2,
  3,
  3,
];

const List<int> _codedBlockPatternIntra = <int>[
  47,
  31,
  15,
  0,
  23,
  27,
  29,
  30,
  7,
  11,
  13,
  14,
  39,
  43,
  45,
  46,
  16,
  3,
  5,
  10,
  12,
  19,
  21,
  26,
  28,
  35,
  37,
  42,
  44,
  1,
  2,
  4,
  8,
  17,
  18,
  20,
  24,
  6,
  9,
  22,
  25,
  32,
  33,
  34,
  36,
  40,
  38,
  41,
];

const List<int> _codedBlockPatternInter = <int>[
  0,
  16,
  1,
  2,
  4,
  8,
  32,
  3,
  5,
  10,
  12,
  15,
  47,
  7,
  11,
  13,
  14,
  6,
  9,
  31,
  35,
  37,
  42,
  44,
  33,
  34,
  36,
  40,
  39,
  43,
  45,
  46,
  17,
  18,
  20,
  24,
  19,
  21,
  26,
  28,
  23,
  27,
  29,
  30,
  22,
  25,
  38,
  41,
];

typedef _SliceDecodeResult = ({int qpY, int intra, int inter, int skipped});

_SliceDecodeResult _decodeSlice({
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> references,
  required int sliceId,
  required int initialQpY,
}) {
  final reader = header.reader;
  final mbCount = state.macroblocks.length;
  var mbAddr = header.firstMbInSlice;
  if (mbAddr < 0 || mbAddr >= mbCount) {
    throw FormatException('first_mb_in_slice=$mbAddr is outside the picture');
  }

  var qpY = initialQpY;
  var intra = 0;
  var inter = 0;
  var skipped = 0;

  while (mbAddr < mbCount && moreRbspData(reader)) {
    if (header.sliceType == H264SliceType.p) {
      final skipRun = readUE(reader);
      if (skipRun > mbCount - mbAddr) {
        throw FormatException(
          'mb_skip_run=$skipRun exceeds ${mbCount - mbAddr} remaining MBs',
        );
      }
      for (var i = 0; i < skipRun; i++) {
        _decodeSkippedMacroblock(
          state: state,
          reference: references.first,
          header: header,
          mbAddr: mbAddr,
          sliceId: sliceId,
          qpY: qpY,
        );
        mbAddr++;
        skipped++;
      }
      if (mbAddr >= mbCount || !moreRbspData(reader)) break;
    }

    final int macroblockStart = reader.bitPos;
    final _MacroblockDecodeResult result;
    try {
      result = _decodeMacroblock(
        reader: reader,
        header: header,
        state: state,
        references: references,
        mbAddr: mbAddr,
        sliceId: sliceId,
        previousQpY: qpY,
      );
    } catch (error) {
      throw FormatException(
        'Macroblock $mbAddr failed at bit ${reader.bitPos} '
        '(start $macroblockStart): $error',
      );
    }
    qpY = result.qpY;
    if (result.isIntra) {
      intra++;
    } else {
      inter++;
    }
    mbAddr++;
  }

  readRbspTrailingBits(reader);
  return (qpY: qpY, intra: intra, inter: inter, skipped: skipped);
}

void _decodeSkippedMacroblock({
  required _FrameState state,
  required _DecodedPicture reference,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
  required int qpY,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final x = mbX * 16;
  final y = mbY * 16;
  final vector = derivePSkipMotionVector(
    grid: state.motion,
    macroblockX: x,
    macroblockY: y,
    currentSliceId: sliceId,
  );
  writeInterPrediction420(
    reference: reference.buffer,
    destination: state.picture,
    x: x,
    y: y,
    width: 16,
    height: 16,
    motionVector: vector,
  );
  state.motion.setPartition(
    x: x,
    y: y,
    width: 16,
    height: 16,
    vector: vector,
    referenceIndex: 0,
    sliceId: sliceId,
  );

  final meta = state.macroblocks[mbAddr];
  meta
    ..decoded = true
    ..isIntra = false
    ..sliceId = sliceId
    ..qpY = qpY
    ..qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset)
    ..qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset)
    ..lumaDcTotalCoeff = 0;
  meta.lumaTotalCoeff.fillRange(0, 16, 0);
  meta.cbTotalCoeff.fillRange(0, 4, 0);
  meta.crTotalCoeff.fillRange(0, 4, 0);
  meta.lumaReconstructed.fillRange(0, 16, true);
}

typedef _MacroblockDecodeResult = ({int qpY, bool isIntra});

_MacroblockDecodeResult _decodeMacroblock({
  required BitReader reader,
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> references,
  required int mbAddr,
  required int sliceId,
  required int previousQpY,
}) {
  final codedType = readUE(reader);
  final isPSlice = header.sliceType == H264SliceType.p;
  final isInter = isPSlice && codedType <= 4;
  final intraType = isInter ? -1 : codedType - (isPSlice ? 5 : 0);
  h264DecoderTrace?.call(
    'mb=$mbAddr start=${reader.bitPos} codedType=$codedType '
    'intraType=$intraType',
  );
  if (!isInter && (intraType < 0 || intraType > 25)) {
    throw FormatException(
      'Invalid ${header.sliceType.name} mb_type=$codedType at MB $mbAddr',
    );
  }

  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final meta = state.macroblocks[mbAddr];
  if (meta.decoded) throw FormatException('Macroblock $mbAddr decoded twice');
  meta
    ..sliceId = sliceId
    ..isIntra = !isInter;

  if (intraType == 25) {
    _decodePcmMacroblock(reader, state, mbAddr, sliceId);
    return (qpY: previousQpY, isIntra: true);
  }

  final isIntra4x4 = intraType == 0;
  final isIntra16x16 = intraType >= 1 && intraType <= 24;
  meta.usesIntra4x4 = isIntra4x4;

  var intra16Mode = 2;
  var intraChromaMode = 0;
  var codedBlockPatternLuma = 0;
  var codedBlockPatternChroma = 0;

  if (isInter) {
    _decodeInterPrediction(
      reader: reader,
      header: header,
      state: state,
      references: references,
      mbAddr: mbAddr,
      sliceId: sliceId,
      codedType: codedType,
    );
    final code = readUE(reader);
    if (code >= _codedBlockPatternInter.length) {
      throw FormatException('Invalid inter coded_block_pattern code $code');
    }
    final pattern = _codedBlockPatternInter[code];
    codedBlockPatternLuma = pattern & 15;
    codedBlockPatternChroma = pattern >> 4;
  } else if (isIntra16x16) {
    final value = intraType - 1;
    intra16Mode = value & 3;
    final group = value ~/ 4;
    codedBlockPatternChroma = group % 3;
    codedBlockPatternLuma = group >= 3 ? 15 : 0;
    intraChromaMode = readUE(reader);
    _validateIntraChromaMode(intraChromaMode);
  } else {
    _readIntra4x4Modes(
      reader: reader,
      state: state,
      mbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: header.pps.constrainedIntraPredFlag,
    );
    intraChromaMode = readUE(reader);
    _validateIntraChromaMode(intraChromaMode);
    final code = readUE(reader);
    if (code >= _codedBlockPatternIntra.length) {
      throw FormatException('Invalid intra coded_block_pattern code $code');
    }
    final pattern = _codedBlockPatternIntra[code];
    codedBlockPatternLuma = pattern & 15;
    codedBlockPatternChroma = pattern >> 4;
  }

  var qpY = previousQpY;
  if (isIntra16x16 ||
      codedBlockPatternLuma != 0 ||
      codedBlockPatternChroma != 0) {
    final delta = readSE(reader);
    qpY = (previousQpY + delta + 52) % 52;
  }
  final qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset);
  final qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset);
  meta
    ..qpY = qpY
    ..qpCb = qpCb
    ..qpCr = qpCr;

  final residual = _decodeResidual(
    reader: reader,
    state: state,
    mbAddr: mbAddr,
    isIntra16x16: isIntra16x16,
    codedBlockPatternLuma: codedBlockPatternLuma,
    codedBlockPatternChroma: codedBlockPatternChroma,
  );
  h264DecoderTrace?.call(
    'mb=$mbAddr residualEnd=${reader.bitPos} i4=$isIntra4x4 '
    'i16=$isIntra16x16 cbpL=$codedBlockPatternLuma '
    'cbpC=$codedBlockPatternChroma qp=$qpY',
  );

  if (isIntra16x16) {
    _reconstructIntra16(
      state: state,
      header: header,
      mbAddr: mbAddr,
      sliceId: sliceId,
      mode: intra16Mode,
      qpY: qpY,
      lumaCoefficients: residual.luma,
    );
  } else if (isIntra4x4) {
    _reconstructIntra4x4(
      state: state,
      header: header,
      mbAddr: mbAddr,
      sliceId: sliceId,
      qpY: qpY,
      lumaCoefficients: residual.luma,
    );
  } else {
    _addInterLumaResidual(state, mbAddr, qpY, residual.luma);
  }

  if (isInter) {
    _addInterChromaResidual(
      state: state,
      mbAddr: mbAddr,
      qpCb: qpCb,
      qpCr: qpCr,
      cbCoefficients: residual.cb,
      crCoefficients: residual.cr,
    );
  } else {
    _reconstructIntraChroma(
      state: state,
      header: header,
      mbAddr: mbAddr,
      sliceId: sliceId,
      mode: intraChromaMode,
      qpCb: qpCb,
      qpCr: qpCr,
      cbCoefficients: residual.cb,
      crCoefficients: residual.cr,
    );
    state.motion.setIntraPartition(
      x: mbX * 16,
      y: mbY * 16,
      width: 16,
      height: 16,
      sliceId: sliceId,
    );
  }

  meta
    ..decoded = true
    ..lumaDcTotalCoeff = _nonNegative(meta.lumaDcTotalCoeff);
  for (var i = 0; i < 16; i++) {
    if (meta.lumaTotalCoeff[i] < 0) meta.lumaTotalCoeff[i] = 0;
    meta.lumaReconstructed[i] = true;
  }
  for (var i = 0; i < 4; i++) {
    if (meta.cbTotalCoeff[i] < 0) meta.cbTotalCoeff[i] = 0;
    if (meta.crTotalCoeff[i] < 0) meta.crTotalCoeff[i] = 0;
  }
  return (qpY: qpY, isIntra: !isInter);
}

void _validateIntraChromaMode(int mode) {
  if (mode < 0 || mode > 3) {
    throw FormatException('Invalid intra_chroma_pred_mode=$mode');
  }
}

void _decodePcmMacroblock(
  BitReader reader,
  _FrameState state,
  int mbAddr,
  int sliceId,
) {
  while ((reader.bitPos & 7) != 0) {
    if (reader.readBit() != 0) {
      throw FormatException('pcm_alignment_zero_bit is not zero at MB $mbAddr');
    }
  }
  final luma = reader.readBytes(256);
  final cb = reader.readBytes(64);
  final cr = reader.readBytes(64);
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final x0 = mbX * 16;
  final y0 = mbY * 16;
  for (var y = 0; y < 16; y++) {
    final destination = (y0 + y) * state.picture.lumaStride + x0;
    state.picture.y.setRange(destination, destination + 16, luma, y * 16);
  }
  final cx0 = mbX * 8;
  final cy0 = mbY * 8;
  for (var y = 0; y < 8; y++) {
    final destination = (cy0 + y) * state.picture.chromaStride + cx0;
    state.picture.u.setRange(destination, destination + 8, cb, y * 8);
    state.picture.v.setRange(destination, destination + 8, cr, y * 8);
  }

  final meta = state.macroblocks[mbAddr];
  meta
    ..decoded = true
    ..isIntra = true
    ..sliceId = sliceId
    ..qpY = 0
    ..qpCb = 0
    ..qpCr = 0
    ..lumaDcTotalCoeff = 16;
  meta.lumaTotalCoeff.fillRange(0, 16, 16);
  meta.cbTotalCoeff.fillRange(0, 4, 16);
  meta.crTotalCoeff.fillRange(0, 4, 16);
  meta.lumaReconstructed.fillRange(0, 16, true);
  state.motion.setIntraPartition(
    x: x0,
    y: y0,
    width: 16,
    height: 16,
    sliceId: sliceId,
  );
}

void _readIntra4x4Modes({
  required BitReader reader,
  required _FrameState state,
  required int mbAddr,
  required int sliceId,
  required bool constrainedIntra,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final meta = state.macroblocks[mbAddr];
  for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
    final bx = _lumaBlockX[syntaxBlock];
    final by = _lumaBlockY[syntaxBlock];
    final raster = by * 4 + bx;
    final left = _intraModeNeighbour(
      state,
      globalBlockX: mbX * 4 + bx - 1,
      globalBlockY: mbY * 4 + by,
      currentMbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: constrainedIntra,
    );
    final top = _intraModeNeighbour(
      state,
      globalBlockX: mbX * 4 + bx,
      globalBlockY: mbY * 4 + by - 1,
      currentMbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: constrainedIntra,
    );
    final predicted = mostProbableIntra4x4Mode(
      leftAvail: left.available,
      topAvail: top.available,
      leftMode: left.mode,
      topMode: top.mode,
    );
    final modeStart = reader.bitPos;
    final previousFlag = reader.readBit();
    final int mode;
    if (previousFlag == 1) {
      mode = predicted;
    } else {
      mode = mapRemToMode(predicted, reader.readBits(3));
    }
    h264DecoderTrace?.call(
      'mb=$mbAddr intra4syntax=$syntaxBlock raster=$raster '
      'modeStart=$modeStart prev=$previousFlag mode=$mode end=${reader.bitPos}',
    );
    if (mode < 0 || mode > 8) {
      throw FormatException('Invalid Intra4x4 prediction mode $mode');
    }
    state.intra4x4Modes[mbAddr * 16 + raster] = mode;
    meta.intraModeKnown[raster] = true;
  }
}

({bool available, int mode}) _intraModeNeighbour(
  _FrameState state, {
  required int globalBlockX,
  required int globalBlockY,
  required int currentMbAddr,
  required int sliceId,
  required bool constrainedIntra,
}) {
  if (globalBlockX < 0 ||
      globalBlockY < 0 ||
      globalBlockX >= state.mbWidth * 4 ||
      globalBlockY >= state.mbHeight * 4) {
    return (available: false, mode: 2);
  }
  final mbX = globalBlockX >> 2;
  final mbY = globalBlockY >> 2;
  final mbAddr = mbY * state.mbWidth + mbX;
  final meta = state.macroblocks[mbAddr];
  if (meta.sliceId != sliceId || (constrainedIntra && !meta.isIntra)) {
    return (available: false, mode: 2);
  }
  final raster = (globalBlockY & 3) * 4 + (globalBlockX & 3);
  if (mbAddr == currentMbAddr) {
    if (!meta.intraModeKnown[raster]) return (available: false, mode: 2);
  } else if (!meta.decoded) {
    return (available: false, mode: 2);
  }
  final mode = meta.usesIntra4x4
      ? state.intra4x4Modes[mbAddr * 16 + raster]
      : 2;
  return (available: true, mode: mode);
}

class _InterPartition {
  final int x;
  final int y;
  final int width;
  final int height;
  final InterPartitionKind kind;
  final int partitionIndex;
  int referenceIndex;

  _InterPartition({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.kind,
    this.partitionIndex = 0,
    this.referenceIndex = 0,
  });
}

void _decodeInterPrediction({
  required BitReader reader,
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> references,
  required int mbAddr,
  required int sliceId,
  required int codedType,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final originX = mbX * 16;
  final originY = mbY * 16;
  final partitions = <_InterPartition>[];

  if (codedType == 0) {
    partitions.add(
      _InterPartition(
        x: originX,
        y: originY,
        width: 16,
        height: 16,
        kind: InterPartitionKind.p16x16,
      ),
    );
  } else if (codedType == 1) {
    for (var index = 0; index < 2; index++) {
      partitions.add(
        _InterPartition(
          x: originX,
          y: originY + index * 8,
          width: 16,
          height: 8,
          kind: InterPartitionKind.p16x8,
          partitionIndex: index,
        ),
      );
    }
  } else if (codedType == 2) {
    for (var index = 0; index < 2; index++) {
      partitions.add(
        _InterPartition(
          x: originX + index * 8,
          y: originY,
          width: 8,
          height: 16,
          kind: InterPartitionKind.p8x16,
          partitionIndex: index,
        ),
      );
    }
  } else {
    final subTypes = <int>[for (var i = 0; i < 4; i++) readUE(reader)];
    for (final type in subTypes) {
      if (type < 0 || type > 3) {
        throw FormatException('Invalid P sub_mb_type=$type');
      }
    }
    final referenceIndices = List<int>.filled(4, 0);
    if (codedType == 3 && header.numRefIdxL0ActiveMinus1 > 0) {
      for (var i = 0; i < 4; i++) {
        referenceIndices[i] = readTE(reader, header.numRefIdxL0ActiveMinus1);
      }
    }
    for (var subMb = 0; subMb < 4; subMb++) {
      final baseX = originX + (subMb & 1) * 8;
      final baseY = originY + (subMb >> 1) * 8;
      final ref = referenceIndices[subMb];
      switch (subTypes[subMb]) {
        case 0:
          partitions.add(
            _InterPartition(
              x: baseX,
              y: baseY,
              width: 8,
              height: 8,
              kind: InterPartitionKind.subMacroblock,
              referenceIndex: ref,
            ),
          );
          break;
        case 1:
          for (var part = 0; part < 2; part++) {
            partitions.add(
              _InterPartition(
                x: baseX,
                y: baseY + part * 4,
                width: 8,
                height: 4,
                kind: InterPartitionKind.subMacroblock,
                referenceIndex: ref,
              ),
            );
          }
          break;
        case 2:
          for (var part = 0; part < 2; part++) {
            partitions.add(
              _InterPartition(
                x: baseX + part * 4,
                y: baseY,
                width: 4,
                height: 8,
                kind: InterPartitionKind.subMacroblock,
                referenceIndex: ref,
              ),
            );
          }
          break;
        case 3:
          for (var part = 0; part < 4; part++) {
            partitions.add(
              _InterPartition(
                x: baseX + (part & 1) * 4,
                y: baseY + (part >> 1) * 4,
                width: 4,
                height: 4,
                kind: InterPartitionKind.subMacroblock,
                referenceIndex: ref,
              ),
            );
          }
          break;
      }
    }
  }

  if (codedType <= 2 && header.numRefIdxL0ActiveMinus1 > 0) {
    for (final partition in partitions) {
      partition.referenceIndex = readTE(reader, header.numRefIdxL0ActiveMinus1);
    }
  }

  for (final partition in partitions) {
    if (partition.referenceIndex >= references.length) {
      throw FormatException(
        'Reference index ${partition.referenceIndex} is unavailable in a '
        '${references.length}-entry list 0',
      );
    }
    final difference = MotionVector(readSE(reader), readSE(reader));
    final predictor = deriveMotionVectorPredictor(
      grid: state.motion,
      partitionX: partition.x,
      partitionY: partition.y,
      partitionWidth: partition.width,
      partitionHeight: partition.height,
      referenceIndex: partition.referenceIndex,
      partitionKind: partition.kind,
      partitionIndex: partition.partitionIndex,
      currentSliceId: sliceId,
    );
    final vector = predictor + difference;
    writeInterPrediction420(
      reference: references[partition.referenceIndex].buffer,
      destination: state.picture,
      x: partition.x,
      y: partition.y,
      width: partition.width,
      height: partition.height,
      motionVector: vector,
    );
    state.motion.setPartition(
      x: partition.x,
      y: partition.y,
      width: partition.width,
      height: partition.height,
      vector: vector,
      referenceIndex: partition.referenceIndex,
      sliceId: sliceId,
    );
  }
}

typedef _ResidualData = ({
  List<List<int>> luma,
  List<List<int>> cb,
  List<List<int>> cr,
});

_ResidualData _decodeResidual({
  required BitReader reader,
  required _FrameState state,
  required int mbAddr,
  required bool isIntra16x16,
  required int codedBlockPatternLuma,
  required int codedBlockPatternChroma,
}) {
  final meta = state.macroblocks[mbAddr];
  final sliceId = meta.sliceId;
  final luma = List<List<int>>.generate(16, (_) => List<int>.filled(16, 0));
  final cb = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
  final cr = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));

  if (isIntra16x16) {
    // Intra16x16DCLevel uses the same neighbouring luma 4x4 TotalCoeff
    // derivation as block 0. It must not use neighbouring DC-block counts.
    final dcNc = _nCLuma(state, mbAddr, 0, 0, sliceId);
    coeffTokenDebugContext = 'mb=$mbAddr Intra16DC nC=$dcNc';
    final dc = decodeResidual4x4(reader, dcNc);
    meta.lumaDcTotalCoeff = dc.totalCoeff;
    for (var raster = 0; raster < 16; raster++) {
      luma[raster][0] = dc.coeffs[raster];
    }
    for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
      final bx = _lumaBlockX[syntaxBlock];
      final by = _lumaBlockY[syntaxBlock];
      final raster = by * 4 + bx;
      final group = syntaxBlock >> 2;
      if ((codedBlockPatternLuma & (1 << group)) == 0) {
        meta.lumaTotalCoeff[raster] = 0;
        continue;
      }
      final nC = _nCLuma(state, mbAddr, bx, by, sliceId);
      coeffTokenDebugContext =
          'mb=$mbAddr Intra16AC block=$syntaxBlock raster=$raster nC=$nC';
      final residual = decodeResidual4x4Ac(reader, nC);
      meta.lumaTotalCoeff[raster] = residual.totalCoeff;
      for (var coefficient = 1; coefficient < 16; coefficient++) {
        luma[raster][coefficient] = residual.coeffs[coefficient];
      }
    }
  } else {
    meta.lumaDcTotalCoeff = 0;
    for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
      final bx = _lumaBlockX[syntaxBlock];
      final by = _lumaBlockY[syntaxBlock];
      final raster = by * 4 + bx;
      final group = syntaxBlock >> 2;
      if ((codedBlockPatternLuma & (1 << group)) == 0) {
        meta.lumaTotalCoeff[raster] = 0;
        continue;
      }
      final nC = _nCLuma(state, mbAddr, bx, by, sliceId);
      coeffTokenDebugContext =
          'mb=$mbAddr Luma block=$syntaxBlock raster=$raster nC=$nC';
      final residual = decodeResidual4x4(reader, nC);
      meta.lumaTotalCoeff[raster] = residual.totalCoeff;
      luma[raster] = List<int>.from(residual.coeffs);
    }
  }

  if (codedBlockPatternChroma == 0) {
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
    coeffTokenDebugContext = '';
    return (luma: luma, cb: cb, cr: cr);
  }

  coeffTokenDebugContext = 'mb=$mbAddr ChromaDC Cb';
  final cbDc = decodeChromaDC2x2(reader);
  coeffTokenDebugContext = 'mb=$mbAddr ChromaDC Cr';
  final crDc = decodeChromaDC2x2(reader);
  for (var block = 0; block < 4; block++) {
    cb[block][0] = cbDc.coeffs4[block];
    cr[block][0] = crDc.coeffs4[block];
  }

  if (codedBlockPatternChroma == 2) {
    for (var block = 0; block < 4; block++) {
      final bx = block & 1;
      final by = block >> 1;
      final nC = _nCChroma(state, mbAddr, bx, by, sliceId, isCb: true);
      coeffTokenDebugContext = 'mb=$mbAddr ChromaAC Cb block=$block nC=$nC';
      final residual = decodeResidual4x4Ac(reader, nC);
      meta.cbTotalCoeff[block] = residual.totalCoeff;
      for (var coefficient = 1; coefficient < 16; coefficient++) {
        cb[block][coefficient] = residual.coeffs[coefficient];
      }
    }
    for (var block = 0; block < 4; block++) {
      final bx = block & 1;
      final by = block >> 1;
      final nC = _nCChroma(state, mbAddr, bx, by, sliceId, isCb: false);
      coeffTokenDebugContext = 'mb=$mbAddr ChromaAC Cr block=$block nC=$nC';
      final residual = decodeResidual4x4Ac(reader, nC);
      meta.crTotalCoeff[block] = residual.totalCoeff;
      for (var coefficient = 1; coefficient < 16; coefficient++) {
        cr[block][coefficient] = residual.coeffs[coefficient];
      }
    }
  } else {
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
  }
  coeffTokenDebugContext = '';
  return (luma: luma, cb: cb, cr: cr);
}

int _nCLuma(_FrameState state, int mbAddr, int bx, int by, int sliceId) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  int? left;
  int? top;
  if (bx > 0) {
    left = _known(state.macroblocks[mbAddr].lumaTotalCoeff[by * 4 + bx - 1]);
  } else if (mbX > 0) {
    final neighbor = state.metaAt(mbX - 1, mbY);
    if (neighbor.decoded && neighbor.sliceId == sliceId) {
      left = _known(neighbor.lumaTotalCoeff[by * 4 + 3]);
    }
  }
  if (by > 0) {
    top = _known(state.macroblocks[mbAddr].lumaTotalCoeff[(by - 1) * 4 + bx]);
  } else if (mbY > 0) {
    final neighbor = state.metaAt(mbX, mbY - 1);
    if (neighbor.decoded && neighbor.sliceId == sliceId) {
      top = _known(neighbor.lumaTotalCoeff[12 + bx]);
    }
  }
  return _combineNc(left, top);
}

int _nCChroma(
  _FrameState state,
  int mbAddr,
  int bx,
  int by,
  int sliceId, {
  required bool isCb,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  List<int> values(_MacroblockMeta meta) =>
      isCb ? meta.cbTotalCoeff : meta.crTotalCoeff;
  int? left;
  int? top;
  if (bx > 0) {
    left = _known(values(state.macroblocks[mbAddr])[by * 2 + bx - 1]);
  } else if (mbX > 0) {
    final neighbor = state.metaAt(mbX - 1, mbY);
    if (neighbor.decoded && neighbor.sliceId == sliceId) {
      left = _known(values(neighbor)[by * 2 + 1]);
    }
  }
  if (by > 0) {
    top = _known(values(state.macroblocks[mbAddr])[(by - 1) * 2 + bx]);
  } else if (mbY > 0) {
    final neighbor = state.metaAt(mbX, mbY - 1);
    if (neighbor.decoded && neighbor.sliceId == sliceId) {
      top = _known(values(neighbor)[2 + bx]);
    }
  }
  return _combineNc(left, top);
}

int? _known(int value) => value < 0 ? null : value;

int _combineNc(int? left, int? top) {
  if (left == null && top == null) return 0;
  if (left == null) return top!;
  if (top == null) return left;
  return (left + top + 1) >> 1;
}

void _reconstructIntra16({
  required _FrameState state,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
  required int mode,
  required int qpY,
  required List<List<int>> lumaCoefficients,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final constrained = header.pps.constrainedIntraPredFlag;
  final topAvailable = state.macroblockAvailable(
    mbX,
    mbY - 1,
    sliceId: sliceId,
    constrainedIntra: constrained,
  );
  final leftAvailable = state.macroblockAvailable(
    mbX - 1,
    mbY,
    sliceId: sliceId,
    constrainedIntra: constrained,
  );
  final topLeftAvailable = state.macroblockAvailable(
    mbX - 1,
    mbY - 1,
    sliceId: sliceId,
    constrainedIntra: constrained,
  );
  final prediction = List<int>.filled(256, 128);
  predictIntra16(
    mode: mode,
    mbX: mbX,
    mbY: mbY,
    width: state.sps.codedWidth,
    height: state.sps.codedHeight,
    yPlane: state.picture.y,
    out16: prediction,
    topAvailable: topAvailable,
    leftAvailable: leftAvailable,
    topLeftAvailable: topLeftAvailable,
  );

  applyIntra16LumaDcHadamard(lumaCoefficients, qp: qpY);
  final residuals = <List<int>>[
    for (final coefficients in lumaCoefficients)
      invTransform4x4(coefficients, qp: qpY, dcAlreadyScaled: true),
  ];
  _writeLumaMacroblock(state.picture, mbX, mbY, prediction, residuals);
  state.macroblocks[mbAddr].lumaReconstructed.fillRange(0, 16, true);
}

void _reconstructIntra4x4({
  required _FrameState state,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
  required int qpY,
  required List<List<int>> lumaCoefficients,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final constrained = header.pps.constrainedIntraPredFlag;
  final meta = state.macroblocks[mbAddr];

  for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
    final bx = _lumaBlockX[syntaxBlock];
    final by = _lumaBlockY[syntaxBlock];
    final raster = by * 4 + bx;
    final globalX = mbX * 4 + bx;
    final globalY = mbY * 4 + by;
    bool available(int x, int y) => state.lumaBlockAvailable(
      x,
      y,
      currentMbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: constrained,
    );

    final topAvailable = available(globalX, globalY - 1);
    final leftAvailable = available(globalX - 1, globalY);
    final topLeftAvailable = available(globalX - 1, globalY - 1);
    final topRightAvailable = available(globalX + 1, globalY - 1);
    final sampleX = globalX * 4;
    final sampleY = globalY * 4;
    final top = List<int>.filled(8, 128);
    if (topAvailable) {
      final row = (sampleY - 1) * state.picture.lumaStride;
      for (var x = 0; x < 4; x++) {
        top[x] = state.picture.y[row + sampleX + x];
      }
    }
    if (topRightAvailable) {
      final row = (sampleY - 1) * state.picture.lumaStride;
      for (var x = 4; x < 8; x++) {
        top[x] = state.picture.y[row + sampleX + x];
      }
    } else {
      for (var x = 4; x < 8; x++) {
        top[x] = top[3];
      }
    }
    final left = List<int>.filled(4, 128);
    if (leftAvailable) {
      for (var y = 0; y < 4; y++) {
        left[y] = state
            .picture
            .y[(sampleY + y) * state.picture.lumaStride + sampleX - 1];
      }
    }
    final topLeft = topLeftAvailable
        ? state.picture.y[(sampleY - 1) * state.picture.lumaStride +
              sampleX -
              1]
        : 128;
    final prediction = List<int>.filled(16, 128);
    predictIntra4x4(
      mode: state.intra4x4Modes[mbAddr * 16 + raster],
      top: top,
      left: left,
      topLeft: topLeft,
      out: prediction,
      topAvailable: topAvailable,
      leftAvailable: leftAvailable,
      topLeftAvailable: topLeftAvailable,
      topRightAvailable: topRightAvailable,
    );
    final residual = invTransform4x4(lumaCoefficients[raster], qp: qpY);
    _write4x4PredictionAndResidual(
      plane: state.picture.y,
      stride: state.picture.lumaStride,
      x: sampleX,
      y: sampleY,
      prediction: prediction,
      residual: residual,
    );
    meta.lumaReconstructed[raster] = true;
  }
}

void _reconstructIntraChroma({
  required _FrameState state,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
  required int mode,
  required int qpCb,
  required int qpCr,
  required List<List<int>> cbCoefficients,
  required List<List<int>> crCoefficients,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final constrained = header.pps.constrainedIntraPredFlag;
  final topAvailable = state.macroblockAvailable(
    mbX,
    mbY - 1,
    sliceId: sliceId,
    constrainedIntra: constrained,
  );
  final leftAvailable = state.macroblockAvailable(
    mbX - 1,
    mbY,
    sliceId: sliceId,
    constrainedIntra: constrained,
  );
  final topLeftAvailable = state.macroblockAvailable(
    mbX - 1,
    mbY - 1,
    sliceId: sliceId,
    constrainedIntra: constrained,
  );
  final predictionCb = predictIntraChroma8x8(
    mode: mode,
    plane: state.picture.u,
    width: state.sps.codedWidth,
    height: state.sps.codedHeight,
    mbX: mbX,
    mbY: mbY,
    topAvailable: topAvailable,
    leftAvailable: leftAvailable,
    topLeftAvailable: topLeftAvailable,
  );
  final predictionCr = predictIntraChroma8x8(
    mode: mode,
    plane: state.picture.v,
    width: state.sps.codedWidth,
    height: state.sps.codedHeight,
    mbX: mbX,
    mbY: mbY,
    topAvailable: topAvailable,
    leftAvailable: leftAvailable,
    topLeftAvailable: topLeftAvailable,
  );
  final residualCb = _transformChroma(cbCoefficients, qpCb);
  final residualCr = _transformChroma(crCoefficients, qpCr);
  _writeChromaMacroblock(
    plane: state.picture.u,
    stride: state.picture.chromaStride,
    mbX: mbX,
    mbY: mbY,
    prediction: predictionCb,
    residuals: residualCb,
  );
  _writeChromaMacroblock(
    plane: state.picture.v,
    stride: state.picture.chromaStride,
    mbX: mbX,
    mbY: mbY,
    prediction: predictionCr,
    residuals: residualCr,
  );
}

void _addInterLumaResidual(
  _FrameState state,
  int mbAddr,
  int qpY,
  List<List<int>> coefficients,
) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  for (var raster = 0; raster < 16; raster++) {
    final residual = invTransform4x4(coefficients[raster], qp: qpY);
    _add4x4Residual(
      plane: state.picture.y,
      stride: state.picture.lumaStride,
      x: mbX * 16 + (raster & 3) * 4,
      y: mbY * 16 + (raster >> 2) * 4,
      residual: residual,
    );
  }
  state.macroblocks[mbAddr].lumaReconstructed.fillRange(0, 16, true);
}

void _addInterChromaResidual({
  required _FrameState state,
  required int mbAddr,
  required int qpCb,
  required int qpCr,
  required List<List<int>> cbCoefficients,
  required List<List<int>> crCoefficients,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final residualCb = _transformChroma(cbCoefficients, qpCb);
  final residualCr = _transformChroma(crCoefficients, qpCr);
  for (var block = 0; block < 4; block++) {
    final x = mbX * 8 + (block & 1) * 4;
    final y = mbY * 8 + (block >> 1) * 4;
    _add4x4Residual(
      plane: state.picture.u,
      stride: state.picture.chromaStride,
      x: x,
      y: y,
      residual: residualCb[block],
    );
    _add4x4Residual(
      plane: state.picture.v,
      stride: state.picture.chromaStride,
      x: x,
      y: y,
      residual: residualCr[block],
    );
  }
}

List<List<int>> _transformChroma(List<List<int>> coefficients, int qp) {
  final rawDc = <int>[for (final block in coefficients) block[0]];
  final scaledDc = inverseChromaDc2x2(rawDc, qp: qp);
  final output = <List<int>>[];
  for (var block = 0; block < 4; block++) {
    final values = List<int>.from(coefficients[block]);
    values[0] = scaledDc[block];
    output.add(invTransform4x4(values, qp: qp, dcAlreadyScaled: true));
  }
  return output;
}

void _writeLumaMacroblock(
  Yuv420PictureBuffer picture,
  int mbX,
  int mbY,
  List<int> prediction,
  List<List<int>> residuals,
) {
  for (var y = 0; y < 16; y++) {
    final row = (mbY * 16 + y) * picture.lumaStride + mbX * 16;
    for (var x = 0; x < 16; x++) {
      final raster = (y >> 2) * 4 + (x >> 2);
      final residual = residuals[raster][(y & 3) * 4 + (x & 3)];
      picture.y[row + x] = clip8(prediction[y * 16 + x] + residual);
    }
  }
}

void _writeChromaMacroblock({
  required Uint8List plane,
  required int stride,
  required int mbX,
  required int mbY,
  required List<int> prediction,
  required List<List<int>> residuals,
}) {
  for (var y = 0; y < 8; y++) {
    final row = (mbY * 8 + y) * stride + mbX * 8;
    for (var x = 0; x < 8; x++) {
      final raster = (y >> 2) * 2 + (x >> 2);
      final residual = residuals[raster][(y & 3) * 4 + (x & 3)];
      plane[row + x] = clip8(prediction[y * 8 + x] + residual);
    }
  }
}

void _write4x4PredictionAndResidual({
  required Uint8List plane,
  required int stride,
  required int x,
  required int y,
  required List<int> prediction,
  required List<int> residual,
}) {
  for (var row = 0; row < 4; row++) {
    final offset = (y + row) * stride + x;
    for (var column = 0; column < 4; column++) {
      final index = row * 4 + column;
      plane[offset + column] = clip8(prediction[index] + residual[index]);
    }
  }
}

void _add4x4Residual({
  required Uint8List plane,
  required int stride,
  required int x,
  required int y,
  required List<int> residual,
}) {
  for (var row = 0; row < 4; row++) {
    final offset = (y + row) * stride + x;
    for (var column = 0; column < 4; column++) {
      final index = row * 4 + column;
      plane[offset + column] = clip8(plane[offset + column] + residual[index]);
    }
  }
}

int _chromaQp(int qpY, int offset) {
  final qPi = (qpY + offset).clamp(0, 51).toInt();
  if (qPi < 30) return qPi;
  const table = <int>[
    29,
    30,
    31,
    32,
    32,
    33,
    34,
    34,
    35,
    35,
    36,
    36,
    37,
    37,
    37,
    38,
    38,
    38,
    39,
    39,
    39,
    39,
  ];
  return table[qPi - 30];
}

Yuv420Frame _cropPicture(Yuv420PictureBuffer picture, SpsInfo sps) {
  final width = sps.width;
  final height = sps.height;
  final left = sps.cropLeftPixels;
  final top = sps.cropTopPixels;
  final y = Uint8List(width * height);
  for (var row = 0; row < height; row++) {
    final source = (top + row) * picture.lumaStride + left;
    y.setRange(row * width, (row + 1) * width, picture.y, source);
  }
  final chromaWidth = width >> 1;
  final chromaHeight = height >> 1;
  final chromaLeft = left >> 1;
  final chromaTop = top >> 1;
  final u = Uint8List(chromaWidth * chromaHeight);
  final v = Uint8List(chromaWidth * chromaHeight);
  for (var row = 0; row < chromaHeight; row++) {
    final source = (chromaTop + row) * picture.chromaStride + chromaLeft;
    final destination = row * chromaWidth;
    u.setRange(destination, destination + chromaWidth, picture.u, source);
    v.setRange(destination, destination + chromaWidth, picture.v, source);
  }
  return Yuv420Frame(width: width, height: height, y: y, u: u, v: v);
}
