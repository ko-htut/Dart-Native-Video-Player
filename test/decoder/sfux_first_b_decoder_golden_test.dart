import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/decoder/rbsp.dart';
import 'package:ndvy_player/src/player_clock.dart';
import 'package:ndvy_player/src/yuv.dart';

void main() {
  test('reconstructs exact sfux IDR, P, B decode order pixel-exactly', () {
    final decoder = H264BaselineDecoder();
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_sfuxSps, _sfuxPps, _sfuxFirstIdr]),
      isNotNull,
      reason: decoder.lastError,
    );
    final futureReference = decoder.decodeAccessUnit(<Uint8List>[_sfuxFirstP]);
    expect(futureReference, isNotNull, reason: decoder.lastError);
    expect(futureReference!.y, everyElement(32));

    final bPicture = decoder.decodeAccessUnit(<Uint8List>[_sfuxFirstB]);
    expect(bPicture, isNotNull, reason: decoder.lastError);
    expect(bPicture!.width, 1236);
    expect(bPicture.height, 720);
    expect(bPicture.y, everyElement(24));
    expect(bPicture.u, everyElement(127));
    expect(bPicture.v, everyElement(127));
    expect(
      sha256.convert(<int>[
        ...bPicture.y,
        ...bPicture.u,
        ...bPicture.v,
      ]).toString(),
      '577954d826c0a9a6f16aeeddaa7637a5099e89e4fa837ed636ebff548683205b',
    );
    expect(decoder.lastStats?.frameNumber, 2);
    expect(decoder.lastStats?.pictureOrderCount, 2);
    expect(decoder.lastStats?.isReference, isFalse);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 0);
    expect(decoder.lastStats?.interMacroblocks, 0);
    expect(decoder.lastStats?.skippedMacroblocks, 3510);
  });

  test('failed non-reference B candidate discards its POC transaction', () {
    final decoder = H264BaselineDecoder();
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_sfuxSps, _sfuxPps, _sfuxFirstIdr]),
      isNotNull,
      reason: decoder.lastError,
    );
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_sfuxFirstP]),
      isNotNull,
      reason: decoder.lastError,
    );

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_sfuxFirstB, arithmeticStartBit: 40, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastError, contains('CABAC B macroblock'));

    // A failed candidate must not publish POC or DPB state. Retrying the exact
    // non-reference B picture therefore still derives POC 2 from reference POC
    // 4 and reconstructs the same midpoint.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_sfuxFirstB]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(recovered!.y, everyElement(24));
  });

  test(
    'failed reference P and failed IDR leave canonical picture state intact',
    () {
      final decoder = H264BaselineDecoder();
      expect(
        decoder.decodeAccessUnit(<Uint8List>[
          _sfuxSps,
          _sfuxPps,
          _sfuxFirstIdr,
        ]),
        isNotNull,
        reason: decoder.lastError,
      );

      final rejectedReference = decoder.decodeAccessUnit(<Uint8List>[
        _withCabacInitialOffset(_sfuxFirstP, arithmeticStartBit: 56, value: 0),
      ]);
      expect(rejectedReference, isNull);
      expect(decoder.lastError, contains('Unsupported non-skip CABAC P'));

      // The failed nal_ref_idc != 0 candidate did not advance POC, frame_num,
      // picture identity, or replace the IDR in the DPB.
      final pPicture = decoder.decodeAccessUnit(<Uint8List>[_sfuxFirstP]);
      expect(pPicture, isNotNull, reason: decoder.lastError);
      expect(pPicture!.y, everyElement(32));

      final rejectedIdr = decoder.decodeAccessUnit(<Uint8List>[
        _withCabacInitialOffset(
          _sfuxFirstIdr,
          arithmeticStartBit: 40,
          value: 0,
        ),
      ]);
      expect(rejectedIdr, isNull);

      // A failed IDR used an empty working DPB but did not clear the canonical
      // IDR/P references. The dependent non-reference B can still resolve POC
      // 0/4, frame_num 2, and its two reference lists.
      final bPicture = decoder.decodeAccessUnit(<Uint8List>[_sfuxFirstB]);
      expect(bPicture, isNotNull, reason: decoder.lastError);
      expect(bPicture!.y, everyElement(24));
    },
  );

  test('decode pump presents B before its already-decoded future P', () async {
    final decoder = H264BaselineDecoder();
    final decoded = <String>[];
    final presented = <String>[];
    final pump = SequentialDecodePump<_AccessUnit, Yuv420Frame>(
      timestampOf: (item) => item.ptsMs,
      decode: (item) {
        decoded.add(item.name);
        return decoder.decodeAccessUnitOrThrow(item.nals);
      },
      onLatestDecoded: (item, frame) {
        presented.add(item.name);
        if (item.name == 'b2') expect(frame.y, everyElement(24));
        if (item.name == 'p4') expect(frame.y, everyElement(32));
      },
      onDecodeError: (_, error, _) => fail('decode failed: $error'),
      presentationMayBeReordered: true,
    );
    pump.replaceQueue(<_AccessUnit>[
      _AccessUnit('idr0', 0, <Uint8List>[_sfuxSps, _sfuxPps, _sfuxFirstIdr]),
      _AccessUnit('p4', 80, <Uint8List>[_sfuxFirstP]),
      _AccessUnit('b2', 40, <Uint8List>[_sfuxFirstB]),
    ]);

    pump.requestThrough(40);
    await pump.waitUntilIdle();
    expect(decoded, <String>['idr0', 'p4', 'b2']);
    expect(presented, <String>['b2']);

    pump.requestThrough(80);
    await pump.waitUntilIdle();
    expect(decoded, <String>['idr0', 'p4', 'b2']);
    expect(presented, <String>['b2', 'p4']);
    pump.dispose();
  });
}

final class _AccessUnit {
  const _AccessUnit(this.name, this.ptsMs, this.nals);

  final String name;
  final int ptsMs;
  final List<Uint8List> nals;
}

final Uint8List _sfuxSps = _hex(
  '67640028acd9c04e05be7f011000003e90000ea600f18319e0',
);
final Uint8List _sfuxPps = _hex('68e9b9cb22c0');
final Uint8List _sfuxFirstIdr = _hex(
  '6588840037fffedb5bf32cadd193c46d4b1c85777972cd4ee8ca19da792f'
  '53300000030000030000030000030086bdc12f77f1155715200000030000'
  '1fc0002a60005f40013300055c001920009d0003e8002380010d000b6000'
  '688004400000030000030000030000030000030000030000030000030000'
  '030000030000030000030000030000030000030000030000030000030000'
  '030000030000030000030000030000030000030000030000030000030000'
  '03000003000003000003000003000003000003000003000003001011',
);
final Uint8List _sfuxFirstP = _hex(
  '419a226e810108fffa580000030000030000030000030000030000030000030000030356',
);
final Uint8List _sfuxFirstB = _hex(
  '019e417908ff000003000003000003000003000003000003000003000004bd',
);

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}

Uint8List _withCabacInitialOffset(
  Uint8List nal, {
  required int arithmeticStartBit,
  required int value,
}) {
  RangeError.checkValueInInterval(value, 0, 509, 'value');
  final rbsp = ebspToRbsp(Uint8List.sublistView(nal, 1));
  for (var index = 0; index < 9; index++) {
    final bit = arithmeticStartBit + index;
    final byte = bit >> 3;
    final mask = 1 << (7 - (bit & 7));
    if ((value & (1 << (8 - index))) == 0) {
      rbsp[byte] &= ~mask;
    } else {
      rbsp[byte] |= mask;
    }
  }

  final escaped = <int>[nal.first];
  var zeroCount = 0;
  for (final byte in rbsp) {
    if (zeroCount >= 2 && byte <= 3) {
      escaped.add(3);
      zeroCount = 0;
    }
    escaped.add(byte);
    zeroCount = byte == 0 ? zeroCount + 1 : 0;
  }
  return Uint8List.fromList(escaped);
}
