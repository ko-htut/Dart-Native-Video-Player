import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/pcm_timeline.dart';

void main() {
  test(
    'float PCM conversion clips endpoints and silences non-finite input',
    () {
      expect(floatSampleToPcm16(-2), -32768);
      expect(floatSampleToPcm16(-1), -32768);
      expect(floatSampleToPcm16(0), 0);
      expect(floatSampleToPcm16(1), 32767);
      expect(floatSampleToPcm16(2), 32767);
      expect(floatSampleToPcm16(double.nan), 0);
    },
  );

  test('builder inserts timestamp gaps and trims overlaps by whole frames', () {
    final builder = PcmAudioTimelineBuilder(sampleRate: 1000, channels: 2);
    builder.addFloatFrame(
      Float32List.fromList(<double>[0.25, -0.25, 0.5, -0.5]),
      ptsUs: 100000,
    );
    // Target starts at frame four, leaving frames two and three silent.
    builder.addFloatFrame(
      Float32List.fromList(<double>[0.75, -0.75, 1, -1]),
      ptsUs: 104000,
    );
    // Starts on frame five, overlapping one frame already present.
    builder.addFloatFrame(
      Float32List.fromList(<double>[0.1, -0.1, 0.2, -0.2]),
      ptsUs: 105000,
    );

    final timeline = builder.build();
    expect(timeline.basePtsUs, 100000);
    expect(timeline.frameCount, 7);
    expect(timeline.samples, <int>[
      8192,
      -8192,
      16384,
      -16384,
      0,
      0,
      0,
      0,
      24576,
      -24576,
      32767,
      -32768,
      6554,
      -6554,
    ]);
  });

  test('maps media time to frames and emits bounded interleaved chunks', () {
    final timeline = PcmAudioTimeline(
      sampleRate: 1000,
      channels: 2,
      basePtsUs: 200000,
      interleavedSamples: Int16List.fromList(List<int>.generate(20, (i) => i)),
    );

    expect(timeline.frameForMediaTimeUs(199000), 0);
    expect(timeline.frameForMediaTimeUs(205000), 5);
    expect(timeline.mediaTimeUsForFrame(5), 205000);
    expect(timeline.endPtsUs, 210000);

    final chunks = timeline.chunksFromFrame(3, framesPerChunk: 4).toList();
    expect(chunks.map((chunk) => chunk.frameCount), <int>[4, 3]);
    expect(chunks.first.startFrame, 3);
    expect(chunks.first.samples, <int>[6, 7, 8, 9, 10, 11, 12, 13]);
  });

  test('rejects an unbounded timestamp gap', () {
    final builder = PcmAudioTimelineBuilder(
      sampleRate: 1000,
      channels: 1,
      maxGap: const Duration(milliseconds: 5),
    );
    builder.addFloatFrame(Float32List(1), ptsUs: 0);
    expect(
      () => builder.addFloatFrame(Float32List(1), ptsUs: 10000),
      throwsFormatException,
    );
  });

  test('exact frame positions trim priming and final padding', () {
    final builder = PcmAudioTimelineBuilder(
      sampleRate: 48000,
      channels: 1,
      basePtsUs: 0,
    );
    builder.addFloatFrameAtFrame(
      Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
      startFrame: -2,
    );
    builder.addFloatFrameAtFrame(
      Float32List.fromList(<double>[0.5, 0.6, 0.7, 0.8]),
      startFrame: 2,
      validFrames: 2,
    );

    final timeline = builder.build();
    expect(timeline.basePtsUs, 0);
    expect(timeline.frameCount, 4);
    expect(timeline.samples, <int>[9830, 13107, 16384, 19661]);
  });
}
