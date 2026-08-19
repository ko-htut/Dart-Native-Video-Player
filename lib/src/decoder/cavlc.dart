import 'bitreader.dart';
import 'cavlc_coeff_token_tables.dart';
import 'cavlc_runbefore_tables.dart';
import 'cavlc_totalzeros_tables.dart';
import 'scan.dart';
import 'vlc.dart';

/// The two values represented by a CAVLC `coeff_token`.
class CoeffToken {
  final int totalCoeff;
  final int trailingOnes;

  const CoeffToken(this.totalCoeff, this.trailingOnes);

  @override
  String toString() =>
      'CoeffToken(totalCoeff: $totalCoeff, trailingOnes: $trailingOnes)';
}

/// Compatibility result for the existing macroblock decoder.
///
/// A successful strict decode always has `desynced == false`. Malformed input
/// throws [BitstreamFormatException]; a damaged variable-length code is never
/// replaced with a guessed zero block.
typedef CavlcResidual4x4 = ({List<int> coeffs, int totalCoeff, bool desynced});

typedef CavlcChromaDc2x2 = ({List<int> coeffs4, int totalCoeff});

/// Optional diagnostics used by the frame decoder's trace mode.
void Function(String message)? coeffTokenDebugLog;
String coeffTokenDebugContext = '';

int _packCoeffToken(int totalCoeff, int trailingOnes) =>
    (totalCoeff << 2) | trailingOnes;

CoeffToken _unpackCoeffToken(int packed) => CoeffToken(packed >> 2, packed & 3);

class _CoeffTokenContext {
  final String name;
  final VlcNode tree;
  final int maxBits;

  const _CoeffTokenContext(this.name, this.tree, this.maxBits);
}

_CoeffTokenContext _buildCoeffTokenContext(
  String name,
  String? Function(CoeffTokenRow row) selectCode,
) {
  final codes = <String, int>{};
  var maxBits = 0;

  for (final row in coeffTokenRows) {
    final code = selectCode(row);
    if (code == null || code.isEmpty) continue;

    final previous = codes[code];
    final packed = _packCoeffToken(row.totalCoeff, row.trailingOnes);
    if (previous != null && previous != packed) {
      throw StateError(
        'duplicate $name coeff_token code "$code" for different values',
      );
    }
    codes[code] = packed;
    if (code.length > maxBits) maxBits = code.length;
  }

  return _CoeffTokenContext(name, buildVlcTree(codes), maxBits);
}

final _coeffTokenNc01 = _buildCoeffTokenContext('nC=0..1', (row) => row.nc01);
final _coeffTokenNc23 = _buildCoeffTokenContext('nC=2..3', (row) => row.nc23);
final _coeffTokenNc47 = _buildCoeffTokenContext('nC=4..7', (row) => row.nc47);
final _coeffTokenNc8Plus = _buildCoeffTokenContext(
  'nC=8..16',
  (row) => row.nc8p,
);
final _coeffTokenChromaDc = _buildCoeffTokenContext(
  'chroma DC 2x2',
  (row) => row.chromaDc,
);

final _totalZeros4x4Trees = <int, VlcNode>{};
final _totalZerosChromaDcTrees = <int, VlcNode>{};
final _runBeforeTrees = <int, VlcNode>{};

_CoeffTokenContext _selectCoeffTokenContext(int nC) {
  if (nC < -1 || nC > 16) {
    throw RangeError.range(nC, -1, 16, 'nC');
  }
  if (nC == -1) return _coeffTokenChromaDc;
  if (nC <= 1) return _coeffTokenNc01;
  if (nC <= 3) return _coeffTokenNc23;
  if (nC <= 7) return _coeffTokenNc47;
  return _coeffTokenNc8Plus;
}

Never _failCavlc(
  BitReader reader,
  String syntaxElement,
  String reason, {
  int? startBit,
}) {
  final context = coeffTokenDebugContext.isEmpty
      ? ''
      : ', context=$coeffTokenDebugContext';
  final start = startBit == null ? '' : ', startBit=$startBit';
  final error = BitstreamFormatException(
    '$syntaxElement: $reason$start$context',
    reader.bitPos,
  );
  coeffTokenDebugLog?.call(error.toString());
  throw error;
}

int _readSyntaxVlc(
  BitReader reader,
  VlcNode tree,
  String syntaxElement, {
  required int maxBits,
}) {
  final startBit = reader.bitPos;
  try {
    return readVlc(reader, tree, maxBits: maxBits);
  } on BitstreamFormatException catch (error) {
    _failCavlc(reader, syntaxElement, error.message, startBit: startBit);
  }
}

int _readSyntaxBits(BitReader reader, int count, String syntaxElement) {
  final startBit = reader.bitPos;
  try {
    return reader.readBits(count);
  } on BitstreamFormatException catch (error) {
    _failCavlc(reader, syntaxElement, error.message, startBit: startBit);
  }
}

/// Decodes `coeff_token` using exactly the table selected by [nC].
///
/// `nC == -1` selects the 4:2:0 chroma-DC table. Other supported values are
/// `0..16`. [maxCoeff] is the block's `maxNumCoeff` (4, 15, or 16 in the
/// decoder currently using this function).
CoeffToken readCoeffToken(BitReader reader, int nC, {required int maxCoeff}) {
  if (maxCoeff < 1 || maxCoeff > 16) {
    throw RangeError.range(maxCoeff, 1, 16, 'maxCoeff');
  }
  if (nC == -1 && maxCoeff != 4) {
    throw ArgumentError.value(
      maxCoeff,
      'maxCoeff',
      'must be 4 for the 4:2:0 chroma-DC coeff_token table',
    );
  }

  final context = _selectCoeffTokenContext(nC);
  final startBit = reader.bitPos;
  final packed = _readSyntaxVlc(
    reader,
    context.tree,
    'coeff_token (${context.name})',
    maxBits: context.maxBits,
  );
  final token = _unpackCoeffToken(packed);

  if (token.totalCoeff > maxCoeff ||
      token.trailingOnes > token.totalCoeff ||
      token.trailingOnes > 3) {
    _failCavlc(
      reader,
      'coeff_token',
      'decoded invalid values totalCoeff=${token.totalCoeff}, '
          'trailingOnes=${token.trailingOnes}, maxNumCoeff=$maxCoeff, nC=$nC',
      startBit: startBit,
    );
  }

  coeffTokenDebugLog?.call(
    'coeff_token totalCoeff=${token.totalCoeff} '
    'trailingOnes=${token.trailingOnes} nC=$nC '
    'table=${context.name} bits=${reader.bitPos - startBit} '
    '${coeffTokenDebugContext.isEmpty ? '' : 'context=$coeffTokenDebugContext'}',
  );
  return token;
}

int _readLevelPrefix(BitReader reader) {
  final startBit = reader.bitPos;
  var prefix = 0;
  while (true) {
    final bit = _readSyntaxBits(reader, 1, 'level_prefix');
    if (bit == 1) return prefix;

    prefix++;
    // H.264 level values supported by the syntax are bounded to a prefix of
    // 28. Larger prefixes would also require an unsafe, non-conforming escape.
    if (prefix > 28) {
      _failCavlc(
        reader,
        'level_prefix',
        'prefix exceeds 28',
        startBit: startBit,
      );
    }
  }
}

int _levelCodeToSigned(int levelCode) {
  final magnitude = (levelCode + 2) >> 1;
  return levelCode.isEven ? magnitude : -magnitude;
}

/// Decodes the level portion of a CAVLC residual block.
///
/// Values are returned in bitstream order: trailing-one levels first (highest
/// scan positions), followed by the remaining levels toward lower positions.
List<int> readLevelsCavlc(BitReader reader, int totalCoeff, int trailingOnes) {
  if (totalCoeff < 0 || totalCoeff > 16) {
    throw RangeError.range(totalCoeff, 0, 16, 'totalCoeff');
  }
  if (trailingOnes < 0 || trailingOnes > 3 || trailingOnes > totalCoeff) {
    throw RangeError.range(
      trailingOnes,
      0,
      totalCoeff < 3 ? totalCoeff : 3,
      'trailingOnes',
    );
  }
  if (totalCoeff == 0) return const <int>[];

  final levels = <int>[];
  for (var index = 0; index < trailingOnes; index++) {
    final sign = _readSyntaxBits(reader, 1, 'trailing_ones_sign_flag');
    levels.add(sign == 0 ? 1 : -1);
  }

  var suffixLength = totalCoeff > 10 && trailingOnes < 3 ? 1 : 0;
  for (var index = trailingOnes; index < totalCoeff; index++) {
    final levelPrefix = _readLevelPrefix(reader);

    final int levelSuffixSize;
    if (levelPrefix == 14 && suffixLength == 0) {
      levelSuffixSize = 4;
    } else if (levelPrefix >= 15) {
      levelSuffixSize = levelPrefix - 3;
    } else {
      levelSuffixSize = suffixLength;
    }

    final levelSuffix = levelSuffixSize == 0
        ? 0
        : _readSyntaxBits(reader, levelSuffixSize, 'level_suffix');

    var levelCode =
        ((levelPrefix < 15 ? levelPrefix : 15) << suffixLength) + levelSuffix;
    if (levelPrefix >= 15 && suffixLength == 0) {
      levelCode += 15;
    }
    if (levelPrefix >= 16) {
      levelCode += (1 << (levelPrefix - 3)) - 4096;
    }
    if (index == trailingOnes && trailingOnes < 3) {
      levelCode += 2;
    }

    final level = _levelCodeToSigned(levelCode);
    levels.add(level);

    if (suffixLength == 0) suffixLength = 1;
    if (suffixLength < 6 && level.abs() > (3 << (suffixLength - 1))) {
      suffixLength++;
    }
  }

  return levels;
}

int _readTotalZeros4x4(BitReader reader, int totalCoeff) {
  final table = totalZeros4x4[totalCoeff];
  if (table == null) {
    throw StateError('no 4x4 total_zeros table for TotalCoeff=$totalCoeff');
  }
  final tree = _totalZeros4x4Trees.putIfAbsent(
    totalCoeff,
    () => buildVlcTree(table),
  );
  final maxBits = table.keys.fold<int>(0, (max, code) {
    return code.length > max ? code.length : max;
  });
  return _readSyntaxVlc(
    reader,
    tree,
    'total_zeros (TotalCoeff=$totalCoeff)',
    maxBits: maxBits,
  );
}

int _readTotalZerosChromaDc(BitReader reader, int totalCoeff) {
  final table = totalZerosChromaDC[totalCoeff];
  if (table == null) {
    throw StateError(
      'no chroma-DC total_zeros table for TotalCoeff=$totalCoeff',
    );
  }
  final tree = _totalZerosChromaDcTrees.putIfAbsent(
    totalCoeff,
    () => buildVlcTree(table),
  );
  final maxBits = table.keys.fold<int>(0, (max, code) {
    return code.length > max ? code.length : max;
  });
  return _readSyntaxVlc(
    reader,
    tree,
    'chroma DC total_zeros (TotalCoeff=$totalCoeff)',
    maxBits: maxBits,
  );
}

int _readRunBefore(BitReader reader, int zerosLeft) {
  if (zerosLeft < 1 || zerosLeft > 15) {
    throw RangeError.range(zerosLeft, 1, 15, 'zerosLeft');
  }

  final tableIndex = zerosLeft < 7 ? zerosLeft : 7;
  final table = runBeforeTable[tableIndex];
  if (table == null) {
    throw StateError('no run_before table for zerosLeft=$zerosLeft');
  }
  final tree = _runBeforeTrees.putIfAbsent(
    tableIndex,
    () => buildVlcTree(table),
  );
  final maxBits = table.keys.fold<int>(0, (max, code) {
    return code.length > max ? code.length : max;
  });
  return _readSyntaxVlc(
    reader,
    tree,
    'run_before (zerosLeft=$zerosLeft)',
    maxBits: maxBits,
  );
}

List<int> _placeLevels({
  required BitReader reader,
  required List<int> levels,
  required int totalZeros,
  required int startIdx,
  required int maxNumCoeff,
  required List<int> scan,
  required int outputLength,
}) {
  final output = List<int>.filled(outputLength, 0);
  if (levels.isEmpty) return output;

  var zerosLeft = totalZeros;
  var coefficientIndex = totalZeros + levels.length - 1;

  void storeLevel(int levelIndex) {
    if (coefficientIndex < 0 || coefficientIndex >= maxNumCoeff) {
      _failCavlc(
        reader,
        'residual_block_cavlc',
        'coefficient index $coefficientIndex is outside '
            '0..${maxNumCoeff - 1}',
      );
    }
    final scanIndex = startIdx + coefficientIndex;
    if (scanIndex < 0 || scanIndex >= scan.length) {
      _failCavlc(
        reader,
        'residual_block_cavlc',
        'scan index $scanIndex is outside 0..${scan.length - 1}',
      );
    }
    output[scan[scanIndex]] = levels[levelIndex];
  }

  storeLevel(0);
  for (var levelIndex = 1; levelIndex < levels.length; levelIndex++) {
    var runBefore = 0;
    if (zerosLeft > 0) {
      runBefore = _readRunBefore(reader, zerosLeft);
      if (runBefore > zerosLeft) {
        _failCavlc(
          reader,
          'run_before',
          'decoded $runBefore with only $zerosLeft zeros left',
        );
      }
      zerosLeft -= runBefore;
    }

    coefficientIndex -= runBefore + 1;
    storeLevel(levelIndex);
  }

  if (coefficientIndex != zerosLeft) {
    _failCavlc(
      reader,
      'residual_block_cavlc',
      'inconsistent run placement: coefficientIndex=$coefficientIndex, '
          'zerosLeft=$zerosLeft',
    );
  }
  return output;
}

CavlcResidual4x4 _decodeResidual4x4(
  BitReader reader,
  int nC, {
  required int startIdx,
  required int maxNumCoeff,
}) {
  final token = readCoeffToken(reader, nC, maxCoeff: maxNumCoeff);
  if (token.totalCoeff == 0) {
    return (coeffs: List<int>.filled(16, 0), totalCoeff: 0, desynced: false);
  }

  final levels = readLevelsCavlc(reader, token.totalCoeff, token.trailingOnes);
  var totalZeros = 0;
  if (token.totalCoeff < maxNumCoeff) {
    totalZeros = _readTotalZeros4x4(reader, token.totalCoeff);
    final maxZeros = maxNumCoeff - token.totalCoeff;
    if (totalZeros > maxZeros) {
      _failCavlc(
        reader,
        'total_zeros',
        'decoded $totalZeros, maximum is $maxZeros for '
            'TotalCoeff=${token.totalCoeff}, maxNumCoeff=$maxNumCoeff',
      );
    }
  }

  final coefficients = _placeLevels(
    reader: reader,
    levels: levels,
    totalZeros: totalZeros,
    startIdx: startIdx,
    maxNumCoeff: maxNumCoeff,
    scan: zigzag4x4,
    outputLength: 16,
  );
  return (coeffs: coefficients, totalCoeff: token.totalCoeff, desynced: false);
}

/// Decodes a complete 4x4 residual block (`startIdx=0`, `maxNumCoeff=16`).
CavlcResidual4x4 decodeResidual4x4(BitReader reader, int nC) {
  return _decodeResidual4x4(reader, nC, startIdx: 0, maxNumCoeff: 16);
}

/// Decodes an Intra16x16 AC-only residual block.
///
/// `coeffs[0]` remains zero; the 15 AC coefficients use scan indices 1..15.
CavlcResidual4x4 decodeResidual4x4Ac(BitReader reader, int nC) {
  return _decodeResidual4x4(reader, nC, startIdx: 1, maxNumCoeff: 15);
}

/// Decodes a 4:2:0 chroma-DC 2x2 residual block.
CavlcChromaDc2x2 decodeChromaDC2x2(BitReader reader) {
  final token = readCoeffToken(reader, -1, maxCoeff: 4);
  if (token.totalCoeff == 0) {
    return (coeffs4: List<int>.filled(4, 0), totalCoeff: 0);
  }

  final levels = readLevelsCavlc(reader, token.totalCoeff, token.trailingOnes);
  var totalZeros = 0;
  if (token.totalCoeff < 4) {
    totalZeros = _readTotalZerosChromaDc(reader, token.totalCoeff);
    final maxZeros = 4 - token.totalCoeff;
    if (totalZeros > maxZeros) {
      _failCavlc(
        reader,
        'chroma DC total_zeros',
        'decoded $totalZeros, maximum is $maxZeros for '
            'TotalCoeff=${token.totalCoeff}',
      );
    }
  }

  final coefficients = _placeLevels(
    reader: reader,
    levels: levels,
    totalZeros: totalZeros,
    startIdx: 0,
    maxNumCoeff: 4,
    scan: scan2x2,
    outputLength: 4,
  );
  return (coeffs4: coefficients, totalCoeff: token.totalCoeff);
}
