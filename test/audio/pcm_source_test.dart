import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/pcm_source.dart';
import 'package:ndvy_player/src/audio/pcm_timeline.dart';

void main() {
  group('GrowingFilePcmAudioSource', () {
    test('bounded ring evicts by the tighter duration/byte limit', () async {
      final source = GrowingFilePcmAudioSource.create(
        sampleRate: 10,
        channels: 1,
        basePtsUs: 500000,
        maxRetainedDuration: const Duration(milliseconds: 600),
        maxRetainedBytes: 8,
      );
      final updates = <GrowingPcmAudioUpdate>[];
      final subscription = source.updates.listen(updates.add);
      addTearDown(subscription.cancel);
      addTearDown(source.dispose);

      expect(source.isBounded, isTrue);
      expect(source.capacityFrames, 4);
      expect(source.capacityBytes, 8);
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4, 0.5, 0.6]),
        startFrame: 0,
      );

      expect(source.frameCount, 6);
      expect(source.firstAvailableFrame, 2);
      expect(source.retainedFrameCount, 4);
      expect(source.firstAvailablePtsUs, 700000);
      expect(source.endPtsUs, 1100000);
      expect(File(source.filePath).lengthSync(), 8);
      expect(updates.single.firstAvailableFrame, 2);

      final retained = await source.readFrames(2, maxFrames: 99);
      expect(retained.startFrame, 2);
      expect(retained.frameCount, 4);
      expect(
        retained.samples,
        <double>[0.3, 0.4, 0.5, 0.6].map(floatSampleToPcm16),
      );
      await expectLater(
        source.readFrames(1, maxFrames: 1),
        throwsA(
          isA<PcmFramesEvictedException>()
              .having((error) => error.requestedFrame, 'requestedFrame', 1)
              .having(
                (error) => error.firstAvailableFrame,
                'firstAvailableFrame',
                2,
              ),
        ),
      );
    });

    test(
      'bounded ring keeps absolute reads exact across repeated wraps',
      () async {
        final source = GrowingFilePcmAudioSource.create(
          sampleRate: 1000,
          channels: 2,
          maxRetainedBytes: 16,
        );
        addTearDown(source.dispose);

        final values = List<double>.generate(20, (index) => (index - 10) / 20);
        source.appendFloatFrameAtFrame(
          Float32List.fromList(values),
          startFrame: 0,
        );

        expect(source.capacityFrames, 4);
        expect(source.frameCount, 10);
        expect(source.firstAvailableFrame, 6);
        expect(File(source.filePath).lengthSync(), 16);
        final chunk = await source.readFrames(6, maxFrames: 4);
        expect(chunk.samples, values.skip(12).map(floatSampleToPcm16));
      },
    );

    test('bounded open-tail read resumes at its absolute frame', () async {
      final source = GrowingFilePcmAudioSource.create(
        sampleRate: 1000,
        channels: 1,
        maxRetainedBytes: 8,
      );
      addTearDown(source.dispose);
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
        startFrame: 0,
      );

      var completed = false;
      final tail = source.readFrames(4, maxFrames: 2)
        ..then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.5, 0.6]),
        startFrame: 4,
      );

      final chunk = await tail;
      expect(chunk.startFrame, 4);
      expect(chunk.samples, <double>[0.5, 0.6].map(floatSampleToPcm16));
      expect(source.firstAvailableFrame, 2);
      expect(File(source.filePath).lengthSync(), 8);
    });

    test('bounded configuration requires positive complete-frame capacity', () {
      expect(
        () => GrowingFilePcmAudioSource.create(
          sampleRate: 1000,
          channels: 2,
          maxRetainedDuration: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => GrowingFilePcmAudioSource.create(
          sampleRate: 1000,
          channels: 2,
          maxRetainedBytes: 3,
        ),
        throwsArgumentError,
      );
    });

    test(
      'bounded failure and disposal unblock tail and delete storage',
      () async {
        final source = GrowingFilePcmAudioSource.create(
          sampleRate: 1000,
          channels: 1,
          maxRetainedBytes: 8,
        );
        final path = source.filePath;
        source.appendFloatFrameAtFrame(
          Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
          startFrame: 0,
        );
        final tail = source.readFrames(4, maxFrames: 1);
        final failure = StateError('live PCM producer stopped');
        source.fail(failure);

        await expectLater(tail, throwsA(same(failure)));
        expect(source.terminalError, same(failure));
        expect(File(path).lengthSync(), source.capacityBytes);
        final firstDispose = source.dispose();
        final secondDispose = source.dispose();
        expect(secondDispose, same(firstDispose));
        await firstDispose;
        expect(source.state, GrowingPcmAudioState.disposed);
        expect(File(path).existsSync(), isFalse);
      },
    );

    test(
      'tail read waits for a committed append and sealed EOF is exact',
      () async {
        final source = GrowingFilePcmAudioSource.create(
          sampleRate: 1000,
          channels: 1,
        );
        final path = source.filePath;
        addTearDown(source.dispose);

        var completed = false;
        final read = source.readFrames(0, maxFrames: 4)
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        source.appendFloatFrameAtFrame(
          Float32List.fromList(<double>[0.25, -0.25]),
          startFrame: 0,
        );
        final first = await read;
        expect(first.startFrame, 0);
        expect(first.frameCount, 2);
        expect(first.samples, <int>[8192, -8192]);
        expect(source.frameCount, 2);
        expect(File(path).lengthSync(), 4);

        final eof = source.readFrames(2, maxFrames: 4);
        await Future<void>.delayed(Duration.zero);
        expect(source.state, GrowingPcmAudioState.open);
        source.seal();
        final tail = await eof;
        expect(tail.startFrame, 2);
        expect(tail.frameCount, 0);
        expect(source.isSealed, isTrue);
        expect((await source.readFrames(99, maxFrames: 1)).startFrame, 2);
      },
    );

    test(
      'append has fixed-builder gap overlap and negative-frame semantics',
      () async {
        final fixed = FilePcmAudioSourceBuilder(sampleRate: 1000, channels: 2);
        final growing = GrowingFilePcmAudioSource.create(
          sampleRate: 1000,
          channels: 2,
        );
        addTearDown(growing.dispose);

        void append(
          List<double> values, {
          required int startFrame,
          int? validFrames,
        }) {
          final samples = Float32List.fromList(values);
          fixed.addFloatFrameAtFrame(
            samples,
            startFrame: startFrame,
            validFrames: validFrames,
          );
          growing.appendFloatFrameAtFrame(
            samples,
            startFrame: startFrame,
            validFrames: validFrames,
          );
        }

        append(<double>[0.1, -0.1, 0.2, -0.2, 0.3, -0.3], startFrame: -1);
        append(<double>[0.4, -0.4, 0.5, -0.5], startFrame: 4);
        append(
          <double>[0.6, -0.6, 0.7, -0.7, 0.8, -0.8],
          startFrame: 5,
          validFrames: 2,
        );
        final expected = fixed.build();
        addTearDown(expected.dispose);
        growing.seal();

        expect(growing.frameCount, expected.frameCount);
        final actualChunk = await growing.readFrames(
          0,
          maxFrames: growing.frameCount,
        );
        final expectedChunk = await expected.readFrames(
          0,
          maxFrames: expected.frameCount,
        );
        expect(actualChunk.pcm16le, expectedChunk.pcm16le);
      },
    );

    test('updates and prebuffer wait expose committed frame count', () async {
      final source = GrowingFilePcmAudioSource.create(
        sampleRate: 8000,
        channels: 1,
      );
      addTearDown(source.dispose);
      final updates = <GrowingPcmAudioUpdate>[];
      final subscription = source.updates.listen(updates.add);
      addTearDown(subscription.cancel);

      final ready = source.waitForFrameCount(3);
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.1, 0.2]),
        startFrame: 0,
      );
      var readyCompleted = false;
      ready.then((_) => readyCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(readyCompleted, isFalse);
      source.appendFloatFrameAtFrame(
        Float32List.fromList(<double>[0.3]),
        startFrame: 2,
      );
      await ready;

      expect(updates.map((update) => update.frameCount), <int>[2, 3]);
      source.seal();
      expect(updates.last.state, GrowingPcmAudioState.sealed);
      await expectLater(source.waitForFrameCount(4), throwsStateError);
    });

    test('failure and disposal unblock tail and prebuffer waiters', () async {
      final failed = GrowingFilePcmAudioSource.create(
        sampleRate: 8000,
        channels: 1,
      );
      final tail = failed.readFrames(0, maxFrames: 1);
      final prebuffer = failed.waitForFrameCount(1);
      final failure = FormatException('network AAC failed');
      failed.fail(failure);
      failed.fail(StateError('ignored duplicate'));
      expect(failed.state, GrowingPcmAudioState.failed);
      expect(failed.terminalError, same(failure));
      await expectLater(tail, throwsA(isA<FormatException>()));
      await expectLater(prebuffer, throwsA(isA<FormatException>()));
      await failed.dispose();

      final disposed = GrowingFilePcmAudioSource.create(
        sampleRate: 8000,
        channels: 1,
      );
      final disposedPath = disposed.filePath;
      final updateStreamDone = disposed.updates.toList();
      final disposedRead = disposed.readFrames(0, maxFrames: 1);
      final disposedWait = disposed.waitForFrameCount(1);
      final readExpectation = expectLater(disposedRead, throwsStateError);
      final waitExpectation = expectLater(disposedWait, throwsStateError);
      final firstDispose = disposed.dispose();
      final secondDispose = disposed.dispose();
      expect(secondDispose, same(firstDispose));
      await Future.wait(<Future<void>>[firstDispose, secondDispose]);
      await readExpectation;
      await waitExpectation;
      expect(
        (await updateStreamDone).last.state,
        GrowingPcmAudioState.disposed,
      );
      expect(File(disposedPath).existsSync(), isFalse);
    });
  });

  test(
    'file source is sample-exact with the in-memory timeline builder',
    () async {
      final timelineBuilder = PcmAudioTimelineBuilder(
        sampleRate: 1000,
        channels: 2,
      );
      final fileBuilder = FilePcmAudioSourceBuilder(
        sampleRate: 1000,
        channels: 2,
      );

      void add(
        Float32List samples, {
        required int startFrame,
        int? validFrames,
      }) {
        timelineBuilder.addFloatFrameAtFrame(
          samples,
          startFrame: startFrame,
          validFrames: validFrames,
        );
        fileBuilder.addFloatFrameAtFrame(
          samples,
          startFrame: startFrame,
          validFrames: validFrames,
        );
      }

      add(
        Float32List.fromList(<double>[0.1, -0.1, 0.2, -0.2, 0.3, -0.3]),
        startFrame: -1,
      );
      add(Float32List.fromList(<double>[0.4, -0.4, 0.5, -0.5]), startFrame: 4);
      add(
        Float32List.fromList(<double>[0.6, -0.6, 0.7, -0.7, 0.8, -0.8]),
        startFrame: 5,
        validFrames: 2,
      );

      final timeline = timelineBuilder.build();
      final source = fileBuilder.build();
      addTearDown(source.dispose);

      expect(source.sampleRate, timeline.sampleRate);
      expect(source.channels, timeline.channels);
      expect(source.basePtsUs, timeline.basePtsUs);
      expect(source.frameCount, timeline.frameCount);
      expect(source.durationUs, timeline.durationUs);
      expect(File(source.filePath).lengthSync(), source.frameCount * 2 * 2);

      final all = await source.readFrames(0, maxFrames: source.frameCount);
      expect(all.samples, timeline.samples);
    },
  );

  test('file source supports bounded arbitrary reads and exact EOF', () async {
    final builder = FilePcmAudioSourceBuilder(
      sampleRate: 8000,
      channels: 1,
      basePtsUs: 200000,
    );
    builder.addFloatFrameAtFrame(
      Float32List.fromList(
        List<double>.generate(10, (index) => (index - 5) / 10),
      ),
      startFrame: 0,
    );
    final source = builder.build();
    addTearDown(source.dispose);

    final reads = await Future.wait(<Future<PcmAudioChunk>>[
      source.readFrames(7, maxFrames: 2),
      source.readFrames(-10, maxFrames: 3),
      source.readFrames(9, maxFrames: 8),
      source.readFrames(99, maxFrames: 4),
    ]);

    expect(reads[0].startFrame, 7);
    expect(reads[0].frameCount, 2);
    expect(reads[0].samples, <int>[6554, 9830]);
    expect(reads[1].startFrame, 0);
    expect(reads[1].frameCount, 3);
    expect(reads[1].samples, <int>[-16384, -13107, -9830]);
    expect(reads[2].startFrame, 9);
    expect(reads[2].frameCount, 1);
    expect(reads[2].samples, <int>[13107]);
    expect(reads[3].startFrame, 10);
    expect(reads[3].frameCount, 0);
    expect(reads[3].pcm16le, isEmpty);
    expect(() => source.readFrames(0, maxFrames: 0), throwsArgumentError);
  });

  test('owned source deletes only its unique temporary directory', () async {
    final firstBuilder = FilePcmAudioSourceBuilder(
      sampleRate: 8000,
      channels: 1,
    );
    final secondBuilder = FilePcmAudioSourceBuilder(
      sampleRate: 8000,
      channels: 1,
    );
    firstBuilder.addFloatFrame(Float32List(1));
    secondBuilder.addFloatFrame(Float32List(1));
    final first = firstBuilder.build();
    final second = secondBuilder.build();
    addTearDown(second.dispose);

    expect(first.filePath, isNot(second.filePath));
    expect(File(first.filePath).existsSync(), isTrue);
    expect(File(second.filePath).existsSync(), isTrue);

    await first.dispose();
    await first.dispose();
    expect(File(first.filePath).existsSync(), isFalse);
    expect(File(second.filePath).existsSync(), isTrue);
    await expectLater(first.readFrames(0, maxFrames: 1), throwsStateError);
  });

  test('owned temp factory rejects broad, mismatched, and symlink paths', () {
    FilePcmAudioSource construct(String filePath, String directoryPath) =>
        FilePcmAudioSource.ownedTemp(
          filePath: filePath,
          ownedDirectoryPath: directoryPath,
          sampleRate: 8000,
          channels: 1,
          basePtsUs: 0,
          frameCount: 0,
        );

    expect(
      () => construct(
        '${Directory.systemTemp.path}/audio.pcm',
        Directory.systemTemp.path,
      ),
      throwsArgumentError,
    );

    final firstDirectory = Directory.systemTemp.createTempSync('ndvy_pcm_');
    final secondDirectory = Directory.systemTemp.createTempSync('ndvy_pcm_');
    addTearDown(() {
      if (firstDirectory.existsSync()) {
        firstDirectory.deleteSync(recursive: true);
      }
      if (secondDirectory.existsSync()) {
        secondDirectory.deleteSync(recursive: true);
      }
    });
    final firstFile = File('${firstDirectory.path}/audio.pcm')
      ..writeAsBytesSync(<int>[]);
    File('${secondDirectory.path}/audio.pcm').writeAsBytesSync(<int>[]);
    expect(
      () => construct(firstFile.path, secondDirectory.path),
      throwsArgumentError,
    );

    firstFile.deleteSync();
    Link(firstFile.path).createSync('${secondDirectory.path}/audio.pcm');
    expect(
      () => construct(firstFile.path, firstDirectory.path),
      throwsArgumentError,
    );
  });

  test('non-owning file source never deletes caller storage', () async {
    final directory = Directory.systemTemp.createTempSync('pcm_caller_');
    final file = File('${directory.path}/caller.pcm')
      ..writeAsBytesSync(<int>[1, 0, 2, 0]);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final source = FilePcmAudioSource.open(
      filePath: file.path,
      sampleRate: 8000,
      channels: 1,
      basePtsUs: 0,
      frameCount: 2,
    );

    expect((await source.readFrames(0, maxFrames: 2)).samples, <int>[1, 2]);
    await source.dispose();
    expect(file.existsSync(), isTrue);
  });
}
