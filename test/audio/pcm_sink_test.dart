import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/pcm_sink.dart';

void main() {
  group('PcmAudioFormat', () {
    test('describes interleaved S16LE frames', () {
      final mono = PcmAudioFormat(sampleRate: 44100, channelCount: 1);
      final stereo = PcmAudioFormat(sampleRate: 48000, channelCount: 2);

      expect(mono.bytesPerSample, 2);
      expect(mono.bytesPerFrame, 2);
      expect(stereo.bytesPerFrame, 4);
      expect(
        const PcmPlaybackPosition(
          generation: 3,
          frames: 48000,
          sampleRate: 48000,
        ).mediaDuration,
        const Duration(seconds: 1),
      );
    });

    test('rejects unsafe sample rates and channel counts', () {
      expect(
        () => PcmAudioFormat(sampleRate: 7999, channelCount: 2),
        throwsRangeError,
      );
      expect(
        () => PcmAudioFormat(sampleRate: 48000, channelCount: 0),
        throwsRangeError,
      );
    });
  });

  group('FakePcmAudioSink', () {
    late FakePcmAudioSink sink;
    late PcmAudioFormat format;

    setUp(() {
      sink = FakePcmAudioSink(maxBufferedFrames: 4);
      format = PcmAudioFormat(sampleRate: 48000, channelCount: 2);
    });

    tearDown(() async {
      await sink.dispose();
    });

    test('requires configuration and frame-aligned writes', () async {
      expect(
        () => sink.enqueue(Uint8List(4), generation: 0),
        throwsA(isA<PcmSinkStateException>()),
      );

      await sink.configure(format, generation: 7);
      expect(sink.state, PcmSinkState.paused);
      expect(
        () => sink.enqueue(Uint8List(3), generation: 7),
        throwsArgumentError,
      );
      expect(
        () => sink.enqueue(Uint8List(4), generation: 6),
        throwsA(isA<PcmSinkStateException>()),
      );
    });

    test('applies bounded backpressure and reports consumed frames', () async {
      final events = <PcmSinkEvent>[];
      final subscription = sink.events.listen(events.add);
      await sink.configure(format, generation: 1);
      await sink.play();

      expect(await sink.enqueue(Uint8List(16), generation: 1), 4);
      expect(sink.bufferedFrames, 4);

      var secondAccepted = false;
      final second = sink.enqueue(Uint8List(8), generation: 1).then((frames) {
        secondAccepted = true;
        return frames;
      });
      await Future<void>.delayed(Duration.zero);
      expect(secondAccepted, isFalse);
      expect(sink.pendingWriteCount, 1);

      expect(sink.consumeFrames(2), 2);
      expect(await second, 2);
      expect(sink.bufferedFrames, 4);
      expect(
        events.where((event) => event.type == PcmSinkEventType.bufferConsumed),
        contains(
          isA<PcmSinkEvent>()
              .having((event) => event.generation, 'generation', 1)
              .having((event) => event.frames, 'frames', 2),
        ),
      );
      await subscription.cancel();
    });

    test('pause preserves queued PCM and freezes position', () async {
      await sink.configure(format, generation: 2);
      await sink.enqueue(Uint8List(16), generation: 2);
      await sink.play();
      expect(sink.consumeFrames(1), 1);
      await sink.pause();

      expect(sink.consumeFrames(3), 0);
      final position = await sink.position();
      expect(position.generation, 2);
      expect(position.frames, 1);
      expect(sink.bufferedFrames, 3);
    });

    test(
      'flush invalidates waiters and resets generation and position',
      () async {
        await sink.configure(format, generation: 4);
        await sink.enqueue(Uint8List(16), generation: 4);
        final blocked = sink.enqueue(Uint8List(4), generation: 4);
        final blockedExpectation = expectLater(
          blocked,
          throwsA(isA<PcmSinkStateException>()),
        );

        await sink.flush(generation: 5);
        await blockedExpectation;
        expect(sink.generation, 5);
        expect(sink.bufferedFrames, 0);
        expect((await sink.position()).frames, 0);
        expect(
          () => sink.enqueue(Uint8List(4), generation: 4),
          throwsA(isA<PcmSinkStateException>()),
        );
        expect(await sink.enqueue(Uint8List(4), generation: 5), 1);
      },
    );

    test('dispose is idempotent and rejects later operations', () async {
      await sink.configure(format, generation: 1);
      await sink.dispose();
      await sink.dispose();

      expect(sink.state, PcmSinkState.disposed);
      expect(() => sink.play(), throwsA(isA<PcmSinkStateException>()));
    });
  });
}
