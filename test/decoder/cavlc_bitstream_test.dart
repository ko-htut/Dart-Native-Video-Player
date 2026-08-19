import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/bitreader.dart';
import 'package:ndvy_player/src/decoder/exp_golomb.dart';
import 'package:ndvy_player/src/decoder/rbsp.dart';

import 'cavlc_test_utils.dart';

void main() {
  group('BitReader', () {
    test('reads MSB-first and honors a logical bit length', () {
      final reader = BitReader(Uint8List.fromList(<int>[0xa5]), bitLength: 6);
      expect(reader.readBits(3), 5);
      expect(reader.peekBits(2), 0);
      expect(reader.bitPos, 3);
      expect(reader.readBits(3), 1);
      expect(reader.eof, isTrue);
    });

    test('an over-read throws without partially advancing', () {
      final reader = bitReader('101');
      expect(
        () => reader.readBits(4),
        throwsA(isA<BitstreamFormatException>()),
      );
      expect(reader.bitPos, 0);
    });

    test('readBytes is exact and atomic when truncated', () {
      final reader = BitReader(Uint8List.fromList(<int>[0xff, 0x12]));
      reader.readBit();
      expect(
        () => reader.readBytes(2),
        throwsA(isA<BitstreamFormatException>()),
      );
      expect(reader.bitPos, 1);
    });

    test('rejects out-of-range seeks', () {
      final reader = bitReader('1');
      expect(() => reader.seekBit(-1), throwsRangeError);
      expect(() => reader.seekBit(2), throwsRangeError);
    });
  });

  group('Exp-Golomb', () {
    test('decodes known ue(v) vectors', () {
      const vectors = <String, int>{
        '1': 0,
        '010': 1,
        '011': 2,
        '00100': 3,
        '00101': 4,
        '00110': 5,
        '00111': 6,
      };
      for (final entry in vectors.entries) {
        final reader = bitReader(entry.key);
        expect(readUE(reader), entry.value, reason: entry.key);
        expect(reader.bitPos, entry.key.length);
      }
    });

    test('decodes known se(v) vectors', () {
      const vectors = <String, int>{
        '1': 0,
        '010': 1,
        '011': -1,
        '00100': 2,
        '00101': -2,
      };
      for (final entry in vectors.entries) {
        final reader = bitReader(entry.key);
        expect(readSE(reader), entry.value, reason: entry.key);
        expect(reader.bitPos, entry.key.length);
      }
    });

    test('rejects a missing stop bit and a truncated suffix', () {
      final noStop = bitReader('0000');
      expect(() => readUE(noStop), throwsA(isA<BitstreamFormatException>()));
      expect(noStop.bitPos, 4);

      final noSuffix = bitReader('0010');
      expect(() => readUE(noSuffix), throwsA(isA<BitstreamFormatException>()));
      expect(noSuffix.bitPos, 3);
    });

    test('rejects 32 leading zero bits', () {
      final reader = bitReader(List.filled(32, '0').join());
      expect(() => readUE(reader), throwsA(isA<BitstreamFormatException>()));
      expect(reader.bitPos, 32);
    });
  });

  group('EBSP and RBSP', () {
    test('removes every legal emulation-prevention sequence', () {
      final rbsp = ebspToRbsp(
        Uint8List.fromList(<int>[
          0x12,
          0x00,
          0x00,
          0x03,
          0x00,
          0x12,
          0x00,
          0x00,
          0x03,
          0x01,
          0x12,
          0x00,
          0x00,
          0x03,
          0x02,
          0x12,
          0x00,
          0x00,
          0x03,
          0x03,
        ]),
      );
      expect(rbsp, <int>[
        0x12,
        0x00,
        0x00,
        0x00,
        0x12,
        0x00,
        0x00,
        0x01,
        0x12,
        0x00,
        0x00,
        0x02,
        0x12,
        0x00,
        0x00,
        0x03,
      ]);
    });

    test('rejects malformed emulation-prevention sequences', () {
      expect(
        () => ebspToRbsp(Uint8List.fromList(<int>[0, 0, 3])),
        throwsA(isA<BitstreamFormatException>()),
      );
      expect(
        () => ebspToRbsp(Uint8List.fromList(<int>[0, 0, 3, 4])),
        throwsA(isA<BitstreamFormatException>()),
      );
      expect(
        () => ebspToRbsp(Uint8List.fromList(<int>[0, 0, 1])),
        throwsA(isA<BitstreamFormatException>()),
      );
    });

    test('moreRbspData recognizes only stop-one plus zero padding', () {
      final reader = bitReader('10100000');
      expect(moreRbspData(reader), isTrue);
      expect(reader.bitPos, 0);
      reader.seekBit(2);
      expect(moreRbspData(reader), isFalse);
      expect(reader.bitPos, 2);

      expect(moreRbspData(bitReader('000')), isTrue);
      expect(moreRbspData(bitReader('')), isFalse);
    });

    test('validates and consumes rbsp_trailing_bits', () {
      final reader = bitReader('00100000');
      reader.seekBit(2);
      readRbspTrailingBits(reader);
      expect(reader.eof, isTrue);
    });

    test('rejects non-zero alignment and bytes after trailing bits', () {
      final badAlignment = bitReader('00101000');
      badAlignment.seekBit(2);
      expect(
        () => readRbspTrailingBits(badAlignment),
        throwsA(isA<BitstreamFormatException>()),
      );

      final extraByte = bitReader('1000000000000000');
      expect(
        () => readRbspTrailingBits(extraByte),
        throwsA(isA<BitstreamFormatException>()),
      );
    });
  });
}
