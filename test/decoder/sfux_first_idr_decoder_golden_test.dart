import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';

void main() {
  test('reconstructs the exact compact sfux first IDR pixel-exactly', () {
    // Exact first access unit extracted from 250_00000.ts at
    // sfux-ext.sfux.info/hls/chapter/105/1588724110 on 2026-08-20.
    // The VCL is compact because the independently decoded picture is flat.
    final decoder = H264BaselineDecoder();
    final frame = decoder.decodeAccessUnit(<Uint8List>[
      _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
      _hex('68e9b9cb22c0'),
      _hex(
        '6588840037fffedb5bf32cadd193c46d4b1c85777972cd4ee8ca19da792f'
        '53300000030000030000030000030086bdc12f77f1155715200000030000'
        '1fc0002a60005f40013300055c001920009d0003e8002380010d000b6000'
        '688004400000030000030000030000030000030000030000030000030000'
        '030000030000030000030000030000030000030000030000030000030000'
        '030000030000030000030000030000030000030000030000030000030000'
        '03000003000003000003000003000003000003000003000003001011',
      ),
    ]);

    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(frame.y, everyElement(16));
    expect(frame.u, everyElement(127));
    expect(frame.v, everyElement(127));
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '7718b81849c25aa1ae5176326aff210031e9671ead9ea25a79216f9ca460de15',
    );
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 3510);
    expect(decoder.lastStats?.interMacroblocks, 0);
  });

  test('requires a decoded reference before the CABAC P_Skip subset', () {
    final decoder = H264BaselineDecoder();
    final frame = decoder.decodeAccessUnit(<Uint8List>[
      _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
      _hex('68e9b9cb22c0'),
      _hex(
        '419a226e810108fffa580000030000030000030000030000030000030000030000030356',
      ),
    ]);

    expect(frame, isNull);
    expect(
      decoder.lastError,
      contains('P picture has no decoded reference picture'),
    );
  });
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}
