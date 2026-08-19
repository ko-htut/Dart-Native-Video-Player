// Minimal coeff_token VLC tables for CAVLC (Baseline).
// Each entry: (code as string, trailingOnes, totalCoeff)
//
// Source: H.264 spec style tables (simplified to common subsets).
// This is enough for many baseline streams but not all edge cases.
class CoeffTokenEntry {
  final String code;
  final int trailingOnes;
  final int totalCoeff;
  const CoeffTokenEntry(this.code, this.trailingOnes, this.totalCoeff);
}

// nC = 0..1
const coeffTokenNC01 = <CoeffTokenEntry>[
  CoeffTokenEntry('1', 0, 0),
  CoeffTokenEntry('01', 0, 1),
  CoeffTokenEntry('001', 1, 1),
  CoeffTokenEntry('0001', 0, 2),
  CoeffTokenEntry('00001', 1, 2),
  CoeffTokenEntry('000001', 2, 2),
  CoeffTokenEntry('0000001', 0, 3),
  CoeffTokenEntry('00000001', 1, 3),
  CoeffTokenEntry('000000001', 2, 3),
  CoeffTokenEntry('0000000001', 3, 3),
  // Extend as needed
];

// nC = 2..3
const coeffTokenNC23 = <CoeffTokenEntry>[
  CoeffTokenEntry('1', 0, 0),
  CoeffTokenEntry('01', 0, 1),
  CoeffTokenEntry('001', 1, 1),
  CoeffTokenEntry('0001', 0, 2),
  CoeffTokenEntry('00001', 1, 2),
  CoeffTokenEntry('000001', 2, 2),
  CoeffTokenEntry('0000001', 0, 3),
  CoeffTokenEntry('00000001', 1, 3),
  CoeffTokenEntry('000000001', 2, 3),
  CoeffTokenEntry('0000000001', 3, 3),
];

// nC = 4..7
const coeffTokenNC47 = <CoeffTokenEntry>[
  CoeffTokenEntry('1', 0, 0),
  CoeffTokenEntry('01', 0, 1),
  CoeffTokenEntry('001', 1, 1),
  CoeffTokenEntry('0001', 0, 2),
  CoeffTokenEntry('00001', 1, 2),
  CoeffTokenEntry('000001', 2, 2),
];

// nC >= 8
const coeffTokenNC8P = <CoeffTokenEntry>[
  CoeffTokenEntry('1', 0, 0),
  CoeffTokenEntry('01', 0, 1),
  CoeffTokenEntry('001', 1, 1),
  CoeffTokenEntry('0001', 0, 2),
];

// chromaDC (2x2)
const coeffTokenChromaDC = <CoeffTokenEntry>[
  CoeffTokenEntry('1', 0, 0),
  CoeffTokenEntry('01', 0, 1),
  CoeffTokenEntry('001', 1, 1),
  CoeffTokenEntry('0001', 0, 2),
  CoeffTokenEntry('00001', 1, 2),
];
