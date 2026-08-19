import 'dart:typed_data';

import 'decoder/bitreader.dart';
import 'decoder/exp_golomb.dart';
import 'decoder/rbsp.dart';

int nalType(Uint8List nal) => nal.isEmpty ? -1 : (nal[0] & 0x1f);

bool _isVcl(int type) => type >= 1 && type <= 5;

/// One H.264 access unit (one coded picture and its associated non-VCL NALs).
class AccessUnit {
  final List<Uint8List> nals;
  final bool isIdr;

  /// Absolute offsets in the Annex-B elementary stream, when the AU was built
  /// by [buildAccessUnitsFromAnnexB]. They are null for a list of detached NALs.
  final int? sourceStartOffset;
  final int? firstVclOffset;
  final int? sourceEndOffset;

  AccessUnit(
    this.nals, {
    required this.isIdr,
    this.sourceStartOffset,
    this.firstVclOffset,
    this.sourceEndOffset,
  });

  bool get isKeyframe => isIdr;
}

/// A NAL payload and its position in an Annex-B elementary stream.
///
/// [bytes] does not contain the start code. [startOffset] points at the first
/// zero preceding the start code, including any Annex-B leading/trailing zero
/// bytes, while [payloadOffset] points at the NAL header byte.
class AnnexBNalUnit {
  final Uint8List bytes;
  final int startOffset;
  final int payloadOffset;
  final int endOffset;

  const AnnexBNalUnit({
    required this.bytes,
    required this.startOffset,
    required this.payloadOffset,
    required this.endOffset,
  });
}

class _StartCode {
  final int zeroRunStart;
  final int payloadOffset;

  const _StartCode(this.zeroRunStart, this.payloadOffset);
}

/// Scans an Annex-B byte stream and retains source byte offsets.
///
/// Both three- and four-byte start codes are accepted. Longer zero runs,
/// leading_zero_8bits, trailing_zero_8bits and empty units are handled without
/// leaking delimiter bytes into a NAL payload.
List<AnnexBNalUnit> splitAnnexBNalUnits(Uint8List es) {
  final out = <AnnexBNalUnit>[];
  var startCode = _findStartCode(es, 0);

  while (startCode != null) {
    final next = _findStartCode(es, startCode.payloadOffset);
    var nalEnd = next?.zeroRunStart ?? es.length;

    // At end of byte_stream_nal_unit(), zero bytes following rbsp_trailing_bits
    // are Annex-B trailing_zero_8bits, not part of the NAL unit.
    if (next == null) {
      while (nalEnd > startCode.payloadOffset && es[nalEnd - 1] == 0) {
        nalEnd--;
      }
    }

    if (nalEnd > startCode.payloadOffset) {
      out.add(
        AnnexBNalUnit(
          bytes: Uint8List.sublistView(es, startCode.payloadOffset, nalEnd),
          startOffset: startCode.zeroRunStart,
          payloadOffset: startCode.payloadOffset,
          endOffset: nalEnd,
        ),
      );
    }
    startCode = next;
  }

  return out;
}

/// Splits Annex-B into NAL payloads without start codes.
List<Uint8List> splitAnnexBNals(Uint8List es) =>
    splitAnnexBNalUnits(es).map((unit) => unit.bytes).toList(growable: false);

_StartCode? _findStartCode(Uint8List bytes, int from) {
  var zeroRunStart = -1;
  var zeroCount = 0;

  for (var i = from; i < bytes.length; i++) {
    final value = bytes[i];
    if (value == 0) {
      if (zeroCount == 0) zeroRunStart = i;
      zeroCount++;
      continue;
    }

    if (value == 1 && zeroCount >= 2) {
      return _StartCode(zeroRunStart, i + 1);
    }

    zeroCount = 0;
    zeroRunStart = -1;
  }
  return null;
}

class _NalRecord {
  final Uint8List bytes;
  final int? startOffset;
  final int? payloadOffset;
  final int? endOffset;

  const _NalRecord(
    this.bytes, {
    this.startOffset,
    this.payloadOffset,
    this.endOffset,
  });
}

class _CachedPps {
  final Uint8List nal;
  final int spsId;

  const _CachedPps(this.nal, this.spsId);
}

/// Builds every H.264 access unit, including non-IDR I/P pictures.
///
/// AUD NALs are authoritative boundaries. In streams without AUDs, a VCL NAL
/// with `first_mb_in_slice == 0` starts the next picture after an existing VCL
/// NAL. Additional slices with a non-zero first macroblock remain in the same
/// AU. SPS, PPS and SEI NALs are attached to the following coded picture.
///
/// When [prependCachedParameterSetsToIdr] is true, the latest SPS/PPS are added
/// to an IDR AU if that AU does not already carry them. This keeps independently
/// selected IDR AUs decodable while avoiding duplicates.
List<AccessUnit> buildAllAccessUnits(
  List<Uint8List> nals, {
  bool prependCachedParameterSetsToIdr = true,
}) {
  return _buildAllAccessUnits(
    nals.map((nal) => _NalRecord(nal)).toList(growable: false),
    prependCachedParameterSetsToIdr: prependCachedParameterSetsToIdr,
  );
}

/// Splits an Annex-B stream and builds every access unit while retaining the
/// byte offsets needed for PES/PTS association.
List<AccessUnit> buildAccessUnitsFromAnnexB(
  Uint8List es, {
  bool prependCachedParameterSetsToIdr = true,
}) {
  final records = splitAnnexBNalUnits(es)
      .map(
        (unit) => _NalRecord(
          unit.bytes,
          startOffset: unit.startOffset,
          payloadOffset: unit.payloadOffset,
          endOffset: unit.endOffset,
        ),
      )
      .toList(growable: false);
  return _buildAllAccessUnits(
    records,
    prependCachedParameterSetsToIdr: prependCachedParameterSetsToIdr,
  );
}

List<AccessUnit> _buildAllAccessUnits(
  List<_NalRecord> records, {
  required bool prependCachedParameterSetsToIdr,
}) {
  final accessUnits = <AccessUnit>[];
  final pending = <_NalRecord>[];
  final current = <_NalRecord>[];

  Uint8List? cachedSps;
  Uint8List? cachedPps;
  final spsById = <int, Uint8List>{};
  final ppsById = <int, _CachedPps>{};
  var currentHasVcl = false;
  var currentIsIdr = false;

  void emitCurrent() {
    if (!currentHasVcl) {
      current.clear();
      return;
    }

    final outputNals = current.map((record) => record.bytes).toList();
    if (prependCachedParameterSetsToIdr && currentIsIdr) {
      final activePpsId = current
          .where((record) => nalType(record.bytes) == 5)
          .map((record) => _tryReadSlicePpsId(record.bytes))
          .whereType<int>()
          .firstOrNull;
      final activePps = activePpsId == null ? null : ppsById[activePpsId];
      final selectedPps = activePps?.nal ?? cachedPps;
      final selectedSps = activePps == null
          ? cachedSps
          : (spsById[activePps.spsId] ?? cachedSps);

      final hasPps = activePpsId == null
          ? outputNals.any((nal) => nalType(nal) == 8)
          : outputNals.any(
              (nal) =>
                  nalType(nal) == 8 &&
                  _tryReadPpsIds(nal)?.ppsId == activePpsId,
            );
      final activeSpsId = activePps?.spsId;
      final hasSps = activeSpsId == null
          ? outputNals.any((nal) => nalType(nal) == 7)
          : outputNals.any(
              (nal) => nalType(nal) == 7 && _tryReadSpsId(nal) == activeSpsId,
            );
      final prefix = <Uint8List>[];
      if (!hasSps && selectedSps != null) prefix.add(selectedSps);
      if (!hasPps && selectedPps != null) prefix.add(selectedPps);
      if (prefix.isNotEmpty) outputNals.insertAll(0, prefix);
    }

    int? sourceStart;
    int? sourceEnd;
    int? firstVcl;
    for (final record in current) {
      sourceStart ??= record.startOffset;
      sourceEnd = record.endOffset ?? sourceEnd;
      if (firstVcl == null && _isVcl(nalType(record.bytes))) {
        firstVcl = record.startOffset ?? record.payloadOffset;
      }
    }

    accessUnits.add(
      AccessUnit(
        outputNals,
        isIdr: currentIsIdr,
        sourceStartOffset: sourceStart,
        firstVclOffset: firstVcl,
        sourceEndOffset: sourceEnd,
      ),
    );
    current.clear();
    currentHasVcl = false;
    currentIsIdr = false;
  }

  void beginCurrentIfNeeded() {
    if (current.isNotEmpty) return;
    current.addAll(pending);
    pending.clear();
  }

  for (final record in records) {
    final type = nalType(record.bytes);
    if (type < 0) continue;

    if (_isVcl(type)) {
      final firstMb = tryReadFirstMbInSlice(record.bytes);
      final startsNewPicture =
          currentHasVcl &&
          (type == 1 || type == 2 || type == 5) &&
          (firstMb == null || firstMb == 0);
      if (startsNewPicture) emitCurrent();

      beginCurrentIfNeeded();
      current.add(record);
      currentHasVcl = true;
      currentIsIdr = currentIsIdr || type == 5;
      continue;
    }

    if (_startsFollowingAccessUnit(type)) {
      if (currentHasVcl) emitCurrent();
      // Update the cache only after closing the preceding picture. Otherwise
      // a parameter set announced for the next picture could be injected into
      // an earlier IDR that did not carry its own copy.
      if (type == 7) {
        cachedSps = record.bytes;
        final spsId = _tryReadSpsId(record.bytes);
        if (spsId != null) {
          spsById[spsId] = record.bytes;
        }
      }
      if (type == 8) {
        cachedPps = record.bytes;
        final ids = _tryReadPpsIds(record.bytes);
        if (ids != null) {
          ppsById[ids.ppsId] = _CachedPps(record.bytes, ids.spsId);
        }
      }
      pending.add(record);
      continue;
    }

    if (type == 10 || type == 11) {
      if (currentHasVcl) {
        current.add(record);
        emitCurrent();
      } else {
        pending.add(record);
      }
      continue;
    }

    if (currentHasVcl) {
      current.add(record);
    } else {
      pending.add(record);
    }
  }

  emitCurrent();
  return accessUnits;
}

bool _startsFollowingAccessUnit(int type) {
  return type == 6 ||
      type == 7 ||
      type == 8 ||
      type == 9 ||
      type == 12 ||
      (type >= 13 && type <= 18);
}

/// Backward-compatible IDR-only view of [buildAllAccessUnits].
List<AccessUnit> buildIdrAccessUnits(List<Uint8List> nals) =>
    buildAllAccessUnits(nals).where((au) => au.isIdr).toList(growable: false);

/// Reads `first_mb_in_slice` from a VCL NAL when it is available.
int? tryReadFirstMbInSlice(Uint8List nal) {
  try {
    if (nal.isEmpty) return null;
    final type = nalType(nal);
    if (type != 1 && type != 2 && type != 5) return null;
    final rbsp = ebspToRbsp(Uint8List.sublistView(nal, 1));
    return readUE(BitReader(rbsp));
  } on BitstreamFormatException {
    return null;
  } on FormatException {
    return null;
  }
}

int? _tryReadSlicePpsId(Uint8List nal) {
  try {
    final type = nalType(nal);
    if (type != 1 && type != 2 && type != 5) return null;
    final reader = BitReader(ebspToRbsp(Uint8List.sublistView(nal, 1)));
    readUE(reader); // first_mb_in_slice
    readUE(reader); // slice_type
    return readUE(reader); // pic_parameter_set_id
  } on FormatException {
    return null;
  }
}

int? _tryReadSpsId(Uint8List nal) {
  try {
    if (nalType(nal) != 7) return null;
    final reader = BitReader(ebspToRbsp(Uint8List.sublistView(nal, 1)));
    reader.skipBits(24); // profile_idc, constraint flags, level_idc
    return readUE(reader);
  } on FormatException {
    return null;
  }
}

class _PpsIds {
  final int ppsId;
  final int spsId;

  const _PpsIds(this.ppsId, this.spsId);
}

_PpsIds? _tryReadPpsIds(Uint8List nal) {
  try {
    if (nalType(nal) != 8) return null;
    final reader = BitReader(ebspToRbsp(Uint8List.sublistView(nal, 1)));
    return _PpsIds(readUE(reader), readUE(reader));
  } on FormatException {
    return null;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
