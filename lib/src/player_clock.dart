import 'dart:async';

typedef PlaybackTimeSource = int Function();
typedef PlaybackStateChanged = void Function(int nowMs, bool playing);

class PlayerClock {
  Timer? _timer;
  final Stopwatch _elapsed = Stopwatch();
  int _playBaseMs = 0;
  int _nowMs = 0;
  bool _playing = false;
  PlaybackTimeSource? _timeSource;

  int get nowMs => _nowMs;
  bool get isPlaying => _playing;

  void Function(int nowMs)? onFrameDue;
  PlaybackStateChanged? onPlaybackStateChanged;

  void setTime(int ms) {
    _nowMs = ms;
    if (_playing) {
      _playBaseMs = ms;
      _elapsed
        ..reset()
        ..start();
    }
    onFrameDue?.call(_nowMs);
    onPlaybackStateChanged?.call(_nowMs, _playing);
  }

  /// Starts ticking from [fromMs].
  ///
  /// When [timeSource] is supplied it becomes the authoritative media clock.
  /// This is used by audio/video playback so rendered PCM, rather than a wall
  /// clock, decides which video picture is due. Video-only playback keeps the
  /// existing stopwatch-backed behavior by omitting [timeSource].
  void play({required int fromMs, PlaybackTimeSource? timeSource}) {
    _timer?.cancel();
    _timeSource = timeSource;
    _playBaseMs = fromMs;
    _playing = true;
    _elapsed
      ..reset()
      ..start();

    _nowMs = _readCurrentTime();
    onPlaybackStateChanged?.call(_nowMs, true);

    // Make a frame at the requested position eligible immediately. Waiting
    // for the first timer tick otherwise makes seeks and replay inconsistent.
    onFrameDue?.call(_nowMs);
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _nowMs = _readCurrentTime();
      onFrameDue?.call(_nowMs);
    });
  }

  void pause() {
    if (_playing) {
      _nowMs = _readCurrentTime();
      // Present everything that became due between the last periodic tick and
      // the exact pause position. This matters when an audio-master timeline
      // completes between 16 ms clock ticks.
      onFrameDue?.call(_nowMs);
    }
    _playing = false;
    _elapsed.stop();
    _timer?.cancel();
    _timer = null;
    onPlaybackStateChanged?.call(_nowMs, false);
  }

  int _readCurrentTime() {
    final source = _timeSource;
    return source == null
        ? _playBaseMs + _elapsed.elapsedMilliseconds
        : source();
  }

  void dispose() {
    pause();
    onFrameDue = null;
    onPlaybackStateChanged = null;
  }
}

typedef SequentialDecode<T, R> = FutureOr<R> Function(T item);
typedef ItemTimestamp<T> = int Function(T item);
typedef LatestDecoded<T, R> = void Function(T item, R result);
typedef SequentialDecodeSkip<T> = bool Function(T item, int requestedThroughMs);
typedef DecodeFailure<T> =
    void Function(T item, Object error, StackTrace stackTrace);

/// Observable lifecycle of a sequential compressed-item queue.
///
/// [starved] is deliberately different from [ended]: a producer may append
/// more items to a starved open queue, whereas an ended queue has been sealed
/// and consumed through its final item.
enum SequentialDecodeQueueState { ready, starved, ended, disposed }

typedef DecodeQueueStateChanged =
    void Function(SequentialDecodeQueueState state);
typedef DecodeDependencyBoundary<T> = bool Function(T item);
typedef DecodeQueueCompacted =
    void Function(int removedItemCount, int firstRetainedIndex);
typedef DecodeAppendCapacityAvailable = void Function(int availableItemSlots);

/// An immutable copy of the compressed items retained by a decode pump.
///
/// Indices are absolute: compaction may make [firstRetainedIndex] non-zero,
/// but never renumbers [nextIndex] or any item that remains in the window.
final class SequentialDecodeQueueSnapshot<T> {
  SequentialDecodeQueueSnapshot._({
    required List<T> items,
    required this.firstRetainedIndex,
    required this.nextIndex,
  }) : items = List<T>.unmodifiable(items);

  final List<T> items;
  final int firstRetainedIndex;
  final int nextIndex;

  int get endIndex => firstRetainedIndex + items.length;
  int get residentLength => items.length;

  T itemAt(int absoluteIndex) {
    if (absoluteIndex < firstRetainedIndex || absoluteIndex >= endIndex) {
      throw RangeError.range(
        absoluteIndex,
        firstRetainedIndex,
        endIndex - 1,
        'absoluteIndex',
      );
    }
    return items[absoluteIndex - firstRetainedIndex];
  }
}

/// Raised when a bounded rolling queue cannot accept an append atomically.
///
/// No item from the attempted append is retained when this exception is
/// thrown. Producers can use [SequentialDecodePump.tryAppendItems] or inspect
/// [SequentialDecodePump.remainingItemCapacity] to implement backpressure.
final class SequentialDecodeQueueCapacityException implements Exception {
  const SequentialDecodeQueueCapacityException({
    required this.requestedItems,
    required this.availableItems,
    required this.maximumItems,
  });

  final int requestedItems;
  final int availableItems;
  final int maximumItems;

  @override
  String toString() =>
      'SequentialDecodeQueueCapacityException: requested $requestedItems '
      'items, but only $availableItems of $maximumItems resident slots are '
      'available';
}

/// Raised when a dependency chain cannot fit inside a bounded rolling queue.
///
/// A producer must be able to append the next random-access boundary before
/// the retained previous boundary fills the complete resident window. Keeping
/// one slot reserved for that next boundary turns an otherwise permanent
/// producer/consumer wait into a deterministic unsupported-stream error.
final class SequentialDecodeDependencyWindowException implements Exception {
  const SequentialDecodeDependencyWindowException({
    required this.previousBoundaryIndex,
    required this.offendingIndex,
    required this.maximumItems,
    required this.offendingItemIsBoundary,
  });

  final int? previousBoundaryIndex;
  final int offendingIndex;
  final int maximumItems;
  final bool offendingItemIsBoundary;

  @override
  String toString() {
    final boundary = previousBoundaryIndex;
    if (boundary == null) {
      return 'SequentialDecodeDependencyWindowException: item '
          '$offendingIndex precedes the first dependency boundary';
    }
    final kind = offendingItemIsBoundary ? 'boundary' : 'dependent item';
    return 'SequentialDecodeDependencyWindowException: $kind at '
        '$offendingIndex is too far from boundary $boundary for a '
        '$maximumItems-item resident window';
  }
}

/// Validates one future append against a bounded dependency window.
///
/// Returns the last boundary after [items] without retaining the items. The
/// caller can therefore validate a complete segment batch before appending any
/// prefix. Non-boundary items reserve one resident slot for the next boundary;
/// a boundary itself may consume that final slot and reset the chain.
int? validateSequentialDecodeDependencyWindow<T>({
  required Iterable<T> items,
  required int startIndex,
  required int? previousBoundaryIndex,
  required int maximumItems,
  required bool Function(T item) isDependencyBoundary,
}) {
  if (startIndex < 0) {
    throw ArgumentError.value(startIndex, 'startIndex', 'must not be negative');
  }
  if (maximumItems < 2) {
    throw ArgumentError.value(
      maximumItems,
      'maximumItems',
      'must reserve at least one dependent item and one future boundary slot',
    );
  }
  final previous = previousBoundaryIndex;
  if (previous != null && previous >= startIndex) {
    throw ArgumentError.value(
      previous,
      'previousBoundaryIndex',
      'must precede startIndex',
    );
  }

  var boundary = previous;
  var index = startIndex;
  for (final item in items) {
    final isBoundary = isDependencyBoundary(item);
    final currentBoundary = boundary;
    if (currentBoundary == null) {
      if (!isBoundary) {
        throw SequentialDecodeDependencyWindowException(
          previousBoundaryIndex: null,
          offendingIndex: index,
          maximumItems: maximumItems,
          offendingItemIsBoundary: false,
        );
      }
      boundary = index;
    } else {
      final distance = index - currentBoundary;
      final tooFar = isBoundary
          ? distance >= maximumItems
          : distance >= maximumItems - 1;
      if (tooFar) {
        throw SequentialDecodeDependencyWindowException(
          previousBoundaryIndex: currentBoundary,
          offendingIndex: index,
          maximumItems: maximumItems,
          offendingItemIsBoundary: isBoundary,
        );
      }
      if (isBoundary) boundary = index;
    }
    index++;
  }
  return boundary;
}

/// Coalesces clock updates while preserving the compressed-stream decode order.
///
/// A clock is allowed to advance while [decode] is awaiting. This pump never
/// advances [nextIndex] until that exact item decodes successfully, then keeps
/// decoding every item due at the newest requested timestamp. Only the newest
/// decoded result from a drain is presented to [onLatestDecoded].
class SequentialDecodePump<T, R> {
  SequentialDecodePump({
    required ItemTimestamp<T> timestampOf,
    required SequentialDecode<T, R> decode,
    required LatestDecoded<T, R> onLatestDecoded,
    required DecodeFailure<T> onDecodeError,
    void Function()? onQueueDrained,
    DecodeQueueStateChanged? onQueueStateChanged,
    DecodeQueueCompacted? onQueueCompacted,
    DecodeAppendCapacityAvailable? onAppendCapacityAvailable,
    this.maxResidentItems,
    this.retainedConsumedItems = 0,
    this.presentationMayBeReordered = false,
    this.shouldSkipDecode,
    this.yieldBetweenDecodes = false,
    DecodeDependencyBoundary<T>? isDependencyBoundary,
  }) : _timestampOf = timestampOf,
       _decode = decode,
       _onLatestDecoded = onLatestDecoded,
       _onDecodeError = onDecodeError,
       _onQueueDrained = onQueueDrained,
       _onQueueStateChanged = onQueueStateChanged,
       _onQueueCompacted = onQueueCompacted,
       _onAppendCapacityAvailable = onAppendCapacityAvailable,
       _isDependencyBoundary = isDependencyBoundary {
    final maximum = maxResidentItems;
    if (maximum != null && maximum <= 0) {
      throw ArgumentError.value(
        maximum,
        'maxResidentItems',
        'must be positive',
      );
    }
    if (retainedConsumedItems < 0) {
      throw ArgumentError.value(
        retainedConsumedItems,
        'retainedConsumedItems',
        'must not be negative',
      );
    }
    if (maximum != null && retainedConsumedItems >= maximum) {
      throw ArgumentError.value(
        retainedConsumedItems,
        'retainedConsumedItems',
        'must be smaller than maxResidentItems so the producer can make '
            'progress',
      );
    }
  }

  final ItemTimestamp<T> _timestampOf;
  final SequentialDecode<T, R> _decode;
  final LatestDecoded<T, R> _onLatestDecoded;
  final DecodeFailure<T> _onDecodeError;
  final void Function()? _onQueueDrained;
  final DecodeQueueStateChanged? _onQueueStateChanged;
  final DecodeQueueCompacted? _onQueueCompacted;
  final DecodeAppendCapacityAvailable? _onAppendCapacityAvailable;
  final DecodeDependencyBoundary<T>? _isDependencyBoundary;

  /// Optional policy for intentionally consuming an item without decoding it.
  ///
  /// This must only return true for items that cannot affect later decode
  /// state. A typical use is dropping a non-reference B picture after playback
  /// has fallen behind its audio-master clock. Skipped items are not presented.
  final SequentialDecodeSkip<T>? shouldSkipDecode;

  /// Yields to the event queue after each consumed item while more work is due.
  ///
  /// Stateful software decoders are often synchronous. Enabling this prevents
  /// a catch-up drain from monopolizing the UI isolate across many frames.
  final bool yieldBetweenDecodes;

  /// Whether compressed items can arrive in decode order with non-monotonic
  /// presentation timestamps (for example H.264 streams containing B
  /// pictures).
  ///
  /// When enabled, the pump decodes through the last resident item due at the
  /// requested clock time, retains any future reference-picture results, and
  /// presents the due result with the greatest timestamp. Decode order is
  /// never changed.
  final bool presentationMayBeReordered;

  /// Maximum compressed items retained at once, or null for an unbounded
  /// fixed queue. The limit is checked atomically by [replaceQueue] and
  /// [appendItems].
  final int? maxResidentItems;

  /// Minimum number of already-consumed items kept for short backward seeks.
  ///
  /// If [isDependencyBoundary] is supplied, compaction additionally preserves
  /// the latest boundary at or before [nextIndex]. For H.264, pass an IDR
  /// predicate so the retained window always contains a decoder restart point.
  final int retainedConsumedItems;

  List<T> _items = <T>[];
  int _firstRetainedIndex = 0;
  int _nextIndex = 0;
  int _generation = 0;
  int _skippedDecodeCount = 0;
  int? _requestedThroughMs;
  bool _draining = false;
  bool _reportedDrained = false;
  bool _queueFinal = true;
  bool _hasEverContainedItems = false;
  bool _disposed = false;
  final List<_PendingPresentation<T, R>> _pendingPresentations =
      <_PendingPresentation<T, R>>[];
  int? _lastPresentedTimestampMs;
  int? _latestDependencyBoundaryIndex;
  SequentialDecodeQueueState _lastQueueState = SequentialDecodeQueueState.ready;
  bool _lastHadAppendCapacity = false;
  Future<void>? _activeDrain;

  /// Absolute index of the next item to decode.
  int get nextIndex => _nextIndex;

  /// Absolute index immediately after the current retained tail.
  ///
  /// This remains equal to the historical `length` for a non-compacting fixed
  /// queue, while staying monotonic when a rolling queue removes its prefix.
  int get length => endIndex;
  int get endIndex => _firstRetainedIndex + _items.length;
  int get firstRetainedIndex => _firstRetainedIndex;
  int get residentLength => _items.length;
  int get skippedDecodeCount => _skippedDecodeCount;
  int get pendingPresentationCount => _pendingPresentations.length;
  bool get isDraining => _draining;
  bool get isQueueFinal => _queueFinal;
  bool get isStarved => queueState == SequentialDecodeQueueState.starved;
  bool get isEnded => queueState == SequentialDecodeQueueState.ended;
  int? get latestDependencyBoundaryIndex => _latestDependencyBoundaryIndex;

  SequentialDecodeQueueState get queueState {
    if (_disposed) return SequentialDecodeQueueState.disposed;
    if (_queueFinal &&
        _nextIndex == endIndex &&
        _pendingPresentations.isEmpty) {
      return SequentialDecodeQueueState.ended;
    }
    if (!_queueFinal && _requestedThroughMs != null && _nextIndex == endIndex) {
      return SequentialDecodeQueueState.starved;
    }
    return SequentialDecodeQueueState.ready;
  }

  /// Remaining resident slots, or null when this pump is unbounded.
  int? get remainingItemCapacity {
    final maximum = maxResidentItems;
    return maximum == null ? null : maximum - residentLength;
  }

  bool get hasAppendCapacity {
    final remaining = remainingItemCapacity;
    return !_disposed && !_queueFinal && (remaining == null || remaining > 0);
  }

  SequentialDecodeQueueSnapshot<T> get retainedSnapshot =>
      SequentialDecodeQueueSnapshot<T>._(
        items: _items,
        firstRetainedIndex: _firstRetainedIndex,
        nextIndex: _nextIndex,
      );

  T itemAt(int absoluteIndex) {
    if (absoluteIndex < _firstRetainedIndex || absoluteIndex >= endIndex) {
      throw RangeError.range(
        absoluteIndex,
        _firstRetainedIndex,
        endIndex - 1,
        'absoluteIndex',
      );
    }
    return _items[absoluteIndex - _firstRetainedIndex];
  }

  void replaceQueue(List<T> items, {int nextIndex = 0, bool isFinal = true}) {
    if (nextIndex < 0 || nextIndex > items.length) {
      throw RangeError.range(nextIndex, 0, items.length, 'nextIndex');
    }
    final maximum = maxResidentItems;
    if (maximum != null && items.length > maximum) {
      throw SequentialDecodeQueueCapacityException(
        requestedItems: items.length,
        availableItems: maximum,
        maximumItems: maximum,
      );
    }
    _generation++;
    _items = List<T>.of(items);
    _firstRetainedIndex = 0;
    _nextIndex = nextIndex;
    _skippedDecodeCount = 0;
    _requestedThroughMs = null;
    _pendingPresentations.clear();
    _lastPresentedTimestampMs = null;
    _reportedDrained = false;
    _queueFinal = isFinal;
    _hasEverContainedItems = items.isNotEmpty;
    _refreshDependencyBoundary();
    _lastHadAppendCapacity = hasAppendCapacity;
    _compactForBoundedPolicy();
    _notifyQueueStateChanged();
  }

  /// Extends an open compressed queue without invalidating an in-flight decode.
  ///
  /// Reaching the current tail of an open queue is temporary starvation, not
  /// end of stream. A pending clock request is reconsidered immediately after
  /// the new items are appended.
  void appendItems(Iterable<T> items) {
    if (_disposed) return;
    if (_queueFinal) {
      throw StateError(
        'Cannot append to a final queue; replace it with isFinal: false first',
      );
    }
    final appended = List<T>.of(items);
    if (appended.isEmpty) return;
    final remaining = remainingItemCapacity;
    if (remaining != null && appended.length > remaining) {
      throw SequentialDecodeQueueCapacityException(
        requestedItems: appended.length,
        availableItems: remaining,
        maximumItems: maxResidentItems!,
      );
    }
    _appendMaterialized(appended);
  }

  /// Atomically appends all [items], returning false instead of throwing when
  /// the bounded resident window does not currently have enough room.
  bool tryAppendItems(Iterable<T> items) {
    if (_disposed) return false;
    if (_queueFinal) {
      throw StateError(
        'Cannot append to a final queue; replace it with isFinal: false first',
      );
    }
    final appended = List<T>.of(items);
    if (appended.isEmpty) return true;
    final remaining = remainingItemCapacity;
    if (remaining != null && appended.length > remaining) return false;
    _appendMaterialized(appended);
    return true;
  }

  /// Marks the current compressed queue as complete.
  ///
  /// [onQueueDrained] is delivered only after this call and after every item
  /// has decoded. Closing an already-consumed queue reports completion without
  /// requiring another clock tick.
  void closeQueue() {
    if (_disposed || _queueFinal) return;
    _queueFinal = true;
    _reportDrainedIfNeeded();
    _updateAppendCapacity();
    _notifyQueueStateChanged();
    _ensureDrain();
  }

  /// Removes consumed items before [absoluteIndex] without renumbering the
  /// retained tail or invalidating an in-flight decode.
  ///
  /// The request is safely clamped so [retainedConsumedItems] and the latest
  /// [isDependencyBoundary] item remain available. It is therefore safe to
  /// call while [decode] is awaiting; the item currently being decoded is
  /// never removed. Returns the number of items actually released.
  int compactConsumedBefore(int absoluteIndex) {
    if (absoluteIndex < _firstRetainedIndex || absoluteIndex > _nextIndex) {
      throw RangeError.range(
        absoluteIndex,
        _firstRetainedIndex,
        _nextIndex,
        'absoluteIndex',
      );
    }

    var safeIndex = absoluteIndex;
    final retainedCountLimit = _nextIndex - retainedConsumedItems;
    if (safeIndex > retainedCountLimit) safeIndex = retainedCountLimit;

    if (_isDependencyBoundary != null) {
      final boundary = _latestDependencyBoundaryIndex;
      // Without a known random-access boundary, dropping a prefix could leave
      // only inter-predicted pictures and make every retained seek invalid.
      if (boundary == null) return 0;
      if (safeIndex > boundary) safeIndex = boundary;
    }

    if (safeIndex <= _firstRetainedIndex) return 0;
    final removeCount = safeIndex - _firstRetainedIndex;
    _items.removeRange(0, removeCount);
    _firstRetainedIndex = safeIndex;
    _onQueueCompacted?.call(removeCount, _firstRetainedIndex);
    _updateAppendCapacity();
    return removeCount;
  }

  /// Invalidates an in-flight result and sets the next compressed item.
  void seekToIndex(int index) {
    if (index < _firstRetainedIndex || index > endIndex) {
      throw RangeError.range(index, _firstRetainedIndex, endIndex, 'index');
    }
    _generation++;
    _nextIndex = index;
    _skippedDecodeCount = 0;
    _requestedThroughMs = null;
    _pendingPresentations.clear();
    _lastPresentedTimestampMs = null;
    _reportedDrained = false;
    _refreshDependencyBoundary();
    _notifyQueueStateChanged();
  }

  void restart() => seekToIndex(0);

  void requestThrough(int targetMs) {
    if (_disposed) return;
    final previousTarget = _requestedThroughMs;
    if (previousTarget == null || targetMs > previousTarget) {
      _requestedThroughMs = targetMs;
    }
    _notifyQueueStateChanged();
    _ensureDrain();
  }

  Future<void> waitUntilIdle() async {
    while (true) {
      final active = _activeDrain;
      if (active == null) return;
      await active;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _requestedThroughMs = null;
    _items = <T>[];
    _pendingPresentations.clear();
    _firstRetainedIndex = _nextIndex;
    _queueFinal = true;
    _updateAppendCapacity();
    _notifyQueueStateChanged();
  }

  bool get _hasDueItem {
    final target = _requestedThroughMs;
    if (target == null || _nextIndex >= endIndex) return false;
    if (!presentationMayBeReordered) {
      return _timestampOf(itemAt(_nextIndex)) <= target;
    }
    for (var index = endIndex - 1; index >= _nextIndex; index--) {
      if (_timestampOf(itemAt(index)) <= target) return true;
    }
    return false;
  }

  bool get _hasDuePresentation {
    if (!presentationMayBeReordered) return false;
    final target = _requestedThroughMs;
    if (target == null) return false;
    return _pendingPresentations.any(
      (pending) => pending.timestampMs <= target,
    );
  }

  void _appendMaterialized(List<T> appended) {
    _items.addAll(appended);
    _hasEverContainedItems = true;
    _refreshDependencyBoundary();
    _compactForBoundedPolicy();
    _updateAppendCapacity();
    _notifyQueueStateChanged();
    _ensureDrain();
  }

  void _ensureDrain() {
    if (_disposed || _draining || (!_hasDueItem && !_hasDuePresentation)) {
      return;
    }
    final generation = _generation;
    _draining = true;
    // Schedule instead of invoking synchronously. A presentation-only drain
    // contains no await; invoking it inline would clear `_activeDrain` in its
    // finally block before this assignment and then overwrite that null with
    // an already-completed Future, making waitUntilIdle loop forever.
    _activeDrain = Future<void>.microtask(() => _drain(generation));
  }

  Future<void> _drain(int generation) async {
    var decodedAny = false;
    var decodedSinceReorderedPresentation = 0;
    late T latestItem;
    late R latestResult;

    void presentLatest() {
      if (!decodedAny || generation != _generation || _disposed) return;
      _onLatestDecoded(latestItem, latestResult);
      decodedAny = false;
    }

    void presentLatestReordered() {
      if (!presentationMayBeReordered ||
          generation != _generation ||
          _disposed) {
        return;
      }
      final target = _requestedThroughMs;
      if (target == null) return;
      var selectedIndex = -1;
      for (var index = 0; index < _pendingPresentations.length; index++) {
        final candidate = _pendingPresentations[index];
        if (candidate.timestampMs > target) continue;
        if (selectedIndex == -1) {
          selectedIndex = index;
          continue;
        }
        final selected = _pendingPresentations[selectedIndex];
        if (candidate.timestampMs > selected.timestampMs ||
            (candidate.timestampMs == selected.timestampMs &&
                candidate.decodeIndex > selected.decodeIndex)) {
          selectedIndex = index;
        }
      }
      if (selectedIndex == -1) return;
      final selected = _pendingPresentations[selectedIndex];
      _pendingPresentations.removeWhere(
        (pending) => pending.timestampMs <= target,
      );
      final lastPresented = _lastPresentedTimestampMs;
      if (lastPresented != null && selected.timestampMs <= lastPresented) {
        return;
      }
      _lastPresentedTimestampMs = selected.timestampMs;
      decodedSinceReorderedPresentation = 0;
      _onLatestDecoded(selected.item, selected.result);
    }

    void coalesceDueReorderedPresentations() {
      if (!presentationMayBeReordered) return;
      final target = _requestedThroughMs;
      if (target == null) return;
      var selectedIndex = -1;
      for (var index = 0; index < _pendingPresentations.length; index++) {
        final candidate = _pendingPresentations[index];
        if (candidate.timestampMs > target) continue;
        if (selectedIndex == -1) {
          selectedIndex = index;
          continue;
        }
        final selected = _pendingPresentations[selectedIndex];
        if (candidate.timestampMs > selected.timestampMs ||
            (candidate.timestampMs == selected.timestampMs &&
                candidate.decodeIndex > selected.decodeIndex)) {
          selectedIndex = index;
        }
      }
      if (selectedIndex == -1) return;
      for (var index = _pendingPresentations.length - 1; index >= 0; index--) {
        if (index != selectedIndex &&
            _pendingPresentations[index].timestampMs <= target) {
          _pendingPresentations.removeAt(index);
          if (index < selectedIndex) selectedIndex--;
        }
      }
    }

    try {
      while (generation == _generation && !_disposed && _hasDueItem) {
        final index = _nextIndex;
        final item = itemAt(index);
        final requestedThroughMs = _requestedThroughMs;
        if (requestedThroughMs != null &&
            (shouldSkipDecode?.call(item, requestedThroughMs) ?? false)) {
          _nextIndex = index + 1;
          _skippedDecodeCount++;
          _refreshDependencyBoundary();
          _compactForBoundedPolicy();
          if (yieldBetweenDecodes && _hasDueItem) {
            await Future<void>.delayed(Duration.zero);
          }
          continue;
        }
        late R result;
        try {
          result = await Future<R>.sync(() => _decode(item));
        } catch (error, stackTrace) {
          if (generation == _generation && !_disposed) {
            if (presentationMayBeReordered) {
              presentLatestReordered();
            } else {
              presentLatest();
            }
            // Keep the failed item as nextIndex. A caller may explicitly retry
            // after fixing/rebuilding state; timer ticks must not spin on it.
            _requestedThroughMs = null;
            _notifyQueueStateChanged();
            _onDecodeError(item, error, stackTrace);
          }
          return;
        }

        if (generation != _generation || _disposed || index != _nextIndex) {
          return;
        }
        _nextIndex = index + 1;
        _refreshDependencyBoundary();
        _compactForBoundedPolicy();
        if (presentationMayBeReordered) {
          _pendingPresentations.add(
            _PendingPresentation<T, R>(
              decodeIndex: index,
              timestampMs: _timestampOf(item),
              item: item,
              result: result,
            ),
          );
          coalesceDueReorderedPresentations();
          decodedSinceReorderedPresentation++;
          // A software decoder can remain permanently behind a 60 fps audio
          // clock. Publish a bounded latest snapshot during that catch-up so
          // obsolete full-resolution frames are released and adaptive quality
          // receives timely lateness feedback instead of waiting for an
          // unreachable drain tail.
          if (decodedSinceReorderedPresentation >= 8) {
            presentLatestReordered();
          }
        } else {
          latestItem = item;
          latestResult = result;
          decodedAny = true;
        }
        if (yieldBetweenDecodes && _hasDueItem) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      if (presentationMayBeReordered) {
        presentLatestReordered();
      } else {
        presentLatest();
      }
      if (generation == _generation && !_disposed) {
        _reportDrainedIfNeeded();
        _notifyQueueStateChanged();
      }
    } finally {
      _draining = false;
      _activeDrain = null;
      // replaceQueue/seekToIndex may invalidate an awaited decode and receive
      // a new clock request before it returns. Start that new generation here.
      _ensureDrain();
    }
  }

  void _reportDrainedIfNeeded() {
    if (!_queueFinal ||
        !_hasEverContainedItems ||
        _nextIndex != endIndex ||
        _pendingPresentations.isNotEmpty ||
        _reportedDrained) {
      return;
    }
    _reportedDrained = true;
    _onQueueDrained?.call();
  }

  void _refreshDependencyBoundary() {
    final isBoundary = _isDependencyBoundary;
    if (isBoundary == null || _items.isEmpty) {
      _latestDependencyBoundaryIndex = null;
      return;
    }

    int? latest;
    final inclusiveEnd = _nextIndex < endIndex ? _nextIndex : endIndex - 1;
    for (var index = _firstRetainedIndex; index <= inclusiveEnd; index++) {
      if (isBoundary(itemAt(index))) latest = index;
    }
    _latestDependencyBoundaryIndex = latest;
  }

  void _compactForBoundedPolicy() {
    if (maxResidentItems == null || _items.isEmpty) return;
    compactConsumedBefore(_nextIndex);
  }

  void _updateAppendCapacity() {
    final hasCapacity = hasAppendCapacity;
    final becameAvailable = !_lastHadAppendCapacity && hasCapacity;
    // Publish the new value before invoking application code. A producer is
    // allowed to append synchronously from the callback and may fill the queue
    // again; the nested update must observe the current state.
    _lastHadAppendCapacity = hasCapacity;
    if (becameAvailable && maxResidentItems != null) {
      _onAppendCapacityAvailable?.call(remainingItemCapacity!);
    }
  }

  void _notifyQueueStateChanged() {
    final state = queueState;
    if (state == _lastQueueState) return;
    _lastQueueState = state;
    _onQueueStateChanged?.call(state);
  }
}

final class _PendingPresentation<T, R> {
  const _PendingPresentation({
    required this.decodeIndex,
    required this.timestampMs,
    required this.item,
    required this.result,
  });

  final int decodeIndex;
  final int timestampMs;
  final T item;
  final R result;
}
