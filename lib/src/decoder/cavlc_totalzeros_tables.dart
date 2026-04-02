// Full H.264 CAVLC total_zeros VLC tables (luma 4x4 + chroma DC 2x2).
// Source layout matches FFmpeg h264_cavlc.c (total_zeros_len/bits).
//
// Mapping form used by decoder:
// totalZeros4x4[totalCoeff] => {bitString -> totalZeros}
// totalZerosChromaDC[totalCoeff] => {bitString -> totalZeros}

String _bits(int code, int size) => code.toRadixString(2).padLeft(size, '0');

final Map<int, Map<String, int>> totalZeros4x4 = _buildTotalZeros4x4();
final Map<int, Map<String, int>> totalZerosChromaDC =
    _buildTotalZerosChromaDc();

Map<int, Map<String, int>> _buildTotalZeros4x4() {
  const totalZerosLen = <List<int>>[
    [1, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9], // totalCoeff=1
    [3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6], // totalCoeff=2
    [4, 3, 3, 3, 4, 4, 3, 3, 4, 5, 5, 6, 5, 6], // totalCoeff=3
    [5, 3, 4, 4, 3, 3, 3, 4, 3, 4, 5, 5, 5], // totalCoeff=4
    [4, 4, 4, 3, 3, 3, 3, 3, 4, 5, 4, 5], // totalCoeff=5
    [6, 5, 3, 3, 3, 3, 3, 3, 4, 3, 6], // totalCoeff=6
    [6, 5, 3, 3, 3, 2, 3, 4, 3, 6], // totalCoeff=7
    [6, 4, 5, 3, 2, 2, 3, 3, 6], // totalCoeff=8
    [6, 6, 4, 2, 2, 3, 2, 5], // totalCoeff=9
    [5, 5, 3, 2, 2, 2, 4], // totalCoeff=10
    [4, 4, 3, 3, 1, 3], // totalCoeff=11
    [4, 4, 2, 1, 3], // totalCoeff=12
    [3, 3, 1, 2], // totalCoeff=13
    [2, 2, 1], // totalCoeff=14
    [1, 1], // totalCoeff=15
  ];

  const totalZerosBits = <List<int>>[
    [1, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 1], // totalCoeff=1
    [7, 6, 5, 4, 3, 5, 4, 3, 2, 3, 2, 3, 2, 1, 0], // totalCoeff=2
    [5, 7, 6, 5, 4, 3, 4, 3, 2, 3, 2, 1, 1, 0], // totalCoeff=3
    [3, 7, 5, 4, 6, 5, 4, 3, 3, 2, 2, 1, 0], // totalCoeff=4
    [5, 4, 3, 7, 6, 5, 4, 3, 2, 1, 1, 0], // totalCoeff=5
    [1, 1, 7, 6, 5, 4, 3, 2, 1, 1, 0], // totalCoeff=6
    [1, 1, 5, 4, 3, 3, 2, 1, 1, 0], // totalCoeff=7
    [1, 1, 1, 3, 3, 2, 2, 1, 0], // totalCoeff=8
    [1, 0, 1, 3, 2, 1, 1, 1], // totalCoeff=9
    [1, 0, 1, 3, 2, 1, 1], // totalCoeff=10
    [0, 1, 1, 2, 1, 3], // totalCoeff=11
    [0, 1, 1, 1, 1], // totalCoeff=12
    [0, 1, 1, 1], // totalCoeff=13
    [0, 1, 1], // totalCoeff=14
    [0, 1], // totalCoeff=15
  ];

  final out = <int, Map<String, int>>{};
  for (int tc = 1; tc <= 15; tc++) {
    final lens = totalZerosLen[tc - 1];
    final bits = totalZerosBits[tc - 1];
    final m = <String, int>{};
    for (int tz = 0; tz < lens.length; tz++) {
      m[_bits(bits[tz], lens[tz])] = tz;
    }
    out[tc] = m;
  }
  return out;
}

Map<int, Map<String, int>> _buildTotalZerosChromaDc() {
  const chromaDcTotalZerosLen = <List<int>>[
    [1, 2, 3, 3], // totalCoeff=1
    [1, 2, 2], // totalCoeff=2
    [1, 1], // totalCoeff=3
  ];
  const chromaDcTotalZerosBits = <List<int>>[
    [1, 1, 1, 0], // totalCoeff=1
    [1, 1, 0], // totalCoeff=2
    [1, 0], // totalCoeff=3
  ];

  final out = <int, Map<String, int>>{};
  for (int tc = 1; tc <= 3; tc++) {
    final lens = chromaDcTotalZerosLen[tc - 1];
    final bits = chromaDcTotalZerosBits[tc - 1];
    final m = <String, int>{};
    for (int tz = 0; tz < lens.length; tz++) {
      m[_bits(bits[tz], lens[tz])] = tz;
    }
    out[tc] = m;
  }
  return out;
}
