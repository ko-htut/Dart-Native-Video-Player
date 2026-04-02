// H.264 CAVLC run_before VLC tables.
// Source: FFmpeg h264_cavlc.c run_len/run_bits.
// Mapping form used by decoder:
// runBeforeTable[zerosLeft] => {bitString -> runBefore}

String _bits(int code, int len) => code.toRadixString(2).padLeft(len, '0');

const List<List<int>> _runLen = <List<int>>[
  <int>[1, 1], // zerosLeft=1
  <int>[1, 2, 2], // zerosLeft=2
  <int>[2, 2, 2, 2], // zerosLeft=3
  <int>[2, 2, 2, 3, 3], // zerosLeft=4
  <int>[2, 2, 3, 3, 3, 3], // zerosLeft=5
  <int>[2, 3, 3, 3, 3, 3, 3], // zerosLeft=6
  // zerosLeft >= 7 use the extended VLC table:
  <int>[3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11], // runBefore=0..14
];

const List<List<int>> _runBits = <List<int>>[
  <int>[1, 0],
  <int>[1, 1, 0],
  <int>[3, 2, 1, 0],
  <int>[3, 2, 1, 1, 0],
  <int>[3, 2, 3, 2, 1, 0],
  <int>[3, 0, 1, 3, 2, 5, 4],
  <int>[7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1],
];

Map<String, int> _buildRow(int rowIndex) {
  final lens = _runLen[rowIndex];
  final bits = _runBits[rowIndex];
  final m = <String, int>{};
  for (int run = 0; run < lens.length; run++) {
    m[_bits(bits[run], lens[run])] = run;
  }
  return m;
}

Map<int, Map<String, int>> _buildRunBeforeTables() {
  final out = <int, Map<String, int>>{};

  for (int zerosLeft = 1; zerosLeft <= 6; zerosLeft++) {
    out[zerosLeft] = _buildRow(zerosLeft - 1);
  }

  final ge7 = _buildRow(6);
  for (int zerosLeft = 7; zerosLeft <= 15; zerosLeft++) {
    out[zerosLeft] = ge7;
  }

  return out;
}

final Map<int, Map<String, int>> runBeforeTable = _buildRunBeforeTables();
