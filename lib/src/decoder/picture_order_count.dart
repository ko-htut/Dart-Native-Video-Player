import 'slice_header.dart';

/// Picture-order values derived for one progressive H.264 frame picture.
///
/// [picOrderCntMsb] is the type-0 MSB derived before an MMCO 5 reset. When
/// [memoryManagementControlOperation5] is true, the returned field order
/// counts are the normalized values that remain after the reset operation.
final class H264PictureOrderCount {
  const H264PictureOrderCount({
    required this.picOrderCntMsb,
    required this.picOrderCntLsb,
    required this.topFieldOrderCount,
    required this.bottomFieldOrderCount,
    required this.pictureOrderCount,
    required this.memoryManagementControlOperation5,
  });

  final int picOrderCntMsb;
  final int picOrderCntLsb;
  final int topFieldOrderCount;
  final int bottomFieldOrderCount;

  /// Frame POC, defined as the lesser of the two field order counts.
  final int pictureOrderCount;
  final bool memoryManagementControlOperation5;
}

/// Immutable state retained from the previous reference picture.
final class H264PocType0ReferenceState {
  const H264PocType0ReferenceState({
    required this.picOrderCntMsb,
    required this.picOrderCntLsb,
    required this.topFieldOrderCount,
    required this.memoryManagementControlOperation5,
  });

  final int picOrderCntMsb;
  final int picOrderCntLsb;
  final int topFieldOrderCount;
  final bool memoryManagementControlOperation5;
}

/// Stateful progressive-frame implementation of H.264 POC type 0.
///
/// Only reference pictures update [previousReferenceState]. This is important
/// for streams with non-reference B pictures: every such B picture derives its
/// MSB from the same preceding reference picture, not from the preceding
/// picture in decoding order.
final class H264PocType0Tracker {
  H264PocType0Tracker()
    : _forkParent = null,
      _forkParentRevision = -1,
      _revision = 0;

  H264PocType0Tracker._forked({
    required H264PocType0Tracker parent,
    required H264PocType0ReferenceState? previousReferenceState,
    required int parentRevision,
  }) : _previousReferenceState = previousReferenceState,
       _forkParent = parent,
       _forkParentRevision = parentRevision,
       _revision = parentRevision;

  H264PocType0ReferenceState? _previousReferenceState;
  final H264PocType0Tracker? _forkParent;
  final int _forkParentRevision;
  int _revision;
  bool _consumed = false;

  H264PocType0ReferenceState? get previousReferenceState =>
      _previousReferenceState;

  /// Creates an isolated transaction seeded with this tracker's POC state.
  ///
  /// Derive the candidate picture on the returned tracker. If reconstruction
  /// succeeds, publish its retained reference state with [commitFrom]. Simply
  /// discard the fork after a failed decode; the source tracker is unchanged.
  H264PocType0Tracker fork() {
    _ensureUsable();
    return H264PocType0Tracker._forked(
      parent: this,
      previousReferenceState: _previousReferenceState,
      parentRevision: _revision,
    );
  }

  /// Atomically adopts the state of a direct [fork] of this tracker.
  ///
  /// A candidate belongs to the exact tracker instance that created it. A
  /// foreign candidate, this tracker itself, a stale sibling, or a candidate
  /// that has already been committed is rejected. A successful commit consumes
  /// the candidate so the same transaction cannot be published twice.
  void commitFrom(H264PocType0Tracker candidate) {
    _ensureUsable();
    if (identical(candidate, this)) {
      throw ArgumentError.value(
        candidate,
        'candidate',
        'must be a fork, not the receiving tracker itself',
      );
    }
    if (!identical(candidate._forkParent, this)) {
      throw ArgumentError.value(
        candidate,
        'candidate',
        'must be a direct fork of this tracker',
      );
    }
    candidate._ensureUsable();
    if (candidate._forkParentRevision != _revision) {
      throw StateError(
        'Cannot commit a stale POC transaction: parent state changed after '
        'fork()',
      );
    }

    _previousReferenceState = candidate._previousReferenceState;
    _revision++;
    candidate._consumed = true;
  }

  void reset() {
    _ensureUsable();
    _previousReferenceState = null;
    _revision++;
  }

  /// Derives and records POC from a parsed progressive slice header.
  H264PictureOrderCount deriveFromHeader(SliceHeader header) {
    _ensureUsable();
    if (!header.sps.frameMbsOnlyFlag) {
      throw const FormatException(
        'POC type 0 tracker supports progressive frame pictures only',
      );
    }
    if (header.sps.picOrderCntType != 0 || header.picOrderCntLsb == null) {
      throw FormatException(
        'Expected pic_order_cnt_type 0, got ${header.sps.picOrderCntType}',
      );
    }
    return derivePictureOrderCount(
      picOrderCntLsb: header.picOrderCntLsb!,
      maxPicOrderCntLsb: header.sps.maxPicOrderCntLsb,
      isIdr: header.isIdr,
      isReference: header.nalRefIdc != 0,
      deltaPicOrderCntBottom: header.deltaPicOrderCntBottom ?? 0,
      memoryManagementControlOperation5: header.memoryManagementOperations.any(
        (operation) => operation.operation == 5,
      ),
    );
  }

  /// Derives POC for one progressive frame and advances reference state.
  ///
  /// Decoding must begin at an IDR picture, or [reset] must be followed by an
  /// IDR picture. This bounded requirement avoids inventing unavailable POC
  /// state when joining a dependent stream mid-GOP.
  H264PictureOrderCount derivePictureOrderCount({
    required int picOrderCntLsb,
    required int maxPicOrderCntLsb,
    required bool isIdr,
    required bool isReference,
    int deltaPicOrderCntBottom = 0,
    bool memoryManagementControlOperation5 = false,
  }) {
    _ensureUsable();
    if (maxPicOrderCntLsb < 16 ||
        (maxPicOrderCntLsb & (maxPicOrderCntLsb - 1)) != 0) {
      throw ArgumentError.value(
        maxPicOrderCntLsb,
        'maxPicOrderCntLsb',
        'must be a power of two of at least 16',
      );
    }
    if (picOrderCntLsb < 0 || picOrderCntLsb >= maxPicOrderCntLsb) {
      throw ArgumentError.value(
        picOrderCntLsb,
        'picOrderCntLsb',
        'must be in 0..${maxPicOrderCntLsb - 1}',
      );
    }
    if (isIdr && !isReference) {
      throw const FormatException('An IDR picture must be a reference picture');
    }
    if (memoryManagementControlOperation5 && (!isReference || isIdr)) {
      throw const FormatException(
        'MMCO 5 is valid only for a non-IDR reference picture',
      );
    }

    final previous = _previousReferenceState;
    if (!isIdr && previous == null) {
      throw StateError('POC type 0 decoding must begin at an IDR picture');
    }

    int previousPicOrderCntMsb;
    int previousPicOrderCntLsb;
    if (isIdr) {
      previousPicOrderCntMsb = 0;
      previousPicOrderCntLsb = 0;
    } else if (previous!.memoryManagementControlOperation5) {
      previousPicOrderCntMsb = 0;
      previousPicOrderCntLsb = previous.topFieldOrderCount;
    } else {
      previousPicOrderCntMsb = previous.picOrderCntMsb;
      previousPicOrderCntLsb = previous.picOrderCntLsb;
    }

    final halfRange = maxPicOrderCntLsb ~/ 2;
    final int picOrderCntMsb;
    if (picOrderCntLsb < previousPicOrderCntLsb &&
        previousPicOrderCntLsb - picOrderCntLsb >= halfRange) {
      picOrderCntMsb = previousPicOrderCntMsb + maxPicOrderCntLsb;
    } else if (picOrderCntLsb > previousPicOrderCntLsb &&
        picOrderCntLsb - previousPicOrderCntLsb > halfRange) {
      picOrderCntMsb = previousPicOrderCntMsb - maxPicOrderCntLsb;
    } else {
      picOrderCntMsb = previousPicOrderCntMsb;
    }

    var topFieldOrderCount = picOrderCntMsb + picOrderCntLsb;
    var bottomFieldOrderCount = topFieldOrderCount + deltaPicOrderCntBottom;
    var pictureOrderCount = topFieldOrderCount < bottomFieldOrderCount
        ? topFieldOrderCount
        : bottomFieldOrderCount;

    // H.264 8.2.5.4 resets the current picture's field order counts when the
    // decoded-reference-picture marking syntax contains MMCO 5.
    if (memoryManagementControlOperation5) {
      topFieldOrderCount -= pictureOrderCount;
      bottomFieldOrderCount -= pictureOrderCount;
      pictureOrderCount = 0;
    }

    final result = H264PictureOrderCount(
      picOrderCntMsb: picOrderCntMsb,
      picOrderCntLsb: picOrderCntLsb,
      topFieldOrderCount: topFieldOrderCount,
      bottomFieldOrderCount: bottomFieldOrderCount,
      pictureOrderCount: pictureOrderCount,
      memoryManagementControlOperation5: memoryManagementControlOperation5,
    );
    if (isReference) {
      _previousReferenceState = H264PocType0ReferenceState(
        picOrderCntMsb: picOrderCntMsb,
        picOrderCntLsb: picOrderCntLsb,
        topFieldOrderCount: topFieldOrderCount,
        memoryManagementControlOperation5: memoryManagementControlOperation5,
      );
      _revision++;
    }
    return result;
  }

  void _ensureUsable() {
    if (_consumed) {
      throw StateError('This POC transaction has already been committed');
    }
  }
}
