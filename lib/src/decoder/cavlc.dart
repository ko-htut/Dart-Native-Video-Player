import 'bitreader.dart';
import 'vlc.dart';
import 'cavlc_totalzeros_tables.dart';
import 'cavlc_runbefore_tables.dart';
import 'cavlc_coeff_token_tables.dart';
import 'scan.dart';

class CoeffToken {
  final int totalCoeff;
  final int trailingOnes;
  const CoeffToken(this.totalCoeff, this.trailingOnes);
}

void Function(String message)? coeffTokenDebugLog;
String coeffTokenDebugContext = '';

/// Pack (totalCoeff, trailingOnes) into one int for VLC tables.
int _packCT(int totalCoeff, int trailingOnes) =>
    (totalCoeff << 2) | trailingOnes;
CoeffToken _unpackCT(int packed) => CoeffToken(packed >> 2, packed & 3);

class _CoeffTokenContext {
  final Map<String, int> byCode;
  final Set<String> prefixes;
  final int maxBits;

  const _CoeffTokenContext(this.byCode, this.prefixes, this.maxBits);
}

_CoeffTokenContext _buildCoeffTokenContext(
  String? Function(CoeffTokenRow row) pickCode,
) {
  final byCode = <String, int>{};
  final prefixes = <String>{};
  int maxBits = 0;

  for (final row in coeffTokenRows) {
    final bits = pickCode(row);
    if (bits == null || bits.isEmpty) continue;

    final packed = _packCT(row.totalCoeff, row.trailingOnes);
    final prev = byCode[bits];
    if (prev != null && prev != packed) {
      throw StateError(
        'Duplicate coeff_token code "$bits" with mismatched value',
      );
    }
    byCode[bits] = packed;

    if (bits.length > maxBits) maxBits = bits.length;
    for (int i = 1; i <= bits.length; i++) {
      prefixes.add(bits.substring(0, i));
    }
  }
  return _CoeffTokenContext(byCode, prefixes, maxBits);
}

final _ctCtxNC01 = _buildCoeffTokenContext((r) => r.nc01);
final _ctCtxNC23 = _buildCoeffTokenContext((r) => r.nc23);
final _ctCtxNC47 = _buildCoeffTokenContext((r) => r.nc47);
final _ctCtxNC8P = _buildCoeffTokenContext((r) => r.nc8p);
final _ctCtxChromaDc = _buildCoeffTokenContext((r) => r.chromaDc);

_CoeffTokenContext _selectCoeffTokenContext(int nC) {
  if (nC == -1) return _ctCtxChromaDc; // chroma_dc
  if (nC <= 1) return _ctCtxNC01;
  if (nC <= 3) return _ctCtxNC23;
  if (nC <= 7) return _ctCtxNC47;
  return _ctCtxNC8P;
}

CoeffToken readCoeffToken(BitReader br, int nC) {
  final ctx = _selectCoeffTokenContext(nC);

  var code = '';
  var first16 = '';

  for (int i = 0; i < ctx.maxBits; i++) {
    if (br.eof) {
      if (first16.isNotEmpty) {
        coeffTokenDebugLog?.call(
          'coeff_token EOF nC=$nC bits16=$first16 ctx=$coeffTokenDebugContext',
        );
      }
      throw StateError(
        'coeff_token unexpected EOF (nC=$nC, bits16=$first16, ctx=$coeffTokenDebugContext)',
      );
    }

    final bit = br.readBit();
    final ch = bit == 0 ? '0' : '1';
    code += ch;
    if (first16.length < 16) first16 += ch;

    final packed = ctx.byCode[code];
    if (packed != null) {
      return _unpackCT(packed);
    }

    if (!ctx.prefixes.contains(code)) {
      coeffTokenDebugLog?.call(
        'coeff_token no match nC=$nC bits16=$first16 prefix=$code ctx=$coeffTokenDebugContext',
      );
      throw StateError(
        'coeff_token no match (nC=$nC, bits16=$first16, prefix=$code, ctx=$coeffTokenDebugContext)',
      );
    }
  }

  coeffTokenDebugLog?.call(
    'coeff_token too long nC=$nC bits16=$first16 prefix=$code ctx=$coeffTokenDebugContext',
  );
  throw StateError(
    'coeff_token too long (nC=$nC, bits16=$first16, ctx=$coeffTokenDebugContext)',
  );
}

final _runTrees = <int, VlcNode>{};
final _tz4x4Trees = <int, VlcNode>{};
final _tzChrTrees = <int, VlcNode>{};

int _readBitChecked(BitReader br, String field) {
  if (br.eof) {
    throw StateError('$field unexpected EOF');
  }
  return br.readBit();
}

int _readBitsChecked(BitReader br, int n, String field) {
  if (n <= 0) return 0;
  int v = 0;
  for (int i = 0; i < n; i++) {
    v = (v << 1) | _readBitChecked(br, field);
  }
  return v;
}

int _readRunBefore(BitReader br, int zerosLeft) {
  if (zerosLeft <= 0) return 0;
  final t = _runTrees.putIfAbsent(
    zerosLeft,
    () => buildVlcTree(runBeforeTable[zerosLeft]!),
  );
  return readVlc(br, t);
}

int _readTotalZeros4x4(BitReader br, int totalCoeff) {
  if (totalCoeff == 0) return 0;
  final m = totalZeros4x4[totalCoeff] ?? const {'1': 0};
  final t = _tz4x4Trees.putIfAbsent(totalCoeff, () => buildVlcTree(m));
  return readVlc(br, t);
}

int _readTotalZerosChromaDC(BitReader br, int totalCoeff) {
  if (totalCoeff == 0) return 0;
  final m = totalZerosChromaDC[totalCoeff] ?? const {'1': 0};
  final t = _tzChrTrees.putIfAbsent(totalCoeff, () => buildVlcTree(m));
  return readVlc(br, t);
}

/// Read CAVLC coefficient levels using H.264 suffixLength transitions.
///
/// Returned order matches this file's run/zero placement code:
/// trailing ones first, then non-trailing levels in decode order.
List<int> readLevelsCavlc(BitReader br, int totalCoeff, int trailingOnes) {
  if (totalCoeff <= 0) return const <int>[];

  final t1 = trailingOnes < 0
      ? 0
      : (trailingOnes > 3
            ? 3
            : (trailingOnes > totalCoeff ? totalCoeff : trailingOnes));

  final levels = <int>[];

  // 1) trailing_ones_sign_flag[i]
  for (int i = 0; i < t1; i++) {
    levels.add(_readBitChecked(br, 'trailing_ones_sign_flag') == 1 ? -1 : 1);
  }

  if (t1 >= totalCoeff) {
    return levels;
  }

  int readLevelPrefix() {
    int prefix = 0;
    while (true) {
      final b = _readBitChecked(br, 'level_prefix');
      if (b == 1) return prefix;
      prefix++;
      if (prefix > 31) {
        throw StateError('level_prefix too large: $prefix');
      }
    }
  }

  int toSignedLevel(int levelCode) {
    return (levelCode & 1) == 0
        ? ((levelCode + 2) >> 1)
        : -((levelCode + 1) >> 1);
  }

  // 2) remaining levels (spec / ffmpeg-compatible):
  // - suffixLength init depends on totalCoeff/trailingOnes
  // - level_prefix cases: <14, ==14, >=15
  // - first non-trailing level gets +2 when trailingOnes < 3
  int suffixLength = (totalCoeff > 10 && t1 < 3) ? 1 : 0;
  for (int i = t1; i < totalCoeff; i++) {
    final prefix = readLevelPrefix();
    int levelSuffixSize;
    if (prefix == 14 && suffixLength == 0) {
      levelSuffixSize = 4;
    } else if (prefix >= 15) {
      levelSuffixSize = prefix - 3;
    } else {
      levelSuffixSize = suffixLength;
    }
    if (levelSuffixSize < 0 || levelSuffixSize > 28) {
      throw StateError(
        'invalid level_suffix size: $levelSuffixSize (prefix=$prefix suffixLength=$suffixLength)',
      );
    }

    final levelSuffix = levelSuffixSize > 0
        ? _readBitsChecked(br, levelSuffixSize, 'level_suffix')
        : 0;

    int levelCode;
    if (prefix == 15 && suffixLength == 0) {
      levelCode = 15 + levelSuffix;
    } else {
      levelCode = (prefix << suffixLength) + levelSuffix;
    }
    if (prefix >= 16) {
      levelCode += (1 << (prefix - 3)) - 4096;
    }

    if (i == t1 && t1 < 3) {
      levelCode += 2;
    }

    final level = toSignedLevel(levelCode);
    levels.add(level);

    if (suffixLength == 0) {
      suffixLength = 1;
    }
    if (suffixLength < 6 && level.abs() > (3 << (suffixLength - 1))) {
      suffixLength++;
    }
  }

  return levels;
}


({List<int> coeffs, int totalCoeff}) _decodeResidual4x4WithRange(
  BitReader br,
  int nC, {
  required int startIdx,
  required int maxCoeff,
}) {
  try {
    final ct = readCoeffToken(br, nC);
    final totalCoeff = ct.totalCoeff;
    final trailingOnes = ct.trailingOnes;

    if (totalCoeff == 0) {
      return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
    }
    if (totalCoeff < 0 || totalCoeff > maxCoeff) {
      throw StateError(
        'residual totalCoeff out of range: totalCoeff=$totalCoeff maxCoeff=$maxCoeff',
      );
    }
    if (trailingOnes < 0 || trailingOnes > 3 || trailingOnes > totalCoeff) {
      throw StateError(
        'residual trailingOnes invalid: trailingOnes=$trailingOnes totalCoeff=$totalCoeff',
      );
    }

    // --- levels ---
    final levels = readLevelsCavlc(br, totalCoeff, trailingOnes);
    if (levels.length < totalCoeff) {
      throw StateError(
        'residual levels truncated: got=${levels.length} totalCoeff=$totalCoeff',
      );
    }

    // --- zeros + runs ---
    // No total_zeros syntax when all coeffs in this range are non-zero.
    int totalZeros = totalCoeff < maxCoeff
        ? _readTotalZeros4x4(br, totalCoeff)
        : 0;
    final maxZeros = maxCoeff - totalCoeff;
    if (totalZeros < 0) totalZeros = 0;
    if (totalZeros > maxZeros) totalZeros = maxZeros;
    int zerosLeft = totalZeros;

    final runs = List<int>.filled(totalCoeff, 0);
    for (int i = 0; i < totalCoeff - 1; i++) {
      final r = _readRunBefore(br, zerosLeft);
      runs[i] = r;
      zerosLeft -= r;
      if (zerosLeft < 0) zerosLeft = 0;
    }
    runs[totalCoeff - 1] = zerosLeft;

    // --- place into scan positions ---
    // First create list in scan-order index (0..15)
    final scanCoeffs = List<int>.filled(16, 0);
    int coeffNum = -1;
    for (int i = totalCoeff - 1; i >= 0; i--) {
      coeffNum += runs[i] + 1;
      final scanIdx = startIdx + coeffNum;
      if (scanIdx < 0 || scanIdx >= 16) continue;
      scanCoeffs[scanIdx] = levels[i];
    }

    // Convert scan-order positions to raster indices using zigzag map
    final out = List<int>.filled(16, 0);
    for (int s = 0; s < 16; s++) {
      final rasterIdx = zigzag4x4[s];
      out[rasterIdx] = scanCoeffs[s];
    }

    return (coeffs: out, totalCoeff: totalCoeff);
  } on StateError catch (e) {
    coeffTokenDebugLog?.call(
      'residual fail-soft nC=$nC startIdx=$startIdx maxCoeff=$maxCoeff err=$e ctx=$coeffTokenDebugContext',
    );
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
  } on RangeError catch (e) {
    coeffTokenDebugLog?.call(
      'residual fail-soft range nC=$nC startIdx=$startIdx maxCoeff=$maxCoeff err=$e ctx=$coeffTokenDebugContext',
    );
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
  }
}

/// Decode full 4x4 residual block (startIdx=0, maxCoeff=16).
/// Returns coeffs in 4x4 raster order index (0..15), after zigzag placement.
({List<int> coeffs, int totalCoeff}) decodeResidual4x4(BitReader br, int nC) {
  return _decodeResidual4x4WithRange(
    br,
    nC,
    startIdx: 0,
    maxCoeff: 16,
  );
}

/// Decode 4x4 AC-only residual block (startIdx=1, maxCoeff=15).
/// coeff[0] remains 0; AC terms are zigzag-placed at indices 1..15.
({List<int> coeffs, int totalCoeff}) decodeResidual4x4Ac(BitReader br, int nC) {
  return _decodeResidual4x4WithRange(
    br,
    nC,
    startIdx: 1,
    maxCoeff: 15,
  );
}

/// Chroma DC 2x2 residual (CAVLC)
({List<int> coeffs4, int totalCoeff}) decodeChromaDC2x2(BitReader br) {
  try {
    final ct = readCoeffToken(br, -1);
    final totalCoeff = ct.totalCoeff;
    final trailingOnes = ct.trailingOnes;

    if (totalCoeff == 0) {
      return (coeffs4: List<int>.filled(4, 0), totalCoeff: 0);
    }
    if (totalCoeff < 0 || totalCoeff > 4) {
      throw StateError('chroma_dc totalCoeff out of range: $totalCoeff');
    }
    if (trailingOnes < 0 || trailingOnes > 3 || trailingOnes > totalCoeff) {
      throw StateError(
        'chroma_dc trailingOnes invalid: trailingOnes=$trailingOnes totalCoeff=$totalCoeff',
      );
    }

    final levels = readLevelsCavlc(br, totalCoeff, trailingOnes);
    if (levels.length < totalCoeff) {
      throw StateError(
        'chroma_dc levels truncated: got=${levels.length} totalCoeff=$totalCoeff',
      );
    }

    // No total_zeros syntax when all 4 chroma-DC coeffs are non-zero.
    final totalZeros = totalCoeff < 4
        ? _readTotalZerosChromaDC(br, totalCoeff)
        : 0;
    int zerosLeft = totalZeros;

    final runs = List<int>.filled(totalCoeff, 0);
    for (int i = 0; i < totalCoeff - 1; i++) {
      final r = _readRunBefore(br, zerosLeft);
      runs[i] = r;
      zerosLeft -= r;
      if (zerosLeft < 0) zerosLeft = 0;
    }
    runs[totalCoeff - 1] = zerosLeft;

    final scan = List<int>.filled(4, 0);
    int coeffNum = -1;
    for (int i = totalCoeff - 1; i >= 0; i--) {
      coeffNum += runs[i] + 1;
      if (coeffNum < 0 || coeffNum >= 4) continue;
      scan[coeffNum] = levels[i];
    }

    final out = List<int>.filled(4, 0);
    for (int s = 0; s < 4; s++) {
      out[scan2x2[s]] = scan[s];
    }

    return (coeffs4: out, totalCoeff: totalCoeff);
  } on StateError catch (e) {
    coeffTokenDebugLog?.call(
      'chroma_dc fail-soft err=$e ctx=$coeffTokenDebugContext',
    );
    return (coeffs4: List<int>.filled(4, 0), totalCoeff: 0);
  } on RangeError catch (e) {
    coeffTokenDebugLog?.call(
      'chroma_dc fail-soft range err=$e ctx=$coeffTokenDebugContext',
    );
    return (coeffs4: List<int>.filled(4, 0), totalCoeff: 0);
  }
}
