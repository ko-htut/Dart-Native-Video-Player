import 'dart:typed_data';

import '../yuv.dart';
import 'b_slice_motion.dart';
import 'bitreader.dart';
import 'cabac/cabac_context.dart';
import 'cabac/cabac_decoder.dart';
import 'cabac/cabac_slice_data.dart';
import 'cavlc.dart';
import 'chroma_pred.dart';
import 'deblocking_filter.dart';
import 'exp_golomb.dart';
import 'intra16_dc.dart';
import 'intra4x4_mpm.dart';
import 'intra8x8_pred.dart';
import 'intra_pred.dart';
import 'inv_transform.dart';
import 'inv_transform8x8.dart';
import 'motion_compensation.dart';
import 'picture_order_count.dart';
import 'pps.dart';
import 'rbsp.dart';
import 'reference_picture_list.dart';
import 'scan.dart';
import 'slice_header.dart';
import 'sps.dart';
import 'weighted_prediction.dart';

/// Optional low-level trace hook used by diagnostics and golden tests.
void Function(String message)? h264DecoderTrace;

class H264DecodeStats {
  final int frameNumber;
  final int? pictureOrderCount;
  final bool isReference;
  final H264SliceType sliceType;
  final int macroblockCount;
  final int intraMacroblocks;
  final int interMacroblocks;
  final int skippedMacroblocks;
  final int sliceCount;

  const H264DecodeStats({
    required this.frameNumber,
    this.pictureOrderCount,
    this.isReference = false,
    required this.sliceType,
    required this.macroblockCount,
    required this.intraMacroblocks,
    required this.interMacroblocks,
    required this.skippedMacroblocks,
    required this.sliceCount,
  });
}

/// Progressive 8-bit 4:2:0 H.264 decoder for Baseline/CAVLC I and P pictures,
/// plus deliberately narrow High-profile CABAC I_16x16/Intra_4x4/Intra_8x8,
/// weighted-P,
/// spatial/temporal-Direct B, and B_Bi_16x16 subsets.
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
  final H264PocType0Tracker _pocType0Tracker = H264PocType0Tracker();
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
    _pocType0Tracker.reset();
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

    // Picture state is transactional. An IDR starts from an empty *working*
    // DPB, but the canonical references/POC remain available until the whole
    // picture has reconstructed, deblocked, cropped, and prepared its next DPB.
    final workingReferences = first.isIdr
        ? <_DecodedPicture>[]
        : List<_DecodedPicture>.of(_shortTermReferences);
    final pictureUsesInterPrediction = headers.any(
      (header) =>
          header.sliceType == H264SliceType.p ||
          header.sliceType == H264SliceType.b,
    );
    if (pictureUsesInterPrediction && workingReferences.isEmpty) {
      final pictureKind = first.sliceType == H264SliceType.b ? 'B' : 'P';
      throw StateError('$pictureKind picture has no decoded reference picture');
    }
    for (final reference in workingReferences) {
      if (reference.buffer.width != first.sps.codedWidth ||
          reference.buffer.height != first.sps.codedHeight) {
        throw StateError('Reference-picture dimensions changed without an IDR');
      }
    }
    if (!first.isIdr && (pictureUsesInterPrediction || first.nalRefIdc != 0)) {
      _validateFrameNumContinuity(first);
    }

    H264PocType0Tracker? pocTransaction;
    H264PictureOrderCount? currentPoc;
    if (first.sps.picOrderCntType == 0) {
      pocTransaction = _pocType0Tracker.fork();
      currentPoc = pocTransaction.deriveFromHeader(first);
    }

    final state = _FrameState(
      first.sps,
      needsDualMotion: first.sliceType == H264SliceType.b,
    );
    var intraCount = 0;
    var interCount = 0;
    var skippedCount = 0;
    for (var sliceId = 0; sliceId < headers.length; sliceId++) {
      final header = headers[sliceId];
      List<_DecodedPicture> referencesL0;
      List<_DecodedPicture> referencesL1;
      if (header.sliceType == H264SliceType.p) {
        referencesL0 = _buildReferenceList0(header, workingReferences);
        referencesL1 = const <_DecodedPicture>[];
      } else if (header.sliceType == H264SliceType.b) {
        final poc = currentPoc;
        if (poc == null) {
          throw const FormatException(
            'CABAC B subset requires pic_order_cnt_type 0',
          );
        }
        final references = _buildBReferenceLists(
          header,
          poc.pictureOrderCount,
          workingReferences,
        );
        referencesL0 = references.list0;
        referencesL1 = references.list1;
      } else {
        referencesL0 = const <_DecodedPicture>[];
        referencesL1 = const <_DecodedPicture>[];
      }
      state.referenceListsBySlice[sliceId] = referencesL0;
      state.referenceListsL1BySlice[sliceId] = referencesL1;
      state.sliceParameters[sliceId] = H264DeblockingSliceParameters(
        disableDeblockingFilterIdc: header.disableDeblockingFilterIdc,
        sliceAlphaC0OffsetDiv2: header.sliceAlphaC0OffsetDiv2,
        sliceBetaOffsetDiv2: header.sliceBetaOffsetDiv2,
      );
      final result = _decodeSlice(
        header: header,
        state: state,
        references: referencesL0,
        referencesL1: referencesL1,
        currentPictureOrderCount: currentPoc?.pictureOrderCount,
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

    final cropped = _cropPicture(state.picture, first.sps);
    final decoded = _DecodedPicture(
      pictureId: _pictureId,
      frameNum: first.frameNum,
      pictureOrderCount: currentPoc?.pictureOrderCount,
      buffer: state.picture,
      motion:
          first.pps.entropyCodingModeFlag && first.sliceType != H264SliceType.b
          ? state.motion
          : null,
      dualMotion: state.dualMotion,
      referencePictureIdsL0BySlice: _snapshotReferencePictureIds(
        state.referenceListsBySlice,
      ),
      referencePictureIdsL1BySlice: _snapshotReferencePictureIds(
        state.referenceListsL1BySlice,
      ),
    );
    final marking = applyShortTermDpbMarking<_DecodedPicture>(
      shortTermReferences: <H264ShortTermReference<_DecodedPicture>>[
        for (final reference in workingReferences)
          H264ShortTermReference<_DecodedPicture>(
            frameNum: reference.frameNum,
            pictureOrderCount: reference.pictureOrderCount,
            value: reference,
          ),
      ],
      currentPicture: H264ShortTermReference<_DecodedPicture>(
        frameNum: decoded.frameNum,
        pictureOrderCount: decoded.pictureOrderCount,
        value: decoded,
      ),
      maxFrameNum: first.sps.maxFrameNum,
      maxNumRefFrames: first.sps.maxNumRefFrames,
      nalRefIdc: first.nalRefIdc,
      adaptiveRefPicMarkingModeFlag: first.adaptiveRefPicMarkingModeFlag,
      memoryManagementOperations: first.memoryManagementOperations,
    );
    final nextReferences = marking.references
        .map((reference) => reference.value)
        .toList(growable: false);
    var nextPreviousReferenceFrameNum = first.isIdr
        ? null
        : _previousReferenceFrameNum;
    if (marking.appendedCurrentPicture) {
      nextPreviousReferenceFrameNum = first.frameNum;
    }

    final stats = H264DecodeStats(
      frameNumber: first.frameNum,
      pictureOrderCount: currentPoc?.pictureOrderCount,
      isReference: first.nalRefIdc != 0,
      sliceType: first.sliceType,
      macroblockCount: state.macroblocks.length,
      intraMacroblocks: intraCount,
      interMacroblocks: interCount,
      skippedMacroblocks: skippedCount,
      sliceCount: headers.length,
    );

    // No operation below this point can fail under the validated invariants.
    // Publish all canonical picture state only after every preparatory step.
    if (pocTransaction != null) {
      _pocType0Tracker.commitFrom(pocTransaction);
    }
    _shortTermReferences
      ..clear()
      ..addAll(nextReferences);
    _previousReferenceFrameNum = nextPreviousReferenceFrameNum;
    _pictureId++;
    lastStats = stats;
    return cropped;
  }

  Yuv420Frame? decodeIdrAccessUnit(List<Uint8List> nals) =>
      decodeAccessUnit(nals);

  void _validateSupportedHeader(SliceHeader header) {
    final sps = header.sps;
    final pps = header.pps;
    final cabacHighSubset = pps.entropyCodingModeFlag;
    final supportedParameterSet = cabacHighSubset
        ? sps.isHighProfile8Bit420 &&
              sps.usesFlatScalingMatrices &&
              !pps.picScalingMatrixPresentFlag
        : sps.isSupportedBaseline420;
    if (!supportedParameterSet) {
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
    final cabacI = header.sliceType == H264SliceType.i;
    final cabacP = !header.isIdr && header.sliceType == H264SliceType.p;
    final cabacB = !header.isIdr && header.sliceType == H264SliceType.b;
    if (cabacHighSubset && !cabacI && !cabacP && !cabacB) {
      throw FormatException(
        'CABAC subset only supports bounded I, P, or B slices; got '
        '${header.isIdr ? '' : 'non-IDR '}${header.sliceType.name}',
      );
    }
    if (cabacHighSubset && cabacP) {
      if (header.nalRefIdc == 0) {
        throw const FormatException(
          'CABAC P subset requires a short-term reference picture',
        );
      }
      if (header.cabacInitIdc != 0) {
        throw FormatException(
          'CABAC P subset requires cabac_init_idc=0, got '
          '${header.cabacInitIdc}',
        );
      }
      if (!pps.weightedPredFlag || header.predictionWeightTable == null) {
        throw const FormatException(
          'CABAC P subset requires explicit weighted prediction',
        );
      }
    }
    if (cabacHighSubset && cabacB) {
      if (header.nalRefIdc != 0 &&
          header.adaptiveRefPicMarkingModeFlag &&
          (header.memoryManagementOperations.isEmpty ||
              header.memoryManagementOperations.any(
                (operation) => operation.operation != 1,
              ))) {
        throw const FormatException(
          'Adaptive reference CABAC B subset requires one or more MMCO 1 '
          'operations',
        );
      }
      if (!sps.direct8x8InferenceFlag) {
        throw const FormatException(
          'CABAC B subset requires direct_8x8_inference_flag=1',
        );
      }
      if (pps.weightedBipredIdc != 2) {
        throw FormatException(
          'CABAC B subset requires implicit weighted bi-prediction; got '
          'weighted_bipred_idc=${pps.weightedBipredIdc}',
        );
      }
      if (header.cabacInitIdc != 0) {
        throw FormatException(
          'CABAC B subset requires cabac_init_idc=0, got '
          '${header.cabacInitIdc}',
        );
      }
      if (header.refPicListModificationsL0.isNotEmpty ||
          header.refPicListModificationsL1.isNotEmpty) {
        throw const FormatException(
          'CABAC B subset requires unmodified reference lists',
        );
      }
      if (sps.picOrderCntType != 0 || header.picOrderCntLsb == null) {
        throw const FormatException(
          'CABAC B subset requires pic_order_cnt_type 0',
        );
      }
    }
    if (!cabacHighSubset &&
        header.sliceType == H264SliceType.p &&
        pps.weightedPredFlag) {
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
    if (!cabacHighSubset &&
        (pps.transform8x8ModeFlag || pps.picScalingMatrixPresentFlag)) {
      throw const FormatException(
        '8x8 transforms/scaling matrices unsupported',
      );
    }
    if (header.sliceType != H264SliceType.i &&
        header.sliceType != H264SliceType.p &&
        !(cabacHighSubset && header.sliceType == H264SliceType.b)) {
      throw FormatException('Unsupported slice type ${header.sliceType.name}');
    }
    if ((header.sliceType == H264SliceType.p ||
            header.sliceType == H264SliceType.b) &&
        header.numRefIdxL0ActiveMinus1 > 31) {
      throw FormatException(
        'num_ref_idx_l0_active_minus1='
        '${header.numRefIdxL0ActiveMinus1} exceeds 31',
      );
    }
    if (header.sliceType == H264SliceType.b &&
        header.numRefIdxL1ActiveMinus1 > 31) {
      throw FormatException(
        'num_ref_idx_l1_active_minus1='
        '${header.numRefIdxL1ActiveMinus1} exceeds 31',
      );
    }
    if (header.adaptiveRefPicMarkingModeFlag &&
        (header.memoryManagementOperations.isEmpty ||
            header.memoryManagementOperations.any(
              (operation) => operation.operation != 1,
            ))) {
      throw const FormatException(
        'Adaptive reference marking requires MMCO 1 operations',
      );
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

  List<_DecodedPicture> _buildReferenceList0(
    SliceHeader header,
    List<_DecodedPicture> shortTermReferences,
  ) {
    return buildPReferenceList0<_DecodedPicture>(
      shortTermReferences: <H264ShortTermReference<_DecodedPicture>>[
        for (final reference in shortTermReferences)
          H264ShortTermReference<_DecodedPicture>(
            frameNum: reference.frameNum,
            pictureOrderCount: reference.pictureOrderCount,
            value: reference,
          ),
      ],
      currentFrameNum: header.frameNum,
      maxFrameNum: header.sps.maxFrameNum,
      activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
      modifications: header.refPicListModificationsL0,
    ).map((reference) => reference.value).toList(growable: false);
  }

  ({List<_DecodedPicture> list0, List<_DecodedPicture> list1})
  _buildBReferenceLists(
    SliceHeader header,
    int currentPictureOrderCount,
    List<_DecodedPicture> shortTermReferences,
  ) {
    final lists = buildBReferenceLists<_DecodedPicture>(
      shortTermReferences: <H264ShortTermReference<_DecodedPicture>>[
        for (final reference in shortTermReferences)
          H264ShortTermReference<_DecodedPicture>(
            frameNum: reference.frameNum,
            pictureOrderCount: reference.pictureOrderCount,
            value: reference,
          ),
      ],
      currentFrameNum: header.frameNum,
      currentPictureOrderCount: currentPictureOrderCount,
      maxFrameNum: header.sps.maxFrameNum,
      activeReferenceCountL0: header.numRefIdxL0ActiveMinus1 + 1,
      activeReferenceCountL1: header.numRefIdxL1ActiveMinus1 + 1,
      modificationsL0: header.refPicListModificationsL0,
      modificationsL1: header.refPicListModificationsL1,
    );
    return (
      list0: lists.list0
          .map((reference) => reference.value)
          .toList(growable: false),
      list1: lists.list1
          .map((reference) => reference.value)
          .toList(growable: false),
    );
  }
}

class H264IdrDecoder extends H264BaselineDecoder {}

class _DecodedPicture {
  final int pictureId;
  final int frameNum;
  final int? pictureOrderCount;
  final Yuv420PictureBuffer buffer;
  final MotionFieldGrid? motion;
  final H264DualMotionFieldGrid? dualMotion;
  final Map<int, List<int>> referencePictureIdsL0BySlice;
  final Map<int, List<int>> referencePictureIdsL1BySlice;

  const _DecodedPicture({
    required this.pictureId,
    required this.frameNum,
    required this.pictureOrderCount,
    required this.buffer,
    required this.motion,
    required this.dualMotion,
    required this.referencePictureIdsL0BySlice,
    required this.referencePictureIdsL1BySlice,
  });
}

Map<int, List<int>> _snapshotReferencePictureIds(
  Map<int, List<_DecodedPicture>> referencesBySlice,
) => Map<int, List<int>>.unmodifiable(<int, List<int>>{
  for (final entry in referencesBySlice.entries)
    entry.key: List<int>.unmodifiable(
      entry.value.map((reference) => reference.pictureId),
    ),
});

class _MacroblockMeta {
  bool decoded = false;
  bool isIntra = false;
  bool isIntra16x16 = false;
  bool skipped = false;
  bool direct = false;
  int sliceId = -1;
  int qpY = 26;
  int qpCb = 26;
  int qpCr = 26;
  int codedBlockPatternLuma = 0;
  int codedBlockPatternChroma = 0;
  int intraChromaPredictionMode = 0;
  int lumaDcTotalCoeff = -1;
  bool lumaDcCoded = false;
  bool cbDcCoded = false;
  bool crDcCoded = false;
  bool usesIntra4x4 = false;
  bool usesIntra8x8 = false;
  bool transformSize8x8 = false;
  final List<int> lumaTotalCoeff = List<int>.filled(16, -1);
  final List<int> cbTotalCoeff = List<int>.filled(4, -1);
  final List<int> crTotalCoeff = List<int>.filled(4, -1);
  int lumaCodedMask = 0;
  int cbCodedMask = 0;
  int crCodedMask = 0;
  final List<bool> lumaReconstructed = List<bool>.filled(16, false);
  final List<bool> intraModeKnown = List<bool>.filled(16, false);
  final List<bool> intra8x8ModeKnown = List<bool>.filled(4, false);
}

class _FrameState {
  final SpsInfo sps;
  final int mbWidth;
  final int mbHeight;
  final Yuv420PictureBuffer picture;
  final List<_MacroblockMeta> macroblocks;
  final List<int> intra4x4Modes;
  final List<int> intra8x8Modes;
  final MotionFieldGrid motion;
  final List<CabacMotionVectorDifference> cabacMvd;
  final List<CabacMotionVectorDifference> cabacMvdL1;
  final H264DualMotionFieldGrid? dualMotion;
  final Map<int, List<_DecodedPicture>> referenceListsBySlice =
      <int, List<_DecodedPicture>>{};
  final Map<int, List<_DecodedPicture>> referenceListsL1BySlice =
      <int, List<_DecodedPicture>>{};
  final Map<int, H264DeblockingSliceParameters> sliceParameters =
      <int, H264DeblockingSliceParameters>{};

  _FrameState(this.sps, {bool needsDualMotion = false})
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
      intra8x8Modes = List<int>.filled(
        (sps.codedWidth >> 4) * (sps.codedHeight >> 4) * 4,
        2,
      ),
      motion = MotionFieldGrid.forLumaSize(
        width: sps.codedWidth,
        height: sps.codedHeight,
      ),
      cabacMvd = List<CabacMotionVectorDifference>.filled(
        (sps.codedWidth >> 2) * (sps.codedHeight >> 2),
        const CabacMotionVectorDifference(horizontal: 0, vertical: 0),
      ),
      cabacMvdL1 = List<CabacMotionVectorDifference>.filled(
        (sps.codedWidth >> 2) * (sps.codedHeight >> 2),
        const CabacMotionVectorDifference(horizontal: 0, vertical: 0),
      ),
      dualMotion = needsDualMotion
          ? H264DualMotionFieldGrid.forLumaSize(
              width: sps.codedWidth,
              height: sps.codedHeight,
            )
          : null {
    picture.y.fillRange(0, picture.y.length, 128);
    picture.u.fillRange(0, picture.u.length, 128);
    picture.v.fillRange(0, picture.v.length, 128);
  }

  _MacroblockMeta metaAt(int mbX, int mbY) => macroblocks[mbY * mbWidth + mbX];

  CabacReferenceNeighbor cabacReferenceNeighbor(
    int blockX,
    int blockY, {
    required int sliceId,
  }) {
    final entry = motion.entryAt4x4(blockX, blockY, currentSliceId: sliceId);
    if (!entry.available) return const CabacReferenceNeighbor.unavailable();
    return CabacReferenceNeighbor(
      intra: entry.referenceIndex < 0,
      referenceIndex: entry.referenceIndex,
    );
  }

  CabacMvdNeighbor cabacMvdNeighbor(
    int blockX,
    int blockY, {
    required int sliceId,
  }) {
    final entry = motion.entryAt4x4(blockX, blockY, currentSliceId: sliceId);
    if (!entry.available) return const CabacMvdNeighbor.unavailable();
    final mvd = cabacMvd[blockY * (mbWidth * 4) + blockX];
    return CabacMvdNeighbor(horizontal: mvd.horizontal, vertical: mvd.vertical);
  }

  CabacReferenceNeighbor cabacBReferenceNeighbor(
    CabacReferenceList list,
    int blockX,
    int blockY, {
    required int sliceId,
  }) {
    final grid = dualMotion;
    if (grid == null) {
      throw StateError('CABAC B reference context has no dual motion field');
    }
    final entry = grid.entryAt4x4(blockX, blockY, currentSliceId: sliceId);
    if (!entry.available) return const CabacReferenceNeighbor.unavailable();
    final motion = entry.motion;
    final selected = motion?.motionFor(
      list == CabacReferenceList.l0
          ? H264MotionList.list0
          : H264MotionList.list1,
    );
    return CabacReferenceNeighbor(
      direct: motion?.derivedFromDirect ?? false,
      intra: entry.intra,
      referenceIndex: selected?.referenceIndex ?? -1,
    );
  }

  CabacMvdNeighbor cabacBMvdNeighbor(
    CabacReferenceList list,
    int blockX,
    int blockY, {
    required int sliceId,
  }) {
    final grid = dualMotion;
    if (grid == null) {
      throw StateError('CABAC B MVD context has no dual motion field');
    }
    final entry = grid.entryAt4x4(blockX, blockY, currentSliceId: sliceId);
    if (!entry.available) return const CabacMvdNeighbor.unavailable();
    final motion = entry.motion;
    final selected = motion?.motionFor(
      list == CabacReferenceList.l0
          ? H264MotionList.list0
          : H264MotionList.list1,
    );
    if (entry.intra ||
        selected == null ||
        (motion?.derivedFromDirect ?? false)) {
      return const CabacMvdNeighbor(horizontal: 0, vertical: 0);
    }
    final index = blockY * (mbWidth * 4) + blockX;
    final mvd = list == CabacReferenceList.l0
        ? cabacMvd[index]
        : cabacMvdL1[index];
    return CabacMvdNeighbor(horizontal: mvd.horizontal, vertical: mvd.vertical);
  }

  void setCabacMvdPartition({
    required int x,
    required int y,
    required int width,
    required int height,
    required CabacMotionVectorDifference mvd,
  }) {
    final x4 = x >> 2;
    final y4 = y >> 2;
    final width4 = width >> 2;
    final height4 = height >> 2;
    final stride4 = mbWidth * 4;
    for (var blockY = y4; blockY < y4 + height4; blockY++) {
      for (var blockX = x4; blockX < x4 + width4; blockX++) {
        cabacMvd[blockY * stride4 + blockX] = mvd;
      }
    }
  }

  void setCabacBMvdPartition({
    required CabacReferenceList list,
    required int x,
    required int y,
    required int width,
    required int height,
    required CabacMotionVectorDifference mvd,
  }) {
    final target = list == CabacReferenceList.l0 ? cabacMvd : cabacMvdL1;
    final x4 = x >> 2;
    final y4 = y >> 2;
    final width4 = width >> 2;
    final height4 = height >> 2;
    final stride4 = mbWidth * 4;
    for (var blockY = y4; blockY < y4 + height4; blockY++) {
      for (var blockX = x4; blockX < x4 + width4; blockX++) {
        target[blockY * stride4 + blockX] = mvd;
      }
    }
  }

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
    final referencesL0 = referenceListsBySlice[meta.sliceId];
    final referencesL1 = referenceListsL1BySlice[meta.sliceId];
    final mbX = mbAddr % mbWidth;
    final mbY = mbAddr ~/ mbWidth;
    final blocks = <H264DeblockingBlock>[];
    for (var raster = 0; raster < 16; raster++) {
      final bx = raster & 3;
      final by = raster >> 2;
      final dualEntry = dualMotion?.entryAt4x4(mbX * 4 + bx, mbY * 4 + by);
      if (dualMotion == null) {
        final entry = motion.entryAt4x4(mbX * 4 + bx, mbY * 4 + by);
        blocks.add(
          H264DeblockingBlock(
            totalCoeff: _nonNegative(meta.lumaTotalCoeff[raster]),
            referenceIndexL0: entry.referenceIndex,
            referencePictureId:
                entry.referenceIndex >= 0 &&
                    referencesL0 != null &&
                    entry.referenceIndex < referencesL0.length
                ? referencesL0[entry.referenceIndex].pictureId
                : null,
            motionVectorL0: H264MotionVector(entry.vector.x, entry.vector.y),
          ),
        );
        continue;
      }

      final dual = dualEntry != null && dualEntry.available && !dualEntry.intra
          ? dualEntry.motion
          : null;
      final list0 = dual?.list0;
      final list1 = dual?.list1;
      blocks.add(
        H264DeblockingBlock(
          totalCoeff: _nonNegative(meta.lumaTotalCoeff[raster]),
          referenceIndexL0: list0?.referenceIndex ?? -1,
          referencePictureIdL0:
              list0 != null &&
                  referencesL0 != null &&
                  list0.referenceIndex < referencesL0.length
              ? referencesL0[list0.referenceIndex].pictureId
              : null,
          motionVectorL0: H264MotionVector(
            list0?.vector.x ?? 0,
            list0?.vector.y ?? 0,
          ),
          referenceIndexL1: list1?.referenceIndex ?? -1,
          referencePictureIdL1:
              list1 != null &&
                  referencesL1 != null &&
                  list1.referenceIndex < referencesL1.length
              ? referencesL1[list1.referenceIndex].pictureId
              : null,
          motionVectorL1: H264MotionVector(
            list1?.vector.x ?? 0,
            list1?.vector.y ?? 0,
          ),
        ),
      );
    }
    return H264DeblockingMacroblock(
      isIntra: meta.isIntra,
      transformSize8x8: meta.transformSize8x8,
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
typedef _CabacPPartition = ({
  int x,
  int y,
  int width,
  int height,
  InterPartitionKind kind,
  int index,
});

_SliceDecodeResult _decodeSlice({
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> references,
  required List<_DecodedPicture> referencesL1,
  required int? currentPictureOrderCount,
  required int sliceId,
  required int initialQpY,
}) {
  if (header.pps.entropyCodingModeFlag) {
    return switch (header.sliceType) {
      H264SliceType.i => _decodeCabacIntraSlice(
        header: header,
        state: state,
        sliceId: sliceId,
        initialQpY: initialQpY,
      ),
      H264SliceType.p => _decodeCabacPSlice(
        header: header,
        state: state,
        references: references,
        sliceId: sliceId,
        initialQpY: initialQpY,
      ),
      H264SliceType.b => _decodeCabacBSlice(
        header: header,
        state: state,
        referencesL0: references,
        referencesL1: referencesL1,
        currentPictureOrderCount: currentPictureOrderCount,
        sliceId: sliceId,
        initialQpY: initialQpY,
      ),
      _ => throw FormatException(
        'Unsupported CABAC slice type ${header.sliceType.name}',
      ),
    };
  }

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

/// Bounded CABAC I reconstruction for the exact sfux I-picture footprint.
///
/// I_16x16, Intra_4x4, and transform-backed Intra_8x8 are supported. PCM and
/// any syntax outside those paths fail before guessed state can be published.
_SliceDecodeResult _decodeCabacIntraSlice({
  required SliceHeader header,
  required _FrameState state,
  required int sliceId,
  required int initialQpY,
}) {
  if (header.sliceType != H264SliceType.i) {
    throw const FormatException('CABAC I reconstruction requires an I slice');
  }

  final reader = header.reader;
  readCabacAlignmentOneBits(reader);
  final arithmetic = H264CabacDecoder.initialize(reader);
  final syntax = H264CabacSliceDataDecoder.fromArithmetic(
    decoder: arithmetic,
    contexts: H264CabacContextSet.initialize(
      sliceType: H264CabacSliceType.i,
      sliceQpY: header.sliceQpY,
    ),
  );

  final mbCount = state.macroblocks.length;
  var mbAddr = header.firstMbInSlice;
  if (mbAddr < 0 || mbAddr >= mbCount) {
    throw FormatException('first_mb_in_slice=$mbAddr is outside the picture');
  }

  var qpY = initialQpY;
  var intra = 0;
  var terminated = false;
  while (!terminated) {
    if (mbAddr >= mbCount) {
      throw const FormatException(
        'CABAC slice reached the end of the picture without '
        'end_of_slice_flag',
      );
    }

    final macroblockStart = arithmetic.bitPosition;
    try {
      final neighbors = _cabacMacroblockNeighbors(
        state,
        mbAddr: mbAddr,
        sliceId: sliceId,
      );
      final type = syntax.decodeMbType(neighbors: neighbors);
      if (type.kind != CabacMacroblockKind.intra16x16 &&
          type.kind != CabacMacroblockKind.intraNxN) {
        throw FormatException(
          'Unsupported CABAC macroblock kind ${type.kind.name} '
          '(mb_type=${type.codeNum ?? 'skip'}); the bounded I subset only '
          'implements I_16x16, Intra_4x4, and Intra_8x8',
        );
      }
      final result = type.kind == CabacMacroblockKind.intra16x16
          ? _decodeCabacIntra16Macroblock(
              syntax: syntax,
              type: type,
              header: header,
              state: state,
              mbAddr: mbAddr,
              sliceId: sliceId,
              previousQpY: qpY,
              neighbors: neighbors,
            )
          : _decodeCabacIntraNxNMacroblock(
              syntax: syntax,
              header: header,
              state: state,
              mbAddr: mbAddr,
              sliceId: sliceId,
              previousQpY: qpY,
              neighbors: neighbors,
            );
      qpY = result.qpY;

      terminated = syntax.decodeEndOfSliceFlag();
      h264DecoderTrace?.call(
        'cabac mb=$mbAddr start=$macroblockStart type=${type.codeNum} '
        '${result.details} qp=$qpY '
        'end=${arithmetic.bitPosition} eos=$terminated',
      );
    } catch (error) {
      throw FormatException(
        'CABAC macroblock $mbAddr failed at bit ${arithmetic.bitPosition} '
        '(start $macroblockStart): $error',
      );
    }

    mbAddr++;
    intra++;
  }

  if (!arithmetic.isTerminated) {
    throw const FormatException(
      'CABAC slice ended without a terminating arithmetic bin',
    );
  }
  // The arithmetic decoder can legally retain prefetched payload bits before
  // rbsp_slice_trailing_bits, so the CAVLC trailing-bit reader must not be used
  // here. The terminating bin is the authoritative CABAC slice boundary.
  return (qpY: qpY, intra: intra, inter: 0, skipped: 0);
}

({int qpY, String details}) _decodeCabacIntra16Macroblock({
  required H264CabacSliceDataDecoder syntax,
  required CabacMacroblockType type,
  required SliceHeader header,
  required _FrameState state,
  required int mbAddr,
  required int sliceId,
  required int previousQpY,
  required CabacMacroblockNeighbors neighbors,
}) {
  final intra16Mode = type.intra16x16PredictionMode!;
  final codedBlockPattern = type.intra16x16CodedBlockPattern!;
  final codedBlockPatternChroma = codedBlockPattern.chroma;
  final codedBlockPatternLuma = codedBlockPattern.luma;
  final intraChromaMode = syntax.decodeIntraChromaPredictionMode(
    neighbors: neighbors,
  );
  _validateIntraChromaMode(intraChromaMode);

  final meta = state.macroblocks[mbAddr];
  if (meta.decoded) throw FormatException('Macroblock $mbAddr decoded twice');
  final deltaQp = syntax.decodeMbQpDelta();
  final qpY = (previousQpY + deltaQp + 52) % 52;
  final qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset);
  final qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset);
  meta
    ..sliceId = sliceId
    ..isIntra = true
    ..isIntra16x16 = true
    ..usesIntra4x4 = false
    ..usesIntra8x8 = false
    ..transformSize8x8 = false
    ..codedBlockPatternLuma = codedBlockPatternLuma
    ..codedBlockPatternChroma = codedBlockPatternChroma
    ..intraChromaPredictionMode = intraChromaMode
    ..qpY = qpY
    ..qpCb = qpCb
    ..qpCr = qpCr;

  final residual = _decodeCabacIntra16Residual(
    syntax: syntax,
    state: state,
    mbAddr: mbAddr,
    sliceId: sliceId,
    codedBlockPatternLuma: codedBlockPatternLuma,
    codedBlockPatternChroma: codedBlockPatternChroma,
  );
  _reconstructIntra16(
    state: state,
    header: header,
    mbAddr: mbAddr,
    sliceId: sliceId,
    mode: intra16Mode,
    qpY: qpY,
    lumaCoefficients: residual.luma,
  );
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
  _finishCabacIntraMacroblock(state: state, mbAddr: mbAddr, sliceId: sliceId);
  return (
    qpY: qpY,
    details:
        'i16mode=$intra16Mode chromaMode=$intraChromaMode '
        'cbpL=$codedBlockPatternLuma cbpC=$codedBlockPatternChroma',
  );
}

({int qpY, String details}) _decodeCabacIntraNxNMacroblock({
  required H264CabacSliceDataDecoder syntax,
  required SliceHeader header,
  required _FrameState state,
  required int mbAddr,
  required int sliceId,
  required int previousQpY,
  required CabacMacroblockNeighbors neighbors,
}) {
  final transformSize8x8 = header.pps.transform8x8ModeFlag
      ? syntax.decodeTransformSize8x8Flag(neighbors: neighbors)
      : false;
  final meta = state.macroblocks[mbAddr];
  if (meta.decoded) throw FormatException('Macroblock $mbAddr decoded twice');
  meta
    ..sliceId = sliceId
    ..isIntra = true
    ..isIntra16x16 = false
    ..usesIntra4x4 = !transformSize8x8
    ..usesIntra8x8 = transformSize8x8
    ..transformSize8x8 = transformSize8x8;
  final modes = transformSize8x8
      ? _decodeCabacIntra8x8Modes(
          syntax: syntax,
          state: state,
          header: header,
          mbAddr: mbAddr,
          sliceId: sliceId,
        )
      : _decodeCabacIntra4x4Modes(
          syntax: syntax,
          state: state,
          header: header,
          mbAddr: mbAddr,
          sliceId: sliceId,
        );
  final intraChromaMode = syntax.decodeIntraChromaPredictionMode(
    neighbors: neighbors,
  );
  _validateIntraChromaMode(intraChromaMode);
  final cbp = syntax.decodeCodedBlockPattern(neighbors: neighbors);
  final deltaQp = cbp.packed == 0 ? 0 : syntax.decodeMbQpDelta();
  if (cbp.packed == 0) syntax.noteMacroblockWithoutQpDelta();
  final qpY = (previousQpY + deltaQp + 52) % 52;
  final qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset);
  final qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset);

  meta
    ..codedBlockPatternLuma = cbp.luma
    ..codedBlockPatternChroma = cbp.chroma
    ..intraChromaPredictionMode = intraChromaMode
    ..qpY = qpY
    ..qpCb = qpCb
    ..qpCr = qpCr;
  late final List<List<int>> cb;
  late final List<List<int>> cr;
  if (transformSize8x8) {
    final residual = _decodeCabac8x8Residual(
      syntax: syntax,
      state: state,
      mbAddr: mbAddr,
      sliceId: sliceId,
      codedBlockPatternLuma: cbp.luma,
      codedBlockPatternChroma: cbp.chroma,
      currentMacroblockIntra: true,
    );
    cb = residual.cb;
    cr = residual.cr;
    _reconstructIntra8x8(
      state: state,
      header: header,
      mbAddr: mbAddr,
      sliceId: sliceId,
      qpY: qpY,
      lumaCoefficients: residual.luma8x8,
    );
  } else {
    final residual = _decodeCabac4x4Residual(
      syntax: syntax,
      state: state,
      mbAddr: mbAddr,
      sliceId: sliceId,
      codedBlockPatternLuma: cbp.luma,
      codedBlockPatternChroma: cbp.chroma,
      currentMacroblockIntra: true,
    );
    cb = residual.cb;
    cr = residual.cr;
    _reconstructIntra4x4(
      state: state,
      header: header,
      mbAddr: mbAddr,
      sliceId: sliceId,
      qpY: qpY,
      lumaCoefficients: residual.luma,
    );
  }
  _reconstructIntraChroma(
    state: state,
    header: header,
    mbAddr: mbAddr,
    sliceId: sliceId,
    mode: intraChromaMode,
    qpCb: qpCb,
    qpCr: qpCr,
    cbCoefficients: cb,
    crCoefficients: cr,
  );
  _finishCabacIntraMacroblock(state: state, mbAddr: mbAddr, sliceId: sliceId);
  return (
    qpY: qpY,
    details:
        '${transformSize8x8 ? 'i8' : 'i4'}modes=$modes '
        'chromaMode=$intraChromaMode '
        'cbpL=${cbp.luma} cbpC=${cbp.chroma}',
  );
}

List<int> _decodeCabacIntra4x4Modes({
  required H264CabacSliceDataDecoder syntax,
  required _FrameState state,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final meta = state.macroblocks[mbAddr];
  final modes = List<int>.filled(16, 2);
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
      constrainedIntra: header.pps.constrainedIntraPredFlag,
    );
    final top = _intraModeNeighbour(
      state,
      globalBlockX: mbX * 4 + bx,
      globalBlockY: mbY * 4 + by - 1,
      currentMbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: header.pps.constrainedIntraPredFlag,
    );
    final predicted = mostProbableIntra4x4Mode(
      leftAvail: left.available,
      topAvail: top.available,
      leftMode: left.mode,
      topMode: top.mode,
    );
    final decoded = syntax.decodeIntra4x4Mode(predictedMode: predicted);
    final mode = decoded.mode;
    if (mode == null || mode < 0 || mode > 8) {
      throw FormatException('Invalid Intra_4x4 prediction mode $mode');
    }
    modes[syntaxBlock] = mode;
    state.intra4x4Modes[mbAddr * 16 + raster] = mode;
    meta.intraModeKnown[raster] = true;
  }
  return modes;
}

List<int> _decodeCabacIntra8x8Modes({
  required H264CabacSliceDataDecoder syntax,
  required _FrameState state,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final meta = state.macroblocks[mbAddr];
  final modes = List<int>.filled(4, 2);
  for (var block = 0; block < 4; block++) {
    final bx = block & 1;
    final by = block >> 1;
    final left = _intra8x8ModeNeighbor(
      state,
      globalBlockX: mbX * 2 + bx - 1,
      globalBlockY: mbY * 2 + by,
      side: Intra8x8NeighbourSide.left,
      currentMbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: header.pps.constrainedIntraPredFlag,
    );
    final top = _intra8x8ModeNeighbor(
      state,
      globalBlockX: mbX * 2 + bx,
      globalBlockY: mbY * 2 + by - 1,
      side: Intra8x8NeighbourSide.top,
      currentMbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: header.pps.constrainedIntraPredFlag,
    );
    final predicted = mostProbableIntra4x4Mode(
      leftAvail: left.available,
      topAvail: top.available,
      leftMode: left.mode,
      topMode: top.mode,
    );
    final decoded = syntax.decodeIntra8x8Mode(predictedMode: predicted);
    final mode = decoded.mode;
    if (mode == null || mode < 0 || mode > 8) {
      throw FormatException('Invalid Intra_8x8 prediction mode $mode');
    }
    modes[block] = mode;
    state.intra8x8Modes[mbAddr * 4 + block] = mode;
    meta.intra8x8ModeKnown[block] = true;
  }
  return modes;
}

({bool available, int mode}) _intra8x8ModeNeighbor(
  _FrameState state, {
  required int globalBlockX,
  required int globalBlockY,
  required Intra8x8NeighbourSide side,
  required int currentMbAddr,
  required int sliceId,
  required bool constrainedIntra,
}) {
  if (globalBlockX < 0 ||
      globalBlockY < 0 ||
      globalBlockX >= state.mbWidth * 2 ||
      globalBlockY >= state.mbHeight * 2) {
    return (available: false, mode: 2);
  }
  final mbX = globalBlockX >> 1;
  final mbY = globalBlockY >> 1;
  final mbAddr = mbY * state.mbWidth + mbX;
  final meta = state.macroblocks[mbAddr];
  if (meta.sliceId != sliceId || (constrainedIntra && !meta.isIntra)) {
    return (available: false, mode: 2);
  }
  final block = (globalBlockY & 1) * 2 + (globalBlockX & 1);
  if (mbAddr == currentMbAddr) {
    if (!meta.intra8x8ModeKnown[block]) {
      return (available: false, mode: 2);
    }
  } else if (!meta.decoded) {
    return (available: false, mode: 2);
  }
  // Any decoded same-slice neighbour that is not constrained away remains
  // available to the MPM derivation. An Intra4x4 neighbour contributes the
  // facing 4x4 mode; Intra16x16 and inter neighbours substitute DC mode 2.
  if (meta.usesIntra8x8) {
    return (available: true, mode: state.intra8x8Modes[mbAddr * 4 + block]);
  }
  if (meta.usesIntra4x4) {
    final raster = intra4x4BlockIndexForIntra8x8Neighbour(
      blockX: globalBlockX & 1,
      blockY: globalBlockY & 1,
      side: side,
    );
    return (available: true, mode: state.intra4x4Modes[mbAddr * 16 + raster]);
  }
  return (available: true, mode: 2);
}

void _finishCabacIntraMacroblock({
  required _FrameState state,
  required int mbAddr,
  required int sliceId,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  state.motion.setIntraPartition(
    x: mbX * 16,
    y: mbY * 16,
    width: 16,
    height: 16,
    sliceId: sliceId,
  );
  state.dualMotion?.setIntraPartition(
    x: mbX * 16,
    y: mbY * 16,
    width: 16,
    height: 16,
    sliceId: sliceId,
  );
  state.setCabacMvdPartition(
    x: mbX * 16,
    y: mbY * 16,
    width: 16,
    height: 16,
    mvd: const CabacMotionVectorDifference(horizontal: 0, vertical: 0),
  );
  final meta = state.macroblocks[mbAddr];
  meta
    ..decoded = true
    ..lumaDcTotalCoeff = _nonNegative(meta.lumaDcTotalCoeff);
  for (var block = 0; block < 16; block++) {
    if (meta.lumaTotalCoeff[block] < 0) meta.lumaTotalCoeff[block] = 0;
    meta.lumaReconstructed[block] = true;
  }
  for (var block = 0; block < 4; block++) {
    if (meta.cbTotalCoeff[block] < 0) meta.cbTotalCoeff[block] = 0;
    if (meta.crTotalCoeff[block] < 0) meta.crTotalCoeff[block] = 0;
  }
}

/// Bounded CABAC P reconstruction for sfux weighted P_Skip, intra, and
/// P_L0_16x16/P_L0_L0_16x8/P_L0_L0_8x16 and bounded P_8x8 macroblocks
/// using the active List0 entries.
_SliceDecodeResult _decodeCabacPSlice({
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> references,
  required int sliceId,
  required int initialQpY,
}) {
  if (header.isIdr || header.sliceType != H264SliceType.p) {
    throw const FormatException('CABAC P reconstruction requires a P slice');
  }
  if (references.isEmpty) {
    throw const FormatException('CABAC P reconstruction requires List0');
  }
  final weights = header.predictionWeightTable;
  if (weights == null || weights.list0.length < references.length) {
    throw FormatException(
      'CABAC P reconstruction requires explicit weights for all '
      '${references.length} active references',
    );
  }

  final reader = header.reader;
  readCabacAlignmentOneBits(reader);
  final arithmetic = H264CabacDecoder.initialize(reader);
  final syntax = H264CabacSliceDataDecoder.fromArithmetic(
    decoder: arithmetic,
    contexts: H264CabacContextSet.initialize(
      sliceType: H264CabacSliceType.p,
      sliceQpY: header.sliceQpY,
      cabacInitIdc: header.cabacInitIdc!,
    ),
  );

  final mbCount = state.macroblocks.length;
  var mbAddr = header.firstMbInSlice;
  if (mbAddr < 0 || mbAddr >= mbCount) {
    throw FormatException('first_mb_in_slice=$mbAddr is outside the picture');
  }

  var qpY = initialQpY;
  var intra = 0;
  var inter = 0;
  var skipped = 0;
  var terminated = false;
  while (!terminated) {
    if (mbAddr >= mbCount) {
      throw const FormatException(
        'CABAC P slice reached the end of the picture without '
        'end_of_slice_flag',
      );
    }

    final macroblockStart = arithmetic.bitPosition;
    try {
      final neighbors = _cabacMacroblockNeighbors(
        state,
        mbAddr: mbAddr,
        sliceId: sliceId,
      );
      final start = syntax.decodeMacroblockStart(neighbors: neighbors);
      String details;
      if (start.skipped) {
        _decodeSkippedMacroblock(
          state: state,
          reference: references.first,
          header: header,
          mbAddr: mbAddr,
          sliceId: sliceId,
          qpY: qpY,
          predictionWeights: weights,
        );
        skipped++;
        details = 'skip';
      } else if (start.type.kind == CabacMacroblockKind.intra16x16) {
        final result = _decodeCabacIntra16Macroblock(
          syntax: syntax,
          type: start.type,
          header: header,
          state: state,
          mbAddr: mbAddr,
          sliceId: sliceId,
          previousQpY: qpY,
          neighbors: neighbors,
        );
        qpY = result.qpY;
        intra++;
        details = result.details;
      } else if (start.type.kind == CabacMacroblockKind.intraNxN) {
        final result = _decodeCabacIntraNxNMacroblock(
          syntax: syntax,
          header: header,
          state: state,
          mbAddr: mbAddr,
          sliceId: sliceId,
          previousQpY: qpY,
          neighbors: neighbors,
        );
        qpY = result.qpY;
        intra++;
        details = result.details;
      } else if (start.type.kind == CabacMacroblockKind.inter &&
          start.type.codeNum != null &&
          start.type.codeNum! >= 0 &&
          start.type.codeNum! <= 3) {
        final result = _decodeCabacPInterMacroblock(
          syntax: syntax,
          type: start.type,
          header: header,
          state: state,
          references: references,
          weights: weights,
          mbAddr: mbAddr,
          sliceId: sliceId,
          previousQpY: qpY,
          neighbors: neighbors,
        );
        qpY = result.qpY;
        inter++;
        details = result.details;
      } else {
        throw FormatException(
          'Unsupported non-skip CABAC P macroblock kind '
          '${start.type.kind.name} '
          '(mb_type=${start.type.codeNum}); only P_Skip, P_L0_16x16, '
          'P_L0_L0_16x8, P_L0_L0_8x16, P_8x8 with four P_L0_8x8 '
          'sub-macroblocks, I_16x16, Intra_4x4, and Intra_8x8 are '
          'implemented',
        );
      }
      terminated = syntax.decodeEndOfSliceFlag();
      h264DecoderTrace?.call(
        'cabac p mb=$mbAddr start=$macroblockStart $details '
        'end=${arithmetic.bitPosition} eos=$terminated',
      );
    } catch (error) {
      throw FormatException(
        'CABAC P macroblock $mbAddr failed at bit ${arithmetic.bitPosition} '
        '(start $macroblockStart): $error',
      );
    }

    mbAddr++;
  }

  if (!arithmetic.isTerminated) {
    throw const FormatException(
      'CABAC P slice ended without a terminating arithmetic bin',
    );
  }
  return (qpY: qpY, intra: intra, inter: inter, skipped: skipped);
}

({int qpY, String details}) _decodeCabacPInterMacroblock({
  required H264CabacSliceDataDecoder syntax,
  required CabacMacroblockType type,
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> references,
  required PredictionWeightTable weights,
  required int mbAddr,
  required int sliceId,
  required int previousQpY,
  required CabacMacroblockNeighbors neighbors,
}) {
  if (type.sliceType != H264CabacSliceType.p ||
      type.kind != CabacMacroblockKind.inter ||
      type.codeNum == null ||
      type.codeNum! < 0 ||
      type.codeNum! > 3) {
    throw FormatException(
      'CABAC weighted-P subset requires P_L0_16x16, P_L0_L0_16x8, or '
      'P_L0_L0_8x16, or bounded P_8x8, got '
      'mb_type=${type.codeNum}',
    );
  }

  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final x = mbX * 16;
  final y = mbY * 16;
  final subMacroblockTypes = <CabacSubMacroblockType>[];
  if (type.codeNum == 3) {
    for (var index = 0; index < 4; index++) {
      final subType = syntax.decodeSubMbType();
      if (subType.codeNum != 0 ||
          subType.partitionCount != 1 ||
          subType.partitionWidth != 8 ||
          subType.partitionHeight != 8) {
        throw FormatException(
          'Unsupported non-skip CABAC P_8x8 '
          'sub_mb_type=${subType.codeNum} at 8x8 region $index; only '
          'P_L0_8x8 is implemented',
        );
      }
      subMacroblockTypes.add(subType);
    }
  }
  final partitions = switch (type.codeNum!) {
    0 => <_CabacPPartition>[
      (
        x: x,
        y: y,
        width: 16,
        height: 16,
        kind: InterPartitionKind.p16x16,
        index: 0,
      ),
    ],
    1 => <_CabacPPartition>[
      (
        x: x,
        y: y,
        width: 16,
        height: 8,
        kind: InterPartitionKind.p16x8,
        index: 0,
      ),
      (
        x: x,
        y: y + 8,
        width: 16,
        height: 8,
        kind: InterPartitionKind.p16x8,
        index: 1,
      ),
    ],
    2 => <_CabacPPartition>[
      (
        x: x,
        y: y,
        width: 8,
        height: 16,
        kind: InterPartitionKind.p8x16,
        index: 0,
      ),
      (
        x: x + 8,
        y: y,
        width: 8,
        height: 16,
        kind: InterPartitionKind.p8x16,
        index: 1,
      ),
    ],
    3 => <_CabacPPartition>[
      for (var index = 0; index < 4; index++)
        (
          x: x + (index & 1) * 8,
          y: y + (index >> 1) * 8,
          width: 8,
          height: 8,
          kind: InterPartitionKind.subMacroblock,
          index: index,
        ),
    ],
    _ => throw StateError('validated CABAC P mb_type=${type.codeNum}'),
  };

  // macroblock_pred() carries every partition's ref_idx_l0 before any MVD.
  // Seed only the reference identity into the local frame grid so each
  // subsequent partition sees the preceding partition in its CABAC ref_idx
  // context.
  // Each entry is overwritten with its final MVP+MVD before it can contribute
  // to an MVD context or a later macroblock.
  final referenceIndices = <int>[];
  for (final partition in partitions) {
    final blockX = partition.x >> 2;
    final blockY = partition.y >> 2;
    final referenceIndex = syntax
        .decodeReferenceIndex(
          list: CabacReferenceList.l0,
          activeReferenceCount: header.numRefIdxL0ActiveMinus1 + 1,
          left: state.cabacReferenceNeighbor(
            blockX - 1,
            blockY,
            sliceId: sliceId,
          ),
          top: state.cabacReferenceNeighbor(
            blockX,
            blockY - 1,
            sliceId: sliceId,
          ),
        )
        .value;
    if (referenceIndex < 0 || referenceIndex >= references.length) {
      throw FormatException(
        'CABAC weighted-P ref_idx_l0 $referenceIndex is outside the '
        '${references.length}-entry active List0',
      );
    }
    referenceIndices.add(referenceIndex);
    state.motion.setPartition(
      x: partition.x,
      y: partition.y,
      width: partition.width,
      height: partition.height,
      vector: MotionVector.zero,
      referenceIndex: referenceIndex,
      sliceId: sliceId,
    );
  }

  final motionDetails = <String>[];
  for (var index = 0; index < partitions.length; index++) {
    final partition = partitions[index];
    final blockX = partition.x >> 2;
    final blockY = partition.y >> 2;
    final referenceIndex = referenceIndices[index];
    final mvd = syntax.decodeMotionVectorDifference(
      left: state.cabacMvdNeighbor(blockX - 1, blockY, sliceId: sliceId),
      top: state.cabacMvdNeighbor(blockX, blockY - 1, sliceId: sliceId),
    );
    final predictor = deriveMotionVectorPredictor(
      grid: state.motion,
      partitionX: partition.x,
      partitionY: partition.y,
      partitionWidth: partition.width,
      partitionHeight: partition.height,
      referenceIndex: referenceIndex,
      partitionKind: partition.kind,
      partitionIndex: partition.index,
      currentSliceId: sliceId,
    );
    final vector = MotionVector(
      predictor.x + mvd.horizontal,
      predictor.y + mvd.vertical,
    );
    writeInterPrediction420(
      reference: references[referenceIndex].buffer,
      destination: state.picture,
      x: partition.x,
      y: partition.y,
      width: partition.width,
      height: partition.height,
      motionVector: vector,
    );
    _applyExplicitWeightedPrediction420(
      picture: state.picture,
      x: partition.x,
      y: partition.y,
      width: partition.width,
      height: partition.height,
      table: weights,
      referenceIndex: referenceIndex,
    );
    state.motion.setPartition(
      x: partition.x,
      y: partition.y,
      width: partition.width,
      height: partition.height,
      vector: vector,
      referenceIndex: referenceIndex,
      sliceId: sliceId,
    );
    state.setCabacMvdPartition(
      x: partition.x,
      y: partition.y,
      width: partition.width,
      height: partition.height,
      mvd: mvd,
    );
    motionDetails.add(
      'part=${partition.index} ref=$referenceIndex '
      'mvd=${mvd.horizontal},${mvd.vertical}',
    );
  }

  final codedBlockPattern = syntax.decodeCodedBlockPattern(
    neighbors: neighbors,
  );
  final transformFlagPresent = isCabacTransformSize8x8FlagPresent(
    transform8x8ModeFlag: header.pps.transform8x8ModeFlag,
    macroblockType: type,
    codedBlockPattern: codedBlockPattern,
    subMacroblockTypes: subMacroblockTypes,
  );
  final transformSize8x8 = transformFlagPresent
      ? syntax.decodeTransformSize8x8Flag(neighbors: neighbors)
      : false;
  final deltaQp = codedBlockPattern.packed == 0 ? 0 : syntax.decodeMbQpDelta();
  if (codedBlockPattern.packed == 0) {
    syntax.noteMacroblockWithoutQpDelta();
  }
  final qpY = (previousQpY + deltaQp + 52) % 52;
  final qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset);
  final qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset);

  final meta = state.macroblocks[mbAddr];
  if (meta.decoded) throw FormatException('Macroblock $mbAddr decoded twice');
  meta
    ..sliceId = sliceId
    ..isIntra = false
    ..isIntra16x16 = false
    ..usesIntra4x4 = false
    ..usesIntra8x8 = false
    ..transformSize8x8 = transformSize8x8
    ..skipped = false
    ..direct = false
    ..codedBlockPatternLuma = codedBlockPattern.luma
    ..codedBlockPatternChroma = codedBlockPattern.chroma
    ..intraChromaPredictionMode = 0
    ..qpY = qpY
    ..qpCb = qpCb
    ..qpCr = qpCr;

  late final List<List<int>> cb;
  late final List<List<int>> cr;
  if (transformSize8x8) {
    final residual = _decodeCabac8x8Residual(
      syntax: syntax,
      state: state,
      mbAddr: mbAddr,
      sliceId: sliceId,
      codedBlockPatternLuma: codedBlockPattern.luma,
      codedBlockPatternChroma: codedBlockPattern.chroma,
      currentMacroblockIntra: false,
    );
    cb = residual.cb;
    cr = residual.cr;
    for (var group = 0; group < 4; group++) {
      _add8x8Residual(
        plane: state.picture.y,
        stride: state.picture.lumaStride,
        x: x + (group & 1) * 8,
        y: y + (group >> 1) * 8,
        residual: invTransform8x8(residual.luma8x8[group], qp: qpY),
      );
    }
    meta.lumaReconstructed.fillRange(0, 16, true);
  } else {
    final residual = _decodeCabac4x4Residual(
      syntax: syntax,
      state: state,
      mbAddr: mbAddr,
      sliceId: sliceId,
      codedBlockPatternLuma: codedBlockPattern.luma,
      codedBlockPatternChroma: codedBlockPattern.chroma,
      currentMacroblockIntra: false,
    );
    cb = residual.cb;
    cr = residual.cr;
    _addInterLumaResidual(state, mbAddr, qpY, residual.luma);
  }
  _addInterChromaResidual(
    state: state,
    mbAddr: mbAddr,
    qpCb: qpCb,
    qpCr: qpCr,
    cbCoefficients: cb,
    crCoefficients: cr,
  );

  meta
    ..decoded = true
    ..lumaDcTotalCoeff = 0
    ..lumaDcCoded = false;
  for (var block = 0; block < 16; block++) {
    if (meta.lumaTotalCoeff[block] < 0) meta.lumaTotalCoeff[block] = 0;
  }
  for (var block = 0; block < 4; block++) {
    if (meta.cbTotalCoeff[block] < 0) meta.cbTotalCoeff[block] = 0;
    if (meta.crTotalCoeff[block] < 0) meta.crTotalCoeff[block] = 0;
  }
  return (
    qpY: qpY,
    details:
        '${switch (type.codeNum) {
          0 => 'p16x16',
          1 => 'p16x8',
          2 => 'p8x16',
          _ => 'p8x8',
        }} '
        '${motionDetails.join(' ')} '
        'cbpL=${codedBlockPattern.luma} cbpC=${codedBlockPattern.chroma} '
        'transform8=$transformSize8x8',
  );
}

/// Bounded sfux CABAC B reconstruction for spatial-Direct Skip/Direct,
/// B_L0_16x16, B_L1_16x16, B_Bi_16x16, bounded 16x8/8x16 partitions, and
/// intra macroblocks.
///
/// B_Skip is spatial Direct. The authoritative motion field retains both
/// lists at 4x4 granularity, while reconstruction uses implicit POC-derived
/// weighted bi-prediction for each inferred Direct 8x8 region.
_SliceDecodeResult _decodeCabacBSlice({
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> referencesL0,
  required List<_DecodedPicture> referencesL1,
  required int? currentPictureOrderCount,
  required int sliceId,
  required int initialQpY,
}) {
  if (header.isIdr || header.sliceType != H264SliceType.b) {
    throw const FormatException(
      'CABAC B reconstruction requires a non-IDR B slice',
    );
  }
  if (referencesL0.isEmpty || referencesL1.isEmpty || referencesL1.length > 2) {
    throw FormatException(
      'CABAC B reconstruction requires non-empty List0 and one or two List1 '
      'references; got '
      '${referencesL0.length}/${referencesL1.length}',
    );
  }
  final currentPoc = currentPictureOrderCount;
  if (currentPoc == null) {
    throw const FormatException(
      'CABAC B reconstruction requires a derived picture order count',
    );
  }
  final dualMotion = state.dualMotion;
  if (dualMotion == null) {
    throw StateError('CABAC B reconstruction has no dual motion field');
  }

  final reader = header.reader;
  readCabacAlignmentOneBits(reader);
  final arithmetic = H264CabacDecoder.initialize(reader);
  final syntax = H264CabacSliceDataDecoder.fromArithmetic(
    decoder: arithmetic,
    contexts: H264CabacContextSet.initialize(
      sliceType: H264CabacSliceType.b,
      sliceQpY: header.sliceQpY,
      cabacInitIdc: header.cabacInitIdc!,
    ),
  );

  final predictionL1 = _emptyPictureLike(state.picture);
  final skippedType = H264BInterMacroblockType.skipped();
  final mbCount = state.macroblocks.length;
  var mbAddr = header.firstMbInSlice;
  if (mbAddr < 0 || mbAddr >= mbCount) {
    throw FormatException('first_mb_in_slice=$mbAddr is outside the picture');
  }

  var qpY = initialQpY;
  var intra = 0;
  var inter = 0;
  var skipped = 0;
  var terminated = false;
  while (!terminated) {
    if (mbAddr >= mbCount) {
      throw const FormatException(
        'CABAC B slice reached the end of the picture without '
        'end_of_slice_flag',
      );
    }

    final macroblockStart = arithmetic.bitPosition;
    try {
      final neighbors = _cabacMacroblockNeighbors(
        state,
        mbAddr: mbAddr,
        sliceId: sliceId,
      );
      final start = syntax.decodeMacroblockStart(neighbors: neighbors);
      String details;
      if (start.skipped) {
        _writeCabacBDirectPrediction(
          state: state,
          header: header,
          referencesL0: referencesL0,
          referencesL1: referencesL1,
          currentPoc: currentPoc,
          predictionL1: predictionL1,
          macroblockType: skippedType,
          mbAddr: mbAddr,
          sliceId: sliceId,
        );

        _markCabacBSkipMacroblock(
          state: state,
          header: header,
          mbAddr: mbAddr,
          sliceId: sliceId,
          qpY: qpY,
        );
        skipped++;
        details = 'skip';
      } else if (start.type.kind == CabacMacroblockKind.intra16x16) {
        final result = _decodeCabacIntra16Macroblock(
          syntax: syntax,
          type: start.type,
          header: header,
          state: state,
          mbAddr: mbAddr,
          sliceId: sliceId,
          previousQpY: qpY,
          neighbors: neighbors,
        );
        qpY = result.qpY;
        intra++;
        details = result.details;
      } else if (start.type.kind == CabacMacroblockKind.intraNxN) {
        final result = _decodeCabacIntraNxNMacroblock(
          syntax: syntax,
          header: header,
          state: state,
          mbAddr: mbAddr,
          sliceId: sliceId,
          previousQpY: qpY,
          neighbors: neighbors,
        );
        qpY = result.qpY;
        intra++;
        details = result.details;
      } else if ((start.type.kind == CabacMacroblockKind.direct &&
              start.type.codeNum == 0) ||
          (start.type.kind == CabacMacroblockKind.inter &&
              (start.type.codeNum == 1 ||
                  start.type.codeNum == 2 ||
                  start.type.codeNum == 3 ||
                  start.type.codeNum == 4 ||
                  start.type.codeNum == 5 ||
                  start.type.codeNum == 6 ||
                  start.type.codeNum == 7 ||
                  start.type.codeNum == 8 ||
                  start.type.codeNum == 9 ||
                  start.type.codeNum == 10 ||
                  start.type.codeNum == 11 ||
                  start.type.codeNum == 12 ||
                  start.type.codeNum == 13 ||
                  start.type.codeNum == 14 ||
                  start.type.codeNum == 15 ||
                  start.type.codeNum == 16 ||
                  start.type.codeNum == 17 ||
                  start.type.codeNum == 18 ||
                  start.type.codeNum == 19 ||
                  start.type.codeNum == 20 ||
                  start.type.codeNum == 21 ||
                  start.type.codeNum == 22))) {
        final result = _decodeCabacBInterMacroblock(
          syntax: syntax,
          type: start.type,
          header: header,
          state: state,
          referencesL0: referencesL0,
          referencesL1: referencesL1,
          currentPoc: currentPoc,
          predictionL1: predictionL1,
          mbAddr: mbAddr,
          sliceId: sliceId,
          previousQpY: qpY,
          neighbors: neighbors,
        );
        qpY = result.qpY;
        inter++;
        details = result.details;
      } else {
        throw FormatException(
          'Unsupported non-skip CABAC B macroblock kind '
          '${start.type.kind.name} (mb_type=${start.type.codeNum}); '
          'only B_Skip, B_Direct_16x16, B_L0_16x16, B_L1_16x16, '
          'B_Bi_16x16, bounded B 16x8/8x16 partitions, bounded B_8x8, '
          'I_16x16, Intra_4x4, and Intra_8x8 are implemented',
        );
      }
      terminated = syntax.decodeEndOfSliceFlag();
      h264DecoderTrace?.call(
        'cabac b mb=$mbAddr start=$macroblockStart $details qp=$qpY '
        'end=${arithmetic.bitPosition} eos=$terminated',
      );
    } catch (error) {
      throw FormatException(
        'CABAC B macroblock $mbAddr failed at bit ${arithmetic.bitPosition} '
        '(start $macroblockStart): $error',
      );
    }

    mbAddr++;
  }

  if (!arithmetic.isTerminated) {
    throw const FormatException(
      'CABAC B slice ended without a terminating arithmetic bin',
    );
  }
  return (qpY: qpY, intra: intra, inter: inter, skipped: skipped);
}

const _cabacBZeroMvd = CabacMotionVectorDifference(horizontal: 0, vertical: 0);

final class _CabacBSubPartitionSyntax {
  _CabacBSubPartitionSyntax({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
  CabacMotionVectorDifference mvdL0 = _cabacBZeroMvd;
  CabacMotionVectorDifference mvdL1 = _cabacBZeroMvd;
}

final class _CabacBPartitionSyntax {
  _CabacBPartitionSyntax({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.mode,
    required this.subPartitions,
  });

  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
  final H264BPredictionMode mode;
  final List<_CabacBSubPartitionSyntax> subPartitions;
  int? referenceIndexL0;
  int? referenceIndexL1;

  bool get direct => mode == H264BPredictionMode.direct;
}

final class _CabacBPendingSyntaxCell {
  _CabacBPendingSyntaxCell({
    required this.usesList0,
    required this.usesList1,
    required this.direct,
  }) : referenceIndexL0 = usesList0 ? 0 : -1,
       referenceIndexL1 = usesList1 ? 0 : -1;

  bool usesList0;
  bool usesList1;
  final bool direct;
  int referenceIndexL0;
  int referenceIndexL1;
  CabacMotionVectorDifference mvdL0 = _cabacBZeroMvd;
  CabacMotionVectorDifference mvdL1 = _cabacBZeroMvd;
}

/// Current-macroblock CABAC ref/MVD syntax state kept separate from the
/// authoritative dual-motion grid until every syntax element is decoded.
/// This preserves list-major syntax contexts without exposing placeholder
/// references to normative MVP derivation.
final class _CabacBPendingSyntaxOverlay {
  _CabacBPendingSyntaxOverlay({
    required this.state,
    required this.macroblockX,
    required this.macroblockY,
    required this.sliceId,
  });

  final _FrameState state;
  final int macroblockX;
  final int macroblockY;
  final int sliceId;
  final List<_CabacBPendingSyntaxCell?> _cells =
      List<_CabacBPendingSyntaxCell?>.filled(16, null);

  int get _originX4 => macroblockX * 4;
  int get _originY4 => macroblockY * 4;

  bool _contains(int x4, int y4) =>
      x4 >= _originX4 &&
      x4 < _originX4 + 4 &&
      y4 >= _originY4 &&
      y4 < _originY4 + 4;

  int _index(int x4, int y4) => (y4 - _originY4) * 4 + (x4 - _originX4);

  void definePartition(_CabacBPartitionSyntax partition) {
    final usesList0 = partition.mode.explicitlyUsesList0;
    final usesList1 = partition.mode.explicitlyUsesList1;
    _forPartition(partition.x, partition.y, partition.width, partition.height, (
      index,
    ) {
      _cells[index] = _CabacBPendingSyntaxCell(
        usesList0: usesList0,
        usesList1: usesList1,
        direct: partition.direct,
      );
    });
  }

  CabacReferenceNeighbor referenceNeighbor(
    CabacReferenceList list,
    int x4,
    int y4,
  ) {
    if (!_contains(x4, y4)) {
      return state.cabacBReferenceNeighbor(list, x4, y4, sliceId: sliceId);
    }
    final cell = _cells[_index(x4, y4)];
    if (cell == null) return const CabacReferenceNeighbor.unavailable();
    final usesList = list == CabacReferenceList.l0
        ? cell.usesList0
        : cell.usesList1;
    return CabacReferenceNeighbor(
      direct: cell.direct,
      referenceIndex: usesList
          ? (list == CabacReferenceList.l0
                ? cell.referenceIndexL0
                : cell.referenceIndexL1)
          : -1,
    );
  }

  CabacMvdNeighbor mvdNeighbor(CabacReferenceList list, int x4, int y4) {
    if (!_contains(x4, y4)) {
      return state.cabacBMvdNeighbor(list, x4, y4, sliceId: sliceId);
    }
    final cell = _cells[_index(x4, y4)];
    if (cell == null) return const CabacMvdNeighbor.unavailable();
    final usesList = list == CabacReferenceList.l0
        ? cell.usesList0
        : cell.usesList1;
    final mvd = usesList && !cell.direct
        ? (list == CabacReferenceList.l0 ? cell.mvdL0 : cell.mvdL1)
        : _cabacBZeroMvd;
    return CabacMvdNeighbor(horizontal: mvd.horizontal, vertical: mvd.vertical);
  }

  void setReference(
    _CabacBPartitionSyntax partition,
    CabacReferenceList list,
    int referenceIndex,
  ) {
    _forPartition(partition.x, partition.y, partition.width, partition.height, (
      index,
    ) {
      final cell = _cells[index]!;
      if (list == CabacReferenceList.l0) {
        cell
          ..usesList0 = true
          ..referenceIndexL0 = referenceIndex;
      } else {
        cell
          ..usesList1 = true
          ..referenceIndexL1 = referenceIndex;
      }
    });
  }

  void setMvd(
    _CabacBSubPartitionSyntax partition,
    CabacReferenceList list,
    CabacMotionVectorDifference mvd,
  ) {
    _forPartition(partition.x, partition.y, partition.width, partition.height, (
      index,
    ) {
      final cell = _cells[index]!;
      if (list == CabacReferenceList.l0) {
        cell.mvdL0 = mvd;
      } else {
        cell.mvdL1 = mvd;
      }
    });
  }

  void _forPartition(
    int x,
    int y,
    int width,
    int height,
    void Function(int index) action,
  ) {
    final startX4 = x >> 2;
    final startY4 = y >> 2;
    for (var y4 = startY4; y4 < startY4 + (height >> 2); y4++) {
      for (var x4 = startX4; x4 < startX4 + (width >> 2); x4++) {
        if (!_contains(x4, y4)) {
          throw StateError('Pending CABAC B partition escaped its macroblock');
        }
        action(_index(x4, y4));
      }
    }
  }
}

({int qpY, String details}) _decodeCabacBInterMacroblock({
  required H264CabacSliceDataDecoder syntax,
  required CabacMacroblockType type,
  required SliceHeader header,
  required _FrameState state,
  required List<_DecodedPicture> referencesL0,
  required List<_DecodedPicture> referencesL1,
  required int currentPoc,
  required Yuv420PictureBuffer predictionL1,
  required int mbAddr,
  required int sliceId,
  required int previousQpY,
  required CabacMacroblockNeighbors neighbors,
}) {
  final code = type.codeNum;
  final directMacroblock = type.kind == CabacMacroblockKind.direct && code == 0;
  final supportedInter =
      type.kind == CabacMacroblockKind.inter &&
      (code == 1 ||
          code == 2 ||
          code == 3 ||
          code == 4 ||
          code == 5 ||
          code == 6 ||
          code == 7 ||
          code == 8 ||
          code == 9 ||
          code == 10 ||
          code == 11 ||
          code == 12 ||
          code == 13 ||
          code == 14 ||
          code == 15 ||
          code == 16 ||
          code == 17 ||
          code == 18 ||
          code == 19 ||
          code == 20 ||
          code == 21 ||
          code == 22);
  if (type.sliceType != H264CabacSliceType.b ||
      code == null ||
      (!directMacroblock && !supportedInter)) {
    throw FormatException(
      'CABAC B inter subset requires B_Direct_16x16, B_L0_16x16, '
      'B_L1_16x16, B_Bi_16x16, bounded B 16x8/8x16 partitions, '
      'or bounded B_8x8, '
      'got mb_type=${type.codeNum}',
    );
  }

  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final x = mbX * 16;
  final y = mbY * 16;
  final macroblockType = H264BInterMacroblockType.fromCode(code);
  final decodedSubMacroblockTypes = <CabacSubMacroblockType>[];
  final partitions = <_CabacBPartitionSyntax>[];
  final syntaxDetails = <String>[];
  if (code == 22) {
    for (var index = 0; index < 4; index++) {
      final subType = syntax.decodeSubMbType();
      if (subType.codeNum != 0 &&
          subType.codeNum != 1 &&
          subType.codeNum != 2 &&
          subType.codeNum != 3) {
        throw FormatException(
          'Unsupported CABAC B_8x8 sub_mb_type=${subType.codeNum} at '
          '8x8 region $index; only Direct, B_L0_8x8, B_L1_8x8, and '
          'B_Bi_8x8 are implemented',
        );
      }
      if (subType.partitionCount != 1 ||
          subType.partitionWidth != 8 ||
          subType.partitionHeight != 8) {
        throw FormatException(
          'CABAC B_8x8 sub_mb_type=${subType.codeNum} has unsupported '
          '${subType.partitionWidth}x${subType.partitionHeight} subdivision',
        );
      }
      decodedSubMacroblockTypes.add(subType);
      syntaxDetails.add('subtype=$index:${subType.codeNum}');
      final partX = x + (index & 1) * 8;
      final partY = y + (index >> 1) * 8;
      partitions.add(
        _CabacBPartitionSyntax(
          index: index,
          x: partX,
          y: partY,
          width: 8,
          height: 8,
          mode: switch (subType.codeNum) {
            0 => H264BPredictionMode.direct,
            1 => H264BPredictionMode.list0,
            2 => H264BPredictionMode.list1,
            3 => H264BPredictionMode.bi,
            _ => throw StateError(
              'Validated B_8x8 sub_mb_type=${subType.codeNum} escaped its '
              'bounded prediction-mode map',
            ),
          },
          subPartitions: <_CabacBSubPartitionSyntax>[
            _CabacBSubPartitionSyntax(
              index: 0,
              x: partX,
              y: partY,
              width: 8,
              height: 8,
            ),
          ],
        ),
      );
    }
  } else {
    for (final partition in macroblockType.partitionsAt(
      macroblockX: x,
      macroblockY: y,
    )) {
      final mode = partition.predictionMode;
      if (mode == null) {
        throw StateError('${macroblockType.name} has an unresolved partition');
      }
      partitions.add(
        _CabacBPartitionSyntax(
          index: partition.macroblockPartitionIndex,
          x: partition.x,
          y: partition.y,
          width: partition.width,
          height: partition.height,
          mode: mode,
          subPartitions: <_CabacBSubPartitionSyntax>[
            _CabacBSubPartitionSyntax(
              index: 0,
              x: partition.x,
              y: partition.y,
              width: partition.width,
              height: partition.height,
            ),
          ],
        ),
      );
    }
  }

  final pending = _CabacBPendingSyntaxOverlay(
    state: state,
    macroblockX: mbX,
    macroblockY: mbY,
    sliceId: sliceId,
  );
  for (final partition in partitions) {
    pending.definePartition(partition);
  }

  for (final list in CabacReferenceList.values) {
    final activeReferenceCount = list == CabacReferenceList.l0
        ? header.numRefIdxL0ActiveMinus1 + 1
        : header.numRefIdxL1ActiveMinus1 + 1;
    final referenceCount = list == CabacReferenceList.l0
        ? referencesL0.length
        : referencesL1.length;
    for (final partition in partitions) {
      final usesList = list == CabacReferenceList.l0
          ? partition.mode.explicitlyUsesList0
          : partition.mode.explicitlyUsesList1;
      if (!usesList || partition.direct) continue;
      final x4 = partition.x >> 2;
      final y4 = partition.y >> 2;
      final referenceIndex = syntax
          .decodeReferenceIndex(
            list: list,
            activeReferenceCount: activeReferenceCount,
            left: pending.referenceNeighbor(list, x4 - 1, y4),
            top: pending.referenceNeighbor(list, x4, y4 - 1),
          )
          .value;
      if (referenceIndex >= referenceCount) {
        throw FormatException(
          '${macroblockType.name} partition ${partition.index} selected '
          'unavailable ${list.name} reference $referenceIndex',
        );
      }
      if (list == CabacReferenceList.l0) {
        partition.referenceIndexL0 = referenceIndex;
      } else {
        partition.referenceIndexL1 = referenceIndex;
      }
      pending.setReference(partition, list, referenceIndex);
      syntaxDetails.add(
        'part=${partition.index} ${list.name}ref=$referenceIndex',
      );
    }
  }

  for (final list in CabacReferenceList.values) {
    for (final partition in partitions) {
      final usesList = list == CabacReferenceList.l0
          ? partition.mode.explicitlyUsesList0
          : partition.mode.explicitlyUsesList1;
      if (!usesList || partition.direct) continue;
      for (final subPartition in partition.subPartitions) {
        final x4 = subPartition.x >> 2;
        final y4 = subPartition.y >> 2;
        final mvd = syntax.decodeMotionVectorDifference(
          left: pending.mvdNeighbor(list, x4 - 1, y4),
          top: pending.mvdNeighbor(list, x4, y4 - 1),
        );
        if (list == CabacReferenceList.l0) {
          subPartition.mvdL0 = mvd;
        } else {
          subPartition.mvdL1 = mvd;
        }
        pending.setMvd(subPartition, list, mvd);
        syntaxDetails.add(
          'part=${partition.index} sub=${subPartition.index} '
          '${list.name}mvd=${mvd.horizontal},${mvd.vertical}',
        );
      }
    }
  }

  final hasDirectPartition = partitions.any((partition) => partition.direct);
  final spatialDirectContext =
      hasDirectPartition && header.directSpatialMvPredFlag
      ? deriveSpatialDirectContext(
          grid: state.dualMotion!,
          macroblockX: x,
          macroblockY: y,
          currentSliceId: sliceId,
        )
      : null;
  final temporalDirectContext =
      hasDirectPartition && !header.directSpatialMvPredFlag
      ? _buildTemporalDirectContext(
          referencesL0: referencesL0,
          referencesL1: referencesL1,
          currentPoc: currentPoc,
        )
      : null;
  final partitionShape = switch (code) {
    5 ||
    7 ||
    9 ||
    11 ||
    13 ||
    15 ||
    17 ||
    19 ||
    21 => H264BPartitionShape.vertical8x16,
    4 ||
    6 ||
    8 ||
    10 ||
    12 ||
    14 ||
    16 ||
    18 ||
    20 => H264BPartitionShape.horizontal16x8,
    22 => H264BPartitionShape.subMacroblock,
    _ => H264BPartitionShape.block16x16,
  };
  for (final partition in partitions) {
    for (final subPartition in partition.subPartitions) {
      late final H264DualListMotion motion;
      if (partition.direct) {
        final colocatedPosition = deriveDirectColocatedLumaSamplePosition(
          macroblockX: x,
          macroblockY: y,
          macroblockPartitionIndex: partition.index,
          subMacroblockPartitionIndex: subPartition.index,
          direct8x8Inference: header.sps.direct8x8InferenceFlag,
        );
        motion = header.directSpatialMvPredFlag
            ? spatialDirectContext!.resolve(
                colocated: _colocatedMotionAt(
                  referencesL1[0],
                  colocatedPosition.x,
                  colocatedPosition.y,
                ),
                list1Reference0IsShortTerm: true,
              )
            : temporalDirectContext!.resolve(
                _temporalColocatedMotionAt(
                  referencesL1[0],
                  colocatedPosition.x,
                  colocatedPosition.y,
                ),
              );
      } else {
        motion = deriveBInterMotion(
          grid: state.dualMotion!,
          mode: partition.mode,
          partitionX: subPartition.x,
          partitionY: subPartition.y,
          partitionWidth: subPartition.width,
          partitionHeight: subPartition.height,
          partitionShape: partitionShape,
          partitionIndex: partition.index,
          referenceIndexL0: partition.referenceIndexL0,
          referenceIndexL1: partition.referenceIndexL1,
          differenceL0: MotionVector(
            subPartition.mvdL0.horizontal,
            subPartition.mvdL0.vertical,
          ),
          differenceL1: MotionVector(
            subPartition.mvdL1.horizontal,
            subPartition.mvdL1.vertical,
          ),
          currentSliceId: sliceId,
        );
      }
      _writeCabacBPrediction(
        state: state,
        referencesL0: referencesL0,
        referencesL1: referencesL1,
        currentPoc: currentPoc,
        predictionL1: predictionL1,
        motion: motion,
        x: subPartition.x,
        y: subPartition.y,
        width: subPartition.width,
        height: subPartition.height,
      );
      state.dualMotion!.setPartition(
        x: subPartition.x,
        y: subPartition.y,
        width: subPartition.width,
        height: subPartition.height,
        motion: motion,
        sliceId: sliceId,
      );
      if (!partition.direct && partition.mode.explicitlyUsesList0) {
        state.setCabacBMvdPartition(
          list: CabacReferenceList.l0,
          x: subPartition.x,
          y: subPartition.y,
          width: subPartition.width,
          height: subPartition.height,
          mvd: subPartition.mvdL0,
        );
      }
      if (!partition.direct && partition.mode.explicitlyUsesList1) {
        state.setCabacBMvdPartition(
          list: CabacReferenceList.l1,
          x: subPartition.x,
          y: subPartition.y,
          width: subPartition.width,
          height: subPartition.height,
          mvd: subPartition.mvdL1,
        );
      }
      final list0 = motion.list0;
      final list1 = motion.list1;
      syntaxDetails.add(
        'part=${partition.index} sub=${subPartition.index} '
        'mode=${motion.effectiveMode.name} '
        'motion=${list0?.referenceIndex ?? -1}:'
        '${list0?.vector.x ?? 0},${list0?.vector.y ?? 0}/'
        '${list1?.referenceIndex ?? -1}:'
        '${list1?.vector.x ?? 0},${list1?.vector.y ?? 0}',
      );
    }
  }
  final motionDetails = '${macroblockType.name} ${syntaxDetails.join(' ')}';

  final codedBlockPattern = syntax.decodeCodedBlockPattern(
    neighbors: neighbors,
  );
  final transformFlagPresent = isCabacTransformSize8x8FlagPresent(
    transform8x8ModeFlag: header.pps.transform8x8ModeFlag,
    macroblockType: type,
    codedBlockPattern: codedBlockPattern,
    subMacroblockTypes: decodedSubMacroblockTypes,
    direct8x8InferenceFlag: header.sps.direct8x8InferenceFlag,
  );
  final transformSize8x8 = transformFlagPresent
      ? syntax.decodeTransformSize8x8Flag(neighbors: neighbors)
      : false;
  final deltaQp = codedBlockPattern.packed == 0 ? 0 : syntax.decodeMbQpDelta();
  if (codedBlockPattern.packed == 0) syntax.noteMacroblockWithoutQpDelta();
  final qpY = (previousQpY + deltaQp + 52) % 52;
  final qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset);
  final qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset);

  final meta = state.macroblocks[mbAddr];
  if (meta.decoded) throw FormatException('Macroblock $mbAddr decoded twice');
  meta
    ..sliceId = sliceId
    ..isIntra = false
    ..isIntra16x16 = false
    ..usesIntra4x4 = false
    ..usesIntra8x8 = false
    ..transformSize8x8 = transformSize8x8
    ..skipped = false
    ..direct = directMacroblock
    ..codedBlockPatternLuma = codedBlockPattern.luma
    ..codedBlockPatternChroma = codedBlockPattern.chroma
    ..intraChromaPredictionMode = 0
    ..qpY = qpY
    ..qpCb = qpCb
    ..qpCr = qpCr;

  late final List<List<int>> cb;
  late final List<List<int>> cr;
  if (transformSize8x8) {
    final residual = _decodeCabac8x8Residual(
      syntax: syntax,
      state: state,
      mbAddr: mbAddr,
      sliceId: sliceId,
      codedBlockPatternLuma: codedBlockPattern.luma,
      codedBlockPatternChroma: codedBlockPattern.chroma,
      currentMacroblockIntra: false,
    );
    cb = residual.cb;
    cr = residual.cr;
    for (var group = 0; group < 4; group++) {
      _add8x8Residual(
        plane: state.picture.y,
        stride: state.picture.lumaStride,
        x: x + (group & 1) * 8,
        y: y + (group >> 1) * 8,
        residual: invTransform8x8(residual.luma8x8[group], qp: qpY),
      );
    }
    meta.lumaReconstructed.fillRange(0, 16, true);
  } else {
    final residual = _decodeCabac4x4Residual(
      syntax: syntax,
      state: state,
      mbAddr: mbAddr,
      sliceId: sliceId,
      codedBlockPatternLuma: codedBlockPattern.luma,
      codedBlockPatternChroma: codedBlockPattern.chroma,
      currentMacroblockIntra: false,
    );
    cb = residual.cb;
    cr = residual.cr;
    _addInterLumaResidual(state, mbAddr, qpY, residual.luma);
  }
  _addInterChromaResidual(
    state: state,
    mbAddr: mbAddr,
    qpCb: qpCb,
    qpCr: qpCr,
    cbCoefficients: cb,
    crCoefficients: cr,
  );

  meta
    ..decoded = true
    ..lumaDcTotalCoeff = 0
    ..lumaDcCoded = false;
  for (var block = 0; block < 16; block++) {
    if (meta.lumaTotalCoeff[block] < 0) meta.lumaTotalCoeff[block] = 0;
  }
  for (var block = 0; block < 4; block++) {
    if (meta.cbTotalCoeff[block] < 0) meta.cbTotalCoeff[block] = 0;
    if (meta.crTotalCoeff[block] < 0) meta.crTotalCoeff[block] = 0;
  }
  return (
    qpY: qpY,
    details:
        '$motionDetails cbpL=${codedBlockPattern.luma} '
        'cbpC=${codedBlockPattern.chroma} transform8=$transformSize8x8',
  );
}

void _writeCabacBDirectPrediction({
  required _FrameState state,
  required SliceHeader header,
  required List<_DecodedPicture> referencesL0,
  required List<_DecodedPicture> referencesL1,
  required int currentPoc,
  required Yuv420PictureBuffer predictionL1,
  required H264BInterMacroblockType macroblockType,
  required int mbAddr,
  required int sliceId,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final x = mbX * 16;
  final y = mbY * 16;
  final spatialDirectContext = header.directSpatialMvPredFlag
      ? deriveSpatialDirectContext(
          grid: state.dualMotion!,
          macroblockX: x,
          macroblockY: y,
          currentSliceId: sliceId,
        )
      : null;
  final temporalDirectContext = !header.directSpatialMvPredFlag
      ? _buildTemporalDirectContext(
          referencesL0: referencesL0,
          referencesL1: referencesL1,
          currentPoc: currentPoc,
        )
      : null;
  for (final region in macroblockType.directInferenceRegionsAt(
    macroblockX: x,
    macroblockY: y,
    direct8x8Inference: header.sps.direct8x8InferenceFlag,
  )) {
    final colocatedPosition = deriveDirectColocatedLumaSamplePosition(
      macroblockX: x,
      macroblockY: y,
      macroblockPartitionIndex: region.macroblockPartitionIndex,
      subMacroblockPartitionIndex: region.subMacroblockPartitionIndex!,
      direct8x8Inference: header.sps.direct8x8InferenceFlag,
    );
    final colocated = _colocatedMotionAt(
      referencesL1[0],
      colocatedPosition.x,
      colocatedPosition.y,
    );
    final motion = header.directSpatialMvPredFlag
        ? spatialDirectContext!.resolve(
            colocated: colocated,
            list1Reference0IsShortTerm: true,
          )
        : temporalDirectContext!.resolve(
            _temporalColocatedMotionAt(
              referencesL1[0],
              colocatedPosition.x,
              colocatedPosition.y,
            ),
          );
    _writeCabacBPrediction(
      state: state,
      referencesL0: referencesL0,
      referencesL1: referencesL1,
      currentPoc: currentPoc,
      predictionL1: predictionL1,
      motion: motion,
      x: region.x,
      y: region.y,
      width: region.width,
      height: region.height,
    );
    state.dualMotion!.setPartition(
      x: region.x,
      y: region.y,
      width: region.width,
      height: region.height,
      motion: motion,
      sliceId: sliceId,
    );
  }
}

void _writeCabacBPrediction({
  required _FrameState state,
  required List<_DecodedPicture> referencesL0,
  required List<_DecodedPicture> referencesL1,
  required int currentPoc,
  required Yuv420PictureBuffer predictionL1,
  required H264DualListMotion motion,
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  switch (motion.effectiveMode) {
    case H264BPredictionMode.list0:
      _writeCabacBUniList0Prediction(
        state: state,
        referencesL0: referencesL0,
        motion: motion,
        x: x,
        y: y,
        width: width,
        height: height,
      );
    case H264BPredictionMode.list1:
      _writeCabacBUniList1Prediction(
        state: state,
        referencesL1: referencesL1,
        motion: motion,
        x: x,
        y: y,
        width: width,
        height: height,
      );
    case H264BPredictionMode.bi:
      _writeCabacBDualPrediction(
        state: state,
        referencesL0: referencesL0,
        referencesL1: referencesL1,
        currentPoc: currentPoc,
        predictionL1: predictionL1,
        motion: motion,
        x: x,
        y: y,
        width: width,
        height: height,
      );
    case H264BPredictionMode.direct:
      throw StateError(
        'Direct syntax motion must resolve to an effective prediction list',
      );
  }
}

void _writeCabacBUniList1Prediction({
  required _FrameState state,
  required List<_DecodedPicture> referencesL1,
  required H264DualListMotion motion,
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  if (motion.list0 != null || motion.list1 == null) {
    throw const FormatException(
      'CABAC B List1 prediction requires List1-only motion',
    );
  }
  final list1 = motion.list1!;
  if (list1.referenceIndex >= referencesL1.length) {
    throw FormatException(
      'CABAC B List1 motion selected unavailable reference '
      '${list1.referenceIndex}',
    );
  }
  // weighted_bipred_idc=2 supplies implicit weights only when both lists are
  // used. A List1-only macroblock is ordinary uni-prediction.
  writeInterPrediction420(
    reference: referencesL1[list1.referenceIndex].buffer,
    destination: state.picture,
    x: x,
    y: y,
    width: width,
    height: height,
    motionVector: list1.vector,
  );
}

void _writeCabacBUniList0Prediction({
  required _FrameState state,
  required List<_DecodedPicture> referencesL0,
  required H264DualListMotion motion,
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  if (motion.list0 == null || motion.list1 != null) {
    throw const FormatException(
      'CABAC B List0 prediction requires List0-only motion',
    );
  }
  final list0 = motion.list0!;
  if (list0.referenceIndex >= referencesL0.length) {
    throw FormatException(
      'CABAC B List0 motion selected unavailable reference '
      '${list0.referenceIndex}',
    );
  }
  // weighted_bipred_idc=2 supplies implicit weights only when both lists are
  // used. A List0-only macroblock is ordinary uni-prediction.
  writeInterPrediction420(
    reference: referencesL0[list0.referenceIndex].buffer,
    destination: state.picture,
    x: x,
    y: y,
    width: width,
    height: height,
    motionVector: list0.vector,
  );
}

void _writeCabacBDualPrediction({
  required _FrameState state,
  required List<_DecodedPicture> referencesL0,
  required List<_DecodedPicture> referencesL1,
  required int currentPoc,
  required Yuv420PictureBuffer predictionL1,
  required H264DualListMotion motion,
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  final motionL0 = motion.list0;
  final motionL1 = motion.list1;
  if (motionL0 == null || motionL1 == null) {
    throw const FormatException('CABAC B subset requires bi-predicted motion');
  }
  if (motionL0.referenceIndex >= referencesL0.length ||
      motionL1.referenceIndex >= referencesL1.length) {
    throw FormatException(
      'CABAC B motion selected unavailable references '
      'L0=${motionL0.referenceIndex}, L1=${motionL1.referenceIndex}',
    );
  }
  final referenceL0 = referencesL0[motionL0.referenceIndex];
  final referenceL1 = referencesL1[motionL1.referenceIndex];
  final pocL0 = referenceL0.pictureOrderCount;
  final pocL1 = referenceL1.pictureOrderCount;
  if (pocL0 == null || pocL1 == null) {
    throw const FormatException(
      'Implicit weighted B prediction requires reference POCs',
    );
  }

  writeInterPrediction420(
    reference: referenceL0.buffer,
    destination: state.picture,
    x: x,
    y: y,
    width: width,
    height: height,
    motionVector: motionL0.vector,
  );
  writeInterPrediction420(
    reference: referenceL1.buffer,
    destination: predictionL1,
    x: x,
    y: y,
    width: width,
    height: height,
    motionVector: motionL1.vector,
  );
  _applyImplicitWeightedBiPrediction420(
    list0: state.picture,
    list1: predictionL1,
    destination: state.picture,
    x: x,
    y: y,
    width: width,
    height: height,
    weights: deriveImplicitBiPredictionWeights(
      currentPoc: currentPoc,
      list0Poc: pocL0,
      list1Poc: pocL1,
    ),
  );
}

H264ColocatedMotion _colocatedMotionAt(_DecodedPicture picture, int x, int y) {
  final dual = picture.dualMotion;
  if (dual != null) {
    final entry = dual.entryAtLuma(x, y);
    if (!entry.available || entry.intra) {
      return const H264ColocatedMotion.intra();
    }
    return H264ColocatedMotion.fromDualList(entry.motion);
  }
  final single = picture.motion;
  // The bounded P path predates the dual-list grid and intentionally retains
  // its normative List0 motion in MotionFieldGrid. Promote that entry only for
  // the B Direct colocated lookup; current B motion remains authoritative in
  // the dual grid and is never collapsed into this representation.
  if (single == null) return const H264ColocatedMotion.intra();
  final entry = single.entryAtLuma(x, y);
  if (!entry.available || entry.referenceIndex < 0) {
    return const H264ColocatedMotion.intra();
  }
  return H264ColocatedMotion.inter(
    referenceIndex: entry.referenceIndex,
    vector: entry.vector,
  );
}

H264TemporalDirectContext _buildTemporalDirectContext({
  required List<_DecodedPicture> referencesL0,
  required List<_DecodedPicture> referencesL1,
  required int currentPoc,
}) {
  if (referencesL0.isEmpty || referencesL1.isEmpty) {
    throw const FormatException(
      'Temporal Direct requires non-empty current List0 and List1',
    );
  }
  int requirePoc(_DecodedPicture picture, String listName) {
    final poc = picture.pictureOrderCount;
    if (poc == null) {
      throw FormatException(
        'Temporal Direct $listName picture ${picture.pictureId} has no POC',
      );
    }
    return poc;
  }

  return deriveTemporalDirectContext(
    referencePictureIdsL0: <int>[
      for (final reference in referencesL0) reference.pictureId,
    ],
    referencePictureOrderCountsL0: <int>[
      for (final reference in referencesL0) requirePoc(reference, 'List0'),
    ],
    currentPictureOrderCount: currentPoc,
    list1Reference0PictureOrderCount: requirePoc(referencesL1[0], 'List1[0]'),
  );
}

H264TemporalColocatedMotion _temporalColocatedMotionAt(
  _DecodedPicture picture,
  int x,
  int y,
) {
  final dual = picture.dualMotion;
  if (dual != null) {
    final entry = dual.entryAtLuma(x, y);
    if (!entry.available || entry.intra || entry.motion == null) {
      return const H264TemporalColocatedMotion.intra();
    }
    final list0 = entry.motion!.list0;
    final selected = list0 ?? entry.motion!.list1;
    if (selected == null) {
      return const H264TemporalColocatedMotion.intra();
    }
    final identities = list0 != null
        ? picture.referencePictureIdsL0BySlice[entry.sliceId]
        : picture.referencePictureIdsL1BySlice[entry.sliceId];
    if (identities == null || selected.referenceIndex >= identities.length) {
      throw FormatException(
        'Temporal Direct co-located slice ${entry.sliceId} has no stable '
        'reference identity for index ${selected.referenceIndex}',
      );
    }
    return H264TemporalColocatedMotion.inter(
      referencePictureId: identities[selected.referenceIndex],
      vector: selected.vector,
    );
  }

  final single = picture.motion;
  if (single == null) return const H264TemporalColocatedMotion.intra();
  final entry = single.entryAtLuma(x, y);
  if (!entry.available || entry.referenceIndex < 0) {
    return const H264TemporalColocatedMotion.intra();
  }
  final identities = picture.referencePictureIdsL0BySlice[entry.sliceId];
  if (identities == null || entry.referenceIndex >= identities.length) {
    throw FormatException(
      'Temporal Direct co-located slice ${entry.sliceId} has no stable '
      'List0 identity for index ${entry.referenceIndex}',
    );
  }
  return H264TemporalColocatedMotion.inter(
    referencePictureId: identities[entry.referenceIndex],
    vector: entry.vector,
  );
}

Yuv420PictureBuffer _emptyPictureLike(Yuv420PictureBuffer picture) =>
    Yuv420PictureBuffer(
      width: picture.width,
      height: picture.height,
      y: Uint8List(picture.lumaStride * picture.height),
      u: Uint8List(picture.chromaStride * (picture.height >> 1)),
      v: Uint8List(picture.chromaStride * (picture.height >> 1)),
      lumaStride: picture.lumaStride,
      chromaStride: picture.chromaStride,
    );

void _applyImplicitWeightedBiPrediction420({
  required Yuv420PictureBuffer list0,
  required Yuv420PictureBuffer list1,
  required Yuv420PictureBuffer destination,
  required int x,
  required int y,
  required int width,
  required int height,
  required H264ImplicitBiWeights weights,
}) {
  _applyImplicitWeightedBiPlane8(
    list0: list0.y,
    list1: list1.y,
    destination: destination.y,
    stride: destination.lumaStride,
    x: x,
    y: y,
    width: width,
    height: height,
    weights: weights,
  );

  final chromaX = x >> 1;
  final chromaY = y >> 1;
  final chromaWidth = width >> 1;
  final chromaHeight = height >> 1;
  for (var component = 0; component < 2; component++) {
    final sourceL0 = component == 0 ? list0.u : list0.v;
    final sourceL1 = component == 0 ? list1.u : list1.v;
    final output = component == 0 ? destination.u : destination.v;
    _applyImplicitWeightedBiPlane8(
      list0: sourceL0,
      list1: sourceL1,
      destination: output,
      stride: destination.chromaStride,
      x: chromaX,
      y: chromaY,
      width: chromaWidth,
      height: chromaHeight,
      weights: weights,
    );
  }
}

void _applyImplicitWeightedBiPlane8({
  required Uint8List list0,
  required Uint8List list1,
  required Uint8List destination,
  required int stride,
  required int x,
  required int y,
  required int width,
  required int height,
  required H264ImplicitBiWeights weights,
}) {
  final list0Weight = weights.list0Weight;
  final list1Weight = weights.list1Weight;
  for (var row = 0; row < height; row++) {
    final offset = (y + row) * stride + x;
    final end = offset + width;
    for (var index = offset; index < end; index++) {
      destination[index] = _clipWeightedSample8(
        (list0Weight * list0[index] + list1Weight * list1[index] + 32) >> 6,
      );
    }
  }
}

void _markCabacBSkipMacroblock({
  required _FrameState state,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
  required int qpY,
}) {
  final meta = state.macroblocks[mbAddr];
  meta
    ..decoded = true
    ..isIntra = false
    ..isIntra16x16 = false
    ..usesIntra4x4 = false
    ..usesIntra8x8 = false
    ..transformSize8x8 = false
    ..skipped = true
    ..direct = true
    ..sliceId = sliceId
    ..qpY = qpY
    ..qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset)
    ..qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset)
    ..codedBlockPatternLuma = 0
    ..codedBlockPatternChroma = 0
    ..intraChromaPredictionMode = 0
    ..lumaDcTotalCoeff = 0
    ..lumaDcCoded = false
    ..cbDcCoded = false
    ..crDcCoded = false
    ..lumaCodedMask = 0
    ..cbCodedMask = 0
    ..crCodedMask = 0;
  meta.lumaTotalCoeff.fillRange(0, 16, 0);
  meta.cbTotalCoeff.fillRange(0, 4, 0);
  meta.crTotalCoeff.fillRange(0, 4, 0);
  meta.lumaReconstructed.fillRange(0, 16, true);
}

CabacMacroblockNeighbors _cabacMacroblockNeighbors(
  _FrameState state, {
  required int mbAddr,
  required int sliceId,
}) {
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  return CabacMacroblockNeighbors(
    left: _cabacMacroblockNeighbor(
      _cabacAdjacentMacroblock(state, mbX: mbX - 1, mbY: mbY, sliceId: sliceId),
    ),
    top: _cabacMacroblockNeighbor(
      _cabacAdjacentMacroblock(state, mbX: mbX, mbY: mbY - 1, sliceId: sliceId),
    ),
  );
}

_MacroblockMeta? _cabacAdjacentMacroblock(
  _FrameState state, {
  required int mbX,
  required int mbY,
  required int sliceId,
}) {
  if (mbX < 0 || mbY < 0 || mbX >= state.mbWidth || mbY >= state.mbHeight) {
    return null;
  }
  final meta = state.metaAt(mbX, mbY);
  return meta.decoded && meta.sliceId == sliceId ? meta : null;
}

CabacMacroblockNeighbor _cabacMacroblockNeighbor(_MacroblockMeta? meta) {
  if (meta == null) return const CabacMacroblockNeighbor.unavailable();
  return CabacMacroblockNeighbor(
    skipped: meta.skipped,
    direct: meta.direct,
    intra16x16: meta.isIntra16x16,
    codedBlockPatternLuma: meta.codedBlockPatternLuma,
    codedBlockPatternChroma: meta.codedBlockPatternChroma,
    intraChromaPredictionMode: meta.intraChromaPredictionMode,
    transformSize8x8: meta.transformSize8x8,
  );
}

({List<List<int>> luma8x8, List<List<int>> cb, List<List<int>> cr})
_decodeCabac8x8Residual({
  required H264CabacSliceDataDecoder syntax,
  required _FrameState state,
  required int mbAddr,
  required int sliceId,
  required int codedBlockPatternLuma,
  required int codedBlockPatternChroma,
  required bool currentMacroblockIntra,
}) {
  final meta = state.macroblocks[mbAddr];
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final leftMeta = _cabacAdjacentMacroblock(
    state,
    mbX: mbX - 1,
    mbY: mbY,
    sliceId: sliceId,
  );
  final topMeta = _cabacAdjacentMacroblock(
    state,
    mbX: mbX,
    mbY: mbY - 1,
    sliceId: sliceId,
  );
  final luma8x8 = List<List<int>>.generate(4, (_) => List<int>.filled(64, 0));
  final cb = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
  final cr = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
  meta
    ..lumaDcTotalCoeff = 0
    ..lumaDcCoded = false
    ..lumaCodedMask = 0;

  for (var group = 0; group < 4; group++) {
    final groupX = group & 1;
    final groupY = group >> 1;
    if ((codedBlockPatternLuma & (1 << group)) == 0) {
      for (var local = 0; local < 4; local++) {
        final raster =
            (groupY * 2 + (local >> 1)) * 4 + groupX * 2 + (local & 1);
        meta.lumaTotalCoeff[raster] = 0;
      }
      continue;
    }
    final block = syntax.decodeResidualBlock(
      category: CabacResidualCategory.luma8x8,
      currentMacroblockIntra: currentMacroblockIntra,
      codedBlockFlagPresent: false,
    );
    final rasterCoefficients = inverseScan8x8(block.coefficients);
    luma8x8[group] = rasterCoefficients;
    // A coded transform-8x8 block is residual-bearing for each constituent
    // 4x4 block during deblocking. Coefficient location within the 8x8 does
    // not suppress boundary strength in the other quadrants.
    final deblockingTotal = block.coded ? block.totalCoefficients : 0;
    for (var local = 0; local < 4; local++) {
      final raster = (groupY * 2 + (local >> 1)) * 4 + groupX * 2 + (local & 1);
      meta.lumaTotalCoeff[raster] = deblockingTotal;
      if (deblockingTotal != 0) meta.lumaCodedMask |= 1 << raster;
    }
  }

  if (codedBlockPatternChroma == 0) {
    meta
      ..cbDcCoded = false
      ..crDcCoded = false
      ..cbCodedMask = 0
      ..crCodedMask = 0;
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
    return (luma8x8: luma8x8, cb: cb, cr: cr);
  }

  final cbDc = syntax.decodeResidualBlock(
    category: CabacResidualCategory.chromaDc420,
    currentMacroblockIntra: currentMacroblockIntra,
    left: _cabacChromaDcNeighbor(leftMeta, isCb: true),
    top: _cabacChromaDcNeighbor(topMeta, isCb: true),
  );
  final crDc = syntax.decodeResidualBlock(
    category: CabacResidualCategory.chromaDc420,
    currentMacroblockIntra: currentMacroblockIntra,
    left: _cabacChromaDcNeighbor(leftMeta, isCb: false),
    top: _cabacChromaDcNeighbor(topMeta, isCb: false),
  );
  meta
    ..cbDcCoded = cbDc.coded
    ..crDcCoded = crDc.coded;
  for (var scanPosition = 0; scanPosition < 4; scanPosition++) {
    final raster = scan2x2[scanPosition];
    cb[raster][0] = cbDc.coefficients[scanPosition];
    cr[raster][0] = crDc.coefficients[scanPosition];
  }
  if (codedBlockPatternChroma == 2) {
    _decodeCabacChromaAcPlane(
      syntax: syntax,
      current: meta,
      left: leftMeta,
      top: topMeta,
      destination: cb,
      isCb: true,
      currentMacroblockIntra: currentMacroblockIntra,
    );
    _decodeCabacChromaAcPlane(
      syntax: syntax,
      current: meta,
      left: leftMeta,
      top: topMeta,
      destination: cr,
      isCb: false,
      currentMacroblockIntra: currentMacroblockIntra,
    );
  } else {
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
    meta
      ..cbCodedMask = 0
      ..crCodedMask = 0;
  }
  return (luma8x8: luma8x8, cb: cb, cr: cr);
}

_ResidualData _decodeCabac4x4Residual({
  required H264CabacSliceDataDecoder syntax,
  required _FrameState state,
  required int mbAddr,
  required int sliceId,
  required int codedBlockPatternLuma,
  required int codedBlockPatternChroma,
  required bool currentMacroblockIntra,
}) {
  final meta = state.macroblocks[mbAddr];
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final leftMeta = _cabacAdjacentMacroblock(
    state,
    mbX: mbX - 1,
    mbY: mbY,
    sliceId: sliceId,
  );
  final topMeta = _cabacAdjacentMacroblock(
    state,
    mbX: mbX,
    mbY: mbY - 1,
    sliceId: sliceId,
  );
  final luma = List<List<int>>.generate(16, (_) => List<int>.filled(16, 0));
  final cb = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
  final cr = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
  meta
    ..lumaDcTotalCoeff = 0
    ..lumaDcCoded = false
    ..lumaCodedMask = 0;

  for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
    final bx = _lumaBlockX[syntaxBlock];
    final by = _lumaBlockY[syntaxBlock];
    final raster = by * 4 + bx;
    final group = syntaxBlock >> 2;
    if ((codedBlockPatternLuma & (1 << group)) == 0) {
      meta.lumaTotalCoeff[raster] = 0;
      continue;
    }
    final block = syntax.decodeResidualBlock(
      category: CabacResidualCategory.luma4x4,
      currentMacroblockIntra: currentMacroblockIntra,
      left: bx > 0
          ? _cabacLuma4x4Neighbor(meta, bx - 1, by)
          : _cabacLuma4x4Neighbor(leftMeta, 3, by),
      top: by > 0
          ? _cabacLuma4x4Neighbor(meta, bx, by - 1)
          : _cabacLuma4x4Neighbor(topMeta, bx, 3),
    );
    meta.lumaTotalCoeff[raster] = block.totalCoefficients;
    if (block.coded) meta.lumaCodedMask |= 1 << raster;
    for (var scanPosition = 0; scanPosition < 16; scanPosition++) {
      luma[raster][zigzag4x4[scanPosition]] = block.coefficients[scanPosition];
    }
  }

  if (codedBlockPatternChroma == 0) {
    meta
      ..cbDcCoded = false
      ..crDcCoded = false
      ..cbCodedMask = 0
      ..crCodedMask = 0;
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
    return (luma: luma, cb: cb, cr: cr);
  }

  final cbDc = syntax.decodeResidualBlock(
    category: CabacResidualCategory.chromaDc420,
    currentMacroblockIntra: currentMacroblockIntra,
    left: _cabacChromaDcNeighbor(leftMeta, isCb: true),
    top: _cabacChromaDcNeighbor(topMeta, isCb: true),
  );
  final crDc = syntax.decodeResidualBlock(
    category: CabacResidualCategory.chromaDc420,
    currentMacroblockIntra: currentMacroblockIntra,
    left: _cabacChromaDcNeighbor(leftMeta, isCb: false),
    top: _cabacChromaDcNeighbor(topMeta, isCb: false),
  );
  meta
    ..cbDcCoded = cbDc.coded
    ..crDcCoded = crDc.coded;
  for (var scanPosition = 0; scanPosition < 4; scanPosition++) {
    final raster = scan2x2[scanPosition];
    cb[raster][0] = cbDc.coefficients[scanPosition];
    cr[raster][0] = crDc.coefficients[scanPosition];
  }
  if (codedBlockPatternChroma == 2) {
    _decodeCabacChromaAcPlane(
      syntax: syntax,
      current: meta,
      left: leftMeta,
      top: topMeta,
      destination: cb,
      isCb: true,
      currentMacroblockIntra: currentMacroblockIntra,
    );
    _decodeCabacChromaAcPlane(
      syntax: syntax,
      current: meta,
      left: leftMeta,
      top: topMeta,
      destination: cr,
      isCb: false,
      currentMacroblockIntra: currentMacroblockIntra,
    );
  } else {
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
    meta
      ..cbCodedMask = 0
      ..crCodedMask = 0;
  }
  return (luma: luma, cb: cb, cr: cr);
}

_ResidualData _decodeCabacIntra16Residual({
  required H264CabacSliceDataDecoder syntax,
  required _FrameState state,
  required int mbAddr,
  required int sliceId,
  required int codedBlockPatternLuma,
  required int codedBlockPatternChroma,
}) {
  final meta = state.macroblocks[mbAddr];
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final leftMeta = _cabacAdjacentMacroblock(
    state,
    mbX: mbX - 1,
    mbY: mbY,
    sliceId: sliceId,
  );
  final topMeta = _cabacAdjacentMacroblock(
    state,
    mbX: mbX,
    mbY: mbY - 1,
    sliceId: sliceId,
  );
  final luma = List<List<int>>.generate(16, (_) => List<int>.filled(16, 0));
  final cb = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
  final cr = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));

  final lumaDc = syntax.decodeResidualBlock(
    category: CabacResidualCategory.lumaDc16x16,
    currentMacroblockIntra: true,
    left: _cabacLumaDcNeighbor(leftMeta),
    top: _cabacLumaDcNeighbor(topMeta),
  );
  meta
    ..lumaDcCoded = lumaDc.coded
    ..lumaDcTotalCoeff = lumaDc.totalCoefficients;
  for (var scanPosition = 0; scanPosition < 16; scanPosition++) {
    luma[zigzag4x4[scanPosition]][0] = lumaDc.coefficients[scanPosition];
  }

  for (var syntaxBlock = 0; syntaxBlock < 16; syntaxBlock++) {
    final bx = _lumaBlockX[syntaxBlock];
    final by = _lumaBlockY[syntaxBlock];
    final raster = by * 4 + bx;
    final group = syntaxBlock >> 2;
    if ((codedBlockPatternLuma & (1 << group)) == 0) {
      meta.lumaTotalCoeff[raster] = 0;
      meta.lumaCodedMask &= ~(1 << raster);
      continue;
    }

    final block = syntax.decodeResidualBlock(
      category: CabacResidualCategory.lumaAc16x16,
      currentMacroblockIntra: true,
      left: bx > 0
          ? _cabacLumaAcNeighbor(meta, bx - 1, by)
          : _cabacLumaAcNeighbor(leftMeta, 3, by),
      top: by > 0
          ? _cabacLumaAcNeighbor(meta, bx, by - 1)
          : _cabacLumaAcNeighbor(topMeta, bx, 3),
    );
    meta.lumaTotalCoeff[raster] = block.totalCoefficients;
    if (block.coded) {
      meta.lumaCodedMask |= 1 << raster;
    } else {
      meta.lumaCodedMask &= ~(1 << raster);
    }
    for (var acPosition = 0; acPosition < 15; acPosition++) {
      final coefficientRaster = zigzag4x4[acPosition + 1];
      luma[raster][coefficientRaster] = block.coefficients[acPosition];
    }
  }

  if (codedBlockPatternChroma == 0) {
    meta
      ..cbDcCoded = false
      ..crDcCoded = false;
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
    meta
      ..cbCodedMask = 0
      ..crCodedMask = 0;
    return (luma: luma, cb: cb, cr: cr);
  }

  final cbDc = syntax.decodeResidualBlock(
    category: CabacResidualCategory.chromaDc420,
    currentMacroblockIntra: true,
    left: _cabacChromaDcNeighbor(leftMeta, isCb: true),
    top: _cabacChromaDcNeighbor(topMeta, isCb: true),
  );
  final crDc = syntax.decodeResidualBlock(
    category: CabacResidualCategory.chromaDc420,
    currentMacroblockIntra: true,
    left: _cabacChromaDcNeighbor(leftMeta, isCb: false),
    top: _cabacChromaDcNeighbor(topMeta, isCb: false),
  );
  meta
    ..cbDcCoded = cbDc.coded
    ..crDcCoded = crDc.coded;
  for (var scanPosition = 0; scanPosition < 4; scanPosition++) {
    final raster = scan2x2[scanPosition];
    cb[raster][0] = cbDc.coefficients[scanPosition];
    cr[raster][0] = crDc.coefficients[scanPosition];
  }

  if (codedBlockPatternChroma != 2) {
    meta.cbTotalCoeff.fillRange(0, 4, 0);
    meta.crTotalCoeff.fillRange(0, 4, 0);
    meta
      ..cbCodedMask = 0
      ..crCodedMask = 0;
    return (luma: luma, cb: cb, cr: cr);
  }

  _decodeCabacChromaAcPlane(
    syntax: syntax,
    current: meta,
    left: leftMeta,
    top: topMeta,
    destination: cb,
    isCb: true,
    currentMacroblockIntra: true,
  );
  _decodeCabacChromaAcPlane(
    syntax: syntax,
    current: meta,
    left: leftMeta,
    top: topMeta,
    destination: cr,
    isCb: false,
    currentMacroblockIntra: true,
  );
  return (luma: luma, cb: cb, cr: cr);
}

void _decodeCabacChromaAcPlane({
  required H264CabacSliceDataDecoder syntax,
  required _MacroblockMeta current,
  required _MacroblockMeta? left,
  required _MacroblockMeta? top,
  required List<List<int>> destination,
  required bool isCb,
  required bool currentMacroblockIntra,
}) {
  final totals = isCb ? current.cbTotalCoeff : current.crTotalCoeff;
  for (var block = 0; block < 4; block++) {
    final bx = block & 1;
    final by = block >> 1;
    final residual = syntax.decodeResidualBlock(
      category: CabacResidualCategory.chromaAc420,
      currentMacroblockIntra: currentMacroblockIntra,
      left: bx > 0
          ? _cabacChromaAcNeighbor(current, block - 1, isCb: isCb)
          : _cabacChromaAcNeighbor(left, by * 2 + 1, isCb: isCb),
      top: by > 0
          ? _cabacChromaAcNeighbor(current, block - 2, isCb: isCb)
          : _cabacChromaAcNeighbor(top, block + 2, isCb: isCb),
    );
    if (isCb) {
      if (residual.coded) {
        current.cbCodedMask |= 1 << block;
      } else {
        current.cbCodedMask &= ~(1 << block);
      }
    } else if (residual.coded) {
      current.crCodedMask |= 1 << block;
    } else {
      current.crCodedMask &= ~(1 << block);
    }
    totals[block] = residual.totalCoefficients;
    for (var acPosition = 0; acPosition < 15; acPosition++) {
      destination[block][zigzag4x4[acPosition + 1]] =
          residual.coefficients[acPosition];
    }
  }
}

CabacCodedBlockNeighbor _cabacLumaDcNeighbor(_MacroblockMeta? meta) {
  if (meta == null) return const CabacCodedBlockNeighbor.unavailable();
  if (!meta.isIntra16x16) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  return CabacCodedBlockNeighbor(coded: meta.lumaDcCoded);
}

CabacCodedBlockNeighbor _cabacLumaAcNeighbor(
  _MacroblockMeta? meta,
  int bx,
  int by,
) {
  return deriveCabacLumaCodedBlockNeighbor(
    macroblockAvailable: meta != null,
    transformSize8x8: meta?.transformSize8x8 ?? false,
    codedBlockPatternLuma: meta?.codedBlockPatternLuma ?? 0,
    lumaCodedMask: meta?.lumaCodedMask ?? 0,
    blockX: bx,
    blockY: by,
  );
}

CabacCodedBlockNeighbor _cabacLuma4x4Neighbor(
  _MacroblockMeta? meta,
  int bx,
  int by,
) {
  return deriveCabacLumaCodedBlockNeighbor(
    macroblockAvailable: meta != null,
    transformSize8x8: meta?.transformSize8x8 ?? false,
    codedBlockPatternLuma: meta?.codedBlockPatternLuma ?? 0,
    lumaCodedMask: meta?.lumaCodedMask ?? 0,
    blockX: bx,
    blockY: by,
  );
}

CabacCodedBlockNeighbor _cabacChromaDcNeighbor(
  _MacroblockMeta? meta, {
  required bool isCb,
}) {
  if (meta == null) return const CabacCodedBlockNeighbor.unavailable();
  if (meta.codedBlockPatternChroma == 0) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  return CabacCodedBlockNeighbor(coded: isCb ? meta.cbDcCoded : meta.crDcCoded);
}

CabacCodedBlockNeighbor _cabacChromaAcNeighbor(
  _MacroblockMeta? meta,
  int block, {
  required bool isCb,
}) {
  if (meta == null) return const CabacCodedBlockNeighbor.unavailable();
  if (meta.codedBlockPatternChroma != 2) {
    return const CabacCodedBlockNeighbor.blockUnavailable();
  }
  return CabacCodedBlockNeighbor(
    coded: ((isCb ? meta.cbCodedMask : meta.crCodedMask) & (1 << block)) != 0,
  );
}

void _decodeSkippedMacroblock({
  required _FrameState state,
  required _DecodedPicture reference,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
  required int qpY,
  PredictionWeightTable? predictionWeights,
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
  if (predictionWeights != null) {
    _applyExplicitWeightedPrediction420(
      picture: state.picture,
      x: x,
      y: y,
      width: 16,
      height: 16,
      table: predictionWeights,
      referenceIndex: 0,
    );
  }
  state.motion.setPartition(
    x: x,
    y: y,
    width: 16,
    height: 16,
    vector: vector,
    referenceIndex: 0,
    sliceId: sliceId,
  );
  state.setCabacMvdPartition(
    x: x,
    y: y,
    width: 16,
    height: 16,
    mvd: const CabacMotionVectorDifference(horizontal: 0, vertical: 0),
  );

  final meta = state.macroblocks[mbAddr];
  meta
    ..decoded = true
    ..isIntra = false
    ..isIntra16x16 = false
    ..skipped = true
    ..direct = false
    ..sliceId = sliceId
    ..qpY = qpY
    ..qpCb = _chromaQp(qpY, header.pps.chromaQpIndexOffset)
    ..qpCr = _chromaQp(qpY, header.pps.secondChromaQpIndexOffset)
    ..codedBlockPatternLuma = 0
    ..codedBlockPatternChroma = 0
    ..intraChromaPredictionMode = 0
    ..lumaDcTotalCoeff = 0
    ..lumaDcCoded = false
    ..cbDcCoded = false
    ..crDcCoded = false
    ..lumaCodedMask = 0
    ..cbCodedMask = 0
    ..crCodedMask = 0;
  meta.lumaTotalCoeff.fillRange(0, 16, 0);
  meta.cbTotalCoeff.fillRange(0, 4, 0);
  meta.crTotalCoeff.fillRange(0, 4, 0);
  meta.lumaReconstructed.fillRange(0, 16, true);
}

void _applyExplicitWeightedPrediction420({
  required Yuv420PictureBuffer picture,
  required int x,
  required int y,
  required int width,
  required int height,
  required PredictionWeightTable table,
  required int referenceIndex,
}) {
  if (referenceIndex < 0 || referenceIndex >= table.list0.length) {
    throw RangeError.index(referenceIndex, table.list0, 'referenceIndex');
  }
  final weight = table.list0[referenceIndex];

  _applyExplicitWeightedPlane8(
    plane: picture.y,
    stride: picture.lumaStride,
    x: x,
    y: y,
    width: width,
    height: height,
    log2WeightDenom: table.lumaLog2WeightDenom,
    weight: weight.lumaWeight,
    offset: weight.lumaOffset,
  );

  final chromaX = x >> 1;
  final chromaY = y >> 1;
  final chromaWidth = width >> 1;
  final chromaHeight = height >> 1;
  if (weight.chromaWeights.length != 2 || weight.chromaOffsets.length != 2) {
    throw const FormatException(
      'Explicit 4:2:0 prediction requires two chroma weights and offsets',
    );
  }
  for (var component = 0; component < 2; component++) {
    final plane = component == 0 ? picture.u : picture.v;
    _applyExplicitWeightedPlane8(
      plane: plane,
      stride: picture.chromaStride,
      x: chromaX,
      y: chromaY,
      width: chromaWidth,
      height: chromaHeight,
      log2WeightDenom: table.chromaLog2WeightDenom,
      weight: weight.chromaWeights[component],
      offset: weight.chromaOffsets[component],
    );
  }
}

void _applyExplicitWeightedPlane8({
  required Uint8List plane,
  required int stride,
  required int x,
  required int y,
  required int width,
  required int height,
  required int log2WeightDenom,
  required int weight,
  required int offset,
}) {
  // Keep the public sample helper's fail-closed validation, but perform it
  // once per prediction region instead of once per pixel. Plane samples are
  // intrinsically 0..255 because their storage is Uint8List.
  explicitWeightedUniSample8(
    sample: 0,
    log2WeightDenom: log2WeightDenom,
    weight: weight,
    offset: offset,
  );
  if (log2WeightDenom == 0) {
    for (var row = 0; row < height; row++) {
      final start = (y + row) * stride + x;
      final end = start + width;
      for (var index = start; index < end; index++) {
        plane[index] = _clipWeightedSample8(weight * plane[index] + offset);
      }
    }
    return;
  }

  final rounding = 1 << (log2WeightDenom - 1);
  for (var row = 0; row < height; row++) {
    final start = (y + row) * stride + x;
    final end = start + width;
    for (var index = start; index < end; index++) {
      plane[index] = _clipWeightedSample8(
        ((weight * plane[index] + rounding) >> log2WeightDenom) + offset,
      );
    }
  }
}

int _clipWeightedSample8(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return value;
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
  final int mode;
  if (meta.usesIntra4x4) {
    mode = state.intra4x4Modes[mbAddr * 16 + raster];
  } else if (meta.usesIntra8x8) {
    final block = intra8x8BlockIndexForIntra4x4Neighbour(
      blockX: globalBlockX & 3,
      blockY: globalBlockY & 3,
    );
    mode = state.intra8x8Modes[mbAddr * 4 + block];
  } else {
    // Intra16x16 and inter neighbours have no 4x4/8x8 mode, so clause
    // 8.3.1.1 substitutes DC while retaining sample availability.
    mode = 2;
  }
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

void _reconstructIntra8x8({
  required _FrameState state,
  required SliceHeader header,
  required int mbAddr,
  required int sliceId,
  required int qpY,
  required List<List<int>> lumaCoefficients,
}) {
  if (lumaCoefficients.length != 4 ||
      lumaCoefficients.any((block) => block.length != 64)) {
    throw const FormatException(
      'Intra_8x8 reconstruction requires four 64-coefficient blocks',
    );
  }
  final mbX = mbAddr % state.mbWidth;
  final mbY = mbAddr ~/ state.mbWidth;
  final constrained = header.pps.constrainedIntraPredFlag;
  final meta = state.macroblocks[mbAddr];
  for (var block = 0; block < 4; block++) {
    final bx = block & 1;
    final by = block >> 1;
    final base4X = mbX * 4 + bx * 2;
    final base4Y = mbY * 4 + by * 2;
    bool available(int x, int y) => state.lumaBlockAvailable(
      x,
      y,
      currentMbAddr: mbAddr,
      sliceId: sliceId,
      constrainedIntra: constrained,
    );

    final topAvailable =
        available(base4X, base4Y - 1) && available(base4X + 1, base4Y - 1);
    final topRightAvailable =
        available(base4X + 2, base4Y - 1) && available(base4X + 3, base4Y - 1);
    final leftAvailable =
        available(base4X - 1, base4Y) && available(base4X - 1, base4Y + 1);
    final topLeftAvailable = available(base4X - 1, base4Y - 1);
    final sampleX = base4X * 4;
    final sampleY = base4Y * 4;
    final top = List<int>.filled(16, 128);
    if (topAvailable) {
      final row = (sampleY - 1) * state.picture.lumaStride;
      for (var index = 0; index < 8; index++) {
        top[index] = state.picture.y[row + sampleX + index];
      }
      if (topRightAvailable) {
        for (var index = 8; index < 16; index++) {
          top[index] = state.picture.y[row + sampleX + index];
        }
      }
    }
    final left = List<int>.filled(8, 128);
    if (leftAvailable) {
      for (var index = 0; index < 8; index++) {
        left[index] = state
            .picture
            .y[(sampleY + index) * state.picture.lumaStride + sampleX - 1];
      }
    }
    final topLeft = topLeftAvailable
        ? state.picture.y[(sampleY - 1) * state.picture.lumaStride +
              sampleX -
              1]
        : 128;
    final prediction = List<int>.filled(64, 128);
    predictIntra8x8(
      mode: state.intra8x8Modes[mbAddr * 4 + block],
      top: top,
      left: left,
      topLeft: topLeft,
      out: prediction,
      topAvailable: topAvailable,
      leftAvailable: leftAvailable,
      topLeftAvailable: topLeftAvailable,
      topRightAvailable: topRightAvailable,
    );
    _write8x8PredictionAndResidual(
      plane: state.picture.y,
      stride: state.picture.lumaStride,
      x: sampleX,
      y: sampleY,
      prediction: prediction,
      residual: invTransform8x8(lumaCoefficients[block], qp: qpY),
    );
    for (var localY = 0; localY < 2; localY++) {
      for (var localX = 0; localX < 2; localX++) {
        meta.lumaReconstructed[(by * 2 + localY) * 4 + bx * 2 + localX] = true;
      }
    }
  }
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

void _write8x8PredictionAndResidual({
  required Uint8List plane,
  required int stride,
  required int x,
  required int y,
  required List<int> prediction,
  required List<int> residual,
}) {
  for (var row = 0; row < 8; row++) {
    final offset = (y + row) * stride + x;
    for (var column = 0; column < 8; column++) {
      final index = row * 8 + column;
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

void _add8x8Residual({
  required Uint8List plane,
  required int stride,
  required int x,
  required int y,
  required List<int> residual,
}) {
  if (residual.length != 64) {
    throw ArgumentError.value(
      residual.length,
      'residual.length',
      'Expected 64',
    );
  }
  for (var row = 0; row < 8; row++) {
    final offset = (y + row) * stride + x;
    for (var column = 0; column < 8; column++) {
      final index = row * 8 + column;
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
  if (left == 0 &&
      top == 0 &&
      width == picture.width &&
      height == picture.height &&
      picture.lumaStride == width &&
      picture.chromaStride == (width >> 1)) {
    // The reconstructed picture is immutable after this point. Returning its
    // tightly packed planes avoids another full-frame allocation/copy for the
    // common uncropped 720p path while preserving the coded buffer in the DPB.
    return Yuv420Frame(
      width: width,
      height: height,
      y: picture.y,
      u: picture.u,
      v: picture.v,
    );
  }
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
