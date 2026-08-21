import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../yuv.dart';
import 'h264_baseline_idr_decoder.dart';
import 'slice_header.dart';

/// A decoded picture together with the statistics for that exact picture.
///
/// Keeping the statistics beside the frame avoids a reordered presentation
/// accidentally displaying the stats of a future reference picture.
final class H264WorkerDecodeResult {
  const H264WorkerDecodeResult({required this.frame, required this.stats});

  final Yuv420Frame frame;
  final H264DecodeStats stats;
}

/// Error returned by the persistent decoder isolate.
final class H264DecodeWorkerException implements Exception {
  const H264DecodeWorkerException(this.message, this.remoteStackTrace);

  final String message;
  final String remoteStackTrace;

  @override
  String toString() => 'H264DecodeWorkerException: $message';
}

/// Owns one stateful [H264BaselineDecoder] on a persistent background isolate.
///
/// Decode and reset commands are serialized. This is important during seek or
/// queue replacement: an already-running picture is allowed to finish, then
/// reset is applied, and only then can a new generation start decoding.
final class H264DecodeWorker {
  H264DecodeWorker({
    this.enableDeblocking = true,
    this.maxCodedDimension = H264BaselineDecoder.defaultMaxCodedDimension,
    this.maxLumaSamples = H264BaselineDecoder.defaultMaxLumaSamples,
  });

  final bool enableDeblocking;
  final int maxCodedDimension;
  final int maxLumaSamples;

  ReceivePort? _responses;
  ReceivePort? _errors;
  ReceivePort? _exits;
  StreamSubscription<Object?>? _responseSubscription;
  StreamSubscription<Object?>? _errorSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  Isolate? _isolate;
  SendPort? _commandPort;
  Completer<SendPort>? _ready;
  Future<void> _commandTail = Future<void>.value();
  final Map<int, Completer<List<Object?>>> _pending =
      <int, Completer<List<Object?>>>{};
  int _nextRequestId = 1;
  bool _disposed = false;
  Object? _terminalError;
  StackTrace? _terminalStackTrace;

  H264DecodeStats? lastStats;

  /// Queues a decoder reset without blocking synchronous player lifecycle code.
  /// Later decode calls remain ordered behind this reset.
  void reset({bool clearParameterSets = true}) {
    final reset = resetAndWait(clearParameterSets: clearParameterSets);
    unawaited(reset.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  Future<void> resetAndWait({bool clearParameterSets = true}) =>
      _serialize<void>(() async {
        await _request(<Object?>['reset', clearParameterSets]);
        lastStats = null;
      });

  Future<H264WorkerDecodeResult> decodeAccessUnitOrThrow(
    List<Uint8List> nals,
  ) => _serialize<H264WorkerDecodeResult>(() async {
    final lengths = <int>[for (final nal in nals) nal.length];
    final compressed = TransferableTypedData.fromList(nals);
    final reply = await _request(<Object?>['decode', lengths, compressed]);
    if (reply.length != 9 || reply[0] != 'decoded') {
      throw StateError('Malformed H.264 worker decode response');
    }

    final width = reply[2]! as int;
    final height = reply[3]! as int;
    final yLength = reply[4]! as int;
    final uLength = reply[5]! as int;
    final pixels = (reply[6]! as TransferableTypedData)
        .materialize()
        .asUint8List();
    final expectedLength = yLength + uLength * 2;
    if (pixels.length != expectedLength) {
      throw StateError(
        'Malformed H.264 worker pixel payload: expected $expectedLength, '
        'got ${pixels.length}',
      );
    }
    final stats = _decodeStats(reply[7]! as List<Object?>);
    final frame = Yuv420Frame(
      width: width,
      height: height,
      y: Uint8List.sublistView(pixels, 0, yLength),
      u: Uint8List.sublistView(pixels, yLength, yLength + uLength),
      v: Uint8List.sublistView(pixels, yLength + uLength),
    );
    lastStats = stats;
    return H264WorkerDecodeResult(frame: frame, stats: stats);
  });

  Future<T> _serialize<T>(Future<T> Function() operation) {
    if (_disposed) {
      return Future<T>.error(StateError('H.264 decode worker is disposed'));
    }
    final previous = _commandTail;
    final result = () async {
      try {
        await previous;
      } catch (_) {
        // One failed picture must not poison reset/retry commands behind it.
      }
      if (_disposed) {
        throw StateError('H.264 decode worker is disposed');
      }
      return operation();
    }();
    _commandTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<List<Object?>> _request(List<Object?> command) async {
    final port = await _ensureStarted();
    if (_disposed) throw StateError('H.264 decode worker is disposed');
    final requestId = _nextRequestId++;
    final completion = Completer<List<Object?>>();
    _pending[requestId] = completion;
    port.send(<Object?>[command.first, requestId, ...command.skip(1)]);
    return completion.future;
  }

  Future<SendPort> _ensureStarted() {
    final terminalError = _terminalError;
    if (terminalError != null) {
      return Future<SendPort>.error(
        terminalError,
        _terminalStackTrace ?? StackTrace.current,
      );
    }
    final port = _commandPort;
    if (port != null) return Future<SendPort>.value(port);
    final starting = _ready;
    if (starting != null) return starting.future;

    final ready = Completer<SendPort>();
    _ready = ready;
    final responses = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    _responses = responses;
    _errors = errors;
    _exits = exits;
    _responseSubscription = responses.listen(_handleResponse);
    _errorSubscription = errors.listen(_handleIsolateError);
    _exitSubscription = exits.listen(_handleIsolateExit);

    unawaited(() async {
      try {
        final isolate = await Isolate.spawn<List<Object?>>(
          _h264DecodeWorkerMain,
          <Object?>[
            responses.sendPort,
            enableDeblocking,
            maxCodedDimension,
            maxLumaSamples,
          ],
          debugName: 'h264-decode-worker',
          onError: errors.sendPort,
          onExit: exits.sendPort,
        );
        // dispose() can run while Isolate.spawn is still awaiting. Do not
        // publish (or leak) a worker that arrived after its owner went away.
        if (_disposed) {
          isolate.kill(priority: Isolate.immediate);
          return;
        }
        _isolate = isolate;
      } catch (error, stackTrace) {
        if (_disposed) return;
        _terminalError = error;
        _terminalStackTrace = stackTrace;
        if (!ready.isCompleted) ready.completeError(error, stackTrace);
        _failPending(error, stackTrace);
      }
    }());
    return ready.future;
  }

  void _handleResponse(Object? message) {
    if (message is SendPort) {
      if (_disposed) return;
      _commandPort = message;
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete(message);
      return;
    }
    if (message is! List<Object?> || message.length < 2) {
      _failPending(
        StateError('Malformed H.264 worker response'),
        StackTrace.current,
      );
      return;
    }
    final requestId = message[1];
    if (requestId is! int) return;
    final completion = _pending.remove(requestId);
    if (completion == null) return;
    if (message.first == 'error') {
      completion.completeError(
        H264DecodeWorkerException(
          message.length > 2 ? message[2].toString() : 'unknown worker error',
          message.length > 3 ? message[3].toString() : '',
        ),
        StackTrace.fromString(message.length > 3 ? message[3].toString() : ''),
      );
      return;
    }
    completion.complete(message);
  }

  void _handleIsolateError(Object? message) {
    final error = StateError('H.264 decoder isolate failed: $message');
    final stackTrace = StackTrace.current;
    _terminalError = error;
    _terminalStackTrace = stackTrace;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, stackTrace);
    }
    _failPending(error, stackTrace);
  }

  void _handleIsolateExit(Object? _) {
    if (_disposed) return;
    final error = StateError('H.264 decoder isolate exited unexpectedly');
    final stackTrace = StackTrace.current;
    _terminalError = error;
    _terminalStackTrace = stackTrace;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, stackTrace);
    }
    _failPending(error, stackTrace);
    _commandPort = null;
    _isolate = null;
  }

  void _failPending(Object error, StackTrace stackTrace) {
    final completions = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completion in completions) {
      if (!completion.isCompleted) completion.completeError(error, stackTrace);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final error = StateError('H.264 decode worker is disposed');
    _failPending(error, StackTrace.current);
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, StackTrace.current);
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
    unawaited(_responseSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_exitSubscription?.cancel());
    _responses?.close();
    _errors?.close();
    _exits?.close();
  }
}

H264DecodeStats _decodeStats(List<Object?> values) {
  if (values.length != 9) {
    throw StateError('Malformed H.264 worker stats payload');
  }
  final sliceTypeIndex = values[3]! as int;
  if (sliceTypeIndex < 0 || sliceTypeIndex >= H264SliceType.values.length) {
    throw StateError('Malformed H.264 worker slice type $sliceTypeIndex');
  }
  return H264DecodeStats(
    frameNumber: values[0]! as int,
    pictureOrderCount: values[1] as int?,
    isReference: values[2]! as bool,
    sliceType: H264SliceType.values[sliceTypeIndex],
    macroblockCount: values[4]! as int,
    intraMacroblocks: values[5]! as int,
    interMacroblocks: values[6]! as int,
    skippedMacroblocks: values[7]! as int,
    sliceCount: values[8]! as int,
  );
}

List<Object?> _encodeStats(H264DecodeStats stats) => <Object?>[
  stats.frameNumber,
  stats.pictureOrderCount,
  stats.isReference,
  stats.sliceType.index,
  stats.macroblockCount,
  stats.intraMacroblocks,
  stats.interMacroblocks,
  stats.skippedMacroblocks,
  stats.sliceCount,
];

@pragma('vm:entry-point')
void _h264DecodeWorkerMain(List<Object?> bootstrap) {
  final replyTo = bootstrap[0]! as SendPort;
  final decoder = H264BaselineDecoder(
    enableDeblocking: bootstrap[1]! as bool,
    maxCodedDimension: bootstrap[2]! as int,
    maxLumaSamples: bootstrap[3]! as int,
  );
  final commands = ReceivePort();
  replyTo.send(commands.sendPort);
  commands.listen((Object? rawMessage) {
    if (rawMessage is! List<Object?> || rawMessage.length < 2) return;
    final command = rawMessage[0];
    final requestId = rawMessage[1];
    if (requestId is! int) return;
    try {
      switch (command) {
        case 'reset':
          decoder.reset(clearParameterSets: rawMessage[2]! as bool);
          replyTo.send(<Object?>['reset', requestId]);
          return;
        case 'decode':
          final lengths = (rawMessage[2]! as List<Object?>).cast<int>();
          final compressed = (rawMessage[3]! as TransferableTypedData)
              .materialize()
              .asUint8List();
          final nals = <Uint8List>[];
          var offset = 0;
          for (final length in lengths) {
            final end = offset + length;
            if (length < 0 || end > compressed.length) {
              throw const FormatException('Malformed worker NAL payload');
            }
            nals.add(Uint8List.sublistView(compressed, offset, end));
            offset = end;
          }
          if (offset != compressed.length) {
            throw const FormatException('Trailing worker NAL payload bytes');
          }
          final frame = decoder.decodeAccessUnitOrThrow(nals);
          final stats = decoder.lastStats;
          if (stats == null) {
            throw StateError('Decoder produced a frame without statistics');
          }
          replyTo.send(<Object?>[
            'decoded',
            requestId,
            frame.width,
            frame.height,
            frame.y.length,
            frame.u.length,
            TransferableTypedData.fromList(<TypedData>[
              frame.y,
              frame.u,
              frame.v,
            ]),
            _encodeStats(stats),
            null,
          ]);
          return;
        default:
          throw StateError('Unknown H.264 worker command $command');
      }
    } catch (error, stackTrace) {
      replyTo.send(<Object?>[
        'error',
        requestId,
        error.toString(),
        stackTrace.toString(),
      ]);
    }
  });
}
