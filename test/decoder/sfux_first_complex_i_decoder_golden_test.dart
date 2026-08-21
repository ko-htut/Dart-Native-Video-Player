import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/decoder/rbsp.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';

void main() {
  test('reconstructs exact sfux IDR, P, B, complex-I sequence', () {
    final decoder = H264BaselineDecoder();
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_sps, _pps, _idr]),
      isNotNull,
      reason: decoder.lastError,
    );
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_p]),
      isNotNull,
      reason: decoder.lastError,
    );
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_b]),
      isNotNull,
      reason: decoder.lastError,
    );

    final frame = decoder.decodeAccessUnit(<Uint8List>[_complexI]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(frame.y.first, 38);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '73e0d49ef1d4887bfe605a2a3f6ac4c11e9f60581d9f3c944ccbe56d183a7be0',
    );
    expect(decoder.lastStats?.frameNumber, 2);
    expect(decoder.lastStats?.pictureOrderCount, 6);
    expect(decoder.lastStats?.isReference, isTrue);
    expect(decoder.lastStats?.sliceType, H264SliceType.i);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 3510);
    expect(decoder.lastStats?.interMacroblocks, 0);
    expect(decoder.lastStats?.skippedMacroblocks, 0);
  });

  test('failed complex-I candidate rolls back before exact retry', () {
    final decoder = H264BaselineDecoder();
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_sps, _pps, _idr]),
      isNotNull,
      reason: decoder.lastError,
    );
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_p]),
      isNotNull,
      reason: decoder.lastError,
    );
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_b]),
      isNotNull,
      reason: decoder.lastError,
    );

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_complexI, arithmeticStartBit: 32, value: 0),
    ]);
    expect(rejected, isNull);

    // The failed nal_ref_idc != 0 picture must not publish POC 6, frame_num 2,
    // picture identity, or its staged DPB. The byte-exact candidate can retry
    // against the still-canonical POC4/reference-frame state.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_complexI]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      '73e0d49ef1d4887bfe605a2a3f6ac4c11e9f60581d9f3c944ccbe56d183a7be0',
    );
    expect(decoder.lastStats?.pictureOrderCount, 6);
    expect(decoder.lastStats?.isReference, isTrue);
  });
}

final Uint8List _sps = _hex(
  '67640028acd9c04e05be7f011000003e90000ea600f18319e0',
);
final Uint8List _pps = _hex('68e9b9cb22c0');
final Uint8List _idr = _hex(
  '6588840037fffedb5bf32cadd193c46d4b1c85777972cd4ee8ca19da792f'
  '53300000030000030000030000030086bdc12f77f1155715200000030000'
  '1fc0002a60005f40013300055c001920009d0003e8002380010d000b6000'
  '688004400000030000030000030000030000030000030000030000030000'
  '030000030000030000030000030000030000030000030000030000030000'
  '030000030000030000030000030000030000030000030000030000030000'
  '03000003000003000003000003000003000003000003000003001011',
);
final Uint8List _p = _hex(
  '419a226e810108fffa580000030000030000030000030000030000030000030000030356',
);
final Uint8List _b = _hex(
  '019e417908ff000003000003000003000003000003000003000003000004bd',
);
final Uint8List _complexI = _hex(
  '418890c0bffed469f32ca27368115265a2d6f7edd518142f837196656b52'
  '000003000003000003000003003308f90b4bf88aab8a9000000300000fc0'
  '0018e0003d8a17a001040003f00015000085000348001e2000e100088000'
  '6880044000000300000300000301b93ceee05530acfff671c7ec000ded80'
  '0026e2a0000003000026c0bcdf815074023214bb7216cc2800a25927353a'
  '874219353d2c2f7000002799a0f70a000dab9ddd8c9ef00006952d2b7e97'
  '7400023f3502c074bfd9018cfb2212a80000bb4a62baa5d90e9bb13c0001'
  'bf0087f335b0ed55c8000003000003000003000003000003000003000003'
  '000003000003000003000003000003000003000003000003000003000003'
  '00000300000300016f',
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
