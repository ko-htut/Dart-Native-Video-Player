import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/aac/adts.dart';

import 'aac_test_utils.dart';

void main() {
  group('AdtsHeader', () {
    test('parses AAC-LC transport fields and derives ASC', () {
      final frame = makeAdtsFrame(<int>[1, 2, 3, 4]);
      final header = AdtsHeader.parse(frame);

      expect(header.mpegVersion, 4);
      expect(header.protectionAbsent, isTrue);
      expect(header.audioObjectType, 2);
      expect(header.samplingFrequencyIndex, 4);
      expect(header.samplingFrequency, 44100);
      expect(header.channelConfiguration, 2);
      expect(header.headerLength, 7);
      expect(header.frameLength, 11);
      expect(header.payloadLength, 4);
      expect(header.sampleCount, 1024);

      final config = header.toAudioSpecificConfig();
      expect(config.bytes, <int>[0x12, 0x10]);
      expect(config.isAacLc, isTrue);
    });

    test('accounts for CRC and multiple raw data blocks', () {
      final frame = makeAdtsFrame(
        <int>[7, 8],
        protectionAbsent: false,
        numberOfRawDataBlocks: 1,
      );
      final header = AdtsHeader.parse(frame);

      expect(header.headerLength, 11);
      expect(header.payloadLength, 2);
      expect(header.sampleCount, 2048);
      expect(() => AdtsParser.parse(frame), throwsUnsupportedError);
    });

    test('rejects invalid sync, layer, frequency and length', () {
      expect(
        () => AdtsHeader.parse(Uint8List.fromList(<int>[0, 1, 2])),
        throwsFormatException,
      );

      final badLayer = makeAdtsFrame(<int>[1])..[1] |= 0x02;
      expect(() => AdtsHeader.parse(badLayer), throwsFormatException);

      final badFrequency = makeAdtsFrame(<int>[1])..[2] |= 0x3c;
      expect(() => AdtsHeader.parse(badFrequency), throwsFormatException);

      final badLength = makeAdtsFrame(<int>[1]);
      badLength[3] &= 0xfc;
      badLength[4] = 0;
      badLength[5] &= 0x1f;
      expect(() => AdtsHeader.parse(badLength), throwsFormatException);
    });
  });

  group('AdtsParser', () {
    test('returns raw payloads and drift-free 44.1 kHz timestamps', () {
      final stream = Uint8List.fromList(<int>[
        ...makeAdtsFrame(<int>[1, 2]),
        ...makeAdtsFrame(<int>[3]),
        ...makeAdtsFrame(<int>[4, 5, 6]),
      ]);
      final units = AdtsParser.parse(stream, firstPts90k: 90000);

      expect(units.map((unit) => unit.payload), <List<int>>[
        <int>[1, 2],
        <int>[3],
        <int>[4, 5, 6],
      ]);
      expect(units.map((unit) => unit.pts90k), <int>[90000, 92089, 94179]);
    });

    test('rejects an incomplete final frame', () {
      final frame = makeAdtsFrame(<int>[1, 2, 3]);
      expect(
        () => AdtsParser.parse(frame.sublist(0, frame.length - 1)),
        throwsFormatException,
      );
    });
  });

  group('AdtsStreamParser', () {
    test('retains split sync/header/frame data across pushes', () {
      final first = makeAdtsFrame(<int>[10, 11, 12]);
      final second = makeAdtsFrame(<int>[20, 21]);
      final bytes = Uint8List.fromList(<int>[...first, ...second]);
      final parser = AdtsStreamParser();

      expect(parser.push(bytes.sublist(0, 1), pts90k: 1000), isEmpty);
      expect(parser.push(bytes.sublist(1, 8)), isEmpty);
      final one = parser.push(bytes.sublist(8, first.length + 3));
      expect(one, hasLength(1));
      expect(one.single.payload, <int>[10, 11, 12]);
      expect(one.single.pts90k, 1000);
      final two = parser.push(bytes.sublist(first.length + 3));
      expect(two, hasLength(1));
      expect(two.single.payload, <int>[20, 21]);
      expect(two.single.pts90k, 3089);
      expect(() => parser.finish(), returnsNormally);
    });

    test('resynchronizes junk and anchors PTS to the next frame boundary', () {
      final parser = AdtsStreamParser();
      final first = makeAdtsFrame(<int>[1, 2, 3]);
      final second = makeAdtsFrame(<int>[4]);

      final units = parser.push(
        Uint8List.fromList(<int>[0xaa, 0xbb, ...first, ...second]),
        pts90k: 777,
      );

      expect(units, hasLength(2));
      expect(units.first.pts90k, 777);
      expect(units.last.pts90k, 2866);
      expect(() => parser.finish(), returnsNormally);
    });

    test('unwraps PTS over the 33-bit rollover', () {
      final parser = AdtsStreamParser();
      final nearWrap = (1 << 33) - 100;
      final first = parser.push(makeAdtsFrame(<int>[1]), pts90k: nearWrap);
      final second = parser.push(makeAdtsFrame(<int>[2]), pts90k: 50);

      expect(first.single.pts90k, nearWrap);
      expect(second.single.pts90k, 1 << 33 | 50);
    });

    test('finish reports a truncated buffered frame', () {
      final parser = AdtsStreamParser();
      final frame = makeAdtsFrame(<int>[1, 2]);
      parser.push(frame.sublist(0, frame.length - 1));
      expect(parser.finish, throwsFormatException);
      parser.reset();
      expect(parser.bufferedByteCount, 0);
    });
  });
}
