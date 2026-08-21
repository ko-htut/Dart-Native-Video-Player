/// MPEG presentation timestamps use an unsigned 33-bit, 90 kHz clock.
const int mpegTimestampClockRate = 90000;
const int mpegTimestampModulus = 1 << 33;
const int mpegTimestampMask = mpegTimestampModulus - 1;
const int mpegTimestampHalfRange = mpegTimestampModulus >> 1;

/// Unwraps one 33-bit MPEG timestamp into the epoch nearest [reference].
int unwrapMpegTimestamp33(int value, int? reference) {
  final raw = value & mpegTimestampMask;
  if (reference == null) return raw;
  final referenceRaw = reference & mpegTimestampMask;
  var delta = raw - referenceRaw;
  if (delta > mpegTimestampHalfRange) {
    delta -= mpegTimestampModulus;
  } else if (delta < -mpegTimestampHalfRange) {
    delta += mpegTimestampModulus;
  }
  return reference + delta;
}

/// One shared source-clock to continuous-timeline mapping.
///
/// Video normally establishes [sourceStart90k] from the first timestamp after
/// an HLS discontinuity. An audio demuxer then consumes this same object, so an
/// audio timestamp offset from the video timestamp is retained instead of both
/// tracks being independently snapped to [timelineStart90k].
final class MpegTimestampEpoch {
  MpegTimestampEpoch({
    required this.discontinuitySequence,
    required this.ordinal,
    required this.timelineStart90k,
    required this.scheduledStart90k,
    required this.cadenceFloor90k,
    int? sourceStart90k,
  }) : _sourceStart90k = sourceStart90k;

  final int discontinuitySequence;
  final int ordinal;

  /// Continuous presentation timestamp assigned to [sourceStart90k].
  final int timelineStart90k;

  /// EXTINF-derived target before the last-emitted-cadence floor was applied.
  final int? scheduledStart90k;

  /// Minimum target derived from the previous emitted timestamp and cadence.
  final int? cadenceFloor90k;

  int? _sourceStart90k;

  /// Unwrapped first source timestamp for this epoch, once video establishes it.
  int? get sourceStart90k => _sourceStart90k;
  bool get isSourceBound => _sourceStart90k != null;

  void _bindSourceStart(int timestamp90k) {
    _sourceStart90k ??= timestamp90k;
  }

  MpegTimestampEpochSnapshot get snapshot => MpegTimestampEpochSnapshot(
    discontinuitySequence: discontinuitySequence,
    ordinal: ordinal,
    sourceStart90k: sourceStart90k,
    timelineStart90k: timelineStart90k,
    scheduledStart90k: scheduledStart90k,
    cadenceFloor90k: cadenceFloor90k,
  );
}

/// Immutable diagnostics for a currently active timestamp epoch.
final class MpegTimestampEpochSnapshot {
  const MpegTimestampEpochSnapshot({
    required this.discontinuitySequence,
    required this.ordinal,
    required this.sourceStart90k,
    required this.timelineStart90k,
    required this.scheduledStart90k,
    required this.cadenceFloor90k,
  });

  final int discontinuitySequence;
  final int ordinal;
  final int? sourceStart90k;
  final int timelineStart90k;
  final int? scheduledStart90k;
  final int? cadenceFloor90k;
}

/// Raised when a shared epoch would move one track backwards.
final class MpegTimestampEpochRegressionException implements Exception {
  const MpegTimestampEpochRegressionException({
    required this.mappedTimestamp90k,
    required this.minimumTimestamp90k,
    required this.discontinuitySequence,
  });

  final int mappedTimestamp90k;
  final int minimumTimestamp90k;
  final int discontinuitySequence;

  @override
  String toString() =>
      'MpegTimestampEpochRegressionException: discontinuity epoch '
      '$discontinuitySequence mapped to $mappedTimestamp90k, before required '
      'continuous timestamp $minimumTimestamp90k';
}

/// Stateful 33-bit unwrap and discontinuity-rebase policy for one track.
///
/// With no declared discontinuity, timestamps are returned byte-for-byte
/// compatible with the former nearest-epoch unwrap behavior. At a declared
/// boundary, [beginEpoch] chooses the later of an EXTINF-derived schedule and
/// the previous emitted cadence. Passing [sharedEpoch] applies the exact video
/// mapping to another track while retaining its raw source-clock offset.
final class MpegTimestampEpochRebaser {
  MpegTimestampEpochRebaser({int? initialReference90k})
    : _unwrapReference90k = initialReference90k;

  int? _unwrapReference90k;
  int? _firstTimelineTimestamp90k;
  int? _lastEmittedTimestamp90k;
  int? _lastCadence90k;
  int _nextOrdinal = 0;
  MpegTimestampEpoch? _epoch;
  bool _firstTimestampPending = false;

  int? get firstTimelineTimestamp90k => _firstTimelineTimestamp90k;
  int? get lastEmittedTimestamp90k => _lastEmittedTimestamp90k;
  int? get lastCadence90k => _lastCadence90k;
  MpegTimestampEpoch? get currentEpoch => _epoch;
  MpegTimestampEpochSnapshot? get currentEpochSnapshot => _epoch?.snapshot;

  /// Clears all unwrap, cadence, and epoch state for a brand-new stream.
  void reset({int? initialReference90k}) {
    _unwrapReference90k = initialReference90k;
    _firstTimelineTimestamp90k = null;
    _lastEmittedTimestamp90k = null;
    _lastCadence90k = null;
    _nextOrdinal = 0;
    _epoch = null;
    _firstTimestampPending = false;
  }

  /// Starts a locally coordinated discontinuity epoch.
  ///
  /// [elapsedDuration90k] is the sum of declared segment durations preceding
  /// the new epoch. It is relative to the first emitted timeline timestamp.
  /// When omitted, the last emitted cadence alone defines the next start.
  MpegTimestampEpoch beginEpoch({
    required int discontinuitySequence,
    int? elapsedDuration90k,
    MpegTimestampEpoch? sharedEpoch,
  }) {
    if (elapsedDuration90k != null && elapsedDuration90k < 0) {
      throw ArgumentError.value(
        elapsedDuration90k,
        'elapsedDuration90k',
        'must not be negative',
      );
    }

    final epoch =
        sharedEpoch ??
        _createEpoch(
          discontinuitySequence: discontinuitySequence,
          elapsedDuration90k: elapsedDuration90k,
        );
    if (epoch.discontinuitySequence != discontinuitySequence) {
      throw ArgumentError.value(
        discontinuitySequence,
        'discontinuitySequence',
        'does not match shared epoch ${epoch.discontinuitySequence}',
      );
    }
    _epoch = epoch;
    _unwrapReference90k = epoch.sourceStart90k;
    _firstTimestampPending = true;
    if (epoch.ordinal >= _nextOrdinal) _nextOrdinal = epoch.ordinal + 1;
    return epoch;
  }

  MpegTimestampEpoch _createEpoch({
    required int discontinuitySequence,
    required int? elapsedDuration90k,
  }) {
    final first = _firstTimelineTimestamp90k;
    final scheduled = first == null || elapsedDuration90k == null
        ? null
        : first + elapsedDuration90k;
    final last = _lastEmittedTimestamp90k;
    final cadence = _lastCadence90k;
    final cadenceFloor = last == null
        ? null
        : last + ((cadence ?? 0) > 0 ? cadence! : 1);
    final target = switch ((scheduled, cadenceFloor)) {
      (final int left, final int right) => left > right ? left : right,
      (final int only, null) => only,
      (null, final int only) => only,
      (null, null) => 0,
    };
    return MpegTimestampEpoch(
      discontinuitySequence: discontinuitySequence,
      ordinal: _nextOrdinal++,
      timelineStart90k: target,
      scheduledStart90k: scheduled,
      cadenceFloor90k: cadenceFloor,
    );
  }

  /// Maps one raw 33-bit timestamp onto the active continuous timeline.
  int rebase(int timestamp90k) {
    final epoch = _epoch;
    if (epoch == null) {
      final unwrapped = unwrapMpegTimestamp33(
        timestamp90k,
        _unwrapReference90k,
      );
      _unwrapReference90k = unwrapped;
      _firstTimelineTimestamp90k ??= unwrapped;
      return unwrapped;
    }

    final reference = _unwrapReference90k ?? epoch.sourceStart90k;
    final sourceTimestamp = unwrapMpegTimestamp33(timestamp90k, reference);
    _unwrapReference90k = sourceTimestamp;
    epoch._bindSourceStart(sourceTimestamp);
    final sourceStart = epoch.sourceStart90k!;
    final mapped = epoch.timelineStart90k + sourceTimestamp - sourceStart;

    if (_firstTimestampPending) {
      _firstTimestampPending = false;
      final last = _lastEmittedTimestamp90k;
      if (last != null) {
        final cadence = _lastCadence90k;
        final minimum = last + ((cadence ?? 0) > 0 ? cadence! : 1);
        if (mapped < minimum) {
          throw MpegTimestampEpochRegressionException(
            mappedTimestamp90k: mapped,
            minimumTimestamp90k: minimum,
            discontinuitySequence: epoch.discontinuitySequence,
          );
        }
      }
    }
    _firstTimelineTimestamp90k ??= mapped;
    return mapped;
  }

  /// Records an emitted access unit so the next epoch has a cadence floor.
  void noteEmitted(int timestamp90k, {int? expectedCadence90k}) {
    if (expectedCadence90k != null && expectedCadence90k > 0) {
      _lastCadence90k = expectedCadence90k;
    } else {
      final previous = _lastEmittedTimestamp90k;
      if (previous != null && timestamp90k > previous) {
        _lastCadence90k = timestamp90k - previous;
      }
    }
    _firstTimelineTimestamp90k ??= timestamp90k;
    _lastEmittedTimestamp90k = timestamp90k;
  }
}
