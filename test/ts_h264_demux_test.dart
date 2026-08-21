import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/access_unit_pts.dart';
import 'package:ndvy_player/src/h264_nal.dart';
import 'package:ndvy_player/src/pes_pts.dart';
import 'package:ndvy_player/src/ts_h264_demux.dart';
import 'package:ndvy_player/src/ts_packets.dart';
import 'package:ndvy_player/src/ts_pes.dart';
import 'package:ndvy_player/src/ts_psi.dart';

import 'audio/aac_test_utils.dart';

const _fixtureRoot = 'test/fixtures/hls/butterfly';

void main() {
  test(
    'incremental Annex-B assembly survives byte-level start-code, NAL, and picture splits',
    () {
      final stream = _annexB(<Uint8List>[
        Uint8List.fromList(<int>[0x67, 0x42]),
        Uint8List.fromList(<int>[0x68, 0xce]),
        Uint8List.fromList(<int>[0x09, 0xf0]),
        _slice(5, 0),
        _slice(5, 1),
        Uint8List.fromList(<int>[0x09, 0xf0]),
        _slice(1, 0),
        Uint8List.fromList(<int>[0x09, 0xf0]),
        _slice(5, 0),
      ]);
      final expected = buildAccessUnitsFromAnnexB(stream);
      final builder = IncrementalAnnexBAccessUnitBuilder();
      final actual = <AccessUnit>[];

      for (final byte in stream) {
        actual.addAll(builder.push(Uint8List.fromList(<int>[byte])));
      }

      // The final P picture is not complete merely because the current push
      // ended. A finite-stream finish is the only operation allowed to emit it.
      expect(actual, hasLength(expected.length - 1));
      actual.addAll(builder.finish());
      expect(builder.finish(), isEmpty);
      _expectAccessUnitsEqual(actual, expected);
      expect(
        actual.last.nals.map(nalType),
        <int>[7, 8, 9, 5],
        reason: 'cached SPS/PPS must make a later IDR independently decodable',
      );
    },
  );

  test(
    'streaming TS demux matches the batch butterfly result across every segment',
    () {
      final segments = _readButterflySegments();
      final expected = _batchDemux(segments);
      final demuxer = TsH264Demuxer();
      final actual = <TimestampedAccessUnit>[];

      for (final segment in segments) {
        actual.addAll(demuxer.pushSegment(segment));
      }
      actual.addAll(demuxer.finish());

      _expectTimestampedAccessUnitsEqual(actual, expected);
      expect(actual, hasLength(226));
      expect(actual.where((accessUnit) => accessUnit.hasIdr), hasLength(8));
      expect(actual.first.ptsMs, 0);
      expect(actual.last.ptsMs, closeTo(7507, 2));
      expect(demuxer.basePts90k, expected.first.pts90k);
      expect(demuxer.diagnostics.continuityErrorCount, 0);
      expect(demuxer.diagnostics.scrambledPacketCount, 0);
      expect(demuxer.diagnostics.emittedAccessUnitCount, actual.length);
    },
  );

  test(
    'one-TS-packet pushes preserve PES, NAL, AU, PTS, and parameter-set state',
    () {
      final segments = _readButterflySegments();
      final expectedDemuxer = TsH264Demuxer();
      final expected = <TimestampedAccessUnit>[];
      for (final segment in segments) {
        expected.addAll(expectedDemuxer.pushSegment(segment));
      }
      expected.addAll(expectedDemuxer.finish());

      final packetizedDemuxer = TsH264Demuxer();
      final actual = <TimestampedAccessUnit>[];
      for (final segment in segments) {
        for (var offset = 0; offset < segment.length; offset += 188) {
          actual.addAll(
            packetizedDemuxer.pushSegment(
              Uint8List.sublistView(segment, offset, offset + 188),
            ),
          );
        }
      }
      actual.addAll(packetizedDemuxer.finish());

      _expectTimestampedAccessUnitsEqual(actual, expected);
      expect(packetizedDemuxer.diagnostics.continuityErrorCount, 0);
      expect(packetizedDemuxer.diagnostics.scrambledPacketCount, 0);
      expect(packetizedDemuxer.diagnostics.segmentCount, greaterThan(4));
    },
  );

  test('HLS segment counter epochs retain the prior video PES', () {
    const pmtPid = 256;
    const videoPid = 257;
    Uint8List picture(int type) => _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(type, 0),
    ]);
    final firstSegment = _joinPackets(<Uint8List>[
      _tsPacket(0, 0, true, _patPayload(pmtPid)),
      _tsPacket(pmtPid, 0, true, _pmtPayload(videoPid)),
      _tsPacket(
        videoPid,
        14,
        true,
        makePes(picture(5), pts90k: 90000, streamId: 0xe0),
      ),
    ]);
    final secondSegment = _joinPackets(<Uint8List>[
      _tsPacket(0, 0, true, _patPayload(pmtPid)),
      _tsPacket(pmtPid, 0, true, _pmtPayload(videoPid)),
      _tsPacket(
        videoPid,
        0,
        true,
        makePes(picture(1), pts90k: 93600, streamId: 0xe0),
      ),
    ]);

    final demuxer = TsH264Demuxer();
    final output = <TimestampedAccessUnit>[
      ...demuxer.pushSegment(firstSegment),
      ...demuxer.pushSegment(secondSegment),
      ...demuxer.finish(),
    ];

    expect(output, hasLength(2));
    expect(output.map((unit) => unit.pts90k), <int>[90000, 93600]);
    expect(output.map((unit) => unit.hasIdr), <bool>[true, false]);
    expect(demuxer.diagnostics.continuityErrorCount, 0);
    expect(demuxer.diagnostics.discontinuityCount, 0);
    expect(demuxer.diagnostics.discardedIncompletePictureCount, 0);
  });

  test('declared discontinuity discards a partial tail and waits for IDR', () {
    final segments = _readButterflySegments();
    final demuxer = TsH264Demuxer();

    final first = demuxer.pushSegment(segments.first);
    final afterDiscontinuity = demuxer.pushSegment(
      segments[1],
      discontinuity: true,
    );
    final tail = <TimestampedAccessUnit>[
      ...afterDiscontinuity,
      ...demuxer.pushSegment(segments[2]),
      ...demuxer.pushSegment(segments[3]),
      ...demuxer.finish(),
    ];

    expect(first, isNotEmpty);
    expect(tail, isNotEmpty);
    expect(tail.first.hasIdr, isTrue);
    expect(demuxer.diagnostics.discontinuityCount, 1);
  });

  test(
    'declared timestamp reset rebases continuously and drops pictures before IDR',
    () {
      const pmtPid = 256;
      const videoPid = 257;
      Uint8List picture(int type) => _annexB(<Uint8List>[
        Uint8List.fromList(<int>[0x09, 0xf0]),
        _slice(type, 0),
      ]);
      final firstEpoch = _joinPackets(<Uint8List>[
        _tsPacket(0, 0, true, _patPayload(pmtPid)),
        _tsPacket(pmtPid, 0, true, _pmtPayload(videoPid)),
        _tsPacket(
          videoPid,
          0,
          true,
          makePes(picture(5), pts90k: 90000, streamId: 0xe0),
        ),
        _tsPacket(
          videoPid,
          1,
          true,
          makePes(picture(1), pts90k: 93600, streamId: 0xe0),
        ),
        _tsPacket(
          videoPid,
          2,
          true,
          makePes(picture(1), pts90k: 97200, streamId: 0xe0),
        ),
      ]);
      final resetEpoch = _joinPackets(<Uint8List>[
        _tsPacket(0, 0, true, _patPayload(pmtPid)),
        _tsPacket(pmtPid, 0, true, _pmtPayload(videoPid)),
        _tsPacket(
          videoPid,
          0,
          true,
          makePes(picture(1), pts90k: 0, streamId: 0xe0),
        ),
        _tsPacket(
          videoPid,
          1,
          true,
          makePes(picture(5), pts90k: 3600, streamId: 0xe0),
        ),
        _tsPacket(
          videoPid,
          2,
          true,
          makePes(picture(1), pts90k: 7200, streamId: 0xe0),
        ),
        _tsPacket(
          videoPid,
          3,
          true,
          makePes(picture(1), pts90k: 10800, streamId: 0xe0),
        ),
      ]);

      final demuxer = TsH264Demuxer();
      final before = demuxer.pushSegment(firstEpoch);
      expect(before, isNotEmpty);
      expect(before.first.pts90k, 90000);

      final epoch = demuxer.beginDiscontinuity(
        discontinuitySequence: 3,
        elapsedDuration90k: 90000,
      );
      final after = <TimestampedAccessUnit>[
        ...demuxer.pushSegment(resetEpoch),
        ...demuxer.finish(),
      ];

      expect(after, isNotEmpty);
      expect(after.first.hasIdr, isTrue);
      expect(after.first.pts90k, 183600);
      expect(after.first.ptsMs, 1040);
      expect(epoch.sourceStart90k, 0);
      expect(epoch.timelineStart90k, 180000);
      expect(
        after.map((accessUnit) => accessUnit.pts90k),
        orderedEquals(
          after.map((accessUnit) => accessUnit.pts90k).toList()..sort(),
        ),
      );
      expect(
        demuxer.diagnostics.droppedDependentAccessUnitCount,
        greaterThan(0),
      );
      expect(demuxer.currentTimestampEpoch?.discontinuitySequence, 3);
    },
  );

  test('transport continuity gaps and scrambling are diagnosed', () {
    final segments = _readButterflySegments();
    final packets = parseTsPackets(segments.first).toList(growable: false);
    final pat = TsPat.find(packets)!;
    final pmt = TsPmt.find(packets, pat.programs.values.first)!;
    final videoPid = pmt.streams
        .singleWhere((stream) => stream.streamType == 0x1b)
        .pid;

    final continuityDamaged = Uint8List.fromList(segments.first);
    final continuityOffset = _videoPacketOffset(
      continuityDamaged,
      videoPid,
      requirePayloadStart: false,
    );
    final oldCounter = continuityDamaged[continuityOffset + 3] & 0x0f;
    continuityDamaged[continuityOffset + 3] =
        (continuityDamaged[continuityOffset + 3] & 0xf0) |
        ((oldCounter + 2) & 0x0f);

    final continuityDemuxer = TsH264Demuxer();
    continuityDemuxer.pushSegment(continuityDamaged);
    for (final segment in segments.skip(1)) {
      continuityDemuxer.pushSegment(segment);
    }
    continuityDemuxer.finish();
    expect(continuityDemuxer.diagnostics.continuityErrorCount, greaterThan(0));

    final scrambled = Uint8List.fromList(segments.first);
    final scrambledOffset = _videoPacketOffset(
      scrambled,
      videoPid,
      requirePayloadStart: false,
    );
    scrambled[scrambledOffset + 3] |= 0x40;

    final scrambledDemuxer = TsH264Demuxer();
    scrambledDemuxer.pushSegment(scrambled);
    for (final segment in segments.skip(1)) {
      scrambledDemuxer.pushSegment(segment);
    }
    scrambledDemuxer.finish();
    expect(scrambledDemuxer.diagnostics.scrambledPacketCount, 1);
    expect(scrambledDemuxer.diagnostics.discontinuityCount, greaterThan(0));
  });

  test('streaming timestamp normalization unwraps the 33-bit PTS rollover', () {
    const modulus = 1 << 33;
    const pmtPid = 256;
    const videoPid = 257;
    final firstPayload = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(5, 0),
    ]);
    final secondPayload = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1, 0),
    ]);
    final firstSegment = _joinPackets(<Uint8List>[
      _tsPacket(0, 0, true, _patPayload(pmtPid)),
      _tsPacket(pmtPid, 0, true, _pmtPayload(videoPid)),
      _tsPacket(
        videoPid,
        0,
        true,
        makePes(firstPayload, pts90k: modulus - 1800, streamId: 0xe0),
      ),
    ]);
    final secondSegment = _joinPackets(<Uint8List>[
      _tsPacket(
        videoPid,
        1,
        true,
        makePes(secondPayload, pts90k: 1800, streamId: 0xe0),
      ),
    ]);
    final demuxer = TsH264Demuxer();
    final output = <TimestampedAccessUnit>[
      ...demuxer.pushSegment(firstSegment),
      ...demuxer.pushSegment(secondSegment),
      ...demuxer.finish(),
    ];

    expect(output, hasLength(2));
    expect(output.map((accessUnit) => accessUnit.ptsMs), <int>[0, 40]);
    expect(output.first.pts90k, modulus - 1800);
    expect(output.last.pts90k, modulus + 1800);
  });
}

List<Uint8List> _readButterflySegments() => <Uint8List>[
  for (var index = 0; index < 4; index++)
    File(
      '$_fixtureRoot/segment_${index.toString().padLeft(3, '0')}.ts',
    ).readAsBytesSync(),
];

List<TimestampedAccessUnit> _batchDemux(List<Uint8List> segments) {
  TsPesAssembler? assembler;
  int? videoPid;
  int? basePts90k;
  final chunks = <PtsChunk>[];

  for (final segment in segments) {
    final packets = parseTsPackets(segment).toList(growable: false);
    final pat = TsPat.find(packets)!;
    final pmt = TsPmt.find(packets, pat.programs.values.first)!;
    final discoveredPid = pmt.streams
        .singleWhere((stream) => stream.streamType == 0x1b)
        .pid;
    videoPid ??= discoveredPid;
    expect(discoveredPid, videoPid);
    assembler ??= TsPesAssembler(discoveredPid);
    for (final pes in assembler.pushPackets(packets)) {
      _appendBatchChunk(chunks, pes, (pts) => basePts90k ??= pts);
    }
  }
  final tail = assembler!.flush();
  if (tail != null) {
    _appendBatchChunk(chunks, tail, (pts) => basePts90k ??= pts);
  }
  final output = buildTimestampedAccessUnitsFromPtsChunks(
    ptsChunks: chunks,
    basePts90k: basePts90k,
  );
  final firstIdr = output.indexWhere((accessUnit) => accessUnit.hasIdr);
  return output.sublist(firstIdr);
}

void _appendBatchChunk(
  List<PtsChunk> chunks,
  Uint8List pes,
  void Function(int value) recordFirstPts,
) {
  final parsed = parsePes(pes)!;
  final pts = parsed.pts90k;
  if (pts != null) recordFirstPts(pts);
  chunks.add(PtsChunk(pts90k: pts, payload: parsed.esPayload));
}

Uint8List _slice(int type, int firstMb) {
  final firstMbBits = switch (firstMb) {
    0 => 0x80,
    1 => 0x40,
    _ => throw ArgumentError.value(firstMb, 'firstMb'),
  };
  return Uint8List.fromList(<int>[0x60 | type, firstMbBits]);
}

Uint8List _annexB(List<Uint8List> nals) {
  final bytes = <int>[];
  for (final nal in nals) {
    bytes.addAll(const <int>[0, 0, 0, 1]);
    bytes.addAll(nal);
  }
  return Uint8List.fromList(bytes);
}

int _videoPacketOffset(
  Uint8List bytes,
  int videoPid, {
  required bool requirePayloadStart,
}) {
  for (var offset = 0; offset + 188 <= bytes.length; offset += 188) {
    final pid = ((bytes[offset + 1] & 0x1f) << 8) | bytes[offset + 2];
    final payloadStart = (bytes[offset + 1] & 0x40) != 0;
    if (pid == videoPid && payloadStart == requirePayloadStart) return offset;
  }
  throw StateError('No matching video TS packet found');
}

Uint8List _patPayload(int pmtPid) => Uint8List.fromList(<int>[
  0,
  0x00,
  0xb0,
  13,
  0,
  1,
  0xc1,
  0,
  0,
  0,
  1,
  0xe0 | (pmtPid >> 8),
  pmtPid & 0xff,
  0,
  0,
  0,
  0,
]);

Uint8List _pmtPayload(int videoPid) => Uint8List.fromList(<int>[
  0,
  0x02,
  0xb0,
  18,
  0,
  1,
  0xc1,
  0,
  0,
  0xe0 | (videoPid >> 8),
  videoPid & 0xff,
  0xf0,
  0,
  0x1b,
  0xe0 | (videoPid >> 8),
  videoPid & 0xff,
  0xf0,
  0,
  0,
  0,
  0,
  0,
]);

Uint8List _tsPacket(
  int pid,
  int continuityCounter,
  bool payloadUnitStart,
  Uint8List payload,
) {
  if (payload.length > 184) {
    throw ArgumentError.value(payload.length, 'payload.length');
  }
  final packet = Uint8List(188)..fillRange(0, 188, 0xff);
  packet[0] = 0x47;
  packet[1] = (payloadUnitStart ? 0x40 : 0) | ((pid >> 8) & 0x1f);
  packet[2] = pid & 0xff;
  packet[3] = 0x10 | (continuityCounter & 0x0f);
  packet.setRange(4, 4 + payload.length, payload);
  return packet;
}

Uint8List _joinPackets(List<Uint8List> packets) {
  final output = Uint8List(packets.length * 188);
  for (var index = 0; index < packets.length; index++) {
    output.setRange(index * 188, (index + 1) * 188, packets[index]);
  }
  return output;
}

void _expectAccessUnitsEqual(
  List<AccessUnit> actual,
  List<AccessUnit> expected,
) {
  expect(actual, hasLength(expected.length));
  for (var index = 0; index < expected.length; index++) {
    expect(actual[index].isIdr, expected[index].isIdr);
    expect(actual[index].sourceStartOffset, expected[index].sourceStartOffset);
    expect(actual[index].firstVclOffset, expected[index].firstVclOffset);
    expect(actual[index].sourceEndOffset, expected[index].sourceEndOffset);
    expect(actual[index].nals, hasLength(expected[index].nals.length));
    for (var nal = 0; nal < expected[index].nals.length; nal++) {
      expect(actual[index].nals[nal], orderedEquals(expected[index].nals[nal]));
    }
  }
}

void _expectTimestampedAccessUnitsEqual(
  List<TimestampedAccessUnit> actual,
  List<TimestampedAccessUnit> expected,
) {
  expect(actual, hasLength(expected.length));
  for (var index = 0; index < expected.length; index++) {
    expect(actual[index].ptsMs, expected[index].ptsMs, reason: 'AU $index PTS');
    expect(
      actual[index].pts90k,
      expected[index].pts90k,
      reason: 'AU $index MPEG PTS',
    );
    expect(
      actual[index].hasIdr,
      expected[index].hasIdr,
      reason: 'AU $index IDR',
    );
    expect(actual[index].nals, hasLength(expected[index].nals.length));
    for (var nal = 0; nal < expected[index].nals.length; nal++) {
      expect(
        actual[index].nals[nal],
        orderedEquals(expected[index].nals[nal]),
        reason: 'AU $index NAL $nal',
      );
    }
  }
}
