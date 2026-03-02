import 'dart:typed_data';
import 'h264_nal.dart';

class PtsChunk {
  final int? pts90k;
  final Uint8List payload;
  PtsChunk({required this.pts90k, required this.payload});
}

class TimestampedAccessUnit {
  final int ptsMs; // normalized to ms
  final List<Uint8List> nals;
  final bool hasIdr;
  TimestampedAccessUnit({
    required this.ptsMs,
    required this.nals,
    required this.hasIdr,
  });
}

List<TimestampedAccessUnit> buildTimestampedIdrAusFromPtsChunks({
  required List<PtsChunk> ptsChunks,
  required int? basePts90k,
}) {
  final out = <TimestampedAccessUnit>[];

  // Very simple strategy:
  // - concatenate payloads into a single ES buffer
  // - pick the last seen PTS as “current” for subsequent bytes
  // - build IDR AUs, assign them the most recent PTS we saw before them
  final es = BytesBuilder(copy: false);

  int? lastPts90k;
  for (final c in ptsChunks) {
    if (c.pts90k != null) lastPts90k = c.pts90k;
    es.add(c.payload);
  }

  final nals = splitAnnexBNals(es.toBytes());
  final aus = buildIdrAccessUnits(nals);

  // If we only saw 1 PTS in the segment, we assign it to all AUs.
  // Later upgrade: map PTS to AU boundaries properly (needs scanning for AUD or slice starts).
  final ptsToUse = lastPts90k ?? basePts90k ?? 0;
  final base = basePts90k ?? ptsToUse;

  int ptsMs = (((ptsToUse - base) * 1000) / 90000).round();
  if (ptsMs < 0) ptsMs = 0;

  for (final au in aus) {
    out.add(
      TimestampedAccessUnit(ptsMs: ptsMs, nals: au.nals, hasIdr: au.isIdr),
    );
    // small fake increment if multiple AUs exist in same segment without PTS mapping
    ptsMs += 500;
  }

  return out;
}
