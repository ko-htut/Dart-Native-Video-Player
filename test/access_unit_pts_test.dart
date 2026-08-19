import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/access_unit_pts.dart';

Uint8List _slice(int type) => Uint8List.fromList(<int>[0x60 | type, 0x80]);

Uint8List _annexB(List<Uint8List> nals) {
  final bytes = <int>[];
  for (final nal in nals) {
    bytes.addAll(<int>[0, 0, 0, 1]);
    bytes.addAll(nal);
  }
  return Uint8List.fromList(bytes);
}

void main() {
  test('all-AU API associates each PES PTS with its own I/P picture', () {
    final first = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x67, 0x42]),
      Uint8List.fromList(<int>[0x68, 0xce]),
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(5),
    ]);
    final second = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1),
    ]);
    final third = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1),
    ]);

    final units = buildTimestampedAccessUnitsFromPtsChunks(
      ptsChunks: <PtsChunk>[
        PtsChunk(pts90k: 90000, payload: first),
        PtsChunk(pts90k: 93600, payload: second),
        PtsChunk(pts90k: 97200, payload: third),
      ],
      basePts90k: 90000,
    );

    expect(units, hasLength(3));
    expect(units.map((unit) => unit.ptsMs), <int>[0, 40, 80]);
    expect(units.map((unit) => unit.hasIdr), <bool>[true, false, false]);
    expect(units.first.isKeyframe, isTrue);
    expect(units.map((unit) => unit.pts90k), <int>[90000, 93600, 97200]);
  });

  test('PTS mapping survives a start code split across PES chunks', () {
    final firstAu = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(5),
    ]);
    final secondAu = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1),
    ]);
    final split = 2;

    final units = buildTimestampedAccessUnitsFromPtsChunks(
      ptsChunks: <PtsChunk>[
        PtsChunk(
          pts90k: 180000,
          payload: Uint8List.fromList(<int>[
            ...firstAu,
            ...secondAu.sublist(0, split),
          ]),
        ),
        PtsChunk(pts90k: 183600, payload: secondAu.sublist(split)),
      ],
      basePts90k: 180000,
    );

    expect(units, hasLength(2));
    expect(units.map((unit) => unit.ptsMs), <int>[0, 40]);
  });

  test('missing middle PTS is interpolated from neighboring PES anchors', () {
    final first = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(5),
    ]);
    final middle = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1),
    ]);
    final last = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1),
    ]);

    final units = buildTimestampedAccessUnitsFromPtsChunks(
      ptsChunks: <PtsChunk>[
        PtsChunk(
          pts90k: 0,
          payload: Uint8List.fromList(<int>[...first, ...middle]),
        ),
        PtsChunk(pts90k: 7200, payload: last),
      ],
      basePts90k: 0,
    );

    expect(units.map((unit) => unit.pts90k), <int>[0, 3600, 7200]);
    expect(units.map((unit) => unit.ptsMs), <int>[0, 40, 80]);
  });

  test('33-bit PTS rollover remains monotonic after normalization', () {
    const modulus = 1 << 33;
    final first = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(5),
    ]);
    final second = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1),
    ]);

    final units = buildTimestampedAccessUnitsFromPtsChunks(
      ptsChunks: <PtsChunk>[
        PtsChunk(pts90k: modulus - 1800, payload: first),
        PtsChunk(pts90k: 1800, payload: second),
      ],
      basePts90k: modulus - 1800,
    );

    expect(units.map((unit) => unit.ptsMs), <int>[0, 40]);
    expect(units[1].pts90k, modulus + 1800);
  });

  test('legacy IDR API filters but preserves the source PTS', () {
    final idr = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(5),
    ]);
    final predicted = _annexB(<Uint8List>[
      Uint8List.fromList(<int>[0x09, 0xf0]),
      _slice(1),
    ]);

    final units = buildTimestampedIdrAusFromPtsChunks(
      ptsChunks: <PtsChunk>[
        PtsChunk(pts90k: 90000, payload: idr),
        PtsChunk(pts90k: 93600, payload: predicted),
      ],
      basePts90k: 90000,
    );

    expect(units, hasLength(1));
    expect(units.single.hasIdr, isTrue);
    expect(units.single.pts90k, 90000);
  });
}
