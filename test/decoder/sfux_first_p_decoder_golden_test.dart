import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/decoder/rbsp.dart';

void main() {
  test('reconstructs the exact sfux IDR to first-P sequence pixel-exactly', () {
    final decoder = H264BaselineDecoder();
    final idr = decoder.decodeAccessUnit(<Uint8List>[
      _sfuxSps,
      _sfuxPps,
      _sfuxFirstIdr,
    ]);
    expect(idr, isNotNull, reason: decoder.lastError);

    final predicted = decoder.decodeAccessUnit(<Uint8List>[_sfuxFirstP]);
    expect(predicted, isNotNull, reason: decoder.lastError);
    expect(predicted!.width, 1236);
    expect(predicted.height, 720);
    expect(predicted.y, everyElement(32));
    expect(predicted.u, everyElement(127));
    expect(predicted.v, everyElement(127));
    expect(
      sha256.convert(<int>[
        ...predicted.y,
        ...predicted.u,
        ...predicted.v,
      ]).toString(),
      '87df45c5084804286ecf31e180eaaa8f1e8d0486dd9abf4666dff73322ff039b',
    );
    expect(decoder.lastStats?.frameNumber, 1);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 0);
    expect(decoder.lastStats?.interMacroblocks, 0);
    expect(decoder.lastStats?.skippedMacroblocks, 3510);
  });

  test('strictly rejects a non-skip CABAC P macroblock', () {
    final decoder = H264BaselineDecoder();
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_sfuxSps, _sfuxPps, _sfuxFirstIdr]),
      isNotNull,
      reason: decoder.lastError,
    );

    // Keep the exact parsed P header/alignment, but replace codIOffset with
    // zero. Its first mb_skip_flag consequently decodes as false, exercising
    // the bounded main-decoder rejection before any explicit MB syntax is
    // reconstructed.
    final frame = decoder.decodeAccessUnit(<Uint8List>[
      _withZeroCabacInitialOffset(_sfuxFirstP, arithmeticStartBit: 56),
    ]);
    expect(frame, isNull);
    expect(decoder.lastError, contains('Unsupported non-skip CABAC P'));
  });
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

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}

Uint8List _withZeroCabacInitialOffset(
  Uint8List nal, {
  required int arithmeticStartBit,
}) {
  final rbsp = ebspToRbsp(Uint8List.sublistView(nal, 1));
  for (var bit = arithmeticStartBit; bit < arithmeticStartBit + 9; bit++) {
    final byte = bit >> 3;
    rbsp[byte] &= ~(1 << (7 - (bit & 7)));
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
