import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/audio_decode_pipeline.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

void main() {
  test('Dart-compatible butterfly asset decodes every video picture', () {
    final bytes = File('assets/butterfly_dart.mp4').readAsBytesSync();
    final track = Mp4Demux.parseH264Track(bytes);
    final decoder = H264BaselineDecoder();

    expect(track.sampleSizes, hasLength(226));
    for (var index = 0; index < track.sampleSizes.length; index++) {
      final sampleNals = Mp4Demux.readSampleNalUnits(bytes, track, index);
      final hasIdr = sampleNals.any(
        (nal) => nal.isNotEmpty && (nal[0] & 0x1f) == 5,
      );
      final nals = <Uint8List>[
        if (index == 0 || hasIdr) ...track.avc.sps,
        if (index == 0 || hasIdr) ...track.avc.pps,
        ...sampleNals,
      ];

      final frame = decoder.decodeAccessUnit(nals);
      expect(
        frame,
        isNotNull,
        reason: 'butterfly sample $index failed: ${decoder.lastError}',
      );
      expect(frame!.width, 854);
      expect(frame.height, 480);
    }
  });

  test('Dart-compatible butterfly asset decodes its AAC track', () async {
    final bytes = File('assets/butterfly_dart.mp4').readAsBytesSync();
    final track = Mp4Demux.parseAacTrack(bytes);

    expect(track, isNotNull);
    final timeline = await decodeMp4AacToPcmInBackground(bytes, track!);
    expect(timeline.sampleRate, 48000);
    expect(timeline.channels, 2);
    expect(timeline.durationUs, closeTo(7530000, 30000));
    expect(timeline.samples.any((sample) => sample != 0), isTrue);
  });
}
