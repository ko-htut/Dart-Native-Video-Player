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

/// Fail-soft CAVLC: prefer keeping frame decode alive over hard-throwing.
const bool kCavlcStrict = false;

/// Non-spec recovery (table/context retries, run clamps) used only for
/// exploratory salvage. Disable to get deterministic first-failure alignment.
const bool kCavlcHeuristicRecovery = false;

/// Pack (totalCoeff, trailingOnes) into one int for VLC tables.
int _packCT(int totalCoeff, int trailingOnes) =>
    (totalCoeff << 2) | trailingOnes;
CoeffToken _unpackCT(int packed) => CoeffToken(packed >> 2, packed & 3);

class _CoeffTokenContext {
  final String name;
  final Map<String, int> byCode;
  final Set<String> prefixes;
  final int maxBits;

  const _CoeffTokenContext(this.name, this.byCode, this.prefixes, this.maxBits);
}

_CoeffTokenContext _buildCoeffTokenContext(
  String name,
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
  return _CoeffTokenContext(name, byCode, prefixes, maxBits);
}

final _ctCtxNC01 = _buildCoeffTokenContext('nc01', (r) => r.nc01);
final _ctCtxNC23 = _buildCoeffTokenContext('nc23', (r) => r.nc23);
final _ctCtxNC47 = _buildCoeffTokenContext('nc47', (r) => r.nc47);
final _ctCtxNC8P = _buildCoeffTokenContext('nc8p', (r) => r.nc8p);
final _ctCtxChromaDc = _buildCoeffTokenContext('chromaDc', (r) => r.chromaDc);

_CoeffTokenContext _selectCoeffTokenContext(int nC) {
  if (nC == -1) return _ctCtxChromaDc; // chroma_dc
  if (nC <= 1) return _ctCtxNC01;
  if (nC <= 3) return _ctCtxNC23;
  if (nC <= 7) return _ctCtxNC47;
  return _ctCtxNC8P;
}

CoeffToken _readCoeffTokenWithContext(
  BitReader br,
  int nC,
  _CoeffTokenContext ctx,
) {
  var code = '';
  var first16 = '';

  for (int i = 0; i < ctx.maxBits; i++) {
    if (br.eof) {
      if (first16.isNotEmpty) {
        coeffTokenDebugLog?.call(
          'coeff_token EOF nC=$nC table=${ctx.name} bits16=$first16 ctx=$coeffTokenDebugContext',
        );
      }
      throw StateError(
        'coeff_token unexpected EOF (nC=$nC, table=${ctx.name}, bits16=$first16, ctx=$coeffTokenDebugContext)',
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
        'coeff_token no match nC=$nC table=${ctx.name} bits16=$first16 prefix=$code ctx=$coeffTokenDebugContext',
      );
      throw StateError(
        'coeff_token no match (nC=$nC, table=${ctx.name}, bits16=$first16, prefix=$code, ctx=$coeffTokenDebugContext)',
      );
    }
  }

  coeffTokenDebugLog?.call(
    'coeff_token too long nC=$nC table=${ctx.name} bits16=$first16 prefix=$code ctx=$coeffTokenDebugContext',
  );
  throw StateError(
    'coeff_token too long (nC=$nC, table=${ctx.name}, bits16=$first16, ctx=$coeffTokenDebugContext)',
  );
}

bool _isCoeffTokenSemanticallyValid(CoeffToken token, int maxCoeff) {
  if (token.totalCoeff < 0 || token.totalCoeff > maxCoeff) return false;
  if (token.trailingOnes < 0 || token.trailingOnes > 3) return false;
  if (token.trailingOnes > token.totalCoeff) return false;
  return true;
}

List<_CoeffTokenContext> _coeffTokenContextsByPriority(int nC) {
  if (nC == -1) return <_CoeffTokenContext>[_ctCtxChromaDc];
  if (nC <= 1)
    return <_CoeffTokenContext>[_ctCtxNC01, _ctCtxNC23, _ctCtxNC47, _ctCtxNC8P];
  if (nC <= 3)
    return <_CoeffTokenContext>[_ctCtxNC23, _ctCtxNC01, _ctCtxNC47, _ctCtxNC8P];
  if (nC <= 7)
    return <_CoeffTokenContext>[_ctCtxNC47, _ctCtxNC23, _ctCtxNC01, _ctCtxNC8P];
  return <_CoeffTokenContext>[_ctCtxNC8P, _ctCtxNC47, _ctCtxNC23, _ctCtxNC01];
}

CoeffToken readCoeffToken(BitReader br, int nC, {required int maxCoeff}) {
  final selected = _selectCoeffTokenContext(nC);
  if (!kCavlcHeuristicRecovery) {
    final token = _readCoeffTokenWithContext(br, nC, selected);
    if (!_isCoeffTokenSemanticallyValid(token, maxCoeff)) {
      throw StateError(
        'coeff_token semantic invalid '
        '(tc=${token.totalCoeff}, t1=${token.trailingOnes}, nC=$nC, '
        'maxCoeff=$maxCoeff, table=${selected.name}, ctx=$coeffTokenDebugContext)',
      );
    }
    return token;
  }

  final candidates = _coeffTokenContextsByPriority(nC);
  final startPos = br.bitPos;
  StateError? lastError;

  for (int i = 0; i < candidates.length; i++) {
    final ctx = candidates[i];
    if (i > 0) {
      br.seekBit(startPos);
    }
    try {
      final token = _readCoeffTokenWithContext(br, nC, ctx);
      if (!_isCoeffTokenSemanticallyValid(token, maxCoeff)) {
        coeffTokenDebugLog?.call(
          'coeff_token semantic retry tc=${token.totalCoeff} t1=${token.trailingOnes} '
          'maxCoeff=$maxCoeff nC=$nC table=${ctx.name} ctx=$coeffTokenDebugContext',
        );
        continue;
      }
      if (ctx != selected) {
        coeffTokenDebugLog?.call(
          'coeff_token context fallback nC=$nC table=${selected.name}->${ctx.name} ctx=$coeffTokenDebugContext',
        );
      }
      return token;
    } on StateError catch (e) {
      lastError = e;
    }
  }

  br.seekBit(startPos);
  throw lastError ??
      StateError(
        'coeff_token decode failed (nC=$nC, maxCoeff=$maxCoeff, ctx=$coeffTokenDebugContext)',
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
  if (br.bitsLeft < n) {
    throw StateError('$field unexpected EOF');
  }
  return br.readBits(n);
}

int _readRunBefore(BitReader br, int zerosLeft) {
  if (zerosLeft <= 0) return 0;
  final t = _runTrees.putIfAbsent(
    zerosLeft,
    () => buildVlcTree(runBeforeTable[zerosLeft]!),
  );
  return readVlc(br, t);
}

int _readTotalZeros4x4(
  BitReader br,
  int totalCoeff,
  int maxCoeff, {
  int? tableTcOverride,
}) {
  if (totalCoeff == 0) return 0;
  // Spec table index is totalCoeff. Alternate table retries are handled by caller.
  final tableTc = tableTcOverride ?? totalCoeff;
  final Map<String, int>? m = totalZeros4x4[tableTc];
  if (m == null) {
    throw StateError(
      'missing total_zeros table for totalCoeff=$totalCoeff tableTc=$tableTc maxCoeff=$maxCoeff',
    );
  }
  final treeKey = (maxCoeff << 8) | tableTc;
  final t = _tz4x4Trees.putIfAbsent(treeKey, () => buildVlcTree(m));
  try {
    return readVlc(br, t);
  } on StateError catch (e) {
    throw StateError(
      'total_zeros decode failed: $e (totalCoeff=$totalCoeff startIdx=${maxCoeff == 15 ? 1 : 0} maxCoeff=$maxCoeff)',
    );
  }
}

int _readTotalZerosChromaDC(BitReader br, int totalCoeff) {
  if (totalCoeff == 0) return 0;
  final m = totalZerosChromaDC[totalCoeff];
  if (m == null) {
    throw StateError(
      'missing chroma_dc total_zeros table for totalCoeff=$totalCoeff',
    );
  }
  final t = _tzChrTrees.putIfAbsent(totalCoeff, () => buildVlcTree(m));
  return readVlc(br, t);
}

/// Read CAVLC coefficient levels using H.264 suffixLength transitions.
///
/// Returned order matches the residual placement loop in this file:
/// trailing ones first, then remaining levels in decode order.
List<int> readLevelsCavlc(BitReader br, int totalCoeff, int trailingOnes) {
  if (totalCoeff <= 0) return const <int>[];
  if (trailingOnes < 0 || trailingOnes > 3 || trailingOnes > totalCoeff) {
    throw StateError(
      'invalid trailingOnes: trailingOnes=$trailingOnes totalCoeff=$totalCoeff',
    );
  }
  final t1 = trailingOnes;

  final levels = <int>[];

  // 1) trailing_ones_sign_flag[i]
  for (int i = 0; i < t1; i++) {
    levels.add(_readBitChecked(br, 'trailing_ones_sign_flag') == 1 ? -1 : 1);
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

  // H.264 CAVLC level sign mapping:
  // even levelCode -> positive, odd levelCode -> negative.
  int toSigned(int levelCode) {
    final absVal = (levelCode + 2) >> 1;
    return (levelCode & 1) == 0 ? absVal : -absVal;
  }

  // H.264 initialization rule.
  int suffixLength = (totalCoeff > 10 && t1 < 3) ? 1 : 0;

  // Decode non-trailing coefficients exactly in spec order.
  for (int i = t1; i < totalCoeff; i++) {
    final prefix = readLevelPrefix();
    if (prefix > 31) {
      throw StateError('invalid level_prefix: $prefix');
    }

    int levelSuffixSize;
    if (prefix == 14 && suffixLength == 0) {
      levelSuffixSize = 4;
    } else if (prefix >= 15) {
      levelSuffixSize = prefix - 3;
    } else {
      levelSuffixSize = suffixLength;
    }
    final levelSuffix = levelSuffixSize > 0
        ? _readBitsChecked(br, levelSuffixSize, 'level_suffix')
        : 0;

    int levelCode = (prefix < 15 ? prefix : 15) << suffixLength;
    levelCode += levelSuffix;

    if (prefix == 15 && suffixLength == 0) {
      // 9.2.2 special-case offset for level_prefix==15, suffixLength==0.
      levelCode += 15;
    }

    if (prefix >= 16) {
      final suffixBits = prefix - 3;
      if (suffixBits < 0 || suffixBits > 28) {
        throw StateError(
          'invalid level_prefix: $prefix (suffixLength=$suffixLength)',
        );
      }
      levelCode += (1 << suffixBits) - 4096;
    }

    // First non-trailing coeff adjustment when trailingOnes < 3.
    if (i == t1 && t1 < 3) {
      levelCode += 2;
    }

    final level = toSigned(levelCode);
    levels.add(level);

    // H.264 suffixLength transition:
    // once suffixLength is non-zero, threshold is 3 << (suffixLength - 1).
    if (suffixLength == 0) {
      suffixLength = 1;
    }
    final threshold = 3 << (suffixLength - 1);
    if (suffixLength < 6 && level.abs() > threshold) {
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
  CoeffToken ct;
  try {
    ct = readCoeffToken(br, nC, maxCoeff: maxCoeff);
  } on StateError catch (e) {
    if (kCavlcStrict || !kCavlcHeuristicRecovery) rethrow;
    coeffTokenDebugLog?.call(
      'residual4x4 fallback all-zero (coeff_token failed: $e) '
      'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC ctx=$coeffTokenDebugContext',
    );
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
  }
  final int totalCoeff = ct.totalCoeff;
  final int trailingOnes = ct.trailingOnes;
  coeffTokenDebugLog?.call(
    'residual token tc=$totalCoeff t1=$trailingOnes '
    'nC=$nC startIdx=$startIdx maxCoeff=$maxCoeff ctx=$coeffTokenDebugContext',
  );

  if (totalCoeff <= 0) {
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
  }

  // Fail fast on impossible values (should never happen when table selection is correct).
  if (totalCoeff > maxCoeff || trailingOnes > totalCoeff) {
    throw StateError(
      'invalid coeff_token values: totalCoeff=$totalCoeff trailingOnes=$trailingOnes '
      'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC ctx=$coeffTokenDebugContext',
    );
  }

  List<int> levels;
  try {
    levels = readLevelsCavlc(br, totalCoeff, trailingOnes);
  } on StateError catch (e) {
    if (kCavlcStrict || !kCavlcHeuristicRecovery) rethrow;
    coeffTokenDebugLog?.call(
      'residual4x4 fallback all-zero (levels failed: $e) '
      'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC ctx=$coeffTokenDebugContext',
    );
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
  }
  if (levels.length != totalCoeff) {
    if (kCavlcStrict || !kCavlcHeuristicRecovery) {
      throw StateError(
        'residual levels size mismatch: levels=${levels.length} '
        'totalCoeff=$totalCoeff startIdx=$startIdx maxCoeff=$maxCoeff '
        'nC=$nC ctx=$coeffTokenDebugContext',
      );
    }
    coeffTokenDebugLog?.call(
      'residual4x4 fallback all-zero (levels size mismatch: ${levels.length}/$totalCoeff) '
      'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC ctx=$coeffTokenDebugContext',
    );
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
  }

  ({int totalZeros, List<int> runs, bool usedRunClamp}) parseTotalZerosAndRuns({
    int? tableTcOverride,
    bool allowRunClamp = false,
  }) {
    final tableTc = tableTcOverride ?? totalCoeff;
    int totalZeros = 0;
    final maxZeros = maxCoeff - totalCoeff;

    if (totalCoeff < maxCoeff) {
      try {
        totalZeros = _readTotalZeros4x4(
          br,
          totalCoeff,
          maxCoeff,
          tableTcOverride: tableTc,
        );
      } on StateError catch (e) {
        if (!allowRunClamp) {
          throw StateError(
            'total_zeros decode failed: $e (totalCoeff=$totalCoeff startIdx=$startIdx '
            'maxCoeff=$maxCoeff tableTc=$tableTc nC=$nC ctx=$coeffTokenDebugContext)',
          );
        }
        totalZeros = maxZeros;
        coeffTokenDebugLog?.call(
          'total_zeros fallback totalZeros=$totalZeros '
          '(decode failed: $e) totalCoeff=$totalCoeff startIdx=$startIdx '
          'maxCoeff=$maxCoeff tableTc=$tableTc nC=$nC ctx=$coeffTokenDebugContext',
        );
      }
      if (totalZeros < 0 || totalZeros > maxZeros) {
        if (!allowRunClamp) {
          throw StateError(
            'total_zeros out of range: totalZeros=$totalZeros maxZeros=$maxZeros '
            'totalCoeff=$totalCoeff startIdx=$startIdx maxCoeff=$maxCoeff tableTc=$tableTc nC=$nC '
            'ctx=$coeffTokenDebugContext',
          );
        }
        final raw = totalZeros;
        totalZeros = raw < 0 ? 0 : maxZeros;
        coeffTokenDebugLog?.call(
          'total_zeros clamp totalZeros=$raw -> $totalZeros '
          'totalCoeff=$totalCoeff startIdx=$startIdx maxCoeff=$maxCoeff tableTc=$tableTc nC=$nC '
          'ctx=$coeffTokenDebugContext',
        );
      }
    }

    int zerosLeft = totalZeros;
    final runs = List<int>.filled(totalCoeff, 0);
    bool usedRunClamp = false;
    for (int i = 0; i < totalCoeff - 1; i++) {
      if (zerosLeft <= 0) break;
      int runBeforeRaw;
      try {
        runBeforeRaw = _readRunBefore(br, zerosLeft);
      } on StateError catch (e) {
        if (!allowRunClamp) rethrow;
        runBeforeRaw = zerosLeft;
        usedRunClamp = true;
        coeffTokenDebugLog?.call(
          'run_before fallback run=$runBeforeRaw (decode failed: $e) '
          '(i=$i totalCoeff=$totalCoeff totalZeros=$totalZeros zerosLeft=$zerosLeft '
          'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC) ctx=$coeffTokenDebugContext',
        );
      }
      int runBefore = runBeforeRaw;
      if (runBeforeRaw < 0 || runBeforeRaw > zerosLeft) {
        if (allowRunClamp) {
          runBefore = runBeforeRaw < 0 ? 0 : zerosLeft;
          usedRunClamp = true;
          coeffTokenDebugLog?.call(
            'run_before clamp run=$runBeforeRaw -> $runBefore '
            '(i=$i totalCoeff=$totalCoeff totalZeros=$totalZeros zerosLeft=$zerosLeft '
            'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC) ctx=$coeffTokenDebugContext',
          );
        } else {
          throw StateError(
            'run_before out of range: run=$runBeforeRaw zerosLeft=$zerosLeft '
            '(i=$i totalCoeff=$totalCoeff totalZeros=$totalZeros startIdx=$startIdx '
            'maxCoeff=$maxCoeff tableTc=$tableTc nC=$nC ctx=$coeffTokenDebugContext)',
          );
        }
      }
      if (runBefore < 0 || runBefore > zerosLeft) {
        throw StateError(
          'run_before out of range: run=$runBefore zerosLeft=$zerosLeft '
          '(i=$i totalCoeff=$totalCoeff totalZeros=$totalZeros startIdx=$startIdx '
          'maxCoeff=$maxCoeff tableTc=$tableTc nC=$nC ctx=$coeffTokenDebugContext)',
        );
      }
      runs[i] = runBefore;
      zerosLeft -= runBefore;
    }
    runs[totalCoeff - 1] = zerosLeft;
    return (totalZeros: totalZeros, runs: runs, usedRunClamp: usedRunClamp);
  }

  final tzStartPos = br.bitPos;
  late List<int> runs;
  // Use table row indexed by totalCoeff as primary.
  final primaryTableTc = totalCoeff;
  final candidateTableTc = <int>[primaryTableTc];
  void addCandidate(int tc) {
    if (tc < 1 || tc > 15) return;
    if (!candidateTableTc.contains(tc)) candidateTableTc.add(tc);
  }

  // In strict alignment mode, keep table selection deterministic:
  // total_zeros row must match totalCoeff per spec.
  if (kCavlcHeuristicRecovery) {
    if (startIdx == 1 && maxCoeff == 15) {
      addCandidate(totalCoeff);
      addCandidate(totalCoeff + 1);
      addCandidate(totalCoeff - 1);
    }
    addCandidate(totalCoeff - 1);
    addCandidate(totalCoeff + 1);
  } else {
    addCandidate(totalCoeff);
  }

  bool parsedOk = false;
  StateError? primaryError;

  for (final tableTc in candidateTableTc) {
    br.seekBit(tzStartPos);
    try {
      final parsed = parseTotalZerosAndRuns(tableTcOverride: tableTc);
      runs = parsed.runs;
      if (tableTc != primaryTableTc) {
        coeffTokenDebugLog?.call(
          'total_zeros table fallback tableTc=$primaryTableTc->$tableTc '
          'totalCoeff=$totalCoeff startIdx=$startIdx maxCoeff=$maxCoeff '
          'ctx=$coeffTokenDebugContext',
        );
      }
      parsedOk = true;
      break;
    } on StateError catch (e) {
      primaryError ??= e;
    }
  }

  if (!parsedOk && kCavlcHeuristicRecovery) {
    for (final tableTc in candidateTableTc) {
      br.seekBit(tzStartPos);
      try {
        final parsed = parseTotalZerosAndRuns(
          tableTcOverride: tableTc,
          allowRunClamp: true,
        );
        runs = parsed.runs;
        if (tableTc != primaryTableTc) {
          coeffTokenDebugLog?.call(
            'total_zeros table fallback tableTc=$primaryTableTc->$tableTc '
            'totalCoeff=$totalCoeff startIdx=$startIdx maxCoeff=$maxCoeff '
            'ctx=$coeffTokenDebugContext',
          );
        }
        if (parsed.usedRunClamp) {
          coeffTokenDebugLog?.call(
            'run_before fallback clamp enabled totalCoeff=$totalCoeff '
            'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC ctx=$coeffTokenDebugContext',
          );
        }
        parsedOk = true;
        break;
      } on StateError catch (e) {
        primaryError ??= e;
      }
    }
  }

  if (!parsedOk) {
    br.seekBit(tzStartPos);
    final err =
        primaryError ??
        StateError(
          'failed to parse total_zeros/run_before '
          '(totalCoeff=$totalCoeff startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC '
          'ctx=$coeffTokenDebugContext)',
        );
    if (kCavlcStrict || !kCavlcHeuristicRecovery) throw err;
    coeffTokenDebugLog?.call(
      'residual4x4 fallback all-zero (decode failed: $err) '
      'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC ctx=$coeffTokenDebugContext',
    );
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
  }

  final out = List<int>.filled(16, 0);

  int coeffNum = -1;
  for (int i = totalCoeff - 1; i >= 0; i--) {
    coeffNum += runs[i] + 1;
    int scanIdx = startIdx + coeffNum;
    if (scanIdx < startIdx || scanIdx > maxCoeff || scanIdx >= 16) {
      final err = StateError(
        'residual coeffNum out of range: coeffNum=$coeffNum scanIdx=$scanIdx '
        'startIdx=$startIdx totalCoeff=$totalCoeff nC=$nC ctx=$coeffTokenDebugContext',
      );
      if (kCavlcStrict || !kCavlcHeuristicRecovery) throw err;
      coeffTokenDebugLog?.call(
        'residual4x4 fallback all-zero (decode failed: $err) '
        'startIdx=$startIdx maxCoeff=$maxCoeff nC=$nC ctx=$coeffTokenDebugContext',
      );
      return (coeffs: List<int>.filled(16, 0), totalCoeff: 0);
    }
    out[zigzag4x4[scanIdx]] = levels[i];
  }

  return (coeffs: out, totalCoeff: totalCoeff);
}

/// Decode full 4x4 residual block (startIdx=0, maxCoeff=16).
/// Returns coeffs in 4x4 raster order index (0..15), after zigzag placement.
({List<int> coeffs, int totalCoeff}) decodeResidual4x4(BitReader br, int nC) {
  return _decodeResidual4x4WithRange(br, nC, startIdx: 0, maxCoeff: 16);
}

/// Decode 4x4 AC-only residual block (startIdx=1, maxCoeff=15).
/// coeff[0] remains 0; AC terms are zigzag-placed at indices 1..15.
({List<int> coeffs, int totalCoeff}) decodeResidual4x4Ac(BitReader br, int nC) {
  return _decodeResidual4x4WithRange(br, nC, startIdx: 1, maxCoeff: 15);
}

/// Chroma DC 2x2 residual (CAVLC)
({List<int> coeffs4, int totalCoeff}) decodeChromaDC2x2(BitReader br) {
  final ct = readCoeffToken(br, -1, maxCoeff: 4);
  final totalCoeff = ct.totalCoeff;
  final trailingOnes = ct.trailingOnes;

  if (totalCoeff == 0) {
    return (coeffs4: List<int>.filled(4, 0), totalCoeff: 0);
  }
  if (totalCoeff < 0 || totalCoeff > 4) {
    throw StateError(
      'chroma_dc totalCoeff out of range: totalCoeff=$totalCoeff ctx=$coeffTokenDebugContext',
    );
  }
  if (trailingOnes < 0 || trailingOnes > 3 || trailingOnes > totalCoeff) {
    throw StateError(
      'chroma_dc trailingOnes out of range: trailingOnes=$trailingOnes totalCoeff=$totalCoeff '
      'ctx=$coeffTokenDebugContext',
    );
  }

  final levels = readLevelsCavlc(br, totalCoeff, trailingOnes);
  if (levels.length != totalCoeff) {
    throw StateError(
      'chroma_dc levels size mismatch: got=${levels.length} totalCoeff=$totalCoeff ctx=$coeffTokenDebugContext',
    );
  }

  int totalZeros = 0;
  if (totalCoeff < 4) {
    totalZeros = _readTotalZerosChromaDC(br, totalCoeff);
  }
  final maxZeros = 4 - totalCoeff;
  if (totalZeros < 0 || totalZeros > maxZeros) {
    throw StateError(
      'chroma_dc total_zeros out of range: totalZeros=$totalZeros maxZeros=$maxZeros '
      'totalCoeff=$totalCoeff ctx=$coeffTokenDebugContext',
    );
  }

  int zerosLeft = totalZeros;
  final runs = List<int>.filled(totalCoeff, 0);
  for (int i = 0; i < totalCoeff - 1; i++) {
    if (zerosLeft <= 0) break;
    final runBefore = _readRunBefore(br, zerosLeft);
    if (runBefore < 0 || runBefore > zerosLeft) {
      throw StateError(
        'chroma_dc run_before out of range: run=$runBefore zerosLeft=$zerosLeft '
        '(i=$i totalCoeff=$totalCoeff totalZeros=$totalZeros) ctx=$coeffTokenDebugContext',
      );
    }
    runs[i] = runBefore;
    zerosLeft -= runBefore;
  }
  runs[totalCoeff - 1] = zerosLeft;

  final scan = List<int>.filled(4, 0);
  int coeffNum = -1;
  for (int i = totalCoeff - 1; i >= 0; i--) {
    coeffNum += runs[i] + 1;
    if (coeffNum < 0 || coeffNum >= 4) {
      throw StateError(
        'chroma_dc coeffNum out of range: coeffNum=$coeffNum totalCoeff=$totalCoeff ctx=$coeffTokenDebugContext',
      );
    }
    scan[coeffNum] = levels[i];
  }

  final out = List<int>.filled(4, 0);
  for (int s = 0; s < 4; s++) {
    out[scan2x2[s]] = scan[s];
  }
  return (coeffs4: out, totalCoeff: totalCoeff);
}
