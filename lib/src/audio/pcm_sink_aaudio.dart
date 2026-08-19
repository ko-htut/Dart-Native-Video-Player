import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'native_memory.dart';
import 'pcm_sink_api.dart';

final class AAudioPcmAudioSink implements PcmAudioSink {
  AAudioPcmAudioSink._(this._isolate, this._receivePort, this._commandPort);

  static Future<AAudioPcmAudioSink> create() async {
    final receivePort = ReceivePort();
    final ready = Completer<SendPort>();
    final startupError = Completer<Object>();
    AAudioPcmAudioSink? sink;

    late final StreamSubscription<Object?> subscription;
    subscription = receivePort.listen((message) {
      if (message is List && message.isNotEmpty && message[0] == 'ready') {
        if (!ready.isCompleted) ready.complete(message[1] as SendPort);
        return;
      }
      if (message is List && message.isNotEmpty && message[0] == 'fatal') {
        final error = PcmSinkStateException(message[1] as String);
        if (!ready.isCompleted && !startupError.isCompleted) {
          startupError.complete(error);
        } else {
          sink?._emitError(error.message);
        }
        return;
      }
      sink?._onWorkerMessage(message);
    });

    final isolate = await Isolate.spawn<SendPort>(
      _aaudioWorkerMain,
      receivePort.sendPort,
      debugName: 'ndvy-AAudio-writer',
    );

    try {
      final commandPort = await Future.any<SendPort>([
        ready.future,
        startupError.future.then<SendPort>((error) => throw error),
      ]);
      sink = AAudioPcmAudioSink._(isolate, receivePort, commandPort)
        .._subscription = subscription;
      return sink;
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      receivePort.close();
      rethrow;
    }
  }

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final SendPort _commandPort;
  late final StreamSubscription<Object?> _subscription;
  final StreamController<PcmSinkEvent> _events =
      StreamController<PcmSinkEvent>.broadcast(sync: true);
  final Map<int, Completer<Object?>> _requests = <int, Completer<Object?>>{};

  int _nextRequestId = 1;

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
    await _request('configure', <Object?>[
      newFormat.sampleRate,
      newFormat.channelCount,
      generation,
    ]);
    format = newFormat;
    this.generation = generation;
    state = PcmSinkState.paused;
    _emitState();
  }

  @override
  Future<int> enqueue(
    Uint8List interleavedPcm, {
    required int generation,
  }) async {
    validatePcmWrite(
      format,
      state,
      this.generation,
      interleavedPcm,
      generation,
    );
    if (interleavedPcm.isEmpty) return 0;
    final transferable = TransferableTypedData.fromList(<TypedData>[
      interleavedPcm,
    ]);
    final result = await _request('enqueue', <Object?>[
      generation,
      transferable,
    ]);
    return result as int;
  }

  @override
  Future<void> play() async {
    _ensureConfigured();
    await _request('play');
    state = PcmSinkState.playing;
    _emitState();
  }

  @override
  Future<void> pause() async {
    _ensureConfigured();
    await _request('pause');
    state = PcmSinkState.paused;
    _emitState();
  }

  @override
  Future<void> flush({required int generation}) async {
    _ensureConfigured();
    await _request('flush', <Object?>[generation]);
    this.generation = generation;
    state = PcmSinkState.paused;
    _emitState();
  }

  @override
  Future<PcmPlaybackPosition> position() async {
    _ensureConfigured();
    final frames = await _request('position') as int;
    return PcmPlaybackPosition(
      generation: generation,
      frames: frames,
      sampleRate: format!.sampleRate,
    );
  }

  @override
  Future<void> dispose() async {
    if (state == PcmSinkState.disposed) return;
    try {
      await _request('dispose');
    } finally {
      state = PcmSinkState.disposed;
      format = null;
      _emitState();
      for (final completer in _requests.values) {
        if (!completer.isCompleted) {
          completer.completeError(
            const PcmSinkStateException('sink was disposed'),
          );
        }
      }
      _requests.clear();
      await _subscription.cancel();
      _receivePort.close();
      _isolate.kill(priority: Isolate.immediate);
      await _events.close();
    }
  }

  Future<Object?> _request(String operation, [List<Object?>? arguments]) {
    _ensureNotDisposed();
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _requests[id] = completer;
    _commandPort.send(<Object?>[id, operation, ...?arguments]);
    return completer.future;
  }

  void _onWorkerMessage(Object? message) {
    if (message is! List || message.isEmpty) return;
    final id = message[0];
    if (id == 0) {
      final kind = message[1] as String;
      if (kind == 'consumed') {
        _events.add(
          PcmSinkEvent(
            type: PcmSinkEventType.bufferConsumed,
            generation: message[2] as int,
            frames: message[3] as int,
          ),
        );
      } else if (kind == 'underrun') {
        _events.add(
          PcmSinkEvent(
            type: PcmSinkEventType.underrun,
            generation: message[2] as int,
            frames: message[3] as int,
          ),
        );
      } else if (kind == 'error') {
        _emitError(message[2] as String);
      }
      return;
    }

    if (id is! int) return;
    final completer = _requests.remove(id);
    if (completer == null || completer.isCompleted) return;
    final succeeded = message[1] as bool;
    if (succeeded) {
      completer.complete(message.length > 2 ? message[2] : null);
    } else {
      completer.completeError(PcmSinkStateException(message[2] as String));
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
}

@pragma('vm:entry-point')
void _aaudioWorkerMain(SendPort ownerPort) {
  try {
    final worker = _AAudioWorker(ownerPort);
    ownerPort.send(<Object?>['ready', worker.commandPort]);
  } catch (error, stackTrace) {
    ownerPort.send(<Object?>['fatal', '$error\n$stackTrace']);
  }
}

final class _AAudioWorker {
  _AAudioWorker(this._ownerPort) : _api = _AAudioApi() {
    _commands.listen(_handleCommand);
  }

  static const int _minimumBufferedFrames = 2048;

  final SendPort _ownerPort;
  final ReceivePort _commands = ReceivePort();
  final _AAudioApi _api;
  final Queue<_AAudioWrite> _writes = Queue<_AAudioWrite>();
  final Queue<_AAudioWrite> _waitingWrites = Queue<_AAudioWrite>();
  Timer? _pumpTimer;

  Pointer<_AAudioStream> _stream = nullptr;
  int _sampleRate = 0;
  int _channelCount = 0;
  int _generation = 0;
  int _lastFramesRead = 0;
  int _lastXRunCount = 0;
  int _totalFramesAccepted = 0;
  int _outstandingFrames = 0;
  int _maxBufferedFrames = 0;
  bool _playing = false;

  SendPort get commandPort => _commands.sendPort;
  int get _bytesPerFrame => _channelCount * 2;

  void _handleCommand(Object? raw) {
    if (raw is! List || raw.length < 2) return;
    final id = raw[0] as int;
    final operation = raw[1] as String;
    try {
      switch (operation) {
        case 'configure':
          _configure(raw[2] as int, raw[3] as int, raw[4] as int);
          _ok(id);
        case 'enqueue':
          _enqueue(id, raw[2] as int, raw[3] as TransferableTypedData);
        case 'play':
          _requireStream();
          _check(_api.requestStart(_stream), 'AAudioStream_requestStart');
          _playing = true;
          _ensurePump();
          _ok(id);
        case 'pause':
          _requireStream();
          _check(_api.requestPause(_stream), 'AAudioStream_requestPause');
          _waitForState(_AAudioApi.streamStatePaused, 'AAudio stream pause');
          _playing = false;
          _ok(id);
        case 'flush':
          _requireStream();
          final newGeneration = raw[2] as int;
          final rate = _sampleRate;
          final channels = _channelCount;
          _failWrites('PCM queue was flushed');
          _closeStream();
          _configure(rate, channels, newGeneration);
          _ok(id);
        case 'position':
          _requireStream();
          _reportConsumption();
          _ok(id, _playbackPositionFrames());
        case 'dispose':
          _failWrites('sink was disposed');
          _closeStream();
          _ok(id);
          _commands.close();
          Isolate.exit();
        default:
          _error(id, 'unknown AAudio worker operation: $operation');
      }
    } catch (error, stackTrace) {
      _error(id, '$error\n$stackTrace');
    }
  }

  void _configure(int sampleRate, int channelCount, int generation) {
    if (sampleRate < 8000 || sampleRate > 192000) {
      throw RangeError.range(sampleRate, 8000, 192000, 'sampleRate');
    }
    if (channelCount < 1 || channelCount > 8) {
      throw RangeError.range(channelCount, 1, 8, 'channelCount');
    }

    _failWrites('sink was reconfigured');
    _closeStream();

    final memory = NativeMemory.instance;
    final builderOut = memory.allocate<Pointer<_AAudioStreamBuilder>>(
      sizeOf<Pointer<Void>>(),
    );
    Pointer<_AAudioStreamBuilder> builder = nullptr;
    try {
      _check(
        _api.createStreamBuilder(builderOut),
        'AAudio_createStreamBuilder',
      );
      builder = builderOut.value;
      if (builder == nullptr) {
        throw StateError('AAudio returned a null stream builder');
      }
      _api.setDirection(builder, _AAudioApi.directionOutput);
      _api.setSampleRate(builder, sampleRate);
      _api.setChannelCount(builder, channelCount);
      _api.setFormat(builder, _AAudioApi.formatPcmI16);
      _api.setSharingMode(builder, _AAudioApi.sharingModeShared);
      _api.setBufferCapacityInFrames(builder, (sampleRate * 40) ~/ 1000);

      final streamOut = memory.allocate<Pointer<_AAudioStream>>(
        sizeOf<Pointer<Void>>(),
      );
      try {
        _check(
          _api.openStream(builder, streamOut),
          'AAudioStreamBuilder_openStream',
        );
        _stream = streamOut.value;
      } finally {
        memory.free(streamOut);
      }
    } finally {
      if (builder != nullptr) _api.deleteStreamBuilder(builder);
      memory.free(builderOut);
    }

    if (_stream == nullptr) throw StateError('AAudio returned a null stream');
    final actualRate = _api.getSampleRate(_stream);
    final actualChannels = _api.getChannelCount(_stream);
    final actualFormat = _api.getFormat(_stream);
    if (actualRate != sampleRate ||
        actualChannels != channelCount ||
        actualFormat != _AAudioApi.formatPcmI16) {
      _closeStream();
      throw StateError(
        'AAudio format mismatch: requested ${sampleRate}Hz/$channelCount/S16, '
        'opened ${actualRate}Hz/$actualChannels/format=$actualFormat',
      );
    }

    final requestedBufferFrames = (sampleRate * 40) ~/ 1000;
    final actualBufferFrames = _api.setBufferSizeInFrames(
      _stream,
      requestedBufferFrames,
    );
    _check(actualBufferFrames, 'AAudioStream_setBufferSizeInFrames');

    _sampleRate = sampleRate;
    _channelCount = channelCount;
    _generation = generation;
    _lastFramesRead = 0;
    _lastXRunCount = 0;
    _totalFramesAccepted = 0;
    _outstandingFrames = 0;
    final durationBufferedFrames = (sampleRate * 250) ~/ 1000;
    _maxBufferedFrames = durationBufferedFrames < _minimumBufferedFrames
        ? _minimumBufferedFrames
        : durationBufferedFrames;
    _playing = false;
    _ensurePump();
  }

  void _enqueue(int id, int generation, TransferableTypedData transferable) {
    _requireStream();
    if (generation != _generation) {
      _error(
        id,
        'stale PCM generation $generation; active generation is $_generation',
      );
      return;
    }

    final bytes = transferable.materialize().asUint8List();
    if (bytes.lengthInBytes % _bytesPerFrame != 0) {
      _error(id, 'PCM byte length is not frame-aligned');
      return;
    }
    if (bytes.isEmpty) {
      _ok(id, 0);
      return;
    }

    final totalFrames = bytes.lengthInBytes ~/ _bytesPerFrame;
    if (totalFrames > _maxBufferedFrames) {
      _error(
        id,
        'PCM write has $totalFrames frames, exceeding the bounded '
        '$_maxBufferedFrames-frame AAudio queue',
      );
      return;
    }

    final data = NativeMemory.instance.allocate<Uint8>(bytes.lengthInBytes);
    data.asTypedList(bytes.lengthInBytes).setAll(0, bytes);
    final write = _AAudioWrite(
      requestId: id,
      generation: generation,
      data: data,
      totalFrames: totalFrames,
    );
    if (_outstandingFrames + totalFrames <= _maxBufferedFrames) {
      _acceptWrite(write);
    } else {
      _waitingWrites.add(write);
    }
  }

  void _acceptWrite(_AAudioWrite write) {
    _outstandingFrames += write.totalFrames;
    _writes.add(write);
    _ok(write.requestId, write.totalFrames);
    _ensurePump();
  }

  void _acceptWaitingWrites() {
    while (_waitingWrites.isNotEmpty) {
      final write = _waitingWrites.first;
      if (write.generation != _generation) {
        _waitingWrites.removeFirst();
        NativeMemory.instance.free(write.data);
        _error(write.requestId, 'stale PCM write discarded');
        continue;
      }
      if (_outstandingFrames + write.totalFrames > _maxBufferedFrames) return;
      _waitingWrites.removeFirst();
      _outstandingFrames += write.totalFrames;
      _writes.add(write);
      _ok(write.requestId, write.totalFrames);
    }
  }

  void _ensurePump() {
    _pumpTimer ??= Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => _pump(),
    );
    _pump();
  }

  void _pump() {
    if (_stream == nullptr) return;
    _reportConsumption();
    if (_writes.isEmpty) return;

    final write = _writes.first;
    if (write.generation != _generation) {
      _writes.removeFirst();
      NativeMemory.instance.free(write.data);
      _discardOutstandingFrames(write.totalFrames - write.framesWritten);
      _ownerPort.send(<Object?>[0, 'error', 'stale PCM write discarded']);
      _acceptWaitingWrites();
      return;
    }

    final remainingFrames = write.totalFrames - write.framesWritten;
    final byteOffset = write.framesWritten * _bytesPerFrame;
    final result = _api.write(
      _stream,
      (write.data + byteOffset).cast<Void>(),
      remainingFrames,
      0,
    );
    if (result < 0) {
      _writes.removeFirst();
      NativeMemory.instance.free(write.data);
      _discardOutstandingFrames(write.totalFrames - write.framesWritten);
      final message = 'AAudioStream_write failed with result $result';
      _ownerPort.send(<Object?>[0, 'error', message]);
      _acceptWaitingWrites();
      return;
    }
    if (result == 0) return;

    write.framesWritten += result;
    _totalFramesAccepted += result;
    if (write.framesWritten == write.totalFrames) {
      _writes.removeFirst();
      NativeMemory.instance.free(write.data);
      if (_writes.isNotEmpty) _pump();
    }
  }

  void _reportConsumption() {
    if (_stream == nullptr) return;
    final framesRead = _safeFramesRead();
    if (framesRead > _lastFramesRead) {
      final consumed = framesRead - _lastFramesRead;
      _lastFramesRead = framesRead;
      _discardOutstandingFrames(consumed);
      _ownerPort.send(<Object?>[0, 'consumed', _generation, consumed]);
      _acceptWaitingWrites();
    }
    final xRuns = _api.getXRunCount(_stream);
    if (xRuns > _lastXRunCount) {
      final newXRuns = xRuns - _lastXRunCount;
      _lastXRunCount = xRuns;
      _ownerPort.send(<Object?>[0, 'underrun', _generation, newXRuns]);
    }
  }

  int _safeFramesRead() {
    if (_stream == nullptr) return 0;
    final value = _api.getFramesRead(_stream);
    if (value < 0) return 0;
    return value > _totalFramesAccepted ? _totalFramesAccepted : value;
  }

  int _playbackPositionFrames() {
    if (_stream == nullptr) return 0;
    final memory = NativeMemory.instance;
    final framePosition = memory.allocate<Int64>(sizeOf<Int64>());
    final timestampNanos = memory.allocate<Int64>(sizeOf<Int64>());
    try {
      final result = _api.getTimestamp(
        _stream,
        _AAudioApi.clockMonotonic,
        framePosition,
        timestampNanos,
      );
      if (result == 0 && framePosition.value >= 0) {
        final value = framePosition.value;
        return value > _totalFramesAccepted ? _totalFramesAccepted : value;
      }
      return _safeFramesRead();
    } finally {
      memory.free(timestampNanos);
      memory.free(framePosition);
    }
  }

  void _waitForState(int targetState, String operation) {
    final nextState = NativeMemory.instance.allocate<Int32>(sizeOf<Int32>());
    try {
      var currentState = _api.getState(_stream);
      for (
        var attempt = 0;
        attempt < 20 && currentState != targetState;
        attempt++
      ) {
        final result = _api.waitForStateChange(
          _stream,
          currentState,
          nextState,
          const Duration(milliseconds: 100).inMicroseconds * 1000,
        );
        if (result == _AAudioApi.errorTimeout) continue;
        _check(result, 'AAudioStream_waitForStateChange');
        currentState = nextState.value;
      }
      if (currentState != targetState) {
        throw StateError(
          '$operation timed out in state $currentState; expected $targetState',
        );
      }
    } finally {
      NativeMemory.instance.free(nextState);
    }
  }

  void _closeStream() {
    _pumpTimer?.cancel();
    _pumpTimer = null;
    if (_stream != nullptr) {
      if (_playing) _api.requestPause(_stream);
      _api.closeStream(_stream);
      _stream = nullptr;
    }
    _playing = false;
  }

  void _failWrites(String message) {
    while (_writes.isNotEmpty) {
      final write = _writes.removeFirst();
      NativeMemory.instance.free(write.data);
    }
    while (_waitingWrites.isNotEmpty) {
      final write = _waitingWrites.removeFirst();
      NativeMemory.instance.free(write.data);
      _error(write.requestId, message);
    }
    _outstandingFrames = 0;
  }

  void _discardOutstandingFrames(int frames) {
    _outstandingFrames -= frames;
    if (_outstandingFrames < 0) _outstandingFrames = 0;
  }

  void _requireStream() {
    if (_stream == nullptr) throw StateError('AAudio sink is not configured');
  }

  void _check(int result, String operation) {
    if (result < 0) throw StateError('$operation failed with result $result');
  }

  void _ok(int id, [Object? value]) =>
      _ownerPort.send(<Object?>[id, true, value]);

  void _error(int id, String message) =>
      _ownerPort.send(<Object?>[id, false, message]);
}

final class _AAudioWrite {
  _AAudioWrite({
    required this.requestId,
    required this.generation,
    required this.data,
    required this.totalFrames,
  });

  final int requestId;
  final int generation;
  final Pointer<Uint8> data;
  final int totalFrames;
  int framesWritten = 0;
}

final class _AAudioStreamBuilder extends Opaque {}

final class _AAudioStream extends Opaque {}

typedef _CreateBuilderNative =
    Int32 Function(Pointer<Pointer<_AAudioStreamBuilder>>);
typedef _CreateBuilderDart =
    int Function(Pointer<Pointer<_AAudioStreamBuilder>>);
typedef _BuilderIntNative = Void Function(Pointer<_AAudioStreamBuilder>, Int32);
typedef _BuilderIntDart = void Function(Pointer<_AAudioStreamBuilder>, int);
typedef _OpenStreamNative =
    Int32 Function(
      Pointer<_AAudioStreamBuilder>,
      Pointer<Pointer<_AAudioStream>>,
    );
typedef _OpenStreamDart =
    int Function(
      Pointer<_AAudioStreamBuilder>,
      Pointer<Pointer<_AAudioStream>>,
    );
typedef _DeleteBuilderNative = Int32 Function(Pointer<_AAudioStreamBuilder>);
typedef _DeleteBuilderDart = int Function(Pointer<_AAudioStreamBuilder>);
typedef _StreamControlNative = Int32 Function(Pointer<_AAudioStream>);
typedef _StreamControlDart = int Function(Pointer<_AAudioStream>);
typedef _StreamWriteNative =
    Int32 Function(Pointer<_AAudioStream>, Pointer<Void>, Int32, Int64);
typedef _StreamWriteDart =
    int Function(Pointer<_AAudioStream>, Pointer<Void>, int, int);
typedef _StreamSetIntNative = Int32 Function(Pointer<_AAudioStream>, Int32);
typedef _StreamSetIntDart = int Function(Pointer<_AAudioStream>, int);
typedef _StreamInt32Native = Int32 Function(Pointer<_AAudioStream>);
typedef _StreamInt32Dart = int Function(Pointer<_AAudioStream>);
typedef _StreamInt64Native = Int64 Function(Pointer<_AAudioStream>);
typedef _StreamInt64Dart = int Function(Pointer<_AAudioStream>);
typedef _WaitForStateNative =
    Int32 Function(Pointer<_AAudioStream>, Int32, Pointer<Int32>, Int64);
typedef _WaitForStateDart =
    int Function(Pointer<_AAudioStream>, int, Pointer<Int32>, int);
typedef _StreamTimestampNative =
    Int32 Function(
      Pointer<_AAudioStream>,
      Int32,
      Pointer<Int64>,
      Pointer<Int64>,
    );
typedef _StreamTimestampDart =
    int Function(Pointer<_AAudioStream>, int, Pointer<Int64>, Pointer<Int64>);

final class _AAudioApi {
  _AAudioApi() : _library = DynamicLibrary.open('libaaudio.so') {
    createStreamBuilder = _library
        .lookupFunction<_CreateBuilderNative, _CreateBuilderDart>(
          'AAudio_createStreamBuilder',
        );
    setDirection = _builderInt('AAudioStreamBuilder_setDirection');
    setSampleRate = _builderInt('AAudioStreamBuilder_setSampleRate');
    setChannelCount = _builderInt('AAudioStreamBuilder_setChannelCount');
    setFormat = _builderInt('AAudioStreamBuilder_setFormat');
    setSharingMode = _builderInt('AAudioStreamBuilder_setSharingMode');
    setBufferCapacityInFrames = _builderInt(
      'AAudioStreamBuilder_setBufferCapacityInFrames',
    );
    openStream = _library.lookupFunction<_OpenStreamNative, _OpenStreamDart>(
      'AAudioStreamBuilder_openStream',
    );
    deleteStreamBuilder = _library
        .lookupFunction<_DeleteBuilderNative, _DeleteBuilderDart>(
          'AAudioStreamBuilder_delete',
        );
    closeStream = _streamControl('AAudioStream_close');
    requestStart = _streamControl('AAudioStream_requestStart');
    requestPause = _streamControl('AAudioStream_requestPause');
    write = _library.lookupFunction<_StreamWriteNative, _StreamWriteDart>(
      'AAudioStream_write',
    );
    setBufferSizeInFrames = _library
        .lookupFunction<_StreamSetIntNative, _StreamSetIntDart>(
          'AAudioStream_setBufferSizeInFrames',
        );
    getFramesRead = _streamInt64('AAudioStream_getFramesRead');
    getTimestamp = _library
        .lookupFunction<_StreamTimestampNative, _StreamTimestampDart>(
          'AAudioStream_getTimestamp',
        );
    getXRunCount = _streamInt32('AAudioStream_getXRunCount');
    getSampleRate = _streamInt32('AAudioStream_getSampleRate');
    getChannelCount = _streamInt32('AAudioStream_getChannelCount');
    getFormat = _streamInt32('AAudioStream_getFormat');
    getState = _streamInt32('AAudioStream_getState');
    waitForStateChange = _library
        .lookupFunction<_WaitForStateNative, _WaitForStateDart>(
          'AAudioStream_waitForStateChange',
        );
  }

  static const int directionOutput = 0;
  static const int formatPcmI16 = 1;
  static const int sharingModeShared = 1;
  static const int clockMonotonic = 1;
  static const int streamStatePaused = 6;
  static const int errorTimeout = -885;

  final DynamicLibrary _library;
  late final _CreateBuilderDart createStreamBuilder;
  late final _BuilderIntDart setDirection;
  late final _BuilderIntDart setSampleRate;
  late final _BuilderIntDart setChannelCount;
  late final _BuilderIntDart setFormat;
  late final _BuilderIntDart setSharingMode;
  late final _BuilderIntDart setBufferCapacityInFrames;
  late final _OpenStreamDart openStream;
  late final _DeleteBuilderDart deleteStreamBuilder;
  late final _StreamControlDart closeStream;
  late final _StreamControlDart requestStart;
  late final _StreamControlDart requestPause;
  late final _StreamWriteDart write;
  late final _StreamSetIntDart setBufferSizeInFrames;
  late final _StreamInt64Dart getFramesRead;
  late final _StreamTimestampDart getTimestamp;
  late final _StreamInt32Dart getXRunCount;
  late final _StreamInt32Dart getSampleRate;
  late final _StreamInt32Dart getChannelCount;
  late final _StreamInt32Dart getFormat;
  late final _StreamInt32Dart getState;
  late final _WaitForStateDart waitForStateChange;

  _BuilderIntDart _builderInt(String symbol) =>
      _library.lookupFunction<_BuilderIntNative, _BuilderIntDart>(symbol);

  _StreamControlDart _streamControl(String symbol) =>
      _library.lookupFunction<_StreamControlNative, _StreamControlDart>(symbol);

  _StreamInt32Dart _streamInt32(String symbol) =>
      _library.lookupFunction<_StreamInt32Native, _StreamInt32Dart>(symbol);

  _StreamInt64Dart _streamInt64(String symbol) =>
      _library.lookupFunction<_StreamInt64Native, _StreamInt64Dart>(symbol);
}
