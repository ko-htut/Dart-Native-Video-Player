import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/audio_playback_controller.dart';
import 'package:ndvy_player/src/audio/fake_pcm_sink.dart';
import 'package:ndvy_player/src/audio/pcm_sink_api.dart';
import 'package:ndvy_player/src/audio/pcm_source.dart';
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

  FilePcmAudioSource fileSource() {
    final builder = FilePcmAudioSourceBuilder(
      sampleRate: 8000,
      channels: 2,
      basePtsUs: 200000,
    );
    builder.addFloatFrameAtFrame(
      Float32List.fromList(
        List<double>.generate(24, (index) => (index - 12) / 24),
      ),
      startFrame: 0,
    );
    return builder.build();
  }

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

  test(
    'growing source waits at temporary tail and resumes after append',
    () async {
      final source = GrowingFilePcmAudioSource.create(
        sampleRate: 8000,
        channels: 1,
      );
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
        startFrame: 0,
      );
      final sink = FakePcmAudioSink(maxBufferedFrames: 8);
      final controller = AudioPlaybackController(
        sink,
        framesPerChunk: 4,
        positionPollInterval: const Duration(days: 1),
      );
      final events = <AudioPlaybackEventType>[];
      final complete = Completer<void>();
      final subscription = controller.events.listen((event) {
        events.add(event.type);
        if (event.type == AudioPlaybackEventType.complete &&
            !complete.isCompleted) {
          complete.complete();
        }
      });

      await controller.load(source);
      await controller.play();
      expect(sink.consumeFrames(4), 4);
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains(AudioPlaybackEventType.complete)));
      expect(controller.isPlaying, isTrue);
      await controller.pause();
      final tailGeneration = controller.generation;
      await controller.play();
      expect(controller.generation, tailGeneration);
      expect(controller.currentMediaTimeUs, 500);

      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.5, 0.6, 0.7, 0.8]),
        startFrame: 4,
      );
      await _waitUntil(() => sink.bufferedFrames == 4);
      expect(sink.consumeFrames(4), 4);
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains(AudioPlaybackEventType.complete)));

      source.seal();
      await complete.future;
      expect(controller.currentMediaTimeUs, 1000);
      expect(controller.isPlaying, isFalse);
      await subscription.cancel();
      await controller.dispose();
    },
  );

  test(
    'windowed source loads at retained start and rejects an evicted seek',
    () async {
      final source = GrowingFilePcmAudioSource.create(
        sampleRate: 8000,
        channels: 1,
        basePtsUs: 200000,
        maxRetainedBytes: 8,
      );
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]),
        startFrame: 0,
      );
      final sink = FakePcmAudioSink(maxBufferedFrames: 4);
      final controller = AudioPlaybackController(
        sink,
        framesPerChunk: 4,
        positionPollInterval: const Duration(days: 1),
      );

      await controller.load(source);
      expect(source.firstAvailableFrame, 4);
      expect(controller.currentMediaTimeUs, 200500);
      expect(controller.seekableStartMediaTimeUs, 200500);
      expect(controller.seekableEndMediaTimeUs, 201000);
      final generation = controller.generation;
      await expectLater(
        controller.seekToMediaTimeUs(200375),
        throwsA(isA<PcmFramesEvictedException>()),
      );
      expect(controller.generation, generation);
      expect(sink.generation, generation);

      await controller.seekToMediaTimeUs(200750);
      expect(controller.generation, generation + 1);
      expect(controller.currentMediaTimeUs, 200750);
      await controller.dispose();
    },
  );

  test('PCM eviction does not jump an already queued playback clock', () async {
    final source = GrowingFilePcmAudioSource.create(
      sampleRate: 8000,
      channels: 1,
      maxRetainedBytes: 16,
    );
    source.appendFloatFrameAtFrame(
      Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]),
      startFrame: 0,
    );
    final sink = FakePcmAudioSink(maxBufferedFrames: 4);
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );

    await controller.load(source);
    await controller.play();
    expect(sink.consumeFrames(2), 2);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentMediaTimeUs, 250);

    source.appendFloatFrameAtFrame(
      Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]),
      startFrame: 8,
    );
    expect(source.firstAvailableFrame, 8);
    expect(controller.seekableStartMediaTimeUs, 1000);
    expect(controller.currentMediaTimeUs, 250);
    await controller.dispose();
  });

  test('falling behind eviction fails one sink generation safely', () async {
    final source = GrowingFilePcmAudioSource.create(
      sampleRate: 8000,
      channels: 1,
      maxRetainedBytes: 8,
    );
    source.appendFloatFrameAtFrame(
      Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
      startFrame: 0,
    );
    final sink = FakePcmAudioSink(maxBufferedFrames: 4);
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    final errors = <AudioPlaybackEvent>[];
    final errorReady = Completer<void>();
    final subscription = controller.events.listen((event) {
      if (event.type == AudioPlaybackEventType.error) {
        errors.add(event);
        if (!errorReady.isCompleted) errorReady.complete();
      }
    });

    await controller.load(source);
    final loadedGeneration = controller.generation;
    source.appendFloatFrameAtFrame(
      Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]),
      startFrame: 4,
    );
    await errorReady.future;

    expect(errors, hasLength(1));
    expect(errors.single.message, contains('PcmFramesEvictedException'));
    expect(controller.generation, loadedGeneration + 1);
    expect(sink.generation, loadedGeneration);
    await expectLater(controller.play(), throwsStateError);
    await subscription.cancel();
    await controller.dispose();
  });

  test(
    'load waits for first growing frame and source failure unblocks it',
    () async {
      final source = GrowingFilePcmAudioSource.create(
        sampleRate: 8000,
        channels: 1,
      );
      final sink = FakePcmAudioSink(maxBufferedFrames: 4);
      final controller = AudioPlaybackController(
        sink,
        framesPerChunk: 4,
        positionPollInterval: const Duration(days: 1),
      );

      final load = controller.load(source);
      var loaded = false;
      load.then((_) => loaded = true);
      await Future<void>.delayed(Duration.zero);
      expect(loaded, isFalse);
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.1, 0.2]),
        startFrame: 0,
      );
      await load;
      expect(loaded, isTrue);

      final errors = <AudioPlaybackEvent>[];
      final subscription = controller.events.listen((event) {
        if (event.type == AudioPlaybackEventType.error) errors.add(event);
      });
      source.fail(const FormatException('AAC connection lost'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('AAC connection lost'));
      await expectLater(controller.play(), throwsStateError);
      await expectLater(
        controller.seekToMediaTimeUs(source.basePtsUs),
        throwsStateError,
      );

      await subscription.cancel();
      await controller.dispose();
    },
  );

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

  test(
    'sink failure unblocks a growing load before its first PCM frame',
    () async {
      final source = GrowingFilePcmAudioSource.create(
        sampleRate: 8000,
        channels: 1,
      );
      final sink = FakePcmAudioSink(maxBufferedFrames: 4);
      final controller = AudioPlaybackController(
        sink,
        framesPerChunk: 4,
        positionPollInterval: const Duration(days: 1),
      );
      final errors = <AudioPlaybackEvent>[];
      final subscription = controller.events.listen((event) {
        if (event.type == AudioPlaybackEventType.error) errors.add(event);
      });

      final load = controller.load(source);
      await Future<void>.delayed(Duration.zero);
      final configuredGeneration = sink.generation;
      expect(configuredGeneration, 1);

      sink.emitError('device lost before prebuffer');
      await expectLater(load, throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(controller.generation, configuredGeneration + 1);
      expect(controller.isPlaying, isFalse);
      expect(source.state, GrowingPcmAudioState.open);
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('device lost before prebuffer'));
      await expectLater(controller.play(), throwsStateError);

      await subscription.cancel();
      await controller.dispose();
    },
  );

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

  test('replacement and disposal delete owned file sources', () async {
    final sink = FakePcmAudioSink(maxBufferedFrames: 4);
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    final first = fileSource();
    final second = fileSource();
    final firstPath = first.filePath;
    final secondPath = second.filePath;

    await controller.load(first);
    expect(File(firstPath).existsSync(), isTrue);
    await controller.load(second);
    expect(File(firstPath).existsSync(), isFalse);
    expect(File(secondPath).existsSync(), isTrue);
    expect(controller.source, same(second));

    final firstDispose = controller.dispose();
    final secondDispose = controller.dispose();
    expect(secondDispose, same(firstDispose));
    await Future.wait(<Future<void>>[firstDispose, secondDispose]);
    expect(File(secondPath).existsSync(), isFalse);
  });

  test('overlapping loads cannot let a delayed old configure win', () async {
    final sink = _ControlledPcmAudioSink();
    sink.blockConfigure();
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    final first = timeline();
    final second = timeline();
    final firstLoad = controller.load(first);
    await sink.configureStarted.future;
    final firstExpectation = expectLater(firstLoad, throwsStateError);
    final secondLoad = controller.load(second);

    sink.releaseConfigure();
    await firstExpectation;
    await secondLoad;
    expect(controller.source, same(second));
    expect(sink.generation, controller.generation);
    expect(sink.configureCount, 2);
    await controller.dispose();
  });

  test('reload supersedes a delayed seek flush without stale pump', () async {
    final sink = _ControlledPcmAudioSink();
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    await controller.load(timeline());
    sink.blockFlush();
    final seek = controller.seekToMediaTimeUs(200500);
    await sink.flushStarted.future;
    final seekExpectation = expectLater(seek, throwsStateError);
    final replacement = timeline();
    final reload = controller.load(replacement);

    sink.releaseFlush();
    await seekExpectation;
    await reload;
    expect(controller.source, same(replacement));
    expect(sink.generation, controller.generation);
    await controller.dispose();
  });

  test('latest pause intent wins over a delayed play', () async {
    final sink = _ControlledPcmAudioSink();
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 4,
      positionPollInterval: const Duration(days: 1),
    );
    await controller.load(timeline());
    sink.blockPlay();
    final play = controller.play();
    await sink.playStarted.future;
    final playExpectation = expectLater(play, throwsStateError);
    final pause = controller.pause();

    sink.releasePlay();
    await playExpectation;
    await pause;
    expect(controller.isPlaying, isFalse);
    expect(sink.state, PcmSinkState.paused);
    await controller.dispose();
  });

  test(
    'configure and flush failures complete buffering and allow reload',
    () async {
      final sink = _ControlledPcmAudioSink();
      final controller = AudioPlaybackController(
        sink,
        framesPerChunk: 4,
        positionPollInterval: const Duration(days: 1),
      );

      sink.failNextConfigure = true;
      await expectLater(controller.load(timeline()), throwsStateError);
      await expectLater(controller.play(), throwsStateError);

      await controller.load(timeline());
      sink.failNextFlush = true;
      await expectLater(controller.seekToMediaTimeUs(200500), throwsStateError);
      await expectLater(controller.play(), throwsStateError);

      await controller.load(timeline());
      expect(controller.source, isNotNull);
      await controller.dispose();
    },
  );

  test('file source uses bounded reads across seek and replay', () async {
    final sink = FakePcmAudioSink(maxBufferedFrames: 6);
    final file = fileSource();
    final source = _TrackingPcmAudioSource(file);
    final path = file.filePath;
    final controller = AudioPlaybackController(
      sink,
      framesPerChunk: 3,
      positionPollInterval: const Duration(days: 1),
    );

    await controller.load(source);
    expect(source.maximumRequestedFrames, 3);

    await controller.seekToMediaTimeUs(200750);
    expect(controller.currentMediaTimeUs, 200750);
    await controller.play();
    expect(sink.consumeFrames(2), 2);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentMediaTimeUs, 201000);
    await controller.pause();

    await controller.seekToMediaTimeUs(source.endPtsUs);
    expect(controller.currentMediaTimeUs, source.endPtsUs);
    final eofGeneration = controller.generation;
    await controller.play();
    expect(controller.generation, eofGeneration + 1);
    expect(controller.currentMediaTimeUs, source.basePtsUs);
    expect(sink.consumeFrames(1), 1);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentMediaTimeUs, 200125);
    expect(source.maximumRequestedFrames, 3);
    expect(source.readStarts, containsAll(<int>[0, 6]));

    await controller.dispose();
    expect(File(path).existsSync(), isFalse);
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _TrackingPcmAudioSource implements PcmAudioSource {
  _TrackingPcmAudioSource(this.delegate);

  final PcmAudioSource delegate;
  final List<int> readStarts = <int>[];
  int maximumRequestedFrames = 0;

  @override
  int get sampleRate => delegate.sampleRate;

  @override
  int get channels => delegate.channels;

  @override
  int get basePtsUs => delegate.basePtsUs;

  @override
  int get frameCount => delegate.frameCount;

  @override
  int get durationUs => delegate.durationUs;

  @override
  int get endPtsUs => delegate.endPtsUs;

  @override
  int mediaTimeUsForFrame(int frame) => delegate.mediaTimeUsForFrame(frame);

  @override
  int frameForMediaTimeUs(int mediaTimeUs) =>
      delegate.frameForMediaTimeUs(mediaTimeUs);

  @override
  Future<PcmAudioChunk> readFrames(int firstFrame, {required int maxFrames}) {
    readStarts.add(firstFrame);
    if (maxFrames > maximumRequestedFrames) {
      maximumRequestedFrames = maxFrames;
    }
    return delegate.readFrames(firstFrame, maxFrames: maxFrames);
  }

  @override
  Future<void> dispose() => delegate.dispose();
}

final class _ControlledPcmAudioSink implements PcmAudioSink {
  final FakePcmAudioSink _delegate = FakePcmAudioSink(maxBufferedFrames: 32);
  Completer<void>? _configureGate;
  Completer<void>? _flushGate;
  Completer<void>? _playGate;
  Completer<void> configureStarted = Completer<void>();
  Completer<void> flushStarted = Completer<void>();
  Completer<void> playStarted = Completer<void>();
  bool failNextConfigure = false;
  bool failNextFlush = false;
  int configureCount = 0;

  void blockConfigure() {
    _configureGate = Completer<void>();
  }

  void releaseConfigure() {
    _configureGate?.complete();
    _configureGate = null;
  }

  void blockFlush() {
    _flushGate = Completer<void>();
  }

  void releaseFlush() {
    _flushGate?.complete();
    _flushGate = null;
  }

  void blockPlay() {
    _playGate = Completer<void>();
  }

  void releasePlay() {
    _playGate?.complete();
    _playGate = null;
  }

  @override
  PcmAudioFormat? get format => _delegate.format;

  @override
  int get generation => _delegate.generation;

  @override
  PcmSinkState get state => _delegate.state;

  @override
  Stream<PcmSinkEvent> get events => _delegate.events;

  @override
  Future<void> configure(
    PcmAudioFormat format, {
    required int generation,
  }) async {
    configureCount++;
    if (!configureStarted.isCompleted) configureStarted.complete();
    final gate = _configureGate;
    if (gate != null) await gate.future;
    if (failNextConfigure) {
      failNextConfigure = false;
      throw StateError('injected configure failure');
    }
    await _delegate.configure(format, generation: generation);
  }

  @override
  Future<int> enqueue(Uint8List interleavedPcm, {required int generation}) =>
      _delegate.enqueue(interleavedPcm, generation: generation);

  @override
  Future<void> flush({required int generation}) async {
    if (!flushStarted.isCompleted) flushStarted.complete();
    final gate = _flushGate;
    if (gate != null) await gate.future;
    if (failNextFlush) {
      failNextFlush = false;
      throw StateError('injected flush failure');
    }
    await _delegate.flush(generation: generation);
  }

  @override
  Future<void> play() async {
    if (!playStarted.isCompleted) playStarted.complete();
    final gate = _playGate;
    if (gate != null) await gate.future;
    await _delegate.play();
  }

  @override
  Future<void> pause() => _delegate.pause();

  @override
  Future<PcmPlaybackPosition> position() => _delegate.position();

  @override
  Future<void> dispose() => _delegate.dispose();
}
