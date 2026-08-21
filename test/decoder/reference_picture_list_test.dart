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

  group('B RefPicList0/1', () {
    test('orders references on both sides of the current POC', () {
      final lists = buildBReferenceLists<String>(
        shortTermReferences: _pocReferences(<(int, int, String)>[
          (1, 2, 'a'),
          (2, 4, 'b'),
          (3, 8, 'c'),
          (4, 10, 'd'),
        ]),
        currentFrameNum: 5,
        currentPictureOrderCount: 6,
        maxFrameNum: 16,
        activeReferenceCountL0: 4,
        activeReferenceCountL1: 4,
      );

      expect(lists.list0.map((reference) => reference.value), <String>[
        'b',
        'a',
        'c',
        'd',
      ]);
      expect(lists.list1.map((reference) => reference.value), <String>[
        'c',
        'd',
        'b',
        'a',
      ]);
    });

    test('swaps the first two List1 entries when initial lists match', () {
      final lists = buildBReferenceLists<String>(
        shortTermReferences: _pocReferences(<(int, int, String)>[
          (1, 4, 'oldest'),
          (2, 6, 'middle'),
          (3, 8, 'newest'),
        ]),
        currentFrameNum: 4,
        currentPictureOrderCount: 10,
        maxFrameNum: 16,
        activeReferenceCountL0: 3,
        activeReferenceCountL1: 3,
      );

      expect(lists.list0.map((reference) => reference.value), <String>[
        'newest',
        'middle',
        'oldest',
      ]);
      expect(lists.list1.map((reference) => reference.value), <String>[
        'middle',
        'newest',
        'oldest',
      ]);
    });

    test('applies independent List0 and List1 modifications', () {
      final lists = buildBReferenceLists<String>(
        shortTermReferences: _pocReferences(<(int, int, String)>[
          (1, 2, 'a'),
          (2, 4, 'b'),
          (3, 8, 'c'),
          (4, 10, 'd'),
        ]),
        currentFrameNum: 5,
        currentPictureOrderCount: 6,
        maxFrameNum: 16,
        activeReferenceCountL0: 4,
        activeReferenceCountL1: 4,
        modificationsL0: const <RefPicListModification>[
          RefPicListModification(0, 1), // PicNum 5 - 2 -> 3.
        ],
        modificationsL1: const <RefPicListModification>[
          RefPicListModification(0, 3), // PicNum 5 - 4 -> 1.
        ],
      );

      expect(lists.list0.map((reference) => reference.value), <String>[
        'c',
        'b',
        'a',
        'd',
      ]);
      expect(lists.list1.map((reference) => reference.value), <String>[
        'a',
        'c',
        'd',
        'b',
      ]);
    });

    test('requires POC and normatively orders a reference matching POC', () {
      expect(
        () => buildBReferenceLists<int>(
          shortTermReferences: _references(<int>[0]),
          currentFrameNum: 1,
          currentPictureOrderCount: 2,
          maxFrameNum: 16,
          activeReferenceCountL0: 1,
          activeReferenceCountL1: 1,
        ),
        throwsFormatException,
      );
      final lists = buildBReferenceLists<String>(
        shortTermReferences: _pocReferences(<(int, int, String)>[
          (0, 2, 'before'),
          (1, 4, 'equal'),
          (2, 6, 'after'),
        ]),
        currentFrameNum: 3,
        currentPictureOrderCount: 4,
        maxFrameNum: 16,
        activeReferenceCountL0: 3,
        activeReferenceCountL1: 3,
      );
      expect(lists.list0.map((reference) => reference.value), <String>[
        'before',
        'equal',
        'after',
      ]);
      expect(lists.list1.map((reference) => reference.value), <String>[
        'after',
        'equal',
        'before',
      ]);
    });
  });

  group('MMCO 1', () {
    test('removes a wrapped short-term PicNum and preserves DPB order', () {
      final result = applyShortTermMmco1<String>(
        shortTermReferences: _pocReferences(<(int, int, String)>[
          (14, 20, 'fourteen'),
          (15, 22, 'fifteen'),
          (0, 24, 'zero'),
          (1, 26, 'one'),
        ]),
        currentFrameNum: 2,
        maxFrameNum: 16,
        operation: const MemoryManagementOperation(
          operation: 1,
          differenceOfPicNumsMinus1: 2,
        ),
      );

      expect(result.picNumX, -1);
      expect(result.removed.value, 'fifteen');
      expect(result.remaining.map((reference) => reference.value), <String>[
        'fourteen',
        'zero',
        'one',
      ]);
    });

    test('selects frame_num max-1 from CurrPicNum zero', () {
      final result = applyShortTermMmco1<int>(
        shortTermReferences: _references(<int>[15, 0]),
        currentFrameNum: 0,
        maxFrameNum: 16,
        operation: const MemoryManagementOperation(
          operation: 1,
          differenceOfPicNumsMinus1: 0,
        ),
      );

      expect(result.picNumX, -1);
      expect(result.removed.frameNum, 15);
      expect(result.remaining.single.frameNum, 0);
    });

    test('rejects unavailable targets and operations outside its scope', () {
      expect(
        () => applyShortTermMmco1<int>(
          shortTermReferences: _references(<int>[1]),
          currentFrameNum: 4,
          maxFrameNum: 16,
          operation: const MemoryManagementOperation(
            operation: 1,
            differenceOfPicNumsMinus1: 0,
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => applyShortTermMmco1<int>(
          shortTermReferences: _references(<int>[1]),
          currentFrameNum: 2,
          maxFrameNum: 16,
          operation: const MemoryManagementOperation(operation: 5),
        ),
        throwsFormatException,
      );
    });
  });
}

List<H264ShortTermReference<int>> _references(List<int> frameNumbers) =>
    <H264ShortTermReference<int>>[
      for (final frameNumber in frameNumbers)
        H264ShortTermReference<int>(frameNum: frameNumber, value: frameNumber),
    ];

List<H264ShortTermReference<String>> _pocReferences(
  List<(int, int, String)> values,
) => <H264ShortTermReference<String>>[
  for (final (frameNum, poc, value) in values)
    H264ShortTermReference<String>(
      frameNum: frameNum,
      pictureOrderCount: poc,
      value: value,
    ),
];
