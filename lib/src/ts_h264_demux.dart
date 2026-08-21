import 'dart:collection';
import 'dart:typed_data';

import 'access_unit_pts.dart';
import 'h264_nal.dart';
import 'mpeg_timestamp_epoch.dart';
import 'pes_pts.dart';
import 'ts_packets.dart';
import 'ts_pes.dart';
import 'ts_psi.dart';

/// Immutable diagnostics for a [TsH264Demuxer] session.
final class TsH264DemuxDiagnostics {
  const TsH264DemuxDiagnostics({
    required this.segmentCount,
    required this.transportPacketCount,
    required this.rejectedTransportPacketCount,
    required this.trailingTransportByteCount,
    required this.segmentWithoutPatCount,
    required this.segmentWithoutPmtCount,
    required this.videoPidChangeCount,
    required this.malformedPesCount,
    required this.continuityErrorCount,
    required this.duplicatePacketCount,
    required this.scrambledPacketCount,
    required this.discontinuityCount,
    required this.discardedIncompletePictureCount,
    required this.droppedDependentAccessUnitCount,
    required this.emittedAccessUnitCount,
    required this.timestampEpochCount,
    required this.currentTimestampEpoch,
  });

  final int segmentCount;
  final int transportPacketCount;
  final int rejectedTransportPacketCount;
  final int trailingTransportByteCount;
  final int segmentWithoutPatCount;
  final int segmentWithoutPmtCount;
  final int videoPidChangeCount;
  final int malformedPesCount;
  final int continuityErrorCount;
  final int duplicatePacketCount;
  final int scrambledPacketCount;
  final int discontinuityCount;
  final int discardedIncompletePictureCount;
  final int droppedDependentAccessUnitCount;
  final int emittedAccessUnitCount;
  final int timestampEpochCount;
  final MpegTimestampEpochSnapshot? currentTimestampEpoch;
}

/// Stateful MPEG-TS/PES/Annex-B H.264 demuxer for ordered HLS media segments.
///
/// PAT, PMT, PID, continuity, PES, NAL, access-unit, parameter-set, and MPEG
/// timestamp state all survive [pushSegment] calls. Only access units whose
/// following boundary has been proven are returned. [finish] is the sole API
/// that treats the current byte tail as the end of a finite VOD stream.
final class TsH264Demuxer {
  TsH264Demuxer({int? basePts90k})
    : _timestamped = _TimestampedH264Assembler(basePts90k: basePts90k);

  static const int _transportPacketSize = 188;
  static const int _h264StreamType = 0x1b;

  final _TimestampedH264Assembler _timestamped;
  TsPesAssembler? _videoPes;
  int? _pmtPid;
  int? _videoPid;
  bool _waitingForRandomAccess = true;
  bool _finished = false;

  int _segmentCount = 0;
  int _transportPacketCount = 0;
  int _rejectedTransportPacketCount = 0;
  int _trailingTransportByteCount = 0;
  int _segmentWithoutPatCount = 0;
  int _segmentWithoutPmtCount = 0;
  int _videoPidChangeCount = 0;
  int _malformedPesCount = 0;
  int _archivedContinuityErrorCount = 0;
  int _archivedDuplicatePacketCount = 0;
  int _archivedScrambledPacketCount = 0;
  int _archivedDiscontinuityCount = 0;
  int _declaredDiscontinuityCount = 0;
  int _discardedIncompletePictureCount = 0;
  int _droppedDependentAccessUnitCount = 0;
  int _emittedAccessUnitCount = 0;

  int? get pmtPid => _pmtPid;
  int? get videoPid => _videoPid;
  int? get basePts90k => _timestamped.basePts90k;
  bool get isFinished => _finished;

  TsH264DemuxDiagnostics get diagnostics {
    final pes = _videoPes;
    return TsH264DemuxDiagnostics(
      segmentCount: _segmentCount,
      transportPacketCount: _transportPacketCount,
      rejectedTransportPacketCount: _rejectedTransportPacketCount,
      trailingTransportByteCount: _trailingTransportByteCount,
      segmentWithoutPatCount: _segmentWithoutPatCount,
      segmentWithoutPmtCount: _segmentWithoutPmtCount,
      videoPidChangeCount: _videoPidChangeCount,
      malformedPesCount: _malformedPesCount,
      continuityErrorCount:
          _archivedContinuityErrorCount + (pes?.continuityErrorCount ?? 0),
      duplicatePacketCount:
          _archivedDuplicatePacketCount + (pes?.duplicatePacketCount ?? 0),
      scrambledPacketCount:
          _archivedScrambledPacketCount + (pes?.scrambledPacketCount ?? 0),
      discontinuityCount:
          _archivedDiscontinuityCount +
          (pes?.discontinuityCount ?? 0) +
          _declaredDiscontinuityCount,
      discardedIncompletePictureCount: _discardedIncompletePictureCount,
      droppedDependentAccessUnitCount: _droppedDependentAccessUnitCount,
      emittedAccessUnitCount: _emittedAccessUnitCount,
      timestampEpochCount: _timestamped.timestampEpochCount,
      currentTimestampEpoch: _timestamped.currentTimestampEpoch,
    );
  }

  /// Pushes one complete ordered HLS MPEG-TS segment.
  ///
  /// [discontinuity] corresponds to an HLS `EXT-X-DISCONTINUITY` boundary. It
  /// discards partial transport and picture state before ingesting [bytes] and
  /// suppresses dependent pictures until a new IDR is found.
  List<TimestampedAccessUnit> pushSegment(
    Uint8List bytes, {
    bool discontinuity = false,
    MpegTimestampEpoch? discontinuityEpoch,
  }) {
    if (_finished) {
      throw StateError('Cannot push an MPEG-TS segment after finish()');
    }
    if (discontinuity && discontinuityEpoch != null) {
      throw ArgumentError(
        'discontinuity and discontinuityEpoch are mutually exclusive',
      );
    }
    if (discontinuityEpoch != null &&
        !identical(_timestamped.currentEpoch, discontinuityEpoch)) {
      _applyDeclaredDiscontinuity(
        discontinuitySequence: discontinuityEpoch.discontinuitySequence,
        sharedEpoch: discontinuityEpoch,
      );
    } else if (discontinuity) {
      final currentSequence =
          _timestamped.currentTimestampEpoch?.discontinuitySequence ?? 0;
      _applyDeclaredDiscontinuity(discontinuitySequence: currentSequence + 1);
    }

    _segmentCount++;
    _trailingTransportByteCount += bytes.length % _transportPacketSize;
    final candidatePacketCount = bytes.length ~/ _transportPacketSize;
    final packets = parseTsPackets(bytes).toList(growable: false);
    _transportPacketCount += packets.length;
    _rejectedTransportPacketCount += candidatePacketCount - packets.length;

    _discoverProgram(packets);
    final pes = _videoPes;
    if (pes == null) return const <TimestampedAccessUnit>[];
    pes.beginSegment();

    final output = <TimestampedAccessUnit>[];
    for (final packet in packets) {
      final discontinuitiesBefore = pes.discontinuityCount;
      final completed = pes.pushPackets(<TsPacket>[packet]);
      if (pes.discontinuityCount != discontinuitiesBefore) {
        _discardDamagedElementaryTail();
      }
      for (final pesBytes in completed) {
        _appendPes(output, pesBytes);
      }
    }
    return List<TimestampedAccessUnit>.unmodifiable(output);
  }

  /// Resets transport, elementary-stream, parameter-set, and dependency state
  /// before a declared HLS discontinuity and starts a continuous PTS epoch.
  ///
  /// The video track normally creates the epoch from [elapsedDuration90k]. A
  /// sibling AAC track must consume the returned mapping so its raw offset from
  /// video is preserved. Passing [sharedEpoch] is intended for a secondary
  /// video view of an already coordinated source clock.
  MpegTimestampEpoch beginDiscontinuity({
    required int discontinuitySequence,
    int? elapsedDuration90k,
    MpegTimestampEpoch? sharedEpoch,
  }) {
    if (_finished) {
      throw StateError('Cannot begin an MPEG timestamp epoch after finish()');
    }
    return _applyDeclaredDiscontinuity(
      discontinuitySequence: discontinuitySequence,
      elapsedDuration90k: elapsedDuration90k,
      sharedEpoch: sharedEpoch,
    );
  }

  MpegTimestampEpochSnapshot? get currentTimestampEpoch =>
      _timestamped.currentTimestampEpoch;

  /// Flushes the final PES, NAL, picture, and timestamp tail of a finite VOD.
  /// Repeated calls return an empty list.
  List<TimestampedAccessUnit> finish() {
    if (_finished) return const <TimestampedAccessUnit>[];
    _finished = true;
    final output = <TimestampedAccessUnit>[];
    final trailingPes = _videoPes?.flush();
    if (trailingPes != null) _appendPes(output, trailingPes);
    _appendAccessUnits(output, _timestamped.finish());
    return List<TimestampedAccessUnit>.unmodifiable(output);
  }

  void _discoverProgram(List<TsPacket> packets) {
    final pat = TsPat.find(packets);
    if (pat == null || pat.programs.isEmpty) {
      _segmentWithoutPatCount++;
    } else {
      final discoveredPmtPid = pat.programs.values.first;
      if (_pmtPid != null && _pmtPid != discoveredPmtPid) {
        _replaceVideoPid(null);
      }
      _pmtPid = discoveredPmtPid;
    }

    final activePmtPid = _pmtPid;
    if (activePmtPid == null) {
      _segmentWithoutPmtCount++;
      return;
    }
    final pmt = TsPmt.find(packets, activePmtPid);
    if (pmt == null) {
      _segmentWithoutPmtCount++;
      return;
    }
    TsStreamInfo? h264;
    for (final stream in pmt.streams) {
      if (stream.streamType == _h264StreamType) {
        h264 = stream;
        break;
      }
    }
    if (h264 == null) {
      _segmentWithoutPmtCount++;
      return;
    }
    if (h264.pid != _videoPid) _replaceVideoPid(h264.pid);
  }

  void _replaceVideoPid(int? nextPid) {
    if (_videoPid == nextPid) return;
    if (_videoPid != null) {
      _videoPidChangeCount++;
      _archivePesDiagnostics();
      _discardDamagedElementaryTail(clearParameterSets: true);
    }
    _videoPid = nextPid;
    _videoPes = nextPid == null ? null : TsPesAssembler(nextPid);
    _waitingForRandomAccess = true;
  }

  MpegTimestampEpoch _applyDeclaredDiscontinuity({
    required int discontinuitySequence,
    int? elapsedDuration90k,
    MpegTimestampEpoch? sharedEpoch,
  }) {
    _declaredDiscontinuityCount++;
    _archivePesDiagnostics();
    // PAT/PMT and elementary PIDs may change at an HLS discontinuity. Require
    // the new epoch to discover its own program instead of accepting packets
    // under stale transport metadata.
    _pmtPid = null;
    _videoPid = null;
    _videoPes = null;
    _discardDamagedElementaryTail(clearParameterSets: true);
    return _timestamped.beginEpoch(
      discontinuitySequence: discontinuitySequence,
      elapsedDuration90k: elapsedDuration90k,
      sharedEpoch: sharedEpoch,
    );
  }

  void _archivePesDiagnostics() {
    final pes = _videoPes;
    if (pes == null) return;
    _archivedContinuityErrorCount += pes.continuityErrorCount;
    _archivedDuplicatePacketCount += pes.duplicatePacketCount;
    _archivedScrambledPacketCount += pes.scrambledPacketCount;
    _archivedDiscontinuityCount += pes.discontinuityCount;
  }

  void _discardDamagedElementaryTail({bool clearParameterSets = false}) {
    _discardedIncompletePictureCount += _timestamped.discardIncompleteTail(
      clearParameterSets: clearParameterSets,
    );
    _waitingForRandomAccess = true;
  }

  void _appendPes(List<TimestampedAccessUnit> output, Uint8List bytes) {
    final parsed = parsePes(bytes);
    if (parsed == null) {
      _malformedPesCount++;
      _discardDamagedElementaryTail();
      return;
    }
    _appendAccessUnits(
      output,
      _timestamped.pushPayload(parsed.esPayload, pts90k: parsed.pts90k),
    );
  }

  void _appendAccessUnits(
    List<TimestampedAccessUnit> output,
    Iterable<TimestampedAccessUnit> accessUnits,
  ) {
    for (final accessUnit in accessUnits) {
      if (_waitingForRandomAccess) {
        if (!accessUnit.hasIdr) {
          _droppedDependentAccessUnitCount++;
          continue;
        }
        _waitingForRandomAccess = false;
      }
      output.add(accessUnit);
      final pts90k = accessUnit.pts90k;
      if (pts90k != null) _timestamped.noteEmitted(pts90k);
      _emittedAccessUnitCount++;
    }
  }
}

final class _TimestampedH264Assembler {
  _TimestampedH264Assembler({int? basePts90k})
    : _requestedBasePts90k = basePts90k,
      _basePts90k = basePts90k,
      _epochBasePts90k = basePts90k,
      _timestampRebaser = MpegTimestampEpochRebaser(
        initialReference90k: basePts90k,
      );

  final IncrementalAnnexBAccessUnitBuilder _accessUnits =
      IncrementalAnnexBAccessUnitBuilder();
  final ListQueue<_TimestampAnchor> _anchors = ListQueue<_TimestampAnchor>();
  final ListQueue<_PendingTimestampedAccessUnit> _pending =
      ListQueue<_PendingTimestampedAccessUnit>();
  final int? _requestedBasePts90k;
  final MpegTimestampEpochRebaser _timestampRebaser;

  int? _basePts90k;
  int? _epochBasePts90k;
  int? _normalizedBasePts90k;
  int _nextAccessUnitIndex = 0;
  int? _previousKnownIndex;
  int? _previousKnownPts90k;
  int? _lastKnownIndex;
  int? _lastKnownPts90k;
  int _timestampEpochCount = 0;
  bool _finished = false;

  int? get basePts90k => _normalizedBasePts90k ?? _basePts90k;
  int get timestampEpochCount => _timestampEpochCount;
  MpegTimestampEpochSnapshot? get currentTimestampEpoch =>
      _timestampRebaser.currentEpochSnapshot;
  MpegTimestampEpoch? get currentEpoch => _timestampRebaser.currentEpoch;

  MpegTimestampEpoch beginEpoch({
    required int discontinuitySequence,
    int? elapsedDuration90k,
    MpegTimestampEpoch? sharedEpoch,
  }) {
    _epochBasePts90k = null;
    final epoch = _timestampRebaser.beginEpoch(
      discontinuitySequence: discontinuitySequence,
      elapsedDuration90k: elapsedDuration90k,
      sharedEpoch: sharedEpoch,
    );
    _timestampEpochCount++;
    return epoch;
  }

  void noteEmitted(int pts90k) => _timestampRebaser.noteEmitted(pts90k);

  List<TimestampedAccessUnit> pushPayload(
    Uint8List payload, {
    required int? pts90k,
  }) {
    if (_finished) {
      throw StateError('Cannot push an H.264 PES payload after finish()');
    }
    final payloadOffset = _accessUnits.streamOffset;
    if (pts90k != null) {
      final rebased = _timestampRebaser.rebase(pts90k);
      _basePts90k ??= rebased;
      _epochBasePts90k ??= rebased;
      _anchors.add(_TimestampAnchor(payloadOffset, rebased));
    }
    return _accept(_accessUnits.push(payload));
  }

  List<TimestampedAccessUnit> finish() {
    if (_finished) return const <TimestampedAccessUnit>[];
    _finished = true;
    final output = <TimestampedAccessUnit>[];
    output.addAll(_accept(_accessUnits.finish()));
    output.addAll(_flushUnanchoredTail());
    _anchors.clear();
    return List<TimestampedAccessUnit>.unmodifiable(output);
  }

  /// Drops unresolved access units, PTS anchors, and the incomplete Annex-B
  /// tail after a transport discontinuity. Returns the discarded picture count.
  int discardIncompleteTail({bool clearParameterSets = false}) {
    if (_finished) return 0;
    final discarded =
        _pending.length +
        _accessUnits.discardIncompleteTail(
          clearParameterSets: clearParameterSets,
        );
    _pending.clear();
    _anchors.clear();
    _previousKnownIndex = null;
    _previousKnownPts90k = null;
    _lastKnownIndex = null;
    _lastKnownPts90k = null;
    _epochBasePts90k = null;
    return discarded;
  }

  List<TimestampedAccessUnit> _accept(Iterable<AccessUnit> accessUnits) {
    final output = <TimestampedAccessUnit>[];
    for (final accessUnit in accessUnits) {
      final index = _nextAccessUnitIndex++;
      final firstVclOffset = accessUnit.firstVclOffset;
      int? directPts90k;
      if (firstVclOffset != null) {
        while (_anchors.isNotEmpty && _anchors.first.offset <= firstVclOffset) {
          directPts90k = _anchors.removeFirst().pts90k;
        }
      }
      if (directPts90k == null &&
          _lastKnownIndex == null &&
          _epochBasePts90k != null) {
        directPts90k = _epochBasePts90k;
      }
      _pending.add(_PendingTimestampedAccessUnit(index, accessUnit));
      if (directPts90k != null) {
        output.addAll(_resolveThroughKnown(index, directPts90k));
      }
    }
    return output;
  }

  List<TimestampedAccessUnit> _resolveThroughKnown(
    int rightIndex,
    int rightPts90k,
  ) {
    final output = <TimestampedAccessUnit>[];
    final leftIndex = _lastKnownIndex;
    final leftPts90k = _lastKnownPts90k;
    while (_pending.isNotEmpty && _pending.first.index <= rightIndex) {
      final pending = _pending.removeFirst();
      final pts90k = leftIndex == null || leftPts90k == null
          ? rightPts90k
          : leftPts90k +
                ((rightPts90k - leftPts90k) *
                        (pending.index - leftIndex) /
                        (rightIndex - leftIndex))
                    .round();
      output.add(_timestamp(pending.accessUnit, pts90k));
    }

    _previousKnownIndex = _lastKnownIndex;
    _previousKnownPts90k = _lastKnownPts90k;
    _lastKnownIndex = rightIndex;
    _lastKnownPts90k = rightPts90k;
    return output;
  }

  List<TimestampedAccessUnit> _flushUnanchoredTail() {
    if (_pending.isEmpty) return const <TimestampedAccessUnit>[];
    final output = <TimestampedAccessUnit>[];
    final lastIndex = _lastKnownIndex;
    final lastPts90k = _lastKnownPts90k;
    if (lastIndex == null || lastPts90k == null) {
      final fallback = _epochBasePts90k == null ? 0 : _epochBasePts90k!;
      while (_pending.isNotEmpty) {
        output.add(_timestamp(_pending.removeFirst().accessUnit, fallback));
      }
      return output;
    }

    var cadence90k = 0;
    final previousIndex = _previousKnownIndex;
    final previousPts90k = _previousKnownPts90k;
    if (previousIndex != null &&
        previousPts90k != null &&
        lastIndex != previousIndex) {
      cadence90k = ((lastPts90k - previousPts90k) / (lastIndex - previousIndex))
          .round();
    }
    while (_pending.isNotEmpty) {
      final pending = _pending.removeFirst();
      final pts90k = lastPts90k + cadence90k * (pending.index - lastIndex);
      output.add(_timestamp(pending.accessUnit, pts90k));
    }
    return output;
  }

  TimestampedAccessUnit _timestamp(AccessUnit accessUnit, int pts90k) {
    final normalizedBase = _normalizedBasePts90k ??= unwrapMpegTimestamp33(
      _requestedBasePts90k ?? _basePts90k ?? pts90k,
      pts90k,
    );
    final delta = pts90k - normalizedBase;
    final ptsMs = delta <= 0 ? 0 : ((delta * 1000) / 90000).round();
    return TimestampedAccessUnit(
      ptsMs: ptsMs,
      pts90k: pts90k,
      nals: accessUnit.nals,
      hasIdr: accessUnit.isIdr,
    );
  }
}

final class _TimestampAnchor {
  const _TimestampAnchor(this.offset, this.pts90k);

  final int offset;
  final int pts90k;
}

final class _PendingTimestampedAccessUnit {
  const _PendingTimestampedAccessUnit(this.index, this.accessUnit);

  final int index;
  final AccessUnit accessUnit;
}
