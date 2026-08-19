import 'dart:typed_data';

import '../../pes_pts.dart';
import '../../ts_packets.dart';
import '../../ts_pes.dart';
import '../../ts_psi.dart';
import 'adts.dart';

const int tsStreamTypeAdtsAac = 0x0f;
const int tsStreamTypeLatmAac = 0x11;

TsStreamInfo? findAdtsAacStream(TsPmt pmt) {
  for (final stream in pmt.streams) {
    if (stream.streamType == tsStreamTypeAdtsAac) return stream;
  }
  return null;
}

/// Stateful MPEG-TS/PES/ADTS extractor for one AAC PID.
///
/// This class only removes transport/container framing. Returned payloads are
/// compressed raw AAC access units ready for the pure-Dart AAC decoder.
final class TsAacDemuxer {
  TsAacDemuxer({required this.pid}) : _pes = TsPesAssembler(pid);

  factory TsAacDemuxer.fromPmt(TsPmt pmt) {
    final stream = findAdtsAacStream(pmt);
    if (stream != null) return TsAacDemuxer(pid: stream.pid);
    final hasLatm = pmt.streams.any(
      (candidate) => candidate.streamType == tsStreamTypeLatmAac,
    );
    if (hasLatm) {
      throw UnsupportedError(
        'MPEG-TS AAC LATM/LOAS (stream_type 0x11) is not supported; '
        'use ADTS AAC stream_type 0x0f',
      );
    }
    throw StateError('MPEG-TS PMT has no ADTS AAC stream_type 0x0f');
  }

  final int pid;
  final TsPesAssembler _pes;
  final AdtsStreamParser _adts = AdtsStreamParser();
  int malformedPesCount = 0;

  int get continuityErrorCount => _pes.continuityErrorCount;
  int get duplicatePacketCount => _pes.duplicatePacketCount;
  int get scrambledPacketCount => _pes.scrambledPacketCount;

  List<AacAccessUnit> pushPackets(Iterable<TsPacket> packets) {
    final output = <AacAccessUnit>[];
    for (final packet in packets) {
      final generation = _pes.discontinuityCount;
      final completed = _pes.pushPackets(<TsPacket>[packet]);
      if (_pes.discontinuityCount != generation) _adts.reset();
      for (final pesBytes in completed) {
        _appendPes(output, pesBytes);
      }
    }
    return List<AacAccessUnit>.unmodifiable(output);
  }

  /// Completes the final pending PES at end of a file or VOD playlist.
  List<AacAccessUnit> finish() {
    final output = <AacAccessUnit>[];
    final finalPes = _pes.flush();
    if (finalPes != null) _appendPes(output, finalPes);
    _adts.finish();
    return List<AacAccessUnit>.unmodifiable(output);
  }

  void reset() {
    _pes.reset();
    _adts.reset();
    malformedPesCount = 0;
  }

  void _appendPes(List<AacAccessUnit> output, Uint8List bytes) {
    final parsed = parsePes(bytes);
    if (parsed == null) {
      malformedPesCount++;
      return;
    }
    output.addAll(_adts.push(parsed.esPayload, pts90k: parsed.pts90k));
  }
}
