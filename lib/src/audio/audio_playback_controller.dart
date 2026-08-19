import 'dart:async';
import 'dart:typed_data';

import 'pcm_sink_api.dart';
import 'pcm_timeline.dart';

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

/// Feeds a decoded PCM timeline to a bounded platform sink.
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
  PcmAudioTimeline? _timeline;
  Completer<void>? _firstBufferReady;
  int _generation = 0;
  int _startFrame = 0;
  int _nextFrame = 0;
  int _playedFrames = 0;
  bool _playing = false;
  bool _pollInFlight = false;
  bool _completionReported = false;
  bool _disposed = false;
  int? _failedGeneration;

  Stream<AudioPlaybackEvent> get events => _events.stream;
  PcmAudioTimeline? get timeline => _timeline;
  bool get hasAudio => _timeline != null && _timeline!.frameCount != 0;
  bool get isPlaying => _playing;
  int get generation => _generation;

  int get currentMediaTimeUs {
    final timeline = _timeline;
    if (timeline == null) return 0;
    return timeline.mediaTimeUsForFrame(_startFrame + _playedFrames);
  }

  int get currentMediaTimeMs =>
      currentMediaTimeUs ~/ Duration.microsecondsPerMillisecond;

  Future<void> load(PcmAudioTimeline timeline) async {
    _ensureNotDisposed();
    _positionTimer?.cancel();
    _playing = false;
    _timeline = timeline;
    _generation++;
    _startFrame = 0;
    _nextFrame = 0;
    _playedFrames = 0;
    _completionReported = false;
    _failedGeneration = null;
    _firstBufferReady = Completer<void>();

    await _sink.configure(
      PcmAudioFormat(
        sampleRate: timeline.sampleRate,
        channelCount: timeline.channels,
      ),
      generation: _generation,
    );
    _startPump(_generation);
    await _firstBufferReady!.future;
    _emit(AudioPlaybackEventType.ready);
  }

  Future<void> play() async {
    _ensureNotDisposed();
    final timeline = _timeline;
    if (timeline == null || timeline.frameCount == 0) return;
    if (_startFrame + _playedFrames >= timeline.frameCount) {
      await seekToMediaTimeUs(timeline.basePtsUs);
    }
    await _firstBufferReady?.future;
    await _sink.play();
    _playing = true;
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(positionPollInterval, (_) {
      unawaited(_refreshPosition());
    });
    await _refreshPosition();
  }

  Future<void> pause() async {
    _ensureNotDisposed();
    if (_timeline == null) return;
    await _sink.pause();
    await _refreshPosition();
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> seekToMediaTimeUs(int mediaTimeUs) async {
    _ensureNotDisposed();
    final timeline = _timeline;
    if (timeline == null) return;

    final resume = _playing;
    if (_sink.state == PcmSinkState.playing) await _sink.pause();
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;

    _generation++;
    _startFrame = timeline.frameForMediaTimeUs(mediaTimeUs);
    _nextFrame = _startFrame;
    _playedFrames = 0;
    _completionReported = false;
    _failedGeneration = null;
    _firstBufferReady = Completer<void>();
    await _sink.flush(generation: _generation);
    _startPump(_generation);
    await _firstBufferReady!.future;
    await _refreshPosition();
    if (resume) await play();
  }

  void _startPump(int pumpGeneration) {
    unawaited(_pump(pumpGeneration));
  }

  Future<void> _pump(int pumpGeneration) async {
    final timeline = _timeline;
    if (timeline == null) return;
    try {
      if (_nextFrame >= timeline.frameCount) {
        if (pumpGeneration == _generation) {
          _completeFirstBuffer();
          _checkForCompletion();
        }
        return;
      }

      while (!_disposed && pumpGeneration == _generation) {
        if (_nextFrame >= timeline.frameCount) break;
        final count = (timeline.frameCount - _nextFrame) < framesPerChunk
            ? timeline.frameCount - _nextFrame
            : framesPerChunk;
        final firstSample = _nextFrame * timeline.channels;
        final lastSample = (_nextFrame + count) * timeline.channels;
        final pcm = _pcm16RangeToLittleEndianBytes(
          timeline.samples,
          firstSample,
          lastSample,
        );
        final accepted = await _sink.enqueue(pcm, generation: pumpGeneration);
        if (_disposed || pumpGeneration != _generation) return;
        if (accepted != count) {
          throw StateError(
            'PCM sink accepted $accepted of $count submitted frames',
          );
        }
        _nextFrame += accepted;
        _completeFirstBuffer();
      }
    } catch (error) {
      if (!_disposed && pumpGeneration == _generation) {
        final first = _firstBufferReady;
        if (first != null && !first.isCompleted) first.completeError(error);
        _handleFailure(error);
      }
    }
  }

  Future<void> _refreshPosition() async {
    if (_disposed || _timeline == null || _pollInFlight) return;
    _pollInFlight = true;
    try {
      final position = await _sink.position();
      if (_disposed || position.generation != _generation) return;
      _playedFrames = position.frames;
      _emit(AudioPlaybackEventType.position);
      _checkForCompletion();
    } catch (error) {
      if (!_disposed) _handleFailure(error);
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

  void _handleFailure(Object error) {
    if (_disposed || _failedGeneration == _generation) return;
    _failedGeneration = _generation;
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;
    if (_sink.state == PcmSinkState.playing) {
      unawaited(_pauseFailedSink(_generation));
    }
    _emit(AudioPlaybackEventType.error, message: '$error');
  }

  Future<void> _pauseFailedSink(int failedGeneration) async {
    try {
      await _sink.pause();
    } catch (_) {
      // The original error is authoritative. A second failure while stopping
      // the same broken generation must not create an event loop.
    }
    if (_disposed || failedGeneration != _generation) return;
  }

  void _checkForCompletion() {
    final timeline = _timeline;
    if (timeline == null || _completionReported) return;
    final remainingFrames = timeline.frameCount - _startFrame;
    if (_nextFrame < timeline.frameCount || _playedFrames < remainingFrames) {
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
    try {
      await _sink.pause();
    } catch (error) {
      if (!_disposed && completedGeneration == _generation) {
        _emit(AudioPlaybackEventType.error, message: '$error');
      }
    }
  }

  void _completeFirstBuffer() {
    final first = _firstBufferReady;
    if (first != null && !first.isCompleted) first.complete();
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _positionTimer?.cancel();
    final first = _firstBufferReady;
    if (first != null && !first.isCompleted) {
      first.completeError(
        StateError('Audio playback was disposed during initial buffering'),
      );
    }
    await _sinkEvents.cancel();
    await _sink.dispose();
    await _events.close();
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('AudioPlaybackController is disposed');
  }
}

Uint8List _pcm16RangeToLittleEndianBytes(
  Int16List samples,
  int start,
  int end,
) {
  RangeError.checkValidRange(start, end, samples.length);
  final bytes = Uint8List((end - start) * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = start; i < end; i++) {
    data.setInt16((i - start) * 2, samples[i], Endian.little);
  }
  return bytes;
}
