import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'pcm_sink_api.dart';

/// Deterministic in-memory implementation of [PcmAudioSink].
///
/// Tests explicitly advance its playback head with [consumeFrames]. The
/// bounded queue makes it useful for testing producer backpressure as well as
/// seek-generation invalidation without depending on audio hardware.
final class FakePcmAudioSink implements PcmAudioSink {
  FakePcmAudioSink({this.maxBufferedFrames = 4096, bool startBlocked = false})
    : _acceptingWrites = !startBlocked {
    if (maxBufferedFrames <= 0) {
      throw RangeError.value(
        maxBufferedFrames,
        'maxBufferedFrames',
        'must be positive',
      );
    }
  }

  final int maxBufferedFrames;
  final StreamController<PcmSinkEvent> _events =
      StreamController<PcmSinkEvent>.broadcast(sync: true);
  final Queue<_PendingFakeWrite> _pending = Queue<_PendingFakeWrite>();

  @override
  PcmAudioFormat? format;

  @override
  int generation = 0;

  @override
  PcmSinkState state = PcmSinkState.unconfigured;

  int _bufferedFrames = 0;
  int _playedFrames = 0;
  bool _acceptingWrites;

  int get bufferedFrames => _bufferedFrames;
  int get pendingWriteCount => _pending.length;

  void releaseWrites() {
    _acceptingWrites = true;
    _acceptPendingWrites();
  }

  @override
  Stream<PcmSinkEvent> get events => _events.stream;

  @override
  Future<void> configure(
    PcmAudioFormat newFormat, {
    required int generation,
  }) async {
    _ensureNotDisposed();
    _failPending('sink was reconfigured');
    format = newFormat;
    this.generation = generation;
    _bufferedFrames = 0;
    _playedFrames = 0;
    state = PcmSinkState.paused;
    _emitState();
  }

  @override
  Future<int> enqueue(Uint8List interleavedPcm, {required int generation}) {
    validatePcmWrite(
      format,
      state,
      this.generation,
      interleavedPcm,
      generation,
    );
    final frameCount = interleavedPcm.lengthInBytes ~/ format!.bytesPerFrame;
    if (frameCount == 0) return Future<int>.value(0);
    if (frameCount > maxBufferedFrames) {
      return Future<int>.error(
        RangeError.value(
          frameCount,
          'interleavedPcm',
          'one write exceeds the $maxBufferedFrames-frame sink capacity',
        ),
      );
    }

    final pending = _PendingFakeWrite(frameCount, generation);
    _pending.add(pending);
    _acceptPendingWrites();
    return pending.completer.future;
  }

  @override
  Future<void> play() async {
    _ensureConfigured();
    state = PcmSinkState.playing;
    _emitState();
  }

  @override
  Future<void> pause() async {
    _ensureConfigured();
    state = PcmSinkState.paused;
    _emitState();
  }

  @override
  Future<void> flush({required int generation}) async {
    _ensureConfigured();
    _failPending('PCM queue was flushed');
    this.generation = generation;
    _bufferedFrames = 0;
    _playedFrames = 0;
    state = PcmSinkState.paused;
    _emitState();
  }

  /// Simulates the hardware consuming up to [frameCount] queued frames.
  int consumeFrames(int frameCount) {
    _ensureConfigured();
    if (frameCount < 0) {
      throw RangeError.value(frameCount, 'frameCount', 'must not be negative');
    }
    if (state != PcmSinkState.playing || frameCount == 0) return 0;

    final consumed = frameCount < _bufferedFrames
        ? frameCount
        : _bufferedFrames;
    _bufferedFrames -= consumed;
    _playedFrames += consumed;
    if (consumed != 0) {
      _events.add(
        PcmSinkEvent(
          type: PcmSinkEventType.bufferConsumed,
          generation: generation,
          frames: consumed,
        ),
      );
    }
    _acceptPendingWrites();
    return consumed;
  }

  /// Injects a platform-style failure for controller tests.
  void emitError(String message) {
    _ensureConfigured();
    _events.add(
      PcmSinkEvent(
        type: PcmSinkEventType.error,
        generation: generation,
        message: message,
      ),
    );
  }

  @override
  Future<PcmPlaybackPosition> position() async {
    _ensureConfigured();
    return PcmPlaybackPosition(
      generation: generation,
      frames: _playedFrames,
      sampleRate: format!.sampleRate,
    );
  }

  @override
  Future<void> dispose() async {
    if (state == PcmSinkState.disposed) return;
    _failPending('sink was disposed');
    state = PcmSinkState.disposed;
    format = null;
    _bufferedFrames = 0;
    _emitState();
    await _events.close();
  }

  void _acceptPendingWrites() {
    if (!_acceptingWrites) return;
    while (_pending.isNotEmpty) {
      final next = _pending.first;
      if (next.generation != generation) {
        _pending.removeFirst();
        next.completer.completeError(
          PcmSinkStateException(
            'stale PCM generation ${next.generation}; active generation is '
            '$generation',
          ),
        );
        continue;
      }
      if (_bufferedFrames + next.frames > maxBufferedFrames) return;
      _pending.removeFirst();
      _bufferedFrames += next.frames;
      next.completer.complete(next.frames);
    }
  }

  void _failPending(String reason) {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completer.completeError(
        PcmSinkStateException(reason),
      );
    }
  }

  void _ensureNotDisposed() {
    if (state == PcmSinkState.disposed) {
      throw const PcmSinkStateException('sink has been disposed');
    }
  }

  void _ensureConfigured() {
    _ensureNotDisposed();
    if (format == null || state == PcmSinkState.unconfigured) {
      throw const PcmSinkStateException('sink is not configured');
    }
  }

  void _emitState() {
    if (!_events.isClosed) {
      _events.add(
        PcmSinkEvent(
          type: PcmSinkEventType.stateChanged,
          generation: generation,
          message: state.name,
        ),
      );
    }
  }
}

final class _PendingFakeWrite {
  _PendingFakeWrite(this.frames, this.generation);

  final int frames;
  final int generation;
  final Completer<int> completer = Completer<int>();
}
