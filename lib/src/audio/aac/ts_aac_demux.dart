import 'dart:typed_data';

import '../../pes_pts.dart';
import '../../mpeg_timestamp_epoch.dart';
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
  int _archivedContinuityErrorCount = 0;
  int _archivedDuplicatePacketCount = 0;
  int _archivedScrambledPacketCount = 0;
  int _archivedTransportDiscontinuityCount = 0;
  int _declaredDiscontinuityCount = 0;
  int malformedPesCount = 0;

  int get continuityErrorCount =>
      _archivedContinuityErrorCount + _pes.continuityErrorCount;
  int get duplicatePacketCount =>
      _archivedDuplicatePacketCount + _pes.duplicatePacketCount;
  int get scrambledPacketCount =>
      _archivedScrambledPacketCount + _pes.scrambledPacketCount;
  int get discontinuityCount =>
      _declaredDiscontinuityCount +
      _archivedTransportDiscontinuityCount +
      _pes.discontinuityCount;
  int get transportDiscontinuityCount =>
      _archivedTransportDiscontinuityCount + _pes.discontinuityCount;
  MpegTimestampEpochSnapshot? get currentTimestampEpoch =>
      _adts.currentTimestampEpoch;

  /// Marks the next matching payload packet as an HLS segment boundary.
  void beginSegment() => _pes.beginSegment();

  /// Starts a declared HLS timestamp epoch and drops partial PES/ADTS bytes.
  ///
  /// The supplied mapping should normally be the epoch established by video.
  void beginDiscontinuity(MpegTimestampEpoch epoch) {
    _archivePesDiagnostics();
    _pes.reset();
    _adts.beginTimestampEpoch(epoch);
    _declaredDiscontinuityCount++;
  }

  List<AacAccessUnit> pushPackets(Iterable<TsPacket> packets) {
    final output = <AacAccessUnit>[];
    for (final packet in packets) {
      final generation = _pes.discontinuityCount;
      final completed = _pes.pushPackets(<TsPacket>[packet]);
      if (_pes.discontinuityCount != generation) {
        _adts.discardIncompleteTail();
      }
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
    _archivedContinuityErrorCount = 0;
    _archivedDuplicatePacketCount = 0;
    _archivedScrambledPacketCount = 0;
    _archivedTransportDiscontinuityCount = 0;
    _declaredDiscontinuityCount = 0;
    malformedPesCount = 0;
  }

  void _archivePesDiagnostics() {
    _archivedContinuityErrorCount += _pes.continuityErrorCount;
    _archivedDuplicatePacketCount += _pes.duplicatePacketCount;
    _archivedScrambledPacketCount += _pes.scrambledPacketCount;
    _archivedTransportDiscontinuityCount += _pes.discontinuityCount;
  }

  void _appendPes(List<AacAccessUnit> output, Uint8List bytes) {
    final parsed = parsePes(bytes);
    if (parsed == null) {
      malformedPesCount++;
      // A malformed PES may be the missing middle of an ADTS frame whose
      // prefix was buffered from an earlier PES. Do not join that stale prefix
      // to bytes from the next valid PES.
      _adts.discardIncompleteTail();
      return;
    }
    output.addAll(_adts.push(parsed.esPayload, pts90k: parsed.pts90k));
  }
}

/// Stateful complete-segment MPEG-TS AAC demuxer with PAT/PMT/PID discovery.
///
/// PID changes are accepted only through [beginDiscontinuity], which drops all
/// partial transport/ADTS state. The same video-created [MpegTimestampEpoch]
/// then keeps AAC on the continuous video timeline while retaining its raw PTS
/// offset. This class is reusable by VOD and live HLS coordinators.
final class TsAacSegmentDemuxer {
  int? _pmtPid;
  TsAacDemuxer? _demuxer;
  MpegTimestampEpoch? _pendingEpoch;
  MpegTimestampEpoch? _currentEpoch;
  bool _finished = false;
  bool _inspectedPmt = false;
  bool _pmtDeclaredNoAdtsStream = false;
  int _archivedContinuityErrorCount = 0;
  int _archivedDuplicatePacketCount = 0;
  int _archivedScrambledPacketCount = 0;
  int _archivedTransportDiscontinuityCount = 0;
  int _declaredDiscontinuityCount = 0;

  int? get pmtPid => _pmtPid;
  int? get pid => _demuxer?.pid;
  bool get hasInspectedPmt => _inspectedPmt;
  bool get latestPmtDeclaresNoAdtsStream =>
      hasInspectedPmt && _pmtDeclaredNoAdtsStream;
  bool get definitivelyHasNoAdtsStream => latestPmtDeclaresNoAdtsStream;
  int get continuityErrorCount =>
      _archivedContinuityErrorCount + (_demuxer?.continuityErrorCount ?? 0);
  int get duplicatePacketCount =>
      _archivedDuplicatePacketCount + (_demuxer?.duplicatePacketCount ?? 0);
  int get scrambledPacketCount =>
      _archivedScrambledPacketCount + (_demuxer?.scrambledPacketCount ?? 0);
  int get discontinuityCount =>
      _declaredDiscontinuityCount +
      _archivedTransportDiscontinuityCount +
      (_demuxer?.transportDiscontinuityCount ?? 0);
  MpegTimestampEpochSnapshot? get currentTimestampEpoch =>
      _demuxer?.currentTimestampEpoch ?? _pendingEpoch?.snapshot;

  /// Drops the old program/PID and partial compressed state at an HLS boundary.
  void beginDiscontinuity(MpegTimestampEpoch epoch) {
    if (_finished) {
      throw StateError('Cannot begin an AAC timestamp epoch after finish()');
    }
    _archiveDemuxerDiagnostics();
    _demuxer = null;
    _pmtPid = null;
    _pendingEpoch = epoch;
    _currentEpoch = epoch;
    _inspectedPmt = false;
    _pmtDeclaredNoAdtsStream = false;
    _declaredDiscontinuityCount++;
  }

  List<AacAccessUnit> pushSegment(
    Uint8List bytes, {
    MpegTimestampEpoch? discontinuityEpoch,
  }) {
    if (_finished) {
      throw StateError('Cannot push an AAC segment after finish()');
    }
    if (discontinuityEpoch != null &&
        !identical(_currentEpoch, discontinuityEpoch)) {
      beginDiscontinuity(discontinuityEpoch);
    }

    final packets = parseTsPackets(bytes).toList(growable: false);
    final pat = TsPat.find(packets);
    if (pat != null && pat.programs.isNotEmpty) {
      final discovered = pat.programs.values.first;
      if (_pmtPid != null && _pmtPid != discovered) {
        throw FormatException(
          'AAC PMT PID changed without a declared discontinuity: '
          '$_pmtPid -> $discovered',
        );
      }
      _pmtPid = discovered;
    }

    final pmtPid = _pmtPid;
    if (pmtPid != null) {
      final pmt = TsPmt.find(packets, pmtPid);
      if (pmt != null) {
        _inspectedPmt = true;
        final stream = findAdtsAacStream(pmt);
        if (stream == null) {
          // This reflects the latest complete PMT even when an older ADTS PID
          // was already active. Callers must not silently keep waiting on a
          // stream that the current program map has removed.
          _pmtDeclaredNoAdtsStream = true;
        } else {
          _pmtDeclaredNoAdtsStream = false;
          final current = _demuxer;
          if (current != null && current.pid != stream.pid) {
            throw FormatException(
              'AAC elementary PID changed without a declared discontinuity: '
              '${current.pid} -> ${stream.pid}',
            );
          }
          if (current == null) {
            final created = TsAacDemuxer(pid: stream.pid);
            final epoch = _pendingEpoch;
            if (epoch != null) created.beginDiscontinuity(epoch);
            _demuxer = created;
            _pendingEpoch = null;
          }
        }
      }
    }

    final demuxer = _demuxer;
    if (demuxer == null) return const <AacAccessUnit>[];
    demuxer.beginSegment();
    return demuxer.pushPackets(packets);
  }

  List<AacAccessUnit> finish() {
    if (_finished) return const <AacAccessUnit>[];
    _finished = true;
    return _demuxer?.finish() ?? const <AacAccessUnit>[];
  }

  void _archiveDemuxerDiagnostics() {
    final demuxer = _demuxer;
    if (demuxer == null) return;
    _archivedContinuityErrorCount += demuxer.continuityErrorCount;
    _archivedDuplicatePacketCount += demuxer.duplicatePacketCount;
    _archivedScrambledPacketCount += demuxer.scrambledPacketCount;
    _archivedTransportDiscontinuityCount += demuxer.transportDiscontinuityCount;
  }
}
