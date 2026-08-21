import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'hls.dart';

/// Wall clock used to timestamp live-playlist observations.
typedef HlsLivePlaylistClock = DateTime Function();

/// Injectable refresh wait used by [HlsLivePlaylistCoordinator].
typedef HlsLivePlaylistSleeper = Future<void> Function(Duration delay);

const int defaultHlsLiveMaxPlaylistBytes = 1024 * 1024;

/// Lifecycle state of one single-use live-playlist coordinator.
enum HlsLivePlaylistState { idle, running, sealed, failed, cancelled }

/// Bounded cumulative progress for a live media playlist.
final class HlsLivePlaylistProgress {
  const HlsLivePlaylistProgress({
    required this.refreshesCompleted,
    required this.segmentsEmitted,
    required this.initialSegmentsSkipped,
    required this.lastEmittedSequence,
    required this.retainedHistoryCount,
    required this.historyCapacity,
    required this.sealed,
    required this.cancelled,
  });

  final int refreshesCompleted;
  final int segmentsEmitted;

  /// Old segments intentionally omitted from the first non-empty snapshot.
  final int initialSegmentsSkipped;

  final int? lastEmittedSequence;
  final int retainedHistoryCount;
  final int historyCapacity;
  final bool sealed;
  final bool cancelled;
}

/// One ordered delta from [HlsLivePlaylistCoordinator].
///
/// [newSegments] contains only sequences that have not appeared in an earlier
/// update. It can be empty when a refresh is unchanged or when `ENDLIST`
/// seals a playlist without adding a segment. The full media-window metadata
/// is included without retaining the full snapshot.
final class HlsLivePlaylistUpdate {
  const HlsLivePlaylistUpdate({
    required this.epoch,
    required this.fetchedAt,
    required this.mediaSequence,
    required this.windowFirstSequence,
    required this.windowLastSequence,
    required this.windowSegmentCount,
    required this.targetDuration,
    required this.isEndList,
    required this.newSegments,
    required this.nextRefreshDelay,
    required this.progress,
    required this.error,
  });

  /// Caller-owned generation copied from the coordinator constructor.
  final int epoch;

  /// Time at which this playlist response (or terminal state) was observed.
  final DateTime fetchedAt;

  /// `EXT-X-MEDIA-SEQUENCE` from the latest successful snapshot.
  ///
  /// This is null only when the initial fetch fails or is cancelled before a
  /// playlist has been parsed.
  final int? mediaSequence;

  final int? windowFirstSequence;
  final int? windowLastSequence;
  final int windowSegmentCount;

  /// `EXT-X-TARGETDURATION` from the latest successful snapshot.
  final int? targetDuration;

  /// True only when the latest successful snapshot contained `EXT-X-ENDLIST`.
  final bool isEndList;

  /// Newly discovered segments in strictly increasing media-sequence order.
  final List<HlsSegment> newSegments;

  /// Remaining delay at [fetchedAt] before the next reload, or null for a
  /// terminal update. Request time is deducted from the target-based interval.
  final Duration? nextRefreshDelay;

  final HlsLivePlaylistProgress progress;
  final Object? error;

  bool get sealed => progress.sealed;
  bool get cancelled => progress.cancelled;
  bool get isTerminal => sealed || cancelled || error != null;
}

/// Adds refresh-stage context to an I/O, parse, or sleeper failure.
final class HlsLivePlaylistFailure implements Exception {
  const HlsLivePlaylistFailure({required this.stage, required this.cause});

  final String stage;
  final Object cause;

  @override
  String toString() => 'HlsLivePlaylistFailure: $stage failed: $cause';
}

/// The live window advanced past a sequence the consumer had not received.
final class HlsLivePlaylistExpiredGapException implements Exception {
  const HlsLivePlaylistExpiredGapException({
    required this.expectedSequence,
    required this.playlistMediaSequence,
  });

  final int expectedSequence;
  final int playlistMediaSequence;

  @override
  String toString() =>
      'HlsLivePlaylistExpiredGapException: expected media sequence '
      '$expectedSequence, but the live window starts at '
      '$playlistMediaSequence';
}

/// A later response moved the media window or its high edge backwards.
final class HlsLivePlaylistRewindException implements Exception {
  const HlsLivePlaylistRewindException({
    required this.previousMediaSequence,
    required this.currentMediaSequence,
    required this.previousLastSequence,
    required this.currentLastSequence,
  });

  final int previousMediaSequence;
  final int currentMediaSequence;
  final int? previousLastSequence;
  final int? currentLastSequence;

  @override
  String toString() =>
      'HlsLivePlaylistRewindException: media window rewound from '
      '$previousMediaSequence..$previousLastSequence to '
      '$currentMediaSequence..$currentLastSequence';
}

/// `EXT-X-DISCONTINUITY-SEQUENCE` moved to an earlier timestamp epoch.
final class HlsLivePlaylistDiscontinuityRewindException implements Exception {
  const HlsLivePlaylistDiscontinuityRewindException({
    required this.previousDiscontinuitySequence,
    required this.currentDiscontinuitySequence,
  });

  final int previousDiscontinuitySequence;
  final int currentDiscontinuitySequence;

  @override
  String toString() =>
      'HlsLivePlaylistDiscontinuityRewindException: discontinuity sequence '
      'rewound from $previousDiscontinuitySequence to '
      '$currentDiscontinuitySequence';
}

/// Metadata for an already-seen media sequence changed between refreshes.
final class HlsLivePlaylistMutationException implements Exception {
  const HlsLivePlaylistMutationException({
    required this.sequence,
    required this.previousUri,
    required this.currentUri,
    required this.previousDuration,
    required this.currentDuration,
    required this.previousDiscontinuitySequence,
    required this.currentDiscontinuitySequence,
  });

  final int sequence;
  final Uri previousUri;
  final Uri currentUri;
  final double previousDuration;
  final double currentDuration;
  final int previousDiscontinuitySequence;
  final int currentDiscontinuitySequence;

  @override
  String toString() =>
      'HlsLivePlaylistMutationException: metadata changed for media '
      'sequence $sequence '
      '(uri $previousUri -> $currentUri, '
      'duration $previousDuration -> $currentDuration, discontinuity '
      '$previousDiscontinuitySequence -> $currentDiscontinuitySequence)';
}

/// Refreshes one live/event HLS media playlist with finite metadata memory.
///
/// This coordinator deliberately owns playlist discovery only: segment bytes,
/// demuxers, and cross-rendition synchronization remain outside it. A player
/// listens to [updates], then passes each ordered [HlsLivePlaylistUpdate.newSegments]
/// batch to its bounded segment loader. Starting is listener-gated, and pausing
/// the single-subscription stream prevents the next refresh from sleeping or
/// fetching, providing explicit downstream backpressure.
///
/// The first non-empty snapshot emits only its newest
/// [initialHoldBackSegments] when that value is non-null. This starts near the
/// live edge without reporting the intentionally skipped prefix as expired.
/// Pass null to emit the entire initial window.
///
/// [historyCapacity] must cover [maxWindowSegments]. This guarantees that any
/// sequence which can legally overlap the next accepted window still has a
/// fingerprint available for mutation detection, while keeping memory bounded.
/// A changed snapshot reloads after one target duration measured from request
/// start; an unchanged snapshot retries after half a target duration.
final class HlsLivePlaylistCoordinator {
  HlsLivePlaylistCoordinator({
    required this.playlistUri,
    required HlsByteFetcher fetcher,
    this.epoch = 0,
    this.initialHoldBackSegments = 3,
    this.historyCapacity = 256,
    this.maxWindowSegments = 256,
    this.maxPlaylistBytes = defaultHlsLiveMaxPlaylistBytes,
    HlsLivePlaylistClock? clock,
    HlsLivePlaylistSleeper? sleeper,
  }) : _fetcher = fetcher,
       _clock = clock ?? DateTime.now,
       _sleeper = sleeper ?? _defaultSleeper {
    final holdBack = initialHoldBackSegments;
    if (holdBack != null && holdBack <= 0) {
      throw ArgumentError.value(
        holdBack,
        'initialHoldBackSegments',
        'must be > 0 or null',
      );
    }
    if (maxWindowSegments <= 0) {
      throw ArgumentError.value(
        maxWindowSegments,
        'maxWindowSegments',
        'must be > 0',
      );
    }
    if (maxPlaylistBytes <= 0) {
      throw ArgumentError.value(
        maxPlaylistBytes,
        'maxPlaylistBytes',
        'must be > 0',
      );
    }
    if (historyCapacity < maxWindowSegments) {
      throw ArgumentError.value(
        historyCapacity,
        'historyCapacity',
        'must be >= maxWindowSegments ($maxWindowSegments)',
      );
    }

    _updates = StreamController<HlsLivePlaylistUpdate>(
      sync: true,
      onListen: _handleUpdateListen,
      onPause: _handleUpdatePause,
      onResume: _handleUpdateResume,
      onCancel: _handleUpdateCancel,
    );
  }

  final Uri playlistUri;
  final int epoch;

  /// Number of newest segments selected from the initial non-empty window.
  /// Null selects the entire initial window.
  final int? initialHoldBackSegments;

  /// Maximum number of fingerprints retained for overlap validation.
  final int historyCapacity;

  /// Hard bound on segment metadata accepted in a single playlist response.
  final int maxWindowSegments;

  /// Hard bound checked before playlist bytes are decoded into text/metadata.
  final int maxPlaylistBytes;

  final HlsByteFetcher _fetcher;
  final HlsLivePlaylistClock _clock;
  final HlsLivePlaylistSleeper _sleeper;

  late final StreamController<HlsLivePlaylistUpdate> _updates;
  final Completer<void> _done = Completer<void>();
  final LinkedHashMap<int, _HlsSegmentFingerprint> _history =
      LinkedHashMap<int, _HlsSegmentFingerprint>();

  HlsLivePlaylistState _state = HlsLivePlaylistState.idle;
  Object? _error;
  StackTrace? _errorStackTrace;
  bool _started = false;
  bool _cancelled = false;
  bool _disposed = false;
  bool _closed = false;
  bool _terminalEmitted = false;
  bool _anchored = false;
  bool _updatesPaused = true;
  Completer<void>? _updateResumeGate;
  void Function()? _cancelActiveWait;
  int _runToken = 0;
  int _refreshesCompleted = 0;
  int _segmentsEmitted = 0;
  int _initialSegmentsSkipped = 0;
  int? _lastEmittedSequence;
  int? _lastMediaSequence;
  int? _lastWindowFirstSequence;
  int? _lastWindowLastSequence;
  int _lastWindowSegmentCount = 0;
  int? _lastTargetDuration;
  int? _lastDiscontinuitySequence;

  Stream<HlsLivePlaylistUpdate> get updates => _updates.stream;
  Future<void> get done => _done.future;
  HlsLivePlaylistState get state => _state;
  Object? get error => _error;
  StackTrace? get errorStackTrace => _errorStackTrace;
  bool get isStarted => _started;
  bool get isSealed => _state == HlsLivePlaylistState.sealed;
  bool get isCancelled => _cancelled;
  bool get isDisposed => _disposed;

  /// This metadata-only coordinator never owns media response bytes.
  int get retainedSegmentByteCount => 0;

  int get retainedSegmentMetadataCount => _history.length;

  HlsLivePlaylistProgress get progress => HlsLivePlaylistProgress(
    refreshesCompleted: _refreshesCompleted,
    segmentsEmitted: _segmentsEmitted,
    initialSegmentsSkipped: _initialSegmentsSkipped,
    lastEmittedSequence: _lastEmittedSequence,
    retainedHistoryCount: _history.length,
    historyCapacity: historyCapacity,
    sealed: isSealed,
    cancelled: _cancelled,
  );

  /// Starts this single-use coordinator.
  ///
  /// No request begins until the first [updates] listener is attached.
  Future<void> start() {
    if (_started || _closed) return done;
    _started = true;
    _state = HlsLivePlaylistState.running;
    final token = ++_runToken;
    unawaited(_run(token));
    return done;
  }

  /// Cancels an in-flight fetch or refresh wait and closes [updates] promptly.
  Future<void> cancel() async {
    if (_closed) return;
    if (_cancelled ||
        _state == HlsLivePlaylistState.sealed ||
        _state == HlsLivePlaylistState.failed) {
      await done;
      return;
    }
    _cancelled = true;
    _state = HlsLivePlaylistState.cancelled;
    _runToken++;
    _cancelActiveWait?.call();
    _releaseUpdatePause();
    if (!_started) {
      _emitTerminal();
      _close();
    }
    await done;
  }

  /// Permanently releases this coordinator. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
  }

  Future<void> _run(int token) async {
    try {
      while (_isCurrent(token)) {
        await _waitForUpdateResume(token);
        if (!_isCurrent(token)) break;

        final refreshStartedAt = _clock();
        final fetchResult = await _awaitCancellable(
          fetchMediaPlaylist(
            playlistUri,
            byteFetcher: _fetchPlaylistBytes,
            requireEndList: false,
          ),
        );
        if (!_isCurrent(token) || fetchResult.cancelled) break;
        if (fetchResult.error != null) {
          _fail(
            HlsLivePlaylistFailure(
              stage: 'playlist fetch/parse',
              cause: fetchResult.error!,
            ),
            fetchResult.stackTrace ?? StackTrace.current,
          );
          break;
        }

        final playlist = fetchResult.value!;
        final fetchedAt = _clock();
        final ingestResult = _ingest(playlist);
        final refreshInterval = playlist.isEndList
            ? null
            : _refreshDelay(
                playlist.targetDuration,
                changed: ingestResult.snapshotChanged,
              );
        final nextRefreshDelay = refreshInterval == null
            ? null
            : _remainingRefreshDelay(
                startedAt: refreshStartedAt,
                interval: refreshInterval,
                now: fetchedAt,
              );
        if (playlist.isEndList) {
          _state = HlsLivePlaylistState.sealed;
        }
        _emitSnapshot(
          playlist: playlist,
          fetchedAt: fetchedAt,
          newSegments: ingestResult.newSegments,
          nextRefreshDelay: nextRefreshDelay,
        );
        if (playlist.isEndList) break;

        await _waitForUpdateResume(token);
        if (!_isCurrent(token)) break;
        final remainingDelay = _remainingRefreshDelay(
          startedAt: refreshStartedAt,
          interval: refreshInterval!,
          now: _clock(),
        );
        final sleepResult = await _awaitCancellable(_sleeper(remainingDelay));
        if (!_isCurrent(token) || sleepResult.cancelled) break;
        if (sleepResult.error != null) {
          _fail(
            HlsLivePlaylistFailure(
              stage: 'playlist refresh wait',
              cause: sleepResult.error!,
            ),
            sleepResult.stackTrace ?? StackTrace.current,
          );
          break;
        }
      }
    } catch (error, stackTrace) {
      if (_isCurrent(token) && _error == null) {
        _fail(error, stackTrace);
      }
    } finally {
      if (!_closed) {
        if (_cancelled || !_isCurrent(token)) {
          _cancelled = true;
          _state = HlsLivePlaylistState.cancelled;
          _emitTerminal();
        }
        _close();
      }
    }
  }

  _SnapshotIngestResult _ingest(HlsMediaPlaylist playlist) {
    _validateSnapshot(playlist);

    final segments = playlist.segments;
    final windowFirst = segments.isEmpty ? null : segments.first.sequence;
    final windowLast = segments.isEmpty ? null : segments.last.sequence;
    final previousMediaSequence = _lastMediaSequence;
    final previousWindowLast = _lastWindowLastSequence;
    final previousWindowCount = _lastWindowSegmentCount;
    final previousDiscontinuitySequence = _lastDiscontinuitySequence;
    final previousHighEdge = previousMediaSequence == null
        ? null
        : previousWindowLast ?? previousMediaSequence - 1;
    final currentHighEdge = windowLast ?? playlist.mediaSequence - 1;
    if (previousMediaSequence != null &&
        (playlist.mediaSequence < previousMediaSequence ||
            (previousHighEdge != null && currentHighEdge < previousHighEdge))) {
      throw HlsLivePlaylistRewindException(
        previousMediaSequence: previousMediaSequence,
        currentMediaSequence: playlist.mediaSequence,
        previousLastSequence: previousWindowLast,
        currentLastSequence: windowLast,
      );
    }
    if (previousDiscontinuitySequence != null &&
        playlist.discontinuitySequence < previousDiscontinuitySequence) {
      throw HlsLivePlaylistDiscontinuityRewindException(
        previousDiscontinuitySequence: previousDiscontinuitySequence,
        currentDiscontinuitySequence: playlist.discontinuitySequence,
      );
    }

    final lastEmitted = _lastEmittedSequence;
    if (_anchored &&
        lastEmitted != null &&
        playlist.mediaSequence > lastEmitted + 1) {
      throw HlsLivePlaylistExpiredGapException(
        expectedSequence: lastEmitted + 1,
        playlistMediaSequence: playlist.mediaSequence,
      );
    }

    for (final segment in segments) {
      final previous = _history[segment.sequence];
      if (previous != null && !previous.matches(segment)) {
        throw HlsLivePlaylistMutationException(
          sequence: segment.sequence,
          previousUri: previous.uri,
          currentUri: segment.uri,
          previousDuration: previous.duration,
          currentDuration: segment.duration,
          previousDiscontinuitySequence: previous.discontinuitySequence,
          currentDiscontinuitySequence: segment.discontinuitySequence,
        );
      }
    }

    late final List<HlsSegment> discovered;
    if (!_anchored && segments.isNotEmpty) {
      final holdBack = initialHoldBackSegments;
      final startIndex = holdBack == null || holdBack >= segments.length
          ? 0
          : segments.length - holdBack;
      _initialSegmentsSkipped = startIndex;
      discovered = segments.sublist(startIndex);
    } else if (lastEmitted == null) {
      discovered = const <HlsSegment>[];
    } else {
      discovered = segments
          .where((segment) => segment.sequence > lastEmitted)
          .toList(growable: false);
      if (discovered.isNotEmpty &&
          discovered.first.sequence != lastEmitted + 1) {
        throw HlsLivePlaylistExpiredGapException(
          expectedSequence: lastEmitted + 1,
          playlistMediaSequence: discovered.first.sequence,
        );
      }
    }

    for (final segment in segments) {
      _history.putIfAbsent(
        segment.sequence,
        () => _HlsSegmentFingerprint.fromSegment(segment),
      );
    }
    while (_history.length > historyCapacity) {
      _history.remove(_history.keys.first);
    }

    if (segments.isNotEmpty && !_anchored) _anchored = true;
    if (discovered.isNotEmpty) {
      _lastEmittedSequence = discovered.last.sequence;
      _segmentsEmitted += discovered.length;
    }
    _refreshesCompleted++;
    _lastMediaSequence = playlist.mediaSequence;
    _lastWindowFirstSequence = windowFirst;
    _lastWindowLastSequence = windowLast;
    _lastWindowSegmentCount = segments.length;
    _lastTargetDuration = playlist.targetDuration;
    _lastDiscontinuitySequence = playlist.discontinuitySequence;
    final snapshotChanged =
        previousMediaSequence == null ||
        previousMediaSequence != playlist.mediaSequence ||
        previousWindowLast != windowLast ||
        previousWindowCount != segments.length ||
        previousDiscontinuitySequence != playlist.discontinuitySequence;
    return _SnapshotIngestResult(
      newSegments: List<HlsSegment>.unmodifiable(discovered),
      snapshotChanged: snapshotChanged,
    );
  }

  void _validateSnapshot(HlsMediaPlaylist playlist) {
    if (playlist.targetDuration <= 0) {
      throw FormatException(
        'Live HLS media playlist has invalid EXT-X-TARGETDURATION '
        '${playlist.targetDuration}',
      );
    }
    final previousTargetDuration = _lastTargetDuration;
    if (previousTargetDuration != null &&
        playlist.targetDuration != previousTargetDuration) {
      throw FormatException(
        'Live HLS EXT-X-TARGETDURATION changed from '
        '$previousTargetDuration to ${playlist.targetDuration}',
      );
    }
    if (playlist.mediaSequence < 0) {
      throw FormatException(
        'Live HLS media playlist has negative EXT-X-MEDIA-SEQUENCE '
        '${playlist.mediaSequence}',
      );
    }
    if (playlist.discontinuitySequence < 0) {
      throw FormatException(
        'Live HLS media playlist has negative '
        'EXT-X-DISCONTINUITY-SEQUENCE '
        '${playlist.discontinuitySequence}',
      );
    }
    if (playlist.segments.length > maxWindowSegments) {
      throw FormatException(
        'Live HLS media window contains ${playlist.segments.length} '
        'segments, exceeding maxWindowSegments=$maxWindowSegments',
      );
    }
    for (var index = 0; index < playlist.segments.length; index++) {
      final segment = playlist.segments[index];
      final expected = playlist.mediaSequence + index;
      if (segment.sequence != expected) {
        throw FormatException(
          'Live HLS media window is not contiguous: expected sequence '
          '$expected, got ${segment.sequence}',
        );
      }
      if (!segment.duration.isFinite || segment.duration <= 0) {
        throw FormatException(
          'Live HLS media sequence ${segment.sequence} has invalid '
          'duration ${segment.duration}',
        );
      }
    }
  }

  void _emitSnapshot({
    required HlsMediaPlaylist playlist,
    required DateTime fetchedAt,
    required List<HlsSegment> newSegments,
    required Duration? nextRefreshDelay,
  }) {
    if (_closed) return;
    if (playlist.isEndList) _terminalEmitted = true;
    _updates.add(
      HlsLivePlaylistUpdate(
        epoch: epoch,
        fetchedAt: fetchedAt,
        mediaSequence: playlist.mediaSequence,
        windowFirstSequence: playlist.segments.isEmpty
            ? null
            : playlist.segments.first.sequence,
        windowLastSequence: playlist.segments.isEmpty
            ? null
            : playlist.segments.last.sequence,
        windowSegmentCount: playlist.segments.length,
        targetDuration: playlist.targetDuration,
        isEndList: playlist.isEndList,
        newSegments: newSegments,
        nextRefreshDelay: nextRefreshDelay,
        progress: progress,
        error: null,
      ),
    );
  }

  void _emitTerminal() {
    if (_closed || _terminalEmitted) return;
    // Commit before synchronously notifying the listener. Its callback may
    // reentrantly cancel the coordinator or its own stream subscription.
    _terminalEmitted = true;
    _updates.add(
      HlsLivePlaylistUpdate(
        epoch: epoch,
        fetchedAt: _clock(),
        mediaSequence: _lastMediaSequence,
        windowFirstSequence: _lastWindowFirstSequence,
        windowLastSequence: _lastWindowLastSequence,
        windowSegmentCount: _lastWindowSegmentCount,
        targetDuration: _lastTargetDuration,
        isEndList: isSealed,
        newSegments: const <HlsSegment>[],
        nextRefreshDelay: null,
        progress: progress,
        error: _error,
      ),
    );
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_error != null || _closed) return;
    _error = error;
    _errorStackTrace = stackTrace;
    _state = HlsLivePlaylistState.failed;
    _emitTerminal();
  }

  Future<Uint8List> _fetchPlaylistBytes(Uri uri) async {
    final bytes = await _fetcher(uri);
    if (bytes.length > maxPlaylistBytes) {
      throw FormatException(
        'Live HLS playlist response contains ${bytes.length} bytes, '
        'exceeding maxPlaylistBytes=$maxPlaylistBytes',
      );
    }
    return bytes;
  }

  Future<_CancellableResult<T>> _awaitCancellable<T>(Future<T> future) async {
    final result = Completer<_CancellableResult<T>>();

    void settle(_CancellableResult<T> value) {
      if (!result.isCompleted) result.complete(value);
    }

    void cancelWait() => settle(_CancellableResult<T>.cancelled());

    // Only one fetch or sleep can be active. Replacing and clearing this
    // callback avoids accumulating listeners on a never-completed global
    // cancellation Future during a long-running live stream.
    _cancelActiveWait = cancelWait;
    future.then<void>(
      (value) => settle(_CancellableResult<T>.value(value)),
      onError: (Object error, StackTrace stackTrace) =>
          settle(_CancellableResult<T>.error(error, stackTrace)),
    );
    if (_cancelled) cancelWait();

    try {
      return await result.future;
    } finally {
      if (identical(_cancelActiveWait, cancelWait)) {
        _cancelActiveWait = null;
      }
    }
  }

  bool _isCurrent(int token) => !_cancelled && !_closed && token == _runToken;

  Future<void> _waitForUpdateResume(int token) async {
    while (_updatesPaused && _isCurrent(token)) {
      final gate = _updateResumeGate ??= Completer<void>();
      await gate.future;
    }
  }

  void _handleUpdateListen() => _releaseUpdatePause();

  void _handleUpdatePause() {
    if (_closed) return;
    _updatesPaused = true;
    _updateResumeGate ??= Completer<void>();
  }

  void _handleUpdateResume() => _releaseUpdatePause();

  Future<void> _handleUpdateCancel() async {
    if (_closed) return;
    await cancel();
  }

  void _releaseUpdatePause() {
    _updatesPaused = false;
    final gate = _updateResumeGate;
    _updateResumeGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _releaseUpdatePause();
    unawaited(_updates.close());
    if (!_done.isCompleted) _done.complete();
  }

  static Future<void> _defaultSleeper(Duration delay) =>
      Future<void>.delayed(delay);

  static Duration _refreshDelay(int targetDuration, {required bool changed}) {
    final microseconds = targetDuration * Duration.microsecondsPerSecond;
    return Duration(microseconds: changed ? microseconds : microseconds ~/ 2);
  }

  static Duration _remainingRefreshDelay({
    required DateTime startedAt,
    required Duration interval,
    required DateTime now,
  }) {
    final elapsed = now.difference(startedAt);
    if (elapsed <= Duration.zero) return interval;
    if (elapsed >= interval) return Duration.zero;
    return interval - elapsed;
  }
}

final class _SnapshotIngestResult {
  const _SnapshotIngestResult({
    required this.newSegments,
    required this.snapshotChanged,
  });

  final List<HlsSegment> newSegments;
  final bool snapshotChanged;
}

final class _HlsSegmentFingerprint {
  const _HlsSegmentFingerprint({
    required this.uri,
    required this.duration,
    required this.discontinuitySequence,
  });

  factory _HlsSegmentFingerprint.fromSegment(HlsSegment segment) =>
      _HlsSegmentFingerprint(
        uri: segment.uri,
        duration: segment.duration,
        discontinuitySequence: segment.discontinuitySequence,
      );

  final Uri uri;
  final double duration;
  final int discontinuitySequence;

  bool matches(HlsSegment segment) =>
      uri == segment.uri &&
      duration == segment.duration &&
      discontinuitySequence == segment.discontinuitySequence;
}

final class _CancellableResult<T> {
  const _CancellableResult.value(this.value)
    : cancelled = false,
      error = null,
      stackTrace = null;

  const _CancellableResult.error(this.error, this.stackTrace)
    : value = null,
      cancelled = false;

  const _CancellableResult.cancelled()
    : value = null,
      cancelled = true,
      error = null,
      stackTrace = null;

  final T? value;
  final bool cancelled;
  final Object? error;
  final StackTrace? stackTrace;
}
