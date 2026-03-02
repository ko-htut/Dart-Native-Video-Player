class CoeffTokenRow {
  final int totalCoeff;
  final int trailingOnes;
  final String nc01;
  final String nc23;
  final String nc47;
  final String nc8p;
  final String? chromaDc;

  const CoeffTokenRow({
    required this.totalCoeff,
    required this.trailingOnes,
    required this.nc01,
    required this.nc23,
    required this.nc47,
    required this.nc8p,
    this.chromaDc,
  });
}

String _bits(int code, int len) => code.toRadixString(2).padLeft(len, '0');

// FFmpeg h264_cavlc.c: coeff_token_len[4][4*17]
const List<int> _coeffTokenLenNc01 = <int>[
  1, 0, 0, 0,
  6, 2, 0, 0, 8, 6, 3, 0, 9, 8, 7, 5, 10, 9, 8, 6,
  11, 10, 9, 7, 13, 11, 10, 8, 13, 13, 11, 9, 13, 13, 13, 10,
  14, 14, 13, 11, 14, 14, 14, 13, 15, 15, 14, 14, 15, 15, 15, 14,
  16, 15, 15, 15, 16, 16, 16, 15, 16, 16, 16, 16, 16, 16, 16, 16,
];

const List<int> _coeffTokenLenNc23 = <int>[
  2, 0, 0, 0,
  6, 2, 0, 0, 6, 5, 3, 0, 7, 6, 6, 4, 8, 6, 6, 4,
  8, 7, 7, 5, 9, 8, 8, 6, 11, 9, 9, 6, 11, 11, 11, 7,
  12, 11, 11, 9, 12, 12, 12, 11, 12, 12, 12, 11, 13, 13, 13, 12,
  13, 13, 13, 13, 13, 14, 13, 13, 14, 14, 14, 13, 14, 14, 14, 14,
];

const List<int> _coeffTokenLenNc47 = <int>[
  4, 0, 0, 0,
  6, 4, 0, 0, 6, 5, 4, 0, 6, 5, 5, 4, 7, 5, 5, 4,
  7, 5, 5, 4, 7, 6, 6, 4, 7, 6, 6, 4, 8, 7, 7, 5,
  8, 8, 7, 6, 9, 8, 8, 7, 9, 9, 8, 8, 9, 9, 9, 8,
  10, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
];

const List<int> _coeffTokenLenNc8p = <int>[
  6, 0, 0, 0,
  6, 6, 0, 0, 6, 6, 6, 0, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
];

// FFmpeg h264_cavlc.c: coeff_token_bits[4][4*17]
const List<int> _coeffTokenBitsNc01 = <int>[
  1, 0, 0, 0,
  5, 1, 0, 0, 7, 4, 1, 0, 7, 6, 5, 3, 7, 6, 5, 3,
  7, 6, 5, 4, 15, 6, 5, 4, 11, 14, 5, 4, 8, 10, 13, 4,
  15, 14, 9, 4, 11, 10, 13, 12, 15, 14, 9, 12, 11, 10, 13, 8,
  15, 1, 9, 12, 11, 14, 13, 8, 7, 10, 9, 12, 4, 6, 5, 8,
];

const List<int> _coeffTokenBitsNc23 = <int>[
  3, 0, 0, 0,
  11, 2, 0, 0, 7, 7, 3, 0, 7, 10, 9, 5, 7, 6, 5, 4,
  4, 6, 5, 6, 7, 6, 5, 8, 15, 6, 5, 4, 11, 14, 13, 4,
  15, 10, 9, 4, 11, 14, 13, 12, 8, 10, 9, 8, 15, 14, 13, 12,
  11, 10, 9, 12, 7, 11, 6, 8, 9, 8, 10, 1, 7, 6, 5, 4,
];

const List<int> _coeffTokenBitsNc47 = <int>[
  15, 0, 0, 0,
  15, 14, 0, 0, 11, 15, 13, 0, 8, 12, 14, 12, 15, 10, 11, 11,
  11, 8, 9, 10, 9, 14, 13, 9, 8, 10, 9, 8, 15, 14, 13, 13,
  11, 14, 10, 12, 15, 10, 13, 12, 11, 14, 9, 12, 8, 10, 13, 8,
  13, 7, 9, 12, 9, 12, 11, 10, 5, 8, 7, 6, 1, 4, 3, 2,
];

const List<int> _coeffTokenBitsNc8p = <int>[
  3, 0, 0, 0,
  0, 1, 0, 0, 4, 5, 6, 0, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
  48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
];

// FFmpeg h264_cavlc.c: chroma_dc_coeff_token_len/bits [4*5]
const List<int> _chromaDcCoeffTokenLen = <int>[
  2, 0, 0, 0,
  6, 1, 0, 0,
  6, 6, 3, 0,
  6, 7, 7, 6,
  6, 8, 8, 7,
];

const List<int> _chromaDcCoeffTokenBits = <int>[
  1, 0, 0, 0,
  7, 1, 0, 0,
  4, 6, 1, 0,
  3, 3, 2, 5,
  2, 3, 2, 0,
];

String _codeAt(List<int> len, List<int> bits, int tc, int t1) {
  final idx = tc * 4 + t1;
  if (idx < 0 || idx >= len.length || idx >= bits.length) return '';
  final l = len[idx];
  if (l <= 0) return '';
  return _bits(bits[idx], l);
}

String? _chromaCodeAt(int tc, int t1) {
  final idx = tc * 4 + t1;
  if (idx < 0 || idx >= _chromaDcCoeffTokenLen.length) return null;
  final l = _chromaDcCoeffTokenLen[idx];
  if (l <= 0) return null;
  return _bits(_chromaDcCoeffTokenBits[idx], l);
}

List<CoeffTokenRow> _buildCoeffTokenRows() {
  final out = <CoeffTokenRow>[];
  for (int tc = 0; tc <= 16; tc++) {
    for (int t1 = 0; t1 <= 3; t1++) {
      final nc01 = _codeAt(_coeffTokenLenNc01, _coeffTokenBitsNc01, tc, t1);
      final nc23 = _codeAt(_coeffTokenLenNc23, _coeffTokenBitsNc23, tc, t1);
      final nc47 = _codeAt(_coeffTokenLenNc47, _coeffTokenBitsNc47, tc, t1);
      final nc8p = _codeAt(_coeffTokenLenNc8p, _coeffTokenBitsNc8p, tc, t1);
      final chroma = tc <= 4 ? _chromaCodeAt(tc, t1) : null;

      if (nc01.isEmpty && nc23.isEmpty && nc47.isEmpty && nc8p.isEmpty && chroma == null) {
        continue;
      }

      out.add(
        CoeffTokenRow(
          totalCoeff: tc,
          trailingOnes: t1,
          nc01: nc01,
          nc23: nc23,
          nc47: nc47,
          nc8p: nc8p,
          chromaDc: chroma,
        ),
      );
    }
  }
  return out;
}

final List<CoeffTokenRow> coeffTokenRows = _buildCoeffTokenRows();
