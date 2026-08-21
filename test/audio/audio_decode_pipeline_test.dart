import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';
import 'package:ndvy_player/src/audio/audio_decode_pipeline.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

void main() {
  test('decodes the complete MP4 AAC track and applies edit-list trimming', () {
    final bytes = File('assets/baby_aac.mp4').readAsBytesSync();
    final track = Mp4Demux.parseAacTrack(bytes)!;
    final timeline = decodeMp4AacToPcm(bytes, track);

    expect(timeline.sampleRate, 48000);
    expect(timeline.channels, 2);
    expect(timeline.basePtsUs, 0);
    expect(timeline.frameCount, 282000);
    expect(timeline.durationUs, 5875000);
    expect(timeline.samples.any((sample) => sample != 0), isTrue);
  });

  test('MP4 background job is isolate-sendable', () async {
    final bytes = File('assets/baby_aac.mp4').readAsBytesSync();
    final track = Mp4Demux.parseAacTrack(bytes)!;

    final timeline = await decodeMp4AacToPcmInBackground(bytes, track);

    expect(timeline.frameCount, 282000);
    expect(timeline.durationUs, 5875000);
  });

  test(
    'file-backed MP4 decode is byte-exact with the timeline decode',
    () async {
      final bytes = File('assets/baby_aac.mp4').readAsBytesSync();
      final track = Mp4Demux.parseAacTrack(bytes)!;
      final timeline = decodeMp4AacToPcm(bytes, track);
      final source = await decodeMp4AacToFilePcmInBackground(bytes, track);
      final path = source.filePath;

      expect(source.sampleRate, timeline.sampleRate);
      expect(source.channels, timeline.channels);
      expect(source.basePtsUs, timeline.basePtsUs);
      expect(source.frameCount, timeline.frameCount);
      expect(File(path).lengthSync(), timeline.samples.length * 2);

      const framesPerRead = 4093;
      var frame = 0;
      while (frame < source.frameCount) {
        final chunk = await source.readFrames(frame, maxFrames: framesPerRead);
        final firstSample = frame * source.channels;
        final lastSample = (frame + chunk.frameCount) * source.channels;
        expect(
          chunk.samples,
          timeline.samples.sublist(firstSample, lastSample),
          reason: 'PCM differs at frame $frame',
        );
        frame += chunk.frameCount;
      }

      await source.dispose();
      expect(File(path).existsSync(), isFalse);
    },
  );

  test(
    'aligns independently unwrapped audio across MPEG PTS rollover',
    () async {
      final bytes = File('assets/baby_aac.mp4').readAsBytesSync();
      final track = Mp4Demux.parseAacTrack(bytes)!;
      final units = <AacAccessUnit>[
        AacAccessUnit(
          payload: Mp4Demux.readAudioSample(bytes, track, 0),
          config: track.config,
          pts90k: 50,
          sampleCount: 1024,
        ),
        AacAccessUnit(
          payload: Mp4Demux.readAudioSample(bytes, track, 1),
          config: track.config,
          pts90k: 1970,
          sampleCount: 1024,
        ),
      ];

      // Video starts 100 ticks before rollover; the audio parser independently
      // starts at raw PTS 50 just after rollover. They are only 150 ticks apart.
      final timeline = await decodeTransportAacToPcmInBackground(
        units,
        originPts90k: (1 << 33) - 100,
      );
      expect(timeline.frameCount, 80 + 2 * 1024);
      expect(timeline.samples.take(80 * 2), everyElement(0));

      final source = await decodeTransportAacToFilePcmInBackground(
        units,
        originPts90k: (1 << 33) - 100,
      );
      addTearDown(source.dispose);
      expect(source.frameCount, timeline.frameCount);
      final chunk = await source.readFrames(0, maxFrames: source.frameCount);
      expect(chunk.samples, timeline.samples);
    },
  );
}
