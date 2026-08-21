import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/bitreader.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_decoder.dart';

void main() {
  group('H264CabacDecoder initialization', () {
    test('starts with codIRange=510 and a nine-bit codIOffset', () {
      final decoder = H264CabacDecoder.initialize(_bitReader('101010101'));
      expect(decoder.range, 510);
      expect(decoder.offset, 341);
      expect(decoder.bitsConsumed, 9);
      expect(decoder.isTerminated, isFalse);
    });

    test('rejects forbidden initial offsets 510 and 511', () {
      for (final bits in <String>['111111110', '111111111']) {
        expect(
          () => H264CabacDecoder.initialize(_bitReader(bits)),
          throwsA(
            isA<BitstreamFormatException>().having(
              (error) => error.bitPosition,
              'bitPosition',
              0,
            ),
          ),
          reason: bits,
        );
      }
    });

    test('requires all nine initialization bits atomically', () {
      final reader = _bitReader('10101010');
      expect(
        () => H264CabacDecoder.initialize(reader),
        throwsA(isA<BitstreamFormatException>()),
      );
      expect(reader.bitPos, 0);
    });
  });

  group('regular decision bins', () {
    test('MPS trajectory selects rangeTabLPS and renormalizes exactly', () {
      // Initial codIOffset=0 followed by the one renormalization bit `1`.
      final decoder = H264CabacDecoder.initialize(_bitReader('0000000001'));
      final context = CabacContextModel(
        probabilityStateIndex: 0,
        mostProbableSymbol: 0,
      );

      expect(decoder.decodeBin(context), 0);
      expect(decoder.range, 270);
      expect(decoder.offset, 0);
      expect(decoder.bitPosition, 9);
      expect(context.probabilityStateIndex, 1);

      expect(decoder.decodeBin(context), 0);
      expect(decoder.range, 284);
      expect(decoder.offset, 1);
      expect(decoder.bitPosition, 10);
      expect(context.probabilityStateIndex, 2);
      expect(context.mostProbableSymbol, 0);
    });

    test('state-zero LPS flips valMPS on consecutive exact decisions', () {
      // codIOffset=509. Each LPS leaves range=240 and consumes a zero while
      // renormalizing to 480.
      final decoder = H264CabacDecoder.initialize(_bitReader('11111110100'));
      final context = CabacContextModel(
        probabilityStateIndex: 0,
        mostProbableSymbol: 0,
      );

      expect(decoder.decodeBin(context), 1);
      expect(decoder.range, 480);
      expect(decoder.offset, 478);
      expect(context.probabilityStateIndex, 0);
      expect(context.mostProbableSymbol, 1);

      expect(decoder.decodeBin(context), 0);
      expect(decoder.range, 480);
      expect(decoder.offset, 476);
      expect(context.probabilityStateIndex, 0);
      expect(context.mostProbableSymbol, 0);
      expect(decoder.bitsConsumed, 11);
    });

    test('state-63 LPS performs the full seven-bit renormalization', () {
      final decoder = H264CabacDecoder.initialize(
        _bitReader('1111111010000000'),
      );
      final context = CabacContextModel(
        probabilityStateIndex: 63,
        mostProbableSymbol: 1,
      );

      expect(decoder.decodeBin(context), 0);
      expect(decoder.range, 256);
      expect(decoder.offset, 128);
      expect(decoder.bitsConsumed, 16);
      expect(context.probabilityStateIndex, 63);
      expect(context.mostProbableSymbol, 1);
    });

    test('truncated renormalization fails instead of synthesizing bits', () {
      final decoder = H264CabacDecoder.initialize(_bitReader('000000000'));
      final context = CabacContextModel(
        probabilityStateIndex: 0,
        mostProbableSymbol: 0,
      );
      expect(decoder.decodeBin(context), 0);
      expect(
        () => decoder.decodeBin(context),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.bitPosition,
            'bitPosition',
            9,
          ),
        ),
      );
    });
  });

  group('bypass and terminate bins', () {
    test('bypass bins shift codIOffset while preserving codIRange', () {
      // codIOffset=100, then bypass bits 1,0,1,1.
      final decoder = H264CabacDecoder.initialize(_bitReader('0011001001011'));

      expect(
        <int>[
          decoder.decodeBypass(),
          decoder.decodeBypass(),
          decoder.decodeBypass(),
          decoder.decodeBypass(),
        ],
        <int>[0, 0, 1, 1],
      );
      expect(decoder.range, 510);
      expect(decoder.offset, 81);
      expect(decoder.bitsConsumed, 13);
    });

    test('terminate zero subtracts two and terminate one seals decoder', () {
      final decoder = H264CabacDecoder.initialize(_bitReader('111111011'));
      expect(decoder.offset, 507);

      expect(decoder.decodeTerminate(), 0);
      expect(decoder.range, 508);
      expect(decoder.isTerminated, isFalse);

      expect(decoder.decodeTerminate(), 1);
      expect(decoder.range, 506);
      expect(decoder.isTerminated, isTrue);
      expect(() => decoder.decodeBypass(), throwsStateError);
      expect(() => decoder.decodeTerminate(), throwsStateError);
      expect(
        () => decoder.decodeBin(
          CabacContextModel(probabilityStateIndex: 0, mostProbableSymbol: 0),
        ),
        throwsStateError,
      );
    });

    test('terminate zero renormalizes a range below 256', () {
      // The state-63 LPS consumes seven zeros and leaves range=256,
      // offset=128. Termination subtracts two, then consumes the final zero.
      final decoder = H264CabacDecoder.initialize(
        _bitReader('11111110100000000'),
      );
      final context = CabacContextModel(
        probabilityStateIndex: 63,
        mostProbableSymbol: 1,
      );
      expect(decoder.decodeBin(context), 0);
      expect(decoder.range, 256);
      expect(decoder.offset, 128);

      expect(decoder.decodeTerminate(), 0);
      expect(decoder.range, 508);
      expect(decoder.offset, 256);
      expect(decoder.bitsConsumed, 17);
    });

    test('bypass over-read reports the exact payload position', () {
      final decoder = H264CabacDecoder.initialize(_bitReader('000000000'));
      expect(
        () => decoder.decodeBypass(),
        throwsA(
          isA<BitstreamFormatException>().having(
            (error) => error.bitPosition,
            'bitPosition',
            9,
          ),
        ),
      );
    });
  });
}

BitReader _bitReader(String bits) {
  final bytes = Uint8List((bits.length + 7) >> 3);
  for (var index = 0; index < bits.length; index++) {
    final character = bits.codeUnitAt(index);
    if (character != 0x30 && character != 0x31) {
      throw ArgumentError.value(bits, 'bits', 'must contain only 0 and 1');
    }
    if (character == 0x31) {
      bytes[index >> 3] |= 1 << (7 - (index & 7));
    }
  }
  return BitReader(bytes, bitLength: bits.length);
}
