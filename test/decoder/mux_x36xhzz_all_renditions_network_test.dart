import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/access_unit_pts.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/hls.dart';
import 'package:ndvy_player/src/ts_h264_demux.dart';
import 'package:ndvy_player/src/yuv.dart';

const _runNetworkRegression = bool.fromEnvironment(
  'MUX_FULL_RENDITION_REGRESSION',
);

const _master = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

const _expected = <String, ({int pictures, String digest})>{
  '320x184': (
    pictures: 300,
    digest: '69bbfd15fdfb899b043ea02ffde9fe641bc8a46469ac4c319a15e981ada846c5',
  ),
  '512x288': (
    pictures: 300,
    digest: '1ac4c4b139cff14b7463d7afaf75144e32fba85b269b414bf239a6e541d7d025',
  ),
  '848x480': (
    pictures: 600,
    digest: '4fde5a97804c0943d0e21cb67338c15f3ee23c2e19e7b063f61cb81a5538efea',
  ),
  '1280x720': (
    pictures: 600,
    digest: '80e6763e1f566865a7de5153727bbc181cce6c0377fec84d0adce701312cab30',
  ),
  '1920x1080': (
    pictures: 600,
    digest: '01fddf55ce484d677047ad93eebd9f4e4a1f7b4a4db2afd026c34d2e4861b5c8',
  ),
};

void main() {
  test(
    'decodes the first complete segment of every Mux rendition pixel-exactly',
    () async {
      final variants = await fetchHlsVariants(Uri.parse(_master));
      expect(
        variants.map((variant) => variant.resolution),
        unorderedEquals(_expected.keys),
      );

      for (final variant in variants) {
        final resolution = variant.resolution!;
        final expected = _expected[resolution]!;
        final playlist = await fetchMediaPlaylist(variant.uri);
        final bytes = await fetchBytes(playlist.segments.first.uri);
        final demuxer = TsH264Demuxer();
        final accessUnits = <TimestampedAccessUnit>[
          ...demuxer.pushSegment(bytes),
          ...demuxer.finish(),
        ];
        expect(accessUnits, hasLength(expected.pictures), reason: resolution);

        final decoder = H264BaselineDecoder();
        final presentation = <({int ptsMs, Digest digest})>[];
        for (var index = 0; index < accessUnits.length; index++) {
          final accessUnit = accessUnits[index];
          final frame = decoder.decodeAccessUnit(accessUnit.nals);
          expect(
            frame,
            isNotNull,
            reason: '$resolution AU $index: ${decoder.lastError}',
          );
          presentation.add((
            ptsMs: accessUnit.ptsMs,
            digest: _frameDigest(frame!),
          ));
        }
        presentation.sort((a, b) => a.ptsMs.compareTo(b.ptsMs));
        final sequenceSink = _DigestSink();
        final sequence = sha256.startChunkedConversion(sequenceSink);
        for (final frame in presentation) {
          sequence.add(frame.digest.bytes);
        }
        sequence.close();
        expect(
          sequenceSink.value.toString(),
          expected.digest,
          reason: resolution,
        );
      }
    },
    skip: _runNetworkRegression
        ? false
        : 'enable with --dart-define=MUX_FULL_RENDITION_REGRESSION=true',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Digest _frameDigest(Yuv420Frame frame) {
  final sink = _DigestSink();
  sha256.startChunkedConversion(sink)
    ..add(frame.y)
    ..add(frame.u)
    ..add(frame.v)
    ..close();
  return sink.value!;
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
