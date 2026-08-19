import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/audio_playback_controller.dart';
import 'package:ndvy_player/src/audio/fake_pcm_sink.dart';
import 'package:ndvy_player/src/audio/pcm_sink_api.dart';
import 'package:ndvy_player/src/audio/pcm_timeline.dart';

void main() {
  PcmAudioTimeline timeline() => PcmAudioTimeline(
    sampleRate: 8000,
    channels: 2,
    basePtsUs: 200000,
    interleavedSamples: Int16List.fromList(
      List<int>.generate(24, (index) => index - 12),
    ),
  );

  test('audio playback head is the media clock', () async {
    final sink = FakePcmAudioSink(maxBufferedFrames: 8);
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    await controller.load(timeline());
    expect(controller.currentMediaTimeUs, 200000);

    await controller.play();
    expect(sink.consumeFrames(3), 3);
    await Future<void>.delayed(Duration.zero);

    expect(controller.currentMediaTimeUs, 200375);
    await controller.dispose();
  });

  test(
    'seek flushes old writes and maps the new generation to media PTS',
    () async {
      final sink = FakePcmAudioSink(maxBufferedFrames: 4);
      final controller = AudioPlaybackController(
        sink,
        framesPerChunk: 4,
        positionPollInterval: const Duration(days: 1),
      );
      await controller.load(timeline());
      final firstGeneration = controller.generation;

      await controller.seekToMediaTimeUs(200750);
      expect(controller.generation, firstGeneration + 1);
      expect(sink.generation, controller.generation);
      expect(controller.currentMediaTimeUs, 200750);

      await controller.play();
      expect(sink.consumeFrames(2), 2);
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentMediaTimeUs, 201000);
      await controller.dispose();
    },
  );

  test('completion follows consumed frames, not submitted frames', () async {
    final sink = FakePcmAudioSink(maxBufferedFrames: 12);
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    final complete = Completer<void>();
    final subscription = controller.events.listen((event) {
      if (event.type == AudioPlaybackEventType.complete &&
          !complete.isCompleted) {
        complete.complete();
      }
    });

    await controller.load(timeline());
    await controller.play();
    expect(sink.consumeFrames(12), 12);
    await complete.future;

    expect(controller.isPlaying, isFalse);
    expect(controller.currentMediaTimeUs, 201500);
    await subscription.cancel();
    await controller.dispose();
  });

  test('sink failure stops audio and is reported exactly once', () async {
    final sink = FakePcmAudioSink(maxBufferedFrames: 12);
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    final errors = <AudioPlaybackEvent>[];
    final subscription = controller.events.listen((event) {
      if (event.type == AudioPlaybackEventType.error) errors.add(event);
    });

    await controller.load(timeline());
    await controller.play();
    sink.emitError('device disconnected');
    sink.emitError('duplicate callback');
    await Future<void>.delayed(Duration.zero);

    expect(controller.isPlaying, isFalse);
    expect(sink.state, PcmSinkState.paused);
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('device disconnected'));
    await subscription.cancel();
    await controller.dispose();
  });

  test('dispose releases a load waiting for its first buffer', () async {
    final sink = FakePcmAudioSink(maxBufferedFrames: 12, startBlocked: true);
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );

    final load = controller.load(timeline());
    await Future<void>.delayed(Duration.zero);
    expect(sink.pendingWriteCount, 1);
    final expectation = expectLater(load, throwsStateError);
    await controller.dispose();
    await expectation;
  });
}
