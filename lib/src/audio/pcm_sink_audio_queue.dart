import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'native_memory.dart';
import 'pcm_sink_api.dart';

/// Recovery action derived from one AudioQueue running-state observation.
final class AudioQueueRefillDecision {
  const AudioQueueRefillDecision({
    required this.emitUnderrun,
    required this.restartQueue,
  });

  final bool emitUnderrun;
  final bool restartQueue;
}

/// Tracks one open-tail AudioQueue starvation episode.
///
/// This pure-Dart state machine is shared by the FFI sink and deterministic
/// tests. An underrun is reported once per stopped episode, while restart is
/// requested only after refill supplies queued audio.
final class AudioQueueStarvationTracker {
  bool _openTail = false;
  bool _underrunReported = false;
  bool _reportUnderrunForEpisode = false;

  bool get hasOpenTail => _openTail;
  bool get hasReportedUnderrun => _underrunReported;

  void noteOpenTail({bool reportUnderrun = true}) {
    _openTail = true;
    _reportUnderrunForEpisode |= reportUnderrun;
  }

  AudioQueueRefillDecision observe({
    required bool logicallyPlaying,
    required bool queueIsRunning,
    required bool hasQueuedAudio,
  }) {
    if (!logicallyPlaying || !_openTail) {
      return const AudioQueueRefillDecision(
        emitUnderrun: false,
        restartQueue: false,
      );
    }
    final emitUnderrun =
        !queueIsRunning && _reportUnderrunForEpisode && !_underrunReported;
    if (emitUnderrun) _underrunReported = true;
    return AudioQueueRefillDecision(
      emitUnderrun: emitUnderrun,
      restartQueue: !queueIsRunning && hasQueuedAudio,
    );
  }

  void markRecovered() {
    _openTail = false;
    _underrunReported = false;
    _reportUnderrunForEpisode = false;
  }

  void reset() => markRecovered();
}

/// PCM output backed directly by Audio Queue Services through `dart:ffi`.
///
/// AudioToolbox owns four bounded native buffers. Its output callback only
/// posts a buffer-credit message back to this isolate; it never runs Dart
/// synchronously on the real-time audio thread.
final class AudioQueuePcmAudioSink implements PcmAudioSink {
  AudioQueuePcmAudioSink._(this._api);

  static Future<AudioQueuePcmAudioSink> create() async =>
      AudioQueuePcmAudioSink._(_AudioQueueApi());

  static const int _bufferCount = 4;
  static const int _minimumFramesPerBuffer = 2048;

  final _AudioQueueApi _api;
  final NativeMemory _memory = NativeMemory.instance;
  final StreamController<PcmSinkEvent> _events =
      StreamController<PcmSinkEvent>.broadcast(sync: true);
  final Queue<Pointer<_AudioQueueBuffer>> _freeBuffers =
      Queue<Pointer<_AudioQueueBuffer>>();
  final Queue<_PendingAudioQueueWrite> _pending =
      Queue<_PendingAudioQueueWrite>();
  final Map<int, _AudioQueueInFlight> _inFlight = <int, _AudioQueueInFlight>{};

  Pointer<Void> _queue = nullptr;
  NativeCallable<_AudioQueueOutputCallbackNative>? _callback;
  int _queueEpoch = 0;
  int _bufferCapacityBytes = 0;
  int _lastPositionFrames = 0;
  int _totalFramesEnqueued = 0;
  bool _audioSessionActive = false;
  final AudioQueueStarvationTracker _starvation = AudioQueueStarvationTracker();

  @override
  PcmAudioFormat? format;

  @override
  int generation = 0;

  @override
  PcmSinkState state = PcmSinkState.unconfigured;

  @override
  Stream<PcmSinkEvent> get events => _events.stream;

  @override
  Future<void> configure(
    PcmAudioFormat newFormat, {
    required int generation,
  }) async {
    _ensureNotDisposed();
    _closeQueue('sink was reconfigured');
    format = newFormat;
    this.generation = generation;
    try {
      _openQueue(newFormat);
      state = PcmSinkState.paused;
      _emitState();
    } catch (_) {
      format = null;
      state = PcmSinkState.unconfigured;
      rethrow;
    }
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
    final frames = interleavedPcm.lengthInBytes ~/ format!.bytesPerFrame;
    if (frames == 0) return Future<int>.value(0);
    if (interleavedPcm.lengthInBytes > _bufferCapacityBytes) {
      return Future<int>.error(
        RangeError.value(
          interleavedPcm.lengthInBytes,
          'interleavedPcm.lengthInBytes',
          'one write exceeds the $_bufferCapacityBytes-byte AudioQueue '
              'buffer capacity',
        ),
      );
    }

    final write = _PendingAudioQueueWrite(
      Uint8List.fromList(interleavedPcm),
      frames,
      generation,
    );
    _pending.add(write);
    _pumpPending();
    return write.completer.future;
  }

  @override
  Future<void> play() async {
    _ensureConfigured();
    _api.setAudioSessionActive(true);
    _audioSessionActive = Platform.isIOS;
    try {
      _check(
        _api.start(_queue, nullptr.cast<_AudioTimeStamp>()),
        'AudioQueueStart',
      );
    } catch (_) {
      _deactivateAudioSession();
      rethrow;
    }
    state = PcmSinkState.playing;
    _emitState();
    if (_inFlight.isEmpty) {
      // Starting before the first producer write may also stop AudioQueue, but
      // it is buffering rather than a media underrun. Refill still restarts it.
      _starvation.noteOpenTail(reportUnderrun: false);
      _observeStarvation(hasQueuedAudio: false);
    } else {
      _starvation.markRecovered();
    }
  }

  @override
  Future<void> pause() async {
    _ensureConfigured();
    _check(_api.pause(_queue), 'AudioQueuePause');
    _deactivateAudioSession();
    state = PcmSinkState.paused;
    _starvation.reset();
    _emitState();
  }

  @override
  Future<void> flush({required int generation}) async {
    _ensureConfigured();
    final currentFormat = format!;
    _closeQueue('PCM queue was flushed');
    this.generation = generation;
    try {
      _openQueue(currentFormat);
      state = PcmSinkState.paused;
      _emitState();
    } catch (_) {
      format = null;
      state = PcmSinkState.unconfigured;
      rethrow;
    }
  }

  @override
  Future<PcmPlaybackPosition> position() async {
    _ensureConfigured();
    final timestamp = _memory.allocate<_AudioTimeStamp>(
      sizeOf<_AudioTimeStamp>(),
    );
    try {
      final status = _api.getCurrentTime(_queue, nullptr, timestamp, nullptr);
      if (status == 0 &&
          (timestamp.ref.flags & _AudioQueueApi.sampleTimeValid) != 0) {
        final reported = timestamp.ref.sampleTime.floor();
        final bounded = reported > _totalFramesEnqueued
            ? _totalFramesEnqueued
            : reported;
        if (bounded >= _lastPositionFrames) {
          _lastPositionFrames = bounded;
        }
      }
    } finally {
      _memory.free(timestamp);
    }
    return PcmPlaybackPosition(
      generation: generation,
      frames: _lastPositionFrames,
      sampleRate: format!.sampleRate,
    );
  }

  @override
  Future<void> dispose() async {
    if (state == PcmSinkState.disposed) return;
    _closeQueue('sink was disposed');
    state = PcmSinkState.disposed;
    format = null;
    _emitState();
    await _events.close();
  }

  void _openQueue(PcmAudioFormat audioFormat) {
    final epoch = ++_queueEpoch;
    final bytesPerFrame = audioFormat.bytesPerFrame;
    final durationCapacity =
        (audioFormat.sampleRate * bytesPerFrame * 80) ~/ 1000;
    final minimumWriteCapacity = _minimumFramesPerBuffer * bytesPerFrame;
    _bufferCapacityBytes = durationCapacity < minimumWriteCapacity
        ? minimumWriteCapacity
        : durationCapacity;
    _bufferCapacityBytes = _bufferCapacityBytes.clamp(4096, 1024 * 1024);
    _bufferCapacityBytes -= _bufferCapacityBytes % bytesPerFrame;

    _api.prepareAudioSession(_memory);

    final description = _memory.allocate<_AudioStreamBasicDescription>(
      sizeOf<_AudioStreamBasicDescription>(),
    );
    final queueOut = _memory.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    final callback = NativeCallable<_AudioQueueOutputCallbackNative>.listener((
      Pointer<Void> userData,
      Pointer<Void> queue,
      Pointer<_AudioQueueBuffer> buffer,
    ) {
      _onBufferConsumed(epoch, buffer.address);
    });
    _callback = callback;

    try {
      description.ref
        ..sampleRate = audioFormat.sampleRate.toDouble()
        ..formatId = _AudioQueueApi.linearPcmFormat
        ..formatFlags =
            _AudioQueueApi.formatFlagSignedInteger |
            _AudioQueueApi.formatFlagPacked
        ..bytesPerPacket = bytesPerFrame
        ..framesPerPacket = 1
        ..bytesPerFrame = bytesPerFrame
        ..channelsPerFrame = audioFormat.channelCount
        ..bitsPerChannel = 16
        ..reserved = 0;

      _check(
        _api.newOutput(
          description,
          callback.nativeFunction,
          nullptr,
          nullptr,
          nullptr,
          0,
          queueOut,
        ),
        'AudioQueueNewOutput',
      );
      _queue = queueOut.value;
      if (_queue == nullptr) {
        throw StateError('AudioQueueNewOutput returned a null queue');
      }

      for (var i = 0; i < _bufferCount; i++) {
        final bufferOut = _memory.allocate<Pointer<_AudioQueueBuffer>>(
          sizeOf<Pointer<Void>>(),
        );
        try {
          _check(
            _api.allocateBuffer(_queue, _bufferCapacityBytes, bufferOut),
            'AudioQueueAllocateBuffer',
          );
          final buffer = bufferOut.value;
          if (buffer == nullptr) {
            throw StateError('AudioQueueAllocateBuffer returned null');
          }
          _freeBuffers.add(buffer);
        } finally {
          _memory.free(bufferOut);
        }
      }
      _lastPositionFrames = 0;
      _totalFramesEnqueued = 0;
      _starvation.reset();
    } catch (_) {
      _closeQueue('AudioQueue configuration failed');
      rethrow;
    } finally {
      _memory.free(queueOut);
      _memory.free(description);
    }
  }

  void _pumpPending() {
    if (_queue == nullptr) return;
    var enqueuedAny = false;
    while (_freeBuffers.isNotEmpty && _pending.isNotEmpty) {
      final write = _pending.removeFirst();
      if (write.generation != generation) {
        write.completer.completeError(
          PcmSinkStateException(
            'stale PCM generation ${write.generation}; active generation is '
            '$generation',
          ),
        );
        continue;
      }

      final buffer = _freeBuffers.removeFirst();
      final target = buffer.ref.audioData.cast<Uint8>().asTypedList(
        write.bytes.lengthInBytes,
      );
      target.setAll(0, write.bytes);
      buffer.ref.audioDataByteSize = write.bytes.lengthInBytes;
      final status = _api.enqueueBuffer(_queue, buffer, 0, nullptr);
      if (status != 0) {
        buffer.ref.audioDataByteSize = 0;
        _freeBuffers.addFirst(buffer);
        final error = PcmSinkStateException(
          'AudioQueueEnqueueBuffer failed with OSStatus $status',
        );
        write.completer.completeError(error);
        _emitError(error.message);
        continue;
      }

      _inFlight[buffer.address] = _AudioQueueInFlight(
        generation: generation,
        frames: write.frames,
      );
      _totalFramesEnqueued += write.frames;
      write.completer.complete(write.frames);
      enqueuedAny = true;
    }
    if (enqueuedAny) _observeStarvation(hasQueuedAudio: true);
  }

  void _onBufferConsumed(int epoch, int bufferAddress) {
    if (epoch != _queueEpoch || _queue == nullptr) return;
    final inFlight = _inFlight.remove(bufferAddress);
    if (inFlight == null) return;
    final buffer = Pointer<_AudioQueueBuffer>.fromAddress(bufferAddress);
    buffer.ref.audioDataByteSize = 0;
    _freeBuffers.add(buffer);
    if (_inFlight.isEmpty && state == PcmSinkState.playing) {
      _starvation.noteOpenTail();
    }
    if (inFlight.generation == generation && !_events.isClosed) {
      _events.add(
        PcmSinkEvent(
          type: PcmSinkEventType.bufferConsumed,
          generation: generation,
          frames: inFlight.frames,
        ),
      );
    }
    _pumpPending();
    if (_inFlight.isEmpty && state == PcmSinkState.playing) {
      _observeStarvation(hasQueuedAudio: false);
    }
  }

  void _observeStarvation({required bool hasQueuedAudio}) {
    if (state != PcmSinkState.playing || !_starvation.hasOpenTail) return;
    late final bool running;
    try {
      running = _api.isRunning(_queue, _memory);
    } catch (error) {
      _emitError('$error');
      return;
    }

    final decision = _starvation.observe(
      logicallyPlaying: true,
      queueIsRunning: running,
      hasQueuedAudio: hasQueuedAudio,
    );
    if (decision.emitUnderrun && !_events.isClosed) {
      _events.add(
        PcmSinkEvent(
          type: PcmSinkEventType.underrun,
          generation: generation,
          frames: 1,
          message: 'AudioQueue stopped after an open-tail PCM underrun',
        ),
      );
    }
    if (running && hasQueuedAudio) {
      _starvation.markRecovered();
      return;
    }
    if (!decision.restartQueue) return;

    try {
      _api.setAudioSessionActive(true);
      _audioSessionActive = Platform.isIOS;
      _check(
        _api.start(_queue, nullptr.cast<_AudioTimeStamp>()),
        'AudioQueueStart after underrun refill',
      );
      _starvation.markRecovered();
    } catch (error) {
      _emitError('$error');
    }
  }

  void _closeQueue(String pendingReason) {
    _queueEpoch++;
    _failPending(pendingReason);
    if (_queue != nullptr) {
      _api.dispose(_queue, 1);
      _queue = nullptr;
    }
    _deactivateAudioSession();
    _inFlight.clear();
    _freeBuffers.clear();
    _callback?.close();
    _callback = null;
    _bufferCapacityBytes = 0;
    _lastPositionFrames = 0;
    _totalFramesEnqueued = 0;
    _starvation.reset();
  }

  void _deactivateAudioSession() {
    if (!_audioSessionActive) return;
    try {
      _api.setAudioSessionActive(false);
    } catch (error) {
      _emitError('$error');
    } finally {
      _audioSessionActive = false;
    }
  }

  void _failPending(String reason) {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completer.completeError(
        PcmSinkStateException(reason),
      );
    }
  }

  void _check(int status, String operation) {
    if (status != 0) {
      throw PcmSinkStateException('$operation failed with OSStatus $status');
    }
  }

  void _ensureNotDisposed() {
    if (state == PcmSinkState.disposed) {
      throw const PcmSinkStateException('sink has been disposed');
    }
  }

  void _ensureConfigured() {
    _ensureNotDisposed();
    if (format == null ||
        state == PcmSinkState.unconfigured ||
        _queue == nullptr) {
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

  void _emitError(String message) {
    if (!_events.isClosed) {
      _events.add(
        PcmSinkEvent(
          type: PcmSinkEventType.error,
          generation: generation,
          message: message,
        ),
      );
    }
  }
}

final class _PendingAudioQueueWrite {
  _PendingAudioQueueWrite(this.bytes, this.frames, this.generation);

  final Uint8List bytes;
  final int frames;
  final int generation;
  final Completer<int> completer = Completer<int>();
}

final class _AudioQueueInFlight {
  const _AudioQueueInFlight({required this.generation, required this.frames});

  final int generation;
  final int frames;
}

final class _AudioStreamBasicDescription extends Struct {
  @Double()
  external double sampleRate;

  @Uint32()
  external int formatId;

  @Uint32()
  external int formatFlags;

  @Uint32()
  external int bytesPerPacket;

  @Uint32()
  external int framesPerPacket;

  @Uint32()
  external int bytesPerFrame;

  @Uint32()
  external int channelsPerFrame;

  @Uint32()
  external int bitsPerChannel;

  @Uint32()
  external int reserved;
}

final class _AudioQueueBuffer extends Struct {
  @Uint32()
  external int audioDataBytesCapacity;

  external Pointer<Void> audioData;

  @Uint32()
  external int audioDataByteSize;

  external Pointer<Void> userData;

  @Uint32()
  external int packetDescriptionCapacity;

  external Pointer<Void> packetDescriptions;

  @Uint32()
  external int packetDescriptionCount;
}

final class _SmpteTime extends Struct {
  @Int16()
  external int subframes;

  @Int16()
  external int subframeDivisor;

  @Uint32()
  external int counter;

  @Uint32()
  external int type;

  @Uint32()
  external int flags;

  @Int16()
  external int hours;

  @Int16()
  external int minutes;

  @Int16()
  external int seconds;

  @Int16()
  external int frames;
}

final class _AudioTimeStamp extends Struct {
  @Double()
  external double sampleTime;

  @Uint64()
  external int hostTime;

  @Double()
  external double rateScalar;

  @Uint64()
  external int wordClockTime;

  external _SmpteTime smpteTime;

  @Uint32()
  external int flags;

  @Uint32()
  external int reserved;
}

typedef _AudioQueueOutputCallbackNative =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<_AudioQueueBuffer>);
typedef _AudioQueueNewOutputNative =
    Int32 Function(
      Pointer<_AudioStreamBasicDescription>,
      Pointer<NativeFunction<_AudioQueueOutputCallbackNative>>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<Pointer<Void>>,
    );
typedef _AudioQueueNewOutputDart =
    int Function(
      Pointer<_AudioStreamBasicDescription>,
      Pointer<NativeFunction<_AudioQueueOutputCallbackNative>>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Pointer<Void>>,
    );
typedef _AudioQueueDisposeNative = Int32 Function(Pointer<Void>, Uint8);
typedef _AudioQueueDisposeDart = int Function(Pointer<Void>, int);
typedef _AudioQueueAllocateBufferNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<_AudioQueueBuffer>>);
typedef _AudioQueueAllocateBufferDart =
    int Function(Pointer<Void>, int, Pointer<Pointer<_AudioQueueBuffer>>);
typedef _AudioQueueEnqueueBufferNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<_AudioQueueBuffer>,
      Uint32,
      Pointer<Void>,
    );
typedef _AudioQueueEnqueueBufferDart =
    int Function(Pointer<Void>, Pointer<_AudioQueueBuffer>, int, Pointer<Void>);
typedef _AudioQueueStartNative =
    Int32 Function(Pointer<Void>, Pointer<_AudioTimeStamp>);
typedef _AudioQueueStartDart =
    int Function(Pointer<Void>, Pointer<_AudioTimeStamp>);
typedef _AudioQueuePauseNative = Int32 Function(Pointer<Void>);
typedef _AudioQueuePauseDart = int Function(Pointer<Void>);
typedef _AudioQueueGetCurrentTimeNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<_AudioTimeStamp>,
      Pointer<Uint8>,
    );
typedef _AudioQueueGetCurrentTimeDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<_AudioTimeStamp>,
      Pointer<Uint8>,
    );
typedef _AudioQueueGetPropertyNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>);
typedef _AudioQueueGetPropertyDart =
    int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>);
typedef _AudioSessionInitializeNative =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _AudioSessionInitializeDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _AudioSessionSetPropertyNative =
    Int32 Function(Uint32, Uint32, Pointer<Void>);
typedef _AudioSessionSetPropertyDart = int Function(int, int, Pointer<Void>);
typedef _AudioSessionSetActiveNative = Int32 Function(Uint8);
typedef _AudioSessionSetActiveDart = int Function(int);

final class _AudioQueueApi {
  _AudioQueueApi()
    : _library = Platform.isMacOS
          ? DynamicLibrary.open(
              '/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox',
            )
          : DynamicLibrary.process() {
    newOutput = _library
        .lookupFunction<_AudioQueueNewOutputNative, _AudioQueueNewOutputDart>(
          'AudioQueueNewOutput',
        );
    dispose = _library
        .lookupFunction<_AudioQueueDisposeNative, _AudioQueueDisposeDart>(
          'AudioQueueDispose',
        );
    allocateBuffer = _library
        .lookupFunction<
          _AudioQueueAllocateBufferNative,
          _AudioQueueAllocateBufferDart
        >('AudioQueueAllocateBuffer');
    enqueueBuffer = _library
        .lookupFunction<
          _AudioQueueEnqueueBufferNative,
          _AudioQueueEnqueueBufferDart
        >('AudioQueueEnqueueBuffer');
    start = _library
        .lookupFunction<_AudioQueueStartNative, _AudioQueueStartDart>(
          'AudioQueueStart',
        );
    pause = _library
        .lookupFunction<_AudioQueuePauseNative, _AudioQueuePauseDart>(
          'AudioQueuePause',
        );
    getCurrentTime = _library
        .lookupFunction<
          _AudioQueueGetCurrentTimeNative,
          _AudioQueueGetCurrentTimeDart
        >('AudioQueueGetCurrentTime');
    getProperty = _library
        .lookupFunction<
          _AudioQueueGetPropertyNative,
          _AudioQueueGetPropertyDart
        >('AudioQueueGetProperty');
    if (Platform.isIOS) {
      audioSessionInitialize = _library
          .lookupFunction<
            _AudioSessionInitializeNative,
            _AudioSessionInitializeDart
          >('AudioSessionInitialize');
      audioSessionSetProperty = _library
          .lookupFunction<
            _AudioSessionSetPropertyNative,
            _AudioSessionSetPropertyDart
          >('AudioSessionSetProperty');
      audioSessionSetActive = _library
          .lookupFunction<
            _AudioSessionSetActiveNative,
            _AudioSessionSetActiveDart
          >('AudioSessionSetActive');
    }
  }

  static const int linearPcmFormat = 0x6c70636d; // 'lpcm'
  static const int formatFlagSignedInteger = 1 << 2;
  static const int formatFlagPacked = 1 << 3;
  static const int sampleTimeValid = 1 << 0;
  static const int propertyIsRunning = 0x6171726e; // 'aqrn'
  static const int audioSessionAlreadyInitialized = 0x696e6974; // 'init'
  static const int audioSessionPropertyCategory = 0x61636174; // 'acat'
  static const int audioSessionCategoryMediaPlayback = 0x6d656469; // 'medi'

  final DynamicLibrary _library;
  late final _AudioQueueNewOutputDart newOutput;
  late final _AudioQueueDisposeDart dispose;
  late final _AudioQueueAllocateBufferDart allocateBuffer;
  late final _AudioQueueEnqueueBufferDart enqueueBuffer;
  late final _AudioQueueStartDart start;
  late final _AudioQueuePauseDart pause;
  late final _AudioQueueGetCurrentTimeDart getCurrentTime;
  late final _AudioQueueGetPropertyDart getProperty;
  _AudioSessionInitializeDart? audioSessionInitialize;
  _AudioSessionSetPropertyDart? audioSessionSetProperty;
  _AudioSessionSetActiveDart? audioSessionSetActive;

  void prepareAudioSession(NativeMemory memory) {
    final initialize = audioSessionInitialize;
    final setProperty = audioSessionSetProperty;
    if (initialize == null || setProperty == null) return;

    final initializeStatus = initialize(nullptr, nullptr, nullptr, nullptr);
    if (initializeStatus != 0 &&
        initializeStatus != audioSessionAlreadyInitialized) {
      throw PcmSinkStateException(
        'AudioSessionInitialize failed with OSStatus $initializeStatus',
      );
    }

    final category = memory.allocate<Uint32>(sizeOf<Uint32>());
    try {
      category.value = audioSessionCategoryMediaPlayback;
      final status = setProperty(
        audioSessionPropertyCategory,
        sizeOf<Uint32>(),
        category.cast<Void>(),
      );
      if (status != 0) {
        throw PcmSinkStateException(
          'AudioSessionSetProperty(category) failed with OSStatus $status',
        );
      }
    } finally {
      memory.free(category);
    }
  }

  void setAudioSessionActive(bool active) {
    final setActive = audioSessionSetActive;
    if (setActive == null) return;
    final status = setActive(active ? 1 : 0);
    if (status != 0) {
      throw PcmSinkStateException(
        'AudioSessionSetActive($active) failed with OSStatus $status',
      );
    }
  }

  bool isRunning(Pointer<Void> queue, NativeMemory memory) {
    final running = memory.allocate<Uint32>(sizeOf<Uint32>());
    final valueSize = memory.allocate<Uint32>(sizeOf<Uint32>());
    try {
      valueSize.value = sizeOf<Uint32>();
      final status = getProperty(
        queue,
        propertyIsRunning,
        running.cast<Void>(),
        valueSize,
      );
      if (status != 0) {
        throw PcmSinkStateException(
          'AudioQueueGetProperty(IsRunning) failed with OSStatus $status',
        );
      }
      if (valueSize.value != sizeOf<Uint32>()) {
        throw PcmSinkStateException(
          'AudioQueueGetProperty(IsRunning) returned '
          '${valueSize.value} bytes',
        );
      }
      return running.value != 0;
    } finally {
      memory.free(valueSize);
      memory.free(running);
    }
  }
}
