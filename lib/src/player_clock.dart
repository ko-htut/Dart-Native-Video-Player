import 'dart:async';

typedef PlaybackTimeSource = int Function();

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

  void setTime(int ms) {
    _nowMs = ms;
    if (_playing) {
      _playBaseMs = ms;
      _elapsed
        ..reset()
        ..start();
    }
    onFrameDue?.call(_nowMs);
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
  }
}

typedef SequentialDecode<T, R> = FutureOr<R> Function(T item);
typedef ItemTimestamp<T> = int Function(T item);
typedef LatestDecoded<T, R> = void Function(T item, R result);
typedef DecodeFailure<T> =
    void Function(T item, Object error, StackTrace stackTrace);

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
  }) : _timestampOf = timestampOf,
       _decode = decode,
       _onLatestDecoded = onLatestDecoded,
       _onDecodeError = onDecodeError,
       _onQueueDrained = onQueueDrained;

  final ItemTimestamp<T> _timestampOf;
  final SequentialDecode<T, R> _decode;
  final LatestDecoded<T, R> _onLatestDecoded;
  final DecodeFailure<T> _onDecodeError;
  final void Function()? _onQueueDrained;

  List<T> _items = const [];
  int _nextIndex = 0;
  int _generation = 0;
  int? _requestedThroughMs;
  bool _draining = false;
  bool _reportedDrained = false;
  bool _disposed = false;
  Future<void>? _activeDrain;

  int get nextIndex => _nextIndex;
  int get length => _items.length;
  bool get isDraining => _draining;

  void replaceQueue(List<T> items, {int nextIndex = 0}) {
    if (nextIndex < 0 || nextIndex > items.length) {
      throw RangeError.range(nextIndex, 0, items.length, 'nextIndex');
    }
    _generation++;
    _items = List<T>.unmodifiable(items);
    _nextIndex = nextIndex;
    _requestedThroughMs = null;
    _reportedDrained = false;
  }

  /// Invalidates an in-flight result and sets the next compressed item.
  void seekToIndex(int index) {
    if (index < 0 || index > _items.length) {
      throw RangeError.range(index, 0, _items.length, 'index');
    }
    _generation++;
    _nextIndex = index;
    _requestedThroughMs = null;
    _reportedDrained = false;
  }

  void restart() => seekToIndex(0);

  void requestThrough(int targetMs) {
    if (_disposed) return;
    final previousTarget = _requestedThroughMs;
    if (previousTarget == null || targetMs > previousTarget) {
      _requestedThroughMs = targetMs;
    }
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
    _disposed = true;
    _generation++;
    _requestedThroughMs = null;
    _items = const [];
  }

  bool get _hasDueItem {
    final target = _requestedThroughMs;
    return target != null &&
        _nextIndex < _items.length &&
        _timestampOf(_items[_nextIndex]) <= target;
  }

  void _ensureDrain() {
    if (_disposed || _draining || !_hasDueItem) return;
    final generation = _generation;
    _draining = true;
    _activeDrain = _drain(generation);
  }

  Future<void> _drain(int generation) async {
    var decodedAny = false;
    late T latestItem;
    late R latestResult;

    void presentLatest() {
      if (!decodedAny || generation != _generation || _disposed) return;
      _onLatestDecoded(latestItem, latestResult);
      decodedAny = false;
    }

    try {
      while (generation == _generation && !_disposed && _hasDueItem) {
        final index = _nextIndex;
        final item = _items[index];
        late R result;
        try {
          result = await Future<R>.sync(() => _decode(item));
        } catch (error, stackTrace) {
          if (generation == _generation && !_disposed) {
            presentLatest();
            // Keep the failed item as nextIndex. A caller may explicitly retry
            // after fixing/rebuilding state; timer ticks must not spin on it.
            _requestedThroughMs = null;
            _onDecodeError(item, error, stackTrace);
          }
          return;
        }

        if (generation != _generation || _disposed || index != _nextIndex) {
          return;
        }
        _nextIndex = index + 1;
        latestItem = item;
        latestResult = result;
        decodedAny = true;
      }

      presentLatest();
      if (generation == _generation &&
          !_disposed &&
          _items.isNotEmpty &&
          _nextIndex == _items.length &&
          !_reportedDrained) {
        _reportedDrained = true;
        _onQueueDrained?.call();
      }
    } finally {
      _draining = false;
      _activeDrain = null;
      // replaceQueue/seekToIndex may invalidate an awaited decode and receive
      // a new clock request before it returns. Start that new generation here.
      _ensureDrain();
    }
  }
}
