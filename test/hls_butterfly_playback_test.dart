import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/access_unit_pts.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';
import 'package:ndvy_player/src/audio/aac/ts_aac_demux.dart';
import 'package:ndvy_player/src/audio/audio_decode_pipeline.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/hls.dart';
import 'package:ndvy_player/src/pes_pts.dart';
import 'package:ndvy_player/src/ts_packets.dart';
import 'package:ndvy_player/src/ts_pes.dart';
import 'package:ndvy_player/src/ts_psi.dart';

const _fixtureRoot = 'test/fixtures/hls/butterfly';

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> requests;
  late Uri origin;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}/');
    requests = server.listen(_serveFixture);
  });

  tearDownAll(() async {
    await requests.cancel();
    await server.close(force: true);
  });

  test(
    'loads the deterministic master and media playlists over HTTP',
    () async {
      final masterUri = origin.resolve('master.m3u8');

      expect(await detectPlaylistKind(masterUri), HlsPlaylistKind.master);
      final variants = await fetchHlsVariants(masterUri);
      expect(variants, hasLength(1));
      expect(variants.single.bandwidth, 1800000);
      expect(variants.single.resolution, '854x480');
      expect(variants.single.codecs, 'avc1.42C01F,mp4a.40.2');
      expect(variants.single.uri, origin.resolve('media.m3u8'));

      expect(
        await detectPlaylistKind(variants.single.uri),
        HlsPlaylistKind.media,
      );
      final media = await fetchMediaPlaylist(variants.single.uri);
      expect(media.targetDuration, 2);
      expect(media.mediaSequence, 0);
      expect(media.isEndList, isTrue);
      expect(media.segments, hasLength(4));
      expect(
        media.segments.map((segment) => segment.sequence),
        orderedEquals(<int>[0, 1, 2, 3]),
      );
      expect(
        media.segments.map((segment) => segment.duration),
        orderedEquals(<double>[2.002, 2.002, 2.002, 1.534867]),
      );
      expect(
        media.segments.map((segment) => segment.uri.pathSegments.last),
        orderedEquals(<String>[
          'segment_000.ts',
          'segment_001.ts',
          'segment_002.ts',
          'segment_003.ts',
        ]),
      );

      final firstSegment = await fetchBytes(media.segments.first.uri);
      expect(firstSegment, isNotEmpty);
      expect(firstSegment.length % 188, 0);
      expect(firstSegment.first, 0x47);
    },
  );

  test(
    'demuxes and decodes every HLS butterfly video and audio access unit',
    () async {
      final variants = await fetchHlsVariants(origin.resolve('master.m3u8'));
      final media = await fetchMediaPlaylist(variants.single.uri);

      TsPesAssembler? videoPes;
      TsAacDemuxer? audioDemuxer;
      int? videoPid;
      int? audioPid;
      int? baseVideoPts90k;
      final videoChunks = <PtsChunk>[];
      final audioUnits = <AacAccessUnit>[];

      for (final segment in media.segments) {
        final bytes = await fetchBytes(segment.uri);
        final packets = parseTsPackets(bytes).toList(growable: false);
        final pat = TsPat.find(packets);
        expect(pat, isNotNull, reason: 'PAT missing in ${segment.uri}');
        final pmt = TsPmt.find(packets, pat!.programs.values.single);
        expect(pmt, isNotNull, reason: 'PMT missing in ${segment.uri}');

        final segmentVideo = pmt!.streams.singleWhere(
          (stream) => stream.streamType == 0x1b,
        );
        final segmentAudio = findAdtsAacStream(pmt);
        expect(
          segmentAudio,
          isNotNull,
          reason: 'AAC missing in ${segment.uri}',
        );

        videoPid ??= segmentVideo.pid;
        audioPid ??= segmentAudio!.pid;
        expect(segmentVideo.pid, videoPid);
        expect(segmentAudio!.pid, audioPid);
        videoPes ??= TsPesAssembler(videoPid);
        audioDemuxer ??= TsAacDemuxer(pid: audioPid);

        for (final pesBytes in videoPes.pushPackets(packets)) {
          _appendVideoChunk(videoChunks, pesBytes, (pts) {
            baseVideoPts90k ??= pts;
          });
        }
        audioUnits.addAll(audioDemuxer.pushPackets(packets));
      }

      final trailingVideoPes = videoPes!.flush();
      if (trailingVideoPes != null) {
        _appendVideoChunk(videoChunks, trailingVideoPes, (pts) {
          baseVideoPts90k ??= pts;
        });
      }
      audioUnits.addAll(audioDemuxer!.finish());

      expect(videoPes.continuityErrorCount, 0);
      expect(videoPes.scrambledPacketCount, 0);
      expect(audioDemuxer.continuityErrorCount, 0);
      expect(audioDemuxer.scrambledPacketCount, 0);
      expect(audioUnits, hasLength(353));

      final accessUnits = buildTimestampedAccessUnitsFromPtsChunks(
        ptsChunks: videoChunks,
        basePts90k: baseVideoPts90k,
      );
      expect(accessUnits, hasLength(226));
      expect(accessUnits.where((unit) => unit.hasIdr), hasLength(8));
      expect(accessUnits.first.ptsMs, 0);
      expect(accessUnits.last.ptsMs, closeTo(7507, 2));

      final decoder = H264BaselineDecoder();
      for (var index = 0; index < accessUnits.length; index++) {
        final frame = decoder.decodeAccessUnit(accessUnits[index].nals);
        expect(
          frame,
          isNotNull,
          reason: 'HLS picture $index failed: ${decoder.lastError}',
        );
        expect(frame!.width, 854);
        expect(frame.height, 480);
      }

      final audio = await decodeTransportAacToPcmInBackground(
        audioUnits,
        originPts90k: baseVideoPts90k!,
      );
      expect(audio.sampleRate, 48000);
      expect(audio.channels, 2);
      expect(audio.frameCount, 361472);
      expect(audio.durationUs, 7530666);
      expect(audio.samples.any((sample) => sample != 0), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

void _appendVideoChunk(
  List<PtsChunk> chunks,
  Uint8List pesBytes,
  void Function(int pts90k) recordFirstPts,
) {
  final parsed = parsePes(pesBytes);
  expect(parsed, isNotNull);
  final pts = parsed!.pts90k;
  if (pts != null) recordFirstPts(pts);
  chunks.add(PtsChunk(pts90k: pts, payload: parsed.esPayload));
}

Future<void> _serveFixture(HttpRequest request) async {
  final name = request.uri.pathSegments.isEmpty
      ? ''
      : request.uri.pathSegments.last;
  const allowed = <String>{
    'master.m3u8',
    'media.m3u8',
    'segment_000.ts',
    'segment_001.ts',
    'segment_002.ts',
    'segment_003.ts',
  };
  if (!allowed.contains(name)) {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
    return;
  }

  request.response.headers.contentType = name.endsWith('.m3u8')
      ? ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8')
      : ContentType('video', 'mp2t');
  await request.response.addStream(File('$_fixtureRoot/$name').openRead());
  await request.response.close();
}
