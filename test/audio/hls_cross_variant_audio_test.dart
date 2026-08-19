import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';
import 'package:ndvy_player/src/audio/aac/ts_aac_demux.dart';
import 'package:ndvy_player/src/audio/audio_decode_pipeline.dart';
import 'package:ndvy_player/src/pes_pts.dart';
import 'package:ndvy_player/src/ts_packets.dart';
import 'package:ndvy_player/src/ts_pes.dart';
import 'package:ndvy_player/src/ts_psi.dart';

void main() {
  test('AAC-LC sibling rendition aligns with HE-AAC rendition video', () {
    final lowPackets = parseTsPackets(
      File(
        'test/fixtures/hls/mux_x36xhzz/low_320x184_segment_000.ts',
      ).readAsBytesSync(),
    ).toList();
    final lowPmt = _readPmt(lowPackets);
    final videoPid = lowPmt.streams
        .singleWhere((stream) => stream.streamType == 0x1b)
        .pid;
    final videoOriginPts = assemblePesPackets(lowPackets, videoPid)
        .map(parsePes)
        .whereType<PesParsed>()
        .map((pes) => pes.pts90k)
        .whereType<int>()
        .first;

    final hqPackets = parseTsPackets(
      File(
        'test/fixtures/hls/mux_x36xhzz/hq_848x480_segment_000.ts',
      ).readAsBytesSync(),
    ).toList();
    final demuxer = TsAacDemuxer.fromPmt(_readPmt(hqPackets));
    final accessUnits = <AacAccessUnit>[
      ...demuxer.pushPackets(hqPackets),
      ...demuxer.finish(),
    ];

    expect(videoOriginPts, 900000);
    expect(accessUnits, hasLength(431));
    expect(accessUnits.first.config.audioObjectType, 2);
    expect(accessUnits.first.config.samplingFrequency, 44100);
    expect(accessUnits.first.config.channelConfiguration, 2);
    expect(accessUnits.first.pts90k, 900909);
    expect(accessUnits.last.pts90k, 1799521);
    expect(accessUnits.first.pts90k! - videoOriginPts, 909);

    final timeline = decodeTransportAacToPcm(
      accessUnits,
      originPts90k: videoOriginPts,
    );
    const leadingFrames = 445; // round(909 * 44,100 / 90,000)
    expect(timeline.sampleRate, 44100);
    expect(timeline.channels, 2);
    expect(timeline.basePtsUs, 0);
    expect(timeline.frameCount, leadingFrames + 431 * 1024);
    expect(timeline.durationUs, 10017891);
    expect(
      timeline.samples.take(leadingFrames * timeline.channels),
      everyElement(0),
    );
    expect(timeline.samples.any((sample) => sample != 0), isTrue);

    // FFmpeg 7.1.1 independently decoded all ADTS packets and removed the
    // encoder's first 1,024 priming frames. Compare every 251st interleaved
    // S16 sample over the remaining complete 430-frame sequence.
    final goldenBytes = base64Decode(
      File(
        'test/audio/goldens/'
        'mux_x36xhzz_hq_segment_000_s16_stride251.base64',
      ).readAsStringSync().replaceAll(RegExp(r'\s'), ''),
    );
    final golden = ByteData.sublistView(goldenBytes);
    const primingFrames = 1024;
    const referenceSampleCount = 430 * 1024 * 2;
    const stride = 251;
    const goldenSampleCount = 3509;
    final alignedFirstSample =
        (leadingFrames + primingFrames) * timeline.channels;
    expect(goldenBytes, hasLength(goldenSampleCount * 2));
    expect(timeline.samples.length - alignedFirstSample, referenceSampleCount);

    var goldenIndex = 0;
    var maximumDelta = 0;
    var sumDelta = 0;
    for (var sample = 0; sample < referenceSampleCount; sample += stride) {
      final actual = timeline.samples[alignedFirstSample + sample];
      final expected = golden.getInt16(goldenIndex * 2, Endian.little);
      final delta = (actual - expected).abs();
      maximumDelta = math.max(maximumDelta, delta);
      sumDelta += delta;
      goldenIndex++;
    }
    expect(goldenIndex, goldenSampleCount);
    expect(maximumDelta, lessThanOrEqualTo(160));
    expect(sumDelta / goldenSampleCount, lessThan(10));
  });
}

TsPmt _readPmt(List<TsPacket> packets) {
  final pat = TsPat.find(packets)!;
  return TsPmt.find(packets, pat.programs.values.single)!;
}
