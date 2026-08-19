import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/bitreader.dart';
import 'package:ndvy_player/src/decoder/cavlc.dart';
import 'package:ndvy_player/src/decoder/vlc.dart';

import 'cavlc_test_utils.dart';

void main() {
  group('fail-fast CAVLC errors', () {
    test('does not turn a truncated coeff_token into a zero block', () {
      // nC=0 code for (16,0) is 0000000000000100; remove its final bit.
      final reader = bitReader('000000000000010');
      expect(
        () => decodeResidual4x4(reader, 0),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.message,
            'message',
            contains('coeff_token'),
          ),
        ),
      );
      expect(reader.bitPos, 15);
    });

    test('rejects a coeff_token exceeding maxNumCoeff without rewind', () {
      // Fixed-length nC>=8 coeff_token(16,0)=111100.
      final reader = bitReader('111100');
      expect(
        () => readCoeffToken(reader, 8, maxCoeff: 15),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.message,
            'message',
            contains('maxNumCoeff=15'),
          ),
        ),
      );
      expect(reader.bitPos, 6);
    });

    test('rejects a missing trailing-one sign', () {
      final reader = bitReader('01'); // coeff_token(1,1), then EOF
      expect(
        () => decodeResidual4x4(reader, 0),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.message,
            'message',
            contains('trailing_ones_sign_flag'),
          ),
        ),
      );
      expect(reader.bitPos, 2);
    });

    test('rejects a truncated level suffix', () {
      final bits = '${unaryPrefix(14)}111'; // needs four suffix bits
      final reader = bitReader(bits);
      expect(
        () => readLevelsCavlc(reader, 1, 0),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.message,
            'message',
            contains('level_suffix'),
          ),
        ),
      );
      expect(reader.bitPos, 15);
    });

    test('rejects a level_prefix larger than 28', () {
      final reader = bitReader(List.filled(29, '0').join());
      expect(
        () => readLevelsCavlc(reader, 1, 0),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.message,
            'message',
            contains('prefix exceeds 28'),
          ),
        ),
      );
      expect(reader.bitPos, 29);
    });

    test('rejects total_zeros that cannot fit an AC-only block', () {
      // coeff_token(1,1)=01, sign=0, then total_zeros=15. An AC block has
      // maxNumCoeff=15 and therefore permits only 14 zeros here.
      const bits = '010000000001';
      final reader = bitReader(bits);
      expect(
        () => decodeResidual4x4Ac(reader, 0),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.message,
            'message',
            contains('maximum is 14'),
          ),
        ),
      );
      expect(reader.bitPos, bits.length);
    });

    test('rejects run_before greater than zerosLeft', () {
      // coeff_token(2,2)=001, signs=00, total_zeros(7)=0011,
      // then the >=7 run_before table code for run=14.
      const bits = '00100001100000000001';
      final reader = bitReader(bits);
      expect(
        () => decodeResidual4x4(reader, 0),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.message,
            'message',
            contains('only 7 zeros left'),
          ),
        ),
      );
      expect(reader.bitPos, bits.length);
    });
  });

  group('generic VLC failures', () {
    test('reports a dead-end prefix', () {
      final reader = bitReader('11');
      final tree = buildVlcTree(const {'0': 10, '10': 20});
      expect(
        () => readVlc(reader, tree),
        throwsA(isA<BitstreamFormatException>()),
      );
      expect(reader.bitPos, 2);
    });

    test('reports a truncated valid prefix', () {
      final reader = bitReader('1');
      final tree = buildVlcTree(const {'0': 10, '10': 20});
      expect(
        () => readVlc(reader, tree),
        throwsA(isA<BitstreamFormatException>()),
      );
      expect(reader.bitPos, 1);
    });
  });
}
