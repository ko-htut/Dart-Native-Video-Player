import 'dart:async';
import 'dart:typed_data';

import 'hls.dart';

/// Default upper bound for one accepted HLS media-segment response (32 MiB).
const int defaultHlsMaxSegmentBytes = 32 * 1024 * 1024;

/// Fetches the bytes for one fully resolved HLS segment URI.
typedef HlsSegmentByteFetcher = Future<Uint8List> Function(Uri uri);

/// Selects the delay before retrying a failed segment fetch.
///
/// [failedAttempt] is one-based: a value of `1` means that the initial fetch
/// failed and the loader is about to make its first retry.
typedef HlsSegmentRetryBackoff =
    Duration Function(HlsSegment segment, int failedAttempt, Object error);

/// Decides whether a failed segment fetch is safe to retry.
///
/// [failedAttempt] is the one-based attempt that just failed. Returning false
/// makes the failure terminal immediately, without backoff or another fetch.
typedef HlsSegmentRetryPredicate =
    bool Function(HlsSegment segment, int failedAttempt, Object error);

/// Waits for a retry delay. Tests can inject a deterministic implementation.
typedef HlsSegmentRetrySleeper = Future<void> Function(Duration delay);

/// Default retry classification, preserving the loader's original behavior.
bool defaultHlsSegmentRetryPredicate(
  HlsSegment segment,
  int failedAttempt,
  Object error,
) => true;

/// The deterministic retry policy used by [HlsSegmentLoader] by default.
///
/// Delays start at 250 ms, double after every failed attempt, and are capped at
/// four seconds. No random jitter is used so callers can reproduce behavior.
Duration defaultHlsSegmentRetryBackoff(
  HlsSegment segment,
  int failedAttempt,
  Object error,
) {
  var exponent = failedAttempt - 1;
  if (exponent < 0) exponent = 0;
  if (exponent > 4) exponent = 4;
  return Duration(milliseconds: 250 * (1 << exponent));
}

Future<void> _defaultRetrySleeper(Duration delay) =>
    Future<void>.delayed(delay);

/// One segment yielded by [HlsSegmentLoader].
final class HlsLoadedSegment {
  const HlsLoadedSegment({
    required this.segment,
    required this.bytes,
    required this.attempts,
  });

  /// Playlist metadata for these bytes.
  final HlsSegment segment;

  /// The fetched transport-stream (or other HLS media segment) bytes.
  final Uint8List bytes;

  /// Number of fetch attempts used, including the successful attempt.
  final int attempts;

  Uri get uri => segment.uri;
  int get sequence => segment.sequence;
  double get duration => segment.duration;
  int get discontinuitySequence => segment.discontinuitySequence;
}

/// A terminal failure to fetch one HLS segment within the retry budget.
final class HlsSegmentLoadException implements Exception {
  const HlsSegmentLoadException({
    required this.segment,
    required this.attempts,
    required this.cause,
    required this.causeStackTrace,
  });

  final HlsSegment segment;
  final int attempts;
  final Object cause;
  final StackTrace causeStackTrace;

  @override
  String toString() =>
      'HlsSegmentLoadException: failed media sequence ${segment.sequence} '
      '(${segment.uri}) after $attempts attempt${attempts == 1 ? '' : 's'}: '
      '$cause';
}

/// A successful fetch whose response is too large to retain safely.
///
/// This is always non-retryable: downloading the same URI again cannot make
/// the already-valid response smaller.
final class HlsSegmentTooLargeException implements Exception {
  const HlsSegmentTooLargeException({
    required this.segment,
    required this.actualBytes,
    required this.maxBytes,
  });

  final HlsSegment segment;
  final int actualBytes;
  final int maxBytes;

  @override
  String toString() =>
      'HlsSegmentTooLargeException: media sequence ${segment.sequence} '
      '(${segment.uri}) returned $actualBytes bytes; limit is $maxBytes bytes';
}

/// Incrementally fetches a finite HLS playlist snapshot with bounded memory.
///
/// Fetches run concurrently up to [prefetchWindow], while events are always
/// emitted in ascending media-sequence order. The window counts both in-flight
/// requests and completed byte results waiting for an earlier sequence, so the
/// loader never retains the entire VOD. Each accepted result is additionally
/// capped by [maxSegmentBytes], bounding retained segment payloads to at most
/// `prefetchWindow * maxSegmentBytes`. Pausing the stream applies backpressure:
/// already-started requests may finish, but no new request starts until resume.
///
/// This loader deliberately owns no playlist-refresh policy. Phase-2 VOD code
/// passes an `#EXT-X-ENDLIST` playlist; future live-HLS code can pass each
/// finite, de-duplicated playlist snapshot through a higher-level coordinator.
///
/// A fetch already executing when [cancel] is called cannot be forcibly aborted
/// through Dart's [Future] API. Its eventual result is ignored, retries stop,
/// and no further segment is scheduled. A network fetcher may additionally
/// implement transport-level cancellation if required.
final class HlsSegmentLoader {
  factory HlsSegmentLoader({
    required HlsMediaPlaylist playlist,
    required HlsSegmentByteFetcher fetcher,
    int prefetchWindow = 4,
    int maxAttempts = 3,
    int maxSegmentBytes = defaultHlsMaxSegmentBytes,
    HlsSegmentRetryPredicate? retryPredicate,
    HlsSegmentRetryBackoff? retryBackoff,
    HlsSegmentRetrySleeper? retrySleeper,
  }) => HlsSegmentLoader.fromSegments(
    segments: playlist.segments,
    fetcher: fetcher,
    prefetchWindow: prefetchWindow,
    maxAttempts: maxAttempts,
    maxSegmentBytes: maxSegmentBytes,
    retryPredicate: retryPredicate,
    retryBackoff: retryBackoff,
    retrySleeper: retrySleeper,
  );

  HlsSegmentLoader.fromSegments({
    required Iterable<HlsSegment> segments,
    required HlsSegmentByteFetcher fetcher,
    this.prefetchWindow = 4,
    this.maxAttempts = 3,
    this.maxSegmentBytes = defaultHlsMaxSegmentBytes,
    HlsSegmentRetryPredicate? retryPredicate,
    HlsSegmentRetryBackoff? retryBackoff,
    HlsSegmentRetrySleeper? retrySleeper,
  }) : _segments = _orderAndValidateSegments(segments),
       _fetcher = fetcher,
       _retryPredicate = retryPredicate ?? defaultHlsSegmentRetryPredicate,
       _retryBackoff = retryBackoff ?? defaultHlsSegmentRetryBackoff,
       _retrySleeper = retrySleeper ?? _defaultRetrySleeper {
    if (prefetchWindow <= 0) {
      throw ArgumentError.value(
        prefetchWindow,
        'prefetchWindow',
        'must be > 0',
      );
    }
    if (maxAttempts <= 0) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be > 0');
    }
    if (maxSegmentBytes <= 0) {
      throw ArgumentError.value(
        maxSegmentBytes,
        'maxSegmentBytes',
        'must be > 0',
      );
    }

    _controller = StreamController<HlsLoadedSegment>(
      sync: true,
      onListen: _handleListen,
      onPause: _handlePause,
      onResume: _handleResume,
      onCancel: _handleSubscriptionCancel,
    );
  }

  final List<HlsSegment> _segments;
  final HlsSegmentByteFetcher _fetcher;
  final HlsSegmentRetryPredicate _retryPredicate;
  final HlsSegmentRetryBackoff _retryBackoff;
  final HlsSegmentRetrySleeper _retrySleeper;

  final Completer<void> _stopSignal = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final Map<int, Future<_SegmentFetchOutcome>> _pending =
      <int, Future<_SegmentFetchOutcome>>{};

  late final StreamController<HlsLoadedSegment> _controller;

  int _nextToLaunch = 0;
  int _nextToEmit = 0;
  bool _pumpRunning = false;
  bool _pumpAgain = false;
  bool _stopped = false;
  bool _finished = false;
  bool _cancelled = false;
  bool _disposed = false;

  /// Maximum number of fetched or in-flight segments retained by the loader.
  final int prefetchWindow;

  /// Maximum fetch attempts for each segment, including the initial attempt.
  final int maxAttempts;

  /// Maximum accepted byte length of one segment response.
  final int maxSegmentBytes;

  /// Immutable metadata in the exact order in which events will be emitted.
  List<HlsSegment> get segments => _segments;

  /// Single-subscription stream of ordered segment metadata and bytes.
  Stream<HlsLoadedSegment> get stream => _controller.stream;

  /// Completes when the loader finishes, fails, or is cancelled.
  Future<void> get done => _done.future;

  bool get isCancelled => _cancelled;
  bool get isDisposed => _disposed;

  /// Stops retries and prevents any new fetch from starting.
  Future<void> cancel() async {
    if (_finished) return;
    _requestStop(cancelled: true);
    _finish();
  }

  /// Permanently releases this loader. Equivalent to [cancel] and idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
  }

  void _handleListen() {
    if (_stopped) {
      _finish();
      return;
    }
    scheduleMicrotask(_requestPump);
  }

  void _handlePause() {
    // The pump checks StreamController.isPaused before scheduling or emitting.
  }

  void _handleResume() => _requestPump();

  void _handleSubscriptionCancel() {
    if (_finished) return;
    _requestStop(cancelled: true);
    _finish();
  }

  void _requestPump() {
    if (_finished || _stopped || _controller.isPaused) return;
    if (_pumpRunning) {
      _pumpAgain = true;
      return;
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumpRunning || _finished || _stopped) return;
    _pumpRunning = true;
    try {
      do {
        _pumpAgain = false;
        while (!_finished && !_stopped && !_controller.isPaused) {
          _fillPrefetchWindow();

          if (_nextToEmit >= _segments.length) {
            _requestStop(cancelled: false);
            _finish();
            break;
          }

          final pending = _pending[_nextToEmit];
          if (pending == null) {
            // This can only occur after cancellation cleared the window.
            break;
          }

          final outcome = await Future.any<_SegmentFetchOutcome>(
            <Future<_SegmentFetchOutcome>>[
              pending,
              _stopSignal.future.then(
                (_) => const _SegmentFetchOutcome.cancelled(),
              ),
            ],
          );

          if (_finished || _stopped) break;
          if (_controller.isPaused) {
            // Keep the completed future resident in the same bounded slot.
            break;
          }

          _pending.remove(_nextToEmit);
          if (outcome.isCancelled) {
            _requestStop(cancelled: true);
            _finish();
            break;
          }

          final error = outcome.error;
          if (error != null) {
            _controller.addError(error, error.causeStackTrace);
            _requestStop(cancelled: false);
            _finish();
            break;
          }

          final loaded = outcome.loaded!;
          _nextToEmit++;
          _controller.add(loaded);
        }
      } while (_pumpAgain && !_finished && !_stopped && !_controller.isPaused);
    } finally {
      _pumpRunning = false;
      if (_pumpAgain && !_finished && !_stopped && !_controller.isPaused) {
        scheduleMicrotask(_requestPump);
      }
    }
  }

  void _fillPrefetchWindow() {
    while (!_stopped &&
        !_controller.isPaused &&
        _pending.length < prefetchWindow &&
        _nextToLaunch < _segments.length) {
      final index = _nextToLaunch++;
      _pending[index] = _fetchWithRetry(_segments[index]);
    }
  }

  Future<_SegmentFetchOutcome> _fetchWithRetry(HlsSegment segment) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_stopped) return const _SegmentFetchOutcome.cancelled();

      try {
        final bytes = await _fetcher(segment.uri);
        if (_stopped) return const _SegmentFetchOutcome.cancelled();
        if (bytes.lengthInBytes > maxSegmentBytes) {
          final cause = HlsSegmentTooLargeException(
            segment: segment,
            actualBytes: bytes.lengthInBytes,
            maxBytes: maxSegmentBytes,
          );
          return _SegmentFetchOutcome.failed(
            HlsSegmentLoadException(
              segment: segment,
              attempts: attempt,
              cause: cause,
              causeStackTrace: StackTrace.current,
            ),
          );
        }
        return _SegmentFetchOutcome.loaded(
          HlsLoadedSegment(segment: segment, bytes: bytes, attempts: attempt),
        );
      } catch (error, stackTrace) {
        if (_stopped) return const _SegmentFetchOutcome.cancelled();

        bool retryable;
        try {
          retryable = _retryPredicate(segment, attempt, error);
        } catch (predicateError, predicateStackTrace) {
          return _SegmentFetchOutcome.failed(
            HlsSegmentLoadException(
              segment: segment,
              attempts: attempt,
              cause: predicateError,
              causeStackTrace: predicateStackTrace,
            ),
          );
        }

        if (!retryable || attempt == maxAttempts) {
          return _SegmentFetchOutcome.failed(
            HlsSegmentLoadException(
              segment: segment,
              attempts: attempt,
              cause: error,
              causeStackTrace: stackTrace,
            ),
          );
        }

        Duration delay;
        try {
          delay = _retryBackoff(segment, attempt, error);
          if (delay.isNegative) {
            throw ArgumentError.value(
              delay,
              'retryBackoff',
              'must not return a negative duration',
            );
          }
        } catch (backoffError, backoffStackTrace) {
          return _SegmentFetchOutcome.failed(
            HlsSegmentLoadException(
              segment: segment,
              attempts: attempt,
              cause: backoffError,
              causeStackTrace: backoffStackTrace,
            ),
          );
        }

        final waitOutcome = await Future.any<_RetryWaitOutcome>(
          <Future<_RetryWaitOutcome>>[
            _waitForRetry(delay),
            _stopSignal.future.then((_) => const _RetryWaitOutcome.cancelled()),
          ],
        );
        if (waitOutcome.isCancelled || _stopped) {
          return const _SegmentFetchOutcome.cancelled();
        }
        final waitError = waitOutcome.error;
        if (waitError != null) {
          return _SegmentFetchOutcome.failed(
            HlsSegmentLoadException(
              segment: segment,
              attempts: attempt,
              cause: waitError.$1,
              causeStackTrace: waitError.$2,
            ),
          );
        }
      }
    }

    throw StateError('unreachable retry loop');
  }

  Future<_RetryWaitOutcome> _waitForRetry(Duration delay) async {
    try {
      await _retrySleeper(delay);
      return const _RetryWaitOutcome.completed();
    } catch (error, stackTrace) {
      return _RetryWaitOutcome.failed(error, stackTrace);
    }
  }

  void _requestStop({required bool cancelled}) {
    if (cancelled) _cancelled = true;
    if (_stopped) return;
    _stopped = true;
    _pending.clear();
    _stopSignal.complete();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    unawaited(_controller.close());
    _done.complete();
  }

  static List<HlsSegment> _orderAndValidateSegments(
    Iterable<HlsSegment> segments,
  ) {
    final ordered = segments.toList(growable: false)
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    for (var i = 1; i < ordered.length; i++) {
      if (ordered[i - 1].sequence == ordered[i].sequence) {
        throw ArgumentError(
          'segments contain duplicate media sequence ${ordered[i].sequence}',
        );
      }
    }
    return List<HlsSegment>.unmodifiable(ordered);
  }
}

final class _SegmentFetchOutcome {
  const _SegmentFetchOutcome.loaded(this.loaded)
    : error = null,
      isCancelled = false;

  const _SegmentFetchOutcome.failed(this.error)
    : loaded = null,
      isCancelled = false;

  const _SegmentFetchOutcome.cancelled()
    : loaded = null,
      error = null,
      isCancelled = true;

  final HlsLoadedSegment? loaded;
  final HlsSegmentLoadException? error;
  final bool isCancelled;
}

final class _RetryWaitOutcome {
  const _RetryWaitOutcome.completed() : error = null, isCancelled = false;

  const _RetryWaitOutcome.failed(Object error, StackTrace stackTrace)
    : error = (error, stackTrace),
      isCancelled = false;

  const _RetryWaitOutcome.cancelled() : error = null, isCancelled = true;

  final (Object, StackTrace)? error;
  final bool isCancelled;
}
