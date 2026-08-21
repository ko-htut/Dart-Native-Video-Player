import 'dart:async';

import 'access_unit_pts.dart';
import 'audio/aac/adts.dart';
import 'audio/aac/audio_specific_config.dart';
import 'audio/aac/ts_aac_demux.dart';
import 'hls.dart';
import 'hls_live_playlist.dart';
import 'hls_segment_loader.dart';
import 'mpeg_timestamp_epoch.dart';
import 'ts_h264_demux.dart';

/// Audio-clock decision for one [HlsLiveRollingSession].
enum HlsLiveAudioState {
  /// The selected live variant is video-only.
  disabled,

  /// Muxed AAC was selected, but its configuration/alignment is not proven.
  pending,

  /// AAC-LC was validated before readiness and is now the locked clock source.
  active,

  /// Muxed audio failed before readiness, so playback is permanently video-only.
  downgradedVideoOnly,
}

/// Immutable cumulative progress for a bounded live playback session.
final class HlsLiveSessionProgress {
  const HlsLiveSessionProgress({
    required this.playlistRefreshesCompleted,
    required this.segmentsDiscovered,
    required this.initialSegmentsSkipped,
    required this.videoSegmentsLoaded,
    required this.audioSegmentsLoaded,
    required this.videoAccessUnitsEmitted,
    required this.audioAccessUnitsEmitted,
    required this.lastDiscoveredSequence,
    required this.lastLoadedSequence,
    required this.playlistMediaSequence,
    required this.windowFirstSequence,
    required this.windowLastSequence,
    required this.windowSegmentCount,
    required this.targetDuration,
    required this.currentDiscontinuitySequence,
    required this.discontinuitiesProcessed,
    required this.audioState,
    required this.endListSeen,
    required this.ready,
    required this.sealed,
    required this.cancelled,
  });

  final int playlistRefreshesCompleted;
  final int segmentsDiscovered;
  final int initialSegmentsSkipped;
  final int videoSegmentsLoaded;
  final int audioSegmentsLoaded;
  final int videoAccessUnitsEmitted;
  final int audioAccessUnitsEmitted;
  final int? lastDiscoveredSequence;
  final int? lastLoadedSequence;
  final int? playlistMediaSequence;
  final int? windowFirstSequence;
  final int? windowLastSequence;
  final int windowSegmentCount;
  final int? targetDuration;
  final int? currentDiscontinuitySequence;
  final int discontinuitiesProcessed;
  final HlsLiveAudioState audioState;
  final bool endListSeen;
  final bool ready;
  final bool sealed;
  final bool cancelled;

  /// Number of discovered segment metadata entries not yet fully demuxed.
  int get pendingSegmentCount {
    final pending = segmentsDiscovered - videoSegmentsLoaded;
    return pending < 0 ? 0 : pending;
  }
}

/// One playlist observation, completed media batch, or terminal live update.
///
/// A successful playlist refresh is emitted immediately with
/// [playlistRefreshed] true and no access units. Each newly discovered segment
/// then produces a separate update with [mediaSequence] set after its response
/// has been fetched and demuxed. This gives a player an unambiguous place to
/// update live-window UI without conflating discovery with buffered media.
final class HlsLiveSessionUpdate {
  const HlsLiveSessionUpdate({
    required this.epoch,
    required this.mediaSequence,
    required this.discontinuitySequence,
    required this.videoAccessUnits,
    required this.audioAccessUnits,
    required this.progress,
    required this.baseVideoPts90k,
    required this.audioConfig,
    required this.audioVideoPtsDelta90k,
    required this.playlistRefreshed,
    required this.becameReady,
    required this.error,
    required this.audioDowngradeReason,
  });

  /// Caller-owned generation inherited from the playlist coordinator.
  final int epoch;

  /// Completed media sequence represented by this update, if any.
  final int? mediaSequence;
  final int? discontinuitySequence;

  /// Newly completed, dependency-safe H.264 access units in decode order.
  final List<TimestampedAccessUnit> videoAccessUnits;

  /// Newly completed muxed ADTS AAC access units in transport order.
  final List<AacAccessUnit> audioAccessUnits;

  final HlsLiveSessionProgress progress;
  final int? baseVideoPts90k;
  final AudioSpecificConfig? audioConfig;

  /// Signed `audio - video` offset validated before readiness.
  final int? audioVideoPtsDelta90k;

  /// True only for the metadata-only update emitted per successful refresh.
  final bool playlistRefreshed;

  /// True only on the update that crosses the configured prebuffer gate.
  final bool becameReady;

  /// Terminal session failure. A failed session is never sealed.
  final Object? error;

  /// Permanent pre-ready audio downgrade cause, when applicable.
  final Object? audioDowngradeReason;

  bool get ready => progress.ready;
  bool get sealed => progress.sealed;
  bool get cancelled => progress.cancelled;
  bool get isTerminal => sealed || cancelled || error != null;
}

/// Adds stage and sequence context to a terminal live-session failure.
final class HlsLiveSessionFailure implements Exception {
  const HlsLiveSessionFailure({
    required this.stage,
    required this.cause,
    this.mediaSequence,
  });

  final String stage;
  final int? mediaSequence;
  final Object cause;

  @override
  String toString() {
    final sequence = mediaSequence == null
        ? ''
        : ' at media sequence $mediaSequence';
    return 'HlsLiveSessionFailure: $stage failed$sequence: $cause';
  }
}

/// Fetches and demuxes ordered deltas from one live/event media playlist.
///
/// The session takes ownership of [playlistCoordinator]. It supports a
/// video-only variant or ADTS AAC muxed into the same MPEG-TS responses;
/// separate live audio renditions require a synchronized dual-playlist
/// coordinator and are deliberately outside this contract.
///
/// Both the playlist coordinator and each finite delta loader are consumed one
/// event at a time. Pausing the single-subscription [updates] stream prevents
/// the next loader/refresh operation; already-started segment requests remain
/// bounded by [prefetchWindow]. Segment response bytes are released after each
/// demux step and are never retained in session state.
///
/// At an HLS discontinuity, video creates a continuous timestamp epoch from
/// cumulative `EXTINF` duration. Video binds the new raw clock first, then the
/// same epoch is applied to AAC so its A/V offset survives a source PTS reset.
///
/// Audio may downgrade only before readiness. Once AAC-LC configuration and
/// first-PTS alignment are locked, any audio failure is terminal rather than a
/// silent clock switch. `EXT-X-ENDLIST` flushes both demuxers and seals the
/// session; a live playlist never calls `finish()` between refreshes.
final class HlsLiveRollingSession {
  HlsLiveRollingSession({
    required HlsLivePlaylistCoordinator playlistCoordinator,
    required HlsSegmentByteFetcher fetcher,
    this.audioFromVideoSegments = false,
    this.prebufferSegments = 2,
    this.prefetchWindow = 4,
    this.maxAttempts = 3,
    this.maxSegmentBytes = defaultHlsMaxSegmentBytes,
    HlsSegmentRetryPredicate? retryPredicate,
    HlsSegmentRetryBackoff? retryBackoff,
    HlsSegmentRetrySleeper? retrySleeper,
  }) : _playlistCoordinator = playlistCoordinator,
       _fetcher = fetcher,
       _retryPredicate = retryPredicate,
       _retryBackoff = retryBackoff,
       _retrySleeper = retrySleeper,
       _audioState = audioFromVideoSegments
           ? HlsLiveAudioState.pending
           : HlsLiveAudioState.disabled {
    if (prebufferSegments <= 0) {
      throw ArgumentError.value(
        prebufferSegments,
        'prebufferSegments',
        'must be > 0',
      );
    }
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

    _updates = StreamController<HlsLiveSessionUpdate>(
      sync: true,
      onListen: _handleUpdateListen,
      onPause: _handleUpdatePause,
      onResume: _handleUpdateResume,
      onCancel: _handleUpdateCancel,
    );
  }

  final HlsLivePlaylistCoordinator _playlistCoordinator;
  final HlsSegmentByteFetcher _fetcher;
  final HlsSegmentRetryPredicate? _retryPredicate;
  final HlsSegmentRetryBackoff? _retryBackoff;
  final HlsSegmentRetrySleeper? _retrySleeper;

  late final StreamController<HlsLiveSessionUpdate> _updates;
  final Completer<void> _done = Completer<void>();
  final TsH264Demuxer _videoDemuxer = TsH264Demuxer();
  final TsAacSegmentDemuxer _audioDemuxer = TsAacSegmentDemuxer();

  HlsSegmentLoader? _segmentLoader;
  HlsLiveAudioState _audioState;
  AudioSpecificConfig? _audioConfig;
  int? _firstAudioPts90k;
  int? _audioVideoPtsDelta90k;
  Object? _audioDowngradeReason;
  Object? _error;
  StackTrace? _errorStackTrace;

  int _runToken = 0;
  int _playlistRefreshesCompleted = 0;
  int _segmentsDiscovered = 0;
  int _initialSegmentsSkipped = 0;
  int _videoSegmentsLoaded = 0;
  int _audioSegmentsLoaded = 0;
  int _videoAccessUnitsEmitted = 0;
  int _audioAccessUnitsEmitted = 0;
  int _elapsedDuration90k = 0;
  int _discontinuitiesProcessed = 0;
  int? _lastDiscoveredSequence;
  int? _lastLoadedSequence;
  int? _playlistMediaSequence;
  int? _windowFirstSequence;
  int? _windowLastSequence;
  int _windowSegmentCount = 0;
  int? _targetDuration;
  int? _currentDiscontinuitySequence;
  bool _endListSeen = false;
  bool _started = false;
  bool _cancelled = false;
  bool _disposed = false;
  bool _ready = false;
  bool _sealed = false;
  bool _closed = false;
  bool _sawFirstVideoAccessUnit = false;
  bool _updatesPaused = true;
  Completer<void>? _updateResumeGate;

  /// Caller-owned identity inherited from [playlistCoordinator].
  int get epoch => _playlistCoordinator.epoch;
  final bool audioFromVideoSegments;
  final int prebufferSegments;
  final int prefetchWindow;
  final int maxAttempts;
  final int maxSegmentBytes;

  HlsLivePlaylistCoordinator get playlistCoordinator => _playlistCoordinator;
  Stream<HlsLiveSessionUpdate> get updates => _updates.stream;
  Future<void> get done => _done.future;
  HlsLiveAudioState get audioState => _audioState;
  AudioSpecificConfig? get audioConfig => _audioConfig;
  int? get baseVideoPts90k => _videoDemuxer.basePts90k;
  int? get audioVideoPtsDelta90k => _audioVideoPtsDelta90k;
  Object? get audioDowngradeReason => _audioDowngradeReason;
  Object? get error => _error;
  StackTrace? get errorStackTrace => _errorStackTrace;
  bool get isStarted => _started;
  bool get isReady => _ready;
  bool get isSealed => _sealed;
  bool get isCancelled => _cancelled;
  bool get isDisposed => _disposed;

  /// Segment payloads are scoped to a loader event and never session state.
  int get retainedSegmentByteCount => 0;

  HlsLiveSessionProgress get progress => HlsLiveSessionProgress(
    playlistRefreshesCompleted: _playlistRefreshesCompleted,
    segmentsDiscovered: _segmentsDiscovered,
    initialSegmentsSkipped: _initialSegmentsSkipped,
    videoSegmentsLoaded: _videoSegmentsLoaded,
    audioSegmentsLoaded: _audioSegmentsLoaded,
    videoAccessUnitsEmitted: _videoAccessUnitsEmitted,
    audioAccessUnitsEmitted: _audioAccessUnitsEmitted,
    lastDiscoveredSequence: _lastDiscoveredSequence,
    lastLoadedSequence: _lastLoadedSequence,
    playlistMediaSequence: _playlistMediaSequence,
    windowFirstSequence: _windowFirstSequence,
    windowLastSequence: _windowLastSequence,
    windowSegmentCount: _windowSegmentCount,
    targetDuration: _targetDuration,
    currentDiscontinuitySequence: _currentDiscontinuitySequence,
    discontinuitiesProcessed: _discontinuitiesProcessed,
    audioState: _audioState,
    endListSeen: _endListSeen,
    ready: _ready,
    sealed: _sealed,
    cancelled: _cancelled,
  );

  /// Starts this single-use session. Fetching remains update-listener gated.
  Future<void> start() {
    if (_started || _closed) return done;
    _started = true;
    final token = ++_runToken;
    unawaited(_run(token));
    return done;
  }

  /// Cancels playlist refresh and the active bounded delta loader promptly.
  Future<void> cancel() async {
    if (_closed) return;
    _cancelled = true;
    _runToken++;
    _releaseUpdatePause();
    await Future.wait(<Future<void>>[
      _playlistCoordinator.cancel(),
      if (_segmentLoader case final loader?) loader.cancel(),
    ]);
    if (!_started) {
      _emit();
      _close();
    }
    await done;
  }

  /// Releases this session and its owned playlist coordinator. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    await _playlistCoordinator.dispose();
  }

  Future<void> _run(int token) async {
    StreamIterator<HlsLivePlaylistUpdate>? playlistIterator;
    try {
      await _waitForUpdateResume(token);
      if (!_isCurrent(token)) return;

      playlistIterator = StreamIterator<HlsLivePlaylistUpdate>(
        _playlistCoordinator.updates,
      );
      unawaited(_playlistCoordinator.start());

      while (_isCurrent(token)) {
        await _waitForUpdateResume(token);
        if (!_isCurrent(token)) break;

        final moved = await _move(playlistIterator);
        if (!_isCurrent(token)) break;
        if (moved.error != null) {
          _fail(
            HlsLiveSessionFailure(
              stage: 'playlist update stream',
              cause: moved.error!,
            ),
            moved.stackTrace ?? StackTrace.current,
          );
          break;
        }
        if (!moved.hasValue) {
          if (!_endListSeen && !_cancelled && _error == null) {
            _fail(
              const HlsLiveSessionFailure(
                stage: 'playlist refresh',
                cause: FormatException(
                  'Live playlist update stream ended without EXT-X-ENDLIST',
                ),
              ),
              StackTrace.current,
            );
          }
          break;
        }

        final playlistUpdate = moved.value!;
        if (playlistUpdate.epoch != epoch) {
          _fail(
            HlsLiveSessionFailure(
              stage: 'playlist epoch',
              cause: StateError(
                'Expected generation $epoch, got ${playlistUpdate.epoch}',
              ),
            ),
            StackTrace.current,
          );
          break;
        }
        _recordPlaylistUpdate(playlistUpdate);

        if (playlistUpdate.error != null) {
          _fail(
            HlsLiveSessionFailure(
              stage: 'playlist refresh',
              cause: playlistUpdate.error!,
            ),
            _playlistCoordinator.errorStackTrace ?? StackTrace.current,
          );
          break;
        }
        if (playlistUpdate.cancelled) {
          _cancelled = true;
          break;
        }

        // One metadata-only event per successful observation makes window
        // movement visible before potentially slow segment downloads begin.
        _emit(playlistRefreshed: true);
        await _waitForUpdateResume(token);
        if (!_isCurrent(token)) break;

        if (playlistUpdate.newSegments.isNotEmpty) {
          if (!await _loadDelta(playlistUpdate.newSegments, token)) break;
        }
        if (!_isCurrent(token) || _error != null) break;

        if (playlistUpdate.isEndList) {
          await _finishDemuxers();
          break;
        }
      }
    } catch (error, stackTrace) {
      if (_isCurrent(token) && _error == null) {
        _fail(
          HlsLiveSessionFailure(stage: 'rolling live session', cause: error),
          stackTrace,
        );
      }
    } finally {
      await playlistIterator?.cancel();
      final loader = _segmentLoader;
      _segmentLoader = null;
      await loader?.dispose();
      await _playlistCoordinator.cancel();

      if (!_closed) {
        if (_cancelled || !_isCurrent(token)) {
          _cancelled = true;
          _emit();
        }
        _close();
      }
    }
  }

  void _recordPlaylistUpdate(HlsLivePlaylistUpdate update) {
    final playlistProgress = update.progress;
    _playlistRefreshesCompleted = playlistProgress.refreshesCompleted;
    _segmentsDiscovered = playlistProgress.segmentsEmitted;
    _initialSegmentsSkipped = playlistProgress.initialSegmentsSkipped;
    _lastDiscoveredSequence = playlistProgress.lastEmittedSequence;
    _playlistMediaSequence = update.mediaSequence;
    _windowFirstSequence = update.windowFirstSequence;
    _windowLastSequence = update.windowLastSequence;
    _windowSegmentCount = update.windowSegmentCount;
    _targetDuration = update.targetDuration;
    if (update.isEndList) _endListSeen = true;
  }

  Future<bool> _loadDelta(List<HlsSegment> segments, int token) async {
    final loader = HlsSegmentLoader.fromSegments(
      segments: segments,
      fetcher: _fetcher,
      prefetchWindow: prefetchWindow,
      maxAttempts: maxAttempts,
      maxSegmentBytes: maxSegmentBytes,
      retryPredicate: _retryPredicate,
      retryBackoff: _retryBackoff,
      retrySleeper: _retrySleeper,
    );
    _segmentLoader = loader;
    final iterator = StreamIterator<HlsLoadedSegment>(loader.stream);
    try {
      while (_isCurrent(token)) {
        await _waitForUpdateResume(token);
        if (!_isCurrent(token)) return false;
        final moved = await _move(iterator);
        if (!_isCurrent(token)) return false;
        if (moved.error != null) {
          final cause = moved.error!;
          final sequence = cause is HlsSegmentLoadException
              ? cause.segment.sequence
              : null;
          _fail(
            HlsLiveSessionFailure(
              stage: 'video segment load',
              mediaSequence: sequence,
              cause: cause,
            ),
            moved.stackTrace ?? StackTrace.current,
          );
          return false;
        }
        if (!moved.hasValue) return true;
        if (!_processSegment(moved.value!)) return false;
      }
      return false;
    } finally {
      await iterator.cancel();
      if (identical(_segmentLoader, loader)) _segmentLoader = null;
      await loader.dispose();
    }
  }

  bool _processSegment(HlsLoadedSegment loaded) {
    final segment = loaded.segment;
    final previousSequence = _lastLoadedSequence;
    if (previousSequence != null && segment.sequence != previousSequence + 1) {
      _fail(
        HlsLiveSessionFailure(
          stage: 'segment ordering',
          mediaSequence: segment.sequence,
          cause: FormatException(
            'Expected media sequence ${previousSequence + 1}, got '
            '${segment.sequence}',
          ),
        ),
        StackTrace.current,
      );
      return false;
    }

    MpegTimestampEpoch? discontinuityEpoch;
    final currentDiscontinuity = _currentDiscontinuitySequence;
    if (currentDiscontinuity == null) {
      _currentDiscontinuitySequence = segment.discontinuitySequence;
    } else if (segment.discontinuitySequence != currentDiscontinuity) {
      if (segment.discontinuitySequence < currentDiscontinuity) {
        _fail(
          HlsLiveSessionFailure(
            stage: 'discontinuity epoch',
            mediaSequence: segment.sequence,
            cause: FormatException(
              'Discontinuity sequence regressed from $currentDiscontinuity '
              'to ${segment.discontinuitySequence}',
            ),
          ),
          StackTrace.current,
        );
        return false;
      }
      try {
        discontinuityEpoch = _videoDemuxer.beginDiscontinuity(
          discontinuitySequence: segment.discontinuitySequence,
          elapsedDuration90k: _elapsedDuration90k,
        );
        _currentDiscontinuitySequence = segment.discontinuitySequence;
        _discontinuitiesProcessed++;
      } catch (error, stackTrace) {
        _fail(
          HlsLiveSessionFailure(
            stage: 'discontinuity epoch',
            mediaSequence: segment.sequence,
            cause: error,
          ),
          stackTrace,
        );
        return false;
      }
    }

    List<TimestampedAccessUnit> videoBatch;
    try {
      // Video must bind the new epoch source clock before muxed AAC consumes
      // the same mapping below.
      videoBatch = _videoDemuxer.pushSegment(loaded.bytes);
      _recordVideoBatch(videoBatch);
    } catch (error, stackTrace) {
      _fail(
        HlsLiveSessionFailure(
          stage: 'video demux',
          mediaSequence: segment.sequence,
          cause: error,
        ),
        stackTrace,
      );
      return false;
    }

    _videoSegmentsLoaded++;
    var audioBatch = const <AacAccessUnit>[];
    if (_audioState == HlsLiveAudioState.pending ||
        _audioState == HlsLiveAudioState.active) {
      _audioSegmentsLoaded++;
      try {
        if (discontinuityEpoch != null && !discontinuityEpoch.isSourceBound) {
          throw const FormatException(
            'Video produced no PTS to bind the shared discontinuity epoch',
          );
        }
        audioBatch = _audioDemuxer.pushSegment(
          loaded.bytes,
          discontinuityEpoch: discontinuityEpoch,
        );
        if (_audioDemuxer.definitivelyHasNoAdtsStream) {
          throw UnsupportedError('MPEG-TS PMT declares no ADTS AAC stream');
        }
        _recordAudioBatch(audioBatch);
      } catch (error, stackTrace) {
        if (!_handleAudioFailure(
          HlsLiveSessionFailure(
            stage: 'audio demux',
            mediaSequence: segment.sequence,
            cause: error,
          ),
          stackTrace,
        )) {
          return false;
        }
        audioBatch = const <AacAccessUnit>[];
      }
    }

    _lastLoadedSequence = segment.sequence;
    _elapsedDuration90k += (segment.duration * mpegTimestampClockRate).round();
    final becameReady = _maybeBecomeReady();
    _emit(
      mediaSequence: segment.sequence,
      discontinuitySequence: segment.discontinuitySequence,
      videoAccessUnits: videoBatch,
      audioAccessUnits: audioBatch,
      becameReady: becameReady,
    );
    return _error == null;
  }

  Future<void> _finishDemuxers() async {
    var videoTail = const <TimestampedAccessUnit>[];
    try {
      videoTail = _videoDemuxer.finish();
      _recordVideoBatch(videoTail);
    } catch (error, stackTrace) {
      _fail(
        HlsLiveSessionFailure(stage: 'video demux finish', cause: error),
        stackTrace,
      );
      return;
    }

    var audioTail = const <AacAccessUnit>[];
    if (_audioState == HlsLiveAudioState.pending ||
        _audioState == HlsLiveAudioState.active) {
      try {
        audioTail = _audioDemuxer.finish();
        _recordAudioBatch(audioTail);
      } catch (error, stackTrace) {
        if (!_handleAudioFailure(
          HlsLiveSessionFailure(stage: 'audio demux finish', cause: error),
          stackTrace,
        )) {
          return;
        }
        audioTail = const <AacAccessUnit>[];
      }
    }

    if (_audioState == HlsLiveAudioState.pending) {
      final missing = _audioConfig == null
          ? 'selected audio produced no complete AAC access unit/configuration'
          : _audioVideoPtsDelta90k == null
          ? 'selected audio/video first PTS values could not be validated'
          : null;
      if (missing != null) {
        _handleAudioFailure(
          HlsLiveSessionFailure(
            stage: 'audio readiness',
            cause: FormatException(missing),
          ),
          StackTrace.current,
        );
        audioTail = const <AacAccessUnit>[];
      }
    }

    final becameReady = _maybeBecomeReady();
    if (!_ready) {
      _fail(
        HlsLiveSessionFailure(
          stage: 'video readiness',
          cause: FormatException(
            'Live HLS reached EXT-X-ENDLIST before $prebufferSegments '
            'complete segments and a dependency-safe IDR were ready',
          ),
        ),
        StackTrace.current,
      );
      return;
    }

    _sealed = true;
    _emit(
      videoAccessUnits: videoTail,
      audioAccessUnits: audioTail,
      becameReady: becameReady,
    );
  }

  void _recordVideoBatch(List<TimestampedAccessUnit> batch) {
    if (batch.isEmpty) return;
    if (!_sawFirstVideoAccessUnit) {
      if (!batch.first.hasIdr) {
        throw const FormatException(
          'First emitted video access unit is not a random-access IDR',
        );
      }
      _sawFirstVideoAccessUnit = true;
    }
  }

  void _recordAudioBatch(List<AacAccessUnit> batch) {
    if (batch.isEmpty) return;
    for (final unit in batch) {
      final config = unit.config;
      if (!config.isAacLc) {
        throw UnsupportedError(
          'Live rolling audio requires AAC-LC, got object type '
          '${config.audioObjectType}',
        );
      }
      final establishedConfig = _audioConfig;
      if (establishedConfig != null &&
          !_sameAudioConfig(establishedConfig, config)) {
        throw const FormatException(
          'AAC configuration changed after live playback selection',
        );
      }
      _audioConfig ??= config;
    }

    if (_firstAudioPts90k == null) {
      final pts = batch.first.pts90k;
      if (pts == null) {
        throw const FormatException(
          'First selected AAC access unit has no MPEG PTS',
        );
      }
      _firstAudioPts90k = pts;
    }
    _validateFirstPtsIfPossible();
  }

  void _validateFirstPtsIfPossible() {
    if (_audioVideoPtsDelta90k != null) return;
    final videoPts = _videoDemuxer.basePts90k;
    final audioPts = _firstAudioPts90k;
    if (videoPts == null || audioPts == null) return;
    _audioVideoPtsDelta90k = validateHlsFirstPtsAlignment(
      videoPts90k: videoPts,
      audioPts90k: audioPts,
    );
  }

  bool _maybeBecomeReady() {
    if (_ready) return false;
    if (_videoSegmentsLoaded < prebufferSegments || !_sawFirstVideoAccessUnit) {
      return false;
    }
    if (_audioState == HlsLiveAudioState.pending) {
      _validateFirstPtsIfPossible();
      if (_audioConfig == null || _audioVideoPtsDelta90k == null) return false;
      _audioState = HlsLiveAudioState.active;
    }
    _ready = true;
    return true;
  }

  bool _handleAudioFailure(Object error, StackTrace stackTrace) {
    if (_ready || _audioState == HlsLiveAudioState.active) {
      _fail(error, stackTrace);
      return false;
    }
    _audioState = HlsLiveAudioState.downgradedVideoOnly;
    _audioDowngradeReason = error;
    _audioConfig = null;
    _firstAudioPts90k = null;
    _audioVideoPtsDelta90k = null;
    return true;
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_error != null || _closed) return;
    _error = error;
    _errorStackTrace = stackTrace;
    _emit(error: error);
  }

  void _emit({
    int? mediaSequence,
    int? discontinuitySequence,
    List<TimestampedAccessUnit> videoAccessUnits =
        const <TimestampedAccessUnit>[],
    List<AacAccessUnit> audioAccessUnits = const <AacAccessUnit>[],
    bool playlistRefreshed = false,
    bool becameReady = false,
    Object? error,
  }) {
    if (_closed) return;
    _videoAccessUnitsEmitted += videoAccessUnits.length;
    _audioAccessUnitsEmitted += audioAccessUnits.length;
    _updates.add(
      HlsLiveSessionUpdate(
        epoch: epoch,
        mediaSequence: mediaSequence,
        discontinuitySequence: discontinuitySequence,
        videoAccessUnits: List<TimestampedAccessUnit>.unmodifiable(
          videoAccessUnits,
        ),
        audioAccessUnits: List<AacAccessUnit>.unmodifiable(audioAccessUnits),
        progress: progress,
        baseVideoPts90k: _videoDemuxer.basePts90k,
        audioConfig: _audioConfig,
        audioVideoPtsDelta90k: _audioVideoPtsDelta90k,
        playlistRefreshed: playlistRefreshed,
        becameReady: becameReady,
        error: error,
        audioDowngradeReason: _audioDowngradeReason,
      ),
    );
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

  void _handleUpdateCancel() {
    if (_closed) return;
    unawaited(cancel());
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
}

final class _MoveResult<T> {
  const _MoveResult.value(this.value)
    : hasValue = true,
      error = null,
      stackTrace = null;

  const _MoveResult.done()
    : value = null,
      hasValue = false,
      error = null,
      stackTrace = null;

  const _MoveResult.error(this.error, this.stackTrace)
    : value = null,
      hasValue = false;

  final T? value;
  final bool hasValue;
  final Object? error;
  final StackTrace? stackTrace;
}

Future<_MoveResult<T>> _move<T>(StreamIterator<T> iterator) async {
  try {
    if (!await iterator.moveNext()) return _MoveResult<T>.done();
    return _MoveResult<T>.value(iterator.current);
  } catch (error, stackTrace) {
    return _MoveResult<T>.error(error, stackTrace);
  }
}

bool _sameAudioConfig(AudioSpecificConfig left, AudioSpecificConfig right) =>
    left.audioObjectType == right.audioObjectType &&
    left.samplingFrequency == right.samplingFrequency &&
    left.channelConfiguration == right.channelConfiguration &&
    left.frameLengthFlag == right.frameLengthFlag &&
    left.extensionAudioObjectType == right.extensionAudioObjectType &&
    left.extensionSamplingFrequency == right.extensionSamplingFrequency;
