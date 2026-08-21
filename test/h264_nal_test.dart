import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/h264_nal.dart';

Uint8List _nal(int type, [int payload = 0x80]) =>
    Uint8List.fromList(<int>[0x60 | type, payload]);

Uint8List _slice(int type, int firstMb) {
  final firstMbBits = switch (firstMb) {
    0 => 0x80, // ue(v) 1
    1 => 0x40, // ue(v) 010
    2 => 0x60, // ue(v) 011
    _ => throw ArgumentError.value(firstMb, 'firstMb'),
  };
  return Uint8List.fromList(<int>[0x60 | type, firstMbBits]);
}

String _ueBits(int value) {
  final codeNum = value + 1;
  final binary = codeNum.toRadixString(2);
  return '${List.filled(binary.length - 1, '0').join()}$binary';
}

Uint8List _nalFromBits(int type, String bits) {
  final withStopBit = '${bits}1';
  final padded = withStopBit.padRight((withStopBit.length + 7) ~/ 8 * 8, '0');
  final bytes = <int>[0x60 | type];
  for (var offset = 0; offset < padded.length; offset += 8) {
    bytes.add(int.parse(padded.substring(offset, offset + 8), radix: 2));
  }
  return Uint8List.fromList(bytes);
}

Uint8List _spsWithId(int spsId) => _nalFromBits(
  7,
  '${0x42.toRadixString(2).padLeft(8, '0')}00000000'
  '${0x1e.toRadixString(2).padLeft(8, '0')}${_ueBits(spsId)}',
);

Uint8List _ppsWithIds(int ppsId, int spsId) =>
    _nalFromBits(8, '${_ueBits(ppsId)}${_ueBits(spsId)}');

Uint8List _sliceWithPps(int type, int ppsId) =>
    _nalFromBits(type, '${_ueBits(0)}${_ueBits(2)}${_ueBits(ppsId)}');

List<int> _types(AccessUnit accessUnit) =>
    accessUnit.nals.map(nalType).toList(growable: false);

void main() {
  group('late-playback discard classification', () {
    Uint8List slice({required int sliceType, required int nalRefIdc}) =>
        _nalFromBits(1, '${_ueBits(0)}${_ueBits(sliceType)}${_ueBits(0)}')
          ..[0] = (nalRefIdc << 5) | 1;

    test('accepts only complete non-reference B access units', () {
      final nonReferenceB = slice(sliceType: 1, nalRefIdc: 0);
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[
          _nal(9),
          nonReferenceB,
        ]),
        isTrue,
      );
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[
          nonReferenceB,
          slice(sliceType: 1, nalRefIdc: 0),
        ]),
        isTrue,
      );
    });

    test('fails closed for references, non-B slices, and parameter sets', () {
      final nonReferenceB = slice(sliceType: 1, nalRefIdc: 0);
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[
          slice(sliceType: 1, nalRefIdc: 2),
        ]),
        isFalse,
      );
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[
          slice(sliceType: 0, nalRefIdc: 0),
        ]),
        isFalse,
      );
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[
          _nal(7),
          nonReferenceB,
        ]),
        isFalse,
      );
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[
          Uint8List.fromList(<int>[0x01]),
        ]),
        isFalse,
      );
      final forbiddenHeader = Uint8List.fromList(nonReferenceB)..[0] |= 0x80;
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[forbiddenHeader]),
        isFalse,
      );
      expect(
        isDisposableNonReferenceBAccessUnit(<Uint8List>[
          slice(sliceType: 1, nalRefIdc: 0),
          _nalFromBits(1, '${_ueBits(0)}${_ueBits(1)}${_ueBits(1)}')
            ..[0] = 0x01,
        ]),
        isFalse,
      );
    });

    test('proactively skips disposable B at high resolution', () {
      final nonReferenceB = slice(sliceType: 1, nalRefIdc: 0);

      expect(
        shouldSkipH264AccessUnitForSmoothPlayback(
          nals: <Uint8List>[nonReferenceB],
          latenessMs: 0,
          highResolution: true,
        ),
        isTrue,
      );
      expect(
        shouldSkipH264AccessUnitForSmoothPlayback(
          nals: <Uint8List>[nonReferenceB],
          latenessMs: 0,
          highResolution: false,
        ),
        isFalse,
      );
      expect(
        shouldSkipH264AccessUnitForSmoothPlayback(
          nals: <Uint8List>[nonReferenceB],
          latenessMs: 100,
          highResolution: false,
        ),
        isTrue,
      );
    });

    test('never skips reference B or P pictures for performance', () {
      expect(
        shouldSkipH264AccessUnitForSmoothPlayback(
          nals: <Uint8List>[slice(sliceType: 1, nalRefIdc: 2)],
          latenessMs: 1000,
          highResolution: true,
        ),
        isFalse,
      );
      expect(
        shouldSkipH264AccessUnitForSmoothPlayback(
          nals: <Uint8List>[slice(sliceType: 0, nalRefIdc: 0)],
          latenessMs: 1000,
          highResolution: true,
        ),
        isFalse,
      );
    });
  });

  group('Annex-B scanner', () {
    test('handles mixed start codes and trims all delimiter zero bytes', () {
      final stream = Uint8List.fromList(<int>[
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x67,
        0x42,
        0x00,
        0x00,
        0x01,
        0x68,
        0xce,
        0x00,
        0x00,
      ]);

      final units = splitAnnexBNalUnits(stream);
      expect(units, hasLength(2));
      expect(units[0].bytes, orderedEquals(<int>[0x67, 0x42]));
      expect(units[0].startOffset, 0);
      expect(units[0].payloadOffset, 5);
      expect(units[1].bytes, orderedEquals(<int>[0x68, 0xce]));
      expect(splitAnnexBNals(stream), hasLength(2));
    });

    test('ignores empty units between consecutive start codes', () {
      final stream = Uint8List.fromList(<int>[
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x01,
        0x65,
        0x80,
      ]);
      expect(splitAnnexBNals(stream).single, orderedEquals(<int>[0x65, 0x80]));
    });
  });

  group('all access-unit assembly', () {
    test('uses AUD and first_mb boundaries and retains additional slices', () {
      final sps = _nal(7, 0x42);
      final pps = _nal(8, 0xce);
      final units = buildAllAccessUnits(<Uint8List>[
        sps,
        pps,
        _nal(9, 0xf0),
        _nal(6),
        _slice(5, 0),
        _slice(5, 1),
        _nal(9, 0xf0),
        _slice(1, 0),
        _slice(1, 2),
        _nal(7, 0x4d),
        _nal(8, 0xef),
        _nal(6),
        _slice(1, 0),
      ]);

      expect(units, hasLength(3));
      expect(_types(units[0]), <int>[7, 8, 9, 6, 5, 5]);
      expect(_types(units[1]), <int>[9, 1, 1]);
      expect(_types(units[2]), <int>[7, 8, 6, 1]);
      expect(units.map((unit) => unit.isIdr), <bool>[true, false, false]);
    });

    test('splits pictures without AUD when first_mb returns to zero', () {
      final units = buildAllAccessUnits(<Uint8List>[
        _slice(1, 0),
        _slice(1, 1),
        _slice(1, 0),
        _slice(1, 2),
      ]);

      expect(units, hasLength(2));
      expect(units[0].nals, hasLength(2));
      expect(units[1].nals, hasLength(2));
    });

    test('cached SPS/PPS are injected into a later IDR for seek reset', () {
      final sps = _nal(7, 0x42);
      final pps = _nal(8, 0xce);
      final idrOnly = buildIdrAccessUnits(<Uint8List>[
        sps,
        pps,
        _slice(1, 0),
        _slice(5, 0),
      ]);

      expect(idrOnly, hasLength(1));
      expect(_types(idrOnly.single), <int>[7, 8, 5]);
      expect(idrOnly.single.isKeyframe, isTrue);
    });

    test('future parameter sets are never injected into the previous IDR', () {
      final oldSps = _nal(7, 0x42);
      final oldPps = _nal(8, 0xce);
      final newSps = _nal(7, 0x4d);
      final units = buildAllAccessUnits(<Uint8List>[
        oldSps,
        oldPps,
        _slice(1, 0),
        _slice(5, 0),
        newSps,
        _slice(1, 0),
      ]);

      expect(_types(units[1]), <int>[7, 8, 5]);
      expect(identical(units[1].nals.first, oldSps), isTrue);
    });

    test(
      'injects the SPS referenced by the IDR active PPS, not the latest',
      () {
        final sps0 = _spsWithId(0);
        final pps0 = _ppsWithIds(0, 0);
        final sps1 = _spsWithId(1);
        final pps1 = _ppsWithIds(1, 1);
        final units = buildAllAccessUnits(<Uint8List>[
          sps0,
          pps0,
          sps1,
          pps1,
          _sliceWithPps(1, 1),
          _sliceWithPps(5, 0),
        ]);

        expect(units, hasLength(2));
        expect(_types(units[1]), <int>[7, 8, 5]);
        expect(identical(units[1].nals[0], sps0), isTrue);
        expect(identical(units[1].nals[1], pps0), isTrue);
      },
    );

    test('malformed VCL cannot silently merge two unknown pictures', () {
      final malformed = Uint8List.fromList(<int>[0x61]);
      final units = buildAllAccessUnits(<Uint8List>[malformed, malformed]);
      expect(units, hasLength(2));
    });

    test('first_mb parser accepts IDR and non-IDR VCL', () {
      expect(tryReadFirstMbInSlice(_slice(5, 0)), 0);
      expect(tryReadFirstMbInSlice(_slice(1, 2)), 2);
      expect(tryReadFirstMbInSlice(_nal(7)), isNull);
    });
  });
}
