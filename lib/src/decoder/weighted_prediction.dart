import 'slice_header.dart';

/// Colour component whose explicit prediction weights are being selected.
enum H264PredictionComponent { luma, cb, cr }

/// Reference picture list containing an explicit prediction-weight entry.
enum H264ReferenceList { list0, list1 }

/// The two POC-derived weights used by implicit B-slice bi-prediction.
///
/// The weights always sum to 64. Equal fallback prediction is represented by
/// 32 for each list.
final class H264ImplicitBiWeights {
  const H264ImplicitBiWeights._({
    required this.list0Weight,
    required this.list1Weight,
  });

  final int list0Weight;
  final int list1Weight;

  bool get usesEqualWeights => list0Weight == 32 && list1Weight == 32;

  @override
  String toString() =>
      'H264ImplicitBiWeights(list0: $list0Weight, list1: $list1Weight)';
}

/// Applies H.264 explicit weighted prediction to one 8-bit sample.
///
/// This is the one-reference branch of section 8.4.2.3.2. It is shared by
/// luma, Cb, and Cr; callers select the corresponding denominator, weight, and
/// offset. The inferred identity weight `1 << log2WeightDenom` is accepted,
/// including 128 when the denominator is 7.
int explicitWeightedUniSample8({
  required int sample,
  required int log2WeightDenom,
  required int weight,
  required int offset,
}) {
  _validateSample(sample, 'sample');
  _validateDenominator(log2WeightDenom);
  _validateExplicitWeight(weight, 'weight');
  _validateExplicitOffset(offset, 'offset');

  if (log2WeightDenom == 0) {
    return _clip8(weight * sample + offset);
  }
  final rounding = 1 << (log2WeightDenom - 1);
  return _clip8(((weight * sample + rounding) >> log2WeightDenom) + offset);
}

/// Applies H.264 explicit weighted bi-prediction to one 8-bit sample.
///
/// This implements the two-reference branch of section 8.4.2.3.2, including
/// the signed rounded average of the two offsets.
int explicitWeightedBiSample8({
  required int list0Sample,
  required int list1Sample,
  required int log2WeightDenom,
  required int list0Weight,
  required int list1Weight,
  required int list0Offset,
  required int list1Offset,
}) {
  _validateSample(list0Sample, 'list0Sample');
  _validateSample(list1Sample, 'list1Sample');
  _validateDenominator(log2WeightDenom);
  _validateExplicitWeight(list0Weight, 'list0Weight');
  _validateExplicitWeight(list1Weight, 'list1Weight');
  _validateExplicitOffset(list0Offset, 'list0Offset');
  _validateExplicitOffset(list1Offset, 'list1Offset');

  final averagedOffset = (list0Offset + list1Offset + 1) >> 1;
  final shift = log2WeightDenom + 1;
  final rounding = 1 << log2WeightDenom;
  return _clip8(
    ((list0Weight * list0Sample + list1Weight * list1Sample + rounding) >>
            shift) +
        averagedOffset,
  );
}

/// Selects one parsed luma/chroma entry and applies explicit uni prediction.
///
/// The denominator and component-specific values come directly from
/// [PredictionWeightTable], preventing a caller from accidentally applying the
/// luma denominator to chroma or vice versa.
int explicitWeightedUniFromTable8({
  required int sample,
  required PredictionWeightTable table,
  required H264ReferenceList referenceList,
  required int referenceIndex,
  H264PredictionComponent component = H264PredictionComponent.luma,
}) {
  final parameters = _parametersFromTable(
    table: table,
    referenceList: referenceList,
    referenceIndex: referenceIndex,
    component: component,
  );
  return explicitWeightedUniSample8(
    sample: sample,
    log2WeightDenom: parameters.denominator,
    weight: parameters.weight,
    offset: parameters.offset,
  );
}

/// Selects two parsed luma/chroma entries and applies explicit bi prediction.
int explicitWeightedBiFromTable8({
  required int list0Sample,
  required int list1Sample,
  required PredictionWeightTable table,
  required int list0ReferenceIndex,
  required int list1ReferenceIndex,
  H264PredictionComponent component = H264PredictionComponent.luma,
}) {
  final list0 = _parametersFromTable(
    table: table,
    referenceList: H264ReferenceList.list0,
    referenceIndex: list0ReferenceIndex,
    component: component,
  );
  final list1 = _parametersFromTable(
    table: table,
    referenceList: H264ReferenceList.list1,
    referenceIndex: list1ReferenceIndex,
    component: component,
  );
  if (list0.denominator != list1.denominator) {
    throw StateError('Prediction table produced inconsistent denominators.');
  }
  return explicitWeightedBiSample8(
    list0Sample: list0Sample,
    list1Sample: list1Sample,
    log2WeightDenom: list0.denominator,
    list0Weight: list0.weight,
    list1Weight: list1.weight,
    list0Offset: list0.offset,
    list1Offset: list1.offset,
  );
}

/// Derives implicit B-slice weights from current, list-0, and list-1 POCs.
///
/// This is the temporal-distance process in H.264 section 8.4.2.3.2. POC
/// differences are clipped to signed 8-bit range before scaling. A zero
/// temporal distance, either long-term reference, or an out-of-range derived
/// weight selects the normative equal-weight fallback.
H264ImplicitBiWeights deriveImplicitBiPredictionWeights({
  required int currentPoc,
  required int list0Poc,
  required int list1Poc,
  bool list0IsLongTerm = false,
  bool list1IsLongTerm = false,
}) {
  final temporalDistance = _clip3(-128, 127, list1Poc - list0Poc);
  if (temporalDistance == 0 || list0IsLongTerm || list1IsLongTerm) {
    return _equalImplicitWeights;
  }

  final currentDistance = _clip3(-128, 127, currentPoc - list0Poc);
  final temporalReciprocal =
      (16384 + (temporalDistance.abs() >> 1)) ~/ temporalDistance;
  final distanceScaleFactor = _clip3(
    -1024,
    1023,
    (currentDistance * temporalReciprocal + 32) >> 6,
  );
  final list1Weight = distanceScaleFactor >> 2;
  if (list1Weight < -64 || list1Weight > 128) {
    return _equalImplicitWeights;
  }
  return H264ImplicitBiWeights._(
    list0Weight: 64 - list1Weight,
    list1Weight: list1Weight,
  );
}

/// Applies POC-derived implicit B-slice bi-prediction to one 8-bit sample.
///
/// The same operation is used for luma, Cb, and Cr. Implicit prediction has a
/// fixed denominator of 5 and zero offsets, yielding the `+32, >>6` equation.
int implicitWeightedBiSample8({
  required int list0Sample,
  required int list1Sample,
  required H264ImplicitBiWeights weights,
}) {
  _validateSample(list0Sample, 'list0Sample');
  _validateSample(list1Sample, 'list1Sample');
  return _clip8(
    (weights.list0Weight * list0Sample +
            weights.list1Weight * list1Sample +
            32) >>
        6,
  );
}

/// Applies the default two-reference rounded average from section 8.4.2.3.1.
int defaultBiPredictionSample8({
  required int list0Sample,
  required int list1Sample,
}) {
  _validateSample(list0Sample, 'list0Sample');
  _validateSample(list1Sample, 'list1Sample');
  return (list0Sample + list1Sample + 1) >> 1;
}

const _equalImplicitWeights = H264ImplicitBiWeights._(
  list0Weight: 32,
  list1Weight: 32,
);

({int denominator, int weight, int offset}) _parametersFromTable({
  required PredictionWeightTable table,
  required H264ReferenceList referenceList,
  required int referenceIndex,
  required H264PredictionComponent component,
}) {
  final entries = switch (referenceList) {
    H264ReferenceList.list0 => table.list0,
    H264ReferenceList.list1 => table.list1,
  };
  if (referenceIndex < 0 || referenceIndex >= entries.length) {
    throw RangeError.index(referenceIndex, entries, 'referenceIndex');
  }
  final entry = entries[referenceIndex];
  return switch (component) {
    H264PredictionComponent.luma => (
      denominator: table.lumaLog2WeightDenom,
      weight: entry.lumaWeight,
      offset: entry.lumaOffset,
    ),
    H264PredictionComponent.cb => _chromaParameters(
      entry,
      table.chromaLog2WeightDenom,
      0,
    ),
    H264PredictionComponent.cr => _chromaParameters(
      entry,
      table.chromaLog2WeightDenom,
      1,
    ),
  };
}

({int denominator, int weight, int offset}) _chromaParameters(
  PredictionWeight entry,
  int denominator,
  int component,
) {
  if (entry.chromaWeights.length != 2 || entry.chromaOffsets.length != 2) {
    throw ArgumentError(
      'PredictionWeight must contain exactly two chroma weights and offsets.',
    );
  }
  return (
    denominator: denominator,
    weight: entry.chromaWeights[component],
    offset: entry.chromaOffsets[component],
  );
}

void _validateSample(int sample, String name) {
  RangeError.checkValueInInterval(sample, 0, 255, name);
}

void _validateDenominator(int denominator) {
  RangeError.checkValueInInterval(denominator, 0, 7, 'log2WeightDenom');
}

void _validateExplicitWeight(int weight, String name) {
  // Signalled values are -128..127. The inferred identity weight at a
  // denominator of 7 is 128, so the derived-value API must also accept 128.
  RangeError.checkValueInInterval(weight, -128, 128, name);
}

void _validateExplicitOffset(int offset, String name) {
  RangeError.checkValueInInterval(offset, -128, 127, name);
}

int _clip3(int minimum, int maximum, int value) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}

int _clip8(int value) => _clip3(0, 255, value);
