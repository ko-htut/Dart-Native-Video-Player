import 'dart:async';

import 'pcm_sink_api.dart';
import 'pcm_source.dart';

enum AudioPlaybackEventType { ready, position, complete, underrun, error }

final class AudioPlaybackEvent {
  const AudioPlaybackEvent({
    required this.type,
    required this.mediaTimeUs,
    this.message,
  });

  final AudioPlaybackEventType type;
  final int mediaTimeUs;
  final String? message;
}

/// Feeds a decoded PCM source to a bounded platform sink.
///
/// Compressed audio never enters the platform layer. The sink sees only
/// interleaved PCM16, while this controller owns PTS mapping, seek generations,
/// backpressure, and the audio-master media clock.
final class AudioPlaybackController {
  AudioPlaybackController(
    this._sink, {
    this.framesPerChunk = 2048,
    this.positionPollInterval = const Duration(milliseconds: 16),
  }) {
    if (framesPerChunk <= 0) {
      throw ArgumentError.value(framesPerChunk, 'framesPerChunk');
    }
    _sinkEvents = _sink.events.listen(_handleSinkEvent);
  }

  final PcmAudioSink _sink;
  final int framesPerChunk;
  final Duration positionPollInterval;
  final StreamController<AudioPlaybackEvent> _events =
      StreamController<AudioPlaybackEvent>.broadcast(sync: true);

  late final StreamSubscription<PcmSinkEvent> _sinkEvents;
  Timer? _positionTimer;
  PcmAudioSource? _source;
  Completer<void>? _firstBufferReady;
  int _generation = 0;
  int _startFrame = 0;
  int _nextFrame = 0;
  int _playedFrames = 0;
  int _transportIntent = 0;
  bool _playing = false;
  bool _pollInFlight = false;
  bool _completionReported = false;
  bool _disposed = false;
  int? _failedGeneration;
  Future<void> _sinkMutationTail = Future<void>.value();
  Future<void>? _disposeFuture;

  Stream<AudioPlaybackEvent> get events => _events.stream;
  PcmAudioSource? get source => _source;

  /// Backward-compatible name for callers that previously loaded only an
  /// in-memory timeline.
  PcmAudioSource? get timeline => _source;

  bool get hasAudio {
    final source = _source;
    return source != null && source.frameCount > _firstAvailableFrame(source);
  }

  bool get isPlaying => _playing;
  int get generation => _generation;

  /// Earliest media time that can be used for a new seek/load generation.
  int? get seekableStartMediaTimeUs {
    final source = _source;
    if (source == null) return null;
    return source.mediaTimeUsForFrame(_firstAvailableFrame(source));
  }

  /// Current committed tail. On an open growing source a read at this media
  /// time waits for the next append instead of reporting final EOF.
  int? get seekableEndMediaTimeUs => _source?.endPtsUs;

  int get currentMediaTimeUs {
    final source = _source;
    if (source == null) return 0;
    return source.mediaTimeUsForFrame(_startFrame + _playedFrames);
  }

  int get currentMediaTimeMs =>
      currentMediaTimeUs ~/ Duration.microsecondsPerMillisecond;

  Future<void> load(PcmAudioSource source) async {
    _ensureNotDisposed();
    _transportIntent++;
    _positionTimer?.cancel();
    _playing = false;
    final loadGeneration = ++_generation;
    final replacedSource = _source;
    final replacedFirstBuffer = _firstBufferReady;
    if (replacedFirstBuffer != null && !replacedFirstBuffer.isCompleted) {
      replacedFirstBuffer.completeError(
        StateError('Audio source was replaced during initial buffering'),
      );
    }
    _source = source;
    _startFrame = _firstAvailableFrame(source);
    _nextFrame = _startFrame;
    _playedFrames = 0;
    _completionReported = false;
    _failedGeneration = null;
    final firstBuffer = Completer<void>();
    // A replacement may fail this future before this async method reaches its
    // await. Register a handler immediately to avoid an unhandled async error.
    firstBuffer.future.ignore();
    _firstBufferReady = firstBuffer;

    try {
      if (replacedSource != null && !identical(replacedSource, source)) {
        await replacedSource.dispose();
      }
      _ensureCurrentLoad(loadGeneration, source, firstBuffer);
      await _mutateSink(() async {
        _ensureCurrentLoad(loadGeneration, source, firstBuffer);
        await _sink.configure(
          PcmAudioFormat(
            sampleRate: source.sampleRate,
            channelCount: source.channels,
          ),
          generation: loadGeneration,
        );
        _ensureCurrentLoad(loadGeneration, source, firstBuffer);
      });
      _ensureCurrentLoad(loadGeneration, source, firstBuffer);
      _startPump(loadGeneration, source, firstBuffer);
      await firstBuffer.future;
      _ensureCurrentLoad(loadGeneration, source, firstBuffer);
      _emit(AudioPlaybackEventType.ready);
    } catch (error, stackTrace) {
      _completeFirstBufferError(firstBuffer, error, stackTrace);
      if (_isCurrentLoad(loadGeneration, source, firstBuffer)) {
        _handleFailure(error);
      }
      rethrow;
    }
  }

  Future<void> play() async {
    _ensureNotDisposed();
    var source = _source;
    if (source == null) return;
    _ensureSourceCanTransport(source);
    if (source.frameCount == 0) return;
    final reachedFinalTail = _startFrame + _playedFrames >= source.frameCount;
    final canRewind = source is! GrowingPcmAudioSource || source.isSealed;
    if (reachedFinalTail && canRewind) {
      final intentBeforeSeek = _transportIntent;
      _playing = false;
      await seekToMediaTimeUs(
        source.mediaTimeUsForFrame(_firstAvailableFrame(source)),
      );
      if (_transportIntent != intentBeforeSeek + 1) {
        throw StateError('Audio play was replaced by a newer transport intent');
      }
      source = _source;
      if (source == null) return;
      _ensureSourceCanTransport(source);
    }
    final playIntent = ++_transportIntent;
    final playGeneration = _generation;
    final firstBuffer = _firstBufferReady;
    await firstBuffer?.future;
    _ensureCurrentTransport(playIntent, playGeneration, source);
    await _mutateSink(() async {
      _ensureCurrentTransport(playIntent, playGeneration, source!);
      await _sink.play();
      _ensureCurrentTransport(playIntent, playGeneration, source);
    });
    _ensureCurrentTransport(playIntent, playGeneration, source);
    _playing = true;
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(positionPollInterval, (_) {
      unawaited(_refreshPosition());
    });
    await _refreshPosition();
  }

  Future<void> pause() async {
    _ensureNotDisposed();
    final source = _source;
    if (source == null) return;
    final pauseIntent = ++_transportIntent;
    final pauseGeneration = _generation;
    await _mutateSink(() async {
      _ensureCurrentTransport(pauseIntent, pauseGeneration, source);
      await _sink.pause();
      _ensureCurrentTransport(pauseIntent, pauseGeneration, source);
    });
    _ensureCurrentTransport(pauseIntent, pauseGeneration, source);
    await _refreshPosition();
    _ensureCurrentTransport(pauseIntent, pauseGeneration, source);
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> seekToMediaTimeUs(int mediaTimeUs) async {
    _ensureNotDisposed();
    final source = _source;
    if (source == null) return;
    _ensureSourceCanTransport(source);
    final requestedFrame = source.frameForMediaTimeUs(mediaTimeUs);
    final availableStart = _firstAvailableFrame(source);
    if (requestedFrame < availableStart) {
      throw PcmFramesEvictedException(
        requestedFrame: requestedFrame,
        firstAvailableFrame: availableStart,
        endFrame: source.frameCount,
      );
    }
    final seekIntent = ++_transportIntent;

    final resume = _playing;
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;

    final seekGeneration = ++_generation;
    final replacedFirstBuffer = _firstBufferReady;
    if (replacedFirstBuffer != null && !replacedFirstBuffer.isCompleted) {
      replacedFirstBuffer.completeError(
        StateError('Audio seek was replaced during initial buffering'),
      );
    }
    _startFrame = requestedFrame;
    _nextFrame = _startFrame;
    _playedFrames = 0;
    _completionReported = false;
    _failedGeneration = null;
    final firstBuffer = Completer<void>();
    firstBuffer.future.ignore();
    _firstBufferReady = firstBuffer;
    try {
      await _mutateSink(() async {
        _ensureCurrentLoad(seekGeneration, source, firstBuffer);
        if (_sink.state == PcmSinkState.playing) await _sink.pause();
        _ensureCurrentLoad(seekGeneration, source, firstBuffer);
        await _sink.flush(generation: seekGeneration);
        _ensureCurrentLoad(seekGeneration, source, firstBuffer);
      });
      _ensureCurrentLoad(seekGeneration, source, firstBuffer);
      _startPump(seekGeneration, source, firstBuffer);
      await firstBuffer.future;
      _ensureCurrentLoad(seekGeneration, source, firstBuffer);
      await _refreshPosition();
      _ensureCurrentLoad(seekGeneration, source, firstBuffer);
      if (resume && seekIntent == _transportIntent) await play();
    } catch (error, stackTrace) {
      _completeFirstBufferError(firstBuffer, error, stackTrace);
      if (_isCurrentLoad(seekGeneration, source, firstBuffer)) {
        _handleFailure(error);
      }
      rethrow;
    }
  }

  void _startPump(
    int pumpGeneration,
    PcmAudioSource source,
    Completer<void> firstBuffer,
  ) {
    unawaited(_pump(pumpGeneration, source, firstBuffer));
  }

  Future<void> _pump(
    int pumpGeneration,
    PcmAudioSource source,
    Completer<void> firstBuffer,
  ) async {
    try {
      if (_nextFrame >= source.frameCount && source is! GrowingPcmAudioSource) {
        if (pumpGeneration == _generation) {
          _completeFirstBuffer(firstBuffer);
          _checkForCompletion();
        }
        return;
      }

      while (!_disposed && pumpGeneration == _generation) {
        final committedRemaining = source.frameCount - _nextFrame;
        if (committedRemaining <= 0 && source is! GrowingPcmAudioSource) break;
        final requested = source is GrowingPcmAudioSource
            ? framesPerChunk
            : committedRemaining < framesPerChunk
            ? committedRemaining
            : framesPerChunk;
        final chunk = await source.readFrames(_nextFrame, maxFrames: requested);
        if (_disposed || pumpGeneration != _generation) return;
        if (chunk.frameCount == 0 &&
            source is GrowingPcmAudioSource &&
            source.isSealed) {
          _completeFirstBuffer(firstBuffer);
          _checkForCompletion();
          return;
        }
        if (chunk.startFrame != _nextFrame || chunk.frameCount <= 0) {
          throw StateError(
            'PCM source returned ${chunk.frameCount} frames at '
            '${chunk.startFrame}; expected data at $_nextFrame',
          );
        }
        final expectedBytes = chunk.frameCount * source.channels * 2;
        if (chunk.pcm16le.lengthInBytes != expectedBytes) {
          throw StateError(
            'PCM source returned ${chunk.pcm16le.lengthInBytes} bytes for '
            '${chunk.frameCount} frames; expected $expectedBytes',
          );
        }
        final accepted = await _sink.enqueue(
          chunk.pcm16le,
          generation: pumpGeneration,
        );
        if (_disposed || pumpGeneration != _generation) return;
        if (accepted != chunk.frameCount) {
          throw StateError(
            'PCM sink accepted $accepted of ${chunk.frameCount} submitted '
            'frames',
          );
        }
        _nextFrame += accepted;
        _completeFirstBuffer(firstBuffer);
      }
    } catch (error, stackTrace) {
      if (!_disposed && pumpGeneration == _generation) {
        _completeFirstBufferError(firstBuffer, error, stackTrace);
        _handleFailure(error);
      }
    }
  }

  Future<void> _refreshPosition() async {
    if (_disposed || _source == null || _pollInFlight) return;
    final pollGeneration = _generation;
    _pollInFlight = true;
    try {
      final position = await _sink.position();
      if (_disposed || position.generation != _generation) return;
      _playedFrames = position.frames;
      _emit(AudioPlaybackEventType.position);
      _checkForCompletion();
    } catch (error) {
      if (!_disposed && pollGeneration == _generation) _handleFailure(error);
    } finally {
      _pollInFlight = false;
    }
  }

  void _handleSinkEvent(PcmSinkEvent event) {
    if (_disposed || event.generation != _generation) return;
    switch (event.type) {
      case PcmSinkEventType.bufferConsumed:
        unawaited(_refreshPosition());
      case PcmSinkEventType.underrun:
        _emit(AudioPlaybackEventType.underrun, message: event.message);
      case PcmSinkEventType.error:
        _handleFailure(event.message ?? 'PCM sink error');
      case PcmSinkEventType.stateChanged:
        break;
    }
  }

  void _handleFailure(Object error, [StackTrace? stackTrace]) {
    if (_disposed || _failedGeneration == _generation) return;
    final failure = error is Error || error is Exception
        ? error
        : StateError('Audio playback failed: $error');
    final failureStack = stackTrace ?? StackTrace.current;
    final firstBuffer = _firstBufferReady;

    // Advancing the generation invalidates a pump that may still be blocked in
    // a growing-source read or native enqueue. Failing its initial-buffer
    // completer guarantees load/seek cannot later report ready for the broken
    // generation.
    _generation++;
    _failedGeneration = _generation;
    _transportIntent++;
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;
    if (firstBuffer != null && !firstBuffer.isCompleted) {
      firstBuffer.completeError(failure, failureStack);
    }
    if (_sink.state == PcmSinkState.playing) {
      unawaited(_pauseFailedSink(_generation));
    }
    _emit(AudioPlaybackEventType.error, message: '$failure');
  }

  Future<void> _pauseFailedSink(int failedGeneration) async {
    try {
      await _mutateSink(() async {
        if (_disposed || failedGeneration != _generation) return;
        await _sink.pause();
      });
    } catch (_) {
      // The original error is authoritative. A second failure while stopping
      // the same broken generation must not create an event loop.
    }
    if (_disposed || failedGeneration != _generation) return;
  }

  void _checkForCompletion() {
    final source = _source;
    if (source == null || _completionReported) return;
    if (source is GrowingPcmAudioSource && !source.isSealed) return;
    final remainingFrames = source.frameCount - _startFrame;
    if (_nextFrame < source.frameCount || _playedFrames < remainingFrames) {
      return;
    }
    _completionReported = true;
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;
    unawaited(_pauseCompletedSink(_generation));
    _emit(AudioPlaybackEventType.complete);
  }

  Future<void> _pauseCompletedSink(int completedGeneration) async {
    if (_disposed || completedGeneration != _generation) return;
    try {
      await _mutateSink(() async {
        if (_disposed || completedGeneration != _generation) return;
        await _sink.pause();
      });
    } catch (error) {
      if (!_disposed && completedGeneration == _generation) {
        _emit(AudioPlaybackEventType.error, message: '$error');
      }
    }
  }

  void _completeFirstBuffer(Completer<void> firstBuffer) {
    if (!firstBuffer.isCompleted) firstBuffer.complete();
  }

  void _completeFirstBufferError(
    Completer<void> firstBuffer,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!firstBuffer.isCompleted) firstBuffer.completeError(error, stackTrace);
  }

  void _emit(AudioPlaybackEventType type, {String? message}) {
    if (_events.isClosed) return;
    _events.add(
      AudioPlaybackEvent(
        type: type,
        mediaTimeUs: currentMediaTimeUs,
        message: message,
      ),
    );
  }

  Future<void> dispose() => _disposeFuture ??= _disposeOnce();

  Future<void> _disposeOnce() async {
    _disposed = true;
    _transportIntent++;
    _generation++;
    _positionTimer?.cancel();
    final source = _source;
    _source = null;
    final first = _firstBufferReady;
    if (first != null && !first.isCompleted) {
      first.completeError(
        StateError('Audio playback was disposed during initial buffering'),
      );
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _sinkEvents.cancel();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await _mutateSink(_sink.dispose);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await source?.dispose();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _events.close();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  bool _isCurrentLoad(
    int generation,
    PcmAudioSource source,
    Completer<void> firstBuffer,
  ) =>
      !_disposed &&
      generation == _generation &&
      identical(source, _source) &&
      identical(firstBuffer, _firstBufferReady);

  void _ensureCurrentLoad(
    int generation,
    PcmAudioSource source,
    Completer<void> firstBuffer,
  ) {
    if (!_isCurrentLoad(generation, source, firstBuffer)) {
      throw StateError('Audio operation was replaced by a newer generation');
    }
  }

  void _ensureCurrentSession(int generation, PcmAudioSource source) {
    if (_disposed || generation != _generation || !identical(source, _source)) {
      throw StateError('Audio operation was replaced by a newer generation');
    }
  }

  void _ensureCurrentTransport(
    int intent,
    int generation,
    PcmAudioSource source,
  ) {
    _ensureCurrentSession(generation, source);
    if (intent != _transportIntent) {
      throw StateError('Audio transport was replaced by a newer intent');
    }
  }

  void _ensureSourceCanTransport(PcmAudioSource source) {
    if (_failedGeneration == _generation) {
      throw StateError('Audio generation failed; load a new source');
    }
    if (source is GrowingPcmAudioSource &&
        (source.state == GrowingPcmAudioState.failed ||
            source.state == GrowingPcmAudioState.disposed)) {
      throw StateError(
        'Growing PCM source is ${source.state.name}; load a new source',
      );
    }
  }

  int _firstAvailableFrame(PcmAudioSource source) =>
      source is WindowedGrowingPcmAudioSource ? source.firstAvailableFrame : 0;

  Future<T> _mutateSink<T>(Future<T> Function() action) {
    final result = _sinkMutationTail.then((_) => action());
    _sinkMutationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('AudioPlaybackController is disposed');
  }
}
