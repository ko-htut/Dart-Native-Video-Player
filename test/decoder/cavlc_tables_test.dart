import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cavlc.dart';
import 'package:ndvy_player/src/decoder/cavlc_coeff_token_tables.dart';
import 'package:ndvy_player/src/decoder/cavlc_runbefore_tables.dart';
import 'package:ndvy_player/src/decoder/cavlc_totalzeros_tables.dart';
import 'package:ndvy_player/src/decoder/vlc.dart';

import 'cavlc_test_utils.dart';

void main() {
  group('H.264 coeff_token tables', () {
    final contexts = <({int nC, String? Function(CoeffTokenRow) code})>[
      (nC: 0, code: (row) => row.nc01),
      (nC: 2, code: (row) => row.nc23),
      (nC: 4, code: (row) => row.nc47),
      (nC: 8, code: (row) => row.nc8p),
      (nC: -1, code: (row) => row.chromaDc),
    ];

    for (final context in contexts) {
      test('decodes every code in nC=${context.nC} table', () {
        var tested = 0;
        for (final row in coeffTokenRows) {
          final code = context.code(row);
          if (code == null || code.isEmpty) continue;

          final reader = bitReader(code);
          final token = readCoeffToken(
            reader,
            context.nC,
            maxCoeff: context.nC == -1 ? 4 : 16,
          );
          expect(token.totalCoeff, row.totalCoeff, reason: 'code=$code');
          expect(token.trailingOnes, row.trailingOnes, reason: 'code=$code');
          expect(reader.bitPos, code.length, reason: 'code=$code');
          tested++;
        }
        expect(tested, greaterThan(0));
      });
    }

    test('uses the correct table at every nC boundary', () {
      for (final nC in <int>[0, 1, 2, 3, 4, 7, 8, 16]) {
        final row = coeffTokenRows.firstWhere(
          (candidate) =>
              candidate.totalCoeff == 3 && candidate.trailingOnes == 2,
        );
        final code = switch (nC) {
          <= 1 => row.nc01,
          <= 3 => row.nc23,
          <= 7 => row.nc47,
          _ => row.nc8p,
        };
        final reader = bitReader(code);
        final token = readCoeffToken(reader, nC, maxCoeff: 16);
        expect(token.totalCoeff, 3, reason: 'nC=$nC code=$code');
        expect(token.trailingOnes, 2, reason: 'nC=$nC code=$code');
        expect(reader.bitPos, code.length);
      }
    });
  });

  group('H.264 run and total-zero tables', () {
    void expectEveryEntry(Map<String, int> table) {
      final tree = buildVlcTree(table);
      final maxBits = table.keys
          .map((code) => code.length)
          .reduce((a, b) => a > b ? a : b);
      for (final entry in table.entries) {
        final reader = bitReader(entry.key);
        expect(
          readVlc(reader, tree, maxBits: maxBits),
          entry.value,
          reason: 'code=${entry.key}',
        );
        expect(reader.bitPos, entry.key.length, reason: 'code=${entry.key}');
      }
    }

    test('decodes every 4x4 total_zeros code', () {
      for (var totalCoeff = 1; totalCoeff <= 15; totalCoeff++) {
        expectEveryEntry(totalZeros4x4[totalCoeff]!);
      }
    });

    test('decodes every 4:2:0 chroma-DC total_zeros code', () {
      for (var totalCoeff = 1; totalCoeff <= 3; totalCoeff++) {
        expectEveryEntry(totalZerosChromaDC[totalCoeff]!);
      }
    });

    test('decodes every run_before code', () {
      for (var zerosLeft = 1; zerosLeft <= 15; zerosLeft++) {
        expectEveryEntry(runBeforeTable[zerosLeft]!);
      }
    });
  });

  group('VLC table validation', () {
    test('rejects an empty table', () {
      expect(() => buildVlcTree(const {}), throwsArgumentError);
    });

    test('rejects non-binary codes', () {
      expect(() => buildVlcTree(const {'02': 1}), throwsArgumentError);
    });

    test('rejects a code that prefixes another code', () {
      expect(() => buildVlcTree(const {'0': 1, '01': 2}), throwsArgumentError);
      expect(() => buildVlcTree(const {'01': 2, '0': 1}), throwsArgumentError);
    });
  });
}
