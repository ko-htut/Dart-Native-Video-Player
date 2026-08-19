import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/ts_aac_demux.dart';
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
