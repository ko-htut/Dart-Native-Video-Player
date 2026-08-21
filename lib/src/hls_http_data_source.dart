import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Default time allowed for a complete HLS HTTP response.
const Duration defaultHlsHttpRequestTimeout = Duration(seconds: 20);

/// Default upper bound for a playlist or media-segment response (32 MiB).
///
/// Individual playlist requests may use a smaller per-call limit. This default
/// is deliberately large enough for ordinary MPEG-TS segments while still
/// placing a firm bound on untrusted network input.
const int defaultHlsHttpMaxResponseBytes = 32 * 1024 * 1024;

/// User-Agent sent with every request unless a custom value is configured.
const String defaultHlsHttpUserAgent = 'ndvy-player/0.2 (Dart HLS)';

/// Base type for failures produced by [HlsHttpDataSource].
sealed class HlsHttpException implements Exception {
  const HlsHttpException({required this.uri});

  final Uri uri;

  String get message;

  @override
  String toString() => '$runtimeType: $message; uri=$uri';
}

/// The server returned a response outside the successful 2xx range.
final class HlsHttpStatusException extends HlsHttpException {
  const HlsHttpStatusException({
    required super.uri,
    required this.statusCode,
    this.reasonPhrase,
  });

  final int statusCode;
  final String? reasonPhrase;

  @override
  String get message {
    final reason = reasonPhrase;
    return reason == null || reason.isEmpty
        ? 'HTTP request failed with status $statusCode'
        : 'HTTP request failed with status $statusCode $reason';
  }
}

/// A declared or observed response size exceeded the configured safety cap.
final class HlsHttpResponseTooLargeException extends HlsHttpException {
  const HlsHttpResponseTooLargeException({
    required super.uri,
    required this.maxBytes,
    this.declaredContentLength,
    this.receivedBytes,
  });

  final int maxBytes;

  /// Value advertised by Content-Length, when rejection happened at headers.
  final int? declaredContentLength;

  /// Bytes observed through the chunk that crossed the limit, when streaming.
  final int? receivedBytes;

  @override
  String get message {
    final declared = declaredContentLength;
    if (declared != null) {
      return 'response declares $declared bytes; limit is $maxBytes bytes';
    }
    return 'response exceeded $maxBytes bytes after receiving '
        '${receivedBytes ?? 'an unknown number of'} bytes';
  }
}

/// The request did not finish within its configured end-to-end timeout.
final class HlsHttpTimeoutException extends HlsHttpException {
  const HlsHttpTimeoutException({required super.uri, required this.timeout});

  final Duration timeout;

  @override
  String get message => 'request timed out after $timeout';
}

/// An active request was cancelled through [HlsHttpDataSource.cancelAll].
final class HlsHttpCancelledException extends HlsHttpException {
  const HlsHttpCancelledException({required super.uri});

  @override
  String get message => 'request was cancelled';
}

/// A request was started after disposal, or was active during disposal.
final class HlsHttpDisposedException extends HlsHttpException {
  const HlsHttpDisposedException({required super.uri});

  @override
  String get message => 'HTTP data source is disposed';
}

/// A client or response-stream failure not classified above.
final class HlsHttpTransportException extends HlsHttpException {
  const HlsHttpTransportException({required super.uri, required this.cause});

  final Object cause;

  @override
  String get message => 'HTTP transport failed: $cause';
}

/// Reusable, bounded HTTP byte source for HLS playlists and media segments.
///
/// The injected [http.Client] is reused for every concurrent request so its
/// connection pool can be reused as well. The caller retains ownership of that
/// client and must close it after this source is disposed.
///
/// Each call performs exactly one HTTP request. Retry and backoff policy belong
/// to the playlist/segment loader rather than this transport primitive.
final class HlsHttpDataSource {
  HlsHttpDataSource({
    required http.Client client,
    this.requestTimeout = defaultHlsHttpRequestTimeout,
    this.maxResponseBytes = defaultHlsHttpMaxResponseBytes,
    this.userAgent = defaultHlsHttpUserAgent,
  }) : _client = client {
    _validateTimeout(requestTimeout, 'requestTimeout');
    _validateMaxBytes(maxResponseBytes, 'maxResponseBytes');
    if (userAgent.trim().isEmpty) {
      throw ArgumentError.value(userAgent, 'userAgent', 'must not be empty');
    }
  }

  final http.Client _client;

  /// End-to-end timeout used when a call does not provide an override.
  final Duration requestTimeout;

  /// Byte cap used when a call does not provide an override.
  final int maxResponseBytes;

  /// User-Agent sent on every request.
  final String userAgent;

  final Map<int, _ActiveRequest> _active = <int, _ActiveRequest>{};
  var _nextRequestId = 0;
  var _disposed = false;

  bool get isDisposed => _disposed;

  /// Number of requests that have not yet completed or been cancelled.
  int get activeRequestCount => _active.length;

  /// Fetches one response into a bounded [Uint8List].
  ///
  /// [timeout] covers connection setup, response headers, and the complete
  /// response stream. [maxResponseBytes] is checked against Content-Length as
  /// soon as headers arrive and against every streamed chunk thereafter.
  Future<Uint8List> fetch(Uri uri, {Duration? timeout, int? maxResponseBytes}) {
    final effectiveTimeout = timeout ?? requestTimeout;
    final effectiveMaxBytes = maxResponseBytes ?? this.maxResponseBytes;
    _validateTimeout(effectiveTimeout, 'timeout');
    _validateMaxBytes(effectiveMaxBytes, 'maxResponseBytes');

    if (_disposed) {
      return Future<Uint8List>.error(
        HlsHttpDisposedException(uri: uri),
        StackTrace.current,
      );
    }

    final id = _nextRequestId++;
    final state = _ActiveRequest(id: id, uri: uri);
    final abortableRequest = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: state.abortTrigger.future,
    )..headers['User-Agent'] = userAgent;
    _active[id] = state;

    state.timeoutTimer = Timer(effectiveTimeout, () {
      if (state.result.isCompleted) return;
      _retire(state);
      state.abortTransport();
      state.result.completeError(
        HlsHttpTimeoutException(uri: uri, timeout: effectiveTimeout),
        StackTrace.current,
      );
    });

    final operation = _sendAndRead(
      abortableRequest,
      state,
      maxBytes: effectiveMaxBytes,
    );
    unawaited(
      operation.then<void>(
        (bytes) {
          if (state.result.isCompleted) return;
          _retire(state);
          state.result.complete(bytes);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (state.result.isCompleted) return;
          _retire(state);
          final typedError = error is HlsHttpException
              ? error
              : HlsHttpTransportException(uri: uri, cause: error);
          state.result.completeError(typedError, stackTrace);
        },
      ),
    );

    return state.result.future;
  }

  /// Aborts all current requests while keeping the data source reusable.
  void cancelAll() {
    final requests = _active.values.toList(growable: false);
    for (final state in requests) {
      if (state.result.isCompleted) continue;
      _retire(state);
      state.abortTransport();
      state.result.completeError(
        HlsHttpCancelledException(uri: state.uri),
        StackTrace.current,
      );
    }
  }

  /// Permanently aborts every request and rejects all future calls.
  ///
  /// This does not close the injected client because its ownership remains
  /// with the caller. Disposal is idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    final requests = _active.values.toList(growable: false);
    for (final state in requests) {
      if (state.result.isCompleted) continue;
      _retire(state);
      state.abortTransport();
      state.result.completeError(
        HlsHttpDisposedException(uri: state.uri),
        StackTrace.current,
      );
    }
  }

  Future<Uint8List> _sendAndRead(
    http.AbortableRequest request,
    _ActiveRequest state, {
    required int maxBytes,
  }) async {
    final response = await _client.send(request);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      state.abortTransport();
      await _cancelResponse(response);
      throw HlsHttpStatusException(
        uri: request.url,
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase,
      );
    }

    final declaredLength = _declaredContentLength(response);
    if (declaredLength != null && declaredLength > maxBytes) {
      state.abortTransport();
      await _cancelResponse(response);
      throw HlsHttpResponseTooLargeException(
        uri: request.url,
        maxBytes: maxBytes,
        declaredContentLength: declaredLength,
      );
    }

    final bytes = BytesBuilder(copy: false);
    var receivedBytes = 0;
    await for (final chunk in response.stream) {
      if (chunk.length > maxBytes - receivedBytes) {
        final rejectedSize = receivedBytes + chunk.length;
        state.abortTransport();
        throw HlsHttpResponseTooLargeException(
          uri: request.url,
          maxBytes: maxBytes,
          receivedBytes: rejectedSize,
        );
      }
      bytes.add(chunk);
      receivedBytes += chunk.length;
    }
    return bytes.takeBytes();
  }

  void _retire(_ActiveRequest state) {
    state.timeoutTimer?.cancel();
    _active.remove(state.id);
  }

  static int? _declaredContentLength(http.StreamedResponse response) {
    final direct = response.contentLength;
    if (direct != null) return direct;
    final raw = response.headers['content-length'];
    if (raw == null) return null;
    final parsed = int.tryParse(raw.trim());
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  static Future<void> _cancelResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen(
      (_) {},
      onError: (Object _, StackTrace _) {
        // The status/size exception which requested cancellation is
        // authoritative; an abort error from the response body is secondary.
      },
    );
    try {
      await subscription.cancel();
    } catch (_) {
      // Preserve the status/size exception which caused response cancellation.
    }
  }

  static void _validateTimeout(Duration timeout, String parameterName) {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, parameterName, 'must be > zero');
    }
  }

  static void _validateMaxBytes(int maxBytes, String parameterName) {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, parameterName, 'must be > 0');
    }
  }
}

final class _ActiveRequest {
  _ActiveRequest({required this.id, required this.uri});

  final int id;
  final Uri uri;
  final Completer<void> abortTrigger = Completer<void>();
  final Completer<Uint8List> result = Completer<Uint8List>();
  Timer? timeoutTimer;

  void abortTransport() {
    if (!abortTrigger.isCompleted) abortTrigger.complete();
  }
}
