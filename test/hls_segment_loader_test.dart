import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/hls.dart';
import 'package:ndvy_player/src/hls_segment_loader.dart';

void main() {
  List<HlsSegment> segments(int count, {int firstSequence = 100}) =>
      <HlsSegment>[
        for (var index = 0; index < count; index++)
          HlsSegment(
            uri: Uri.parse('https://media.example/segment_$index.ts'),
            duration: 6,
            sequence: firstSequence + index,
          ),
      ];

  Future<void> flushAsyncWork() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'bounds in-flight and resident results and emits exact sequence order',
    () async {
      final input = segments(6);
      final gates = <Uri, Completer<Uint8List>>{
        for (final segment in input) segment.uri: Completer<Uint8List>(),
      };
      final started = <int>[];
      var inFlight = 0;
      var maxInFlight = 0;
      var completedNotEmitted = 0;
      var maxResidentResults = 0;

      final loader = HlsSegmentLoader.fromSegments(
        // Deliberately reverse the input to verify media-sequence ordering.
        segments: input.reversed,
        prefetchWindow: 3,
        fetcher: (uri) async {
          final index = input.indexWhere((segment) => segment.uri == uri);
          started.add(index);
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          final bytes = await gates[uri]!.future;
          inFlight--;
          completedNotEmitted++;
          if (completedNotEmitted > maxResidentResults) {
            maxResidentResults = completedNotEmitted;
          }
          return bytes;
        },
      );

      final emitted = <HlsLoadedSegment>[];
      final streamDone = Completer<void>();
      loader.stream.listen(
        (loaded) {
          emitted.add(loaded);
          completedNotEmitted--;
        },
        onError: streamDone.completeError,
        onDone: streamDone.complete,
      );

      await flushAsyncWork();
      expect(started, <int>[0, 1, 2]);

      // Later requests may finish first, but they remain in the bounded window.
      gates[input[2].uri]!.complete(Uint8List.fromList(<int>[2]));
      gates[input[1].uri]!.complete(Uint8List.fromList(<int>[1]));
      await flushAsyncWork();
      expect(emitted, isEmpty);
      expect(started, <int>[0, 1, 2]);

      gates[input[0].uri]!.complete(Uint8List.fromList(<int>[0]));
      await flushAsyncWork();
      expect(started, <int>[0, 1, 2, 3, 4, 5]);

      // Finish the second window in reverse order too.
      gates[input[5].uri]!.complete(Uint8List.fromList(<int>[5]));
      gates[input[4].uri]!.complete(Uint8List.fromList(<int>[4]));
      gates[input[3].uri]!.complete(Uint8List.fromList(<int>[3]));
      await streamDone.future;

      expect(emitted.map((loaded) => loaded.sequence), <int>[
        100,
        101,
        102,
        103,
        104,
        105,
      ]);
      expect(emitted.map((loaded) => loaded.bytes.single), <int>[
        0,
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(maxInFlight, lessThanOrEqualTo(3));
      expect(maxResidentResults, lessThanOrEqualTo(3));
      expect(loader.isCancelled, isFalse);
      await loader.done;
    },
  );

  test('stream pause applies backpressure without filling the VOD', () async {
    final input = segments(10);
    final gates = <Uri, Completer<Uint8List>>{
      for (final segment in input) segment.uri: Completer<Uint8List>(),
    };
    final started = <Uri>[];
    final loader = HlsSegmentLoader.fromSegments(
      segments: input,
      prefetchWindow: 4,
      fetcher: (uri) {
        started.add(uri);
        return gates[uri]!.future;
      },
    );

    late StreamSubscription<HlsLoadedSegment> subscription;
    final firstEvent = Completer<void>();
    subscription = loader.stream.listen((loaded) {
      subscription.pause();
      firstEvent.complete();
    });

    await flushAsyncWork();
    expect(started, hasLength(4));
    gates[input.first.uri]!.complete(Uint8List(1));
    await firstEvent.future;
    await flushAsyncWork();

    // The emitted slot is not refilled while downstream is paused.
    expect(started, hasLength(4));
    expect(started.length, lessThan(input.length));

    await subscription.cancel();
    expect(loader.isCancelled, isTrue);
    await loader.done;
  });

  test('subscription cancellation prevents all new work', () async {
    final input = segments(8);
    final gates = <Uri, Completer<Uint8List>>{
      for (final segment in input) segment.uri: Completer<Uint8List>(),
    };
    final started = <Uri>[];
    final loader = HlsSegmentLoader.fromSegments(
      segments: input,
      prefetchWindow: 3,
      fetcher: (uri) {
        started.add(uri);
        return gates[uri]!.future;
      },
    );

    final subscription = loader.stream.listen((_) {});
    await flushAsyncWork();
    expect(started, hasLength(3));

    await subscription.cancel();
    for (final uri in started) {
      gates[uri]!.complete(Uint8List(1));
    }
    await flushAsyncWork();

    expect(started, hasLength(3));
    expect(loader.isCancelled, isTrue);
    await loader.done;
  });

  test('default retry predicate retries then succeeds', () async {
    final input = segments(1);
    var attempts = 0;
    final failedAttempts = <int>[];
    final slept = <Duration>[];
    final loader = HlsSegmentLoader.fromSegments(
      segments: input,
      maxAttempts: 3,
      fetcher: (_) async {
        attempts++;
        if (attempts < 3) throw StateError('temporary $attempts');
        return Uint8List.fromList(<int>[42]);
      },
      retryBackoff: (segment, failedAttempt, error) {
        failedAttempts.add(failedAttempt);
        return Duration(milliseconds: failedAttempt * 7);
      },
      retrySleeper: (delay) async {
        slept.add(delay);
      },
    );

    final loaded = await loader.stream.single;

    expect(loaded.sequence, 100);
    expect(loaded.bytes, Uint8List.fromList(<int>[42]));
    expect(loaded.attempts, 3);
    expect(attempts, 3);
    expect(failedAttempts, <int>[1, 2]);
    expect(slept, <Duration>[
      const Duration(milliseconds: 7),
      const Duration(milliseconds: 14),
    ]);
  });

  test('non-retryable fetch failure stops before backoff', () async {
    final input = segments(1, firstSequence: 91);
    var attempts = 0;
    final classifiedAttempts = <int>[];
    final errors = <Object>[];
    final streamDone = Completer<void>();
    final loader = HlsSegmentLoader.fromSegments(
      segments: input,
      maxAttempts: 5,
      fetcher: (_) async {
        attempts++;
        throw StateError('permanent failure');
      },
      retryPredicate: (segment, failedAttempt, error) {
        expect(segment.sequence, 91);
        expect(error, isA<StateError>());
        classifiedAttempts.add(failedAttempt);
        return false;
      },
      retryBackoff: (_, _, _) {
        fail('a non-retryable failure must not request backoff');
      },
      retrySleeper: (_) async {
        fail('a non-retryable failure must not sleep');
      },
    );

    loader.stream.listen(
      (_) => fail('a failed segment must not be emitted'),
      onError: errors.add,
      onDone: streamDone.complete,
    );
    await streamDone.future;

    expect(attempts, 1);
    expect(classifiedAttempts, <int>[1]);
    expect(errors, hasLength(1));
    final error = errors.single as HlsSegmentLoadException;
    expect(error.attempts, 1);
    expect(error.cause, isA<StateError>());
    expect(error.toString(), contains('media sequence 91'));
  });

  test(
    'reports a clear terminal error after the bounded retry budget',
    () async {
      final input = segments(2, firstSequence: 40);
      var attempts = 0;
      final errors = <Object>[];
      final streamDone = Completer<void>();
      final loader = HlsSegmentLoader.fromSegments(
        segments: input,
        prefetchWindow: 1,
        maxAttempts: 2,
        fetcher: (_) async {
          attempts++;
          throw StateError('offline');
        },
        retryBackoff: (_, _, _) => Duration.zero,
        retrySleeper: (_) async {},
      );

      loader.stream.listen(
        (_) => fail('a failed segment must not be emitted'),
        onError: errors.add,
        onDone: streamDone.complete,
      );
      await streamDone.future;

      expect(attempts, 2);
      expect(errors, hasLength(1));
      final error = errors.single as HlsSegmentLoadException;
      expect(error.segment.sequence, 40);
      expect(error.segment.uri, input.first.uri);
      expect(error.attempts, 2);
      expect(error.cause, isA<StateError>());
      expect(error.toString(), contains('media sequence 40'));
      expect(error.toString(), contains(input.first.uri.toString()));
      expect(error.toString(), contains('after 2 attempts'));
      expect(loader.isCancelled, isFalse);
    },
  );

  test(
    'cancellation interrupts retry wait and dispose is idempotent',
    () async {
      final retryStarted = Completer<void>();
      final neverWake = Completer<void>();
      var attempts = 0;
      final loader = HlsSegmentLoader.fromSegments(
        segments: segments(1),
        maxAttempts: 5,
        fetcher: (_) async {
          attempts++;
          throw StateError('retry me');
        },
        retryBackoff: (_, _, _) => const Duration(days: 1),
        retrySleeper: (_) {
          retryStarted.complete();
          return neverWake.future;
        },
      );

      loader.stream.listen((_) {});
      await retryStarted.future;
      await loader.dispose();
      await loader.dispose();
      await flushAsyncWork();

      expect(attempts, 1);
      expect(loader.isCancelled, isTrue);
      expect(loader.isDisposed, isTrue);
      await loader.done;
    },
  );

  test('rejects an oversized response once without retrying it', () async {
    final input = segments(1, firstSequence: 77);
    var attempts = 0;
    final errors = <Object>[];
    final streamDone = Completer<void>();
    final loader = HlsSegmentLoader.fromSegments(
      segments: input,
      maxAttempts: 5,
      maxSegmentBytes: 2,
      fetcher: (_) async {
        attempts++;
        return Uint8List.fromList(<int>[1, 2, 3]);
      },
      retryBackoff: (_, _, _) {
        fail('an oversized successful response must not be retried');
      },
      retrySleeper: (_) async {
        fail('an oversized successful response must not sleep');
      },
    );

    loader.stream.listen(
      (_) => fail('an oversized segment must not be emitted'),
      onError: errors.add,
      onDone: streamDone.complete,
    );
    await streamDone.future;

    expect(attempts, 1);
    expect(errors, hasLength(1));
    final error = errors.single as HlsSegmentLoadException;
    expect(error.attempts, 1);
    final cause = error.cause as HlsSegmentTooLargeException;
    expect(cause.segment.sequence, 77);
    expect(cause.actualBytes, 3);
    expect(cause.maxBytes, 2);
    expect(cause.toString(), contains('returned 3 bytes'));
    expect(cause.toString(), contains('limit is 2 bytes'));
  });

  test('validates window, attempts, and duplicate media sequences', () {
    final oneSegment = segments(1);
    Future<Uint8List> fetcher(Uri _) async => Uint8List(0);

    expect(
      () => HlsSegmentLoader.fromSegments(
        segments: oneSegment,
        fetcher: fetcher,
        prefetchWindow: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => HlsSegmentLoader.fromSegments(
        segments: oneSegment,
        fetcher: fetcher,
        maxSegmentBytes: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => HlsSegmentLoader.fromSegments(
        segments: oneSegment,
        fetcher: fetcher,
        maxAttempts: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => HlsSegmentLoader.fromSegments(
        segments: <HlsSegment>[oneSegment.single, oneSegment.single],
        fetcher: fetcher,
      ),
      throwsArgumentError,
    );
  });
}
