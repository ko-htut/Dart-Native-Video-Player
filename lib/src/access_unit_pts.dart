import 'dart:typed_data';

import 'h264_nal.dart';

/// One completed PES elementary-stream payload and the PTS carried by its PES
/// header. PTS uses the MPEG 90 kHz, 33-bit clock.
class PtsChunk {
  final int? pts90k;
  final Uint8List payload;

  const PtsChunk({required this.pts90k, required this.payload});
}

class TimestampedAccessUnit {
  /// Presentation timestamp normalized relative to the requested base.
  final int ptsMs;

  /// Unwrapped MPEG timestamp. It may exceed 33 bits after a rollover.
  final int? pts90k;
  final List<Uint8List> nals;
  final bool hasIdr;

  const TimestampedAccessUnit({
    required this.ptsMs,
    required this.nals,
    required this.hasIdr,
    this.pts90k,
  });

  bool get isKeyframe => hasIdr;
}

class _PtsAnchor {
  final int offset;
  final int pts90k;

  const _PtsAnchor(this.offset, this.pts90k);
}

const int _ptsModulus = 1 << 33;
const int _ptsMask = _ptsModulus - 1;
const int _ptsHalfRange = _ptsModulus >> 1;

/// Builds timestamped access units for every H.264 I/P picture in the chunks.
///
/// PES PTS values are associated by elementary-stream byte position: a PTS
/// belongs to the first access unit whose first VCL NAL starts at or after that
/// PES payload boundary. This remains correct when Annex-B start codes or NALs
/// are split across transport/PES chunks. Missing intermediate timestamps are
/// interpolated from neighboring PTS anchors; after the last anchor the most
/// recently observed cadence is used. With only one anchor, its value is kept.
List<TimestampedAccessUnit> buildTimestampedAccessUnitsFromPtsChunks({
  required List<PtsChunk> ptsChunks,
  required int? basePts90k,
}) {
  if (ptsChunks.isEmpty) return const <TimestampedAccessUnit>[];

  final stream = BytesBuilder(copy: false);
  final anchors = <_PtsAnchor>[];
  var streamOffset = 0;
  int? unwrapReference = basePts90k == null ? null : (basePts90k & _ptsMask);

  for (final chunk in ptsChunks) {
    final rawPts = chunk.pts90k;
    if (rawPts != null) {
      final unwrapped = _unwrapPts(rawPts, unwrapReference);
      anchors.add(_PtsAnchor(streamOffset, unwrapped));
      unwrapReference = unwrapped;
    }
    stream.add(chunk.payload);
    streamOffset += chunk.payload.length;
  }

  final accessUnits = buildAccessUnitsFromAnnexB(stream.toBytes());
  if (accessUnits.isEmpty) return const <TimestampedAccessUnit>[];

  final ptsByAccessUnit = _associatePts(accessUnits, anchors, basePts90k);
  final normalizedBase = basePts90k == null
      ? (ptsByAccessUnit.first ?? anchors.firstOrNull?.pts90k ?? 0)
      : _unwrapPts(basePts90k, ptsByAccessUnit.firstOrNull);

  return List<TimestampedAccessUnit>.generate(accessUnits.length, (index) {
    final accessUnit = accessUnits[index];
    final pts = ptsByAccessUnit[index] ?? normalizedBase;
    final delta = pts - normalizedBase;
    final ptsMs = delta <= 0 ? 0 : ((delta * 1000) / 90000).round();
    return TimestampedAccessUnit(
      ptsMs: ptsMs,
      pts90k: pts,
      nals: accessUnit.nals,
      hasIdr: accessUnit.isIdr,
    );
  }, growable: false);
}

/// Backward-compatible IDR-only view.
///
/// Unlike the former implementation, each retained IDR keeps the PTS of its
/// source PES instead of receiving the segment's final PTS plus a fake 500 ms
/// increment.
List<TimestampedAccessUnit> buildTimestampedIdrAusFromPtsChunks({
  required List<PtsChunk> ptsChunks,
  required int? basePts90k,
}) {
  return buildTimestampedAccessUnitsFromPtsChunks(
    ptsChunks: ptsChunks,
    basePts90k: basePts90k,
  ).where((accessUnit) => accessUnit.hasIdr).toList(growable: false);
}

List<int?> _associatePts(
  List<AccessUnit> accessUnits,
  List<_PtsAnchor> anchors,
  int? basePts90k,
) {
  final values = List<int?>.filled(accessUnits.length, null);

  var targetIndex = 0;
  for (final anchor in anchors) {
    while (targetIndex < accessUnits.length - 1 &&
        (accessUnits[targetIndex].firstVclOffset ?? 0) < anchor.offset) {
      targetIndex++;
    }
    if ((accessUnits[targetIndex].firstVclOffset ?? 0) < anchor.offset) {
      // The anchor occurs after the final coded picture; it belongs to a
      // picture that is not present in this batch.
      continue;
    }
    values[targetIndex] = anchor.pts90k;
  }

  if (basePts90k != null && values.first == null) {
    values[0] = _unwrapPts(basePts90k, anchors.firstOrNull?.pts90k);
  }

  final known = <int>[
    for (var i = 0; i < values.length; i++)
      if (values[i] != null) i,
  ];
  if (known.isEmpty) {
    final fallback = basePts90k == null ? 0 : (basePts90k & _ptsMask);
    values.fillRange(0, values.length, fallback);
    return values;
  }

  final firstKnown = known.first;
  for (var i = 0; i < firstKnown; i++) {
    values[i] = values[firstKnown];
  }

  for (var knownIndex = 0; knownIndex + 1 < known.length; knownIndex++) {
    final left = known[knownIndex];
    final right = known[knownIndex + 1];
    final leftPts = values[left]!;
    final rightPts = values[right]!;
    final distance = right - left;
    for (var i = left + 1; i < right; i++) {
      values[i] =
          leftPts + ((rightPts - leftPts) * (i - left) / distance).round();
    }
  }

  final lastKnown = known.last;
  var cadence = 0;
  if (known.length >= 2) {
    final previous = known[known.length - 2];
    cadence =
        ((values[lastKnown]! - values[previous]!) / (lastKnown - previous))
            .round();
  }
  for (var i = lastKnown + 1; i < values.length; i++) {
    values[i] = values[i - 1]! + cadence;
  }

  return values;
}

int _unwrapPts(int pts90k, int? reference) {
  final raw = pts90k & _ptsMask;
  if (reference == null) return raw;

  final referenceRaw = reference & _ptsMask;
  var delta = raw - referenceRaw;
  if (delta > _ptsHalfRange) {
    delta -= _ptsModulus;
  } else if (delta < -_ptsHalfRange) {
    delta += _ptsModulus;
  }
  return reference + delta;
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
