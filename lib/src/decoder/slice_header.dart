import 'dart:typed_data';

import 'bitreader.dart';
import 'exp_golomb.dart';
import 'pps.dart';
import 'rbsp.dart';
import 'sps.dart';

enum H264SliceType {
  p,
  b,
  i,
  sp,
  si;

  static H264SliceType fromCode(int code) {
    if (code < 0 || code > 9) {
      throw FormatException('Invalid slice_type=$code');
    }
    return H264SliceType.values[code % 5];
  }

  bool get isIntra => this == H264SliceType.i || this == H264SliceType.si;
}

class RefPicListModification {
  final int idc;
  final int value;

  const RefPicListModification(this.idc, this.value);
}

class MemoryManagementOperation {
  final int operation;
  final int? differenceOfPicNumsMinus1;
  final int? longTermPicNum;
  final int? longTermFrameIdx;
  final int? maxLongTermFrameIdxPlus1;

  const MemoryManagementOperation({
    required this.operation,
    this.differenceOfPicNumsMinus1,
    this.longTermPicNum,
    this.longTermFrameIdx,
    this.maxLongTermFrameIdxPlus1,
  });
}

/// One reference entry from `pred_weight_table()`.
///
/// Missing syntax flags are materialized as the normative identity weights so
/// prediction code does not need to distinguish an omitted value from an
/// explicitly signalled one.
class PredictionWeight {
  final int lumaWeight;
  final int lumaOffset;
  final List<int> chromaWeights;
  final List<int> chromaOffsets;

  const PredictionWeight({
    required this.lumaWeight,
    required this.lumaOffset,
    required this.chromaWeights,
    required this.chromaOffsets,
  });
}

/// Explicit weighted-prediction parameters carried by a P/SP/B slice.
class PredictionWeightTable {
  final int lumaLog2WeightDenom;
  final int chromaLog2WeightDenom;
  final List<PredictionWeight> list0;
  final List<PredictionWeight> list1;

  const PredictionWeightTable({
    required this.lumaLog2WeightDenom,
    required this.chromaLog2WeightDenom,
    required this.list0,
    required this.list1,
  });
}

/// Parsed slice header and a reader positioned at the first slice-data bit.
class SliceHeader {
  final Uint8List nal;
  final BitReader reader;
  final SpsInfo sps;
  final PpsInfo pps;
  final int nalRefIdc;
  final int nalUnitType;
  final int firstMbInSlice;
  final int rawSliceType;
  final H264SliceType sliceType;
  final int picParameterSetId;
  final int frameNum;
  final int? idrPicId;
  final int? picOrderCntLsb;
  final int? deltaPicOrderCntBottom;
  final int? deltaPicOrderCnt0;
  final int? deltaPicOrderCnt1;
  final int? redundantPicCnt;
  final bool directSpatialMvPredFlag;
  final int numRefIdxL0ActiveMinus1;
  final int numRefIdxL1ActiveMinus1;
  final List<RefPicListModification> refPicListModificationsL0;
  final List<RefPicListModification> refPicListModificationsL1;
  final PredictionWeightTable? predictionWeightTable;
  final bool noOutputOfPriorPicsFlag;
  final bool longTermReferenceFlag;
  final bool adaptiveRefPicMarkingModeFlag;
  final List<MemoryManagementOperation> memoryManagementOperations;
  final int? cabacInitIdc;
  final int sliceQpDelta;
  final int sliceQpY;
  final int disableDeblockingFilterIdc;
  final int sliceAlphaC0OffsetDiv2;
  final int sliceBetaOffsetDiv2;
  final int dataBitOffset;

  const SliceHeader({
    required this.nal,
    required this.reader,
    required this.sps,
    required this.pps,
    required this.nalRefIdc,
    required this.nalUnitType,
    required this.firstMbInSlice,
    required this.rawSliceType,
    required this.sliceType,
    required this.picParameterSetId,
    required this.frameNum,
    required this.idrPicId,
    required this.picOrderCntLsb,
    required this.deltaPicOrderCntBottom,
    required this.deltaPicOrderCnt0,
    required this.deltaPicOrderCnt1,
    required this.redundantPicCnt,
    required this.directSpatialMvPredFlag,
    required this.numRefIdxL0ActiveMinus1,
    required this.numRefIdxL1ActiveMinus1,
    required this.refPicListModificationsL0,
    required this.refPicListModificationsL1,
    required this.predictionWeightTable,
    required this.noOutputOfPriorPicsFlag,
    required this.longTermReferenceFlag,
    required this.adaptiveRefPicMarkingModeFlag,
    required this.memoryManagementOperations,
    required this.cabacInitIdc,
    required this.sliceQpDelta,
    required this.sliceQpY,
    required this.disableDeblockingFilterIdc,
    required this.sliceAlphaC0OffsetDiv2,
    required this.sliceBetaOffsetDiv2,
    required this.dataBitOffset,
  });

  bool get isIdr => nalUnitType == 5;
}

SliceHeader parseSliceHeader(
  Uint8List nal, {
  required Map<int, PpsInfo> ppsById,
  required Map<int, SpsInfo> spsById,
}) {
  if (nal.length < 2) {
    throw const FormatException('Truncated VCL NAL');
  }
  if ((nal.first & 0x80) != 0) {
    throw const FormatException('forbidden_zero_bit is set');
  }
  final nalUnitType = nal.first & 0x1f;
  if (nalUnitType != 1 && nalUnitType != 5) {
    throw FormatException('Expected VCL NAL type 1 or 5, got $nalUnitType');
  }

  final nalRefIdc = (nal.first >> 5) & 3;
  final reader = BitReader(ebspToRbsp(Uint8List.sublistView(nal, 1)));
  final firstMbInSlice = readUE(reader);
  final rawSliceType = readUE(reader);
  final sliceType = H264SliceType.fromCode(rawSliceType);
  final picParameterSetId = readUE(reader);
  final pps = ppsById[picParameterSetId];
  if (pps == null) {
    throw FormatException('Slice references missing PPS $picParameterSetId');
  }
  final sps = spsById[pps.spsId];
  if (sps == null) {
    throw FormatException(
      'PPS ${pps.ppsId} references missing SPS ${pps.spsId}',
    );
  }
  if (!sps.frameMbsOnlyFlag) {
    throw const FormatException('Field-coded pictures are not supported');
  }
  if (sps.separateColourPlaneFlag) {
    reader.readBits(2); // colour_plane_id
  }

  final frameNum = reader.readBits(sps.log2MaxFrameNumMinus4 + 4);
  int? idrPicId;
  if (nalUnitType == 5) idrPicId = readUE(reader);

  int? picOrderCntLsb;
  int? deltaPicOrderCntBottom;
  int? deltaPicOrderCnt0;
  int? deltaPicOrderCnt1;
  if (sps.picOrderCntType == 0) {
    picOrderCntLsb = reader.readBits(sps.log2MaxPicOrderCntLsbMinus4 + 4);
    if (pps.bottomFieldPicOrderInFramePresentFlag) {
      deltaPicOrderCntBottom = readSE(reader);
    }
  } else if (sps.picOrderCntType == 1 && !sps.deltaPicOrderAlwaysZeroFlag) {
    deltaPicOrderCnt0 = readSE(reader);
    if (pps.bottomFieldPicOrderInFramePresentFlag) {
      deltaPicOrderCnt1 = readSE(reader);
    }
  }

  int? redundantPicCnt;
  if (pps.redundantPicCntPresentFlag) redundantPicCnt = readUE(reader);
  final directSpatialMvPredFlag =
      sliceType == H264SliceType.b && reader.readBit() == 1;

  var numRefIdxL0ActiveMinus1 = pps.numRefIdxL0DefaultActiveMinus1;
  var numRefIdxL1ActiveMinus1 = pps.numRefIdxL1DefaultActiveMinus1;
  if (sliceType == H264SliceType.p ||
      sliceType == H264SliceType.sp ||
      sliceType == H264SliceType.b) {
    final override = reader.readBit() == 1;
    if (override) {
      numRefIdxL0ActiveMinus1 = readUE(reader);
      if (sliceType == H264SliceType.b) {
        numRefIdxL1ActiveMinus1 = readUE(reader);
      }
    }
  }

  final modificationsL0 = <RefPicListModification>[];
  final modificationsL1 = <RefPicListModification>[];
  if (!sliceType.isIntra) {
    _readRefPicListModifications(reader, modificationsL0);
    if (sliceType == H264SliceType.b) {
      _readRefPicListModifications(reader, modificationsL1);
    }
  }

  PredictionWeightTable? predictionWeightTable;
  if ((pps.weightedPredFlag &&
          (sliceType == H264SliceType.p || sliceType == H264SliceType.sp)) ||
      (pps.weightedBipredIdc == 1 && sliceType == H264SliceType.b)) {
    predictionWeightTable = _readPredWeightTable(
      reader,
      sps: sps,
      l0Count: numRefIdxL0ActiveMinus1 + 1,
      l1Count: sliceType == H264SliceType.b ? numRefIdxL1ActiveMinus1 + 1 : 0,
    );
  }

  var noOutputOfPriorPicsFlag = false;
  var longTermReferenceFlag = false;
  var adaptiveRefPicMarkingModeFlag = false;
  final memoryManagementOperations = <MemoryManagementOperation>[];
  if (nalRefIdc != 0) {
    if (nalUnitType == 5) {
      noOutputOfPriorPicsFlag = reader.readBit() == 1;
      longTermReferenceFlag = reader.readBit() == 1;
    } else {
      adaptiveRefPicMarkingModeFlag = reader.readBit() == 1;
      if (adaptiveRefPicMarkingModeFlag) {
        while (true) {
          final operation = readUE(reader);
          if (operation == 0) break;
          if (operation < 1 || operation > 6) {
            throw FormatException('Invalid MMCO operation $operation');
          }
          int? differenceOfPicNumsMinus1;
          int? longTermPicNum;
          int? longTermFrameIdx;
          int? maxLongTermFrameIdxPlus1;
          if (operation == 1 || operation == 3) {
            differenceOfPicNumsMinus1 = readUE(reader);
          }
          if (operation == 2) longTermPicNum = readUE(reader);
          if (operation == 3 || operation == 6) {
            longTermFrameIdx = readUE(reader);
          }
          if (operation == 4) maxLongTermFrameIdxPlus1 = readUE(reader);
          memoryManagementOperations.add(
            MemoryManagementOperation(
              operation: operation,
              differenceOfPicNumsMinus1: differenceOfPicNumsMinus1,
              longTermPicNum: longTermPicNum,
              longTermFrameIdx: longTermFrameIdx,
              maxLongTermFrameIdxPlus1: maxLongTermFrameIdxPlus1,
            ),
          );
        }
      }
    }
  }

  int? cabacInitIdc;
  if (pps.entropyCodingModeFlag && !sliceType.isIntra) {
    cabacInitIdc = readUE(reader);
    if (cabacInitIdc > 2) {
      throw FormatException('Invalid cabac_init_idc=$cabacInitIdc');
    }
  }
  final sliceQpDelta = readSE(reader);
  final sliceQpY = 26 + pps.picInitQpMinus26 + sliceQpDelta;
  if (sliceQpY < 0 || sliceQpY > 51) {
    throw FormatException('Invalid SliceQPY=$sliceQpY');
  }

  if (sliceType == H264SliceType.sp || sliceType == H264SliceType.si) {
    if (sliceType == H264SliceType.sp) reader.readBit();
    readSE(reader); // slice_qs_delta
  }

  var disableDeblockingFilterIdc = 0;
  var sliceAlphaC0OffsetDiv2 = 0;
  var sliceBetaOffsetDiv2 = 0;
  if (pps.deblockingFilterControlPresentFlag) {
    disableDeblockingFilterIdc = readUE(reader);
    if (disableDeblockingFilterIdc > 2) {
      throw FormatException(
        'Invalid disable_deblocking_filter_idc=$disableDeblockingFilterIdc',
      );
    }
    if (disableDeblockingFilterIdc != 1) {
      sliceAlphaC0OffsetDiv2 = readSE(reader);
      sliceBetaOffsetDiv2 = readSE(reader);
    }
  }

  if (pps.numSliceGroupsMinus1 != 0) {
    throw const FormatException('Flexible macroblock ordering is unsupported');
  }

  return SliceHeader(
    nal: nal,
    reader: reader,
    sps: sps,
    pps: pps,
    nalRefIdc: nalRefIdc,
    nalUnitType: nalUnitType,
    firstMbInSlice: firstMbInSlice,
    rawSliceType: rawSliceType,
    sliceType: sliceType,
    picParameterSetId: picParameterSetId,
    frameNum: frameNum,
    idrPicId: idrPicId,
    picOrderCntLsb: picOrderCntLsb,
    deltaPicOrderCntBottom: deltaPicOrderCntBottom,
    deltaPicOrderCnt0: deltaPicOrderCnt0,
    deltaPicOrderCnt1: deltaPicOrderCnt1,
    redundantPicCnt: redundantPicCnt,
    directSpatialMvPredFlag: directSpatialMvPredFlag,
    numRefIdxL0ActiveMinus1: numRefIdxL0ActiveMinus1,
    numRefIdxL1ActiveMinus1: numRefIdxL1ActiveMinus1,
    refPicListModificationsL0: List<RefPicListModification>.unmodifiable(
      modificationsL0,
    ),
    refPicListModificationsL1: List<RefPicListModification>.unmodifiable(
      modificationsL1,
    ),
    predictionWeightTable: predictionWeightTable,
    noOutputOfPriorPicsFlag: noOutputOfPriorPicsFlag,
    longTermReferenceFlag: longTermReferenceFlag,
    adaptiveRefPicMarkingModeFlag: adaptiveRefPicMarkingModeFlag,
    memoryManagementOperations: List<MemoryManagementOperation>.unmodifiable(
      memoryManagementOperations,
    ),
    cabacInitIdc: cabacInitIdc,
    sliceQpDelta: sliceQpDelta,
    sliceQpY: sliceQpY,
    disableDeblockingFilterIdc: disableDeblockingFilterIdc,
    sliceAlphaC0OffsetDiv2: sliceAlphaC0OffsetDiv2,
    sliceBetaOffsetDiv2: sliceBetaOffsetDiv2,
    dataBitOffset: reader.bitPos,
  );
}

void _readRefPicListModifications(
  BitReader reader,
  List<RefPicListModification> output,
) {
  if (reader.readBit() == 0) return;
  while (true) {
    final idc = readUE(reader);
    if (idc == 3) return;
    if (idc < 0 || idc > 2) {
      throw FormatException('Invalid modification_of_pic_nums_idc=$idc');
    }
    output.add(RefPicListModification(idc, readUE(reader)));
  }
}

PredictionWeightTable _readPredWeightTable(
  BitReader reader, {
  required SpsInfo sps,
  required int l0Count,
  required int l1Count,
}) {
  final lumaLog2WeightDenom = readUE(reader);
  final chromaLog2WeightDenom = sps.chromaFormatIdc == 0 ? 0 : readUE(reader);
  if (lumaLog2WeightDenom > 7 || chromaLog2WeightDenom > 7) {
    throw FormatException(
      'Invalid prediction weight denominators '
      'luma=$lumaLog2WeightDenom chroma=$chromaLog2WeightDenom',
    );
  }

  List<PredictionWeight> readList(int count) {
    final output = <PredictionWeight>[];
    for (var i = 0; i < count; i++) {
      var lumaWeight = 1 << lumaLog2WeightDenom;
      var lumaOffset = 0;
      if (reader.readBit() == 1) {
        lumaWeight = readSE(reader);
        lumaOffset = readSE(reader);
      }
      final chromaWeights = <int>[
        1 << chromaLog2WeightDenom,
        1 << chromaLog2WeightDenom,
      ];
      final chromaOffsets = <int>[0, 0];
      if (sps.chromaFormatIdc != 0 && reader.readBit() == 1) {
        for (var component = 0; component < 2; component++) {
          chromaWeights[component] = readSE(reader);
          chromaOffsets[component] = readSE(reader);
        }
      }
      output.add(
        PredictionWeight(
          lumaWeight: lumaWeight,
          lumaOffset: lumaOffset,
          chromaWeights: List<int>.unmodifiable(chromaWeights),
          chromaOffsets: List<int>.unmodifiable(chromaOffsets),
        ),
      );
    }
    return List<PredictionWeight>.unmodifiable(output);
  }

  return PredictionWeightTable(
    lumaLog2WeightDenom: lumaLog2WeightDenom,
    chromaLog2WeightDenom: chromaLog2WeightDenom,
    list0: readList(l0Count),
    list1: readList(l1Count),
  );
}
