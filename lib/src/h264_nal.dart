import 'dart:typed_data';

import 'decoder/bitreader.dart';
import 'decoder/exp_golomb.dart';
import 'decoder/rbsp.dart';

int nalType(Uint8List nal) => nal.isEmpty ? -1 : (nal[0] & 0x1f);

bool _isVcl(int type) => type >= 1 && type <= 5;

/// Whether this complete access unit is safe to omit during late playback.
///
/// Only non-reference B pictures qualify. Parameter sets make the complete AU
/// non-disposable because the decoder must still observe those side effects.
/// Every VCL NAL is checked so a malformed or mixed picture fails closed.
bool isDisposableNonReferenceBAccessUnit(Iterable<Uint8List> nals) {
  var sawVcl = false;
  int? pictureParameterSetId;
  for (final nal in nals) {
    if (nal.isEmpty) return false;
    if ((nal[0] & 0x80) != 0) return false;
    final type = nalType(nal);
    if (type == 7 || type == 8) return false;
    if (!_isVcl(type)) continue;

    sawVcl = true;
    final nalRefIdc = (nal[0] >> 5) & 0x03;
    if (type != 1 || nalRefIdc != 0) return false;
    try {
      final rbsp = ebspToRbsp(Uint8List.sublistView(nal, 1));
      final reader = BitReader(rbsp);
      readUE(reader); // first_mb_in_slice
      if (readUE(reader) % 5 != 1) return false; // B slice
      final currentPpsId = readUE(reader);
      pictureParameterSetId ??= currentPpsId;
      if (currentPpsId != pictureParameterSetId) return false;
    } catch (_) {
      return false;
    }
  }
  return sawVcl;
}

/// Decides whether a disposable B picture should be omitted during playback.
///
/// High-resolution software decoding has much less timing headroom, so it
/// can shed non-reference B pictures proactively to maintain a stable
/// reference-picture cadence. Lower resolutions retain the more tolerant
/// legacy threshold.
/// Reference pictures, parameter-set-bearing access units, and malformed
/// slices always fail closed through [isDisposableNonReferenceBAccessUnit].
bool shouldSkipH264AccessUnitForSmoothPlayback({
  required Iterable<Uint8List> nals,
  required int latenessMs,
  required bool highResolution,
  int normalLateThresholdMs = 100,
  int highResolutionLateThresholdMs = 0,
}) {
  if (normalLateThresholdMs < 0 || highResolutionLateThresholdMs < 0) {
    throw ArgumentError('Playback skip thresholds must not be negative.');
  }
  if (!isDisposableNonReferenceBAccessUnit(nals)) return false;
  final threshold = highResolution
      ? highResolutionLateThresholdMs
      : normalLateThresholdMs;
  return latenessMs >= threshold;
}

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
  final builder = _AccessUnitRecordBuilder(
    prependCachedParameterSetsToIdr: prependCachedParameterSetsToIdr,
  );
  return <AccessUnit>[...builder.push(records), ...builder.finish()];
}

/// Incrementally splits Annex-B bytes and assembles complete H.264 access units.
///
/// Unlike [buildAccessUnitsFromAnnexB], [push] never treats the end of the
/// supplied chunk as the end of a NAL unit or picture. The final buffered NAL
/// and access unit are emitted only by [finish], which makes this class safe for
/// elementary streams split across PES packets and HLS media segments.
///
/// Emitted NAL payloads own their bytes. They therefore do not retain a large
/// rolling input buffer through a [Uint8List.sublistView].
final class IncrementalAnnexBAccessUnitBuilder {
  IncrementalAnnexBAccessUnitBuilder({
    bool prependCachedParameterSetsToIdr = true,
  }) : _accessUnits = _AccessUnitRecordBuilder(
         prependCachedParameterSetsToIdr: prependCachedParameterSetsToIdr,
         copyOutputNals: true,
       );

  final _IncrementalAnnexBNalScanner _scanner = _IncrementalAnnexBNalScanner();
  final _AccessUnitRecordBuilder _accessUnits;
  bool _finished = false;

  /// Absolute byte offset immediately after all elementary-stream bytes pushed
  /// so far, including bytes retained as an incomplete NAL tail.
  int get streamOffset => _scanner.streamOffset;

  int get bufferedByteCount => _scanner.bufferedByteCount;

  bool get hasIncompleteAccessUnit => _accessUnits.hasIncompleteAccessUnit;

  List<AccessUnit> push(Uint8List bytes) {
    if (_finished) {
      throw StateError('Cannot push Annex-B bytes after finish()');
    }
    return _accessUnits.push(_scanner.push(bytes));
  }

  /// Flushes the finite-stream tail. Repeated calls are harmless.
  List<AccessUnit> finish() {
    if (_finished) return const <AccessUnit>[];
    _finished = true;
    return <AccessUnit>[
      ..._accessUnits.push(_scanner.finish()),
      ..._accessUnits.finish(),
    ];
  }

  /// Drops bytes and picture state that could have crossed a damaged transport
  /// boundary. Cached SPS/PPS state is retained by default so the next IDR can
  /// still be made independently decodable.
  ///
  /// Returns the number of incomplete coded pictures discarded.
  int discardIncompleteTail({bool clearParameterSets = false}) {
    if (_finished) return 0;
    _scanner.discardIncompleteTail();
    return _accessUnits.discardIncompleteTail(
      clearParameterSets: clearParameterSets,
    );
  }
}

final class _IncrementalAnnexBNalScanner {
  Uint8List _buffer = Uint8List(0);
  int _bufferStartOffset = 0;
  int _streamOffset = 0;
  bool _finished = false;

  int get streamOffset => _streamOffset;
  int get bufferedByteCount => _buffer.length;

  List<_NalRecord> push(Uint8List bytes) {
    if (_finished) {
      throw StateError('Cannot push Annex-B bytes after finish()');
    }
    if (bytes.isNotEmpty) {
      final joined = Uint8List(_buffer.length + bytes.length);
      joined.setRange(0, _buffer.length, _buffer);
      joined.setRange(_buffer.length, joined.length, bytes);
      _buffer = joined;
      _streamOffset += bytes.length;
    }
    return _scan(flushTail: false);
  }

  List<_NalRecord> finish() {
    if (_finished) return const <_NalRecord>[];
    _finished = true;
    final output = _scan(flushTail: true);
    _bufferStartOffset = _streamOffset;
    _buffer = Uint8List(0);
    return output;
  }

  void discardIncompleteTail() {
    if (_finished) return;
    _bufferStartOffset = _streamOffset;
    _buffer = Uint8List(0);
  }

  List<_NalRecord> _scan({required bool flushTail}) {
    final output = <_NalRecord>[];
    final firstStartCode = _findStartCode(_buffer, 0);
    if (firstStartCode == null) {
      if (flushTail) {
        _bufferStartOffset = _streamOffset;
        _buffer = Uint8List(0);
      } else {
        _retainPossibleStartCodePrefix();
      }
      return output;
    }
    _StartCode current = firstStartCode;

    // Bytes before the first delimiter are leading junk. Dropping them keeps
    // the scanner bounded without changing any NAL payload offset.
    if (current.zeroRunStart > 0) {
      _discardPrefix(current.zeroRunStart);
      current = _findStartCode(_buffer, 0)!;
    }

    while (true) {
      final next = _findStartCode(_buffer, current.payloadOffset);
      if (next == null) {
        if (flushTail) {
          var nalEnd = _buffer.length;
          while (nalEnd > current.payloadOffset && _buffer[nalEnd - 1] == 0) {
            nalEnd--;
          }
          _appendRecord(output, current, nalEnd);
        }
        break;
      }
      _appendRecord(output, current, next.zeroRunStart);
      current = next;
    }

    if (!flushTail && current.zeroRunStart > 0) {
      _discardPrefix(current.zeroRunStart);
    }
    return List<_NalRecord>.unmodifiable(output);
  }

  void _appendRecord(
    List<_NalRecord> output,
    _StartCode startCode,
    int nalEnd,
  ) {
    if (nalEnd <= startCode.payloadOffset) return;
    output.add(
      _NalRecord(
        Uint8List.fromList(
          Uint8List.sublistView(_buffer, startCode.payloadOffset, nalEnd),
        ),
        startOffset: _bufferStartOffset + startCode.zeroRunStart,
        payloadOffset: _bufferStartOffset + startCode.payloadOffset,
        endOffset: _bufferStartOffset + nalEnd,
      ),
    );
  }

  void _retainPossibleStartCodePrefix() {
    var trailingZeroStart = _buffer.length;
    while (trailingZeroStart > 0 && _buffer[trailingZeroStart - 1] == 0) {
      trailingZeroStart--;
    }
    if (trailingZeroStart > 0) _discardPrefix(trailingZeroStart);
  }

  void _discardPrefix(int count) {
    if (count <= 0) return;
    _buffer = Uint8List.fromList(_buffer.sublist(count));
    _bufferStartOffset += count;
  }
}

final class _AccessUnitRecordBuilder {
  _AccessUnitRecordBuilder({
    required this.prependCachedParameterSetsToIdr,
    this.copyOutputNals = false,
  });

  final bool prependCachedParameterSetsToIdr;
  final bool copyOutputNals;
  final List<_NalRecord> _pending = <_NalRecord>[];
  final List<_NalRecord> _current = <_NalRecord>[];

  Uint8List? _cachedSps;
  Uint8List? _cachedPps;
  final Map<int, Uint8List> _spsById = <int, Uint8List>{};
  final Map<int, _CachedPps> _ppsById = <int, _CachedPps>{};
  bool _currentHasVcl = false;
  bool _currentIsIdr = false;
  bool _finished = false;

  bool get hasIncompleteAccessUnit => _currentHasVcl;

  List<AccessUnit> push(Iterable<_NalRecord> records) {
    if (_finished) {
      throw StateError('Cannot push H.264 NAL units after finish()');
    }
    final output = <AccessUnit>[];
    for (final record in records) {
      _consume(record, output);
    }
    return List<AccessUnit>.unmodifiable(output);
  }

  List<AccessUnit> finish() {
    if (_finished) return const <AccessUnit>[];
    _finished = true;
    final output = <AccessUnit>[];
    _emitCurrent(output);
    _pending.clear();
    return List<AccessUnit>.unmodifiable(output);
  }

  int discardIncompleteTail({required bool clearParameterSets}) {
    final discardedPictures = _currentHasVcl ? 1 : 0;
    _pending.clear();
    _current.clear();
    _currentHasVcl = false;
    _currentIsIdr = false;
    if (clearParameterSets) {
      _cachedSps = null;
      _cachedPps = null;
      _spsById.clear();
      _ppsById.clear();
    }
    return discardedPictures;
  }

  void _consume(_NalRecord record, List<AccessUnit> output) {
    final type = nalType(record.bytes);
    if (type < 0) return;

    if (_isVcl(type)) {
      final firstMb = tryReadFirstMbInSlice(record.bytes);
      final startsNewPicture =
          _currentHasVcl &&
          (type == 1 || type == 2 || type == 5) &&
          (firstMb == null || firstMb == 0);
      if (startsNewPicture) _emitCurrent(output);

      _beginCurrentIfNeeded();
      _current.add(record);
      _currentHasVcl = true;
      _currentIsIdr = _currentIsIdr || type == 5;
      return;
    }

    if (_startsFollowingAccessUnit(type)) {
      if (_currentHasVcl) _emitCurrent(output);
      _cacheParameterSet(record, type);
      _pending.add(record);
      return;
    }

    if (type == 10 || type == 11) {
      if (_currentHasVcl) {
        _current.add(record);
        _emitCurrent(output);
      } else {
        _pending.add(record);
      }
      return;
    }

    if (_currentHasVcl) {
      _current.add(record);
    } else {
      _pending.add(record);
    }
  }

  void _cacheParameterSet(_NalRecord record, int type) {
    // Cache only after closing the preceding picture. Otherwise a parameter set
    // for the next picture could be injected into an earlier IDR.
    if (type == 7) {
      _cachedSps = record.bytes;
      final spsId = _tryReadSpsId(record.bytes);
      if (spsId != null) _spsById[spsId] = record.bytes;
    }
    if (type == 8) {
      _cachedPps = record.bytes;
      final ids = _tryReadPpsIds(record.bytes);
      if (ids != null) {
        _ppsById[ids.ppsId] = _CachedPps(record.bytes, ids.spsId);
      }
    }
  }

  void _beginCurrentIfNeeded() {
    if (_current.isNotEmpty) return;
    _current.addAll(_pending);
    _pending.clear();
  }

  void _emitCurrent(List<AccessUnit> output) {
    if (!_currentHasVcl) {
      _current.clear();
      return;
    }

    final outputNals = _current
        .map(
          (record) =>
              copyOutputNals ? Uint8List.fromList(record.bytes) : record.bytes,
        )
        .toList();
    if (prependCachedParameterSetsToIdr && _currentIsIdr) {
      final activePpsId = _current
          .where((record) => nalType(record.bytes) == 5)
          .map((record) => _tryReadSlicePpsId(record.bytes))
          .whereType<int>()
          .firstOrNull;
      final activePps = activePpsId == null ? null : _ppsById[activePpsId];
      final selectedPps = activePps?.nal ?? _cachedPps;
      final selectedSps = activePps == null
          ? _cachedSps
          : (_spsById[activePps.spsId] ?? _cachedSps);

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
      if (!hasSps && selectedSps != null) {
        prefix.add(
          copyOutputNals ? Uint8List.fromList(selectedSps) : selectedSps,
        );
      }
      if (!hasPps && selectedPps != null) {
        prefix.add(
          copyOutputNals ? Uint8List.fromList(selectedPps) : selectedPps,
        );
      }
      if (prefix.isNotEmpty) outputNals.insertAll(0, prefix);
    }

    int? sourceStart;
    int? sourceEnd;
    int? firstVcl;
    for (final record in _current) {
      sourceStart ??= record.startOffset;
      sourceEnd = record.endOffset ?? sourceEnd;
      if (firstVcl == null && _isVcl(nalType(record.bytes))) {
        firstVcl = record.startOffset ?? record.payloadOffset;
      }
    }

    output.add(
      AccessUnit(
        outputNals,
        isIdr: _currentIsIdr,
        sourceStartOffset: sourceStart,
        firstVclOffset: firstVcl,
        sourceEndOffset: sourceEnd,
      ),
    );
    _current.clear();
    _currentHasVcl = false;
    _currentIsIdr = false;
  }
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
