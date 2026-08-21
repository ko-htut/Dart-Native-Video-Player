import 'dart:async';

import 'access_unit_pts.dart';
import 'audio/aac/adts.dart';
import 'audio/aac/audio_specific_config.dart';
import 'audio/aac/ts_aac_demux.dart';
import 'hls.dart';
import 'hls_segment_loader.dart';
import 'ts_h264_demux.dart';

/// Audio-clock decision for one [HlsVodRollingSession].
enum HlsVodAudioState {
  /// No audio rendition was selected.
  disabled,

  /// Audio is being demuxed, but readiness and A/V alignment are not proven.
  pending,

  /// Audio was validated before readiness and is now the locked clock choice.
  active,

  /// Audio failed before readiness, so the session committed to video-only.
  downgradedVideoOnly,
}

/// Immutable cumulative progress for a rolling VOD session.
final class HlsVodSessionProgress {
  const HlsVodSessionProgress({
    required this.videoSegmentsLoaded,
    required this.audioSegmentsLoaded,
    required this.totalSegments,
    required this.videoAccessUnitsEmitted,
    required this.audioAccessUnitsEmitted,
    required this.audioState,
    required this.ready,
    required this.sealed,
    required this.cancelled,
  });

  final int videoSegmentsLoaded;
  final int audioSegmentsLoaded;
  final int totalSegments;
  final int videoAccessUnitsEmitted;
  final int audioAccessUnitsEmitted;
  final HlsVodAudioState audioState;
  final bool ready;
  final bool sealed;
  final bool cancelled;

  double get loadedFraction => totalSegments == 0
      ? 1
      : (videoSegmentsLoaded / totalSegments).clamp(0, 1).toDouble();
}

/// One incremental batch emitted by [HlsVodRollingSession].
///
/// The batch owns only completed compressed access units and metadata. MPEG-TS
/// segment response bytes are never exposed or retained by the session.
final class HlsVodSessionUpdate {
  const HlsVodSessionUpdate({
    required this.epoch,
    required this.mediaSequence,
    required this.videoAccessUnits,
    required this.audioAccessUnits,
    required this.progress,
    required this.baseVideoPts90k,
    required this.firstVideoPts90k,
    required this.firstVideoPtsMs,
    required this.audioConfig,
    required this.audioVideoPtsDelta90k,
    required this.becameReady,
    required this.error,
    required this.audioDowngradeReason,
  });

  /// Caller-owned generation copied from the session constructor.
  final int epoch;

  /// Media sequence represented by this batch, or null for a terminal/tail
  /// update that is not owned by one segment.
  final int? mediaSequence;

  /// Newly completed, dependency-safe H.264 access units in decode order.
  final List<TimestampedAccessUnit> videoAccessUnits;

  /// Newly completed ADTS AAC access units in transport order.
  final List<AacAccessUnit> audioAccessUnits;

  final HlsVodSessionProgress progress;

  /// MPEG PTS used as zero for the normalized video timeline.
  final int? baseVideoPts90k;

  /// First video MPEG PTS actually emitted by this session. This differs from
  /// [baseVideoPts90k] when a quality restart begins partway through a VOD.
  final int? firstVideoPts90k;

  /// Normalized media time of [firstVideoPts90k].
  final int? firstVideoPtsMs;

  /// Validated stable AAC configuration while audio is pending or active.
  final AudioSpecificConfig? audioConfig;

  /// Signed `audio - video` offset after first-PTS alignment succeeds.
  final int? audioVideoPtsDelta90k;

  /// True only on the update that crosses the configurable prebuffer gate.
  final bool becameReady;

  /// Terminal session failure. A failed session is not sealed.
  final Object? error;

  /// Why a pre-ready audio selection was permanently downgraded.
  final Object? audioDowngradeReason;

  bool get ready => progress.ready;
  bool get sealed => progress.sealed;
  bool get cancelled => progress.cancelled;
  bool get isTerminal => sealed || cancelled || error != null;
}

/// Adds stage and sequence context to a terminal rolling-session failure.
final class HlsVodSessionFailure implements Exception {
  const HlsVodSessionFailure({
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
    return 'HlsVodSessionFailure: $stage failed$sequence: $cause';
  }
}

/// Incrementally fetches and demuxes one finite, single-epoch HLS VOD.
///
/// A session is single-use. [epoch] is copied into every update so a player can
/// reject work from a replaced session. [cancel] and [dispose] invalidate the
/// in-flight run and cancel both bounded segment loaders, including while an
/// injected fetcher is still waiting.
///
/// [audioFromVideoSegments] demuxes muxed AAC from each already-fetched video
/// response without a second download. Alternatively, separate audio and video
/// segment lists must be pre-paired by media sequence, duration, and
/// discontinuity epoch. Their loaders prefetch independently but this
/// coordinator consumes matching sequences together. Consequently no segment
/// payload is retained after its pair has been demuxed.
///
/// Pausing the single-subscription [updates] stream applies backpressure before
/// the next segment pair is requested from the loaders. Already-started work
/// remains bounded by each loader's [prefetchWindow].
///
/// Readiness requires [prebufferSegments] complete video segments (clamped to
/// the VOD length), a first IDR access unit, and—for selected audio—a stable
/// AAC-LC configuration plus validated first A/V PTS alignment. An audio error
/// may permanently downgrade the session only before that point. Once ready,
/// audio is the locked clock choice and any audio failure terminates the
/// session instead of silently switching clocks.
final class HlsVodRollingSession {
  HlsVodRollingSession({
    required Iterable<HlsSegment> videoSegments,
    Iterable<HlsSegment>? audioSegments,
    bool audioFromVideoSegments = false,
    required HlsSegmentByteFetcher fetcher,
    HlsSegmentByteFetcher? audioFetcher,
    this.epoch = 0,
    this.prebufferSegments = 2,
    this.prefetchWindow = 4,
    this.maxAttempts = 3,
    this.maxSegmentBytes = defaultHlsMaxSegmentBytes,
    this.durationToleranceSeconds = 0.5,
    int? videoTimestampBase90k,
    HlsSegmentRetryPredicate? retryPredicate,
    HlsSegmentRetryBackoff? retryBackoff,
    HlsSegmentRetrySleeper? retrySleeper,
  }) : _videoSegments = _orderedSegments(videoSegments, 'videoSegments'),
       _audioSegments = audioSegments == null
           ? null
           : _orderedSegments(audioSegments, 'audioSegments'),
       _audioFromVideoSegments = audioFromVideoSegments,
       _fetcher = fetcher,
       _audioFetcher = audioFetcher ?? fetcher,
       _videoDemuxer = TsH264Demuxer(basePts90k: videoTimestampBase90k),
       _retryPredicate = retryPredicate,
       _retryBackoff = retryBackoff,
       _retrySleeper = retrySleeper {
    if (_videoSegments.isEmpty) {
      throw ArgumentError.value(
        videoSegments,
        'videoSegments',
        'must contain at least one VOD segment',
      );
    }
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
    if (durationToleranceSeconds < 0) {
      throw ArgumentError.value(
        durationToleranceSeconds,
        'durationToleranceSeconds',
      );
    }
    if (_audioFromVideoSegments && _audioSegments != null) {
      throw ArgumentError(
        'audioFromVideoSegments and separate audioSegments are mutually '
        'exclusive',
      );
    }

    discontinuitySequence = _requireOneEpoch(_videoSegments);
    final audio = _audioSegments;
    if (audio != null) {
      _validatePairs(_videoSegments, audio, durationToleranceSeconds);
      final audioEpoch = _requireOneEpoch(audio);
      if (audioEpoch != discontinuitySequence) {
        throw FormatException(
          'HLS component renditions start in different discontinuity epochs: '
          'video=$discontinuitySequence, audio=$audioEpoch',
        );
      }
      _audioState = HlsVodAudioState.pending;
    } else if (_audioFromVideoSegments) {
      _audioState = HlsVodAudioState.pending;
    }
    _updates = StreamController<HlsVodSessionUpdate>(
      sync: true,
      onListen: _handleUpdateListen,
      onPause: _handleUpdatePause,
      onResume: _handleUpdateResume,
      onCancel: _handleUpdateCancel,
    );
  }

  final List<HlsSegment> _videoSegments;
  final List<HlsSegment>? _audioSegments;
  final bool _audioFromVideoSegments;
  final HlsSegmentByteFetcher _fetcher;
  final HlsSegmentByteFetcher _audioFetcher;
  final HlsSegmentRetryPredicate? _retryPredicate;
  final HlsSegmentRetryBackoff? _retryBackoff;
  final HlsSegmentRetrySleeper? _retrySleeper;

  late final StreamController<HlsVodSessionUpdate> _updates;
  final Completer<void> _done = Completer<void>();
  final TsH264Demuxer _videoDemuxer;
  final TsAacSegmentDemuxer _audioDemuxer = TsAacSegmentDemuxer();

  HlsSegmentLoader? _videoLoader;
  HlsSegmentLoader? _audioLoader;
  HlsVodAudioState _audioState = HlsVodAudioState.disabled;
  AudioSpecificConfig? _audioConfig;
  int? _firstAudioPts90k;
  int? _firstVideoPts90k;
  int? _firstVideoPtsMs;
  int? _audioVideoPtsDelta90k;
  Object? _audioDowngradeReason;
  Object? _error;
  StackTrace? _errorStackTrace;

  int _runToken = 0;
  int _videoSegmentsLoaded = 0;
  int _audioSegmentsLoaded = 0;
  int _videoAccessUnitsEmitted = 0;
  int _audioAccessUnitsEmitted = 0;
  bool _started = false;
  bool _cancelled = false;
  bool _disposed = false;
  bool _ready = false;
  bool _sealed = false;
  bool _closed = false;
  bool _sawFirstVideoAccessUnit = false;
  // start() may be called before the single updates listener is attached.
  // Hold the producer at zero fetched segments until that listener owns the
  // stream so StreamController cannot become an unbounded AU buffer.
  bool _updatesPaused = true;
  Completer<void>? _updateResumeGate;

  /// Caller-owned identity copied into every [HlsVodSessionUpdate].
  final int epoch;

  /// Number of complete video segments required before readiness.
  final int prebufferSegments;

  /// Independent bounded-loader request window for each rendition.
  final int prefetchWindow;

  final int maxAttempts;
  final int maxSegmentBytes;
  final double durationToleranceSeconds;

  /// The one playlist discontinuity epoch accepted by this session.
  late final int discontinuitySequence;

  List<HlsSegment> get videoSegments => _videoSegments;
  List<HlsSegment>? get audioSegments => _audioSegments;
  bool get audioFromVideoSegments => _audioFromVideoSegments;
  Stream<HlsVodSessionUpdate> get updates => _updates.stream;
  Future<void> get done => _done.future;
  HlsVodAudioState get audioState => _audioState;
  AudioSpecificConfig? get audioConfig => _audioConfig;
  int? get baseVideoPts90k => _videoDemuxer.basePts90k;
  int? get firstVideoPts90k => _firstVideoPts90k;
  int? get firstVideoPtsMs => _firstVideoPtsMs;
  int? get audioVideoPtsDelta90k => _audioVideoPtsDelta90k;
  Object? get audioDowngradeReason => _audioDowngradeReason;
  Object? get error => _error;
  StackTrace? get errorStackTrace => _errorStackTrace;
  bool get isStarted => _started;
  bool get isReady => _ready;
  bool get isSealed => _sealed;
  bool get isCancelled => _cancelled;
  bool get isDisposed => _disposed;

  /// Segment response bytes are intentionally never session state.
  int get retainedSegmentByteCount => 0;

  HlsVodSessionProgress get progress => HlsVodSessionProgress(
    videoSegmentsLoaded: _videoSegmentsLoaded,
    audioSegmentsLoaded: _audioSegmentsLoaded,
    totalSegments: _videoSegments.length,
    videoAccessUnitsEmitted: _videoAccessUnitsEmitted,
    audioAccessUnitsEmitted: _audioAccessUnitsEmitted,
    audioState: _audioState,
    ready: _ready,
    sealed: _sealed,
    cancelled: _cancelled,
  );

  /// Starts this single-use session. Repeated calls return the same [done].
  Future<void> start() {
    if (_started || _closed) return done;
    _started = true;
    final token = ++_runToken;
    unawaited(_run(token));
    return done;
  }

  /// Cancels both rendition loaders and unblocks a waiting session promptly.
  Future<void> cancel() async {
    if (_closed) return;
    _cancelled = true;
    _runToken++;
    _releaseUpdatePause();
    final loaders = <HlsSegmentLoader>[?_videoLoader, ?_audioLoader];
    await Future.wait(loaders.map((loader) => loader.cancel()));
    if (!_started) {
      _emit(mediaSequence: null);
      _close();
    }
    await done;
  }

  /// Permanently releases this session. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
  }

  Future<void> _run(int token) async {
    StreamIterator<HlsLoadedSegment>? videoIterator;
    StreamIterator<HlsLoadedSegment>? audioIterator;
    try {
      await _waitForUpdateResume(token);
      if (!_isCurrent(token)) return;

      final videoLoader = HlsSegmentLoader.fromSegments(
        segments: _videoSegments,
        fetcher: _fetcher,
        prefetchWindow: prefetchWindow,
        maxAttempts: maxAttempts,
        maxSegmentBytes: maxSegmentBytes,
        retryPredicate: _retryPredicate,
        retryBackoff: _retryBackoff,
        retrySleeper: _retrySleeper,
      );
      _videoLoader = videoLoader;
      videoIterator = StreamIterator<HlsLoadedSegment>(videoLoader.stream);

      final audioSegments = _audioSegments;
      if (audioSegments != null) {
        final audioLoader = HlsSegmentLoader.fromSegments(
          segments: audioSegments,
          fetcher: _audioFetcher,
          prefetchWindow: prefetchWindow,
          maxAttempts: maxAttempts,
          maxSegmentBytes: maxSegmentBytes,
          retryPredicate: _retryPredicate,
          retryBackoff: _retryBackoff,
          retrySleeper: _retrySleeper,
        );
        _audioLoader = audioLoader;
        audioIterator = StreamIterator<HlsLoadedSegment>(audioLoader.stream);
      }

      while (_isCurrent(token)) {
        await _waitForUpdateResume(token);
        if (!_isCurrent(token)) break;
        final videoMoveFuture = _move(videoIterator);
        final currentAudioIterator = audioIterator;
        final audioMoveFuture = currentAudioIterator == null
            ? Future<_MoveResult<HlsLoadedSegment>>.value(
                const _MoveResult<HlsLoadedSegment>.done(),
              )
            : _move(currentAudioIterator);
        final moves = await Future.wait(<Future<_MoveResult<HlsLoadedSegment>>>[
          videoMoveFuture,
          audioMoveFuture,
        ]);
        if (!_isCurrent(token)) break;

        final videoMove = moves[0];
        var audioMove = moves[1];
        if (videoMove.error != null) {
          _fail(
            HlsVodSessionFailure(
              stage: 'video segment load',
              cause: videoMove.error!,
            ),
            videoMove.stackTrace ?? StackTrace.current,
          );
          break;
        }
        if (!videoMove.hasValue) {
          if (currentAudioIterator != null && audioMove.hasValue) {
            _fail(
              const HlsVodSessionFailure(
                stage: 'rendition synchronization',
                cause: FormatException(
                  'Audio rendition contains more segments than video',
                ),
              ),
              StackTrace.current,
            );
          }
          break;
        }

        final loadedVideo = videoMove.value!;
        _videoSegmentsLoaded++;
        HlsLoadedSegment? loadedAudio;
        if (_audioFromVideoSegments) {
          // Demux both elementary streams from this one response. No copy and
          // no second request are needed; the local response is released after
          // this iteration.
          loadedAudio = loadedVideo;
          _audioSegmentsLoaded++;
        } else if (currentAudioIterator != null) {
          if (audioMove.error != null || !audioMove.hasValue) {
            final cause =
                audioMove.error ??
                const FormatException(
                  'Audio rendition ended before the matching video segment',
                );
            if (!_handleAudioFailure(
              HlsVodSessionFailure(
                stage: 'audio segment load',
                mediaSequence: loadedVideo.sequence,
                cause: cause,
              ),
              audioMove.stackTrace ?? StackTrace.current,
            )) {
              break;
            }
            await currentAudioIterator.cancel();
            audioIterator = null;
            final loader = _audioLoader;
            _audioLoader = null;
            await loader?.dispose();
            audioMove = const _MoveResult<HlsLoadedSegment>.done();
          } else {
            loadedAudio = audioMove.value;
            _audioSegmentsLoaded++;
            if (loadedAudio!.sequence != loadedVideo.sequence) {
              _fail(
                HlsVodSessionFailure(
                  stage: 'rendition synchronization',
                  mediaSequence: loadedVideo.sequence,
                  cause: FormatException(
                    'Expected audio sequence ${loadedVideo.sequence}, got '
                    '${loadedAudio.sequence}',
                  ),
                ),
                StackTrace.current,
              );
              break;
            }
          }
        }

        List<TimestampedAccessUnit> videoBatch;
        try {
          videoBatch = _videoDemuxer.pushSegment(loadedVideo.bytes);
          _recordVideoBatch(videoBatch);
        } catch (error, stackTrace) {
          _fail(
            HlsVodSessionFailure(
              stage: 'video demux',
              mediaSequence: loadedVideo.sequence,
              cause: error,
            ),
            stackTrace,
          );
          break;
        }

        var audioBatch = const <AacAccessUnit>[];
        if (loadedAudio != null &&
            (_audioState == HlsVodAudioState.pending ||
                _audioState == HlsVodAudioState.active)) {
          try {
            audioBatch = _audioDemuxer.pushSegment(loadedAudio.bytes);
            if (_audioDemuxer.definitivelyHasNoAdtsStream) {
              throw UnsupportedError('MPEG-TS PMT declares no ADTS AAC stream');
            }
            _recordAudioBatch(audioBatch);
          } catch (error, stackTrace) {
            if (!_handleAudioFailure(
              HlsVodSessionFailure(
                stage: 'audio demux',
                mediaSequence: loadedAudio.sequence,
                cause: error,
              ),
              stackTrace,
            )) {
              break;
            }
            audioBatch = const <AacAccessUnit>[];
            await audioIterator?.cancel();
            audioIterator = null;
            final loader = _audioLoader;
            _audioLoader = null;
            await loader?.dispose();
          }
        }

        final becameReady = _maybeBecomeReady();
        _emit(
          mediaSequence: loadedVideo.sequence,
          videoAccessUnits: videoBatch,
          audioAccessUnits: audioBatch,
          becameReady: becameReady,
        );
      }

      if (_isCurrent(token) && _error == null) {
        await _finishDemuxers(audioIterator);
      }
    } catch (error, stackTrace) {
      if (_isCurrent(token) && _error == null) {
        _fail(
          HlsVodSessionFailure(stage: 'rolling session', cause: error),
          stackTrace,
        );
      }
    } finally {
      await videoIterator?.cancel();
      await audioIterator?.cancel();
      final videoLoader = _videoLoader;
      final audioLoader = _audioLoader;
      _videoLoader = null;
      _audioLoader = null;
      await videoLoader?.dispose();
      await audioLoader?.dispose();

      if (!_closed) {
        if (_cancelled || !_isCurrent(token)) {
          _cancelled = true;
          _emit(mediaSequence: null);
        }
        _close();
      }
    }
  }

  Future<void> _finishDemuxers(
    StreamIterator<HlsLoadedSegment>? audioIterator,
  ) async {
    var videoTail = const <TimestampedAccessUnit>[];
    try {
      videoTail = _videoDemuxer.finish();
      _recordVideoBatch(videoTail);
    } catch (error, stackTrace) {
      _fail(
        HlsVodSessionFailure(stage: 'video demux finish', cause: error),
        stackTrace,
      );
      return;
    }

    var audioTail = const <AacAccessUnit>[];
    if (_audioState == HlsVodAudioState.pending ||
        _audioState == HlsVodAudioState.active) {
      try {
        audioTail = _audioDemuxer.finish();
        _recordAudioBatch(audioTail);
      } catch (error, stackTrace) {
        if (!_handleAudioFailure(
          HlsVodSessionFailure(stage: 'audio demux finish', cause: error),
          stackTrace,
        )) {
          return;
        }
        audioTail = const <AacAccessUnit>[];
        await audioIterator?.cancel();
      }
    }

    if (_audioState == HlsVodAudioState.pending) {
      final missing = _audioConfig == null
          ? 'selected audio produced no complete AAC access unit/configuration'
          : _audioVideoPtsDelta90k == null
          ? 'selected audio/video first PTS values could not be validated'
          : null;
      if (missing != null) {
        _handleAudioFailure(
          HlsVodSessionFailure(
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
        const HlsVodSessionFailure(
          stage: 'video readiness',
          cause: FormatException(
            'Finite HLS VOD ended before a dependency-safe IDR prefix was ready',
          ),
        ),
        StackTrace.current,
      );
      return;
    }

    _sealed = true;
    _emit(
      mediaSequence: null,
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
      _firstVideoPts90k = batch.first.pts90k;
      _firstVideoPtsMs = batch.first.ptsMs;
      _validateFirstPtsIfPossible();
    }
    _videoAccessUnitsEmitted += batch.length;
  }

  void _recordAudioBatch(List<AacAccessUnit> batch) {
    if (batch.isEmpty) return;
    for (final unit in batch) {
      final config = unit.config;
      if (!config.isAacLc) {
        throw UnsupportedError(
          'Rolling audio requires AAC-LC, got object type '
          '${config.audioObjectType}',
        );
      }
      final establishedConfig = _audioConfig;
      if (establishedConfig != null &&
          !_sameAudioConfig(establishedConfig, config)) {
        throw const FormatException(
          'AAC configuration changed inside one discontinuity epoch',
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
    _audioAccessUnitsEmitted += batch.length;
    _validateFirstPtsIfPossible();
  }

  void _validateFirstPtsIfPossible() {
    if (_audioVideoPtsDelta90k != null) return;
    final videoPts = _firstVideoPts90k;
    final audioPts = _firstAudioPts90k;
    if (videoPts == null || audioPts == null) return;
    _audioVideoPtsDelta90k = validateHlsFirstPtsAlignment(
      videoPts90k: videoPts,
      audioPts90k: audioPts,
    );
  }

  bool _maybeBecomeReady() {
    if (_ready) return false;
    final target = prebufferSegments < _videoSegments.length
        ? prebufferSegments
        : _videoSegments.length;
    if (_videoSegmentsLoaded < target || !_sawFirstVideoAccessUnit) {
      return false;
    }
    if (_audioState == HlsVodAudioState.pending) {
      _validateFirstPtsIfPossible();
      if (_audioConfig == null || _audioVideoPtsDelta90k == null) return false;
      _audioState = HlsVodAudioState.active;
    }
    _ready = true;
    return true;
  }

  bool _handleAudioFailure(Object error, StackTrace stackTrace) {
    if (_ready || _audioState == HlsVodAudioState.active) {
      _fail(error, stackTrace);
      return false;
    }
    _audioState = HlsVodAudioState.downgradedVideoOnly;
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
    _emit(mediaSequence: null, error: error);
  }

  void _emit({
    required int? mediaSequence,
    List<TimestampedAccessUnit> videoAccessUnits =
        const <TimestampedAccessUnit>[],
    List<AacAccessUnit> audioAccessUnits = const <AacAccessUnit>[],
    bool becameReady = false,
    Object? error,
  }) {
    if (_closed) return;
    _updates.add(
      HlsVodSessionUpdate(
        epoch: epoch,
        mediaSequence: mediaSequence,
        videoAccessUnits: List<TimestampedAccessUnit>.unmodifiable(
          videoAccessUnits,
        ),
        audioAccessUnits: List<AacAccessUnit>.unmodifiable(audioAccessUnits),
        progress: progress,
        baseVideoPts90k: _videoDemuxer.basePts90k,
        firstVideoPts90k: _firstVideoPts90k,
        firstVideoPtsMs: _firstVideoPtsMs,
        audioConfig: _audioConfig,
        audioVideoPtsDelta90k: _audioVideoPtsDelta90k,
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

  void _handleUpdatePause() {
    if (_closed) return;
    _updatesPaused = true;
    _updateResumeGate ??= Completer<void>();
  }

  void _handleUpdateListen() => _releaseUpdatePause();

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

  static List<HlsSegment> _orderedSegments(
    Iterable<HlsSegment> source,
    String parameterName,
  ) {
    final result = source.toList(growable: false)
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    for (var index = 1; index < result.length; index++) {
      if (result[index - 1].sequence == result[index].sequence) {
        throw ArgumentError.value(
          source,
          parameterName,
          'contains duplicate media sequence ${result[index].sequence}',
        );
      }
    }
    return List<HlsSegment>.unmodifiable(result);
  }

  static int _requireOneEpoch(List<HlsSegment> segments) {
    if (segments.isEmpty) return 0;
    final epoch = segments.first.discontinuitySequence;
    for (final segment in segments.skip(1)) {
      if (segment.discontinuitySequence != epoch) {
        throw HlsDiscontinuityUnsupportedException(
          firstSequence: segment.sequence,
          discontinuitySequence: segment.discontinuitySequence,
        );
      }
    }
    return epoch;
  }

  static void _validatePairs(
    List<HlsSegment> video,
    List<HlsSegment> audio,
    double durationToleranceSeconds,
  ) {
    if (video.length != audio.length) {
      throw FormatException(
        'HLS component rendition segment counts differ: '
        'video=${video.length}, audio=${audio.length}',
      );
    }
    for (var index = 0; index < video.length; index++) {
      final videoSegment = video[index];
      final audioSegment = audio[index];
      if (videoSegment.sequence != audioSegment.sequence) {
        throw FormatException(
          'HLS component sequence mismatch at index $index: '
          'video=${videoSegment.sequence}, audio=${audioSegment.sequence}',
        );
      }
      if (videoSegment.discontinuitySequence !=
          audioSegment.discontinuitySequence) {
        throw FormatException(
          'HLS component discontinuity mismatch at sequence '
          '${videoSegment.sequence}: '
          'video=${videoSegment.discontinuitySequence}, '
          'audio=${audioSegment.discontinuitySequence}',
        );
      }
      if ((videoSegment.duration - audioSegment.duration).abs() >
          durationToleranceSeconds) {
        throw FormatException(
          'HLS component duration mismatch at sequence '
          '${videoSegment.sequence}: video=${videoSegment.duration}, '
          'audio=${audioSegment.duration}',
        );
      }
    }
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
