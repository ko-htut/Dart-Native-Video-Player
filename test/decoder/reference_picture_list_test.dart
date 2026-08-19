import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/bitreader.dart';
import 'package:ndvy_player/src/decoder/exp_golomb.dart';
import 'package:ndvy_player/src/decoder/reference_picture_list.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';

void main() {
  group('truncated Exp-Golomb', () {
    test('zero range consumes no bits and two-value range inverts one bit', () {
      final reader = BitReader(Uint8List.fromList(<int>[0x40])); // bits 0, 1

      expect(readTE(reader, 0), 0);
      expect(reader.bitPos, 0);
      expect(readTE(reader, 1), 1);
      expect(readTE(reader, 1), 0);
      expect(reader.bitPos, 2);
    });

    test('larger ranges use bounded ue(v)', () {
      expect(readTE(BitReader(Uint8List.fromList(<int>[0x60])), 4), 2);
      expect(
        () => readTE(BitReader(Uint8List.fromList(<int>[0x20])), 2),
        throwsA(isA<BitstreamFormatException>()),
      );
    });
  });

  group('P RefPicList0', () {
    test('orders short-term pictures by descending PicNum', () {
      final list = buildPReferenceList0<int>(
        shortTermReferences: _references(<int>[0, 1, 2, 3]),
        currentFrameNum: 4,
        maxFrameNum: 16,
        activeReferenceCount: 3,
      );

      expect(list.map((reference) => reference.value), <int>[3, 2, 1]);
    });

    test('derives wrapped PicNum before sorting', () {
      final list = buildPReferenceList0<int>(
        shortTermReferences: _references(<int>[13, 14, 15, 0]),
        currentFrameNum: 1,
        maxFrameNum: 16,
        activeReferenceCount: 4,
      );

      expect(list.map((reference) => reference.value), <int>[0, 15, 14, 13]);
    });

    test('applies sequential subtract/add list modifications', () {
      final list = buildPReferenceList0<int>(
        shortTermReferences: _references(<int>[1, 2, 3, 4]),
        currentFrameNum: 5,
        maxFrameNum: 16,
        activeReferenceCount: 3,
        modifications: const <RefPicListModification>[
          RefPicListModification(0, 2), // predicted PicNum 5 -> 2
          RefPicListModification(1, 1), // predicted PicNum 2 -> 4
        ],
      );

      expect(list.map((reference) => reference.value), <int>[2, 4, 3]);
    });

    test('rejects unavailable and long-term selections explicitly', () {
      expect(
        () => buildPReferenceList0<int>(
          shortTermReferences: _references(<int>[4]),
          currentFrameNum: 5,
          maxFrameNum: 16,
          activeReferenceCount: 1,
          modifications: const <RefPicListModification>[
            RefPicListModification(0, 2),
          ],
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('unavailable PicNum'),
          ),
        ),
      );
      expect(
        () => buildPReferenceList0<int>(
          shortTermReferences: _references(<int>[4]),
          currentFrameNum: 5,
          maxFrameNum: 16,
          activeReferenceCount: 1,
          modifications: const <RefPicListModification>[
            RefPicListModification(2, 0),
          ],
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

List<H264ShortTermReference<int>> _references(List<int> frameNumbers) =>
    <H264ShortTermReference<int>>[
      for (final frameNumber in frameNumbers)
        H264ShortTermReference<int>(frameNum: frameNumber, value: frameNumber),
    ];
