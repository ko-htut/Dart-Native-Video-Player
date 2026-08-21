import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/intra8x8_pred.dart';

const _top = <int>[
  12,
  37,
  89,
  6,
  201,
  55,
  144,
  233,
  17,
  99,
  181,
  42,
  215,
  8,
  76,
  160,
];
const _left = <int>[244, 31, 122, 7, 198, 66, 155, 23];

void main() {
  group('H.264 Intra_8x8 reference filtering', () {
    test('matches the section 8.3.2.2.1 defining equations', () {
      final references = filterIntra8x8References(
        top: _top,
        left: _left,
        topLeft: 111,
      );

      expect(references.top, <int>[
        43,
        44,
        55,
        76,
        116,
        114,
        144,
        157,
        92,
        99,
        126,
        120,
        120,
        77,
        80,
        139,
      ]);
      expect(references.left, <int>[158, 107, 71, 84, 117, 121, 100, 56]);
      expect(references.topLeft, 120);
      expect(references.topAvailable, isTrue);
      expect(references.leftAvailable, isTrue);
      expect(references.topLeftAvailable, isTrue);
      expect(() => references.top[0] = 0, throwsUnsupportedError);
      expect(() => references.left[0] = 0, throwsUnsupportedError);
    });

    test('substitutes the last top sample when top-right is unavailable', () {
      final references = filterIntra8x8References(
        top: const <int>[10, 20, 30, 40, 50, 60, 70, 80],
        left: _left,
        topLeft: 40,
        topRightAvailable: false,
      );

      expect(references.top, <int>[
        20,
        20,
        30,
        40,
        50,
        60,
        70,
        78,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
      ]);
    });

    test('validates reference lengths and explicit top-right availability', () {
      expect(
        () => filterIntra8x8References(
          top: List<int>.filled(7, 0),
          left: _left,
          topLeft: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => filterIntra8x8References(
          top: _top,
          left: List<int>.filled(7, 0),
          topLeft: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => filterIntra8x8References(
          top: List<int>.filled(8, 0),
          left: _left,
          topLeft: 0,
          topRightAvailable: true,
        ),
        throwsArgumentError,
      );
    });
  });

  group('H.264 Intra_8x8 luma prediction', () {
    test('vertical, horizontal, and DC use filtered references', () {
      expect(_predict(0), <int>[
        for (var row = 0; row < 8; row++) ...<int>[
          43,
          44,
          55,
          76,
          116,
          114,
          144,
          157,
        ],
      ]);
      expect(_predict(1), <int>[
        for (final value in <int>[158, 107, 71, 84, 117, 121, 100, 56])
          ...List<int>.filled(8, value),
      ]);
      expect(_predict(2), List<int>.filled(64, 98));
    });

    test('six directional modes match libavc reference goldens', () {
      for (final entry in _directionalGoldens.entries) {
        expect(
          _predict(entry.key),
          entry.value.expand((row) => row).toList(),
          reason: 'Intra_8x8 mode ${entry.key}',
        );
      }
    });

    test('DC covers each neighbour-availability branch', () {
      expect(_predict(2, leftAvailable: false), List<int>.filled(64, 94));
      expect(_predict(2, topAvailable: false), List<int>.filled(64, 102));
      expect(
        _predict(2, topAvailable: false, leftAvailable: false),
        List<int>.filled(64, 128),
      );
    });

    test(
      'unavailable directional input and invalid mode conceal deterministically',
      () {
        expect(_predict(3, topAvailable: false), List<int>.filled(64, 128));
        expect(_predict(4, topLeftAvailable: false), List<int>.filled(64, 128));
        expect(_predict(8, leftAvailable: false), List<int>.filled(64, 128));
        expect(_predict(99), List<int>.filled(64, 128));
      },
    );

    test('requires a complete output block', () {
      expect(
        () => predictIntra8x8(
          mode: 0,
          top: _top,
          left: _left,
          topLeft: 111,
          out: List<int>.filled(63, 0),
        ),
        throwsArgumentError,
      );
    });
  });
}

List<int> _predict(
  int mode, {
  bool topAvailable = true,
  bool leftAvailable = true,
  bool topLeftAvailable = true,
}) {
  final output = List<int>.filled(64, 0);
  predictIntra8x8(
    mode: mode,
    top: _top,
    left: _left,
    topLeft: 111,
    out: output,
    topAvailable: topAvailable,
    leftAvailable: leftAvailable,
    topLeftAvailable: topLeftAvailable,
  );
  return output;
}

const _directionalGoldens = <int, List<List<int>>>{
  3: <List<int>>[
    <int>[47, 58, 81, 106, 122, 140, 138, 110],
    <int>[58, 81, 106, 122, 140, 138, 110, 104],
    <int>[81, 106, 122, 140, 138, 110, 104, 118],
    <int>[106, 122, 140, 138, 110, 104, 118, 122],
    <int>[122, 140, 138, 110, 104, 118, 122, 109],
    <int>[140, 138, 110, 104, 118, 122, 109, 89],
    <int>[138, 110, 104, 118, 122, 109, 89, 94],
    <int>[110, 104, 118, 122, 109, 89, 94, 124],
  ],
  4: <List<int>>[
    <int>[110, 63, 47, 58, 81, 106, 122, 140],
    <int>[136, 110, 63, 47, 58, 81, 106, 122],
    <int>[111, 136, 110, 63, 47, 58, 81, 106],
    <int>[83, 111, 136, 110, 63, 47, 58, 81],
    <int>[89, 83, 111, 136, 110, 63, 47, 58],
    <int>[110, 89, 83, 111, 136, 110, 63, 47],
    <int>[115, 110, 89, 83, 111, 136, 110, 63],
    <int>[94, 115, 110, 89, 83, 111, 136, 110],
  ],
  5: <List<int>>[
    <int>[82, 44, 50, 66, 96, 115, 129, 151],
    <int>[110, 63, 47, 58, 81, 106, 122, 140],
    <int>[136, 82, 44, 50, 66, 96, 115, 129],
    <int>[111, 110, 63, 47, 58, 81, 106, 122],
    <int>[83, 136, 82, 44, 50, 66, 96, 115],
    <int>[89, 111, 110, 63, 47, 58, 81, 106],
    <int>[110, 83, 136, 82, 44, 50, 66, 96],
    <int>[115, 89, 111, 110, 63, 47, 58, 81],
  ],
  6: <List<int>>[
    <int>[139, 110, 63, 47, 58, 81, 106, 122],
    <int>[133, 136, 139, 110, 63, 47, 58, 81],
    <int>[89, 111, 133, 136, 139, 110, 63, 47],
    <int>[78, 83, 89, 111, 133, 136, 139, 110],
    <int>[101, 89, 78, 83, 89, 111, 133, 136],
    <int>[119, 110, 101, 89, 78, 83, 89, 111],
    <int>[111, 115, 119, 110, 101, 89, 78, 83],
    <int>[78, 94, 111, 115, 119, 110, 101, 89],
  ],
  7: <List<int>>[
    <int>[44, 50, 66, 96, 115, 129, 151, 125],
    <int>[47, 58, 81, 106, 122, 140, 138, 110],
    <int>[50, 66, 96, 115, 129, 151, 125, 96],
    <int>[58, 81, 106, 122, 140, 138, 110, 104],
    <int>[66, 96, 115, 129, 151, 125, 96, 113],
    <int>[81, 106, 122, 140, 138, 110, 104, 118],
    <int>[96, 115, 129, 151, 125, 96, 113, 123],
    <int>[106, 122, 140, 138, 110, 104, 118, 122],
  ],
  8: <List<int>>[
    <int>[133, 111, 89, 83, 78, 89, 101, 110],
    <int>[89, 83, 78, 89, 101, 110, 119, 115],
    <int>[78, 89, 101, 110, 119, 115, 111, 94],
    <int>[101, 110, 119, 115, 111, 94, 78, 67],
    <int>[119, 115, 111, 94, 78, 67, 56, 56],
    <int>[111, 94, 78, 67, 56, 56, 56, 56],
    <int>[78, 67, 56, 56, 56, 56, 56, 56],
    <int>[56, 56, 56, 56, 56, 56, 56, 56],
  ],
};
