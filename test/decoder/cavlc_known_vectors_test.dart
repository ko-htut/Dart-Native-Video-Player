import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cavlc.dart';

import 'cavlc_test_utils.dart';

void main() {
  group('CAVLC level vectors', () {
    test('reads trailing-one signs in bitstream order', () {
      final reader = bitReader('01');
      expect(readLevelsCavlc(reader, 2, 2), <int>[1, -1]);
      expect(reader.bitPos, 2);
    });

    test('applies the first non-trailing level adjustment', () {
      final positive = bitReader('1');
      expect(readLevelsCavlc(positive, 1, 0), <int>[2]);
      expect(positive.bitPos, 1);

      final negative = bitReader('01');
      expect(readLevelsCavlc(negative, 1, 0), <int>[-2]);
      expect(negative.bitPos, 2);
    });

    test('handles the level_prefix 14 suffix escape', () {
      final bits = '${unaryPrefix(14)}1110';
      final reader = bitReader(bits);
      expect(readLevelsCavlc(reader, 1, 0), <int>[16]);
      expect(reader.bitPos, bits.length);
    });

    test('handles level_prefix 15 and 16 escapes', () {
      final prefix15 = '${unaryPrefix(15)}${List.filled(12, '0').join()}';
      final reader15 = bitReader(prefix15);
      expect(readLevelsCavlc(reader15, 1, 0), <int>[17]);
      expect(reader15.bitPos, prefix15.length);

      final prefix16 = '${unaryPrefix(16)}${List.filled(13, '0').join()}';
      final reader16 = bitReader(prefix16);
      expect(readLevelsCavlc(reader16, 1, 0), <int>[2065]);
      expect(reader16.bitPos, prefix16.length);
    });

    test('updates suffixLength after a large level', () {
      // +4: prefix=4 with suffixLength=0 (and first-level adjustment).
      // -3: prefix=1, suffix=01 with the resulting suffixLength=2.
      const bits = '000010101';
      final reader = bitReader(bits);
      expect(readLevelsCavlc(reader, 2, 0), <int>[4, -3]);
      expect(reader.bitPos, bits.length);
    });
  });

  group('complete residual block vectors', () {
    test('decodes an all-zero 4x4 block', () {
      final reader = bitReader('1');
      final result = decodeResidual4x4(reader, 0);
      expect(result.totalCoeff, 0);
      expect(result.coeffs, List<int>.filled(16, 0));
      expect(result.desynced, isFalse);
      expect(reader.bitPos, 1);
    });

    test('places a positive trailing one at DC', () {
      // coeff_token(1,1)=01, sign=0, total_zeros(0)=1.
      const bits = '0101';
      final reader = bitReader(bits);
      final result = decodeResidual4x4(reader, 0);
      expect(result.totalCoeff, 1);
      expect(result.coeffs[0], 1);
      expect(result.coeffs.where((value) => value != 0).length, 1);
      expect(reader.bitPos, bits.length);
    });

    test('places a negative trailing one at the final scan position', () {
      // coeff_token(1,1)=01, sign=1, total_zeros(15)=000000001.
      const bits = '011000000001';
      final reader = bitReader(bits);
      final result = decodeResidual4x4(reader, 0);
      expect(result.totalCoeff, 1);
      expect(result.coeffs[15], -1);
      expect(result.coeffs.where((value) => value != 0).length, 1);
      expect(reader.bitPos, bits.length);
    });

    test('combines coeff_token, levels, total_zeros, and run_before', () {
      // Scan-order coefficients: [ +2, 0, 0, -1 ].
      // coeff_token(2,1)=000100, sign=1, +2 level=1,
      // total_zeros(2)=101, run_before(2)=00.
      const bits = '0001001110100';
      final reader = bitReader(bits);
      final result = decodeResidual4x4(reader, 0);
      expect(result.totalCoeff, 2);
      expect(result.coeffs[0], 2);
      expect(result.coeffs[8], -1); // zigzag scan index 3
      expect(result.coeffs.where((value) => value != 0).length, 2);
      expect(reader.bitPos, bits.length);
    });

    test('keeps DC clear for a 15-coefficient AC block', () {
      const bits = '0101';
      final reader = bitReader(bits);
      final result = decodeResidual4x4Ac(reader, 0);
      expect(result.totalCoeff, 1);
      expect(result.coeffs[0], 0);
      expect(result.coeffs[1], 1); // zigzag scan index 1
      expect(reader.bitPos, bits.length);
    });

    test('decodes a 4:2:0 chroma-DC block', () {
      // Chroma coeff_token(2,1)=000110. Scan coefficients are
      // [ +2, 0, 0, -1 ].
      const bits = '000110110000';
      final reader = bitReader(bits);
      final result = decodeChromaDC2x2(reader);
      expect(result.totalCoeff, 2);
      expect(result.coeffs4, <int>[2, 0, 0, -1]);
      expect(reader.bitPos, bits.length);
    });
  });
}
