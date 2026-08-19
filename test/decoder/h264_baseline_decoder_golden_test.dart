import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

void main() {
  test('decodes the complete baseline MP4 pixel-exactly', () {
    final bytes = File('assets/baby.mp4').readAsBytesSync();
    final track = Mp4Demux.parseH264Track(bytes);
    final decoder = H264BaselineDecoder();
    final decodedSequence = BytesBuilder(copy: false);

    expect(track.sampleSizes, hasLength(141));

    for (
      var sampleIndex = 0;
      sampleIndex < track.sampleSizes.length;
      sampleIndex++
    ) {
      final nals = _sampleNals(bytes, track, sampleIndex);

      final frame = decoder.decodeAccessUnit(nals);

      expect(
        frame,
        isNotNull,
        reason: 'sample $sampleIndex failed: ${decoder.lastError}',
      );
      decodedSequence
        ..add(frame!.y)
        ..add(frame.u)
        ..add(frame.v);
    }

    // Generated independently with Apple AVAssetReader as planar I420, using
    // active rows only. FFmpeg's H.264 decoder produces the same digest.
    expect(
      sha256.convert(decodedSequence.takeBytes()).toString(),
      'ccd20c092507bb8150d0d8759de51658e6314e5c3a6360f7bc18b7f438f23bf9',
    );
  });

  test('can restart cleanly from every random-access picture', () {
    final bytes = File('assets/baby.mp4').readAsBytesSync();
    final track = Mp4Demux.parseH264Track(bytes);
    const expected = <int, String>{
      0: 'e8587372bac5a06a59ec0729f522bb51683317ff71b71b09a540d9196093d912',
      30: '31b4fd21a833929d84451e387dd7549607103d9bc24a35a383fb8c12fdbd348d',
      60: '38ffb4fc138218ff409eea8ec2917a4668659aa6510a0d87f2bd693af04070bc',
      90: 'be84b03cb5709d23cf076048cbd0d884aa77b0b8a2376e6490bed8d7e11ec16f',
      120: '74a59fd5d3c7dbaf70a41402fd073490fa918f006775edd1948c51f72f7fbbed',
    };

    for (final entry in expected.entries) {
      final decoder = H264BaselineDecoder();
      final frame = decoder.decodeAccessUnit(
        _sampleNals(bytes, track, entry.key),
      );
      expect(frame, isNotNull, reason: decoder.lastError);
      expect(
        sha256.convert(<int>[...frame!.y, ...frame.u, ...frame.v]).toString(),
        entry.value,
        reason: 'random-access sample ${entry.key}',
      );
    }
  });

  test('rejects a predictive picture when its reference is missing', () {
    final bytes = File('assets/baby.mp4').readAsBytesSync();
    final track = Mp4Demux.parseH264Track(bytes);
    final decoder = H264BaselineDecoder();

    final predictiveNals = <Uint8List>[
      ...track.avc.sps,
      ...track.avc.pps,
      ...Mp4Demux.readSampleNalUnits(bytes, track, 1),
    ];
    expect(decoder.decodeAccessUnit(predictiveNals), isNull);
    expect(decoder.lastError, contains('no decoded reference picture'));
  });
}

List<Uint8List> _sampleNals(
  Uint8List bytes,
  Mp4VideoTrack track,
  int sampleIndex,
) {
  final nals = <Uint8List>[];
  if (sampleIndex == 0 || sampleIndex % 30 == 0) {
    nals
      ..addAll(track.avc.sps)
      ..addAll(track.avc.pps);
  }
  return nals..addAll(Mp4Demux.readSampleNalUnits(bytes, track, sampleIndex));
}
