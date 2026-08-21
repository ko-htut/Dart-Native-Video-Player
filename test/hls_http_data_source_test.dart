import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ndvy_player/src/hls_http_data_source.dart';

void main() {
  final firstUri = Uri.parse('https://media.example.test/master.m3u8');
  final secondUri = Uri.parse('https://media.example.test/segment-1.ts');

  test(
    'reuses the injected client and returns successful streamed bytes',
    () async {
      final responseGates = <Uri, Completer<http.StreamedResponse>>{
        firstUri: Completer<http.StreamedResponse>(),
        secondUri: Completer<http.StreamedResponse>(),
      };
      final client = _FakeClient(
        (request) => responseGates[request.url]!.future,
      );
      final source = HlsHttpDataSource(
        client: client,
        userAgent: 'ndvy-test/1.0',
      );

      final first = source.fetch(firstUri);
      final second = source.fetch(secondUri);
      expect(source.activeRequestCount, 2);
      expect(client.requests, hasLength(2));
      expect(client.requests, everyElement(isA<http.AbortableRequest>()));
      expect(client.requests.first.method, 'GET');
      expect(client.requests.first.headers['User-Agent'], 'ndvy-test/1.0');

      // Complete in reverse order to exercise independent concurrent state.
      responseGates[secondUri]!.complete(
        http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[4],
            <int>[5, 6],
          ]),
          200,
          contentLength: 3,
        ),
      );
      responseGates[firstUri]!.complete(
        http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2],
            <int>[3],
          ]),
          200,
          contentLength: 3,
        ),
      );

      expect(await first, Uint8List.fromList(<int>[1, 2, 3]));
      expect(await second, Uint8List.fromList(<int>[4, 5, 6]));
      expect(source.activeRequestCount, 0);
      expect(client.closeCalls, 0);
    },
  );

  test('rejects non-2xx status without retrying', () async {
    final client = _FakeClient(
      (_) async => http.StreamedResponse(
        const Stream<List<int>>.empty(),
        503,
        reasonPhrase: 'Service Unavailable',
      ),
    );
    final source = HlsHttpDataSource(client: client);

    await expectLater(
      source.fetch(firstUri),
      throwsA(
        isA<HlsHttpStatusException>()
            .having((error) => error.uri, 'uri', firstUri)
            .having((error) => error.statusCode, 'statusCode', 503)
            .having(
              (error) => error.reasonPhrase,
              'reasonPhrase',
              'Service Unavailable',
            ),
      ),
    );
    expect(client.requests, hasLength(1));
  });

  test('rejects an oversized declared Content-Length before reading', () async {
    var listened = false;
    final responseStream = StreamController<List<int>>(
      onListen: () => listened = true,
    );
    final client = _FakeClient(
      (_) async =>
          http.StreamedResponse(responseStream.stream, 200, contentLength: 9),
    );
    final source = HlsHttpDataSource(client: client, maxResponseBytes: 8);

    await expectLater(
      source.fetch(firstUri),
      throwsA(
        isA<HlsHttpResponseTooLargeException>()
            .having((error) => error.maxBytes, 'maxBytes', 8)
            .having(
              (error) => error.declaredContentLength,
              'declaredContentLength',
              9,
            )
            .having((error) => error.receivedBytes, 'receivedBytes', isNull),
      ),
    );
    expect(listened, isTrue);
    expect(client.requests, hasLength(1));
    await responseStream.close();
  });

  test('caps actual streamed bytes when Content-Length is absent', () async {
    final client = _FakeClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2, 3],
          <int>[4, 5, 6],
        ]),
        200,
      ),
    );
    final source = HlsHttpDataSource(client: client, maxResponseBytes: 5);

    await expectLater(
      source.fetch(secondUri),
      throwsA(
        isA<HlsHttpResponseTooLargeException>()
            .having((error) => error.maxBytes, 'maxBytes', 5)
            .having((error) => error.receivedBytes, 'receivedBytes', 6)
            .having(
              (error) => error.declaredContentLength,
              'declaredContentLength',
              isNull,
            ),
      ),
    );
    expect(client.requests, hasLength(1));
  });

  test('timeout completes its per-request AbortableRequest trigger', () async {
    final transportSawAbort = Completer<void>();
    final client = _FakeClient((request) async {
      final abortTrigger = (request as http.AbortableRequest).abortTrigger!;
      await abortTrigger;
      transportSawAbort.complete();
      throw http.RequestAbortedException(request.url);
    });
    const timeout = Duration(milliseconds: 10);
    final source = HlsHttpDataSource(client: client, requestTimeout: timeout);

    await expectLater(
      source.fetch(firstUri),
      throwsA(
        isA<HlsHttpTimeoutException>()
            .having((error) => error.uri, 'uri', firstUri)
            .having((error) => error.timeout, 'timeout', timeout),
      ),
    );
    await transportSawAbort.future;
    expect(source.activeRequestCount, 0);
    expect(client.requests, hasLength(1));
  });

  test(
    'dispose aborts every request and ignores later stale success',
    () async {
      final responseGates = <Uri, Completer<http.StreamedResponse>>{
        firstUri: Completer<http.StreamedResponse>(),
        secondUri: Completer<http.StreamedResponse>(),
      };
      final abortedUris = <Uri>[];
      final client = _FakeClient((request) {
        final abortTrigger = (request as http.AbortableRequest).abortTrigger!;
        unawaited(abortTrigger.then((_) => abortedUris.add(request.url)));
        // Deliberately ignore abortion and eventually return success. The data
        // source must never expose that stale completion to its caller.
        return responseGates[request.url]!.future;
      });
      final source = HlsHttpDataSource(client: client);
      final first = source.fetch(firstUri);
      final second = source.fetch(secondUri);
      final firstExpectation = expectLater(
        first,
        throwsA(isA<HlsHttpDisposedException>()),
      );
      final secondExpectation = expectLater(
        second,
        throwsA(isA<HlsHttpDisposedException>()),
      );

      source.dispose();
      source.dispose();
      await firstExpectation;
      await secondExpectation;
      await Future<void>.delayed(Duration.zero);

      expect(abortedUris, unorderedEquals(<Uri>[firstUri, secondUri]));
      expect(source.activeRequestCount, 0);
      expect(source.isDisposed, isTrue);
      expect(client.closeCalls, 0);

      for (final gate in responseGates.values) {
        gate.complete(
          http.StreamedResponse(
            Stream<List<int>>.value(<int>[99]),
            200,
            contentLength: 1,
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'cancelAll aborts current work but leaves the source reusable',
    () async {
      final firstGate = Completer<http.StreamedResponse>();
      var attempt = 0;
      final client = _FakeClient((request) {
        attempt++;
        if (attempt == 1) return firstGate.future;
        return Future<http.StreamedResponse>.value(
          http.StreamedResponse(
            Stream<List<int>>.value(<int>[7]),
            200,
            contentLength: 1,
          ),
        );
      });
      final source = HlsHttpDataSource(client: client);
      final cancelled = source.fetch(firstUri);
      final cancelledExpectation = expectLater(
        cancelled,
        throwsA(isA<HlsHttpCancelledException>()),
      );

      source.cancelAll();
      await cancelledExpectation;
      expect(await source.fetch(secondUri), Uint8List.fromList(<int>[7]));

      firstGate.complete(
        http.StreamedResponse(
          Stream<List<int>>.value(<int>[1]),
          200,
          contentLength: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('rejects use after dispose with a typed exception', () async {
    final client = _FakeClient(
      (_) async => http.StreamedResponse(const Stream.empty(), 200),
    );
    final source = HlsHttpDataSource(client: client)..dispose();

    await expectLater(
      source.fetch(firstUri),
      throwsA(
        isA<HlsHttpDisposedException>().having(
          (error) => error.uri,
          'uri',
          firstUri,
        ),
      ),
    );
    expect(client.requests, isEmpty);
  });
}

typedef _RequestHandler =
    Future<http.StreamedResponse> Function(http.BaseRequest request);

final class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final _RequestHandler _handler;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  var closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return _handler(request);
  }

  @override
  void close() {
    closeCalls++;
  }
}
