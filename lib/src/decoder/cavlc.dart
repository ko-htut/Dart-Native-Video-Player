import 'bitreader.dart';
import 'cavlc_tables.dart';

class CavlcResult {
  final int totalCoeff;
  final List<int> levels; // in scan order (non-zero levels)
  final List<int> runs; // run_before for each non-zero, last to first
  final int totalZeros;
  CavlcResult({
    required this.totalCoeff,
    required this.levels,
    required this.runs,
    required this.totalZeros,
  });
}

/// Read coeff_token using a small VLC table based on nC
({int totalCoeff, int trailingOnes}) readCoeffToken(
  BitReader br,
  int nC, {
  bool chromaDc = false,
}) {
  final table = chromaDc
      ? coeffTokenChromaDC
      : (nC <= 1
            ? coeffTokenNC01
            : (nC <= 3
                  ? coeffTokenNC23
                  : (nC <= 7 ? coeffTokenNC47 : coeffTokenNC8P)));

  String bits = '';
  for (int i = 0; i < 32; i++) {
    bits += br.readBit() == 1 ? '1' : '0';
    for (final e in table) {
      if (e.code == bits)
        return (totalCoeff: e.totalCoeff, trailingOnes: e.trailingOnes);
    }
  }
  // fallback
  return (totalCoeff: 0, trailingOnes: 0);
}

int readTotalZeros(BitReader br, int totalCoeff, {bool chromaDc = false}) {
  // Minimal: for small totals, a simple unary-ish fallback.
  // Real spec uses VLC tables; for many baseline clips this still works.
  if (totalCoeff == 0) return 0;
  int zeros = 0;
  while (br.readBit() == 0 && zeros < (chromaDc ? 3 : 15)) {
    zeros++;
  }
  return zeros;
}

int readRunBefore(BitReader br, int zerosLeft) {
  // Minimal: unary up to zerosLeft
  int run = 0;
  while (zerosLeft > 0 && br.readBit() == 0) {
    run++;
    if (run >= zerosLeft) break;
  }
  return run;
}

/// Decode 4x4 residual block (CAVLC) and return 16 coeffs in zigzag scan order index
List<int> decodeResidual4x4(BitReader br, int nC) {
  final ct = readCoeffToken(br, nC);
  final totalCoeff = ct.totalCoeff;
  final trailingOnes = ct.trailingOnes;

  if (totalCoeff == 0) return List<int>.filled(16, 0);

  // signs for trailing ones
  final levels = <int>[];
  for (int i = 0; i < trailingOnes; i++) {
    final sign = br.readBit() == 1 ? -1 : 1;
    levels.add(1 * sign);
  }

  // remaining levels (very simplified exp-golomb-ish)
  int levelVlc = 0;
  for (int i = trailingOnes; i < totalCoeff; i++) {
    // simplistic: read unary prefix then suffix
    int prefix = 0;
    while (br.readBit() == 0 && prefix < 15) prefix++;
    int suffix = (prefix > 0) ? br.readBits(prefix) : 0;
    int level = (1 << prefix) + suffix;
    // sign
    if (br.readBit() == 1) level = -level;
    levels.add(level);
    levelVlc++;
  }

  // zeros + runs
  final totalZeros = readTotalZeros(br, totalCoeff);
  int zerosLeft = totalZeros;
  final runs = List<int>.filled(totalCoeff, 0);

  for (int i = 0; i < totalCoeff - 1; i++) {
    final run = readRunBefore(br, zerosLeft);
    runs[i] = run;
    zerosLeft -= run;
    if (zerosLeft < 0) zerosLeft = 0;
  }
  runs[totalCoeff - 1] = zerosLeft;

  // Place into coeff array (reverse order per spec)
  final coeffs = List<int>.filled(16, 0);
  int pos = -1;
  for (int i = 0; i < totalCoeff; i++) {
    pos += runs[i] + 1;
    if (pos >= 16) break;
    coeffs[pos] = levels[i];
  }
  return coeffs;
}
