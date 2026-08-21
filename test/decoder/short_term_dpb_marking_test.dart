import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/reference_picture_list.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

void main() {
  group('pure short-term DPB marking', () {
    test('applies the exact parsed sfux MMCO 1 then appends by identity', () {
      final sps = parseSpsNal(
        _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
      );
      final pps = parsePpsNal(
        _hex('68e9b8372c8b'),
        chromaFormatIdc: sps.chromaFormatIdc,
      );
      final header = parseSliceHeader(
        _hex('419ea664945c2bff'),
        ppsById: <int, PpsInfo>{pps.ppsId: pps},
        spsById: <int, SpsInfo>{sps.spsId: sps},
      );
      final payloads = List<Object>.generate(6, (_) => Object());
      final before = <H264ShortTermReference<Object>>[
        for (var frameNum = 0; frameNum < 5; frameNum++)
          H264ShortTermReference<Object>(
            frameNum: frameNum,
            pictureOrderCount: frameNum * 2,
            value: payloads[frameNum],
          ),
      ];
      final current = H264ShortTermReference<Object>(
        frameNum: header.frameNum,
        pictureOrderCount: header.picOrderCntLsb,
        value: payloads[5],
      );

      final result = applyShortTermDpbMarking<Object>(
        shortTermReferences: before,
        currentPicture: current,
        maxFrameNum: sps.maxFrameNum,
        maxNumRefFrames: sps.maxNumRefFrames,
        nalRefIdc: header.nalRefIdc,
        adaptiveRefPicMarkingModeFlag: header.adaptiveRefPicMarkingModeFlag,
        memoryManagementOperations: header.memoryManagementOperations,
      );

      expect(result.removed, hasLength(1));
      expect(identical(result.removed.single, before[0]), isTrue);
      expect(result.references.map((reference) => reference.frameNum), <int>[
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(identical(result.references.last, current), isTrue);
      expect(identical(result.references.last.value, payloads[5]), isTrue);
      expect(result.appendedCurrentPicture, isTrue);
      expect(before.map((reference) => reference.frameNum), <int>[
        0,
        1,
        2,
        3,
        4,
      ]);
    });

    test('applies multiple MMCO 1 operations in syntax order', () {
      final payloads = List<Object>.generate(6, (_) => Object());
      final before = _references(payloads.take(5).toList());
      final current = H264ShortTermReference<Object>(
        frameNum: 5,
        value: payloads[5],
      );

      final result = applyShortTermDpbMarking<Object>(
        shortTermReferences: before,
        currentPicture: current,
        maxFrameNum: 16,
        maxNumRefFrames: 6,
        nalRefIdc: 2,
        adaptiveRefPicMarkingModeFlag: true,
        memoryManagementOperations: const <MemoryManagementOperation>[
          MemoryManagementOperation(
            operation: 1,
            differenceOfPicNumsMinus1: 4,
          ), // PicNumX 0.
          MemoryManagementOperation(
            operation: 1,
            differenceOfPicNumsMinus1: 2,
          ), // PicNumX 2.
        ],
      );

      expect(result.removed, <H264ShortTermReference<Object>>[
        before[0],
        before[2],
      ]);
      expect(result.references.map((reference) => reference.frameNum), <int>[
        1,
        3,
        4,
        5,
      ]);
      expect(identical(result.references[0].value, payloads[1]), isTrue);
      expect(identical(result.references.last, current), isTrue);
    });

    test('missing target throws without mutating the caller DPB', () {
      final before = _references(List<Object>.generate(5, (_) => Object()));
      final snapshot = List<H264ShortTermReference<Object>>.of(before);
      final current = H264ShortTermReference<Object>(
        frameNum: 5,
        value: Object(),
      );

      expect(
        () => applyShortTermDpbMarking<Object>(
          shortTermReferences: before,
          currentPicture: current,
          maxFrameNum: 16,
          maxNumRefFrames: 6,
          nalRefIdc: 2,
          adaptiveRefPicMarkingModeFlag: true,
          memoryManagementOperations: const <MemoryManagementOperation>[
            MemoryManagementOperation(
              operation: 1,
              differenceOfPicNumsMinus1: 4,
            ),
            MemoryManagementOperation(
              operation: 1,
              differenceOfPicNumsMinus1: 4,
            ),
          ],
        ),
        throwsFormatException,
      );
      expect(before, orderedEquals(snapshot));
      for (var index = 0; index < before.length; index++) {
        expect(identical(before[index], snapshot[index]), isTrue);
      }
      expect(before, isNot(contains(current)));
    });

    test('non-reference picture returns an unchanged identity snapshot', () {
      final before = _references(List<Object>.generate(2, (_) => Object()));
      final current = H264ShortTermReference<Object>(
        frameNum: 2,
        value: Object(),
      );

      final result = applyShortTermDpbMarking<Object>(
        shortTermReferences: before,
        currentPicture: current,
        maxFrameNum: 16,
        maxNumRefFrames: 6,
        nalRefIdc: 0,
        adaptiveRefPicMarkingModeFlag: false,
      );

      expect(result.references, orderedEquals(before));
      expect(result.removed, isEmpty);
      expect(result.appendedCurrentPicture, isFalse);
      expect(result.references, isNot(contains(current)));
      for (var index = 0; index < before.length; index++) {
        expect(identical(result.references[index], before[index]), isTrue);
      }
      expect(() => result.references.add(current), throwsUnsupportedError);
    });

    test('max refs 6 sliding window evicts oldest wrapped PicNum', () {
      final frameNumbers = <int>[12, 13, 14, 15, 0, 1];
      final payloads = List<Object>.generate(7, (_) => Object());
      final before = <H264ShortTermReference<Object>>[
        for (var index = 0; index < frameNumbers.length; index++)
          H264ShortTermReference<Object>(
            frameNum: frameNumbers[index],
            value: payloads[index],
          ),
      ];
      final current = H264ShortTermReference<Object>(
        frameNum: 2,
        value: payloads[6],
      );

      final result = applyShortTermDpbMarking<Object>(
        shortTermReferences: before,
        currentPicture: current,
        maxFrameNum: 16,
        maxNumRefFrames: 6,
        nalRefIdc: 2,
        adaptiveRefPicMarkingModeFlag: false,
      );

      expect(result.removed.single.frameNum, 12); // FrameNumWrap = -4.
      expect(identical(result.removed.single, before.first), isTrue);
      expect(result.references.map((reference) => reference.frameNum), <int>[
        13,
        14,
        15,
        0,
        1,
        2,
      ]);
      expect(identical(result.references.last, current), isTrue);
      expect(before.map((reference) => reference.frameNum), frameNumbers);
    });

    test('adaptive overflow and unsupported operations fail atomically', () {
      final before = <H264ShortTermReference<Object>>[
        for (final frameNum in <int>[12, 13, 14, 15, 0, 1])
          H264ShortTermReference<Object>(frameNum: frameNum, value: Object()),
      ];
      final snapshot = List<H264ShortTermReference<Object>>.of(before);
      final current = H264ShortTermReference<Object>(
        frameNum: 2,
        value: Object(),
      );

      expect(
        () => applyShortTermDpbMarking<Object>(
          shortTermReferences: before,
          currentPicture: current,
          maxFrameNum: 16,
          maxNumRefFrames: 6,
          nalRefIdc: 2,
          adaptiveRefPicMarkingModeFlag: true,
        ),
        throwsFormatException,
      );
      expect(
        () => applyShortTermDpbMarking<Object>(
          shortTermReferences: before,
          currentPicture: current,
          maxFrameNum: 16,
          maxNumRefFrames: 6,
          nalRefIdc: 2,
          adaptiveRefPicMarkingModeFlag: true,
          memoryManagementOperations: const <MemoryManagementOperation>[
            MemoryManagementOperation(operation: 2, longTermPicNum: 0),
          ],
        ),
        throwsFormatException,
      );
      expect(before, orderedEquals(snapshot));
    });
  });
}

List<H264ShortTermReference<Object>> _references(List<Object> payloads) =>
    <H264ShortTermReference<Object>>[
      for (var frameNum = 0; frameNum < payloads.length; frameNum++)
        H264ShortTermReference<Object>(
          frameNum: frameNum,
          value: payloads[frameNum],
        ),
    ];

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
