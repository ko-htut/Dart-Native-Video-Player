import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'aac/adts.dart';
import 'aac/audio_specific_config.dart';
import 'aac/decoder.dart';
import 'pcm_source.dart';

/// A persistent worker-isolate AAC-LC decoder backed by a growing PCM file.
///
/// One [AacLcDecoder] remains alive for the complete session, preserving
/// filterbank overlap and noise state across [push] and [pushAll] calls. Each
/// push is backpressured until its frames have been decoded and committed to
/// [source]. The worker sends decoded frames incrementally rather than
/// retaining a decoded segment in the Dart heap.
///
/// The decoder does not own [source] storage after [start] succeeds. Loading
/// [source] into `AudioPlaybackController` transfers that ownership to the
/// controller. [dispose] stops the worker and unblocks tail reads, while
/// `dispose(disposeSource: true)` is available before ownership is transferred.
final class StreamingAacPcmDecoder {
  StreamingAacPcmDecoder._({
    required this.source,
    required this.originPts90k,
    required this.maxAccessUnitsPerPush,
    required this.maxCompressedBytesPerPush,
    required ReceivePort responses,
  }) : _responses = responses {
    // Isolate.spawn itself can fail before start() reaches its await. Attach an
    // error handler immediately so failing the readiness completer during
    // cleanup cannot surface as an unrelated unhandled async error.
    _ready.future.ignore();
    _responseSubscription = responses.listen(_handleWorkerMessage);
  }

  static Future<StreamingAacPcmDecoder> start({
    required AudioSpecificConfig config,
    required int originPts90k,
    int basePtsUs = 0,
    Duration maxGap = const Duration(seconds: 10),
    Duration? maxRetainedPcmDuration,
    int? maxRetainedPcmBytes,
    int maxAccessUnitsPerPush = 512,
    int maxCompressedBytesPerPush = 8 * 1024 * 1024,
  }) async {
    final channels = config.channelCount;
    if (channels == null || channels <= 0) {
      throw FormatException(
        'Streaming AAC requires an explicit channel configuration',
      );
    }
    if (maxAccessUnitsPerPush <= 0) {
      throw ArgumentError.value(maxAccessUnitsPerPush, 'maxAccessUnitsPerPush');
    }
    if (maxCompressedBytesPerPush <= 0) {
      throw ArgumentError.value(
        maxCompressedBytesPerPush,
        'maxCompressedBytesPerPush',
      );
    }
    final source = GrowingFilePcmAudioSource.create(
      sampleRate: config.samplingFrequency,
      channels: channels,
      basePtsUs: basePtsUs,
      maxGap: maxGap,
      maxRetainedDuration: maxRetainedPcmDuration,
      maxRetainedBytes: maxRetainedPcmBytes,
    );
    final responses = ReceivePort();
    final decoder = StreamingAacPcmDecoder._(
      source: source,
      originPts90k: originPts90k,
      maxAccessUnitsPerPush: maxAccessUnitsPerPush,
      maxCompressedBytesPerPush: maxCompressedBytesPerPush,
      responses: responses,
    );
    try {
      decoder._isolate = await Isolate.spawn<_AacWorkerStart>(
        _aacWorkerMain,
        _AacWorkerStart(responses.sendPort, config.bytes),
        onError: responses.sendPort,
        onExit: responses.sendPort,
        errorsAreFatal: true,
        debugName: 'ndvy-aac-stream',
      );
      await decoder._ready.future;
      return decoder;
    } catch (error, stackTrace) {
      decoder._failSession(error, stackTrace);
      await decoder._closePortsAndWorker();
      await source.dispose();
      rethrow;
    }
  }

  final GrowingFilePcmAudioSource source;
  final int originPts90k;
  final int maxAccessUnitsPerPush;
  final int maxCompressedBytesPerPush;
  final ReceivePort _responses;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _workerExited = Completer<void>();
  final Map<int, Completer<void>> _pending = <int, Completer<void>>{};

  late final StreamSubscription<Object?> _responseSubscription;
  Isolate? _isolate;
  SendPort? _commands;
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _sealFuture;
  Future<void>? _decoderDisposeFuture;
  Future<void>? _closePortsFuture;
  int _nextRequestId = 1;
  int? _epochOffset;
  int _decodedAccessUnitCount = 0;
  bool _expectingExit = false;
  bool _terminal = false;

  int get decodedAccessUnitCount => _decodedAccessUnitCount;
  bool get isClosed => _terminal;

  Future<void> push(AacAccessUnit accessUnit) =>
      pushAll(<AacAccessUnit>[accessUnit]);

  /// Decodes and commits [accessUnits] in order with bounded backpressure.
  Future<void> pushAll(Iterable<AacAccessUnit> accessUnits) {
    final mutableBatch = <AacAccessUnit>[];
    var compressedBytes = 0;
    for (final accessUnit in accessUnits) {
      if (mutableBatch.length >= maxAccessUnitsPerPush) {
        return Future<void>.error(
          RangeError.value(
            mutableBatch.length + 1,
            'accessUnits',
            'one push exceeds the $maxAccessUnitsPerPush-access-unit limit',
          ),
        );
      }
      compressedBytes += accessUnit.payload.lengthInBytes;
      if (compressedBytes > maxCompressedBytesPerPush) {
        return Future<void>.error(
          RangeError.value(
            compressedBytes,
            'accessUnits',
            'one push exceeds the $maxCompressedBytesPerPush-byte limit',
          ),
        );
      }
      mutableBatch.add(accessUnit);
    }
    final batch = List<AacAccessUnit>.unmodifiable(mutableBatch);
    if (batch.isEmpty) {
      return _terminal
          ? Future<void>.error(StateError('Streaming AAC decoder is closed'))
          : Future<void>.value();
    }
    final result = _operationTail.then((_) => _sendBatch(batch));
    _operationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  /// Decodes an arbitrarily sized ordered iterable as bounded worker pushes.
  ///
  /// Each individual access unit must still fit [maxCompressedBytesPerPush].
  /// Completed chunks remain committed if a later iterable element or worker
  /// chunk fails, matching the incremental nature of a rolling stream.
  Future<void> pushAllChunked(Iterable<AacAccessUnit> accessUnits) async {
    var batch = <AacAccessUnit>[];
    var compressedBytes = 0;

    for (final accessUnit in accessUnits) {
      final unitBytes = accessUnit.payload.lengthInBytes;
      if (unitBytes > maxCompressedBytesPerPush) {
        throw RangeError.value(
          unitBytes,
          'accessUnits',
          'one access unit exceeds the $maxCompressedBytesPerPush-byte limit',
        );
      }
      if (batch.isNotEmpty &&
          (batch.length == maxAccessUnitsPerPush ||
              compressedBytes + unitBytes > maxCompressedBytesPerPush)) {
        await pushAll(batch);
        batch = <AacAccessUnit>[];
        compressedBytes = 0;
      }
      batch.add(accessUnit);
      compressedBytes += unitBytes;
    }

    if (batch.isNotEmpty) await pushAll(batch);
  }

  Future<void> _sendBatch(List<AacAccessUnit> batch) {
    if (_terminal || source.state != GrowingPcmAudioState.open) {
      return Future<void>.error(StateError('Streaming AAC decoder is closed'));
    }
    final commands = _commands;
    if (commands == null) {
      return Future<void>.error(StateError('AAC worker is not ready'));
    }
    final id = _nextRequestId++;
    final complete = Completer<void>();
    _pending[id] = complete;
    final units = batch
        .map(
          (unit) => _CompressedAacUnit(
            TransferableTypedData.fromList(<TypedData>[unit.payload]),
            unit.config.bytes,
            unit.pts90k,
            unit.sampleCount,
          ),
        )
        .toList(growable: false);
    commands.send(_AacDecodeBatch(id, units));
    return complete.future;
  }

  /// Commits final EOF after all queued pushes and shuts down the worker.
  ///
  /// Repeated calls are idempotent. A prior failure remains authoritative.
  Future<void> seal() => _sealFuture ??= _sealOnce();

  Future<void> _sealOnce() async {
    if (_terminal) return;
    try {
      await _operationTail;
      if (_terminal) return;
      source.seal();
      _terminal = true;
      await _requestWorkerShutdown();
    } catch (error, stackTrace) {
      _failSession(error, stackTrace);
      rethrow;
    }
  }

  /// Terminates decoding with [error] and unblocks all source tail reads.
  Future<void> fail(Object error, [StackTrace? stackTrace]) async {
    if (!_terminal) _failSession(error, stackTrace ?? StackTrace.current);
    await _closePortsAndWorker();
  }

  /// Stops the worker without deleting source storage by default.
  ///
  /// An open source becomes failed so playback and prebuffer waiters unblock.
  /// Use [disposeSource] only when the source has not been handed to a playback
  /// controller. Both decoder and source disposal are independently idempotent.
  Future<void> dispose({bool disposeSource = false}) async {
    await (_decoderDisposeFuture ??= _disposeDecoder());
    if (disposeSource) await source.dispose();
  }

  Future<void> _disposeDecoder() async {
    if (!_terminal) {
      _failSession(
        StateError('Streaming AAC decoder was disposed before sealing'),
        StackTrace.current,
      );
    }
    await _closePortsAndWorker();
  }

  void _handleWorkerMessage(Object? message) {
    if (message case _AacWorkerReady(:final commands)) {
      if (_commands != null) return;
      _commands = commands;
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    if (message case _AacWorkerStartupFailure(:final message, :final stack)) {
      final error = StreamingAacDecoderException(message, remoteStack: stack);
      if (!_ready.isCompleted) {
        _ready.completeError(error, StackTrace.fromString(stack));
      }
      _failSession(error, StackTrace.fromString(stack));
      return;
    }
    if (message case _AacDecodedFrame(
      :final requestId,
      :final samples,
      :final sampleRate,
      :final channels,
      :final samplesPerChannel,
      :final pts90k,
    )) {
      if (_terminal || !_pending.containsKey(requestId)) return;
      try {
        if (sampleRate != source.sampleRate || channels != source.channels) {
          throw StateError(
            'AAC worker changed PCM format from ${source.sampleRate}Hz/'
            '${source.channels}ch to ${sampleRate}Hz/${channels}ch',
          );
        }
        final bytes = samples.materialize().asUint8List();
        if (bytes.lengthInBytes != samplesPerChannel * channels * 4) {
          throw StateError('AAC worker returned invalid PCM geometry');
        }
        final floats = Float32List.view(
          bytes.buffer,
          bytes.offsetInBytes,
          bytes.lengthInBytes ~/ 4,
        );
        final startFrame = _startFrameForPts(pts90k);
        source.appendFloatFrameAtFrame(
          floats,
          startFrame: startFrame,
          validFrames: samplesPerChannel,
        );
        _decodedAccessUnitCount++;
      } catch (error, stackTrace) {
        _failSession(error, stackTrace);
      }
      return;
    }
    if (message case _AacBatchDone(:final requestId)) {
      _pending.remove(requestId)?.complete();
      return;
    }
    if (message case _AacBatchFailure(
      :final requestId,
      :final message,
      :final stack,
    )) {
      final error = StreamingAacDecoderException(message, remoteStack: stack);
      _pending
          .remove(requestId)
          ?.completeError(error, StackTrace.fromString(stack));
      _failSession(error, StackTrace.fromString(stack));
      return;
    }
    if (message is _AacWorkerStopped) {
      _expectingExit = true;
      return;
    }
    if (message == null) {
      if (!_workerExited.isCompleted) _workerExited.complete();
      if (!_expectingExit && !_terminal) {
        _failSession(
          const StreamingAacDecoderException('AAC worker exited unexpectedly'),
          StackTrace.current,
        );
      }
      return;
    }
    if (message is List<Object?> && message.length == 2) {
      final error = StreamingAacDecoderException(
        '${message[0]}',
        remoteStack: '${message[1]}',
      );
      if (!_ready.isCompleted) _ready.completeError(error);
      _failSession(error, StackTrace.fromString('${message[1]}'));
    }
  }

  int _startFrameForPts(int? pts90k) {
    if (pts90k == null) return source.frameCount;
    _epochOffset ??= _nearestMpegEpochOffset(pts90k, originPts90k);
    return _scaleTimestamp(
      pts90k + _epochOffset! - originPts90k,
      90000,
      source.sampleRate,
    );
  }

  void _failSession(Object error, StackTrace stackTrace) {
    if (_terminal) return;
    _terminal = true;
    if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
    source.fail(error, stackTrace);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error, stackTrace);
    }
    _pending.clear();
    _expectingExit = true;
    _isolate?.kill(priority: Isolate.immediate);
    unawaited(_closePortsAndWorker());
  }

  Future<void> _requestWorkerShutdown() async {
    final commands = _commands;
    if (commands == null || _workerExited.isCompleted) {
      await _closePortsAndWorker();
      return;
    }
    _expectingExit = true;
    commands.send(const _AacShutdown());
    await _workerExited.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _isolate?.kill(priority: Isolate.immediate);
      },
    );
    await _closePortsAndWorker();
  }

  Future<void> _closePortsAndWorker() =>
      _closePortsFuture ??= _closePortsAndWorkerOnce();

  Future<void> _closePortsAndWorkerOnce() async {
    _expectingExit = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    await _responseSubscription.cancel();
    _responses.close();
  }
}

final class StreamingAacDecoderException implements Exception {
  const StreamingAacDecoderException(this.message, {this.remoteStack});

  final String message;
  final String? remoteStack;

  @override
  String toString() => 'StreamingAacDecoderException: $message';
}

void _aacWorkerMain(_AacWorkerStart start) {
  final commands = ReceivePort();
  late final AacLcDecoder decoder;
  try {
    decoder = AacLcDecoder(AudioSpecificConfig.parse(start.configBytes));
  } catch (error, stackTrace) {
    start.responses.send(_AacWorkerStartupFailure('$error', '$stackTrace'));
    commands.close();
    return;
  }
  start.responses.send(_AacWorkerReady(commands.sendPort));
  commands.listen((message) {
    if (message case _AacDecodeBatch(:final requestId, :final units)) {
      try {
        for (final unit in units) {
          final payload = unit.payload.materialize().asUint8List();
          final decoded = decoder.decode(
            AacAccessUnit(
              payload: payload,
              config: AudioSpecificConfig.parse(unit.configBytes),
              pts90k: unit.pts90k,
              sampleCount: unit.sampleCount,
            ),
          );
          final sampleBytes = Uint8List.view(
            decoded.samples.buffer,
            decoded.samples.offsetInBytes,
            decoded.samples.lengthInBytes,
          );
          start.responses.send(
            _AacDecodedFrame(
              requestId,
              TransferableTypedData.fromList(<TypedData>[sampleBytes]),
              decoded.sampleRate,
              decoded.channels,
              decoded.samplesPerChannel,
              decoded.pts90k,
            ),
          );
        }
        start.responses.send(_AacBatchDone(requestId));
      } catch (error, stackTrace) {
        start.responses.send(
          _AacBatchFailure(requestId, '$error', '$stackTrace'),
        );
      }
      return;
    }
    if (message is _AacShutdown) {
      start.responses.send(const _AacWorkerStopped());
      commands.close();
    }
  });
}

const int _mpegPtsModulus = 1 << 33;

int _nearestMpegEpochOffset(int firstPts90k, int originPts90k) {
  final delta = originPts90k - firstPts90k;
  final half = _mpegPtsModulus ~/ 2;
  final epochs = delta >= 0
      ? (delta + half) ~/ _mpegPtsModulus
      : -((-delta + half) ~/ _mpegPtsModulus);
  return epochs * _mpegPtsModulus;
}

int _scaleTimestamp(int value, int sourceTimescale, int targetTimescale) {
  if (sourceTimescale <= 0 || targetTimescale <= 0) {
    throw ArgumentError('Timestamp scales must be positive');
  }
  final product = value * targetTimescale;
  if (product >= 0) {
    return (product + sourceTimescale ~/ 2) ~/ sourceTimescale;
  }
  return -((-product + sourceTimescale ~/ 2) ~/ sourceTimescale);
}

final class _AacWorkerStart {
  const _AacWorkerStart(this.responses, this.configBytes);

  final SendPort responses;
  final Uint8List configBytes;
}

final class _AacWorkerReady {
  const _AacWorkerReady(this.commands);

  final SendPort commands;
}

final class _AacWorkerStartupFailure {
  const _AacWorkerStartupFailure(this.message, this.stack);

  final String message;
  final String stack;
}

final class _CompressedAacUnit {
  const _CompressedAacUnit(
    this.payload,
    this.configBytes,
    this.pts90k,
    this.sampleCount,
  );

  final TransferableTypedData payload;
  final Uint8List configBytes;
  final int? pts90k;
  final int sampleCount;
}

final class _AacDecodeBatch {
  const _AacDecodeBatch(this.requestId, this.units);

  final int requestId;
  final List<_CompressedAacUnit> units;
}

final class _AacDecodedFrame {
  const _AacDecodedFrame(
    this.requestId,
    this.samples,
    this.sampleRate,
    this.channels,
    this.samplesPerChannel,
    this.pts90k,
  );

  final int requestId;
  final TransferableTypedData samples;
  final int sampleRate;
  final int channels;
  final int samplesPerChannel;
  final int? pts90k;
}

final class _AacBatchDone {
  const _AacBatchDone(this.requestId);

  final int requestId;
}

final class _AacBatchFailure {
  const _AacBatchFailure(this.requestId, this.message, this.stack);

  final int requestId;
  final String message;
  final String stack;
}

final class _AacShutdown {
  const _AacShutdown();
}

final class _AacWorkerStopped {
  const _AacWorkerStopped();
}
