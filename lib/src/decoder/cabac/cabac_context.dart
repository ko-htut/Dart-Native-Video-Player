import 'cabac_tables.dart';

/// Slice classes that select H.264 CABAC context-initialization models.
enum H264CabacSliceType { i, p, b }

/// The `(m, n)` pair used to initialize one CABAC probability context.
typedef CabacContextInitParameters = ({int m, int n});

/// Mutable H.264 CABAC probability state (`pStateIdx`, `valMPS`).
///
/// This object contains no arithmetic-decoder state. It is deliberately small
/// so a slice decoder can retain one instance for each normative `ctxIdx`.
final class CabacContextModel {
  CabacContextModel({
    required int probabilityStateIndex,
    required int mostProbableSymbol,
  }) : _probabilityStateIndex = probabilityStateIndex,
       _mostProbableSymbol = mostProbableSymbol {
    RangeError.checkValueInInterval(
      probabilityStateIndex,
      0,
      63,
      'probabilityStateIndex',
    );
    RangeError.checkValueInInterval(
      mostProbableSymbol,
      0,
      1,
      'mostProbableSymbol',
    );
  }

  /// Initializes a context using H.264 clause 9.3.1.1.
  factory CabacContextModel.initialize({
    required int m,
    required int n,
    required int sliceQpY,
  }) {
    final clippedQp = sliceQpY.clamp(0, 51);
    final unclippedPreContextState = ((m * clippedQp) >> 4) + n;
    final preContextState = unclippedPreContextState.clamp(1, 126);
    if (preContextState <= 63) {
      return CabacContextModel(
        probabilityStateIndex: 63 - preContextState,
        mostProbableSymbol: 0,
      );
    }
    return CabacContextModel(
      probabilityStateIndex: preContextState - 64,
      mostProbableSymbol: 1,
    );
  }

  int _probabilityStateIndex;
  int _mostProbableSymbol;

  int get probabilityStateIndex => _probabilityStateIndex;
  int get mostProbableSymbol => _mostProbableSymbol;

  /// Compact `(pStateIdx << 1) | valMPS` representation for diagnostics.
  int get packedState => (_probabilityStateIndex << 1) | _mostProbableSymbol;

  /// Applies Table 9-45 after decoding the most-probable symbol.
  void updateForMps() {
    _probabilityStateIndex =
        h264CabacStateTransitions[_probabilityStateIndex][1];
  }

  /// Applies Table 9-45 after decoding the least-probable symbol.
  ///
  /// At state zero, `valMPS` is inverted before the state transition, as
  /// required by clause 9.3.3.2.1.1.
  void updateForLps() {
    if (_probabilityStateIndex == 0) {
      _mostProbableSymbol ^= 1;
    }
    _probabilityStateIndex =
        h264CabacStateTransitions[_probabilityStateIndex][0];
  }

  CabacContextModel copy() => CabacContextModel(
    probabilityStateIndex: _probabilityStateIndex,
    mostProbableSymbol: _mostProbableSymbol,
  );

  @override
  String toString() =>
      'CabacContextModel(pStateIdx=$_probabilityStateIndex, '
      'valMPS=$_mostProbableSymbol)';
}

/// The 460 context models required by H.264 4:2:0 I, P, and B slices.
///
/// Context indices 0 through 459 cover the syntax used by progressive 4:2:0
/// streams, including High-profile 8x8-transform significance contexts.
/// Separate-colour-plane and 4:4:4-only contexts above 459 are intentionally
/// outside this phase.
final class H264CabacContextSet {
  H264CabacContextSet._({
    required this.sliceType,
    required this.sliceQpY,
    required this.effectiveSliceQpY,
    required this.cabacInitIdc,
    required List<CabacContextModel> contexts,
  }) : _contexts = List<CabacContextModel>.unmodifiable(contexts);

  factory H264CabacContextSet.initialize({
    required H264CabacSliceType sliceType,
    required int sliceQpY,
    int cabacInitIdc = 0,
  }) {
    if (sliceType == H264CabacSliceType.i) {
      if (cabacInitIdc != 0) {
        throw ArgumentError.value(
          cabacInitIdc,
          'cabacInitIdc',
          'is not present for an I slice',
        );
      }
    } else {
      RangeError.checkValueInInterval(cabacInitIdc, 0, 2, 'cabacInitIdc');
    }

    final effectiveQp = sliceQpY.clamp(0, 51);
    final contexts = <CabacContextModel>[];
    for (
      var contextIndex = 0;
      contextIndex < h264CabacContextCount;
      contextIndex++
    ) {
      final parameters = h264CabacContextInitParameters(
        sliceType: sliceType,
        cabacInitIdc: cabacInitIdc,
        contextIndex: contextIndex,
      );
      contexts.add(
        CabacContextModel.initialize(
          m: parameters.m,
          n: parameters.n,
          sliceQpY: effectiveQp,
        ),
      );
    }

    return H264CabacContextSet._(
      sliceType: sliceType,
      sliceQpY: sliceQpY,
      effectiveSliceQpY: effectiveQp,
      cabacInitIdc: cabacInitIdc,
      contexts: contexts,
    );
  }

  final H264CabacSliceType sliceType;

  /// Unclipped slice QP supplied by the caller.
  final int sliceQpY;

  /// `Clip3(0, 51, SliceQPY)` used by the initialization process.
  final int effectiveSliceQpY;

  /// Initialization model for P/B slices; always zero for I slices.
  final int cabacInitIdc;

  final List<CabacContextModel> _contexts;

  int get length => _contexts.length;

  CabacContextModel operator [](int contextIndex) {
    RangeError.checkValidIndex(contextIndex, _contexts, 'contextIndex');
    return _contexts[contextIndex];
  }

  List<CabacContextModel> get contexts => _contexts;
}

/// Returns the normative `(m, n)` initialization pair for one `ctxIdx`.
CabacContextInitParameters h264CabacContextInitParameters({
  required H264CabacSliceType sliceType,
  required int contextIndex,
  int cabacInitIdc = 0,
}) {
  RangeError.checkValueInInterval(
    contextIndex,
    0,
    h264CabacContextCount - 1,
    'contextIndex',
  );
  final modelIndex = switch (sliceType) {
    H264CabacSliceType.i => 0,
    H264CabacSliceType.p || H264CabacSliceType.b => cabacInitIdc + 1,
  };
  if (sliceType == H264CabacSliceType.i) {
    if (cabacInitIdc != 0) {
      throw ArgumentError.value(
        cabacInitIdc,
        'cabacInitIdc',
        'is not present for an I slice',
      );
    }
  } else {
    RangeError.checkValueInInterval(cabacInitIdc, 0, 2, 'cabacInitIdc');
  }
  final offset = contextIndex * 8 + modelIndex * 2;
  return (
    m: h264CabacContextInitMn[offset],
    n: h264CabacContextInitMn[offset + 1],
  );
}
