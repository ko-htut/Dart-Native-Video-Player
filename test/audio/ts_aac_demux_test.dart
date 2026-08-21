import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';
import 'package:ndvy_player/src/audio/aac/ts_aac_demux.dart';
import 'package:ndvy_player/src/mpeg_timestamp_epoch.dart';
import 'package:ndvy_player/src/pes_pts.dart';
import 'package:ndvy_player/src/ts_packets.dart';
import 'package:ndvy_player/src/ts_pes.dart';
import 'package:ndvy_player/src/ts_psi.dart';

import 'aac_test_utils.dart';

void main() {
  group('MPEG-TS packet/PES transport', () {
    test('packet parser exposes continuity and discontinuity metadata', () {
      final bytes = Uint8List(188)..fillRange(0, 188, 0xff);
      bytes[0] = 0x47;
      bytes[1] = 0x41; // payload start, PID high bits=1
      bytes[2] = 0x23;
      bytes[3] = 0x35; // adaptation + payload, continuity=5
      bytes[4] = 1;
      bytes[5] = 0x80; // discontinuity_indicator
      bytes[6] = 0x00;

      final packet = parseTsPackets(bytes).single;
      expect(packet.pid, 0x123);
      expect(packet.payloadUnitStart, isTrue);
      expect(packet.continuityCounter, 5);
      expect(packet.hasPayload, isTrue);
      expect(packet.discontinuityIndicator, isTrue);
      expect(packet.transportScramblingControl, 0);
      expect(packet.payload.first, 0x00);
    });

    test('PES parser bounds payload by declared packet length', () {
      final pes = makePes(Uint8List.fromList(<int>[1, 2, 3]), pts90k: 456);
      final withStuffing = Uint8List.fromList(<int>[...pes, 0xff, 0xff]);
      final parsed = parsePes(withStuffing)!;

      expect(parsed.streamId, 0xc0);
      expect(parsed.pts90k, 456);
      expect(parsed.esPayload, <int>[1, 2, 3]);
      expect(parsed.packetLength, pes.length - 6);
      expect(parsePes(pes.sublist(0, pes.length - 1)), isNull);
    });

    test('continuity-aware assembler ignores duplicate packets', () {
      const pid = 256;
      final pes = makePes(Uint8List.fromList(<int>[1, 2, 3, 4]));
      final first = _packet(pid, 0, true, pes.sublist(0, 10));
      final duplicate = _packet(pid, 0, true, pes.sublist(0, 10));
      final rest = _packet(pid, 1, false, pes.sublist(10));
      final assembler = TsPesAssembler(pid);

      expect(assembler.pushPackets(<TsPacket>[first]), isEmpty);
      expect(assembler.pushPackets(<TsPacket>[duplicate, rest]), isEmpty);
      expect(assembler.flush(), pes);
      expect(assembler.duplicatePacketCount, 1);
      expect(assembler.continuityErrorCount, 0);
    });

    test('accepts an HLS segment-local counter reset at a new PES', () {
      const pid = 257;
      final firstPes = makePes(Uint8List.fromList(<int>[1, 2, 3]));
      final secondPes = makePes(Uint8List.fromList(<int>[4, 5, 6]));
      final assembler = TsPesAssembler(pid)..beginSegment();

      expect(
        assembler.pushPackets(<TsPacket>[_packet(pid, 14, true, firstPes)]),
        isEmpty,
      );
      assembler.beginSegment();
      final completed = assembler.pushPackets(<TsPacket>[
        _packet(pid, 0, true, secondPes),
      ]);

      expect(completed, <Uint8List>[firstPes]);
      expect(assembler.flush(), secondPes);
      expect(assembler.continuityErrorCount, 0);
      expect(assembler.discontinuityCount, 0);
    });

    test('still rejects an HLS segment-local reset in the middle of PES', () {
      const pid = 258;
      final pes = makePes(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]));
      final assembler = TsPesAssembler(pid)..beginSegment();

      assembler.pushPackets(<TsPacket>[
        _packet(pid, 14, true, pes.sublist(0, 10)),
      ]);
      assembler.beginSegment();
      assembler.pushPackets(<TsPacket>[
        _packet(pid, 0, false, pes.sublist(10)),
      ]);

      expect(assembler.flush(), isNull);
      expect(assembler.continuityErrorCount, 1);
      expect(assembler.discontinuityCount, 1);
    });
  });

  group('TsAacDemuxer', () {
    test('discovers ADTS AAC and rejects LATM-only PMTs', () {
      final pmt = TsPmt(const <TsStreamInfo>[
        TsStreamInfo(pid: 100, streamType: 0x1b),
        TsStreamInfo(pid: 101, streamType: tsStreamTypeAdtsAac),
      ]);
      expect(findAdtsAacStream(pmt)?.pid, 101);
      expect(TsAacDemuxer.fromPmt(pmt).pid, 101);

      final latm = TsPmt(const <TsStreamInfo>[
        TsStreamInfo(pid: 102, streamType: tsStreamTypeLatmAac),
      ]);
      expect(() => TsAacDemuxer.fromPmt(latm), throwsUnsupportedError);
    });

    test('extracts ADTS split across TS packets and preserves PES PTS', () {
      const pid = 300;
      final adts = makeAdtsFrame(<int>[9, 8, 7]);
      final pes = makePes(adts, pts90k: 123456);
      final demuxer = TsAacDemuxer(pid: pid);

      final first = demuxer.pushPackets(<TsPacket>[
        _packet(pid, 0, true, pes.sublist(0, 12)),
      ]);
      final second = demuxer.pushPackets(<TsPacket>[
        _packet(pid, 1, false, pes.sublist(12)),
      ]);
      final finalUnits = demuxer.finish();

      expect(first, isEmpty);
      expect(second, isEmpty);
      expect(finalUnits, hasLength(1));
      expect(finalUnits.single.payload, <int>[9, 8, 7]);
      expect(finalUnits.single.pts90k, 123456);
      expect(finalUnits.single.config.samplingFrequency, 44100);
    });

    test('emits a PES when the following payload-unit start arrives', () {
      const pid = 301;
      final firstPes = makePes(makeAdtsFrame(<int>[1]), pts90k: 1000);
      final secondPes = makePes(makeAdtsFrame(<int>[2]), pts90k: 4000);
      final demuxer = TsAacDemuxer(pid: pid);

      final firstUnits = demuxer.pushPackets(<TsPacket>[
        _packet(pid, 0, true, firstPes),
        _packet(pid, 1, true, secondPes),
      ]);
      final finalUnits = demuxer.finish();

      expect(firstUnits.single.payload, <int>[1]);
      expect(firstUnits.single.pts90k, 1000);
      expect(finalUnits.single.payload, <int>[2]);
      expect(finalUnits.single.pts90k, 4000);
    });

    test('drops a partial PES after a continuity gap', () {
      const pid = 302;
      final damaged = makePes(makeAdtsFrame(<int>[1, 2, 3]));
      final valid = makePes(makeAdtsFrame(<int>[4, 5]), pts90k: 9000);
      final demuxer = TsAacDemuxer(pid: pid);

      expect(
        demuxer.pushPackets(<TsPacket>[
          _packet(pid, 0, true, damaged.sublist(0, 10)),
          _packet(pid, 2, false, damaged.sublist(10)),
          _packet(pid, 3, true, valid),
        ]),
        isEmpty,
      );
      final units = demuxer.finish();

      expect(units.single.payload, <int>[4, 5]);
      expect(units.single.pts90k, 9000);
      expect(demuxer.continuityErrorCount, 1);
    });

    test('malformed PES drops an ADTS carry before the next payload', () {
      const pid = 303;
      final splitFrame = makeAdtsFrame(<int>[1, 2, 3, 4]);
      final completeFrame = makeAdtsFrame(<int>[7, 8, 9]);
      final malformed = makePes(Uint8List.fromList(<int>[0xaa, 0xbb]));
      final continuationAndFrame = Uint8List.fromList(<int>[
        ...splitFrame.sublist(9),
        ...completeFrame,
      ]);
      final demuxer = TsAacDemuxer(pid: pid);

      final output = <AacAccessUnit>[
        ...demuxer.pushPackets(<TsPacket>[
          _packet(pid, 0, true, makePes(splitFrame.sublist(0, 9))),
          _packet(pid, 1, true, malformed.sublist(0, malformed.length - 1)),
          _packet(pid, 2, true, makePes(continuationAndFrame, pts90k: 9000)),
        ]),
        ...demuxer.finish(),
      ];

      expect(output, hasLength(1));
      expect(output.single.payload, <int>[7, 8, 9]);
      expect(output.single.pts90k, 9000);
      expect(demuxer.malformedPesCount, 1);
    });

    test('segment demuxer preserves AAC across a counter epoch reset', () {
      const pmtPid = 256;
      const audioPid = 304;
      Uint8List segment(int counter, int pts90k, List<int> payload) =>
          _joinTsPackets(<Uint8List>[
            _tsPacketBytes(0, 0, true, _patPayload(pmtPid)),
            _tsPacketBytes(pmtPid, 0, true, _aacPmtPayload(audioPid)),
            _tsPacketBytes(
              audioPid,
              counter,
              true,
              makePes(makeAdtsFrame(payload), pts90k: pts90k),
            ),
          ]);
      final demuxer = TsAacSegmentDemuxer();

      final output = <AacAccessUnit>[
        ...demuxer.pushSegment(segment(14, 90000, <int>[1, 2, 3])),
        ...demuxer.pushSegment(segment(0, 92089, <int>[4, 5, 6])),
        ...demuxer.finish(),
      ];

      expect(output, hasLength(2));
      expect(output.map((unit) => unit.payload), <List<int>>[
        <int>[1, 2, 3],
        <int>[4, 5, 6],
      ]);
      expect(output.map((unit) => unit.pts90k), <int>[90000, 92089]);
      expect(demuxer.continuityErrorCount, 0);
      expect(demuxer.discontinuityCount, 0);
    });

    test('shared video epoch rebases AAC reset and preserves A/V offset', () {
      const pid = 304;
      final videoTimeline = MpegTimestampEpochRebaser();
      videoTimeline.noteEmitted(videoTimeline.rebase(90000));
      videoTimeline.noteEmitted(videoTimeline.rebase(93600));

      final demuxer = TsAacDemuxer(pid: pid);
      final initial = demuxer.pushPackets(<TsPacket>[
        _packet(pid, 0, true, makePes(makeAdtsFrame(<int>[1]), pts90k: 90900)),
        _packet(pid, 1, true, makePes(makeAdtsFrame(<int>[2]), pts90k: 94500)),
        _packet(pid, 2, true, makePes(makeAdtsFrame(<int>[3]), pts90k: 98100)),
      ]);
      expect(initial.map((unit) => unit.pts90k), <int>[90900, 94500]);

      final epoch = videoTimeline.beginEpoch(
        discontinuitySequence: 5,
        elapsedDuration90k: 90000,
      );
      expect(videoTimeline.rebase(0), 180000);
      demuxer.beginDiscontinuity(epoch);
      final rebased = demuxer.pushPackets(<TsPacket>[
        _packet(pid, 0, true, makePes(makeAdtsFrame(<int>[4]), pts90k: 900)),
        _packet(pid, 1, true, makePes(makeAdtsFrame(<int>[5]), pts90k: 4500)),
        _packet(pid, 2, true, makePes(makeAdtsFrame(<int>[6]), pts90k: 8100)),
      ]);

      expect(rebased.map((unit) => unit.pts90k), <int>[180900, 184500]);
      expect(rebased.first.pts90k! - epoch.timelineStart90k, 900);
      expect(demuxer.currentTimestampEpoch?.sourceStart90k, 0);
      expect(demuxer.discontinuityCount, 1);
    });

    test('segment demuxer rediscovers PAT, PMT, and AAC PID across epoch', () {
      const pmtPid = 256;
      const firstPid = 304;
      const secondPid = 305;
      Uint8List segment(int pid, int firstPts, int secondPts) =>
          _joinTsPackets(<Uint8List>[
            _tsPacketBytes(0, 0, true, _patPayload(pmtPid)),
            _tsPacketBytes(pmtPid, 0, true, _aacPmtPayload(pid)),
            _tsPacketBytes(
              pid,
              0,
              true,
              makePes(makeAdtsFrame(<int>[1]), pts90k: firstPts),
            ),
            _tsPacketBytes(
              pid,
              1,
              true,
              makePes(makeAdtsFrame(<int>[2]), pts90k: secondPts),
            ),
          ]);

      final demuxer = TsAacSegmentDemuxer();
      final initial = demuxer.pushSegment(segment(firstPid, 90900, 94500));
      expect(initial.single.pts90k, 90900);
      expect(demuxer.pid, firstPid);

      final videoTimeline = MpegTimestampEpochRebaser();
      videoTimeline.noteEmitted(videoTimeline.rebase(90000));
      videoTimeline.noteEmitted(videoTimeline.rebase(93600));
      final epoch = videoTimeline.beginEpoch(
        discontinuitySequence: 6,
        elapsedDuration90k: 90000,
      );
      expect(videoTimeline.rebase(0), 180000);

      final rebased = demuxer.pushSegment(
        segment(secondPid, 900, 4500),
        discontinuityEpoch: epoch,
      );
      expect(rebased.single.pts90k, 180900);
      expect(demuxer.pid, secondPid);
      expect(demuxer.currentTimestampEpoch?.discontinuitySequence, 6);
      expect(demuxer.discontinuityCount, 1);
    });

    test('latest PMT reports ADTS removal after an active audio PID', () {
      const pmtPid = 256;
      const audioPid = 304;
      const videoPid = 305;
      final demuxer = TsAacSegmentDemuxer();

      demuxer.pushSegment(
        _joinTsPackets(<Uint8List>[
          _tsPacketBytes(0, 0, true, _patPayload(pmtPid)),
          _tsPacketBytes(pmtPid, 0, true, _aacPmtPayload(audioPid)),
          _tsPacketBytes(
            audioPid,
            0,
            true,
            makePes(makeAdtsFrame(<int>[1]), pts90k: 90000),
          ),
        ]),
      );
      expect(demuxer.pid, audioPid);
      expect(demuxer.definitivelyHasNoAdtsStream, isFalse);

      demuxer.pushSegment(
        _joinTsPackets(<Uint8List>[
          _tsPacketBytes(0, 1, true, _patPayload(pmtPid)),
          _tsPacketBytes(pmtPid, 1, true, _pmtPayload(videoPid, 0x1b)),
        ]),
      );

      expect(demuxer.latestPmtDeclaresNoAdtsStream, isTrue);
      expect(demuxer.definitivelyHasNoAdtsStream, isTrue);
    });

    test(
      'finite playlist retains complete AUs when its AAC tail is truncated',
      () {
        const pid = 303;
        final completePes = makePes(
          makeAdtsFrame(<int>[7, 8, 9]),
          pts90k: 12000,
        );
        final completeAdts = makeAdtsFrame(<int>[1, 2, 3, 4]);
        final truncatedPes = makePes(
          Uint8List.fromList(completeAdts.sublist(0, completeAdts.length - 2)),
          pts90k: 14089,
        );
        final demuxer = TsAacDemuxer(pid: pid);
        final retained = demuxer.pushPackets(<TsPacket>[
          _packet(pid, 0, true, completePes),
          _packet(pid, 1, true, truncatedPes),
        ]).toList();

        Object? tailError;
        try {
          retained.addAll(demuxer.finish());
        } catch (error) {
          // Mirrors the player: a selected finite HLS range may end mid-frame,
          // but its previously completed audio and video remain playable.
          tailError = error;
        }

        expect(tailError, isA<FormatException>());
        expect(retained, hasLength(1));
        expect(retained.single.payload, <int>[7, 8, 9]);
        expect(retained.single.pts90k, 12000);
      },
    );
  });
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

Uint8List _aacPmtPayload(int audioPid) =>
    _pmtPayload(audioPid, tsStreamTypeAdtsAac);

Uint8List _pmtPayload(int elementaryPid, int streamType) =>
    Uint8List.fromList(<int>[
      0,
      0x02,
      0xb0,
      18,
      0,
      1,
      0xc1,
      0,
      0,
      0xe0 | (elementaryPid >> 8),
      elementaryPid & 0xff,
      0xf0,
      0,
      streamType,
      0xe0 | (elementaryPid >> 8),
      elementaryPid & 0xff,
      0xf0,
      0,
      0,
      0,
      0,
      0,
    ]);

Uint8List _tsPacketBytes(
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

Uint8List _joinTsPackets(List<Uint8List> packets) {
  final output = Uint8List(packets.length * 188);
  for (var index = 0; index < packets.length; index++) {
    output.setRange(index * 188, (index + 1) * 188, packets[index]);
  }
  return output;
}

TsPacket _packet(
  int pid,
  int continuityCounter,
  bool payloadUnitStart,
  Uint8List payload,
) {
  return TsPacket(
    pid: pid,
    payloadUnitStart: payloadUnitStart,
    payload: payload,
    continuityCounter: continuityCounter,
    hasPayload: true,
  );
}
