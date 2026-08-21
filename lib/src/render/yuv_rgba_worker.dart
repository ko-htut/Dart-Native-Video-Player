import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../yuv.dart';

typedef YuvRgbaFrameReady = void Function(Uint8List rgba);
typedef YuvRgbaFrameError = void Function(Object error, StackTrace stackTrace);

/// Converts presented YUV pictures away from the UI isolate.
///
/// The worker deliberately owns a two-slot latest-wins mailbox: one conversion
/// may be in flight and at most one newer frame may wait behind it. Replacing
/// the waiting frame, or finishing an in-flight frame after a newer one
/// arrived, counts as a coalesced frame. This bounds both work and retained
/// pixel memory during decoder catch-up bursts.
final class YuvRgbaRenderWorker {
  ReceivePort? _responses;
  ReceivePort? _errors;
  ReceivePort? _exits;
  StreamSubscription<Object?>? _responseSubscription;
  StreamSubscription<Object?>? _errorSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  Isolate? _isolate;
  SendPort? _commandPort;
  Completer<SendPort>? _ready;
  final Map<int, Completer<TransferableTypedData>> _requests =
      <int, Completer<TransferableTypedData>>{};

  _QueuedYuvFrame? _pending;
  _QueuedYuvFrame? _inFlight;
  Completer<void>? _idle;
  int _generation = 0;
  int _nextRequestId = 1;
  int _coalescedFrameCount = 0;
  bool _disposed = false;
  Object? _terminalError;
  StackTrace? _terminalStackTrace;

  int get coalescedFrameCount => _coalescedFrameCount;
  bool get isIdle => _pending == null && _inFlight == null;

  /// Replaces any waiting frame and starts background conversion if needed.
  void submit(
    Yuv420Frame frame, {
    int? outputWidth,
    int? outputHeight,
    required YuvRgbaFrameReady onFrame,
    YuvRgbaFrameError? onError,
  }) {
    if (_disposed) return;
    _validateFrame(frame);
    if ((outputWidth == null) != (outputHeight == null)) {
      throw ArgumentError(
        'outputWidth and outputHeight must either both be set or both be null',
      );
    }
    final targetWidth = outputWidth ?? frame.width;
    final targetHeight = outputHeight ?? frame.height;
    if (targetWidth <= 0 || targetHeight <= 0) {
      throw ArgumentError('RGBA output dimensions must be positive');
    }
    if (_pending != null) _coalescedFrameCount++;
    _pending = _QueuedYuvFrame(
      generation: _generation,
      frame: frame,
      outputWidth: targetWidth,
      outputHeight: targetHeight,
      onFrame: onFrame,
      onError: onError,
    );
    _idle ??= Completer<void>();
    _startNextIfNeeded();
  }

  /// Invalidates queued/returning pixels without killing the reusable isolate.
  void reset({bool resetStatistics = true}) {
    if (_disposed) return;
    _generation++;
    if (_pending != null) _coalescedFrameCount++;
    _pending = null;
    if (resetStatistics) _coalescedFrameCount = 0;
    _completeIdleIfNeeded();
  }

  Future<void> waitUntilIdle() async {
    while (!isIdle) {
      final idle = _idle;
      if (idle == null) return;
      await idle.future;
    }
  }

  void _startNextIfNeeded() {
    if (_disposed || _inFlight != null) return;
    final request = _pending;
    if (request == null) {
      _completeIdleIfNeeded();
      return;
    }
    _pending = null;
    _inFlight = request;
    unawaited(_convert(request));
  }

  Future<void> _convert(_QueuedYuvFrame request) async {
    try {
      final rgbaPayload = await _requestConversion(request);
      if (_disposed || request.generation != _generation) return;

      // A newer frame superseded this one while conversion was running. Avoid
      // even materializing its large RGBA payload on the UI isolate.
      if (_pending != null) {
        _coalescedFrameCount++;
        return;
      }
      request.onFrame(rgbaPayload.materialize().asUint8List());
    } catch (error, stackTrace) {
      if (!_disposed && request.generation == _generation) {
        request.onError?.call(error, stackTrace);
      }
    } finally {
      if (identical(_inFlight, request)) _inFlight = null;
      _startNextIfNeeded();
    }
  }

  Future<TransferableTypedData> _requestConversion(
    _QueuedYuvFrame request,
  ) async {
    final frame = request.frame;
    final port = await _ensureStarted();
    if (_disposed) throw StateError('YUV render worker is disposed');
    final requestId = _nextRequestId++;
    final completion = Completer<TransferableTypedData>();
    _requests[requestId] = completion;
    port.send(<Object?>[
      'convert',
      requestId,
      frame.width,
      frame.height,
      request.outputWidth,
      request.outputHeight,
      frame.y.length,
      frame.u.length,
      TransferableTypedData.fromList(<TypedData>[frame.y, frame.u, frame.v]),
    ]);
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
    final commandPort = _commandPort;
    if (commandPort != null) return Future<SendPort>.value(commandPort);
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
        final isolate = await Isolate.spawn<SendPort>(
          _yuvRgbaWorkerMain,
          responses.sendPort,
          debugName: 'yuv-rgba-render-worker',
          onError: errors.sendPort,
          onExit: exits.sendPort,
        );
        if (_disposed) {
          isolate.kill(priority: Isolate.immediate);
          return;
        }
        _isolate = isolate;
      } catch (error, stackTrace) {
        if (_disposed) return;
        _failTerminal(error, stackTrace);
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
    if (message is! List<Object?> || message.length < 3) {
      _failTerminal(
        StateError('Malformed YUV render-worker response'),
        StackTrace.current,
      );
      return;
    }
    final requestId = message[1];
    if (requestId is! int) return;
    final completion = _requests.remove(requestId);
    if (completion == null) return;
    if (message.first == 'error') {
      final stackTrace = StackTrace.fromString(
        message.length > 3 ? message[3].toString() : '',
      );
      completion.completeError(StateError(message[2].toString()), stackTrace);
      return;
    }
    final payload = message[2];
    if (message.first != 'rgba' || payload is! TransferableTypedData) {
      completion.completeError(
        StateError('Malformed YUV render-worker pixel response'),
        StackTrace.current,
      );
      return;
    }
    completion.complete(payload);
  }

  void _handleIsolateError(Object? message) {
    _failTerminal(
      StateError('YUV render isolate failed: $message'),
      StackTrace.current,
    );
  }

  void _handleIsolateExit(Object? _) {
    if (_disposed) return;
    _commandPort = null;
    _isolate = null;
    _failTerminal(
      StateError('YUV render isolate exited unexpectedly'),
      StackTrace.current,
    );
  }

  void _failTerminal(Object error, StackTrace stackTrace) {
    _terminalError = error;
    _terminalStackTrace = stackTrace;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, stackTrace);
    }
    final completions = _requests.values.toList(growable: false);
    _requests.clear();
    for (final completion in completions) {
      if (!completion.isCompleted) completion.completeError(error, stackTrace);
    }
  }

  void _completeIdleIfNeeded() {
    if (!isIdle) return;
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _pending = null;
    final error = StateError('YUV render worker is disposed');
    final stackTrace = StackTrace.current;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, stackTrace);
    }
    final completions = _requests.values.toList(growable: false);
    _requests.clear();
    for (final completion in completions) {
      if (!completion.isCompleted) completion.completeError(error, stackTrace);
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
    _inFlight = null;
    _completeIdleIfNeeded();
  }
}

final class _QueuedYuvFrame {
  const _QueuedYuvFrame({
    required this.generation,
    required this.frame,
    required this.outputWidth,
    required this.outputHeight,
    required this.onFrame,
    required this.onError,
  });

  final int generation;
  final Yuv420Frame frame;
  final int outputWidth;
  final int outputHeight;
  final YuvRgbaFrameReady onFrame;
  final YuvRgbaFrameError? onError;
}

void _validateFrame(Yuv420Frame frame) {
  if (frame.width <= 0 || frame.height <= 0) {
    throw ArgumentError('YUV frame dimensions must be positive');
  }
  if (frame.width.isOdd || frame.height.isOdd) {
    throw ArgumentError('YUV420 frame dimensions must be even');
  }
  final yLength = frame.width * frame.height;
  final chromaLength = (frame.width ~/ 2) * (frame.height ~/ 2);
  if (frame.y.length != yLength ||
      frame.u.length != chromaLength ||
      frame.v.length != chromaLength) {
    throw ArgumentError('Malformed planar YUV420 frame');
  }
}

@pragma('vm:entry-point')
void _yuvRgbaWorkerMain(SendPort replyTo) {
  final commands = ReceivePort();
  replyTo.send(commands.sendPort);
  commands.listen((Object? rawMessage) {
    if (rawMessage is! List<Object?> || rawMessage.length != 9) return;
    final requestId = rawMessage[1];
    if (requestId is! int) return;
    try {
      if (rawMessage[0] != 'convert') {
        throw StateError('Unknown YUV render command ${rawMessage[0]}');
      }
      final width = rawMessage[2]! as int;
      final height = rawMessage[3]! as int;
      final outputWidth = rawMessage[4]! as int;
      final outputHeight = rawMessage[5]! as int;
      final yLength = rawMessage[6]! as int;
      final uLength = rawMessage[7]! as int;
      final pixels = (rawMessage[8]! as TransferableTypedData)
          .materialize()
          .asUint8List();
      if (pixels.length != yLength + uLength * 2) {
        throw const FormatException('Malformed transferable YUV payload');
      }
      final frame = Yuv420Frame(
        width: width,
        height: height,
        y: Uint8List.sublistView(pixels, 0, yLength),
        u: Uint8List.sublistView(pixels, yLength, yLength + uLength),
        v: Uint8List.sublistView(pixels, yLength + uLength),
      );
      _validateFrame(frame);
      final rgba = yuv420ToRgbaScaled(frame, outputWidth, outputHeight);
      replyTo.send(<Object?>[
        'rgba',
        requestId,
        TransferableTypedData.fromList(<TypedData>[rgba]),
      ]);
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
