import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';
import 'package:ndvy_player/src/decoder/rbsp.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';

void main() {
  test('reconstructs exact sfux IDR, P, B, I, complex-P sequence', () {
    final decoder = H264BaselineDecoder();
    _decodePrefix(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_complexP]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '65c92359e8964124a2c0dcdb2d3c1a063000e080b3d2b09719be1eef1925ab88',
    );
    expect(decoder.lastStats?.frameNumber, 3);
    expect(decoder.lastStats?.pictureOrderCount, 10);
    expect(decoder.lastStats?.isReference, isTrue);
    expect(decoder.lastStats?.sliceType, H264SliceType.p);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 273);
    expect(decoder.lastStats?.interMacroblocks, 4);
    expect(decoder.lastStats?.skippedMacroblocks, 3233);
  });

  test('failed complex-P candidate rolls back before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodePrefix(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_complexP, arithmeticStartBit: 144, value: 0),
    ]);
    expect(rejected, isNull);

    // A failed reference P must not publish POC10, frame_num 3, picture id,
    // previous-reference frame_num, or its staged DPB. The exact AU can retry
    // against the still-canonical complex-I POC6 state.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_complexP]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      '65c92359e8964124a2c0dcdb2d3c1a063000e080b3d2b09719be1eef1925ab88',
    );
    expect(decoder.lastStats?.frameNumber, 3);
    expect(decoder.lastStats?.pictureOrderCount, 10);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux sequence through complex-B POC8', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughComplexP(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_complexB]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '2cbe355edcd37f2ff8a4f305c3de8f233e5d730a664afbdd6c07718df4112abf',
    );
    expect(decoder.lastStats?.frameNumber, 4);
    expect(decoder.lastStats?.pictureOrderCount, 8);
    expect(decoder.lastStats?.isReference, isFalse);
    expect(decoder.lastStats?.sliceType, H264SliceType.b);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 271);
    expect(decoder.lastStats?.interMacroblocks, 0);
    expect(decoder.lastStats?.skippedMacroblocks, 3239);
  });

  test('failed complex-B candidate rolls back before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughComplexP(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_complexB, arithmeticStartBit: 40, value: 500),
    ]);
    expect(rejected, isNull);

    // The failed non-reference picture must not publish its POC transaction,
    // picture id, or stats. Retrying derives POC8 from the canonical POC10
    // reference state and retains the same L0=[6,4,0], L1=[10] ordering.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_complexB]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      '2cbe355edcd37f2ff8a4f305c3de8f233e5d730a664afbdd6c07718df4112abf',
    );
    expect(decoder.lastStats?.frameNumber, 4);
    expect(decoder.lastStats?.pictureOrderCount, 8);
    expect(decoder.lastStats?.isReference, isFalse);
  });

  test('reconstructs exact sfux sequence through second complex-P POC16', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughComplexB(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_secondComplexP]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '70ce91b2048835539d94b60cfd68ad17c8bbdfe10cf1fee4666bd851e622951d',
    );
    expect(decoder.lastStats?.frameNumber, 4);
    expect(decoder.lastStats?.pictureOrderCount, 16);
    expect(decoder.lastStats?.isReference, isTrue);
    expect(decoder.lastStats?.sliceType, H264SliceType.p);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 409);
    expect(decoder.lastStats?.interMacroblocks, 7);
    expect(decoder.lastStats?.skippedMacroblocks, 3094);
  });

  test('failed second complex-P candidate rolls back before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughComplexB(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(
        _secondComplexP,
        arithmeticStartBit: 160,
        value: 0,
      ),
    ]);
    expect(rejected, isNull);

    // The failed reference candidate must not publish frame_num 4, POC16,
    // picture id, previous-reference continuity, or its staged DPB. Retrying
    // must rebuild the repeated six-entry List0 from canonical POC10 state.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_secondComplexP]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      '70ce91b2048835539d94b60cfd68ad17c8bbdfe10cf1fee4666bd851e622951d',
    );
    expect(decoder.lastStats?.frameNumber, 4);
    expect(decoder.lastStats?.pictureOrderCount, 16);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux reference B POC12 with explicit inter', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughSecondComplexP(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_explicitInterB]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      'f64d3a330db1d3494c78b423f73903c3b2ac003d3d745d9ea0d153ec18222a3b',
    );
    expect(decoder.lastStats?.frameNumber, 5);
    expect(decoder.lastStats?.pictureOrderCount, 12);
    expect(decoder.lastStats?.isReference, isTrue);
    expect(decoder.lastStats?.sliceType, H264SliceType.b);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 3422);
    expect(decoder.lastStats?.interMacroblocks, 9);
    expect(decoder.lastStats?.skippedMacroblocks, 79);
  });

  test('failed explicit-inter B rolls back before exact MMCO retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughSecondComplexP(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(
        _explicitInterB,
        arithmeticStartBit: 56,
        value: 0,
      ),
    ]);
    expect(rejected, isNull);

    // Failed reconstruction must not publish POC12, frame_num 5, picture id,
    // or the staged MMCO1 removal. The retry still builds L0=[10,6,4,0] and
    // L1=[16], then removes PicNum0 and appends the reference B atomically.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_explicitInterB]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      'f64d3a330db1d3494c78b423f73903c3b2ac003d3d745d9ea0d153ec18222a3b',
    );
    expect(decoder.lastStats?.frameNumber, 5);
    expect(decoder.lastStats?.pictureOrderCount, 12);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux non-reference B POC14 with List1 inter', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughExplicitInterB(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_secondExplicitInterB]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '62a7a7370843613e387c83fa280bd2724be8ef6a5fabba35493acdb95e2bc692',
    );
    expect(decoder.lastStats?.frameNumber, 6);
    expect(decoder.lastStats?.pictureOrderCount, 14);
    expect(decoder.lastStats?.isReference, isFalse);
    expect(decoder.lastStats?.sliceType, H264SliceType.b);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 363);
    expect(decoder.lastStats?.interMacroblocks, 9);
    expect(decoder.lastStats?.skippedMacroblocks, 3138);
  });

  test('failed non-reference B POC14 rolls back before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughExplicitInterB(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(
        _secondExplicitInterB,
        arithmeticStartBit: 40,
        value: 500,
      ),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 5);
    expect(decoder.lastStats?.pictureOrderCount, 12);

    // A failed non-reference AU must not publish its POC transaction, picture
    // identity, stats, or disturb AU7's MMCO-created POC12 reference. Retrying
    // must rebuild L0=[12,10,6,4], L1=[16] and produce the same POC14 frame.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[
      _secondExplicitInterB,
    ]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      '62a7a7370843613e387c83fa280bd2724be8ef6a5fabba35493acdb95e2bc692',
    );
    expect(decoder.lastStats?.frameNumber, 6);
    expect(decoder.lastStats?.pictureOrderCount, 14);
    expect(decoder.lastStats?.isReference, isFalse);
  });

  test('reconstructs exact sfux reference P POC20 with P_16x8', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughSecondExplicitInterB(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_thirdComplexP]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      'd39c85e93fccf04b595e330af39e7e92494c0badbf162541d1c79ec9aa9b5437',
    );
    expect(decoder.lastStats?.frameNumber, 6);
    expect(decoder.lastStats?.pictureOrderCount, 20);
    expect(decoder.lastStats?.isReference, isTrue);
    expect(decoder.lastStats?.sliceType, H264SliceType.p);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 112);
    expect(decoder.lastStats?.interMacroblocks, 7);
    expect(decoder.lastStats?.skippedMacroblocks, 3391);
  });

  test('failed reference P POC20 rolls back before exact MMCO retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughSecondExplicitInterB(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(
        _thirdComplexP,
        arithmeticStartBit: 160,
        value: 0,
      ),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 6);
    expect(decoder.lastStats?.pictureOrderCount, 14);
    expect(decoder.lastStats?.isReference, isFalse);

    // The failed reference AU must not publish POC20/frame_num6, MMCO1's POC4
    // removal, the staged POC20 append, or picture identity. Retry rebuilds
    // the seven logical entries from the canonical five-picture DPB.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_thirdComplexP]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      'd39c85e93fccf04b595e330af39e7e92494c0badbf162541d1c79ec9aa9b5437',
    );
    expect(decoder.lastStats?.frameNumber, 6);
    expect(decoder.lastStats?.pictureOrderCount, 20);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('successful AU7 MMCO removes PicNum0 for the next picture', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughSecondComplexP(decoder);
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_explicitInterB]),
      isNotNull,
      reason: decoder.lastError,
    );

    // The next frame_num=6 P probe explicitly reorders PicNum0 into List0.
    // AU7's committed MMCO1 must have removed it while retaining/appending
    // frames 1..5, so list construction fails before CABAC payload decoding.
    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _removedPicNum0Probe(),
    ]);
    expect(rejected, isNull);
    expect(
      decoder.lastError,
      contains('Reference-list reordering selects unavailable PicNum 0'),
    );
    expect(decoder.lastStats?.frameNumber, 5);
    expect(decoder.lastStats?.pictureOrderCount, 12);
  });

  test('reconstructs exact sfux eight-reference P POC24 with P_8x16', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughPoc22(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_eightReferenceP]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '867c04741b577cb3f44687534f020448dd9846f6aa5763217a21931e222b4e05',
    );
    expect(decoder.lastStats?.frameNumber, 8);
    expect(decoder.lastStats?.pictureOrderCount, 24);
    expect(decoder.lastStats?.isReference, isTrue);
    expect(decoder.lastStats?.sliceType, H264SliceType.p);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 79);
    expect(decoder.lastStats?.interMacroblocks, 7);
    expect(decoder.lastStats?.skippedMacroblocks, 3424);
  });

  test('failed eight-reference P rolls back before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughPoc22(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(
        _eightReferenceP,
        arithmeticStartBit: 152,
        value: 0,
      ),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 7);
    expect(decoder.lastStats?.pictureOrderCount, 22);
    expect(decoder.lastStats?.isReference, isTrue);

    // A failed reference candidate must not publish POC24/frame_num8, picture
    // identity, previous-reference continuity, or the staged sliding-window
    // eviction. Retry must rebuild all eight logical List0 entries from the
    // canonical six-picture DPB and reproduce the exact frame.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_eightReferenceP]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      '867c04741b577cb3f44687534f020448dd9846f6aa5763217a21931e222b4e05',
    );
    expect(decoder.lastStats?.frameNumber, 8);
    expect(decoder.lastStats?.pictureOrderCount, 24);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('successful POC24 sliding window evicts frame2 POC6', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughPoc22(decoder);
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_eightReferenceP]),
      isNotNull,
      reason: decoder.lastError,
    );

    // The next frame_num=9 probe explicitly selects PicNum2. AU12 must have
    // evicted that oldest reference (POC6) before appending frame8/POC24.
    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _removedFrame2AfterAu12Probe(),
    ]);
    expect(rejected, isNull);
    expect(
      decoder.lastError,
      contains('Reference-list reordering selects unavailable PicNum 2'),
    );
    expect(decoder.lastStats?.frameNumber, 8);
    expect(decoder.lastStats?.pictureOrderCount, 24);
  });

  test('reconstructs exact sfux POC26 with CABAC Intra4x4', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughEightReferenceP(decoder);

    final frame = decoder.decodeAccessUnit(<Uint8List>[_firstIntra4P]);
    expect(frame, isNotNull, reason: decoder.lastError);
    expect(frame!.width, 1236);
    expect(frame.height, 720);
    expect(
      sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
      '60050f2a440f023b484b8a7d4ea7876026b2d36c10becce5a70ff5a662b9123c',
    );
    expect(decoder.lastStats?.frameNumber, 9);
    expect(decoder.lastStats?.pictureOrderCount, 26);
    expect(decoder.lastStats?.isReference, isTrue);
    expect(decoder.lastStats?.sliceType, H264SliceType.p);
    expect(decoder.lastStats?.macroblockCount, 3510);
    expect(decoder.lastStats?.intraMacroblocks, 100);
    expect(decoder.lastStats?.interMacroblocks, 7);
    expect(decoder.lastStats?.skippedMacroblocks, 3403);
  });

  test('failed CABAC Intra4x4 P rolls back before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughEightReferenceP(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_firstIntra4P, arithmeticStartBit: 152, value: 0),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 8);
    expect(decoder.lastStats?.pictureOrderCount, 24);
    expect(decoder.lastStats?.isReference, isTrue);

    // The partially decoded Intra4x4 modes, reconstructed blocks, residual,
    // POC/frame-number transaction, picture id, and staged DPB eviction all
    // belong to scratch state. Retrying from canonical POC24 must be exact.
    final recovered = decoder.decodeAccessUnit(<Uint8List>[_firstIntra4P]);
    expect(recovered, isNotNull, reason: decoder.lastError);
    expect(
      sha256.convert(<int>[
        ...recovered!.y,
        ...recovered.u,
        ...recovered.v,
      ]).toString(),
      '60050f2a440f023b484b8a7d4ea7876026b2d36c10becce5a70ff5a662b9123c',
    );
    expect(decoder.lastStats?.frameNumber, 9);
    expect(decoder.lastStats?.pictureOrderCount, 26);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test(
    'reconstructs exact sfux AU14-AU17 and exercises inter luma 4x4 residual',
    () {
      // These four VCL NALs are byte-for-byte AUs 14..17 demuxed from
      // /tmp/sfux-audit.N51PSH/250_00000.ts. The frame hashes below come from
      // an independent FFmpeg 7.1.1 oracle:
      //
      // /private/tmp/ndvy-ffmpeg/ffmpeg -hide_banner -loglevel error
      // -threads 1 -i /tmp/sfux-audit.N51PSH/250_00000.ts -map 0:v:0 -an
      // -f framehash -hash sha256 -
      //
      // Decode order differs from presentation order: AU14/POC30 is frame 15,
      // AU15/POC28 is frame 14, AU16/POC34 is frame 17, and AU17/POC32 is
      // frame 16. FFmpeg reports cropped 1236x720 I420 frames (1,334,880 B).
      expect(
        (_au14.length, sha256.convert(_au14).toString()),
        (
          316,
          'aa574129c5a16bf65f1fc96a1d711fa662cb2e69b0bad98624da55e709787e39',
        ),
      );
      expect(
        (_au15.length, sha256.convert(_au15).toString()),
        (
          65,
          'dcbecb8354e59409495167f1f1848a3bc3d6b7e87229eca317ca18313c6da5e8',
        ),
      );
      expect(
        (_au16.length, sha256.convert(_au16).toString()),
        (
          331,
          '5a713bb58576bcb2809069f2294008d71a83754dda4f7c733c9eea318816d1e7',
        ),
      );
      expect(
        (_au17.length, sha256.convert(_au17).toString()),
        (
          317,
          'ce659ce705c4ac64ce3066f7beb65f74a608784f77cd4ab4a6940e72e072ad71',
        ),
      );

      final decoder = H264BaselineDecoder();
      _decodeThroughFirstIntra4P(decoder);

      _expectExactFrame(
        decoder: decoder,
        nal: _au14,
        hash:
            '02a7ae3b99f4f0d8d2f8ab275fd5d1de4267194ffdb6f791dff79fd148b4a4e3',
        frameNumber: 10,
        pictureOrderCount: 30,
        sliceType: H264SliceType.p,
        isReference: true,
        intraMacroblocks: 132,
        interMacroblocks: 4,
        skippedMacroblocks: 3374,
      );
      _expectExactFrame(
        decoder: decoder,
        nal: _au15,
        hash:
            '635c7110ea9444a8f3aaf0b37c6ffbce76bc22eb6a84333c92a2e2d2618784b2',
        frameNumber: 11,
        pictureOrderCount: 28,
        sliceType: H264SliceType.b,
        isReference: false,
        intraMacroblocks: 10,
        interMacroblocks: 2,
        skippedMacroblocks: 3498,
      );

      final traces = <String>[];
      final previousTrace = h264DecoderTrace;
      try {
        h264DecoderTrace = traces.add;
        _expectExactFrame(
          decoder: decoder,
          nal: _au16,
          hash:
              '473a03e23bb6ef7f24c247d3d5407c1e387c7b2a3d0f5aa8fb288e3fd06a0f15',
          frameNumber: 11,
          pictureOrderCount: 34,
          sliceType: H264SliceType.p,
          isReference: true,
          intraMacroblocks: 106,
          interMacroblocks: 4,
          skippedMacroblocks: 3400,
        );
      } finally {
        h264DecoderTrace = previousTrace;
      }
      expect(
        traces.where(
          (line) =>
              line.contains('cabac p mb=1815 ') &&
              line.contains('p16x16 part=0 ref=1 mvd=0,0 ') &&
              line.contains('cbpL=5 cbpC=0 transform8=false'),
        ),
        hasLength(1),
        reason:
            'AU16 must execute the inter-luma 4x4 residual branch, not the '
            'already-covered transform-8x8 branch',
      );

      _expectExactFrame(
        decoder: decoder,
        nal: _au17,
        hash:
            '2a0e2c44fa545b3b6335ca011c154e4663455a16d6f6f31e4916ec514acff47b',
        frameNumber: 12,
        pictureOrderCount: 32,
        sliceType: H264SliceType.b,
        isReference: false,
        intraMacroblocks: 220,
        interMacroblocks: 5,
        skippedMacroblocks: 3285,
      );
    },
  );

  test('failed AU16 rolls back before exact 4x4-residual retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu15(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au16, arithmeticStartBit: 144, value: 0),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 11);
    expect(decoder.lastStats?.pictureOrderCount, 28);
    expect(decoder.lastStats?.isReference, isFalse);

    // A failed reference P must not publish POC34/frame_num11, picture id,
    // previous-reference continuity, or its staged sliding-window update.
    // Retrying must reconstruct the transformSize8x8=false inter residual
    // against the canonical AU15/POC28 state and remain usable by AU17.
    _expectExactFrame(
      decoder: decoder,
      nal: _au16,
      hash: '473a03e23bb6ef7f24c247d3d5407c1e387c7b2a3d0f5aa8fb288e3fd06a0f15',
      frameNumber: 11,
      pictureOrderCount: 34,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 106,
      interMacroblocks: 4,
      skippedMacroblocks: 3400,
    );
    _expectExactFrame(
      decoder: decoder,
      nal: _au17,
      hash: '2a0e2c44fa545b3b6335ca011c154e4663455a16d6f6f31e4916ec514acff47b',
      frameNumber: 12,
      pictureOrderCount: 32,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 220,
      interMacroblocks: 5,
      skippedMacroblocks: 3285,
    );
  });

  test('reconstructs exact sfux AU18 with ref-index 2 and cross-size MPM', () {
    expect(
      (_au18.length, sha256.convert(_au18).toString()),
      (479, 'd2b8388bfbe9f0417890b743f22858fbd78ce10f4f67b7bbaea45538a04881a2'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu17(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au18,
        hash:
            'e6426859831b9c4186538198fe731e32c054dcfa9f0876f862c98f812f1c74d6',
        frameNumber: 12,
        pictureOrderCount: 36,
        sliceType: H264SliceType.p,
        isReference: true,
        intraMacroblocks: 127,
        interMacroblocks: 2,
        skippedMacroblocks: 3381,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac p mb=1815 ') &&
            line.contains('p16x16 part=0 ref=2 mvd=0,-1 ') &&
            line.contains('cbpL=5 cbpC=0 transform8=false'),
      ),
      hasLength(1),
    );
    expect(
      traces.where(
        (line) =>
            line.contains('cabac p mb=2049 ') &&
            line.contains(
              'i4modes=[1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]',
            ),
      ),
      hasLength(1),
      reason:
          'Intra4x4 must inherit horizontal mode 1 from the facing '
          'Intra8x8 neighbour instead of substituting DC mode 2',
    );
  });

  test('failed AU18 rolls back before exact ref-index-2 retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu17(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au18, arithmeticStartBit: 144, value: 0),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 12);
    expect(decoder.lastStats?.pictureOrderCount, 32);
    expect(decoder.lastStats?.isReference, isFalse);

    // Ref-index decoding, cross-transform mode state, reconstruction, POC,
    // picture id, and the staged sixth DPB entry all remain transactional.
    _expectExactFrame(
      decoder: decoder,
      nal: _au18,
      hash: 'e6426859831b9c4186538198fe731e32c054dcfa9f0876f862c98f812f1c74d6',
      frameNumber: 12,
      pictureOrderCount: 36,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 127,
      interMacroblocks: 2,
      skippedMacroblocks: 3381,
    );
  });

  test('reconstructs exact sfux AU19 with reciprocal cross-size MPM', () {
    expect(
      (_au19.length, sha256.convert(_au19).toString()),
      (623, '9f8e4a134682362ebfe6259bdc9b064d3bc2fa6c77c7a4b77f9fcced90703ee4'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu18(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au19,
        hash:
            '6c5beebf067f0f621a985fbc85c2a1dc09bc1b6b88139afdee11af0079a8e510',
        frameNumber: 13,
        pictureOrderCount: 38,
        sliceType: H264SliceType.p,
        isReference: true,
        intraMacroblocks: 121,
        interMacroblocks: 33,
        skippedMacroblocks: 3356,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac p mb=1343 ') &&
            line.contains('i8modes=[2, 0, 0, 0]'),
      ),
      hasLength(1),
      reason:
          'Intra8x8 must inherit the facing Intra4x4 mode instead of '
          'substituting DC mode 2 for the available neighbour',
    );
  });

  test('AU19 raw reconstruction is pixel-exact without deblocking', () {
    final decoder = H264BaselineDecoder(enableDeblocking: false);
    _decodeThroughAu18(decoder);
    _expectExactFrame(
      decoder: decoder,
      nal: _au19,
      hash: 'b1118dd05e2a6ce871f729210a0213c8997c85977fbe12a145e796e59f3f9ddd',
      frameNumber: 13,
      pictureOrderCount: 38,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 121,
      interMacroblocks: 33,
      skippedMacroblocks: 3356,
    );
  });

  test('failed AU19 rolls back before exact reciprocal-MPM retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu18(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au19, arithmeticStartBit: 200, value: 0),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 12);
    expect(decoder.lastStats?.pictureOrderCount, 36);
    expect(decoder.lastStats?.isReference, isTrue);

    // Cross-transform modes, reconstruction, POC, picture id, and the staged
    // sliding-window eviction/append all remain private to the failed AU.
    _expectExactFrame(
      decoder: decoder,
      nal: _au19,
      hash: '6c5beebf067f0f621a985fbc85c2a1dc09bc1b6b88139afdee11af0079a8e510',
      frameNumber: 13,
      pictureOrderCount: 38,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 121,
      interMacroblocks: 33,
      skippedMacroblocks: 3356,
    );
  });

  test('reconstructs exact sfux AU20 with bounded P_8x8', () {
    expect(
      (_au20.length, sha256.convert(_au20).toString()),
      (
        1184,
        'a30c700f111b13c6557a724e81f55210e2e773eea4e5c202424dac5eb11fc220',
      ),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu19(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au20,
        hash:
            '06833011e7d3c7ad4b1a45fe61d8f76353a74c29a4839b7bf9f29df42de43670',
        frameNumber: 14,
        pictureOrderCount: 42,
        sliceType: H264SliceType.p,
        isReference: true,
        intraMacroblocks: 114,
        interMacroblocks: 31,
        skippedMacroblocks: 3365,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac p mb=1420 ') &&
            line.contains('p8x8 ') &&
            line.contains('part=0 ref=1 mvd=35,0 ') &&
            line.contains('part=1 ref=0 mvd=0,0 ') &&
            line.contains('part=2 ref=0 mvd=1,0 ') &&
            line.contains('part=3 ref=0 mvd=-1,0 ') &&
            line.contains('cbpL=14 cbpC=0 transform8=true'),
      ),
      hasLength(1),
    );
  });

  test('failed AU20 rolls back before exact P_8x8 retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu19(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au20, arithmeticStartBit: 168, value: 0),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 13);
    expect(decoder.lastStats?.pictureOrderCount, 38);
    expect(decoder.lastStats?.isReference, isTrue);

    // Sub-macroblock motion, reconstruction, POC, picture id, and both MMCO1
    // removals remain private to the failed access unit.
    _expectExactFrame(
      decoder: decoder,
      nal: _au20,
      hash: '06833011e7d3c7ad4b1a45fe61d8f76353a74c29a4839b7bf9f29df42de43670',
      frameNumber: 14,
      pictureOrderCount: 42,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 114,
      interMacroblocks: 31,
      skippedMacroblocks: 3365,
    );
  });

  test('reconstructs exact sfux AU21 with B_L0_16x16', () {
    expect(
      (_au21.length, sha256.convert(_au21).toString()),
      (103, '5886c91393da023e0685d76653fe320051c48402bc9b00b6eb46d562d80e01f2'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu20(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au21,
        hash:
            '0b75679972bf330cddd6126651ccfa8cd9de7050efa3a111ec816c2e5d5f4f20',
        frameNumber: 15,
        pictureOrderCount: 40,
        sliceType: H264SliceType.b,
        isReference: false,
        intraMacroblocks: 13,
        interMacroblocks: 10,
        skippedMacroblocks: 3487,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1349 ') &&
            line.contains('B_L0_16x16') &&
            line.contains('part=0 l0ref=1') &&
            line.contains('part=0 sub=0 l0mvd=0,-104') &&
            line.contains('cbpL=0 cbpC=1 transform8=false'),
      ),
      hasLength(1),
    );
  });

  test('failed AU21 rolls back before exact B_L0_16x16 retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu20(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au21, arithmeticStartBit: 40, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 14);
    expect(decoder.lastStats?.pictureOrderCount, 42);
    expect(decoder.lastStats?.isReference, isTrue);

    // Per-list CABAC/MVP state and reconstruction remain transactional. AU21
    // is non-reference, so neither the failed nor successful retry mutates DPB.
    _expectExactFrame(
      decoder: decoder,
      nal: _au21,
      hash: '0b75679972bf330cddd6126651ccfa8cd9de7050efa3a111ec816c2e5d5f4f20',
      frameNumber: 15,
      pictureOrderCount: 40,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 13,
      interMacroblocks: 10,
      skippedMacroblocks: 3487,
    );
  });

  test('reconstructs exact sfux AU22 after cross-transform CABAC CBF', () {
    expect(
      (_au22.length, sha256.convert(_au22).toString()),
      (
        1123,
        '52683b310a4ad91786b93b30b04bff7a46ef61f0aa5c33bc177247f8fa6ce998',
      ),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu21(decoder);
    _expectExactFrame(
      decoder: decoder,
      nal: _au22,
      hash: '2e34e61cff1b489aef246b6b638ff22c20c6d42e06bf0357a6ca051b1619ba18',
      frameNumber: 15,
      pictureOrderCount: 44,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 62,
      interMacroblocks: 85,
      skippedMacroblocks: 3363,
    );
  });

  test('failed AU22 rolls back before exact cross-transform CBF retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu21(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au22, arithmeticStartBit: 184, value: 0),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 15);
    expect(decoder.lastStats?.pictureOrderCount, 40);
    expect(decoder.lastStats?.isReference, isFalse);

    // Cross-category CBF state, reconstruction, POC, picture id, and the
    // staged reference append remain private to the failed candidate. The
    // retry must still build its seven-entry List0 from AU20's canonical DPB.
    _expectExactFrame(
      decoder: decoder,
      nal: _au22,
      hash: '2e34e61cff1b489aef246b6b638ff22c20c6d42e06bf0357a6ca051b1619ba18',
      frameNumber: 15,
      pictureOrderCount: 44,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 62,
      interMacroblocks: 85,
      skippedMacroblocks: 3363,
    );
  });

  test('reconstructs exact sfux AU25 reference B with two MMCO1s', () {
    expect(
      (_au25.length, sha256.convert(_au25).toString()),
      (87, '1da4e3713819a1331a77cdcbea5c75e41e66e37863d7b98c612a0dc877558d26'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu24(decoder);
    _expectExactFrame(
      decoder: decoder,
      nal: _au25,
      hash: 'cee07ebe77aa178026cce35507c5721447489731e2d0e255a37ef824786a32f3',
      frameNumber: 2,
      pictureOrderCount: 48,
      sliceType: H264SliceType.b,
      isReference: true,
      intraMacroblocks: 17,
      interMacroblocks: 5,
      skippedMacroblocks: 3488,
    );
  });

  test('successful AU25 removes both MMCO1 targets from the DPB', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu24(decoder);
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_au25]),
      isNotNull,
      reason: decoder.lastError,
    );

    // AU25 removes frame12/PicNum-4 and frame13/PicNum-3 sequentially. Each
    // failed probe is transactional, so both removed targets can be checked
    // independently against the same committed post-AU25 DPB.
    for (final differenceOfPicNumsMinus1 in <int>[6, 5]) {
      final rejected = decoder.decodeAccessUnit(<Uint8List>[
        _removedAu25ReferenceProbe(differenceOfPicNumsMinus1),
      ]);
      expect(rejected, isNull);
      final selectedPicNum = 3 - (differenceOfPicNumsMinus1 + 1);
      expect(
        decoder.lastError,
        contains(
          'Reference-list reordering selects unavailable PicNum '
          '$selectedPicNum',
        ),
      );
      expect(decoder.lastStats?.frameNumber, 2);
      expect(decoder.lastStats?.pictureOrderCount, 48);
      expect(decoder.lastStats?.isReference, isTrue);
    }
  });

  test('failed AU25 rolls back both MMCO1s before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu24(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au25, arithmeticStartBit: 64, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 1);
    expect(decoder.lastStats?.pictureOrderCount, 52);
    expect(decoder.lastStats?.isReference, isTrue);

    // Neither MMCO removal, the POC transaction, frame_num continuity,
    // picture identity, nor the POC48 append may escape a failed candidate.
    _expectExactFrame(
      decoder: decoder,
      nal: _au25,
      hash: 'cee07ebe77aa178026cce35507c5721447489731e2d0e255a37ef824786a32f3',
      frameNumber: 2,
      pictureOrderCount: 48,
      sliceType: H264SliceType.b,
      isReference: true,
      intraMacroblocks: 17,
      interMacroblocks: 5,
      skippedMacroblocks: 3488,
    );
  });

  test('reconstructs exact sfux AU26-AU33 transactional prefix', () {
    for (final expected in _au26To33) {
      expect(
        (expected.nal.length, sha256.convert(expected.nal).toString()),
        (expected.nalLength, expected.nalHash),
        reason:
            'decode-order AU${expected.decodeIndex} / presentation '
            'n=${expected.presentationIndex} fixture identity',
      );
    }
    final decoder = H264BaselineDecoder();
    _decodeThroughAu33(decoder);
    expect(decoder.lastStats?.frameNumber, 6);
    expect(decoder.lastStats?.pictureOrderCount, 68);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux AU34 partitioned and B_8x8 motion', () {
    expect(
      (_au34.length, sha256.convert(_au34).toString()),
      (297, '0b50884f52d65916266324c9ef22b8e982c2578696740387932a0347ce14725a'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu33(decoder);

    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au34,
        hash:
            'ebea4edd2554002c78300a049795d745aa6e2df8ab9a39eb5385c211d8cadfff',
        frameNumber: 7,
        pictureOrderCount: 66,
        sliceType: H264SliceType.b,
        isReference: false,
        intraMacroblocks: 29,
        interMacroblocks: 39,
        skippedMacroblocks: 3442,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }

    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1186 ') &&
            line.contains('B_L1_L0_8x16') &&
            line.contains('part=1 l0ref=0') &&
            line.contains('part=0 l1ref=0') &&
            line.contains('part=0 sub=0 l1mvd=0,0') &&
            line.contains('part=1 sub=0 l0mvd=0,0'),
      ),
      hasLength(1),
      reason: 'AU34 must retain separate List1-left/List0-right syntax state',
    );
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1583 ') &&
            line.contains('B_8x8') &&
            line.contains('subtype=0:0') &&
            line.contains('subtype=2:1') &&
            line.contains('part=2 l0ref=0') &&
            line.contains('part=2 sub=0 l0mvd=24,0') &&
            line.contains('transform8=true'),
      ),
      hasLength(1),
      reason: 'AU34 must reconstruct mixed Direct/List0 B_8x8 motion',
    );
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1658 ') &&
            line.contains('B_8x8') &&
            line.contains('subtype=2:1') &&
            line.contains('subtype=3:1') &&
            line.contains('part=2 l0ref=0') &&
            line.contains('part=3 l0ref=0') &&
            line.contains('transform8=true'),
      ),
      hasLength(1),
      reason: 'AU34 must retain both explicit List0 B_8x8 regions',
    );

    // AU34 is non-reference and signals no memory-management operation.
    // Replaying it must therefore rebuild the same lists from AU33's unchanged
    // DPB and derive the same non-reference POC from the retained reference
    // POC anchor; accidentally appending AU34 would perturb this exact hash.
    _expectExactFrame(
      decoder: decoder,
      nal: _au34,
      hash: 'ebea4edd2554002c78300a049795d745aa6e2df8ab9a39eb5385c211d8cadfff',
      frameNumber: 7,
      pictureOrderCount: 66,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 29,
      interMacroblocks: 39,
      skippedMacroblocks: 3442,
    );
  });

  test('failed AU34 rolls back before exact partitioned-B retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu33(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au34, arithmeticStartBit: 40, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 6);
    expect(decoder.lastStats?.pictureOrderCount, 68);
    expect(decoder.lastStats?.isReference, isTrue);

    // Pending per-list CABAC syntax, authoritative dual motion, POC, and
    // picture identity all stay scratch-local on failure. AU34 is non-ref and
    // carries no MMCO, so retry must use the unchanged AU33 reference DPB.
    _expectExactFrame(
      decoder: decoder,
      nal: _au34,
      hash: 'ebea4edd2554002c78300a049795d745aa6e2df8ab9a39eb5385c211d8cadfff',
      frameNumber: 7,
      pictureOrderCount: 66,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 29,
      interMacroblocks: 39,
      skippedMacroblocks: 3442,
    );
  });

  test('reconstructs exact sfux AU35 reference prefix', () {
    expect(
      (_au35.length, sha256.convert(_au35).toString()),
      (237, '4009c25d2bdc05d7a4b935a87fcadba48817bcebf70a56961119f56d6b975a4a'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu34(decoder);
    _expectExactFrame(
      decoder: decoder,
      nal: _au35,
      hash: '3fa2fa34c256d03d5bde6dac10b41f14f00e0d5b405bd144a1f52e354fb02092',
      frameNumber: 7,
      pictureOrderCount: 76,
      sliceType: H264SliceType.p,
      isReference: true,
      intraMacroblocks: 19,
      interMacroblocks: 21,
      skippedMacroblocks: 3470,
    );
  });

  test('reconstructs exact sfux AU36 reference B with B_L0_L0_8x16', () {
    expect(
      (_au36.length, sha256.convert(_au36).toString()),
      (82, '3f42645434e589d42bec38f8f97d303a199e8e7c069b7aa632a37ae361f68497'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu35(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au36,
        hash:
            'f7812df78d69e094cfe97a359487b3a5aef811bf5cca64d36fd2adec99c320df',
        frameNumber: 8,
        pictureOrderCount: 72,
        sliceType: H264SliceType.b,
        isReference: true,
        intraMacroblocks: 10,
        interMacroblocks: 20,
        skippedMacroblocks: 3480,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1813 ') &&
            line.contains('B_L0_L0_8x16') &&
            line.contains('part=0 l0ref=0') &&
            line.contains('part=1 l0ref=0') &&
            line.contains('part=0 sub=0 l0mvd=8,0') &&
            line.contains('part=1 sub=0 l0mvd=0,0') &&
            line.contains('cbpL=0 cbpC=0 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU36 must use vertical 8x16 MVPs for both List0 partitions',
    );
  });

  test('successful AU36 commits both MMCO1 removals', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu35(decoder);
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_au36]),
      isNotNull,
      reason: decoder.lastError,
    );

    // CurrPicNum 9 minus 8/6 selects the frame1 and frame3 references removed
    // sequentially by AU36. Each failed probe is itself transactional.
    for (final differenceOfPicNumsMinus1 in <int>[7, 5]) {
      final rejected = decoder.decodeAccessUnit(<Uint8List>[
        _removedAu36ReferenceProbe(differenceOfPicNumsMinus1),
      ]);
      expect(rejected, isNull);
      final selectedPicNum = 9 - (differenceOfPicNumsMinus1 + 1);
      expect(
        decoder.lastError,
        contains(
          'Reference-list reordering selects unavailable PicNum '
          '$selectedPicNum',
        ),
      );
      expect(decoder.lastStats?.frameNumber, 8);
      expect(decoder.lastStats?.pictureOrderCount, 72);
      expect(decoder.lastStats?.isReference, isTrue);
    }
  });

  test('failed AU36 rolls back both MMCO1s before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu35(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au36, arithmeticStartBit: 64, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 7);
    expect(decoder.lastStats?.pictureOrderCount, 76);
    expect(decoder.lastStats?.isReference, isTrue);

    // The type5 motion fields, POC transaction, both staged MMCO removals,
    // frame continuity, picture identity, and POC72 append must roll back.
    _expectExactFrame(
      decoder: decoder,
      nal: _au36,
      hash: 'f7812df78d69e094cfe97a359487b3a5aef811bf5cca64d36fd2adec99c320df',
      frameNumber: 8,
      pictureOrderCount: 72,
      sliceType: H264SliceType.b,
      isReference: true,
      intraMacroblocks: 10,
      interMacroblocks: 20,
      skippedMacroblocks: 3480,
    );
  });

  test('reconstructs exact sfux AU37 with second List1 reference', () {
    expect(
      (_au37.length, sha256.convert(_au37).toString()),
      (68, 'b950ac91162dd879c1981948eeb89182be3c6f37e717d89e02d2b08ae99c4158'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu36(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au37,
        hash:
            'f64d8df5064e0070269476fca9b254c32d207d7e8b54d1209c475da171728beb',
        frameNumber: 9,
        pictureOrderCount: 70,
        sliceType: H264SliceType.b,
        isReference: false,
        intraMacroblocks: 9,
        interMacroblocks: 13,
        skippedMacroblocks: 3488,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1192 ') &&
            line.contains('B_L1_16x16') &&
            line.contains('part=0 l1ref=1') &&
            line.contains('part=0 sub=0 l1mvd=0,0') &&
            line.contains('motion=-1:0,0/1:'),
      ),
      hasLength(1),
      reason: 'AU37 must retain List1[1] as the AU35/POC76 identity',
    );
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1422 ') &&
            line.contains('B_L1_L1_8x16') &&
            line.contains('part=0 l1ref=0') &&
            line.contains('part=1 l1ref=0') &&
            line.contains('part=0 sub=0 l1mvd=0,0') &&
            line.contains('part=1 sub=0 l1mvd=1,0') &&
            line.contains('cbpL=0 cbpC=0 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU37 must reconstruct both vertical List1 8x16 partitions',
    );
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1894 ') &&
            line.contains('B_L1_16x16') &&
            line.contains('part=0 l1ref=1') &&
            line.contains('motion=-1:0,0/1:'),
      ),
      hasLength(1),
      reason: 'AU37 must preserve the second List1 identity across the slice',
    );

    // AU37 is non-reference and carries no MMCO. Replaying it must rebuild
    // L0=[68,64,60] and L1=[72,76] from AU36's unchanged reference DPB.
    _expectExactFrame(
      decoder: decoder,
      nal: _au37,
      hash: 'f64d8df5064e0070269476fca9b254c32d207d7e8b54d1209c475da171728beb',
      frameNumber: 9,
      pictureOrderCount: 70,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 9,
      interMacroblocks: 13,
      skippedMacroblocks: 3488,
    );
  });

  test('failed AU37 rolls back before exact second-List1 retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu36(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au37, arithmeticStartBit: 40, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 8);
    expect(decoder.lastStats?.pictureOrderCount, 72);
    expect(decoder.lastStats?.isReference, isTrue);

    // List1[1] selection, per-list syntax/MVP state, POC, picture identity,
    // and the non-reference DPB decision are all scratch-local on failure.
    _expectExactFrame(
      decoder: decoder,
      nal: _au37,
      hash: 'f64d8df5064e0070269476fca9b254c32d207d7e8b54d1209c475da171728beb',
      frameNumber: 9,
      pictureOrderCount: 70,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 9,
      interMacroblocks: 13,
      skippedMacroblocks: 3488,
    );
  });

  test('reconstructs exact sfux AU38-AU46 transactional prefix', () {
    for (final expected in _au38To46) {
      expect(
        (expected.nal.length, sha256.convert(expected.nal).toString()),
        (expected.nalLength, expected.nalHash),
        reason:
            'decode-order AU${expected.decodeIndex} / presentation '
            'n=${expected.presentationIndex} fixture identity',
      );
    }
    final decoder = H264BaselineDecoder();
    _decodeThroughAu46(decoder);
    expect(decoder.lastStats?.frameNumber, 14);
    expect(decoder.lastStats?.pictureOrderCount, 94);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux AU47 horizontal B partitions', () {
    expect(
      (_au47.length, sha256.convert(_au47).toString()),
      (112, '8289d8c7a7b6731f26b51b1067d8814ec26a8f4d566e1e99f24ea2da944212fa'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu46(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au47,
        hash:
            '9cabe407540c29d6d4aedab3d4845a86e215d357b2579b7f37297872a9a6f537',
        frameNumber: 15,
        pictureOrderCount: 92,
        sliceType: H264SliceType.b,
        isReference: false,
        intraMacroblocks: 7,
        interMacroblocks: 31,
        skippedMacroblocks: 3472,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1358 ') &&
            line.contains('B_L0_L1_16x8') &&
            line.contains('part=0 l0ref=0') &&
            line.contains('part=1 l1ref=0') &&
            line.contains('part=0 sub=0 l0mvd=0,0') &&
            line.contains('part=1 sub=0 l1mvd=47,0') &&
            line.contains('cbpL=0 cbpC=0 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU47 code8 must retain its top-List0/bottom-List1 syntax',
    );
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1514 ') &&
            line.contains('B_L1_L0_16x8') &&
            line.contains('part=1 l0ref=0') &&
            line.contains('part=0 l1ref=0') &&
            line.contains('part=1 sub=0 l0mvd=0,0') &&
            line.contains('part=0 sub=0 l1mvd=0,-17') &&
            line.contains('cbpL=1 cbpC=0 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU47 code10 must decode references and MVDs in list order',
    );
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1592 ') &&
            line.contains('B_L1_L1_16x8') &&
            line.contains('part=0 l1ref=0') &&
            line.contains('part=1 l1ref=0') &&
            line.contains('part=0 sub=0 l1mvd=0,0') &&
            line.contains('part=1 sub=0 l1mvd=46,32') &&
            line.contains('cbpL=0 cbpC=0 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU47 code6 must retain both horizontal List1 partitions',
    );

    // AU47 is non-reference and carries no MMCO. Replaying it must rebuild
    // L0=[90,88,86,84] and L1=[94] from AU46's unchanged reference DPB.
    _expectExactFrame(
      decoder: decoder,
      nal: _au47,
      hash: '9cabe407540c29d6d4aedab3d4845a86e215d357b2579b7f37297872a9a6f537',
      frameNumber: 15,
      pictureOrderCount: 92,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 7,
      interMacroblocks: 31,
      skippedMacroblocks: 3472,
    );
  });

  test('failed AU47 rolls back before exact horizontal-B retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu46(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au47, arithmeticStartBit: 40, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 14);
    expect(decoder.lastStats?.pictureOrderCount, 94);
    expect(decoder.lastStats?.isReference, isTrue);

    // All pending partition syntax, per-list MVP state, reconstructed pixels,
    // POC, picture identity, and the non-reference DPB decision roll back.
    _expectExactFrame(
      decoder: decoder,
      nal: _au47,
      hash: '9cabe407540c29d6d4aedab3d4845a86e215d357b2579b7f37297872a9a6f537',
      frameNumber: 15,
      pictureOrderCount: 92,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 7,
      interMacroblocks: 31,
      skippedMacroblocks: 3472,
    );
  });

  test('reconstructs exact sfux AU48-AU54 transactional prefix', () {
    for (final expected in _au48To54) {
      expect(
        (expected.nal.length, sha256.convert(expected.nal).toString()),
        (expected.nalLength, expected.nalHash),
        reason:
            'decode-order AU${expected.decodeIndex} / presentation '
            'n=${expected.presentationIndex} fixture identity',
      );
    }
    final decoder = H264BaselineDecoder();
    _decodeThroughAu54(decoder);
    expect(decoder.lastStats?.frameNumber, 2);
    expect(decoder.lastStats?.pictureOrderCount, 110);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux AU55 B_L0_L0_16x8 with ref2', () {
    expect(
      (_au55.length, sha256.convert(_au55).toString()),
      (113, '001566ee11c1c80395b0d2677838254c505155ecfe3d2f94f5ebd1d256301164'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu54(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au55,
        hash:
            '29331d0b4d70b9cf26255313a3eea1df653a4440dec8594f5f9a478f57b8de5e',
        frameNumber: 3,
        pictureOrderCount: 108,
        sliceType: H264SliceType.b,
        isReference: false,
        intraMacroblocks: 18,
        interMacroblocks: 37,
        skippedMacroblocks: 3455,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1980 ') &&
            line.contains('B_L0_L0_16x8') &&
            line.contains('part=0 l0ref=2') &&
            line.contains('part=1 l0ref=0') &&
            line.contains('part=0 sub=0 l0mvd=0,3') &&
            line.contains('part=1 sub=0 l0mvd=0,0') &&
            line.contains('cbpL=0 cbpC=0 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU55 code4 must retain ref2 on its top List0 partition',
    );

    // AU55 is non-reference and carries no MMCO. Replaying it must rebuild
    // L0=[106,102,98,94] and L1=[110] from AU54's unchanged reference DPB.
    _expectExactFrame(
      decoder: decoder,
      nal: _au55,
      hash: '29331d0b4d70b9cf26255313a3eea1df653a4440dec8594f5f9a478f57b8de5e',
      frameNumber: 3,
      pictureOrderCount: 108,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 18,
      interMacroblocks: 37,
      skippedMacroblocks: 3455,
    );
  });

  test('failed AU55 rolls back before exact type4 retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu54(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au55, arithmeticStartBit: 40, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 2);
    expect(decoder.lastStats?.pictureOrderCount, 110);
    expect(decoder.lastStats?.isReference, isTrue);

    // The ref2 selection, both 16x8 partitions, per-list MVP state, pixels,
    // POC, picture identity, and non-reference DPB decision all roll back.
    _expectExactFrame(
      decoder: decoder,
      nal: _au55,
      hash: '29331d0b4d70b9cf26255313a3eea1df653a4440dec8594f5f9a478f57b8de5e',
      frameNumber: 3,
      pictureOrderCount: 108,
      sliceType: H264SliceType.b,
      isReference: false,
      intraMacroblocks: 18,
      interMacroblocks: 37,
      skippedMacroblocks: 3455,
    );
  });

  test('reconstructs exact sfux AU56-AU90 transactional prefix', () {
    for (final expected in _au56To90) {
      expect(
        (expected.nal.length, sha256.convert(expected.nal).toString()),
        (expected.nalLength, expected.nalHash),
        reason:
            'decode-order AU${expected.decodeIndex} / presentation '
            'n=${expected.presentationIndex} fixture identity',
      );
    }
    final decoder = H264BaselineDecoder();
    _decodeThroughAu90(decoder);
    expect(decoder.lastStats?.frameNumber, 5);
    expect(decoder.lastStats?.pictureOrderCount, 184);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux AU91 reference B_L0_L1_8x16', () {
    expect(
      (_au91.length, sha256.convert(_au91).toString()),
      (133, '60dfb90c08b657c2944716b8a7777dbd33e1cfffe51d73ba31c92d1df8c067d8'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu90(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au91,
        hash:
            '51b663e6701ce08d0e5c0babe81279eb0e8a7e3081ee5aece0db2d2592731a7e',
        frameNumber: 6,
        pictureOrderCount: 180,
        sliceType: H264SliceType.b,
        isReference: true,
        intraMacroblocks: 8,
        interMacroblocks: 38,
        skippedMacroblocks: 3464,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1656 ') &&
            line.contains('B_L0_L1_8x16') &&
            line.contains('part=0 l0ref=0') &&
            line.contains('part=1 l1ref=0') &&
            line.contains('part=0 sub=0 l0mvd=0,0') &&
            line.contains('part=1 sub=0 l1mvd=0,0') &&
            line.contains('cbpL=0 cbpC=1 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU91 code9 must retain its left-List0/right-List1 syntax',
    );
  });

  test('successful AU91 commits both MMCO1 removals', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu90(decoder);
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_au91]),
      isNotNull,
      reason: decoder.lastError,
    );

    // CurrPicNum 7 minus 8/5 selects the frame15 and frame2 references
    // removed sequentially by AU91. Each failed probe is transactional.
    for (final differenceOfPicNumsMinus1 in <int>[7, 4]) {
      final rejected = decoder.decodeAccessUnit(<Uint8List>[
        _removedAu91ReferenceProbe(differenceOfPicNumsMinus1),
      ]);
      expect(rejected, isNull);
      final selectedPicNum = 7 - (differenceOfPicNumsMinus1 + 1);
      expect(
        decoder.lastError,
        contains(
          'Reference-list reordering selects unavailable PicNum '
          '$selectedPicNum',
        ),
      );
      expect(decoder.lastStats?.frameNumber, 6);
      expect(decoder.lastStats?.pictureOrderCount, 180);
      expect(decoder.lastStats?.isReference, isTrue);
    }
  });

  test('failed AU91 rolls back both MMCO1s before exact retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu90(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au91, arithmeticStartBit: 64, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 5);
    expect(decoder.lastStats?.pictureOrderCount, 184);
    expect(decoder.lastStats?.isReference, isTrue);

    // Code9 syntax/motion, both staged MMCO removals, POC, picture identity,
    // frame continuity, pixels, and the POC180 append all remain scratch-local.
    _expectExactFrame(
      decoder: decoder,
      nal: _au91,
      hash: '51b663e6701ce08d0e5c0babe81279eb0e8a7e3081ee5aece0db2d2592731a7e',
      frameNumber: 6,
      pictureOrderCount: 180,
      sliceType: H264SliceType.b,
      isReference: true,
      intraMacroblocks: 8,
      interMacroblocks: 38,
      skippedMacroblocks: 3464,
    );
  });

  test('reconstructs exact sfux AU92-AU122 transactional prefix', () {
    for (final expected in _au92To122) {
      expect(
        (expected.nal.length, sha256.convert(expected.nal).toString()),
        (expected.nalLength, expected.nalHash),
        reason:
            'decode-order AU${expected.decodeIndex} / presentation '
            'n=${expected.presentationIndex} fixture identity',
      );
    }
    final decoder = H264BaselineDecoder();
    _decodeThroughAu122(decoder);
    expect(decoder.lastStats?.frameNumber, 1);
    expect(decoder.lastStats?.pictureOrderCount, 250);
    expect(decoder.lastStats?.isReference, isTrue);
  });

  test('reconstructs exact sfux AU123 B_8x8 with List1 subtype', () {
    expect(
      (_au123.length, sha256.convert(_au123).toString()),
      (128, '8583d53733326501375bb956b7ca34ce028af695a37fe59a194a688163ba25ed'),
    );
    final decoder = H264BaselineDecoder();
    _decodeThroughAu122(decoder);
    final traces = <String>[];
    final previousTrace = h264DecoderTrace;
    try {
      h264DecoderTrace = traces.add;
      _expectExactFrame(
        decoder: decoder,
        nal: _au123,
        hash:
            '691c9dab19386704d26a0b5cd0aa2c0b57cec9c8d290c8f19ebf5ab7154b69ae',
        frameNumber: 2,
        pictureOrderCount: 246,
        sliceType: H264SliceType.b,
        isReference: true,
        intraMacroblocks: 12,
        interMacroblocks: 49,
        skippedMacroblocks: 3449,
      );
    } finally {
      h264DecoderTrace = previousTrace;
    }
    expect(
      traces.where(
        (line) =>
            line.contains('cabac b mb=1898 ') &&
            line.contains('B_8x8') &&
            line.contains('subtype=0:0') &&
            line.contains('subtype=1:2') &&
            line.contains('subtype=2:0') &&
            line.contains('subtype=3:0') &&
            line.contains('part=1 l1ref=0') &&
            line.contains('part=1 sub=0 l1mvd=0,0') &&
            line.contains('part=1 sub=0 mode=list1') &&
            line.contains('cbpL=0 cbpC=0 transform8=false'),
      ),
      hasLength(1),
      reason: 'AU123 must retain its sole explicit B_L1_8x8 region',
    );
  });

  test('successful AU123 commits both MMCO1 removals', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu122(decoder);
    expect(
      decoder.decodeAccessUnit(<Uint8List>[_au123]),
      isNotNull,
      reason: decoder.lastError,
    );

    // AU123 removes wrapped frame12/PicNum-4, then frame13/PicNum-3.
    // A failed next-picture list probe must observe both removals without
    // mutating the successfully committed AU123 state.
    for (final differenceOfPicNumsMinus1 in <int>[6, 5]) {
      final rejected = decoder.decodeAccessUnit(<Uint8List>[
        _removedAu123ReferenceProbe(differenceOfPicNumsMinus1),
      ]);
      expect(rejected, isNull);
      final selectedPicNum = 3 - (differenceOfPicNumsMinus1 + 1);
      expect(
        decoder.lastError,
        contains(
          'Reference-list reordering selects unavailable PicNum '
          '$selectedPicNum',
        ),
      );
      expect(decoder.lastStats?.frameNumber, 2);
      expect(decoder.lastStats?.pictureOrderCount, 246);
      expect(decoder.lastStats?.isReference, isTrue);
    }
  });

  test('failed AU123 rolls back before exact List1-subtype retry', () {
    final decoder = H264BaselineDecoder();
    _decodeThroughAu122(decoder);

    final rejected = decoder.decodeAccessUnit(<Uint8List>[
      _withCabacInitialOffset(_au123, arithmeticStartBit: 64, value: 500),
    ]);
    expect(rejected, isNull);
    expect(decoder.lastStats?.frameNumber, 1);
    expect(decoder.lastStats?.pictureOrderCount, 250);
    expect(decoder.lastStats?.isReference, isTrue);

    // Subtype syntax, List1 motion, both staged MMCO removals, POC, picture
    // identity, pixels, and the reference-B append remain scratch-local.
    _expectExactFrame(
      decoder: decoder,
      nal: _au123,
      hash: '691c9dab19386704d26a0b5cd0aa2c0b57cec9c8d290c8f19ebf5ab7154b69ae',
      frameNumber: 2,
      pictureOrderCount: 246,
      sliceType: H264SliceType.b,
      isReference: true,
      intraMacroblocks: 12,
      interMacroblocks: 49,
      skippedMacroblocks: 3449,
    );
  });
}

void _expectExactFrame({
  required H264BaselineDecoder decoder,
  required Uint8List nal,
  required String hash,
  required int frameNumber,
  required int pictureOrderCount,
  required H264SliceType sliceType,
  required bool isReference,
  required int intraMacroblocks,
  required int interMacroblocks,
  required int skippedMacroblocks,
}) {
  final frame = decoder.decodeAccessUnit(<Uint8List>[nal]);
  expect(frame, isNotNull, reason: decoder.lastError);
  expect((frame!.width, frame.height), (1236, 720));
  expect(frame.y.length + frame.u.length + frame.v.length, 1334880);
  expect(
    sha256.convert(<int>[...frame.y, ...frame.u, ...frame.v]).toString(),
    hash,
  );
  expect(decoder.lastStats?.frameNumber, frameNumber);
  expect(decoder.lastStats?.pictureOrderCount, pictureOrderCount);
  expect(decoder.lastStats?.sliceType, sliceType);
  expect(decoder.lastStats?.isReference, isReference);
  expect(decoder.lastStats?.macroblockCount, 3510);
  expect(decoder.lastStats?.intraMacroblocks, intraMacroblocks);
  expect(decoder.lastStats?.interMacroblocks, interMacroblocks);
  expect(decoder.lastStats?.skippedMacroblocks, skippedMacroblocks);
}

void _decodeThroughAu15(H264BaselineDecoder decoder) {
  _decodeThroughFirstIntra4P(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au14]),
    isNotNull,
    reason: decoder.lastError,
  );
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au15]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu17(H264BaselineDecoder decoder) {
  _decodeThroughAu15(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au16]),
    isNotNull,
    reason: decoder.lastError,
  );
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au17]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu18(H264BaselineDecoder decoder) {
  _decodeThroughAu17(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au18]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu19(H264BaselineDecoder decoder) {
  _decodeThroughAu18(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au19]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu20(H264BaselineDecoder decoder) {
  _decodeThroughAu19(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au20]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu21(H264BaselineDecoder decoder) {
  _decodeThroughAu20(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au21]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu22(H264BaselineDecoder decoder) {
  _decodeThroughAu21(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au22]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu24(H264BaselineDecoder decoder) {
  _decodeThroughAu22(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au23]),
    isNotNull,
    reason: decoder.lastError,
  );
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au24]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu25(H264BaselineDecoder decoder) {
  _decodeThroughAu24(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au25]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu33(H264BaselineDecoder decoder) {
  _decodeThroughAu25(decoder);
  for (final expected in _au26To33) {
    _expectExactFrame(
      decoder: decoder,
      nal: expected.nal,
      hash: expected.frameHash,
      frameNumber: expected.frameNumber,
      pictureOrderCount: expected.pictureOrderCount,
      sliceType: expected.sliceType,
      isReference: expected.isReference,
      intraMacroblocks: expected.intraMacroblocks,
      interMacroblocks: expected.interMacroblocks,
      skippedMacroblocks: expected.skippedMacroblocks,
    );
  }
}

void _decodeThroughAu34(H264BaselineDecoder decoder) {
  _decodeThroughAu33(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au34]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu35(H264BaselineDecoder decoder) {
  _decodeThroughAu34(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au35]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu36(H264BaselineDecoder decoder) {
  _decodeThroughAu35(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au36]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu37(H264BaselineDecoder decoder) {
  _decodeThroughAu36(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au37]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu46(H264BaselineDecoder decoder) {
  _decodeThroughAu37(decoder);
  for (final expected in _au38To46) {
    _expectExactFrame(
      decoder: decoder,
      nal: expected.nal,
      hash: expected.frameHash,
      frameNumber: expected.frameNumber,
      pictureOrderCount: expected.pictureOrderCount,
      sliceType: expected.sliceType,
      isReference: expected.isReference,
      intraMacroblocks: expected.intraMacroblocks,
      interMacroblocks: expected.interMacroblocks,
      skippedMacroblocks: expected.skippedMacroblocks,
    );
  }
}

void _decodeThroughAu47(H264BaselineDecoder decoder) {
  _decodeThroughAu46(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au47]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu54(H264BaselineDecoder decoder) {
  _decodeThroughAu47(decoder);
  for (final expected in _au48To54) {
    _expectExactFrame(
      decoder: decoder,
      nal: expected.nal,
      hash: expected.frameHash,
      frameNumber: expected.frameNumber,
      pictureOrderCount: expected.pictureOrderCount,
      sliceType: expected.sliceType,
      isReference: expected.isReference,
      intraMacroblocks: expected.intraMacroblocks,
      interMacroblocks: expected.interMacroblocks,
      skippedMacroblocks: expected.skippedMacroblocks,
    );
  }
}

void _decodeThroughAu55(H264BaselineDecoder decoder) {
  _decodeThroughAu54(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_au55]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughAu90(H264BaselineDecoder decoder) {
  _decodeThroughAu55(decoder);
  for (final expected in _au56To90) {
    _expectExactFrame(
      decoder: decoder,
      nal: expected.nal,
      hash: expected.frameHash,
      frameNumber: expected.frameNumber,
      pictureOrderCount: expected.pictureOrderCount,
      sliceType: expected.sliceType,
      isReference: expected.isReference,
      intraMacroblocks: expected.intraMacroblocks,
      interMacroblocks: expected.interMacroblocks,
      skippedMacroblocks: expected.skippedMacroblocks,
    );
  }
}

void _decodeThroughAu91(H264BaselineDecoder decoder) {
  _decodeThroughAu90(decoder);
  _expectExactFrame(
    decoder: decoder,
    nal: _au91,
    hash: '51b663e6701ce08d0e5c0babe81279eb0e8a7e3081ee5aece0db2d2592731a7e',
    frameNumber: 6,
    pictureOrderCount: 180,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 8,
    interMacroblocks: 38,
    skippedMacroblocks: 3464,
  );
}

void _decodeThroughAu122(H264BaselineDecoder decoder) {
  _decodeThroughAu91(decoder);
  for (final expected in _au92To122) {
    _expectExactFrame(
      decoder: decoder,
      nal: expected.nal,
      hash: expected.frameHash,
      frameNumber: expected.frameNumber,
      pictureOrderCount: expected.pictureOrderCount,
      sliceType: expected.sliceType,
      isReference: expected.isReference,
      intraMacroblocks: expected.intraMacroblocks,
      interMacroblocks: expected.interMacroblocks,
      skippedMacroblocks: expected.skippedMacroblocks,
    );
  }
}

void _decodeThroughFirstIntra4P(H264BaselineDecoder decoder) {
  _decodeThroughEightReferenceP(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_firstIntra4P]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughEightReferenceP(H264BaselineDecoder decoder) {
  _decodeThroughPoc22(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_eightReferenceP]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughPoc22(H264BaselineDecoder decoder) {
  _decodeThroughPostMmcoB(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_poc22]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughPostMmcoB(H264BaselineDecoder decoder) {
  _decodeThroughThirdComplexP(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_postMmcoB]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughThirdComplexP(H264BaselineDecoder decoder) {
  _decodeThroughSecondExplicitInterB(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_thirdComplexP]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughSecondExplicitInterB(H264BaselineDecoder decoder) {
  _decodeThroughExplicitInterB(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_secondExplicitInterB]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughExplicitInterB(H264BaselineDecoder decoder) {
  _decodeThroughSecondComplexP(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_explicitInterB]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughSecondComplexP(H264BaselineDecoder decoder) {
  _decodeThroughComplexB(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_secondComplexP]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughComplexB(H264BaselineDecoder decoder) {
  _decodeThroughComplexP(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_complexB]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodeThroughComplexP(H264BaselineDecoder decoder) {
  _decodePrefix(decoder);
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_complexP]),
    isNotNull,
    reason: decoder.lastError,
  );
}

void _decodePrefix(H264BaselineDecoder decoder) {
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
  expect(
    decoder.decodeAccessUnit(<Uint8List>[_complexI]),
    isNotNull,
    reason: decoder.lastError,
  );
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
final Uint8List _complexP = _hex(
  '419a654be10843c86c057019d015c06900857ffde100001f2ddb48eb67eef7a7df073e26fca82e3382f7fdc025cfef6feb000876490d7fe00a1e26af9822c8e00723216c2fc12cf43000005f200d2935a981c00f27bd3c0ff1a6034d77ace5f52ca884ae73108c198b6f80b4c94f29cfa5d4000003001e2c2b503ae65a416fe807e7e11cb8dee606fdcbba238e091fc06c3bd1e2a01c2b2f69a842b9ac6994003725c8a32e1ca1aae1f1641ea3a29a3680a534f4f65007960e0315999abc5654e8d4b767ad7acfbc35ed92d4d1c3d9e3821ad405702e0160b0d6e85775a2f198331e91c75cf2e745e0b242ee6ad5381eb0b971b9e2004d946a038f29e15ea0b1bf637f3467820d8cd71e9870c0bb8bf1c964a6867e31ce3994964892f5ab13ef4f4990dc1a93a804730b47dbdf7b1527832e3dbed93fde75c8898887fbc0000003000003006ac1',
);
final Uint8List _complexB = _hex(
  '019e846e47ff000003000003000032f2b5cae5a30fcd3fcb5bfb026683243a1769a8f03d70b9da1832c3680ba6de8c81ec9151e093138352057069d3d3b52a49a8df2177be13a6fb2b23b44dcfa56a5f4f5a3128f21dcc34fd425af26787bfd8c1fae39202ee679e565c483898d53f4de20e0bd7199688098882880adfdf3b4c1470acd766cf9e93c4b36c454a23540485bf86d20a2bd40485bf86e44c055540485bf86e612268226c037a40c96a12268126c037a40c96a2ac1454a8090b7f0dcc5a8489a6fd8242dfc37316a2ac1a15',
);
final Uint8List _secondComplexP = _hex(
  '419a883c21087e43e0288215200ff80a21c0042bfffde10000e8fa387c5dce'
  'a723b039a0926d9e4aa83f1b4158361c480028597c724022031180000005ad'
  'cae17896424945f894c99f64500945c7170b335a0980d5b77d45aeb01dc0c'
  'c8744f926fe77346673bcb551d71c51280234a7d32cb48ddd7699369292dc3'
  '400eaa8febc7ff7ba20aefe8c8225f62594ae9b7bd9796118c6801fcb0dd7'
  'fceb4cacbd3eaa26dea79db93e2e887bb4a1687560004ceec60fa1f65fda4'
  '45992a2527a331b19dbd547a791e7475342cc5aa3560ca2d7c84adce8bd3e'
  '84684e8090043659d4532f740750499f6a1dd717960eeba6c90f7d77fdb5f'
  '44bf7a1d659e5dd65e8cd90c8034f11c0f02bdfb94cf2640c7dd1a0b0f2a'
  'e000d4c82ef6c48942bf915685bca85052c57dee659e10e7c9cd2b45b4a5a'
  '0e5b9692e2d83d7173efa8a9ab3d807651fa14dac2e1859557130b8723767'
  '6a447d0e6058fcd3f2a6567c8774f09ab9da102d3002c5ddce99c1e5a74c'
  '17dcd5e53a0310d7bdd52383e428b1fef8dfa5a7f3be6f6d222e5d44c392'
  '05e9ff8d11a09e432c3cbc3622968c30540000003000195',
);

final Uint8List _explicitInterB = _hex(
  '419ea664945c23fffb49ee0f9e636aa02aa70080bd4e27071dd4c919bef52af42ee70d1d8e0b6fefa3bc33128081db8c77efeba45ee62441fa73f45e9474da9ebd0a5aae4545586bbfc0085164424ca42eb31b69614d8565755e93799ec15d28a9eab500aeff4c963035824e829bcf023567895079ab3f80148ba38592f6a320fd6a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a68516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a647d6a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a6336a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a31222d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d4c0ed45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d4614f5a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a96fa8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b633516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516818a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d03145a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a0628b516ae16ff52f8b3b8bc9af189d32cb9fd34d40485bf86e62d45a8b516a2d45a8b516a2d45a8b516a2a9ad45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d455428b51731e02eb72147ad45a8b516a2d45a8b516a2d45a8b53b7a5c27b44d5a0c10c69d1cb4a7b4dbb6a33080fd2d6661cd81f4fbb1ad0d7ce72e78788cb851e5c19f3e00522e8e164bda8b516a2e61aa24e85122b4d65b6721fa36adcba1268be193609cd56d8b0302337d9b77cd094426c16bf48952eb6a2d45a8b516a2d45a8b5198197d7f110fa045b714724ee180c18ebd43645aa2aedb94a2d3930c9e81b3d6809abc55a8d22c6a164b5a8b516a1b5221f5a9d55546baceb74732ac578c60892c52300d5e6f7c4915cf39c08d59e253da537208d5c23e918d88d1946f3ac6bcf27e4858ca4c9da1e6e16d68a5106f438941b3ae5495b640f09a7344c90f780e988cb74d5aa53c4974a20bcce7c12f2d67890d830541ace81f92f751eb62aafac2e585c6f5fe8d17c046cf3482faf1f1d433dd1694f6a2d45a3c6b51697d929165f5482159f469df5bcf66acf129ed1356830431a7472d29ed45a8b516a2d430ea8b516a2d457b55d250ec9a6cf207dbc5dc03cacd0bbeab0bd9360abdb217b516a2d45a8b516a2d45a8b46ad16a2d45a8b52ff73803ad8e4b4d5ab3c4a7b44d5a0c10c69d1cb4a7b516a2d45a8b5168b6e2d45a8b516a5c2e8f16f8cbb9d572bac0485bf86e62d45a8b516a2d45a8b516a2d45a8b434116a2d45a8b50f773483a5410e565c95120bf2567894f689ab418218d3a39694f6a2d45a8ad07516a2d45a8b5101cf322c1d4642d465c64b10982c8a9a7590d6a2d45a8b516a2d45a8b516a0ef6d45a8b516a2d4684f4f1f312534482587573e4f1b42e0b34eb21ad45a8b516a2d45a8b516a2d454d1da8b516a2d45a8ac5d77187566b5aab6fc192d45a8b516a2d45a8b516a2d45a8b516a2d45a1b18b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b44a916a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b5168bbbad45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d1b8f5a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a36bb516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b50dcaa2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2b8dc5a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a498516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b515edfad45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d22fa8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b099d6a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b5169486d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d442928b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b0d3d6a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b51697ed45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d45a8b516a2d46651',
);

final Uint8List _secondExplicitInterB = _hex(
  '019ec76491ff0000030000155b17fab54c74763bfd35273893fc252865ab9c90f49217af25465b2c41ea57424dc5c9a72c6c830d9eec35f1576d294232c7b273ea257cbd2930d6300eefda85b73af12d3f69c252201bcbe0634ee52c72628717bdc33e28da0d77501c269ba348393af4ceb8f9b172ec6d4862b0b834e53da8b516a1fe86b7c378e71b24f6abd21f8b1a51e7c527647a4b455fa940d613da26ad0611c8b4e7edba0302a5ac2445e904273d3e7026d39429920c9090fb8edacc38006c97bb9a111d82bc6ccaf3d25fcb24718c3ce4cc654e9b9c1a1dbd46b9394cd73d69584db2ebcda4c0e06b12dc2901790fd1cc3b7b579b501c71ebad369d1ef7791cd854df609b37d271df78915d1be5963982d2f2e21bdc1071e41e0ecc2a8ac1c9f56ed2d458f872040d85e84589990f563fe98382f2e529129de9ef100f5bd169c42559350996a3e983a6b565d319dd7ff5a8b091c8350c15ad56c7c5ed74',
);

final Uint8List _thirdComplexP = _hex(
  '419aca4fa842105af21f03703440dc0c8005171ffffa580000030000030178e671c604ae3c0313a83f314c76d53d94002341000d81b86bf382ec5f7362defefde0b3f937f71e204349ce958e3aae6af09d7ddf6907a0593b3c481de55132e8ee868f11c834d13e39f3f593775b3dfaadb5d4b8081e2ea84a971f6d694826065683008433cd1faed2c1ec770a7f15e6cf5163210f7dcb895937f25c23db5cb02ef24d774e4e73e71b20ac4e72dbeb7cbf264fdedfc46f7eb91540213fb55b1b4878c2ff69ad398d5cd3580c8ccead89cba6850f5160e193cd34cf43011bcc96ee4fa517d295d7e54df25c01e94eac619cbed3a3c856ddb836eb6bdc51dbb08d8f6a081252df3d45489673a1770000030000030216',
);

final Uint8List _postMmcoB = _hex(
  '019ee96491ff0000030000030001a18e32f7f1daec8019fb52688cbf1d3e4f299ec983bb2405a97fd1b9de89844aeca45108c6b520012a363875d13276b257925709fd0772bf3aae64a590ac5683f030020e1a36b1b61a02b710000003000003000025e1',
);

final Uint8List _poc22 = _hex(
  '419aeb4fe1084296b23c502345025000847ffa580000030000030000ea798a94c5c8195b7b83e81647b4a1be83a7a540ee65dc84fddcb277f6c91450d33d9ac777131a3f9641898fbca3304b4bad073ea84a6e941cb8be30f786d6e5618d3a734864a1ab7280704f24ee0c0b72d8475f65a45e98396c9dd77e7f5ac4a78012095c79f9fa6b79cba6efeee32a6cfc726eea1489677bc28dca47ad7203ebcb3e739837319c4ca289d0e9441ba514978fd8d27b39d31e568e4733b7aed18054484fadd4ef114f3d3548aea62889a21bf07128bb22409526ca66097b582d192110cc1fa50493bec01dcbf3f32266f9f21ba4dd908b315bf050912ad6468b7509ac2a87bf2f29d850de905670f8aeac3fd4e685536c365afdf955ec91feeb165042a54996f7587f5c1ebb2dc8000003000003003960',
);

final Uint8List _eightReferenceP = _hex(
  '419b0c44784210e96b21f03902440e40880008fffa5800000300000300001d4dff0a7fba4f07a01bfa76254b333ef12e4649a7e3555f52783de18a22f31602f74e2fc697be4a769d0a9e20c4f83104dfe346cad80cdc0adbec047647e2ce66c227b1781ee49945f0e0fa3c2bfa8cb4203adb5de2e56823b650b4012ddf90a19f065f05d52b198a5a5e63247825d9b9e93280ff5605af898abc3b14156ff36e621c3ff5ac562a589211f64ec6ab07f0f97df850d283941c5e862704e0290cd3177a22a3a8fd12def3f28f3990d0512d2c8e586d9af960d2dc52c338ed1f2d67d678678ee1934fc8caae3d37e0ca1c76eefc61446cec7efd02d5d0000003000047c0',
);

final Uint8List _firstIntra4P = _hex(
  '419b2d44784210fa5a2170540dd0540e400084fffc8400000300000300000f3efd6f7ea0a417faa3bb1987cdb30673b75bdbe26700adea8cebe618b44b657ec4fd5183c5a8bf4d9b16d616fdb1c31257d60110d28e1e3d235a8f217b074ca0fa1f3f1c2501715a6abe337364f765719f66d4b9ea4f7265b4df9569b818a8f9513964da61d71bd8e48fceb380957d11510d06ccbd699334de565ed102a119a9e4899abbd5158caeeba95fa79c677bad4a3443e9329c70ed5a1479664a1177fe0dae7716649de8e199298c2a69f5afaca891e44cc84dd1f7b9b58579f4516febce54d1c4dd43dd651300c81c1382cba3a1476ba3efecaafe17b745f8015031daf7b7862bacfa2df8f1c5b18d4e3ff11658c35217f7f182d40247bd3b6cd13aa3f633cbf2735f9b8253816eefe8037613381303ba4b2033551f346b0a2b9841fa0d4000000300019f',
);

final Uint8List _au14 = _hex(
  '419b4f44784210fe94873409c076810205a034c09c0740005151b08ffa580000030000'
  '0300001dff31529a59b02259bdfbf75834c8f3f8cf44e09ec7519206cd72e78015e6e5'
  '25f833e1f7ee20f1883351000037ac7f955035047af65391a365cf1c5a234182eb340c'
  '99839200c0801f88ab4ba5995a0efe510e01bd8613000bc477f6a6fdc4c5c61f3ed07d'
  'a3ce426fc3854fb5aff51ca650b06644a84d3424842245fd43427161b7e7942cce545a'
  '22f5e5b279b0a657e5da2554549cf4a4558f7fd04c417e6cc7c835cfd32686184e7a87'
  'e9d454058e391b8690b927c6adcd0ce38ca893564d69d0467fc96ab51c7534c890deeb'
  'd72d2846aad381b989de6fbb63a39cfac0a712153abc2c9ab2964624b022ceddab8d80'
  'eab2d4f092c330369f187cd3befb7d132cdb32c1d6fbc5210adab20000030000030023'
  '61',
);

final Uint8List _au15 = _hex(
  '019f6e6491ff000003000003000006ff090aea9eb3c6162db8bcc59ba1c7a9043c986a'
  '0c1b2d578758013c85bfa155d9be5797f95c000003000003000003000293',
);

final Uint8List _au16 = _hex(
  '419b714fe10843fc87c0490940490b00145c7ffa5800000300000300001c9e2e9268b5'
  'fff62d0355646216d6b86353e1efa46fd41a4475d1ca13c47333b0049c463a9e2a2302'
  '1d7a452ab1167588bf5cbaffe58df38aeea7233f1c21fce659f00bdcfd21140428a958'
  '8b4b4182f949f96b11c85965cde1ea884cc73bfa020c8695bd4943ec1d9ef5ac4feb92'
  '53aa772dad8fed8dc7f536a05dd4d427d3ddc36e259536cd23da6d7ad52b1c5bb6eb27'
  '440ceb83d690b1ada100062d2d48b8d7256a23ecfc77089f4345c7642d3b1c6cd0b6a4'
  '3f872d5600294a06791de8673a1f69f3cea2e17bcc0e7316c9abcda69f9162fe22b7a9'
  '294151ddb614a197cd32dd9bae7eff1149a13813a52f04395549844a439d48d958221c'
  'cda7a5372aff0bc7dd91d05fbfede264dacb70a395cb062227a8a6f1f28c409848b679'
  '117629d5412c6c9ad8000003000006d4',
);

final Uint8List _au17 = _hex(
  '019f906491ff000003000003000034422ff5793762b4a0a8a58ff343a19c427b3c28ff'
  '93ae5a866a56b671c0bd7e63a101080b8b76df1bd76b97ad3a49585f8ca471d24e923a'
  'f1ba4a4fd3d0827b9a5ef0428dd18721c96e75c07b7e80ce39c4e1dbeaf535db035cad'
  '5b78ec9a49a67b96a2fadbe5f43881e595a074c182262c9493524f9af9a76941c3933f'
  'c2168d5f13a1253d6ce3e2a0ee191360d16db545584f03cbced15e9b7f2e2be58cb4da'
  '59136e2f2817f766e2c7640a8172d090f8678acd543fc986c3e64eac9426e51195cb12'
  'c20ce44df3b47c8a0bbfebf635cf626c8107b849f91f79da9ac6850901424d1ee39a36'
  'ea6bb10dace3febf635cf666e6ff1fa5b03f2bd03cfa67c22a52c74a98c42603ab47e3'
  'e0011e9f0c92122c400afd33725b8302e6f37e867cfccfdb892c7cf626ca63440ead4c'
  '2334',
);

final Uint8List _au18 = _hex(
  '419b924fe10843fc86c0b406340b40650008fffa5800000300000300001dc96eefa4bfb7769c18163848848b6d3c69975e1ad7adca55e732929b7e7f024cf25e9fae43d00c1e3acb45ecd6a8675e564b5eb87d320606f1e610d7e3e66773819167e0f23d67ddf9fa5a9cde43c7b80b3a568835ff33bd761c2871d0cd8017ebd3d536074a40113ca922304c132bc1188ed03001c6afc35756cc81688d24b323f19592051351dc7a840f9b79de08fb16ec3067ea0814fde32fba1116425b6230da2f28fddbc3d2ac4b8b070a5d7685c03d75a848b43041ec2eceb036d085ef6c9beec653beec846a637805cfeb1cd72eb09a09412de1097c46c65b3e875675db825d9e7cba32c8243d34a48558dbb1c529a9407faa879285a49d45f48ced642a6ed0e4daeeea29ccfe40ab9ebf8348478f6dfd44da4c4a01b92df6a31086af6911d910e8950a83c24b6c844e849194604baa6b963b41b22346a6dcbb27ffe4d49a6f6b71a0c09566dabc5423f070854a44bca6b7aee1e86f5adae44aa12cf61739e7aa179f036d2d335d1eaf2640d088c72f84166909e1c78f44d0b913e52918c3038285683724a12ea7aeb80f30450a0d77aaba099fee9e858c1687eaf12a8354556db6b2d5729458df424a6695fddf9002ad14efaa7f84d0000003000007ad',
);

final Uint8List _au19 = _hex(
  '419bb344784210ffc8734051010e0408118330144045000213fffc8400000300000300000f96ff878e16895905f823e443d7c5f73a5bb8069242fbabf9fd3e5cd36dd71305148d583a8c76416758530d7ce2ee8a837c0d4109a53344fc58565ed39043e08017b349294a26820f2f861b7c14f4a75da8392784055727fcd8d0485b3ad3b5b12945aeed69120dea2095390ceb3d4db756fde5df51109f6e7f1cccb3c22d76d34d97f1290f51663c3a6b86d311592171e3c26e293c8263c5f8e9c11b89e02220038d7202edbf22f64e9d5fa8242f55d6455cceabdac4f27dc5bd3517cdae57116345baeaaffd596f3fd35ad5054202632a4fd1de603701f13cb3116c7f3847b14e159f7972ca205989af3ed8a74570786f8a6a27ecd2bfac7adacaa3a7f1e6f592bc431d9d79aa2e4334f1ae512dcad8107e895736c5f7c88f45a0ff909e17f794145869f9d838c7493ee43b563369f107878d948c01209b33573899f3a7c60ea50e8d1e9cc032302fbd2ee2f24072a6c5364a3c8e693ffe22fbf558e9655d8d9f0f0ebe5f4890240c174c9f2e15501d8ec887272868dddb4899c73f1fab43f02285472f8b43887b5f78c61cd58a96c7cb900d2bb0ccd7cf5d594498ba1c95d65176c37f40f840e90a62e085bbcfecae84a3c390bbbbcd0f0bf778c6cb272c251ffe5bed23994d9e1813131ebbcd9d69ea2c90fa5f7134bc7f8a4844fd29d27da2f89cfe45f3fca9fb926c314e7403a259f6973023c01e13cb7c1054287f6192bd087327740d2da719b260e1d01c87dd0b08f2268775d3cb2dfc601d39335a44078c3ddc7d4c06fa77a64c68ec926cebcbca3f53bb3d6a02a166770d9a4898302c13791acede57581dc0',
);

final Uint8List _au20 = _hex(
  '419bd54fe10ffc852c1f004060820a80a20014645c7ffa5800000300000300001eae31106a7e7879'
  '483091f65aef9381cf14a166afa459ebe79084562706599d077d7f7acaf7d9b430b1ff1b27ce8f6a'
  'e742772a295e54324b73c95d891fcca3316d079dd3be7fe1165c48e2ee5c316ddf29dfd8ac3001c8'
  'e803a7d4e354b74e86cb26f29f1c622d5ad3695a663611a2c1fe26ea79435744a6549e7b5592a21a'
  'be281eaf6cba04182440f789e26604e77d6f0e3374c701c317d61693eab344a1272b121a7adb3eb5'
  'dd1d70d3b991b8c26a60f5f18eb08bf336400f9b2ef19f3cbebc102745c6913245aa6405e4e50546'
  '90556c73cb3c1ebd0a153cdf91f64deb1b43a378de8ebb8b250b97015744396ff6b70ae5d83f7880'
  'e744b9e360790d8befe27c4690bd0e6556bd4ce1e766d27660cc39ebefda47d41df3e1bfd058e19b'
  '32abf1907a70a5b7343cd272208395956bfb42407d7c1358445a822655d01bbee06fe2325ed089e4'
  'eb1188c64e35d37b6227913f6a68d5db439c09ffc000a09feec5db5c21784b2e236cf23fca587a75'
  'd18405600eb81894bc165ae620e48fcf49439f92f7901e78b7360e882fe4481297461ff94e40cdff'
  'cb0ea68944c7900a318e39960c2f91e756945603976e564d4bbe6a12953afa1a889d92008e3ef1c4'
  '7e97492d4855945ba761eb66efa482a1146a8d9fa463c4e536f35b10b0b866a9815726d27397aad2'
  'a4c0dfb4c5ac06657cdc4b231b8de5cf1675278b2fdb5d653c7e441b9d341ead727cbf801ad50df5'
  '2cc31181ce9ebc2c841d4901420c8e73ea11144e8f586e5402672251e5e9fda52ed755d55b2e1e1a'
  '86317f647de58d4846e6e32d3e64d7a4b10bab9218705b2e7e970a47ce8d90645b0a8faa39d55bb6'
  '9de08d019dda0ef430019a5ea255216572383adb82ca40ee52644ce942001459bdc6d73a880e67f4'
  'f90c96431b1a7d0038e6225aeba93f75b0a87165f54d381c770effc96750d09069a09269fa3bde20'
  '6156b9ac23b561383e25cef683d9c68ad7ed8b7838aab44cf8a0b13f29f87b2ca33bb47b8025aa2b'
  '0f874e2c2cd22ead902ad6580f541386e777ade0c5b7790f454aa2d223784833e5512c26daedb44b'
  'a01dc07df381fc85c939a0ac4f557cef47e2a18e6c1bcf259ae2ac42042ddc7f5d1b397c3a69e18a'
  'b58f20dc4dd5d77a431fd0884e5db38aadd724345f6dd4af83ce830f23522322dc9d46dc59261db1'
  'c9b7a52d00fa32dd2673ac079cf33ea2c3a82d5fab359eeba0270f3cda004d6b04121dc0552668ae'
  'e74561082cfac26adca88ce0c731310c72d292188acae373c82bed26fce968d802ab22ae81b2378e'
  '66c1eaf55a8e1bec03a55f01e277271149d8dae23496dc559d784855f3bc0822fc40882af7350902'
  '4973399a60c054e2cfb13763cecad1ff5c92839d01b752cf6f840037dc75f402e93c0fed23fd36a0'
  '586bc07f3ca04f306a435bc30adb20f01f2ad9653fcd030587c5a556a49d4c1e13201be5e9a9c6b6'
  '81f97517628afdfeccd8e7bfbd199e5fb0223df78aea658fbb408981066674b9fd7a08b27c54416f'
  '25a242a02379109aa9684118de2ec6da7f426b468554dd896572d2ee340df4d7e5709f0fabeef0f8'
  'd2863ee457ed069ba270b6cf76893a4988000003000008b8',
);

final Uint8List _au21 = _hex(
  '019ff46491ff000003000003000006ae57fbea4863f1e36bff00ec665744b0ba7121374c86882bbed7'
  '789412aa9b159f48bfffa83fdaec98c1719ea045a7ca547c66a25da6420ded86f0cb13645b9c723e3'
  'd20c0248e3bbe3f8445fcfa00000300000300007541',
);

final Uint8List _au22 = _hex(
  '419bf64fe10843fc86340ac06581020460cc0ac0670008fffa5800000300000300001eadff608a3b'
  'fcceb92b7e1690b34e3e52df0e6cf694f27c87ba920575ef7c3cdb40e528b6da983e3add5fe22eb8'
  'c9c51d8e9a339d6268a7d15e13ee74793dd5711221aa51eb9722dbec1ec78ee948a96ba05c409891'
  '8482cefe93f288263cc853b382a6df7e22cf9f0232d1f458038539da05fb09ad493680f155ad1188'
  '9b0911d80d86968e28eede05d50a5c5f6d70fa246d2e6dcc75c168d06dcd32b61beae7266ce87fd9'
  '199bbf91400ea2d49602c48ab1fc6de64a4ed4de021f8919638a799f7b6212a405f34627373898e3'
  '932ee344a83e3859f010ceb04d2f5b62799b38dc8273f64dd0e04bdcb07006c3c1545c8f60fc6904'
  'ca5cfba97e2ca4fa1ff3ce49bc74f73b816362717cd44d1793f919d3fc5cdda2a7cd5a279bdc5291'
  'dc62a19cbfbf26dd46a46a4cd66785a25e6bdcf3a7d189db6ddf13da72939ad68a119e699300d33b'
  '0af6ce7fb0559d981cc56e2d4720935198cd45cee8c482d29725e7fe84c3ed3245308dc8bb7b28d3'
  '5f5971a1bf275f5626ecf617c5e86d2e57f7ec925c7e86d275b71390f7f0238aafe73faf1094dfb3'
  '69d6e489cff1708bb804b0953beafc3c85d804f23e7d888a54c96710064a397c57d1d61cabb7421f'
  'f63b89faca125caefbc73cad40c1a36c9f641680ebe17049d7e66c069a0e9231a03fd347376f0457'
  '812ba43c4eaa0fd38abc5174eb96fca4a444a53848a01d6c78298ec41f6d29ebdf530e90ba707551'
  'cfe787d9e9a278a35332177f042734f53ace885b55a51fb8fba011766c02ca12a3a98b7e7d0129c6'
  '7a6544cc23aa92c7d143d3ff40f8fa39ef576655a568a2b2dac3a6275c873e3f5bfcc78e520e9b84'
  '42a70217cc9865e82f8427fb2cc786cd5917fd2b75281575cbab3d6c5c913c95e90df1413c5c7440'
  '2187b8d78b91a29eede4d954de3d5dd290a6a0cd07c478abdf0b927074b00730dcba1701dd64756a'
  '7c03014d38a21311fb831c89b56750f5acbe8ab5902a570b3951d260ecb501b40f9931d33e615778'
  'f3d62a6edadecb60a1279f41d6f9650495b6e3c01cd21fed13204b45a7950d9ef43dbe5a6e90f753'
  'cf671117050db4d8e907a1ab0c407e0c81c9da761c686dcfe63b97c9a7fc13c76047183f8d3097ae'
  '81cc130fb0ec1fe2622ce99ccdac920278cfcb65def173e8376b6b130d00691529c35fe727e243df'
  '4aaa1a57332d03344d25ab9776575eb8fa379eddaf05c5c07244567e683d5ccbeeb11ec579d9374c'
  '430ad217bc6f68ec676c2f5e82642126e542a5571f2d81290d3982ece4de2815dc89d2690dc7c933'
  '2d73e9268f1a558fd0015bd48b9a0df437886374a1157e9511675d17a5a7c7a55c059c67b448a1c7'
  '83c0cdd3badc3aa0a8e180ee1a35a10a0c6c96ba2bb69d072468874d0003f25407d9a2037fceb401'
  '632309ad39504cdd587b93f31f911ca335426ef756848f47f7fd47c8411f9d56deb346ed8b24f91f'
  '8d1c78c2c537b6002f17af3ace79eb7b24a4a7529f4aa6b491253c9d280d454abb4c39a000000300'
  '003020',
);

final Uint8List _au23 = _hex(
  '419a1744784210ffc862409c043842120430270114000857fffde100000300000300001c6dff6d97'
  'a43058fff7842877ed8ba3bc3a6a2a573a31124ba524c41fe716d62095d33f7cc0367673cea45fe1'
  'a8c3c335998860fe3a1b33305532c6cdbf25f9a0932a09347f9df6f280cce2178860d947f481f577'
  '4b8b5d98de6d15cc93228d98a828bddf46fa6e372f02b1784cbc5ec9ecbc4c51a371bdaa140f136c'
  'da930e96fcea04eefa478ed6f8b4b826cecb0dd02d8cb03fe9ebe8a4952a7f848b455196f5358bff'
  'af7242b7df2453807823f0d1ef3e0b49ab8b3aecbabc2ce3548bb78dd9f1d45eb974f7a0935579e9'
  '240700aac9d5ada184128db7725b5b7025bf8366c18dfa8ef880bcd74c25fc4383c53dc1c488bb03'
  '866aa5e4044111cc8df3c6161fa9ee90fdee24a0e48aa58d21b18f60317abc394052553855cd6de7'
  '1d27788d07ded4e91e21e76d71bcdf4f7043715fce49c361c07f89359023d975b8241ba640aa4048'
  '449b97f3fdf8d6c7e3a751c5c22788a8a356bdb6b75a3a85e0e3cf2ab209874b86deb9d8d03644a3'
  '031e8b8739be1e8b82f37460ad11fbfa7f6f41ca8b069c539d93ac0a232ff74e5f92719be2598e81'
  '35bd930ab3e7c21647d572819df1c20552f0fc8a99f651fb995c950cd85cbb66b976a8c76041698a'
  'd73a427493fa46550c79b2ddda2e0e40d4d597b790d486c456746358d3ee1425cd86cb9cac7d0f17'
  '57720ebc5a97500043300f4aabf237f324c8e38f66ee029d5ffc57d0282293c3e77645cd403258d6'
  '5562f367d1b461868ab0e6ddd4aebc8ed73f8b9c1750fe019fee621c5e675c8ede82d1a3187b4b96'
  '03ed36c621e639a2220dddd1f0b98aa2c00723ee5e09d601baa4aab7c8a6249cd5fbf8c6c06a18f6'
  '7b762f237e0c9adc3aaf1bd9088d2fde61e182cfd9eb1fc91a5d37cf13f8c81918ea759bca04b970'
  '8c96c18d6ee7811b8caf104887cee739aa342b6deb1749869ee3a0ea76860e28e0dfaa988c57d409'
  'f216c8f4a035c5caa98794ad72dea3b9e26f3a94e8a5af24b66fac8cc0122b70257ab5b6f5e40332'
  '9554d657d8886b61563ea747c2dfdba8b1895c926bd455cd97773dbaba0b7fb2cdc82aeb0a74df58'
  'f6c9699ae479b9c9f7858c863f99a088d35cb33641228a8f0db71634a497181794f8583d8ddfe352'
  'a7dbe9b07542e4aa61c8079801df17509ff12fb7f88154e66d59d327925c9d3049b8ae48e056c9b4'
  '58f6e61cbe05946d42b13cdffdad5c2aec292e84f9718adab9b191bbc1dd6437d32d257a18c8504c'
  '21556c839b6a518d3d8b2c24b6ace155824cfd9ed92a936ad3ddd9e4e25874cd305e08fbf805c64b'
  'cb9dde6dd9ff4f07db34f5c76f25584f04d5f602e60ef4444ca6d13f692815ab7f3ae413c61177aa'
  '81051b86d641c47be1cc83c7973ec3c03db19d83ad4df5dfb6ee4f9f80fde36459f8ac3cba6229e8'
  '2c225bdf9ee5c457b4f8f396bbbc11711b2141249540eb59cef09bd17c12f377361219a3cadad50d'
  '817d20b08dcc492d9edb2433b4c150b1f3b2b4621174012b4d53cdd12a20532f8eb662ec28019929'
  'cc08dd8ebebf0ebf2f9cc7d098b697b0ae280caac6634000d8d061cab2926dfe41',
);

final Uint8List _au24 = _hex(
  '419a3a4fe10ffc873c07500406020202d80da000847ffa5800000300000300001f5df23d307cffbf'
  'ac2ec845e00360688be8a863b823e28326f5ea7d5a30782c66555cdbbd13ca08b01ab0b1c822d96e'
  'cdb743fbcbbec5288754c095ec8c073b012c6f0bef725a60a4c6e94c27a05b011ac13758f66b600e'
  'c93e486d73d89af5cac8206581a7c8ca95eb628a9c879bc0082bd06e7fb94049611d3330f7535bff'
  '2ece672ad420287e6305afa73ed8008070cfa96b78cdc29eebed2193896df7d4444e3e02888d99e4'
  '8ad6b49f9886a2b7edc21e31af8ec243916e3e43588ed6b1962b31be77330428bc80992bd8725fd7'
  '43d17b08422d3917fcbb9fee99938d610ba5ec11c20041d3c176ca7d7f1c57cdb4355c1b5521a67b'
  '970fb9748417894abfc37b338cd089c780fda48f176c7728230f6cf271660df5872cc3c696de22e7'
  'f89c8fc32455c18fc148f2b6c17570c7958686a4bd85758bace9b60cd259ef40e2991bdb12851476'
  '42fc6aff04a87f527d41fedf71826c3f2615fbe1b97b640bf8c035732381745c4bd7a80e22c8316d'
  '5e9d5a14d0a88604557db2c021195a82099a9dd2df3bf509885e4af912d5e9ffa3dd54fa174087fc'
  'c87d7f3d14878331969651961edecca43b1cbf99c18a718f244791e06cec2ab6b899b9e852541e82'
  'ae08a4f3889897bbdf9642a562a331e372f4fd12d75a9961b95f84906d6bdf784d8a9655c2812a86'
  '155e2f6234bc47eabfd84acda70cf181e7248a3da57d1ab9b90df5199fa1cf3970754a9c0d7de530'
  'f5512a417631e5194d155a013fb9d50788abc9f548c8499712e3b1a5ac303bc171c19ffd4d55128b'
  '8292e761a92c6eec5eb03073aab2d5a89caf3948568b9a4defc2e9ee145fc61b478f9202d907dfd5'
  '0e4c481cc5229c1140a254c8f7ce5d364bed1d1792d221ed0fc4e508fb367f8bde28e93465bfe2d5'
  'b70c219c873e96c0a6baf517c99fcd3f245321becacfdc5b905627e94b80984da17101dd7f348c4a'
  'b411fd7a6552eb1dffdc21daf5d402152a1316890ac77d69354dc41163ac9817e619b3757da42104'
  '8420a18bba676ad95f57e9b1401713c97da721227562c18f77c4dd51cbc245f4d3d5f1a0646f968b'
  '470c0818c7879a6508846f04166c41b7f646aa0c8306375cdffaa07bdacea419e37eb279f39c79d2'
  'c61de561a6aeeddc58fd76986f3203c7de7801f3dceaeb001c5b1852aa82b8fc970622b6e5f5d4c2'
  '2c8fd5d7e6eea6472cc08e1c8d8c61d0fa2ed8407d0d4d605bb18cd236e8e92a525217baebe775bd'
  '5972707ed899bab18b507e65e58544e90ff77a13020b2189f08d8ad4b2abba101a06bfc125f55198'
  '7e5638d7d2eff69aa8fe1ac6b7fced575267e95b80d67ce182becf177a081d47978da36fe03dcc0a'
  '62560a686c160385f049eb082cfb5d0d16855eedbe7ae2a940c6718dd242b46e89b32b6d48762bfc'
  '53f6abadb9df7ed66a6d50d2d670e1166b8f7f0b1e223ad291e3212e57ee417fcdfce2451e99704e'
  '7914ca854cdb7a8d5e8ca6008ed6bc29d61d7d664389a6a43c67897604db88508d64321d7a77c745'
  '58c6a70d522b2dd1abbb9fd8949d778621b0140ce4c955a685923c715683ad976b548d38459b46da'
  '16f53d9c09d5090b71da4345e92a2d6a090cc02af04adff4d60572033f44713fc6bdcee55766a282'
  '16b83b18a93918844da58485345259814560c85fbd52acd3c834ff349a0783c5e36482ff552eccda'
  '704df64782dac45a4557d6c598292c3b7a139d001620c52ce355491964a134ccbacb735f54a1a33c'
  '462292a23808c88e9bd11026389c05b755a6e7cb681bf9793b961aedcb5746253d2d434893362ec2'
  'd72f3267e794bfc1880db66b9aef03d771296384e7ed763deb98f4156b55f4e7f022591735469408'
  'be233fba5a287442335fd7f2ab5cfd232798ced36a747c1eeb727f4872a0e46fcec11ba66a88c1a9'
  '3d15ff53f1a3b229e5e501974546f4ad3440244103b3c1e4b992a80f225024be38797bce5074c214'
  '2034e35b94e36fa1a2e718bde68ab0da21b4d1725b2dd9200e52b308bfd1acaf026670d6244a1514'
  'ead70c962577f6b244c27bad56d9ca549c72dbefa8421422e9d7c0e264ad3a544f6a887106fede1b'
  'bc2cca41e8092c01a172245a275942eda6c8812404d061de245e58fdc0989bcc4302f9ee2958ec66'
  'd42a4dee9f2af07479143a163ade245d3cfcd0f0e091574bf2a112d4df03747528c27fe65aa6eaa7'
  'a25e5cc84104990199db9405480fea9bbec5b188eec39390515f9dbbb62ea5f4276e1b3a62b83d9c'
  '464a3667ecaf4195ef7079ffb38f30493b08117d46e225458325b1fae823c7bb7b03bd71fda86a78'
  '847e0aa11ca976c790a5c6ec71a0702333750686b84b2e23b42c6c28d79eb12237b93f310a50f8df'
  'bd84671432c41ca604b4d72d61a084f06cb461e75d7be535933a3cc8eac405fd402982b1c5ac089f'
  '83f9db50d2c42a175dbd2fb3f9ce9e90c3dcdc1fafef466a15dec5f8346331fe58555866fbe21f1d'
  'da55fba18724f20e488181d667fdbc14b3b6bb0fdec971765ea598671cb1bc4975285d8af25ae67b'
  '1ed57e8e9fd97dead55b2cd6edfb0cc9bba4c80d5d0e4cf5812110ecd0c9f7b34086e20f11b9b55f'
  'b6e0c32c19a43914761a009c790cc695302d5fa662d6d3d3c013ef5c8624964b2a62ebc313d5e18e'
  '98811c8d2c5960c2611ab590cd18a3908605ed3cf06a0258daac91fa4149358f8a49fffbd1b05320'
  '1537c58afc7e02f42d89b54d706911d3b0d4b0d6d12170cfb22e96b8217ace444c1426e52710079d'
  '76c5bd65cebcb792c1d692c0ef239582421bdadd301f3b193daa6fba88fec58b6e652a0337a814fa'
  '29704284239f0907c5f9e7e8675ed99f21efe5abe0a9153517b2b5bbf4d1c13e665338c2d4f52da9'
  'd5a74a6dc40e66b778bb86d5495bb90f08d0aa6a53af7340e2bb3376058e75e4c59ec64f3a842f7c'
  'af954486f5ed6fb44530fbe71efb635fc5b05e310397be0e6280ee26dbd6000f1e36905829fc2f27'
  '390c600af12f1ca0fbab86a46d2ced1833dffabdafeaec5dc892d1a4135ce41f28b96f1da044dfe1'
  'dd9a95838aa274affd08c279a2dd801120508cd652bd23d537d012c228c81f3b2123d8b2131e0d8c'
  'e0ab1fb05fdb5a82379a1e7a8744566a6a0a6e4197cb2f71ff8efe348b1bf2e082d74e193c22102b'
  '2a68124ef560ae6871d3880c97ff38733fbafba8694c24e14971edfd2409847cf34c584e049297e1'
  'c8776a545a6cc72ff39627faf0b731de3539b1b9e71268f1944812c99a8b7f016b378294c73baca0'
  '2dc4526897733a5ce1aa6af9a3d5e1d40087e94ed32c9d9ec237794e0478d7044d59ee4d9bdda1c8'
  'ea002849f26261',
);

final Uint8List _au25 = _hex(
  '419e586594645c23ff0000030000030000f083c5f1a2af2e5896ff533cc920a8baa1459db27de1de'
  '04eae5e20836123148fc00db523ad58c089ec2ee82cd0d8a80f608d21591a0b7ff221e71143b8360'
  '00000300001dd0',
);

final Uint8List _au26 = _hex(
  '019e796491ff00000300000300015e2e961ea6443d8f2202c1b3340bbd59609fbb4847a1e0000003'
  '0000030000030032a1',
);

final Uint8List _au27 = _hex(
  '419a7c4fa842105af21cf0164022e020202781ec059008d00145c23ffa580000030000030000c679'
  '8a94c5fcac1b6fdae037a0afd638615718b56c12dd6b42990d58cbabc797919903b858bb56da366b'
  '6b6adfe3d25140d19e523413e1dd58ce354515eaad85f7e72405defcf3b6b08deaaee1048c4486f6'
  '5a3d47be5de4a9acf6baff7c31efaa83c83726783569bbd0d1082ef7c810edde19cbdb69dc68be04'
  '729481e206bdf661400d3055958311f7e9db3fc8eae4336a5bb67aec0458c0ac178da7325857d7d7'
  'f1a6e1d3d4af0718f67ac3fff8b818c570fe9c922954bfffda127aff4448ad8555179763d788db68'
  'e3cd001031a3dbd81c9b7cf769616a9ef2fff1fab593b4c08a9471dc8874374f2d44b51014b0c76e'
  '58e5aeb09abc85c2f8e621365c6abbe414fcfc3e6ee795a3f93447d0dc7f645161c5c23c0eeccab1'
  'e3e8fc3f2fbc614c7adde1b84ab9bfe1505702cecbc6b0dd212b2c09a450e05d599a44a675960c8e'
  'ed49e35c69eb96f377a68788eabef7444ec9f461cf1549d8ff0c456ba2c607ce3eaaca4c09e85e5d'
  'db1e27466eaa732fbc602817c80d3164adc535413acfbc12b2df84b5eeb0e6455d915cf7e8e9b7aa'
  '5bbea7d85885e6e00096443be76b74f4d2c60867e62c9af351c74b971f536da5a05fdcb6024be891'
  '970ee57691fd20b31012e693a3b38a037939b0af70cfdbc5d29b03d34ee9a8fcf6a9f8e69567b2fc'
  'e77056a1700a0a08d4447cd369975be6aa41c1705ac2e5ff2a196d520e786db4e58f745e9178cc12'
  '3c34f5f5e2b952aab51e39a59149276516fed563674900203374a17e1852dac9e3dc2ee7299613bf'
  '9b3754371d6c32770b463ccb304f7b6c83e928292e0b04d46582e0c22899ea4463c0c4ffed1e8c08'
  'f8dc45c3cec54ab454c86e9adea699efa7cad4e6ef8c6d264fd0253b01a0545b037617d6db2ec07b'
  '7f8868ee5f946f9d38c0d048d9fb9c10bc986999256fd3dcc4cb4907b6613e06680f5fd9907ba6f4'
  '6f3e4beb2842dc0beba8125b5f93cac5c1edc82ddccfbe5ec296395378634c8c469fb10c62050e0d'
  '2feeef3eb2d542e1a0a1719124362fe03a7c2ab2b29beb00522fb93ba3bad22f82fff15dd38b94d5'
  '1df8014aee1264550b34945d440f81618c6e64f5184216dde0280cae9d52c05826a1f45a84683bea'
  '7478828e748ca6a5bc32fdc4a7c557390a14222875fcdd940e6ccd41ef29cbe06ed4f4a5e3582e0a'
  '0cc58f6dc3965cd47ac7737d08de2cf3672cd7336de7b79f8302b3678b7a3b0efea9af675df304ae'
  'e47862d512556370385acf877d4de47233570037c616cf047f30cc5e6f6346723d8bdb621e00eb3a'
  'ae8e6553e186fdcbb7f1d8fc05d09d74ade4e64ce8a5c26bb1231ba1d13ea15fec911ce31f047da7'
  '60098122f9b0f7774c477ce3ad9f60062cb5b503b43c63597ffbbb2dab56ea5b421abf4c23d69c83'
  'f2194055b7c128ea241cef06864489dd6a7d7dd11b133bdf24c0f4ec4566c67e0098ff4172636107'
  '8aa1a4b050e74ce56e8a249e0f457c33cecbe24603f74b17d1cb8face5b9fea9ba0d0ab1c20281f6'
  'd117241fc04c5c6dcd3f0ff3360905ee5ef026f04a018c9f9a45709ac7d95dbe97c68ce3ff9c18b6'
  'e8f69eceefe70de767d110fe3fabba1947c1b7668dfd56552374029123632daa8aac08284d9ac024'
  '7e062725a44cbe6f6022523031319932f141f476b294b32728f355fd3d83088d655ee626c8baaaf5'
  '33691a18c1aa9fcf80b4cc7f2af0f29e349eb71624554cb51f17a306f45dd676f98e86bc20385b44'
  '6cc176be66b1d1adaabc77b86ade1a926f07057f633777857cb10dcf989a913721efe6a28910f0ce'
  '5792f9c34fbb09aca37cd871a08e0b2e496b90c8bb33ef887b140db64b50335642df6056ec1e20ec'
  'af2c9e09c315e50ec738c0eb4bf83da44ce1900f1aeb2e606e81fa0baca2132e67e22ea4a9c8ece3'
  '1cc52314a55af8851b0a5e91d1fc2d0ab6bee3de0980907cc2863b75e3f9a2f5866a46230ef4f572'
  '4fec80c5940f9129f587655c5d33bd1af6269914149cd28449734b7f99bb2ec237428c887f8d554f'
  '9b84182ffc4a52b33a01a42e9363bfb90fecdaa34a31d081f8827fa7ca740020d96e3d82aa064b00'
  '938fd3a806fb7982c033c29569b33d0e2d1ddfe19601f66911a35b933d3268765d4968dec7865ff8'
  'ad03bfb02f37025d01f44b36a0aab9e62a442553e50671b33d73256c6e6f29a1b6a2aac683c9150f'
  '9c8f2d38693d108374dcaa767400848cf04e505c59a7e78e103accd94353b1dd43563392b8ef642a'
  '02b58ba234b961dc8a27bd6392ba560d0ca239b69e0873b1a968370206a66f36b3e5da126fec934b'
  '7ad2b41dcddb84dbeddd38a2d45bfaeef5c5b62818417160a9fdd5347b47093ff90e515ee0c63bf9'
  '39d0bd29fc43f3e7152901c23135c85c1f93758e18939847de9035ffc75eaecfbb07bc8886e3ed3d'
  '9a02ef306ca660f98c2e31dead3772485bc22cec1811bf2adc29c24cef616bb6ba6bba63c6c27ace'
  '8ccba660d9c11253eae06f54cb688e669d9cd7a1390eb4fd6801e8ac5b80c86e3717a8f3b2d58bd6'
  '414cd5566a3c7c5f90ad3a1b5efe4cbd110ef3b405f600595c798121fe23a8e57009f947a91f68a8'
  '3c3dcae600c10dfd91c4bc573bf70285a80b550b42573c445bd5cffee36a9a1e03c90ce8cbf9ee66'
  '701566b1dcc44721c282c649ce86aed578b6776ef45c59e185ef61b190e595778c0511ec458afd47'
  '143c8937c2ab7dc42d50412af2b32fe9e00e889ff8c0e3a7827f669ecb452f568a1f2077555cf824'
  '78ed4972cbb0d60ac33fd79dec0155f69399014955fa7c521e113eca7a5c363bc01a930c31da1356'
  'b6b975f57fdc619da1af326b5c0b44d8e5cb29fe95dbc6069c8a11a52c45563fcdba7e4243dc9ec1'
  '99f2e869134a48c12063bf093e9294d4447d6e3b3975792f630fa978fc733ad4b8d71d5b04837775'
  '063a89a9936994b195b50e149e1f2e65eef87aff5c4c1f8cdd55eed2c7af39c99ba15a47f3c7ed45'
  '70da2a57402dc3a7f00b8573be303c3b5892f5a9d6bfc6782c9898f6cd5464cf3eecd3d1be5230a8'
  '52d303a516ef2766d7da863db40fbca4f3c1d39fe74763e879730803f493ce6a285a36f170d8a630'
  '659d8e21893cfb6f0a444798833c07edc494f6bd457286a68fcfff52f657da73185a836ef633ca53'
  'd19b96f7c70e959918ab087689f7d96940dd2aa73a6bbc5541ea15d281882efaf004f0b3b928fcb3'
  '164230de3fc28600b7a4608fee18f542bdaf250954f5966426528a7dfa3a1c7a1cd3f6e125b502c7'
  '8c1836443ccef5296cc402cfb467be3a8339a1ee8d6cfd60',
);

final Uint8List _au28 = _hex(
  '019e9b6491ff000003000003000037f565113f3002cc098b0dab778dcf7c77044c43da46327b5701'
  'ed1e43571574c90be08527feb19c442c0000030000030000f481',
);

final Uint8List _au29 = _hex(
  '419a9e4fe1084296b218d02f00af818804381580b302f00b100145c2fffdf1000003000003000012'
  '6f80637a5c9fcbcc9c193829c786d4997e2fab9944c1e4ff5ef64b7e6ea81269cbf0f848fcf9d5e4'
  '423929f34bd23cafe857a92b42291f8468dc7b128d9529ac29ef21b517bdbfc96c8375b7cd0e0bde'
  '2813c5409f74df26724f87a23f27c8e1c0d06582d902a07efdf33393cb3feec78bc6b045cd0d69d2'
  '2c81a851b0c38511c93a700cba304b60d93c5ea6fb648711bbf082e98e0af6f4ffbbfb59f55b3ea8'
  'c056e110f9dcc8422ab5527c104da7bd476b832fdddec1895f3e21300c5442b321f799c485b60aff'
  '21fe95e2de1d9dba32b4ef8b3f12d5ff55e4074f8778ff3a11adcc5c7e2079afa48ddfbb7f54df71'
  '4b34d2d84c7726c0bdfc25aacba51386302a491bb612c4de5fe926ea3300b031aba9b6bf56183b69'
  '3566c3cfc3cb7490211833020b14b6ecfbaf157a6a95a4f481d372b9719c7de827fa531c0d0bbf28'
  '1a52e5e91aa99c4490de56ad82cd258d4c9e5b8df8d61638bf47c9ea03aeb61219e9ebadf954d8d3'
  '791e02d58c8ecd504270b487ad4d9796011fb6c30b6023ba728839bcb4058ae838d15dbb8503f605'
  '41a7bc911a9c9418c93c063fdb720fc02a9b9cfc274356bb4593dcf246b76085bc0bd84871706170'
  '494bcef4d74d0ad058911432ab8c4aeab68628b10ac552415bed193381e9d3f5d42a73651c824b88'
  '20f06d5f8e2e75f3c3eeaf9d085becdfbd2910e3ccdc8de62a6630b57942daebf1eacea1a3799a73'
  '6843d57014e486aadeb6c7511f9b1210f471a43a324553c37507d62cde8aa6a5efdb1a8a88e2742f'
  '06f5be27fbaf4a889b460a612abae02213beb40c04c8cedbaef890f3f279499f9762381cffddc386'
  'b5116d915b74f531279af1a17705202e5e3318fffb630e45bb55c24a66bcc21aef6b77b4feb68e4b'
  '43a5fb682fff42976c3926e63fb4313eddb1a275ad6f7522de5bf38981cd94c935dc5b42fd6dab5a'
  '1372e8b2d8bffd90c705b30055c40e984799b1db8a9cba13cc8bff26480b9dcad23421d13a010cd9'
  '187ecd823a57c08e413c23aed96dad91e0138b55a9da6a6dba0794a05759943018fbb5e302638343'
  '7ad492f5fb1c0dab733ec41791eb452a4c1c9114a98c9a1824101a5d5e3c7f7be5625710fb20febd'
  '935c341258ac6c3997093b0fbd96f09618cc7aa1cd5fe79de19747e16be8a3e731834c77b4ba2d63'
  '0e590e6ada8bace0fa2ac053cd0c74b3f597fd19476628385c91b619f60fe93ac6bf629be2d05379'
  '20a1ea361d4f0b0d181361f98b597e2c3a33fb6a7188628da0efc728029b4892099ad91032a5a265'
  '955445392054ff584bfa70a8c6720cd2cdf43f2adbbb9614bed96584fcdecdc610f097b424295b58'
  'e0724b4392b9cda508f2c91ab6085bef1cccf1c7614180cbe017ce049fb09dd6a3da20147aa66881'
  '3e44ca72000b88c823c68ffffce7263678cbe7c3c1f3c0e15e0f828ef2f718d518b40d728638eb18'
  '716ce5430f42b3bc80d143b8f4177517d363f56993699fc5812406fc1570adf169b052a6478b69bd'
  '479069c524f81a9fe709626c7b589088df8f0ba8c001b9f9ee92b9c5865ce8140361867210dad3f1'
  '260f86a437f85e23bd8061bcd83655969f06dc22ce0bd56f1516f8fd9a076086032fafb6cb29e53f'
  'd79c4bca413d11fb56a3798f5f32fcc331214088f5b354dc7d5697cfd4976240bc8f23c202d6f4f5'
  'c18c5920bc22f85cd36f9f8762ac423cfa213ad438ea0517d6544e248d71185cd5c8b8e78bb4e9a5'
  '3b789fd47a5d948cb61a21f30217aca72499e8d71d42c799620a0f945a0aaec6b4353fbbeb903e31'
  '5a7c1d16ec86b3848516a66d185dbd34f39065f97e4835fc318768b318ffae9db1c77e1847f921a9'
  '1ac002790070f0781753e21f5cbc6927ecefcc0194a8407a8a38e74866d9fa85f3de897dd04389a4'
  'd9c8b8bc5f580e4c0023125b10d7d55295d23a83a683a40699c0006db66b70993bc7b4b72ce2d412'
  'e71979a122a1a71be5a0a2661669f514ae8a818c0cded5578134cfca1b50a3c6621c96da7b14a5e0'
  '7b6952cd68d302dcfc73c8a26c3a43a339e4495e9ad5af7b108b1ba8f4c16729f285de64a62c83d7'
  '9466bed4f891059e8607f75f218d996050735c30e173cc63a5d1714d847214e989158c564fc69de2'
  '763caae5621351f071e20237c4a5fe71278d27a8628bafa9ad347e1ee6ab1b97abc16a020ca1c3d7'
  '85390e95442fa228b081e9b9ed5616e48386d774d9d05a126ede9d1a372763f64762e225126a7199'
  '0177711789b8460bc8d1490ccd6d682c88c0990550b9b0022f1808338cf59a9f0d98d1ff29cd07bb'
  '0d1729090a54fa1446ee03ed9bbd1bff19f5dd8c9ae40f0fc6246ca26c93a9ece62bebaca9856103'
  '8634c5bacf44a35851bc2d5ba12a173cff47558bfd922f98184b4d48ee3234feb9a4d162ad61e6bc'
  '79620f86f20cd67c632a14dc47a86ea19a47709230eabcdaf5bf141aa90fed3bf6ac7a9b581b24fc'
  '2de18a7e3a4893e6766773a1e5521dd90a1dc8feba83b34943aaf65c1c64baa67eccba885778be64'
  '2ccebb22d3ebf260a9260bf0c33d02a8485449ec17231c2c7a7ebe56bba9d6c384292d79eacfde27'
  'b67741c86a3c4f076197f0df3d30d0fc810c67c85cc7592d8a4e617aa3574b4b989743c61cff6086'
  'fe52017ba7230444b82efeff1567977599f29791d5e8386a0af9c4a3c5410e88d893a2daaafa4a23'
  '903ee08381e50b8640f2fc8f32170129d3c7a1180cb6286f56e2fb91a52834c37f2ebd4fbd2f9019'
  '5905832743806843e43cef0b439a9031e1ab6b40e219de8686a81cb62c9b5233fcb04b2e56d0a0ae'
  '76d6f9abf6a26357bb0a9741c15da6064df265a5bcd4b7839922d74111bf25b312b4b9fbfad5ad16'
  '5ea406572a0fcaaa1dbb3dbd1042dbe76f7187ce3ac756732e21593fd03490179328ff5d55d04a4e'
  '8a87b2d28aa65ddecbfb151033126e4a47df09d6f98630a3614e61fa0d26efbbfeaceadcd554a827'
  '4371f0d93933730c6c1ed82892947c9192ac6a081ff0aecd247513570c0ddcccb97f9fe38a61a85d'
  '3f44e447eca1fc6451885051638b73f76ed09855e2d1721f91ca2fb7bd035dce08f27f367fba2c24'
  'b9ab8d2b8fe41fbc5ec0db0c6f9fa21e3159a9b509c7c56ba72529644e314d5008bb7bd1363dcc15'
  'f04563e7e970af4ba9f6a1b6819a4a00d3d8c54d9e2c935694ac9860f22f8cf5db44ee62d71c85e1'
  '8610281996a90d70a537dceb0c4054e1f2f8e62aac54d1b19ceda0050b683d64eb8ccfcbc9cec291'
  'aad2d1186c5dc9f6c50eca233a0924b5b5da56e927de1cf6767701b09d3f300b08216b07001e8a2d'
  '9876b0b0f7566fc3a74f50084fc74978282c87ecb85b2054716c51def1c916efa8e3361e94908966'
  'ce90c466843005d6b029d32388205e67d0c4a9928ad222d79be8f3ea5b493818f0a97c24f126b956'
  '5aa7b28209435efd5f3c718cf3bac67d3c0e805b901c6e0d28c9f5d1acb2ba3fb31cff308670ebb6'
  'c3fd674923c8dae2a141506d169f0a4f2058ae127eeb1927e4d7ef3edc5cd90c8bc2f1e02845dd90'
  '63fb5a4cb382fd88b2e0f5e4259f1d157458c5833451c08de70c597628bde640cb1ac8981e334cb5'
  'ba19ae4e089acee18f63bf0b24388c0b2be03bcfe0e8ca7cb9031a43ad76a47046892efbea7b33b0'
  '33c58a17d74c77993f025fe96d0e2ed684dbdf91a68a559552a22daadbf803b51eae19874d2b387f'
  'd05d930269cbf75dfad3ba9a3f3d2abb9e17bf1fcb60c09bd7e594c77b8855a9485ece23643fc038'
  'e8e315da950e8229c042c29260761b43d74b25669c2841bd3acda26578235344ff0e6dc3f7c8ad5a'
  '5b3f2efef12128aab6be30980e80dadd3030e2f337792c13e13e451b9d6152848b0b40d2ba80c7e3'
  '380cba8d6eef13e7999b770e6388775a4db0911215de0d087d2c6f4b623d82fc173ff4d9abc58b13'
  '23c8da5a74ae73721ad79b8dad87c41103732194479995343fefd7b5b4b41d591d28dbdbd1048f27'
  '829931c9515048da046bb1ccd8bd4582e4e7e970d83507f246f21f8a322823a99989',
);

final Uint8List _au30 = _hex(
  '019ebd6491ff000003000003000006ef92e033ac7f3a2d64933ca46d7d81b44102f7f8279e473ab3'
  '654759057ac8008ff934a81e74e97273eac2c96000000300000300002da0',
);

final Uint8List _au31 = _hex(
  '419aa04fe10843a5a21cf012c0538080809204b012c05500145c2ffffdf10000030000030000126f'
  '80637a5c9fcbd095b95589f4fd047820c668c9fcaf6a5720430d230e7453a9674a7c2b1f8588088f'
  '50015fff16903c83b7c6533f9dccdce3843e783fe507aa50ed2c219a69c4bdb55fa8ed7959976ae7'
  'db1c6a7b1f9a97b33c9b3d189e6ff469454590a85fd4945950d8f1d40d983de26c08aad38d17b265'
  '453ad884d7eb8a5279837cd0825955fd7c4ba03b1e39b1c0bf835a4c2516f8a8fd748f65d122f4b4'
  '5f81ecd80ca2ad11b599e9f2e6cd70abff2bc74f81cf7c8333ea961a66f115bccc90dca89dd98311'
  '14285eefef07a4f730ce677f3f43b96ecf6bfad6aa9f6e06af7713c176773e1e361461125f48ed82'
  '5229627f2531fee7ac23db0aeed6aec9237d435e6efe40519eb3e848d639e3b089da68f4bc793476'
  '49956ab9bf1381f2479f242affb4a1b147824f725d1c361cd6ef9ae4c10720713983d255b5e0375f'
  'bca26b00835709f36f2513f56fcbea06197a987706acc8f9a9b05a4956715c096b2928fc04c11d5e'
  '652ef7792fa513764ab87fe8049942bab146cd7d0060975c13594f2c5190f48b7fc0cb85d2109279'
  'eb8ddebf09af172f7c4da401ae8219bcc44409b6e9b98efe5beb9cb4058d5ad681509d5739071b98'
  'df998ae5a65665f5de28fc7c74e87ec0f668a594bf1f39ffb543e256e3e3954d3ff611b21cd4043a'
  'f97e36a7338517e6c9e28e90aa989662c2a49b65e6e2c5778353b0e9bc6cf4389fd2a082cea92258'
  'aa946baaa037f9a54b90e46d6b74fbe5b265068705ff8b837b965e4e81d8dd3b770018b97c7755e4'
  'acba2df7b4010ec8e12c2854f0203bed0354e3fef3da92a2c306fb5e35ff44b8a4a2864c310b75e2'
  '824fa6417b3c415302c02fe3baf7d045764b50c5853986010d2781fcfcbafe23f0811afd37860e90'
  '6e6f8a3ebba8d7a0b371c5bdeadfe5384391babe6b8fde980e790b9e1e04b5b06855d9682fde1d84'
  'c55730c52e680805f24f05d356967a98e9a1eb8c3cf1aa76ce9c0e11225e07e38d89a350822cb8a7'
  '683040ef4ea9b7f18c4c95b10bac8ca9109dafad9a2c6b14fc451780af9e652501725fdd8e49150d'
  'd7b5c811027dba999b5e19d9b5bf1a48aae81848449babf3bc15c78a3b8846590e159d04d56c24d4'
  '1e71f5d10eebdb92aeeb480973ac017654934ae864ee4cfedb7de11bc04e4274e53487b5ec5f1fd0'
  '9eba76d36cdd2b021a806265b35add9e5548ccb719897704874e6140908bb5f41731e0cfad89894a'
  '19a4d615e2326f76afcaf6139bd163d071640ad104de3d0755675086676c7a395f336a890a13d49f'
  'c84dbd4e2d4d5ca0a6986f894bfee5c8b69bbe73d8652c9e7fb1c0e8504f9965d8fa9857da1df7a1'
  'dab3b2c9daa3b813e970e36e28a553ee4f39f4ddcb4fbbb0fb4d4c4fdebd65dba20efa4675584e60'
  '7be3292537d27851edca588fedc2faf84ddfd7d8ada0af4c8e74362c7c1dea74117d40e5e1be20d4'
  '5740eedb9fabeeb254e74bcf09d13d0a8174da2d283ce7e3a2aa7fed8342cb44f1973ad63fd10a20'
  '72c3e8b0f9fa5a8cf2c0ee9d4898b9f8b578d7f0cb9892df80284e77691ce45d6873842e41983558'
  '840b14a55f7a452ba67b6438f89ae4d32171c27fe04f76678e55e24c761b3673fd5a1a8fff5809ef'
  '1396b82fefb6c7164cff6d6894315812f709d4720fad8aef5548dc95343fc87ecbbcda96df0ad183'
  '98675dbed5bacab522d7004f54a52accafb2054d2fa9bdcc51fe47024fe11b07bbadd4a8f85d50eb'
  'db3bc16cf9da13d5601570d376416a8b77c8a3f41ade2ec2ad26b7e6545087f7e2420d4216bef368'
  '34a08f6a2f09102d5b13076e529acbb26a36171df004d7075e5ccd1cd434bfa91182e4bfd3b6233e'
  'aec33cf3c74a2afc7bcb67ceb482506cc4de3d3b435999fc7957bda0855019ee0dab60e4dee36bd2'
  '9c2bd2f17b4ab7f008c857e9aaa62b8a4b62c4af597c5eb70b5daeb722c9d901e23e7f96035b4d25'
  '0bf029d04abe41b23f6346438e9b8b0d62c0b20e00aad554b19485cb8c56cfe81a8f98f196a23d7a'
  '999b952c30ee5d37751d590bf8b0e2cdb65093e09d59700560873fd55954d4f0cd2e95cc5d3dfb0a'
  '7dd38ac14ede4c473a13f03c4f2b5ba9157d8b6d8ee731c26070afeff58d15a53ca30ad328834743'
  '89cd763e6f6950d9d08d8d91e31fa809cfcd064773cbc60281d0b2675e50ba3ea41e8dfebc356db2'
  'b0b5eddf6f2c032bb0d9025f5649b06854a3c56c98acfa4c5c486b8f9671077d7ce391bfd6f4288c'
  'bdd77a579d571d899037cda0141598acbc9e6407194374126af678699d68f8c0464fd6f80111d61b'
  '609344fe6a615e34a84154431dc7b49004b8f001993f180827629509f239b76a001bdf0eac49c979'
  '57f01795e7492a6712d49d8d5519ec9818d5f955adf31b61f8605a6a1a86c0b7eebbe85a84729d52'
  'b29efa1fd66fddeca58718b95a644164b63c89c26f5d3d54a64d53c0ecee5f403c2f50cfe2964e50'
  '433fa895ffe7cba5f0c96fc62c73dac14139ece0b9781fefdf8859d2f7b781a327e54b3bf3452c42'
  'f5ba55d3fb7332f9a7a2e9a42f5f2fd221bd2db1e3b0ac1f5fa8853493f9db756de4d47c7306ad60'
  'd72b163f218d41cdb1b55d51025e7bf06064860d60533f12d94c583dcfb2f013b3c76badfa39a3f4'
  '7130a4e394eaaa74978bf8135cfa7da352bcb81797f45064ffd6bf70d0dc2d0cfa571355555e02f5'
  '8dca4287ed278b2ba72945b1570c2b41f34e114a7667b59fd7104f1ce86acca1c6ad956589a51ae5'
  'cdea9cfcd47adadbe2c953dc050533882e03a46350c0ffd57b21e721814e60be876c02b7db9e2ead'
  '90b99f85147b1d1c621bcd949fb2173f85fff6566f720957f37294a1b263fea614b9dd6858faaed8'
  'f5dc0d332fad6a84948f132b4cf14991774c60d76b66b5b3646552d4ec992df648fbcb985a7edeb8'
  '3616d5a5c61f4e8b64584e85eb3572f90c719384e00b3f0683c423b4159d8439da7470f2f02cd831'
  'af32cf017330ece2207d57843bbfb7221981182338613c7f38b5fa898192120e087aca1779e8f181'
  '3602df87def0982c87bfa7eebfc4269c8a0a0eb4a1ef600e12c95f2da800000300010f',
);

final Uint8List _au32 = _hex(
  '019edf6491ff00000300000300018d8ee34cb595fb35abfab4b8421036baa8fe29f8ed6e82cb934e'
  'f092b8e32eb2c8da531a70f263cb1549090f71a6ab000003000003000c19',
);

final Uint8List _au33 = _hex(
  '419ac24fe10843e94863c0b4030602e00e202b80bb02d00c300144c2fffdf1000003000003000012'
  '6f8063789eb9f148e83d1080bf3dfb5a563219c345c78c927181a86de27e8c90d8a427dcec679d6a'
  '96f6bcc0ded84a9d2fd8f6d32c46f5c10732b9233423d374b3af4f77f29c1fe7b886ddf3091cfdb4'
  'e0bc86c4942d37079e51f01600441c0f12e6615e2d87b9a1543cfda6e5c335cd2aa743d6c4a61207'
  '6b86185f213a95639cbde1dcc8c2f5f791cd2323750d7df0d274bf8fc67ed49afcd53c555a3075bd'
  'e236d1b7079fe6d4f1fa5f2c10163a9752c6699749c09992a5d7a6e74dfcc06018f52643ee584dab'
  'fccbb43a0c55769cdcce91a3815294caa40bd5251d491675c66b57c9616963dec58ebbbb70333a48'
  '88a05e7d7e8e9c6f42a209de153af76e966fb2454b3ed31ade67cf790d3218dd019f3fd45aeb7319'
  '5293691e8add71c13ee18aa2b23e60ebad8cba3dc27c52bfbde7313fbb1b60503f1a70d92ced7352'
  'ae498df79f709575ce0ee603d8503cd40787db5db29e3f45914dbd894dbf7acfbeed14f8339b7e8d'
  'd1b76c6f6c3c76a6ad8411374fcae33dfdc1562a3b4a22ff7d7bc541b8305e0801ab63a720da4d46'
  '1656700b56be192a19d7937c500dddc5c916b0758059eaceb90612d161f04b9e907b55b23884498d'
  '0ecefe91e9236f4d24ead0e8b19501d03157762f0b6e5b3fe0a5c22cd81b4ff8f359c50efc99cecb'
  'b49aec7d46e908e3dfadd257e5a79e0309af06de56e1d70b1a394a1543f1d4dc865ce575f5860a35'
  'aeea4f76e5fa250155adaeddad919c7b9e47914c95a1df744413a056caa998503d0f49abbeefad7e'
  'bfa2482f97b871a1015705488d150f3d0d867e7bcc0e8090ff677ea36e351842be4f72fb6a244831'
  '506a99cf1832b9671e3414d208c18b5d236dc5405880390300bcc11d6a35c5303b8ee92797d4a9f7'
  'ad13a4a1318ee7f5249abb98556731f6ccea33b461523fa891b45659eb6758470879516df0dc7b5b'
  'c37f0a9ab6dec433cfbef092e662717eb03ec312f3d1bf7aeb7ec5aa5c2e4b9a07b334fd7675c20d'
  '3f7dbb2d178635f79b97722f895c5acfff74df881e68dcd773f575fd9a884960be5042a9386afad7'
  '4aa1bedb9a45fc084bed6270d3c851a1f0a7898dc5d328cee020e45361f7680b0e5fd7d2ee562be4'
  '6705d99eb35207620079fed3fda5bd3472f9d02edc85c58b9391345d9753d0d346eb365b446aba59'
  'c3c078d5b5069d197667485ec95a87a25dd871525320a25714064720d2bd7703fae9ea4eb9304a75'
  '6382730172b245e6eda7b7275da6aa2506fc36823c2c0210c45b0071e67ff20bfc0eeb5faf8b57b4'
  'c7523ac57a9fc6193e38599be99441eb025d089f34a9b9f6238a830bbe3593e0f1cae6dd35860451'
  '9cd7702757301208c1ec0f6cc09a62de54799a9f86c1f78dc112561267ae6847ad0093ad500817a9'
  '93d035555cef2e64a2d4e3f45557c7cbeada757165a8713bfc7b853835ee40bde47fc18167ba5d28'
  '3a2bb148393f07d02529b60852d0c1cff21acdba6d465b1e2e99cbb0257a76272b0f49635096e9b2'
  '9dadddec5a3b5271b8e5ae8e317b5f69819221a7723ae721fd508fba3533ca1e223375763a537db4'
  'a0008c3b5084fe7f57db3dd73958e35bac0c775dafe564bf8468e75acc7da60a94716bb6ae83b8b8'
  '169f881c47760ccb112ee4664a3fba103b419dc10b85c993149e81fa0ffe084fa8bb55a46b6eb831'
  '24a6c6307be4ca9609002c1b83e50bfc58bc106403450216bd069f8548a2edabb5cca30758affc86'
  '962473fccc030a59197eca04e3399421e83cfb175c884b8754716543434d7a1e7bfac99d4fc08f98'
  '58599f43e3526c4ce84a644c8821074d7714ee144180e1cbb455f4f860a9ee712680ef761cb27fe4'
  '834767097d73a8b83da59d697b713afb4a860c324a2d811eeaa19317530da9936f6ff3791f2d43dc'
  '774dad5cc90a0ceb27416462297553bda9fad587401548fa1dc8577d784d00108a46e2aa8dac3809'
  '56aad19c8703168e9285f254bcb53be3d471d121af93abdd02451fdec5a1e288e7316423cf5118e0'
  '79f0a42f81c58092859023e404af06efae1332396707847ff4b33735cea9c4f980bf1c04c8ef16b4'
  'ffeb432de415db2151482a6f6037f66d9aa32994a321dd9cbe23ffdfdf48034235520eb54b352d19'
  '804db27cea39a018a058ee0777a82f32c5cd4a2fe62d3c9423f56b624cc402eb58337710dd78e133'
  '8d411fe68ac53a8694861f0c50730da88a7b28c4e05e2c953f61b9457c68f368a131d78b5ac1f95a'
  'd0490c97b87d38dcff57a10435d0776fce1906eeabd134529600376e8a89cc26696a15d52a6cc4f8'
  '4eb1d7c1be2ec497a97e18e34050dbb56bb1fcf9ceaa776c4cd6aef6b196164c35c71ef57f0ba742'
  'ac97b357ef6e3f6ad83402d32b6969d0d6520a19a5297d2bd4a89c726c559908a901d035d3a5e984'
  '2de510a2a9492b11c7439e98280b386a602b12fb00be500f05ae25b9f1589fe95d53738b9f792fcd'
  '3c8fe7922f19a0fa482b0e51fd293f785830ded3432a10f4c1d5a88ae917874d2de46fe16a5833e5'
  'b0363bde5914e9b934e4f385affa15a8fa0e18fa778f6af4c6e95b739208bb8a3a4e7daabb82021b'
  '2aa39bc3ef2084e252eec0af23baa0e6a039e91855d77f7f13cc3af3bea5a7b2f3702d6baed593b5'
  '5dad19b1c1b03e5186d4e8a4b2e7627ce1f2235701926a9066ed052a4710e1cf35206d6fcdd78a94'
  '26679809ef8bbccd846f38c8ad666e9a385c181e0d3ffa40d53bbd63474ccbdc08f641423c1d5a97'
  '01d566b019ebae65df5ab44a9595a92814577980ffe1136adcf9f9ea674f353557d351638a81041d'
  '29415e6d60b7166b073d95618e4282be8be7f9f698f01ecd0626edd99ebdcd4db0e971b77842e511'
  '0a7ef494c2f0d96ce765c42419ae136b2f645e1ec427325cd7dfbc0cc338bdbb0679133181dc55e9'
  'ce98c0e3ae5933bc8b8baf24b320cbf0bdc14097a80a7faffc7c70bb82c586524b7dff76d9cef489'
  '1e36508d24599f2a703b37c15888fc920a3a680cf39cbcea3f2440d580c68d01a3d2e682e8e679fc'
  'd9ab74e219d7ae3ffffff67fe420feb9cf64d8240250f2f3038de2f9a3c10b28267785a50c1da7d7'
  '57f1b6ea67743ed31e3a7516691c42401fc08dd39ada4dd9518e3d4cd0ad214da321bd81c74519eb'
  '29136a47c1969072d25597402043ff356839efce31a061bdbd63596e1c520048606e33af6828a405'
  'c4bf9582e91041b470aead735c47717ab7b7d3d75648c7d7840fc6834cbf1e4b1e75eba68267f93d'
  'cdb86a7c12660685d149dcb4fea1afd6b6712c99925feb542ef489d6f030bc47d86006e8516ce23c'
  '0980953945c2fbbfa78807bf75462c17d7c9ecedd5cd38bea5fd9a3b4078a3731b040d6eb783f107'
  '7dc846bf18313adb65f98b2617a56a9565afc3df1320179096a5f293c152cf2c9c12630c8e5dc338'
  'ab8b0043b7edba14c6709bf0d0823003879ac37262a4beeb5991a96773cfbdf043a189b02948229e'
  '3f5f09ed8748ea1fdd3372a59c134f18d867c2693ccbe7610d26d0c9c06c762e78ce1a6bcbb24707'
  'b6fe68ac28a1e6fac7186e096d29ae28414f1d0fbf02a9753f528de24a8a6243f41bced6bf97da86'
  '22d947fbdb9755ecc56ce3673c569017a85b196049bac827f27648b6426a113e300fa7918192d7f8'
  '8256b503999dc8f2f30056785cd0026dde323bc2174f357ef04a168851b01522e3a55fe6e53b6efe'
  '6b61334058cf3906eefb9da37bf4a14d8ad1a5f3cbd4bd2a67c76597c9f816cc746d6a672ba083de'
  'a427211e68e457e0cc909e5ffbd719fd5f3cc46addf12f51836db75a6801bf7e213b6598f2e58641'
  '5f3898439f8cd4cd98b4e6fcb8edc1d5922a6172b9473d176bcc77ba06f3088e5769869d1e1be33f'
  'ae9e841282fdeb778264e701b5cd778c49f3770c24cbc0999b5a23755283769e8a01e38757afd454'
  '4c4a901a34a52099dbebc83d8347272c47dcbba1814d1ff848e3d00b3dcce1e296eb9c92fa63e304'
  '61c60d67faf477a425052400d4927549e5ca1935c1361c1bf2c6519f770e916113c630948ab3a0be'
  '409fbf4a5ab2a7de1a5c823fe10ad20767a97ac5114453f703dce8f4dc272433468bcd10adea3e64'
  '5cf99c08e0722121c58e054773a8698d9d033e2e38b9fc658548cf5ed3283d5ab44a6b05169819fb'
  'd0466c5bdfe853f84d5e6dd3321a079be8818adf2973d9f66d42bc1a1f22622ee1ede64d58ce3df0'
  '2ec07141f87122c8dbbbf84949d56cca7cfd1fd85d844c9d387c994ce38d88234644c6a7a8ec2f1f'
  '8a0e5450fbfab24165f193a4b2dfed32566b9506adffdb90b417e90b6886434513dad586f97ab466'
  '023f22353ba42e7947bab89d06db960ea606b3b9b7747e5da705cb1edbc869f7e84bedef26c8858e'
  'a5dee6d94be1a08ff25f6bbf8e10a3424b1742096a50e6e70d958df98765bf1ef79b65b6c93f2b50'
  '7ed6f1885aac2b6ca6d2166d9af14dd5b0cc9b128c5ab25bb0df55b731aaa4d39e63abc730327d83'
  '56fd7f6777c69601b027b97d780f3353ec27efc98aa407be3a9334798fa171e093144d35551ae2af'
  'ad6a70930548ecec330b61e610c4e9761d3f311450c295cebcbcd7ea7d3f9696ce3b060682f4a104'
  '935ff7389db9ed1a33c5866f9347a5c8a19f037f40efc16ffe0eff41c11be5370d2571a323b27a2c'
  '251273b459704dc90bc4c5e39bda54711f800354dd9f2e2ae5b6dd11593658b5406c0b48f2203233'
  'f2020fab6e25d3c48b2f9a0a6d6ab5b91a2036cd2c78f9aed74a5f25981acd33988d86306fa8969e'
  '5df4840ff5adb7f968d6a57a0e9b395a6217cbeba7ef4e8a982910b66245071ab1f4b0d7fd77f9d2'
  'b2f4ed346b5c8b29db56dea0fef7722605870945a1e965386993e962c84f102cb686e0c6d31565c2'
  'cc6fe36aee0ae44c7447b991a99fba52dfd5e2b914c896847350b85dd9ff12f09889bcf7bcd682ab'
  '2bfdc78570cd80bfad3aec3c06ed66f97ea8b97868fdd62a9a6071e9b64948a7b27824bfbfb65b94'
  '97eb06a374233b88743e31726f26c154d93b8f7d3247c9ea61b6fac9dfbdc4956386f3bddcdf70a7'
  '556a576569c803dc98d6b42b3b94979a3b61165d7c919d600669436e331be151c791ca1fb2324301'
  'f8de8ad868a5bfb78a815b90e15ad0bcbc6fd0e98dbcd9cc2dd46b6eb60000030000030165',
);

final Uint8List _au34 = _hex(
  '019ee16491ff00000300000300018d3303fdd59733069aa96716a85f807cb33ffebed44e15e4801b'
  '15dd4a96f5604e33c638e06006532a23afc00b58ea67fe708ca3e4893ad901c32fdc7b57a1757c8'
  '686c4e12ad8b92e2de2336fe32385fd678c5cd09b870c20cfacd40c0a4533105676d03b73fcde15d'
  '3c5dea2b4a237fd26b455b000c2af0deababc88542dffa624f19379d24c6e74db254231b8b0f7ef'
  '2d83049bd5d1d8348e38446773e75cfdb7281ffe5c50e786be2b81ad83445d8ac93c897880e8191'
  'd35ec3dfb95d4a5a2ba48025c4c9fd85b26ce41bdd091fb007b17a0da591af9e873233f1a4c78a5'
  'e589b494af4dda89741d03033fba179e003e6daf60ed6592d8a1e4f344635195ff1aed25020c906a'
  'fd58edaecdd02feeecf0000003000003006f41',
);

final Uint8List _au35 = _hex(
  '419ae63c21fd13298010bffdf1000003000003000011ef8079abcd8047b14ac1f0013047387014425'
  '3bd7cad51df595de5940a4704805e74baa306b860f8dc14a49f85d12513ac42cafe583dddbfd2fb7'
  'caa2b5f20e5907a8c3f980a1df96d11ebfcaf4bd3d3e0be6e32cf36983d3015bfa5fb6b54a5a12'
  '594734622380dae95e6b8f1914f4760d66ac37a0e2f1c7e433f578327222bd3fab162ea1d236a705'
  'f049f90ab64558f3bd42422fb6282e3b060fdc8f337386a4f3c374d04902aa59a92f9735757dc7dc'
  'df4a84116e1e47eb6f51025e86b1e85576b2669bb0eb55ede6860201c000003000003006f40',
);

final Uint8List _au36 = _hex(
  '419f046594745c27ff0000030000030000f2e41e8b4d72b32399ad34084a59e8a558f434b9f877c8'
  '84443f275298b7d41dc08f1371557ce959fea9344d55e869743c98522e7cb601d7a0000003000003'
  '0357',
);

final Uint8List _au37 = _hex(
  '019f236d11ff00000300000300015972fa5665661edca112aba8c34046b7dc95b53d421b18db8769'
  'd0643f1abd7d52dfde00dfe2342e08e5160944000003000003000939',
);

final Uint8List _au38 = _hex(
  '019f256491ff00000300000300000782ac7198847d97a6dc2afa2085ea9d0dc11e488c3b389e01cd'
  '10167b9943618c6d455680000003000047c1',
);

final Uint8List _au39 = _hex(
  '419b2a35082d793298010afffde100000300000300000302ebeb65547a1c74a832497a00b8ed9fea'
  '7e39536a46d5cd3e503c1caa84cfa2ba9927f042fb941323da70990a9f685741c0ebadeb43fe9b3d'
  'e7ee3ef835b49fde8abb24da8bc86c19f49a2ac886ae811870b8f4b120b8c4d82e65ba0e9635ac03'
  '7dba16508745d2899b1d281a03dbc8afd100b58fae244d8f2a429974152961804250ffa287126895'
  'c9863eed3e00d5c5439bdf40627649d46d572ae477cdd35a9639252ba85f7725ad3ba46376679a1a'
  '302ad8073db90b0e2fef623fc0f0be52f624cf8000000300000879',
);

final Uint8List _au40 = _hex(
  '419f486594645c27ff0000030000030000ed2c457bc478a6a9ccaaf48c2edcaccba6005e55ac9d2e'
  '79f527e4f9d61c5de92d9f29f32180b9a5cd4b8000000300000ff0',
);

final Uint8List _au41 = _hex(
  '019f676d11ff000003000003000027bbf89b7d0639fdff7a365573afa811fba2c9bb8543fe990190'
  '7bd8c4073e2afbd200000300000300074c',
);

final Uint8List _au42 = _hex(
  '019f696491ff0000030000030000079603f988b09e93e1a61b62f45a5728e0ee0c9304e76eda801d'
  'a2cf3ee02984b194000003000003008381',
);

final Uint8List _au43 = _hex(
  '419b6b35082dad13298010affde1000003000003000003000d29f97886db3d44bc8ec83ec655dce8'
  '808e88bd6db130de24e29ef1a52aaed6de82ea80a3a7d28f9ed2148fe3429863e4afdd2d047c7456'
  'dc6308a0e995e170f78cf3be81efc6cffcdfbe1d717ea74871786bc76f506bdbe3e35e11c207510b'
  '91b9600968b3cde6bea02663d93a8c5f0c05c24272003d917941354e83ad4c3a29aafafe6ffe9dc3'
  '9d8d721735ee9681141fe0a66f52dfeb37a46acfbb7142a446db658abbd4e87ea88b43644bca6e6a'
  '25c0c8b10713984eb4259b37e424603d2d47a7f4b5ba877e4b6bd2106f541b9ab4fb7220102fe27d'
  'd888e8755edd54cb358ac55ebb0e5f962bfb0e30e440d7d6f39101dbfa550c9af8102df3f803c0ea'
  '577cffbc0581cabefc135e77d59b15dc81a55725aa376accd7553507d31be967f7a4ce63f3092e52'
  '1ab40f136467331635b25740603b2cc957c2c66bf9a9ed32a80000030000030117',
);

final Uint8List _au44 = _hex(
  '419b8c4fe10a5b5a2653000857fffde10000030000030000030079083a08602ec7416f5010afcb7d'
  'efe9e90774b988b636297be53992645ed350ee6ae6ca8fb4169a2e49315e761b385ee4621964853f'
  '19474e266ef5e4397feaf72af98d77b1b0c4c26134fd1c7d38057cf2b4a51d3a6cebca2e1565983d'
  'b389f17a675922f38c846275cd25cdbf2afca96ee0efccadfecb9ed991d0e7f014cc40b09186ec35'
  '1e510f25a8cd559f6671e9df6bc14514db5990d228ceedf8ad93fa6352dae012fbc2cf786d073e77'
  'd163c5a5712614dd28e38d9a447abe8a6c94db289e71dacd0c2544bd32b02392dd99d18c598106c6'
  '110d590050000003000003025e',
);

final Uint8List _au45 = _hex(
  '419bad4fe10e96d4994c00217ffdf1000003000003000003004b4044404b54b7bab81c519dfa2ac5'
  '656586e81a55f570b492a90d8a89840afbef35f11bdf8bb8e19b581fb0b5e8c29d0544d083bd0315'
  '42b35b00119cc0bb554a42e4da55768f7f1a5dd38af393d522183a3d908dfa16351505ef4b6574dd'
  '1f5e758f0629295bddfffc736aad063336756739df760fdcfa186aa6830e88eb038fb2953854483b'
  '4aae684a4d43d21c5ac202103104a6dcb9007e64f77747780934453b6742f4d9105485cce273bd1d'
  'e9f9c573ee856426309861d6e31662573432902517c72e7e48bbbe1bb58b9622fea2e9dbc8405df5'
  '9564da0fe69b5bd3c3b46665a8fbb03e31b8389cc1286bde9ea6d7f86d0905d91b9493e54e410b96'
  '1966a6c435fb8a7bf53c4dbbb11f56afab2078233a3e0f4d3bd6cd6026d89396d538000003000003'
  '005941',
);

final Uint8List _au46 = _hex(
  '419bcf4fe10fa5a26530014644c2fffdf1000003000003000003004b279a50c2351488f3c6070028'
  '9bb8b11c17046cf094c7c273bfc6ab148ed25d4f3b0581d75b75af034aed3ddaf61229773f88695f'
  '47d4e4686316627d0451e625c1f676509f9fa9a806547c98a02558b58e57030421e6578df1672d51'
  '99f6b95f3f2d1b1844232db40060abcd1d00880f9fea64ee0775e8d861f8a9fabcfe3fcddf8390c3'
  '5ef0a3f472d430d1ffd2a3ff7f9355a2e4f9c4f50bb5d771e3c515b1b1176e629bfb205f6f5f5280'
  '7c19ddbbfce5f04fd60fac2cafe109025247c57656e395cbee401c12523409f6a08df0b9c3dbebc9'
  'fac6ed3af7b2b72c84aad84c3b1e20308fc6ea5599229e62bb044b546c26c556f05433a1f53829a2'
  'c474bb8f7285d80ce9693644711ad6cf20df2d92fa2fb00863f3307f5de07f7116ee95093c4e79ac'
  'c4fa5d6793acc98c25d50ff5bb7c127f66cc2f385f072aea1761442c63d47187f2b8df011a685b59'
  '6d41b5a0ff8652ba76bbba7fedc2947829e8099c77900c949c8f771e092d067045b8160cfc480e5c'
  '55df8be1aec3c60d0af8a2cd35ced3f77b8325dbd2028c526784c0d78a73a6d7a2156fb10ce67d24'
  '32c65bea406816a48a911a8e52dc97f1a2296b943aabb3230aa4d8d3bddcf3b10594a110345459f2'
  'a94854cdef551b4b9a9864fed27135816047cd97061f9ccb7d68189975e51be82b96d7d833858c9c'
  '87f948042c06c6b8b45ce7b000000300000595',
);

final Uint8List _au47 = _hex(
  '019fee6491ff00000300000300017d471112afe3248a1fa3f79b21b224e5b18cea88d2bf29eca800'
  '4e855543b20efff530410372c72334d43dad5cbf0015b79d57ca18e44aae86f143a55066c731ccc0'
  'aac827ef1dd5b0cd1c09e7bc3577343cbec976035f103e4800000300000302a7',
);

final Uint8List _au48 = _hex(
  '419bf13c21fd13298028d85ffffdf100000300000300000300386b1228ef3442ccd40168fd3f5870'
  '9b00000a121235276fb662726cad465ee523d661dc42d00126bc045e8d9b8c640a65f115e187192d'
  '419efe364ea9a4f8f9bc264666c615fd57fd6391f69b1c3705e1cd16ae88903f8ab805e7916a6d35'
  'aa03f334697710f7673b1473ebeaf1614ab2bb629ac0f42412a29ca1be9c8a5d8d3b591f91f41c21'
  'd835c637dc06f96912e1a2f5b09656f883a12486b6f7246d31c3c4eca332172413983f33956c4399'
  'bec5b40cf5abe4c8f1178c62736ea96a56225bd1cff85a98f6bb0ae757fa6e8beb027b7c3c67ba1a'
  '952e737cbbac0285a01b5d0447bd063689e65f064d95577c36d2072b5ca94b97928b2ec7006f46b3'
  'fbd96208bf9d880c7a4c8a7663e2e530ea43f451a71c67121bf6628e1d418e494dbe52313754230f'
  '07597d685a37d2a616ec4512570147dcd42c77998abe9e26177ba748c04d1cd751dbeaa2792137e3'
  '86770ac47ca940e7bda5b5ed822899879c2e7468125c6f6393096f8f5d367a6eedd16cded38b4978'
  '71ac3bbf0318f8030f061ff2bf68b634610c5b68c1b5498496bfb1da0b180433cb3d446f3a8ebbcb'
  '2f7e8c2a107e6929d288c801435c42b717561e5f8747de5f4461b4c909852aa1da462b7541d513fc'
  '49e9903bd9652feff217850ffc09f4e19a9bcf31662630384ef5de7587401b80',
);

final Uint8List _au49 = _hex(
  '019e106491ff00000300000300017d471f6603509f6fa88095014f875c12892765c875d210825cf8'
  '6be0a00b3183f65c9d343a0956554785ee0588bad1a7194569590225a8be9d81593e6c829c67d824'
  '3c94a5a376be5392cb89f5cf3c26f78bd56c208cf2ecd2233cfff8dc7a63c5b64d5b3c17712e0811'
  '5aefdbf8f00000030000030002b6',
);

final Uint8List _au50 = _hex(
  '419a153c21fe4ca60042bffde1000003000003000003005600c8a73cad22265f80340c6716658919'
  '6819634ce1becfa513b2f29c1524a6999f4488ca062e0c5a0dc9c0df8b738150aeabaf3bd7a13814'
  '05a02c28dd090fbfb734447e81c11689c7c5e8955e1db4d57ccc888ac29e8ee262995c48c576823f'
  '3a1dd67db1b0ae7d4b6025ee8d958a3954ecf2f1237e27c7c1e7d5352ca7e689833e6dc3455ab914'
  'a5253fad0da417122a01991dc22502deea4aa127d4f9be6414ba56ef69163249532a2408d2a799a9'
  'aedadbce16859645a5b034e877ce50d50d5f481d148e32c3b152fbac075868b0a46bab60feb8c5ce'
  'ab42f279014eeab1dd51f38138966b16a751784fe73aeaf7df804c1e832dfe1092ff43ca9526b201'
  '4038b0c33107f51b148769463691495fcd17cabeb2c94cf96d6a44673663019285df842c540b036f'
  '2eebf713222fdd95043705f6d249f45b2f3efe61879abab4cc178df7d5b64a3c5a5ef68a5563534f'
  '085662306c2eac6b9b5864e249ca674ac7da3a471f973105e5116583a0ca56b73754e4be9f4e3f01'
  '5e6812e79942d914be3ce5cb679b6b2d72cec5df836c3257bbc53c492fd824b9d9e017b90363b2ec'
  '42d050e31bfe8b7ab71dca21d2896a86c842ce3cab520052b14fd86677c7683f999ccd76f8000003'
  '0000030317',
);

final Uint8List _au51 = _hex(
  '419e336594645c27ff0000030000030000ed2c44dff6f440e5e633905e4e8e97c3436daaa6d58cc9'
  '0d67f3455584a98b5b02717825bcb83fedf44234d6197ce25888b778c05400e8f92855a007d17eea'
  '782d878dadf3fb0d0000030000030006fc',
);

final Uint8List _au52 = _hex(
  '019e526d11ff000003000003000023c57e47cbec4273d60a2dd0f297cc5b284a8e991ba697a0f2e6'
  'cda6600ab932bf7460cb5126fd5266e85bbfa69e4b4ec600d34493355d4a6d1b7cde5003cc000003'
  '00000300010f',
);

final Uint8List _au53 = _hex(
  '019e546491ff000003000003000021be7cb75ab5f2c067c0fc88838e705a96cb8abc039eb40e9245'
  '93fc351e1b688350036e8721b422236d2e6ca0033eaea7900000030000030041c1',
);

final Uint8List _au54 = _hex(
  '419a5735082d793298028b857ffde1000003000003000003004ff73e5a054980013b720748ddb0ea'
  'd9983d16c19a19c4b44884ca196e1a4a0eed5aa77e3297220b227fe5660bcb23386a7237eaca2280'
  'cad2f991b522f2e4de7f7e10774ad6ca7300e36d187a6e66ce07294b2d3f60a5cb1004f1f045a2ef'
  '40e32f15f5afce2910f01bb181c63115cfeb00811d204345aa1f914dca0a51c06b2b2fc9a6259184'
  '0f20a7666aa9c9552fc5fda15ed5c524261d0965dbd5c85c1906625104f44aea19d2000003000003'
  '006840',
);

final Uint8List _au55 = _hex(
  '019e766491ff00000300000300017d471e78d36b87a8e48986da9e800b4df1cde99fd4526ac93543'
  '077a36ba84df824e902ff73f2cb3b9ffffbc868bf0669be6db1b84b163ff77fd870e56e7b14bf3f5'
  '4e42f2f900481243c3da9021cd0a5dfcb8cca862cf2b08760000030000030006a5',
);

final List<Uint8List> _au56To90Nals = _splitNalBlob(
  _hex(
    '419a783c214b593298010bfffdf10000030000030000030030e502922d6e105d0002a3a2d21724a5'
    'f095988560802ee45b347af8482f4b9d25cabb956ac2e0d318be7fa6ec1abfb6a7ad07d6e9e4114e'
    '4edd0207d006159f1450869c53342950c062f8cb5d39776bda75fdc62e170560810ca8f81426fec5'
    '8bf38db08f184801e629e3e43a58f8ce0d5ad5567b7d0c637e522c95736c733cffa65f057f6ac761'
    '22af43c5f82435319b10e000000300000655419a9a4fe10e96b26530014645c2fffdf10000030000'
    '03000003002ffeea2fd5225c80ff176c081bb3185a92b03eb292f358e5b0f00c3a24f5d6e9032684'
    'f92b0c9c6459f3f59708bfe1e976bfa52b9e38cba0b52914b88ab391a92de99f568184cd291f2e91'
    '3de77a443bd5c9b2a03b73b2858a0f42bc15f7f87cd3c81a17c50db1e433ed6e92280ea76e4fa4cb'
    '43287ffbefeafd8fd3e373200287c5d4747fbd319b8df6ac65022c212222df5cf33e45d8356bb4f2'
    '973def3cbd9c392c91b3c5bdd92e41404c3e5509e800000300000300a480019eb96491ff00000300'
    '000300017d471e771d0ae3591b2c92980db81cbcc583a152c217abcb35aea6bc27be158654c4d6fe'
    'f5b258150540a5ef83a2f876b0e6bce90efb05f4c3bf86ee9b400000030000030000de81419abe3c'
    '21f4a4ca60042ffffdf1000003000003000003002e63a35f486717a6d000ab0e7e166c7d633926dc'
    '8bb296606732c1b81fed61a6007dbcefc811ff99e86f1838d04b6071514f617449e5ef10880fcb56'
    '439f0e881898f42cc301359093e32b91fa9d4d9c32003997359a86d3bdd5349a318e6116e01b3bf2'
    'd9e1c00000030000ee80419edc6594546c27ff0000030000030000ed2c4498499bb4d9fd8c0724d6'
    '123d23cfbe4d36b1a405e57665370a1a8e43bebf7c3a7bcde312cd538813dbf74387b15d2d772bca'
    'aa8a101a98452c442251d1a163e0d8000003000003002b61019efb6d11ff000003000003000021a4'
    '83606d3e6fb29c44c5470a85dda93fef74e1e2f4c44722fe2d2e1d8f6de9b466dfb8389a46be1404'
    'd7dbd3403e6012500000030000030000de81019efd6491ff000003000003000021be7c4a9f51586d'
    'ecdc126a7c36eedd32586dcbec0dd27422e7e280a2742d795cf39678c6bab0d36f45ed4056000003'
    '00000300005240419aff35082d793298010bfffdf1000003000003000003002a3bab8d15aa1f0016'
    '80984f81adbfa6ddaf9a4a5e792f5cef7a920b789fbf3531adfa523cc6dbaf302bdbc672f5e0a799'
    '3da765efb7ec2c85d094f2ead8b77af5b5456225f190339484da287c000003000003012f419b014f'
    'e10a5af26530014645c33ffe3840000003000003000010ee25e34428cd4011a162e891a5230249cc'
    '162d512838b27d354bd246718dda54859fc689407d5665a0cb38cf3d0f3aa16f0cefb3c2ecd44fea'
    '7ede13f18a76cfd4b9577e600842a968b0dd53e1eafc2d998646de9c6ba7eed88e7a80d4015ca3fe'
    'd56a092c49c9e4ed2cb46bd458c14a310465adc0a92942cb099566f1777c086e3b199047378a628b'
    'a92fe4a088a9ee16cf981ce7aef95a9725a38ec15208593dab6645b8dc626145b4b9530fa3635dce'
    'd196eddae990efb8cd66ca730e358cf679a4ad49dc3d02d75cc0f66fa8cebfd6c52de8c367420028'
    'c5d7e2b7caa79d8635483f5e681d26bbecd7b0fc708739ccc396b76d18db3cde3cc519e136cee991'
    '9f9a3c6691a64afed4b6120fc30d7d01f9a31301a2e000000300000eb9019f206491ff0000030000'
    '0300017d471e7686b5c1f2974ad64002092f909d3b1331b4e98ea98f155a094d34480542398f5ebf'
    'fb4ef80ab0f3c0b5c4c9114bc8a63b59c51de479f0e282419c2b8184a09770e2a3d38ff06def2552'
    'ac158a39f54a6941893af00566eb93157ba0000003000003009d80419b253c21d2d13298010cfffe'
    '384000000300000300000fd333b38b564984015881f359632fc63b4979d66b2cb5e92e73e34e8e58'
    'a59590b4182f451d6b8914aa2043f102af10185423da4e57d2fdfe07c272e5d6269598b4b5f77993'
    '5404d8e3b3557e00f5e3d42cf6326df8886ed6edf41c918c1531fb2ef124256dda8826ce04851078'
    'e8c9e5bebab3d4dec96578f5e880d84aadd86e83a31f951d1c5cabaef9cc85fcbcbfceca2baa57c5'
    '79d1fba9a47a569174c9ffd4e3001fe237b254ad599c84bf63581df912cdd2a43cd7b2ae936389e0'
    'a674ef8cde8c5bb70a2adf482166861722e40ef1965c030ee55de2beeb01b2a844be6150828f832e'
    '99a6b60f7b828a34bc6a694a570a94e11ed7eba753ab907d3b3eb7def43fe57f78f77f2065d3b7d2'
    'b9bba2355caa9a1bc0569a31de4c34abd354a39b9a5afae8bd4fd458eb44b437337fa1366704850b'
    'ac55a3ab84e536421e7bd9a8498edcef0b5b903ec0dad5e25707780000030000030123419f436594'
    '644c27ff0000030000030000ed2c4498333769826a6c78b23e000747913caf9dfd3a8373b552796a'
    '7bbc67da2c578b49f800a5730bf53d55860d8a2b9ea6cc241e2f752efd500175adaa061fda74f553'
    '6bc11242bd191c68458fb9ff2c5113ba6f46755ed408feee000003000003000286019f626d11ff00'
    '0003000003000021a482ed767711ebd955f7f4ea67a80b01578f468abb5b6ecbc3c6270ff585a2c4'
    '78dc10049c32242a1c668825357f495b7c670907f400430009bda1cfe02c012599c03a1000000300'
    '0003000072c1019f646491ff000003000003000021be7bfcbd84dba02b965a2ab99e8e5885c5fd9a'
    '1bb271a235574eed2502f87bc2bf06499ebdeb800b9e87bbb655b196b96a3f6d82960f5c7e337f67'
    '43d7ebfd2494bd8be0000003000003002821419b6935082d744ca600433ffe384000000300000300'
    '000f97a91ee757832469bd8049f5b8831fe1c5b568aba8b27c5a32ed522364b5ca77d221f62dcb30'
    '3600f0c510e299d335a585a03288fa27d17cca43d9950b7d8126ae65840f61b8b5383ede1e0df026'
    '3ffa323ff6be67ebbeb7866d6eec47eb622cd29d4a234e979583c6e63e7a5dae6304adb3862bcf68'
    'bdd7df399099f85119773d5b2b43ab0c4ee959a904dfa9317d72cadf82d36ac2c1499bfa077c6960'
    'ce1286bd20b2a6526cd5df350296c4c76bb14a1f2927233e2713b15b62f47fb38f6b9663eb8069d6'
    '930c9d305abe6328dfba97400ddfa94b5612a7a9e06bdf4036d88f781a7a02761ba55057a229ce47'
    '78884072ffa34a39ef997d8f7a79e5b505508e575f5e0a557f73ffdc527d7d0c3b0fa30b2e2a108d'
    'f0d5c0f530a0a80efca46f05c5f6d32e83449a6f71551f72fa2c3fddd8b38bbbf23558948604eac8'
    '0a496f20cfdabfd1b5c0f28ce2b8cb2fcfc2f578005d50606efdc13c8c1504f800012768af402c6e'
    'e4d7ae1a6ff6ccd10bdee0d3f550ee1415831417b7a1092975d5a1f8ef211fd3e6bf9877456a38c4'
    '59714671827ffd19019fcbd8806e28c98d4b0000030000030041c1419f876594745c27ff00000300'
    '00030000ed2c4498acdda9ee36c6cb164800340cf900d1468f209e76eedffa609bd0b5abc4ed1fd7'
    '606090f71017c3312c03641dd716d0d8a1e7d7c1673a45259cb5b6ab70e0378f79556aa0281bad5f'
    'a5c76931d803ac00648f7a3cfbcdffe2e71c3bbcc6b97d8bf6b300000300000300002e21019fa66d'
    '11ff000003000003000021a482dcc6c4d57b35fd4a6dfa875df3d610911e74847b9e6bf82e1ffcff'
    '62febf8fbfe067f47e7153b86e80421c00dca4116c0cdda15ed032067219b173ae85566c4029018a'
    'ec890d6be44bc19064433150f00000030000030007b4019fa86491ff000003000003000021be7bfa'
    'b47eddebc8b3d7a001317358f43d532e3427d7d6f2e92633fe5f34175010911cf50215a7863e21c3'
    '83bb66e1e639c8d08932e05b0060f035ef708954c548fe27685e453dc6cc96a00db241cb2e674eb3'
    'c63717108553e55ee6fe0133cc00000300000300037a419bad35082dad13298010cffe3840000003'
    '00000300000e1d69bdaff6e277450009a81dc47a237620e94055377a5bbb2ecf88cc9b6ca2bf9a37'
    '16999e4cf2aaa343eb2fe57247bce9f5d08d2bde2f6490c3cde2282e9c7eb6c00000030000030065'
    '41419fcb6594644c27ff0000030000030000ed2c4498acdda9d464fdcc2ffebdd2b850f29b58ef8a'
    '0c8e7099fc90bf4fa799fc5e52233483f921c27fa337655322fed131a9e4bd600b06dea600000300'
    '0003000e38019fea6d11ff000003000003000021a4809e5bede54aff299d805862b8e500e2f69ec6'
    '6107c7c1356cd322322346200976d760146034167a4000000300000878019fec6491ff0000030000'
    '03000021be7a31acbea065f24950ced201c67ac0815396fd12da0aace51bc9a614c77d06cf7ec4a8'
    '48103b27000003000003002861419bf135082dad93298010cffe3840000003000003000003000029'
    'fa4475e8000003000003000003003f21419e0f6594744c27ff0000030000030000ed2c4498acdda9'
    'd464fdcceabbdce092be34a70a5b77844e3477f83374866ed315a2f0f9487403048ed6f6e1c677cc'
    '009548c800000300000300007f81019e2e6d11ff000003000003000021a4809ec7744677ea7822e2'
    'e88d0cb3b0032116447d641377a02e78dece8a5800000300000300006cc0019e306491ff00000300'
    '0003000021be7a31be969c05f52b99e6c226cc24ec2690885306922c9cde0467dfede57026000003'
    '0000030002b6419a3535082dad93298010bffdf10000030000030000030000030066e813d5130000'
    '03000003000003003021419e536594744c27ff0000030000030000ed2c4498acdda9d464fdcc2ffe'
    'bdce0879e4146ea4cc818f4ea4c54c20022f78572cfce80cbe31037234438251bd64d3a52c059a00'
    '000300000300007f80019e726d11ff000003000003000021a4809e5a64cbd6e5123f1743648b5d80'
    '1965b2a8877d6d2101c23d467452c000000300000300037a019e746491ff000003000003000021be'
    '7a31abfa7022a43f9f8bbc136127613424429321b324e6f02a17f32de3fa50000003000003001d71'
    '419a7935082dad93298010bffdf1000003000003000003004d40444014cf99be753bef56ffc76706'
    '2b3995e92e054a00271bbbe5c15d3b959cf25f91a3000003000003000003000127419e976594744c'
    '27ff0000030000030000ed2c4498acdda9d464fdcceabbdce092be34a70a5b77844e3477f8337486'
    '6ed315a2f0f9400021883d6f6e1c677ce42bd0a180000003000003000a69019eb66d11ff00000300'
    '0003000021a4809ec7744677ea7822e2e88d0cb3b0032116447d6413835c053e78b964f500000300'
    '0003000007cd019eb86491ff000003000003000021be7a31be969c05f52b99e6c226cc24ec269088'
    '5306922c9d708092fbfdbcac6fc0000003000003004dc0419abc35082dad93298010bffdf1000003'
    '000003000003024df3a00019c5d7b8da3ea5f095d021d7fffeff08f022215654b68aed1d8e653c5f'
    '0fdaa940e2977d78980440a885d8a4ddfd6b9ae17e16268cbb4478191b76d67e44ee1fa69217086b'
    '6b31f1251f7320c2dea5d3b17c061573b784fabba5075bef288d376c16e418852ab01a2f07f7d62d'
    '8e31e0e1142b1400a3ae679f917be5725ea3f333943a19af66280bbc56e7e9cc3a59b9f60fb22799'
    '89cfb0a01918961606024ffa20337c91ad53e2e24359bdbea984213d4792e5ec86013b765bb03a38'
    '951b0d5f8228979d1095783c78aae27ecc2f16458c27b478109000000ccc2f23418b361f2c3b5401'
    '16711ce460c56a957130bbe2b4e60230cb8b4029d78d5fd14ad5f989099bd1ae37d78d406e207d1d'
    '5a18b478fd47fc59acc06231ae306f5089e1cb1cf6bf19c88ad9a430d2a5a65bc6704839ad9a3f02'
    'f44ccb92e86ebf449b8f1d0a1031105c7809caeaf8eb27b850679b9284aa85ca2180a4659d880000'
    '0300000ca9',
  ),
  <int>[
    178,
    212,
    86,
    134,
    94,
    74,
    69,
    109,
    313,
    118,
    368,
    118,
    93,
    92,
    449,
    129,
    106,
    120,
    99,
    84,
    64,
    64,
    43,
    78,
    56,
    56,
    44,
    79,
    55,
    56,
    73,
    77,
    56,
    57,
    382,
  ],
);

final Uint8List _au91 = _hex(
  '419eda6594744c23ff00000300000300012d1ec1740810bdfa0892dcf02ec6740c934e3a2504c2a890'
  '2ee14041760f4eeb49b19887454116cc8f4573862ebba6cbbb6860bbca6613357cd7dc9ec04b176e4'
  '267dc6bdc46da9231223cdee2da947f7dd4abf516c2a30152b2c5e030d3abaab7a2261aec019dffc9'
  'c700000300000300003ae0',
);

final Uint8List _au123 = _hex(
  '419e5b6594645c27ff0000030000030000ed2d289bbb7bfa8575e14f4872d7583618024bf2132a733'
  '5d9e21b7380aa0b002d0b6362d5ead6f19e8e24d424d5533b1345d55754559dd2aaea8df1dd9d728'
  '9a873782890af961afb709f2f2a91a2fa15b85c9bc7fc0d9649ace792c942acbc130281c442224000'
  '00030000030366',
);

final List<Uint8List> _au92To122Nals = _splitNalBlob(
  _hex(
    '019efb6491ff000003000003000021c5683efef80d1372d092d25dcf61a90b4b4990f3e427d37506'
    '31f06b7abd7a3ec745c5fdf626c184d7a2587e87c5240d6fc0abc1ed36713fcc15704c35c9cc780e'
    'f2fc2df9340264fb30000003000003000e99419aff35082dad93298010affde10000030000030000'
    '03039dcab54011d20a04151d7bf8e2b80d2215ed916f229f541affbb4f0a6340debcb3df94c75c2a'
    'de8d20b166e89dd7ec6ccc637ceb2d6e7de65e2d9cdcdadbe211510b0aeed5c62d70acc4627bc829'
    '01e926d3d02a91ebfe7eeec40687d097308d6b905c09e803c4eedb3fb001188a02986c849fd835fc'
    '0299f342f6b979bd7b0d9b43cb42fa2cf1f61f366d596c685d23624740b2b84f605ed70539d251b7'
    '5d797d16bf0310b6820b68dc303adcdf20f2a254933762c48b4277ef5cef04a5b6f0b3b8445888ce'
    'c17f3430c244dd549b34aae3979c33d0f8251bf580004de462edbb6e7e038f02cdeb68db05f07d5b'
    '2e4a31a17bb3e71b64520497bc9d66e0a1327e22aadb58e34ff86561451916c46d2a9df81fccb75d'
    '1c478e858b9aec1f4658ab914a7db116511a565b7f6cfd1bc2870c06ef66f1c5731d769fbf612f42'
    'afdb07bb33bad0b58ecf4bab8470083c6878eec1091207d7d12435b48e99d917ca19504c50bb3e6f'
    'ec85bdf5bb07c43971533379bf14cfa7a6dba737e9631f4fe42e9f523ab991d03b24983013d7f34b'
    '48856cb3f8931f9ee922000c2fca5b84769122cfc2bda05b9eecbc517bd430b039b86e31039540b6'
    '8e93c3d1b5366a845c1bf88ce79b0945305003d3dcb72614ba03d28d3d0ca76f8e1548c71dba139b'
    '2e6f6e5b27188a97e7c60a50d766e1be53ab9392021324c0f713be9b7a3e084350fb8fe777ce6c4d'
    'b2cfe535cd5b21f430ee9691207f3d72269eff5fef8e4b354ba2ff7fc9f285880fea1c6e0965a59d'
    '3c4dbc7c37b199ca2a955ab23b19d91141808de000b24ec3f1c09f90ee13d5100f610041b86cfe6b'
    'd46d7c0989d579bd0fc98000000300000c59419f1d6594744c23ff00000300000300012d1ec1732e'
    '7f63d2227756422aa4335c32c73fc4cbfe1366e7074961fde334b707dc26d537e725a533d832e510'
    '265cb1b3b5ae048dda78b377cb5a09253e4fa98664f236f090de8b64214f05468de8a382441efdd3'
    'ab1741cebcbaa9a50c2ee6204d7d85f7df572b62973374248ade7f948687b32220b18f5e4cb6987b'
    '9a20e00f59e318d960000003000003024e019f3e6491ff000003000003000006e7956586e286bbca'
    '670114724c2e73fe3337b87fdd1a799fb59142dc1b1caf22188a7ec1923479571c7400d9b8ca66fe'
    '37ff4b5eba53e5208643cac74407e15df117bc9fe08eb43220ccbb49091a1bc6607cb03db155b2a4'
    '8521f7adf4820000030000030011b0419b2135082dad93298028d857fffde1000003000003000003'
    '03c9be39011713d86e23666920da568a25c8f836294e4d0677ac27dff7efb78a635d59cd85193fff'
    'f9259f1925454543eae1d662b703dc93b22ab2fd3fe21588e52e3c57db288aeba304701ace96811a'
    'c24705767c9085ecba7627e091463119d0f6b3338bc907a3a9b2f7c2e67e3df2255a249446ec9c93'
    'ece58592a57822b7811691627721edfea3a6ad5239fc80ecd35097296d1c99730bd95a71c1ef4126'
    '8ea61eccef838e7c3daf32dc90c60080ce3b6a8dd353fba87ad23122491fb899589198cc25158da9'
    '888fc763e55ba2a242701b99974b3190ddf9dc0a7a45ec80cd1a3bda8f0c8a6795d2f135a98a814f'
    '4b378e3c7d496f6d2922f3b41d7cf2777d99464907bb06328aeefcbe01cc1294742fe0fdc75e5cb7'
    '791cc539fdd34731415305f8727be4f4970f429bafd84585cfc2a1d3dc1cf13b8ed0112e50059e60'
    '0a699850f46a3456e4bbbdd2ee3c74bc85272ff2093686861c3ee516a72c073fb1b34401cf51b35d'
    '743028e45f993ad666bd5c6540616529146cf55450b27f9d9f4ca9a642c18a6950d6d76b5191220e'
    '440e80f24e15104e9964cc5e4a7f4886df5102ee6c85b634cbf40c2e36d5cdcd31f75b8b7b377637'
    '251248d3e3d639e8d09f0e3d6227f5596c6c76172bd1ba6546d7404887d54621f920f8d6698b0f95'
    '4129c135cfc97ef5dc0541e9c92b759d28c5b12104f4c24eb761b9ef51c3fc2e4611747536db0ea1'
    '8f59d0f3f38d29edd74a807fc6b9452653440378b65b3dbb730233666cf61f586f87273565d12083'
    '1b7c04a66a0ab6949b28fbc13fe420ebbfde230fe469244d9d7083fed1733fce5af7af3d88f894ee'
    'b45027b6be86c915303c3a2df328f009f8d1bab788f71f6a17dfacbc4483c0981c6869897eb237fa'
    '0000030000030181019f406491ff00000300000300017d472818afd990b9e4546063d21de93f05d8'
    '10711b5d98ecf8790b7bd84f4dd3bbb937fb01c5c383cc720b8f46e7300fb2d80d33c478e7ac9f58'
    'bc29197bdb6589d8abab4d22d4a6e7b46a2474b3e53b39da25f38c084becbdb06421f7f9df1f0000'
    '03000003000316419b423c214b6a4ca60042bffde100000300000300000303367b8000338765dd13'
    '75bd50594cf1819aa53b9f6066aec1c51cbffae3000ceb6d711efba86e8b0323c0f81216719a05e2'
    '09b7a440588c6b2604e17a0e8668c0b6dec8c9d5846c268c18071896b6643438cffacbf3c6b5853e'
    '416228953ce79e73f3792cc58373827749081baa09d4c986b2ab1c10fc37fe3eac248c15c23ec4a4'
    '2b3fe70a3b2141e207b663edbdc691bf0cc15bb16cc464d5c2a673ec70b72c462f741078db06a3a3'
    '26fa1e7181c57862416065a2ca54ef2636c0f57aa6393e832c76c8000d2226664de61cd059ed6ef8'
    '17bab1a27c3a1e50d047183840f703e69712de021dee01956acd3752765bf6bdc04b232316e52048'
    '0fe67303ffedbed05f9df9b236f3150e6c998d9e5c63100138a5617ec7644c5dbfaa877748ae4779'
    'ce69d92ae2a7fa74e1656df604894315e5f58da8953afec6d787688e322f67ed345569ee02f28fa9'
    '3604c36be3840f9ec051a5e9ab8b119dec6d2dd4badac78992dac092437b8b89ba9d1e64596790f6'
    '832181bb1e99cc5cff559e71a26a065b74c2376644a066d209d7c2992cfc58933042439ee7cbb03c'
    '591a99d09ecf622376c879d3a47472e5d52f80fa2e45c8008a32ed646f38b02279e551fbb0777f48'
    '3a7c933981cea0401979590363ef2a7035cb1d6df070d318987d8519944c48f96f36a76f8eead3dc'
    '000003000003005b41419b634fe10e96d4994c00215ffde100000300000300000303dfb86401b8e8'
    'ff24a359966df88d6623a5532b68c8d3f41636b8916f229539c3272dccf26c0663d83cdfce06975b'
    'd9da153b84649e5873405aa02110742aa6179a59ed6203994a855a1374921a0e4fdd7ee81047747d'
    '37ff5eafe9337f32f3582d17ddd1577219e8b1e3c87bb69f95d206b08fb3f2437a885ee20021621d'
    '876e11c8cad29439affc50d570d5d010f9388ad07962883a6075cc8fd6cd416b1c45e0e6b5b62de1'
    'bba2f52258fa0735197c3cadf050706f80d7741da0b2e946f870a90f5c9f8981ccc602b82f340eba'
    'e1890995d96847f5a59ac75c9c1f116a852f9dddee178b41a9fb567430b25e5a72924b9c3dac5a93'
    '88736af16bebc0d7e27fa88ce44bd94480aefbb982f6b5893bb8d18e8001c371c30000bf1bb0fe22'
    'a09b9db4d6859fe2c0e85d8c8ae0bc5d2672f49b4fc223014b69499c35c0c2719b2c4ab7c9e6841c'
    'bc6885e270193455bf9148045c17edb762c671b48b03fc3c8b7a40b891a7b177cc2b49af6751bc39'
    'c4cc96b423b98077deab68d5f6a5d01393b7e7548e7ccc2ef330e60595ebe7df5bcd4863edd30e05'
    'a3ac1541d2577e03df1fc2f72b9f6deca2845837e7f2579e9c97f9eb7009185627a850a9d8f7f426'
    '9d36a5a427cba098b9a27fe041d01b76fc445e24c2516b544b5ee1ea1c5cfa0c6a1e1b1b8b44f5ad'
    '5de31ee98e35a1fdbed4531797d7517fe0b6ef2e48fd161d6c4308805e3fd6b577c139cefc70c770'
    '73445763392867a5e6bbcb2b2dc3c52e18df1c621cfca306c672a80e11f2fed55e0fc8b837d7fe4d'
    '7cf6f432707330ed92b2fd3b9da4f0724b02d682ad0264d12ee13c39ece220a43c3fd12f1b5286e0'
    'ac0301df46602b9000000300000978419b844fe10fa5a2653000857ffde100000300000300000303'
    'dfdde70006d9f25daf16be2c697f76df70743a02c27deea868c154159fb463cfa4ea0806a1f3c7ac'
    '9f006f0155f3f3e33e519c9814fd83d0e3c5e60fade369ba1b80c2a278f16222260d1a73fe84baf9'
    'f35017603bc27b6ce196da5716ee7feb57cb691b15aca5a11b6d7251fcd1acceb3696656cb24be6b'
    '6fa92f535dc2fc2cf5edfc7aee475c2eeaa360fac23cde29137e8bcb10034c44dbf9da8fcc28eaa2'
    '848e1ec1251f27b106cf54d1bd54cd00c8178603e4dda07897a8ef361186c3b18017380ebb8670fe'
    '9fae7ebd42dc873ddeaf6731f433d146679e60c20d8d97ee46424036e4b455cd1ff328677798c3b9'
    'af85ca3dd78189fb14c9255aad3cba5793b154fcf76f5307e501d733aa93967738e0ff55cd9b02e1'
    'e5a1841bdc941633e7e496c6ad44b202e848fc71ca0044fe1925c0f74771994b916bb6a43490468a'
    '9f485e4df1ae049dbd3819a2e4a1fe41b8a8e87fecd69dc978a0663b6af6d2d5a92b3dbee849375e'
    'b7bcb13f5b1f1e538a53dc03a4f995e26ff414c016ea3278fb945549552f403eb9bcdeaad8f43f47'
    'ba41e2631790511544f43fad0d2b7e3acfc001dbb9e8d4f887a2f2b1f5c6652fbb3324f96bbad589'
    'de3d6f220aec92a64ca968a8172896c7b87bff41984e4f0d3dd18bafcbcc9c0b2aaf39a2d320d5e8'
    'a0fcaa684340efbd8e1a6aa80c628573437af1886f07ea3799fbd65013c4af77101324da9233a334'
    '96a3013f9ad056e75fcc096214a57a7c99493d04aa6485502260201d6e7063bf62fe621b40a45c26'
    'f74d55f6212a4be7393f5bfaf38e5bb08fddc4caecc94abaa2ab2230a956a988ff0c8392e6234df6'
    '7ab7794791119b406b3f519ebbc31770d693e04099a2f6f52c8045ddaa910bb10498c219ab91f05e'
    '6c9f324e5814e9566a5c584d65d2913fc6159184a59a77cdce3ccbe85bb83e7ccda241ae678e86a0'
    'f8303146d1d3b4c9f2e773bc5c9bb0ae00a681407888f4b1933313fab124b9cac73ba2fa099508dc'
    '986fcdb93f246777d57281811b2d232c1a6c7af1e667572a00452b0cfef22567d4f1154003a0b04f'
    '7b306b27e9d783f163436a6852501be622c1bcdc207695ad18e2c5d4310fed3e335c1fe43d023e0e'
    '49046c18c1ff98c270f20443a8f55f288cf5cbca3c7cd0a0bc99d43caa63370dbd0ffd7506dc45a2'
    'abb856c68b68a8f2b8282ea501fbd37c4f08859b937c88ee7c3822d7b569645422a0e919d92b087a'
    'b6e3793a7d3dcef01e35c0a6c20713ef5b30ba3f29442b7eab537ffbdb22e51e8812ed0e332f6bc0'
    'b9175775d02a79899352c186a8614e7512ad67233abb2d3eada94ec20070af7e0000030000030000'
    '1a91419ba54fe10fe94994c00215fffde100000300000300001b1f70903ef94739e5fb82b5dcf6dc'
    '8da2fdd1bf22e996416c25232af6bbc39aef0d7d5e2dc7cd7929a7b429355bc8a00e11c5deb89769'
    '30a176603948cc03082b98d2bfbbac5a54024f21b1c7c028ac6399ce28d691e0f7dcb1c1d74e2bbe'
    '659a9861bc615ef7c2742ae732d62f0ad386aa4f73856d4849a0ae37cd242bd93dc0b6f1e9590aab'
    '5edba5e24c2454674d38c3d1b69127667feb2b7a3680b753b1622d3c008e0e50fbdb2f7c4c49ccee'
    '2276fd4e1a59d7d917af73ea178f5e47353cef59df8e7d39411c945f1e754b355d3f98e747e3415f'
    '05f70f3e0cada86074e298505ba70796d073f116c403f31df39679d6dac497c005655c7f512fd39e'
    '1390aca73cae6289fd45eaea4dff101ebb4959b52342963bf164f0cd1a88b7060448bb9810812a63'
    'a8a4000c97d8f00a7e59b44b3f51eafc7e87aa9eb9e0e71dda42a6ca588e2a1923aadb2c4f6b1a8c'
    '68a1f46377d18c0d848e3ce0279af917569611532c15c336b5f9701033c04987d4cda7c61e122599'
    '3391b5c5b761cbf49ab3fb0300586344463ad44b28a5c558a02a34bb88744190533b241b1de4e7be'
    '5cf22eb74622251e42d8c18f00ad7c2faa4162f5270e631b8e3cc7808c377d3430d6bdf8f9250c27'
    '40f8b20c8977e62dd51883bd6273799937fc5d78a6a0837f9ea541b8fb5d0320233146413de6ac80'
    '8a458d7d0f6892b599b8366b41971f3596c251be6ba521cdb1503f78dde0e6c259db0a8617f0e04b'
    '23cbe4708925255271676494c688f00aeef8a02ef53ac861d01ef75eb1b152d4ddfb737455975a45'
    'd88fea8a19f50dfae5f6c000000300000665419bc64fe10ffc994c00215ffde10000030000030000'
    '1c6f46ef725f91fd8bdc257ffcc519dbda2bc13a1654fb60433e9b3846d697e99fbc6bffd133c7cb'
    '41ce12162262477c127ddb4a8ccfefc4412576ab05e820238b07b549fa3d41122348630e44b3ff75'
    '362756b2a30df9b5b378902df0f74819db6390056e1dd203cc018dbf262a351e1a9ad020fb18ec4d'
    'edc91253e05c9e1d062ad59738fba6b3659b1e9663d3b6ba6f1e253aa04cb53d413f2080c58bbed9'
    '2d0934264e113c2ac64fdeb8116b1f06c27ee45e8b3882a1f120c11ea276fc50373234b59608d5d3'
    'ec47c0d8f2eacd4c84ad955aabc22f17b0c48d456d75df550480bf7f273c4ad7a7e7a99b47a7b815'
    '023ba3f9471c81019d9eaf2dd7dff1fb76f211b23806124455e0abcd9757f2109db8843489ece449'
    '60937f51bfc1e31adfcbdb86dafb66e6662557b54e11d2236feb0abd277b11d8f63eb4a1bb09bc93'
    'b0ba6e0639a47be7560152ce6f190e8984d24bd3c1295f61245ace026dcf32ffe046e3c5073ba36e'
    '291762fe70195ceedc4b7eb80ec657f7fa295539b42b1c55154772fa68a82ce51aa7628ed3e62fee'
    '3f78d7af3f3c5b0c6536a8b9a078cd7f5c97581c82d628b1ec4d3b84a480b3c76368d47a3fed2ac9'
    '15e268974e7a7ad9ecb545d07f728486f0f02669cf20069876a232884c2c5add6d3f2cf197b00347'
    '95ef2be02089d4184ab19eb7ec5a93cff652071c04c45c977f8c62a8e5ca304914c2cbb8f0a9dd77'
    '75d2446011794c0194ad8817b7d0f1b08acc53b0cf45ffb7dd1f1f170ad9eeb191e6c4bc115b348d'
    'ada1e7b9622519bd45a254e9e18209a44b1dc9886c8637f8fe4bf48ed30ec0d21f93b7464e1ada2a'
    '468959bf7b84a8c21bead38e8c79be3b923e9e03fd44d8d423a9666fbf74f36044cef0f9e3a7e86b'
    'ca3412353c679d430c48c93eec058b454ccda364e8f8958a0557016234cc6ade343488d328a41f50'
    'e695d4540170a0afb2b01f06c29feeeaa12953822c86aa04f6ee7e3c4470194d2fb5a841bb528517'
    '1110606cdbcd16587d51aedc479eb192232be0000003000032a1419be74fe10ffc994c00215ffde1'
    '00000300000300000303b3cab5400911f42e422adf812d70c9884a89d6346bd0720ef8b66dd982bf'
    'f09a7716274d8c8bd831490e37fa1f5509fa18cca887f893d72c8507ba649430c6c6b641fe59430f'
    'f4a5a470f820583fafb99da995cf415ffd2d875d018defd811fc51788f09b18fed20e8215e27cb58'
    '273654c79f77677653f3192e3035980b2b57677a8467cb046947cff41336feb43c7fcb8641caf96f'
    'c4d2f03576a6476452efeb884db403f92848844ca3aaa6d475addf98826ead29d5daebc89c17f21d'
    '65e31c020ffdcc09e463c2c6dfd43b8fef2d9b67a096d858ac8fb4a0009eb1ee205cd1e2821cc0a4'
    '0f4c3f33282663744795b8084c7824dd03f531b015ea1eddaaa4191a083c450deba18592ff6d7340'
    '335d13d67483ff1f85587ec1fbd9ca2190ceba810a5d7845269df0ef4fd765231c1d18a9d98a3358'
    'ebdbaba45ebb00778797f87f2eb92c398066df6ed398fee6d98e85851459a9f23b6d10cb890a106f'
    '99ff53f603414a28c680f25dfff49afbfd25333173ea4a35ad45946863df4afe79db8f46cd724053'
    '48f7e9143e737c32fa48871b7bf86b13d3ca868252de1ce684cc4600c14b1e1430612bbe7c4da76d'
    '1325e9ed5cc9c7e19d98635ba52777a95b7f2117e25b692f0164a5cb0e04412d2603a61b5d72c9f3'
    '6cec5f094271346e58c84c883bf6e1062fa6a869bca5448de03c3f426a20c0ee053dfcbc362162ed'
    '824f1d9990472f8f45fbcd2c687275da3d26e7234d86d860b004f45c9ace190765f12a656bc71f4c'
    '40a8c3b4707b31166e99bdeb04eaa5ad3b19984eeb9b4dd35402e6da5b05422da34cad2cea3fcb8a'
    '5b2806f33344a498640714b909ce58c5a2e425137adc6d30a9d1bba21c7e0d0123df81532b3380ca'
    '2934adeac39ca1ad493e90b74776c142333de3a1be9b719181aa560efc10734a27a9815bfa711c83'
    '1c3b8c49cffcedb58767cb330b241f2f8b5398870a9e9006f0580e8cc8634afe13f30ca65ddbbc18'
    '36dbb1d6add76d1e818a00f760bf09397c0000030000030008f9419a084fe10ffc994c00215ffde1'
    '00000300000300000303dfb86401c401b1e1c0d60f7fb22863ec79652c46b7fd46fe97fa51fcafec'
    'c6f5c6516f492716841a79f957d3beea07f768cd7892ed51f9f1c989eb87ab30042cd4df50d0af4e'
    '0d9422cab25c313d794f603e86329b52abf4614f0658df6dd743230c7faef4819cfd4e9924dafa33'
    'ad829ccd68f5e3f7d5bdca74d12f167ffc22441c9fd98682808a158abac02d74a67e52343a6574f2'
    'f3a62d8b1c1357e6213e32ec9d73956d266844df19c73264a42f31fe8623abf6fbe0b882d029ca2d'
    '1ac4534b8b5db67f557d5c2d82e2fcf8698f08d9174317a33a112662a28b97f30d8ea512d355ce8d'
    'f83e820dadd45a72177f4c28f864a8b16ccbf15d6b2c1a4f72e9027c6b783a6cb187376e1aac70c2'
    'a4fcdfe080224585a1a5561b8a2b18af8185fbd47aae13a1c60f8fb04e6cc5212048580393c9d850'
    '24faaad3896d2cec672839255c5f7071abab53b94f275d5067b48a94e4bb9777c333188ca888d0ba'
    '8188345f6111e453189940c9c54b877b896f7b5bfcb577ef382113822ec5ebf0de635400329d7224'
    '1ac13b2247c7f6380314cc05249b42277a9c21c5036b169831947883770c7d7dc68f184cd3b247ca'
    'c6462cd57bd9d33c2c1dea69e9e82a70871091d3211195d9c86917ee02f85d75d2e44fcdd1b42d61'
    '66e4f77220279abfbc5cc7d2fa1d6b7cdc2187a4aba49e2f48018c5f704538f725ea472c9732675f'
    '5c1bc23e9e57cd8f07c5ce8d02f43d8e1067a0cb19dc3fdf354dab911a973527a8c981db88252993'
    'c9e8c0dc84362c2b949934ba76091be334264f58820d60d2e326845a54f6075f0d6f18fde1345a54'
    '8c89d9fcf26fc73cf9e3b6d71006601710d4bc3e5c0b7dc0ac09f3826fec6be161d9b43217f3618b'
    '7173e19c8118baf37b6426224131b1eff141bb8c00f9dd78d0a43b16c3d55951434898c728a9fd64'
    '052b76d6b13dded0307abc382fc92995312924d388380d5a6871c267a2895034a69a76215c85f71f'
    'b308a37b6649b5ad4abee3d404ec5bcea2271d66d8a7a6af8f2770c1d13da4819191cbe522548bcd'
    '7589d79b0902ade32ffc50f0a35c6e8246d3549b368e57cb8b7d19fc71aecb36bdfe82778b2d001f'
    'a36cdbeba7f43c9b3192b11f23bf53f2b98202e51e3f4c39be8ad01bac4756650ab2216640000003'
    '0004bc419a294fe10ffc994c00215ffde100000300000300000303dfc0f880394becfd30e82ce6be'
    'bf53d4b5d2bfe6e0055f644b6cce65766c3676674dbfcf9b95b914208431ffe88d16a3a0b628db56'
    '008561daad26f268cd42c1606325a361c14a6b7cf956e45dc8895c469bf962534a924ecb2cc3a4a2'
    '2b3295041e898c0edd5eab006e5723bb7f619d804a99e2c92fb6dc8d5463bcfe39365b0ca74068da'
    '6d3631758d1c5d1adfc15c8944edac2d7fcdcfa9cb1ac9d53cf92ba8a5e6f837af4e2ff911813a94'
    '32cd6a3768bf34ee08de282d8f86d964fa981266f6c1c746c07ba273979bc03fb31329080a8ba09c'
    '5bb25c18f62c24cc28b6ec22241c099b2d56a7126a56a639780683f1d45e4e9b2dd88f7d547c8cd8'
    '47a8677e8566497b4eca06a520013434d0a29cb8a5a4ed0c630b401cb04aad6a2d624cdd0601762e'
    'fa788fb69d27d3bddf535fef51fcb935c15fabffc90bf4418430d4cdfb9e8ab3d6735c202558fa56'
    'c000c64ec517367e77052a381650e892b497be31c635151fb966be3dc031999d32233c56a3c58338'
    '7aea8811c071c07d5d4939535a63bb667dcb703b8df118fa53015cb74487c60e462ba8e300c5607b'
    'b31b6a1270ec749c64f4f3c2deec9c66ced49847bc9ae79cf1e06fe00d6506bfb5fda048e5124706'
    '1158d7fbe1a0cf2957f4b9cdd34c8a5576a7be6bbfd69771f2732fa538f34034e235ed7522996b11'
    'b900c7d89ceaff63b508a76be676a8c5a3af22f894c13f0e93bb6776a021413b679cfcc2b3e45a15'
    '0d482b8e25eee3f0eaa670cdd27fa9c7ce66848f83486b6c6a78b8b4ebeabd806be05defe77d724c'
    'f6d61fb61091246990142525d3b1838187239c054bdd68ca48dd3900a253c752502883d27bc9120b'
    '31c52eeb621e80d275f733496c0b8d08b576a074f7ecb16102b5535927956ccf762dcbb02a68e931'
    '7a4761605831f8c5fc1e8b4bdf383b44cbfe4000000300000cf8419a4a4fe10ffc994c00215ffde1'
    '00000300000300000303f5be3901c07a094cf2ad220d7a2e5924d129655b0b141cab5f64c45c2706'
    'c0306b6378f922c333e845be94aa22ef1eace048b359a3afa9c0c385af82b8ca6f3ef9f3bf62ec6f'
    '07a7e792ec6c34b9702f37af2d841a9682f41784df74c7c63768cf8916439671c3d6c94399aa8b57'
    '49e66d7d5f77b1d6a60bf74c30d4726ac1070e72fd5960fe8afad6037cdf96c278c434f8fa7f8635'
    '2318bb731ea6a40bc5161b80c0ce4a2cdfd347ae958d327a4d2ede77ee30840c338d7d542a53cb02'
    '0ac75ae1bcfeaa063c98ef80917f7ea1cf8d64d86ed87eb8e1b48d1dc0406d87a59cadf479c0f6e7'
    '0f702a8cbbe3ece65546d62ada989e6f6a4753ee4545b065b50b701dc103676c6419460a6f279354'
    'd821a0ebc023253e8d667c0a71436f5a2c09de06fad4eab28ca78757b148b09af829522001128d4b'
    '187cfcb9bafa54d73adaf9069e7d3f5981d38a15395b1df830a1f6ee45fdf1869256110587a54523'
    '5c7e6802cc4d69bb724f17547680e47fdf18674228f8d1b9f3c0f88d101ab07a367e519a498f1de3'
    '0307d2106ee78afc5b9d48a6a969430f290fabc710fcb4ff8ec53c769864da5212b61b330a37f100'
    'c299f73dd2e159c474e39a15eefc1d1cea5fd1b02a2d077d01ffe6206e858965d4aa84bf9de1b484'
    '9f7adb0ebd212d17fd918ec27b20b6865a4f399fa9a2d98e8b797eb0812db72efa34c52d3ad190cc'
    '03a34d44aee2a777b143073971c0885e04591c2534c0dfbe20660730d22c6f523e0f49e883411edb'
    '7981e9250caf1e5796ff9afd1e542f4d18936db439bcbc1241a6a174ac969972f3baa3da0b1d03e5'
    '9ef8b2adb65af2351972881bc6605cb32b71df452f545c604a421606005713dc807ce581fff17173'
    '8b1581ff943ff569bb36f59eb8fb14eadfe9ca81ee2431c77c61a990f4bdf34a526d5a39cb521f6f'
    '2130e8d14844ffff9c8ebaaf9aab935dff6dff576eee5c3204e75ae02fb7268187e248725720033b'
    'ece2f63a9a5b8151f662e12801763f4467542cf95fec2e04f39451e801d6e3e6e38525a56136a927'
    '95e1574f55a453c94098a43218ea4e6ab3b6fd0c200dd42bfe826515b9864798f9492361a24d09a3'
    '36e284a1c51c2a854d23a1f6d60435cb2833fecdd2a0db60dd612d0d4320ff7a3f5b5746bc057ed4'
    '3e6e1a637ac3f4c80adac0d6244416f4ad2335d4594ddf7a2d919ef1eb4ec1c5c8468fdcb1398dd2'
    'e76998cbec5f13735ebfac3b9e2689f65a441bdabaff167373b9abb6c2ece5cb10e9a0addae5318c'
    '7f1ecc1a7765bcf26e782eba896452befe2bcd0e19b2000003000003007541419a6b4fe10ffc994c'
    '00215ffde100000300000300000303dfc13d40160625a9acfe682e4dfaee6a3b72f5a5ab9dc8dbf6'
    '48b227adf976ea846adea96a60ba3b05623ed7ce61e710b4890fd212555ec1d29f3f6fec7ed57223'
    'c1a57db18589d1c3c5d861ccb701a47fce99d4a0da544a28a6b6db4d278578922e386dbe79f95789'
    '7e395c35aa0ee52a0172939a7a4eae51b7fb66c902394b4807cd8347830b46cb96d9003a7b5c80f1'
    '075701899c7f21db55c427f099558dc0e77fb0ef5bcf69c032a5e0e3c2dd2de9d7abbe8e1c10844a'
    'e41b9c2f696cfff0341833b41ec0acc93cc12c852cbdf5ee009b9124731928bd9111606a56df1dfe'
    'd6a25b350e15b1c7d2e2869048ac8a25234a3d8bbdff5a78ccefaef4ba8b51d51ee538dd5b8af642'
    '8a60294d0463cca84b59dff73ba4177a970bd66f86579d967185decc9ca803190639ffa1446f2dc4'
    'faa0f79a27c0c71a6fc88bdcb83ed75d1f08a6aff4ab06db9ca56b8d06788ad0104f12fc28667582'
    'a8064be63bad1a1f5950021c688a7b65a08396d9adfcdaaca477f565ccf06389224417d58720324c'
    'c01c0baccddf104bfdca061999a5232935687afc8dd4b0507d33c770e97be0e75472cf1652c3895e'
    '75290fd7d6ee8290bfd2fc8c6819d7d7e0e2f64812e6667d2102a651a0482bc4fa7b2e4aef205c3b'
    'bf897249488ece63bbb391f130de44fae5486bf47140967adde3ffa9d1ba5300f24e87062e1cd736'
    '4ece98b0c2131e5f8134d0891abdc87011cf1aa17faaa5f002acbd2c6746cc168bb9ecd88785ecb1'
    'e4678d7c62b25e9f21426b689edf37ae9355eadf8d448f122ef26250f56df9b8ea79909111014eb0'
    '885578379eff37e89d10c71b3b1bb87e5516639f9c35df3b28902b6b3acd8abdc40a827c48ee393a'
    '39ca7be2f721262ca8ae35479f980bc4ade5cdef8334621cde06fadcafc8e4aed94388ae7f0fc4dc'
    'bd45fb72b5eb1fd60e0796cf6bf6a6ef83f1ab6d57fdf242463d20d79c71a88b39e47d54bd03b12a'
    '39cad6d06ac50b469a7697df158cd1b484f9c1649a317c605b25e30c9f735e92414403b1217bbb55'
    'c602e62c51c9dcfdc286e1593f3dd8b3129d64822e6b0797d713cc87ed60b465a5e568eefad44933'
    'b01dd1ead8b43e137a2a8c340144fd55b0cb2b4f15a26c26a00b4d41d656f474287cf412814111c1'
    '0db1b2d7b89efae000000300000524419a8c4fe10ffc994c00215ffde10000030000030000175f5b'
    '2a494d44019f6e202f26edd92d91e8a9ce655d5e2062769a1c38616bc92df6a5b3ea810f4d2fe18c'
    '91b77c0d5a88bf0eb0d9bcd3f36db46ad34756931c94dc4212f00821d192ab6aa1eebffba5f07eaa'
    '5f15c7109d3ea3e11228670ff990c4cc86c5393075f48028603757551a59dabe1663e07dc1d4f637'
    '43f21f9799efab34b6d9e1131ef71913742fdb8621b6479cae3d3d174f482ccbcab9d9e1e69c4ed3'
    '50808d90020ad7ed991cca28acc1d12df87b8a7a877ff9164cb308838df6fb77ce972f4e56f3b1ee'
    'b778a8cd80a112f8ee58de88ba2ce41d7f6bce83f3e229edd9325b8b3c1076b7512a5ae41efced64'
    '57dea6ade08837d247738421b12be605af89dc4b73afb90aba759562415d7b333dc2623287ed066e'
    'fb0aa8977eadc7d36aab63a701f24ab88f67ba08dd1781dd65429cbb721f54ca2e64d9b878b8d1ec'
    '6a427b4d7fc2eb77c471f4df51b0aa1bd44f079b938cee9c71afd0a7f85a74eba98baf96491b7f14'
    '8f7b89cf9f045c14b95dec7e36e42cba23f8e6d9b897b5ea4aaa6a57fd6afa35a51b820536c32e3e'
    'c4424853e8a32bf87ad135058111fe5a2b66856861f61c449283247468ce2f4f51638f6ba177657c'
    '903624b8d276396882f80815abb9ebb75c1cfb19a9ffad60422972acb9ef6abe4d7ac99ad95355e0'
    '13b6e7da75917b0c209073c9743c08bee8e2ba8f11784c489637eaf28ce438a4cc9e7de7ae9939c5'
    '083a2a4ae837b579bc2c491579dff6e37aa8879aca5bc9efcb4d2f3d1464c0f0877b8a7365702427'
    'c818bce5c71c036274e768a71e51dff50e7d40cc7140ca315ab54057ad995c4c3b4b0352698fd2af'
    'd872f70595588a4f9afa06ed556d83562c4f7606941a4b5c6d985552c7bd98c99d6482b4abd84ab3'
    '512b8b9b9c90d20d36370b9601f4afe146cdc3f4a4c8c97cf2a3acaab721cb2de12c8150739781ae'
    '2042e8b8131211dfb66de9d1a2cc1ab99d71ac044b93af641b845c80506ba38b16f60b6087ae0610'
    'f0a5daa24bb34789b9fece392624d15d11b33b2381995f26b0f21e880b28426cd70f407c8410626d'
    'fabb27e7cbbb07f3b7858cc65eb9a328d38414e7339f73fc064589cfed7014ee6354acfeac488d84'
    '87ec9b334c561792f75462ddc39794c32154d546f5b20b062761dc2746d29b04e3f12d99a17137ab'
    '8a8a4ec760896efd928c818b652aa0ac1161c6e761c414336e5f162286d7ce064d067b0720e88e63'
    '6241b8832e684fef7112098b67c04801bef41c41a82b5d743f9da5aba2be1b915f670dd9337243de'
    'a82ce606db82da181096fc4731ea7ea2de55b8dffa5145821fa14c6b9fbc1253c57375de236d2e5c'
    'e57887d859654148838850832d5c8a32ad41805a07471487d3628116811048000003000003019f41'
    '9aad4fe10ffc994c00215ffde1000003000003000016cf5b28e750b94e300952291aecd7ad1f0de2'
    '6c7471792e9dd64a6de5f12f274c29c79751c5f53dde5b17e69a228a7ed2cdfc87b55e8e553a8bb2'
    'ba5df6fc1f74da207731d7c0ed9db32fa278d76ef93d3704714c2087ba6471a300a7334b868652fa'
    '5038766894f374a241c290c8cf77689db4b7bf37338b4962807f4ac1f71c03a8f01925917de02d30'
    '5de5abf82196a37182a7ce80954be19cc9ade21fa0ad80550df586c2a4baafc3ee10f20534982480'
    'a4995d78d793090aa2fe325c2571b41af4e18ea1139c39fea670404ea5ebaef33f461c02cc764896'
    'a4ef9aa9b4f14ae5a02d280ab80cbec0ea710e9b303fe5d210a272c7ee7093445e9d3cc0a54546b2'
    'c36ea188c04be54003686a37a33641f485cc58d40e2ec499935dc3261e7538d7814820e13eee8d12'
    '02838e9c9d0cffe00bd1ed8b7ad9aa1b4948ff02bc18366ba069ace1930583de183d2fd4d20d915c'
    '77755caeb820772a6eae35a8c5050b94a8d91fb2784e6aa7a05cdb5025ff1635ed2797d9434a0914'
    '1dcdafc1a4b2f116d7a6ed3295b17230c8f3b92723c20165553d84407a364a6b600ee2327d7834d1'
    '19e7449ff3c3c9f8b6c008aa613d3c908694e1d19e2941b1734071e3fb1399fc461d9a90a66092de'
    '8f453b7133a53a77e55f36f95476484bad8bcf24b06f8f4cda7aab2a8bf81f117b50e486da413ffd'
    '7bcf068f07024da7d96bf2feaa141ea0cff0cb4df9cf5afef292a2e48c4a38029786e09bbea7127d'
    '1a71080aaa256cbffbcbfe2215079e91f36e9e033aec30021eeb995cc816af9b6b037f054274fb85'
    'df2ccacfc2420acfd2e56823b572b0149e53e70c84e3aa7d256e9897b40829ed211a378bd3748f83'
    'df90ace1ab7045555c4373e8958ea01bf853d398acad2c47090786feb61c19a12707837affef1cb3'
    '8d2eaf0a00000300000300ad81419ace4fe10ffc994c00215ffde100000300000300000303dfcab5'
    '4016409d8c501fc4ad34c59d189ce8b74a687d487f68ab8ff4555e14a7a53af0f612d0b130920c0a'
    'bb3a2bfa2c1e75b451d810c3ae14f1731a85350bd257c4a09371cbe2826df7f852a5bf5b6787a21b'
    '960aadceabf51f88f1ffe079bd62aabfdc108c5744cb002e6f5e75c370ba0655845b41b08bf27dbb'
    '4b6238368e5b16cc3a827b3a4169ccd250ad16a74f00c059f1e023d6e2d20a8768aef34a8b70a6b4'
    'e8512633457b8e62bee07f72d5f89ac10219039bb6bab92d7dbec1a06b2a9db0efc208d79bfd06b9'
    '512c56662fb7dc550701c68f4ccb8fe69494122b8ed2369f0c91ea8ae7b593d701978fb3a3f4bf1b'
    'd373b1187d29ed10e9b0791ebd731d54644d81515a49faf9d11c0b1f7f6b421ef53fa254e40c781b'
    '4e1c19e73f1a306adad318f933cc5cf5ec3490f253194993a1b2e107b12d79bc055f94c23336dd2c'
    'daa910a36398873370590e7df73e9cd05c9463417af0b61661efa6e2a6339901ee2b8eb3c8170dcf'
    '8b6b763ca466a2fcf5798bf730da89ced86efdfbb8e5b6cecfdee78673a81eccb754262d0e9a3db3'
    'b111ce1f0eb8f8f7349a497ba1743f06504971682aa105ee71943c7bfffcec0960ad96173fdc8f52'
    '8ce54954aecee2c0f7604ba18d5fe6f8c3d709a312489965e462b32d7b152c2449aa337a876d22a6'
    '97819772ddc31bf62c5d070b20b64254dad1301e769d8fb0c867d46fdf0d79f609a40c007fd1b841'
    '5945ddbd4284d4d75c01f125fd513706942070a98c81d1bfd783b4510bc82988451c55f7e2b46f28'
    'e3241fadc93513e271bcd0c2b7773392581c4b9f729e4b2020c2411aa0821b38bdaced133ff27801'
    '6be994d3fdaf08ad0dedbba8801cfa7b38c87c86c87c73059d8cc4a83e71d3fd17e3911199af04c7'
    '4126c4a4bb9ab227ed4192ad2ff4af99e88cd18f6409979f4e04f153a9987add94162da7051b1db7'
    '550e823dc87c115514b0abe673f06fb1eb81efe8d410b1de4aa5ccbb4e21665b91ffb0a9ca7127f7'
    '2583e9c851811899a37448e71dc4a77d5ffe38170b1601ca0bfabcfeb7620cceaa17190c82c0d341'
    '418a49a7107ee32991248a61331384a663035601e40e6d9104f2605aeec27fe7f19d8548aad6cafc'
    'dabb3865804749298751b7e4816a2f547581c591ef6e0816729389ef84ed309140333211d8db6168'
    '486794a5ca31803b1900000302026d68f9bed73189ac527dea7bf42a4db8b3ec5e38b3e302e52390'
    'e55d2a8525a593fe50a36247df937055040c145a50005b760ff4c6f9801cb528ae358348eb168ddf'
    'a07bcc31d6712c8b52e783dcd410a49277cea1a0b9ae5c9935e02d85485c57c841429be2ba168d4e'
    'b07554d47422882ca1c24433e96d8326d6f18a5a307ee52392eba63dfc5ba2e2157781301f366ef6'
    '4ef185484b60a892a31cb80d410702699191b2a2657bd575c84c10066006ac96f29c3ad39e19fc6f'
    '5dd2683bfb37d19b5e902069d039efbe9349f985b13e8e6636be135dd244283318c4f21c18783d03'
    'ec3c5c01e54cf1b1da35413746f69e37c3211b900272be18790c96b5336ab5a74c2fe71e5a37b0cf'
    'de17537a725642365f9641e8e15d2391ac37811264ef5669400800000300005b41419aef4fe10ffc'
    '994c00215ffde100000300000300000303e3481e4c00bc0f7253fc5b915a060ef346cce849099918'
    '1e0441553a0ebc3beb89c849bcfdaf70310a357259f27aa4b3f27b6805956d2fff5bbe1948a4f1d8'
    'f6371d64fbb6c25897ad56f94f6b063d3ac81b22851e6fbfd3ac59f1b247e8eafe246d17ef7aa334'
    '95cc1476730585123c4ed1be0e5a4429ad633415c359e4e6ec07f663a1c0138d8b0228b189e6d8db'
    '2cfa772d151e16577ed50c36386924e81850e6e62651c47876c7116433e3fa95bcdc8acdd636dfe4'
    '34ea0a8bf06f753da0b2916f812691315f81548131ae9eae97a8cfd27ca4d0717dd54176c70c7896'
    'bc90c779d9150122e05b8f888a48f3b4aabf0b339f84c7a994f5ea54244c6941e72ddb6248159d20'
    'dd8e02dbfeafd43d6e8b3cee440074efab794fa4d66d3e2a97f0793325a08c40edc135c45b014fe2'
    'd2637148d9d6e5adcc12b4fba92352e200a12b34b534a081d5c855e1f9a528ee96ee0eaa39023f9f'
    'b3139fe82deb949d6104477c969d582b421fc42c047295004f20d42f24a34630417a8c9f5a5317b8'
    'ba83b3dc557d284625ca6f9998a5d65e703a2d4499ce4640a44a5a7902377220ec38a0f4c0e77e46'
    'f3f8cbfd1e026b0b68ce3e5629d46bf6d8d4c421c92aaaf07720c2e1bc237b63dca8b549702439dc'
    'd680dfbfb19c71828d8892b0169132ada32083fdf99395db1fd0b328ef11bf02b63af1f8cd9d2545'
    'f86dc8c7ab73808034a430225be471130d9b35ca2afaea6755f1b6f5afcee6606a1c1e9f79d8926d'
    'c157dda1733b8deaa5ec92767d11b4d01ce156379b5629a2dfee6ac7dd002d23518d510f3bd707ac'
    '37d1e949f8c76f535c7d0a4de1a525efb316ef547063a1962951651dec08c81e2533e714c8e1a816'
    '0b326779672423a2742e3bfc8512f5e33d4ea1b65a5347c7c0a1ea1507f305f38335918a2106b762'
    '41f308df18de63066a09b7edfc7f89413d43b5d9218737df792b12fa79197bd934e7bb3d77a418b2'
    '934073c8ba2317a3ac264da7ace0c9538bd3c3a6b56ea3d5bb16e812af31bb46ee6071efac605203'
    'dfae66998361236aae0bbb55ef6286bbdd021578b46acf8105b6ec0786ba96aaf1578a6000e8ea80'
    '1c1003a84fcbd23b2fe2ff8ba98cdc8df62821e958c638d785e0198d36460569fc75a76e9d1feaac'
    '4a7d5bdddb39a0fd07fbcbd5f00a9015e7ae133b9a4df9b234de5612bd4cca29e835e53a58e51d6c'
    '2b512898dab0e4a46713a9c746347f9f84d64e1b2ad34f983c4593d3cf500d71147297c52d6aa1a0'
    '00000300000a09419b104fe10ffc994c00215ffde1000003000003000017fdffa556bc71cd6a3a00'
    'b734af6d64d9cccb62ed741d017e1215e47ddbf14f945f1a8815e42e3f1e5d62a2f6f4516b779c9f'
    '536f58339d209599761a8349f421b24391aa352065203dc369f488c378a5939e885ad2f4a1e0b820'
    'fbb1d82794700710d7e4d1ddccc5afb8a2b4119fe957989e3be6483863393cffaed8ae7845ba8cc1'
    'de696455d41d05a5046f7b36b9c534b578d302bfe5256408750f4838d3a5276818dd6e8fb148ece9'
    '94808c69fee488ccca9be4c1a890aedb5a7658accbc03967456de584dcef4fbcdc23ee4e83fe12d0'
    '074b113c6fdf32f840cf6a19900a618f26bc6a44c42a84194cf4cc91a42b1ca7777be07ef66a5770'
    'dc65fb397f955e3f38a8f258fa380064a555bc4afc408654a637698b17d66353ad0fee99dfcadadb'
    'bffaef1dfc23f57fb3aad03665d89f17779d5c4516edc9b19498944308e0f7a03d916c5d7feb5b4f'
    '2665b0a867af19e48eea0cc8104b3f685e0b53df2673035a8e061549c4ec3e15c72dc64a09f2bf8a'
    'f4b87e016d7aa6892af21b3fe444611bd2d22a0674fc419cebc159c0c3700cefc9c3cdd1c345f476'
    'ee6c1d2e15d517bf55ebb67b15ee19c8878ede7c33c4a51c176b0faa9f1b9c5034379d2b7b701dea'
    '09d00b91e155ed7ceb51c306489557e34b5d1033af4900245b2b601a82a1b166a96721ddc0ed77fa'
    'b82a401284abe607de724ba71a4677e2d2f1322116f97009c4ff1144c4ac41c024977b6ed8a0b31c'
    '4c9b5b7133574aff0ba3f60afe5d225f7d3e2b7d4601244304beea80346ab7e4ac6b5c11852fd7e0'
    'f467f60dc107e051859c35d58037add4f48f9fce55a0d2c7bf32ae897cb30f6d05c4ec66c6fed7ee'
    '537a06a466405164a2b576ad2098cf257d1fbd65615dc70f59b2b4138760b259ec17730f71608c69'
    '7f34e82d0291cecd5c04058deff3acc1902b926572f09a68b76983d14bbbee0e5731ae55ef7ddd6d'
    '14f826c1f08983d0e68268384797f403c23da6252025070fea15bc4ac1e6dfaa72f5eaef494f5c89'
    'b1edd66f03c2273b37cc9f96b75d12da1926d0813f77a9e1c93c75ba80bcdcadd18c6fc9507017f3'
    'efe8b42473f92f21d32a79765da90e2a4821f0677d59d9612efdd1b0336f75573974db22699fefa7'
    '77c51a1913762d4775116ad0e96a783ed3d663e800bc2490a4bc53677b3b8b4b19513fce470ca158'
    '59df6e11382c35842f8ba2a56ad98eb1d7c55c0b88195ab72d1c0e585c9e3f865a8ceb8d30b3b5ba'
    'ceed6e9a3a3e8c6f87b1befa5a4dbe478ed98f6d08940e21d6c6df91e0b5023d17d7a9891897829a'
    '6a058398c4b7ea4832168ab954cfce911362e34c14dcbbe5559d006653d6957ce56c28e9a220ac39'
    'c5f8a3b27572c32ec882a87fe91c594d1826530736e9257354ac353a537c69682403853d83a1fbc4'
    '77fcd0050d68e0fad8cd5480ff5dc5fac6f77bb488f23e36c76b677e7543be26b4e528a399443189'
    '31e5e9db21acee8aba4be322c805f87a5ad839feab50dca7873cf5bf0497201e16d800000300005b'
    '40419b314fe10ffc994c00215ffde10000030000030000189f70a1579353bd2d6f04e97f3ffcacc3'
    '5276c599ef82fc050ec3c9dd467058b277061a6f51f56da771eb7a64bff49bc2eefb91121efb68e0'
    '54a4154dbb8b834a80e01fe15ff927059575b99f08b143bdd25aa6c8a2e212f7742f68a5acdd8796'
    '8d06c66b98ec78736e8272e1b412e4edb57ed8fc64a0f12b631cd6387697ccec919388d6b341fc9b'
    'd2b142e166c5b8f6afc1cf291db97d641f6041a71f7621ba02470d4f2b98b58c3efc3ba31419ea9f'
    '2e19605b2cc7f8a4d84a6a21c076f9a99524644234131f87b64c7ba534ca94dd42cda398a4bbd9ff'
    'dff67c734f26910509a0b7b3280eb3a23c41eade94fc3e87bd0a23739638d59a99bbcdaed07694d8'
    'e944b0f30c28c17ed975706e46f2a86bf1dd382ce1e0e1f05cb71414c00c6dbbc84005d9a8434f58'
    '8920dddf683e6d042c72176ed1b1a35848886a992a791bb636f8ee3b623848652971c0788dcdabba'
    'ac46f7c9c7669952ca30b6ed17cbe109c2cc1fdad68584d238fa3c174d548d4e05b2e11d05e1dac7'
    '03c750e3d8ef0bf884884a7bc7468a916bdfed0430f5fca83f4bf2847d18b04a27195db6ab7486b2'
    '02af52c1727ec1a307f7ec1713c85a02c34ca4a735f36bf0fc2234af3f4370eb90448aec13b68198'
    '074a91f13552fffaddae01a98edcf1a25fa8d8628eddf70ea9dea54ee06afd8b32f1ce17293f1286'
    'c6fdbf98bc3e154d38c93a94efd3fca0b74582fc2be2009345224ded5b4f3011dcf74c281d0a4359'
    'ac19fdad266187a3807fbb303a9a7cf2629f7c6cec269f1e4d84d891f2500031d5343770eb3100e7'
    'd03e23333af3ec15654ad9d36d4e4bc40b1c7ca75b8d503c369013c63c9a8f5835958714584535bd'
    'c733cc840a5e98c298f22210848d15d40c0a4c57f814050d63bb67a28d0ff8817f3f9af86ce030e6'
    '12860e4bce8b061b9c332c2f028f69651bf81004978b06417e06c08b5792ce68874ae91248158043'
    '0d9cfea8e2e225307ac4cce8b919330f35c22e2abfff2e908c50206b919a00d4d42c5ee38038c855'
    '4f324550bd3f11d284a03a5d0ff4c37b07754180daf96a5e3dd5398204280a2ef22966060346ea2a'
    'd291cea9abf7d0cb0d9761ba8bce6c17291f58f1ec61f8896f9c79140cbfb61027f798cc22eca3d2'
    '8d1f25f10da80ef2d5fd7bf8415747346440e473a677de5821183a4d5e4bf4d82449137653699513'
    '7fd6f0f6e4f09a020cb8b0a78cdc47ecc75f204515a3974e78c60132d877369e92c75767c8ec3fd3'
    '6ed33a0c4e29ebdb82c85be7d13058e9340a211bddcbedd991c77daba59712fd7a9b7de0eb6323a4'
    'd973389c3fc86364000583e3e79a062005464de6f492f01efa09af395b55d57630bd32c2059b67f3'
    '8c1b7863f8a91f4d935afad2fd6f52e075840bd9e62c770310a2faa446be923948b47cd598e8e63f'
    'c401ef2a0e2ca68e3ae377f391e11f4756e23808ca7a3f522b12b0346cafa083a042cac6dffcf0f5'
    'c8b16cead5b1cbb2bbbbb4932fc4f3a67492079e5822d4143017fda4a127a8b550461251edc72e16'
    '5ee19308b996397be5ef829cb8a295e46dae8a55a569e36b983109aba6d95e8556e8e88c65b538ae'
    'ef40000003000003000352419b524fe10ffc994c00215ffde10000030000030000193f46217104a4'
    'c17c6d80fa2b4499c0a40721cf42aab2b7240c7676407dda830726ffb579a8730323aac8f8cbc3a7'
    'a13b58e5f0a759fda294d6ebbc48b12715bb9a1aef3b7120da8ec63ddaca2a13a4ce78a3361a5694'
    'fca7b28dfea284f47c91431fdda28ba731573a424f22006d73c834ff36ab3f8ea9af8f46a687e78e'
    '205c5908157b135764223201612afe6719cb96719ded920ee7f08405dacd0c1790ae438e53075875'
    '6bda7a12e93fc3ba0e0ae226f6bb8c1030850eb83fecf79dcab1e04da5900f86d80f8cccb7357eb4'
    '6a4849a00a60cc052f0ccd58ea4c47b9debe196dfaf1f8597c3ca1c4a2df4e51bf03b8dae23518c5'
    'b338df99e56367397be9010206f076ad1791dc5bfac1443c27b3c2ef911bb19b938e38fa1f85013a'
    'f51a2dd40f7acd474574ff261074b705201e36df3746c38739c3c4efee41946c2afb286678f09231'
    'e27963bd0abf451b393e7d677a722db767efaf996cb2b6240ac0132dd79b69d41a75f07da6c6f897'
    '2135a969427067af6a96a26f5bea98d72e69015f11387e367184e816d40158d7dba2fcfe91ef92ca'
    'fb23f2f109770d6982251510bfd2de41523597cc5b1a32223d8edcc3f54063d860ac88cd95900203'
    '84722609452e10b14321297125d7aa930a9afebeede12945555557e8f51f382fdd1ed41b18d2a315'
    '1dcdbe7154ee31bd6d17e58edacda96fa187f4abba4bc20a2477192abeaca6c3947319a02db8f60f'
    'b5151e72f545b2849b1eb89f8d47c6dcdfe3cf1a0bcd49a2d0a23b58210224c7fb6555c5ef9d6cfd'
    'cf160a44809a129897ac247a263bd48595a0ee82c6bba3d55b8d0218db5c45d2101a4023913df0dd'
    '356769a2f290639f8612daeefe05509c7273307cde7d6f3b0b7280302e6e89e9b59fe6d62419bc7c'
    '2246290b72ac010fa4fe9cd40ec2a28c5740e4d11ed5c0985861cdd363d6428122fb1bb02e463680'
    'd485132546b8193c59e169b7b019e36734cb731cc4a86c0c47032221f50778edf2d36cd9745cfbcd'
    '0aa7d0a852ff14ae409c675b7d41ae3456768b7b3c711daba242b4ecb6bb25d2274e6c13537daf4a'
    'e1a286051713ef0722c2881e0ceed69f32033052f484f9467d69b91f3da4cd3145a337ce85f2dc38'
    'd654880691c08387127daf29ab74d17dc99fbb880c37bf3059e2474ef1b6e87630597f85ca73949f'
    'b41d2644f330401f49f7bb4e26a95db50466cbda15e9b88a13096c1416b9fcd41135bde06f327f5e'
    '67d603689b4000000300011f419b734fe10ffc994c00215ffde10000030000030000175f5b222ccf'
    'a19a0466028e01745ccfb10d9cda975b013b5c21ec49a2f33263300b80b8189bdee1e68fe09ff33c'
    'dc6af50307c037a9106b6017764b9aa2682963a859570572a6b311751a456a67a12891840a48b8ed'
    'a8a330d42d86197a7dcdbf1af1e1a0ff692998cc0abed15e2d2f7b576e117c2dcb36953b6936e37f'
    '5f9840513df006925cb8994f58d197241e056435f4b2f4569bb9f495878686321c7b39afe3e9e69a'
    '4196a192ece7684262aab7a7c8569fd36f24e6dafe0a97685821367fccea7cdbec484e7974b4e083'
    '785ddf8f46635bb19bcd70cf35f66d64477fd6ca84fcb12026b712de4c51f6d5c47bbe809d083cf6'
    'df105e4765100a9681bf13ff5df85f19b43f4622cfd497419f5cee4e05091c77cf7c1e41a1fce51d'
    'a322dd6a1acb600bdc1cbcf167dfba35b5a9a0d31814a99bc1a6c5e42360fd9b313e3670c3de4c19'
    'a3be9fb5bd88af35ffcb18d49c5a779498c5676b1b888203ced6a74198cd110236cc5726925c7b6f'
    'd19ad8ff405e164872d8094e996851c67dae1308f8bb364a377ec8464ec449d2db71fca4b8e8820f'
    '23ee0d92fd7f6ed4816d2b8862418d7c39f0d8ec00f98a594ebb5d21dbec478f3a84ba9ede14250c'
    '0563ade120aff0624ad1e584fbe3e9522edc1e11528e7f786fa80ee74d5f03849a8143c37bb78ee6'
    'd890e79e507b5cf3dd5cff690c04aa2ec97529689435ece5b8ce19ae7a8df588dd3ec9eae8603a6b'
    'c8f889ece394ec0ecc6bbf978ec842a30ade2e9bed763f76e3eaf155ffbc45c60591793b831e28de'
    '3dd1ce23b17bd68e4a543668a4b8b3e4fb5739a971182d367358e78537f99a4b7e12aba2e766a4b1'
    'f11169abc7d74a2f827835a53b0b3f6097c4152f2a70a32ef955d5fc538e1a53695696a2d1583bc4'
    '13238b603507cc2b2da0b11d5b7c470844d2ea9d6325822e299c768346a97bdcbad569f8fd323936'
    'dab910255932e1cd005c04342b47285a550c676bc6c504611b968501d04437f3bf43c46bd14481fa'
    '505bc32404aab2a60176e92fa021b16ef35a8de888c54be5ea424113217e3bd18be4214a1976c778'
    '7a60000003000007cc419b944fe10ffc994c00215ffde10000030000030000175f5b2a587350659d'
    '80e6104bc5289f8185910794436c00870d0e12307b2d18a67ead8b361dd2f6bfd62964c604f97e3e'
    '571b9a5016e4eb4bdd3043dd6f68ab71eb9b81390006be2f5704c46ef1a3396f7da77192d6116c5f'
    '1a00ea81a06d359c9cc408a2589e4ee7939f7446593b66f27c1837ce892069342787a73c04c25a44'
    '3981fe8b553192c51bc8c0c6118221495ed556c1f063602d7dfc90e93b5ec608992ef16d506e54a2'
    '034333cc869741555ba433a8ab2974420ea8cfaed1bb5bae9a5385d0bc3c377d10a690b68167ec5d'
    'd2c0d9eef97f4b3edc774700e110dbc93c35e875eb7e5774f329fa5230935f90ae2d3dcdae776b9f'
    '60097ebd221a22d52f5d7ef76a3455a422fd3670009cd4c89af8fdf821534431048e22fcd351cd5f'
    '74353c2771a0e896393270b1f6258d68b3204310b697165d6b094840c5cbdd7999d6364785b69bb5'
    '6b56f4b12ecf9f5e286d9804e09a311f739ed3a9b862a74563855491fcf4d438f8e9c92ca4a541cc'
    'dd32fbcfa3174c16becff573573c116db52d24e7164a82b7b34cd8b307904576dc0f9687089cb65a'
    '2db6dde13df12a0149b0ef59afaa723d7556660272b459936582bb640bba4023d8edc9ca05e598a5'
    '753064396d8ac124aa64cd8dbb4351af6f380ffe7d7e9581b2577036643e3ef026a62d43a573cb33'
    'b1c7623a40946dc801042f972f80823b6fc3b530de686ae1799f541c4c688c3a987fb9e2b0c9694a'
    'd1332a4791b3d5b3db78375a872f2ec6072af5ab69f5f1e9ac2eba18c0317d508aca77aa9df2d2b6'
    'eaa78cb2d30d161f97a90a8f84919c192fed4955aea99f022c8fc5fa1aec0e7e30809eba9b7eb8ea'
    '191879683e8aa13122ce8aba8c23cb890780af16d697e3701e6265a150a38b1e22d7a8de264a7a14'
    'fb5c33fd6c6318f22cf1e6227c1b00bc0c18bc7264ad6933eef541b15d432d75aa28facb921e9df4'
    '548684093e6ab7a0fc0a1b1f00e3d17fa4920684d9dc560a9abe4af3ab947109dfb9b6949ad9e5f3'
    '684e0d0b14fa4f3be850c780adfd3decd3ff7b94c4df1c602bb5b38d66015ab8374313d08d8259e6'
    '6240913d10fc911819c6bfbd069ce046d4ad6fd9c0c39dd1effcedd7d6944ae0d0b81062528ee5d7'
    'de0778897b6d03e56be7da6f03b28c5325398b3529c18c326baf96eda5cb58baf0f930b4139bfe89'
    'a117227c67c74d56cf808a4dde5a3a42586448102fec3aafc5d10a1e21e683953d7aa685614fdb77'
    'e5c4376337444d17263f73d29ea8b78e51e9949d8d2334e8ade3496207e7da34fb6020c74b601036'
    'c8495900324684c1cf677d575a613e8a0afec91322a25f582b9e6db93285f34c0e3ab9dee767f61b'
    '89135353b632711e81ff50061aacb94db4cc35510357fd923e0db93ae31bd6d352e3fbe7d5ded9b0'
    'e33b2165c7766be317181eb837436d152fe21de3d6135c0e3c80c11193ecf648e0bef4b513b42e87'
    '277c16ef9b87f95c639c269b5c5a3e85865ef2e14c4c07513fbc6d4f15f9b3860791d7df44623653'
    'dd6efdeb386422b1b2b65a50208ee20acc8f8c6b179402332fe41e44515fbccc47d4f2611c4ee906'
    '444a5ec5814f117e78dab0d339187e559b7ffce093be817139b6b46864bb0347d6912f1640e04348'
    '1adc2325d649d424432d8d3e1a5b380436336b68c2b796a5731b8845c1d02a3ba03d2be81330099c'
    'b7329c00b629b07ef4edf28606fe6d9e1589a901a2c3aa800000030000b880419bb54fe10ffc994c'
    '00215ffde100000300000300001a7f6f396b7abe45aec00ff5d194fa2f6566ead9c61d2721f71450'
    '6b2a1408424bc216a71775a6aa8815a46aba149fa2f533d702106596069dedcea505a29e92052cdb'
    '4e9cefd5762aebf65972aa15d82fd79c4c9e03a0946b64e0d79154e3ccd4d0eb30e3670b758031d9'
    '91b58fb1ffc8e4df5aa9b7e49028c303906fe5ac0265a3c6ef0678b37f35ada0c6a7c2f50a0ebcd0'
    'a9e72ae7446f1dbbcf015d6397eccf943db38c968ffe3f458158ff5a822db2d296a48e415fe15b92'
    'bafd9055cce365cba6cf11464697f2bc7d309ed9be5a49de289455e5ce5f84ec3925317cc35d9201'
    'a53d85214243a359f6441ddfb2503df58d63fd1fc347fd15254097c6c74adf4c9ca6920d1de7e256'
    '41fbfac4fb51c25e14da3fd3248ed6b28548ad1d927ee0de8c20d9751f8447de33f8af04451ee638'
    'de2e2fdb47b23a2affe1725dcf2ba8a66ca37f9b0913799efb489b9e486d6ca9b3b3561de147ff68'
    'd00961ea582d2060f922859ffc0145faaeae5486deb53a5b824f8a75ebf91bcb4fd861f6b93063d9'
    'fc4244629ea1e7f8b9da405bfdb997da373e71ee3d15c3f574e36f88230b0ab4c916453c93dabb27'
    'c96470b1393356ce0f0a6ad94709e9ab8cffd4aa60f623ab143f35867ee77721f227e4d261a24050'
    '3e6677bb9a11afb71ad8b20d4a27b9082ad9ac3d7c1f5b9d53dca6ff3cae8b96f22c06a0566efc22'
    '0b79b503aaa5eda4cd12cdf8499534b0b2db291255d0a838f1ccf45e4c0af7dc86aabcc843df206f'
    'ae57b410089d944f6bf132cb53d4a5e76376deaef13b031c66f0499463c40d1bd07987f7a3b1b447'
    '29b1148717c05e42f8b30b11d3e426066c5bd8d470ce35075fd13b40158718b3bd5b877e45417170'
    'e016131ad94209ce267a6b778cdbcad3407d105f7cab645059b5564265bd9d9e585212d176270516'
    'c95f739bd9eb9efa1f7eea3cf5f3b202fdc35429ebbc091835a9d63b99bda5d69d9575a336241866'
    'a3c05b4aa812106dca2f7457537597c347e7bad36000a9cac5ed99db0a268457e21decf763a33d02'
    'ac687c60aba09788609172b3a576d2f1afa0ef553ee4edbe7865d8ccec201764dac7eee60517e9ec'
    'd240db423a7fb290fdf4bee95bd894525fae64b212b7b7150bcbe3bd6aa4ad00be785584c473ad7f'
    '37884d5a988a048ceeefd678606bd04d227368f1a000b292ead75dbb006fc8d01ea6858783f29756'
    '22623fdb612b5dbe26aaec802108e0c4a11a61b79e0e9e45b9e7fbd7fed69aa4d86b870617be1112'
    '9961d94b3d764b0d62fc6c2a628bc01fee4274e355f564836f7d30c218a17cd656670cd3d2b435c8'
    'dd061c6ac23121a82b44601924e1bf513cbd1737fc7aeffa9a163cdc30c5df000028e7ce0091edef'
    '83050654062f17c67bae2c40a1b82f94011aa2ac5ac897290e5bd1a70a561993e61fb1427c34fe3f'
    '26f0476f1551b01485def9deafc59075770dfbaeabffdd95ca481b6bbba345faded182ff9f0b5ce5'
    '0936808575b4827f0fba9886c382ffa3deca9aca2080678bbe6a2778203ac0c9c0ba7c83441992a8'
    '70aac8a8249f09b58fb48f3efdffb53172cbbc332673b904375d3887012b2f52c4089d1b68abe2ec'
    'eb02574f9257b1c4182ca8ca6e359fc53da28b3f04495034dfdbe7a18fbe92e2e59984868f9e3f88'
    'e9a78a96698a12087575264309195feded6966ed063779a2ad868865556c37ad5516ad41924e5682'
    'b0cfa9eb0c00000300002ca1419bd64fe10ffc994c00217ffdf100000300000300000e8fa6ea7ce4'
    '6f3005844ee50f7b4f58f32b1a1bc78189062402bd27a310bae7d0d20363ccdfdf14f43ff07bd9f0'
    'cb0f000791619d211de9ede49db79c8761fdd8c70bece12ddccbc12ea02827c564ad324e26ffc788'
    'f59c441216800ff32ffaa5d04e8471c9cad226d1340656d4492c616325e3bd6bcb359a53ae60f25d'
    '9f23c73ff12cad01490b563552f483fd8af88feb9dd01a5091be43f968b46af69e70769f14dca9cc'
    'af0798f5e8ca5737cf16fd1a1f2a463874f67ac756b71a87c84b47e64c5ee9dbf6d5f55ffe963faf'
    '870298a4dca37d10710f7066ab5ed7bb4785ce36e75f1c6e30b2c10bc1a4f345cea5d96c13657c2f'
    '1f7e0f9a1e2a45abfcddf3c8e89b05d03efb43b61397bc0397a7f3c0089175d5ee9faaee5cff326d'
    'd69d89ed531939ec277d7cb79b7d26cffdc840c1bd81b03eb65a394cd70a2e62bc55a6d309bda3bf'
    '8fdc191848db512551ef10e5e1e6bb55f75e5c26779a09a8f08678d4cd41e55460a33cc3a362e0eb'
    '4cdb963066e1fee13d4a9d022e9edfcfb7037669aa73cb62e7dc4d2a1ee8190f2149cf4e1ff64417'
    '8d7833e8ebbf80ae1e75a7a80df428e0ca16b8366096cbd7ba20b5bd7cfe3a71d7a5095b0aef1e89'
    '7d81f55f5574756e224480a42995314ad0f0db6756a69418cf256d402b7f3946beb9cea4caf87d7c'
    '9fc2d7a785583d5fee0526197986cc84d3f5a3eddef052e2fbbe240e0beab0d944b4de26f1fcec50'
    'd0db9401244f0f7c734930e603a0b0219be1bd26f653102915c6e052a35f300b5a2771ecba001a40'
    'ad39cdd74a34ffe76f5afacd5b67630f5a37149ea47c28592fee5a9c1b0b85aa58691dba5a64a055'
    'a63ec0d5e203668e0871ae29d980e6de891114a1730c06720fb6304cc3be9e6d3efc91ebd7f2579e'
    '993b7f3adfca29ddb6b025dcb70de65174d543a07206f497fa1793390b9e90060dd048af93e1cfad'
    '1a40c0805dbc031b30602be167c7c0a3e66fcc67fbdc7820f95cdd307e1dcf0f157f69b7d28f306f'
    '408135279f0d14e87ba7eda71e594d85630f75552000000302ce5fe9c53beb425c2d521978b67ac6'
    'c4cc4deed32d33853fee74891550f185e3fb347972b625a59f0c0c578aaed46de4e6c78e03d929d7'
    '06e9e96b49f7f9c81abebaccd5b156ea07deadd4f851268b04c66b1edada650a1bdc1997a361d4b7'
    'f6cbf612e7b5ddf40913ddd16afdb6666ee44b1dbc3c975e2b294ea253bd35ac680618c26e924392'
    'e37c34179a3ea4e103da59f98cf7a521376d98bea0b6387cdd090b55d637b188b02924f7c46e5452'
    'f3a9832f004688f3423b21ff806407718f0fae06ce7ce3448e15bb282356dacc12a6edd21389dfbc'
    '92399c953b03b80955cf19ee6b642f674fc7463a5738ff0de7ea5ffe7632933a8f3313ed42bbe3aa'
    'f1c34bd1930423afe9f01bdb08cf038c81ec948ff632adae84e3f3778ba7ef3cf46706c01da37ae0'
    '419bf74fe10ffc994c00217ffdf1000003000003000011ef806ace4d1d13007252401bf900d79cf6'
    'da59149c8d3a37a3b46000792e2ebe50be80473f000f9af15362005894a16f0e4abff7e841f1ef76'
    'c6dcd1f26a55249c7438fe28bde51ddd4a0c6c2356112717480e6007b9b2183a6c74bf3a5910f673'
    '7d978cec5c10567f625afceae072120c2076c0b886099262fc8fc32cab1dbc129c1c55283172b15f'
    'c0628bfac57fb9c13c9e31274eecd72e5a64cef33648722e51b1c778371140b2f4a9ef490f63583e'
    'f2bf20a97260c9d73ff8707fa695a16180df0df3e09158bd5d4f2f79a8c066705877641c666c0648'
    '21978e2aebdb76f2750e778637527d209839a364224a3bad700059dc8525f3874b500a63edf3aa61'
    'a1c0b7cd4abe526ef7d53dad9880127be0aa59b9f2443eced13d17cd5989fc569aae15effdc464e1'
    '792027ca786becf3de3c69f81b1281bd6c9d44e34014bd7f41a2edc2689cc49f75e84081e41d866f'
    '01af7b6f3e857fc115c7150c75f0e1fcb02299f3d9cc45821f272c9129af50ecd4d2b97294fcff15'
    '313c75c2292f9885cd93f220c7c7e5c2aecde89e8efc5bd5d8992907d2eaa6252690e8694c0bf5a2'
    '733f3de320931c8b1ce2c0c4a4655f11ea36709167810132f7d6f5e8df124c544e163df81e61705c'
    '12e0b389a47140fa222a074685c994f7a55cc6e605cc1cf39668f96132f695cb6a41c026908e8ea5'
    '900024097bf17bec67cef57fd8da2f6ec87d4a11465d63005adf05ef8bda182d309902db6cee88bb'
    'b3e529a87d5e5a8cbeb0a32a5e616f89a8449c215dc6a3331314c3f9eda758b1a6d482e0cd5d544c'
    'd034bae9789bf419515e993927fd181b6dd8348b9ef6ea1c0f8fcbdb6e6b7e262578509620f3b15c'
    '38c84e685ddf88fe358378429a430de05f36888f21807c856ef37b873f4e6684fa4d45a52f7ecaf0'
    'e0b250a47f9848997df65f46614bd2226e6fa2d1f8e4b90cf19de8806b7bba19be47c5dba9741236'
    '1e63dd0a6eace29dcb1326a2e26c3f13301870adc2405c9261e54a70e2a098625a75ba367599dd5b'
    '998edcc35a0e7ea706aea1ce7cf863215df675f571911a473f6e66b61fc923ba2f8ec343471c61e3'
    '9d1a3675bf6953be486236d262d891df692edc40de19325a0b26178211c87e7c25461bffee27be03'
    'ec965e8582211c4839cfe3c8c9c667dcc489e05c25f06172e3918794c69c782c0a36261267e5e416'
    'a6ce25fcd8a59218733abc25618dc7ca26a513b5fed60a5053f165d86d00c0cc93d85a39af13d430'
    'ec1fc1158bc5cf9b2621f601442f82de040908161dacb066466c090093886025811cfe2c17d8b9e6'
    '570cc0c4fcd3bf8689cd745278cf0251f6fc7d3e13015ced2d3d0c291d967b54a36265cc41d112d6'
    '9ca2083353cf7c0a95cc26317a0c24ad78b9daa948f621d0bb7deaf40717c8b382a0adaf00289710'
    'e9eec6ad5e1cf0cae750e6b380931c5ff6cb3b9c255f604691818166dfa6d292a11d4785abf9f9da'
    '34cb3a7b03eafae9c066b289776c16cc31206159ad43134be73612e41c25796d2ed8813ddb0cb58f'
    '7af0d19d8a9b51385fa64ea1d50bd5ac0b5c7f66e2bf3a9c9dc133a34a78f34e3af8c979d6d8717f'
    '8ce25f207e7b75bd09d359b5f61203c807a690fd470a4d459848f334646bfbaa35861478eb3ca712'
    'be1223433a949139560351847ae534b338270666e21f686f4043a6cafea95c3b013a7756fa651b9d'
    '3478484247b6ca5c23acabbe6d63145b08588aff26961b33f9db6fc07f54225ccc8b698b051fcc4e'
    'd1ea6657dbafaf1b64fd03e5065c6a6b1e9f13aaf040021926e7e6d709dc3f60f369a4455bc4df53'
    '44a2454b2fc58a9e374626dad393d95ed1e74012cece8329c3acee867935fcddaea0b3b41d450648'
    '2d132bc60aa8207b5329d2661835e267b8896511ea696e21db3cabd3552c28bed75d026c3ce25c06'
    'aa8a20cbd758147bd47b45ade5bdf63d91d1da4e900b603d61e2a5cf7d5221bde580607d5112df41'
    '9d50d575ff04784489cb02085f5b95cf7deb554e21f03eeedd4da7e50c6fb6961c2202c0eccb3a4a'
    '8dfd1ae8048b8c7cdd9b4a6b414ca80e7576fd875e3390000003000016d1419a194fe10ffc994c00'
    '519170cffe38400000030000030000fd78b8002b87f9ca2bcf3855afa127808cd59b7ec1a341b5b8'
    '7549ccaed56fa05761d96bc3c3381c1c1bfaf72e6558a98c37ffffcfafa9d8422246be880774c840'
    '841b587ab8739e99735a102000dd921613184ed8726c1e7908a9b171a372ed6cae0cdb622fa9c540'
    '3c5e404d772dd958ddc146338add23833473d33a7d6a9d8ed894e0df2dc820678cfaf99006e63770'
    'd43ff725f9a358b581a9a950536918cce3a3fa32732f589da5e8aa99d489b76850c6dec621552ab9'
    'c53fff6b8092d0c4ca7d45a98798dd05123c759212f26a0e761799069cc19fe1f7686ba8e412c2a9'
    'b61205c88531eafd4a1aff9d5b8d80b31be2425cf9c059ab524182f18168cc52fc3a550f8c3bd04e'
    'ab1c2fd88cb97ba8f724022d1cca069f84438dc0907eb64a66cdccdfc870a518d4abbdeeb61f2a1c'
    '7b1957ff244499075e67ac3d85d529d5a50353b74de6a7c144e0161153b909e1cb03123b23b3959e'
    '4b208031a83e45c9a248c36070ce30ca35a88de59fa4df7c4ddb8e7c0ac3ae0c7fd50b6e96820ee9'
    '125ef558f9b0497901cc7f7774da85a1aada9e607e73d81e8c91dbbd7b4f91e779161f73a98877f3'
    'fd84858b53787d5ee61cba7fd8bafed932a0b23aae3a94647b7673c61ed034da228908bec9941c4e'
    'be117ef396597d1666e06602df116f7280513bde837f3f63ca8e0b350ca6cee39186824459043f77'
    'ee2623f8a9a77f4c380c4017aa04926933c73f419db73bed57e3fcd8986f272e700c06e861ae2179'
    'abb001d66568748879dd7b5ae581f0fa75a6ed1a4ad94c1020a45da459702ceb85a0b168990a5e57'
    '4f3342fbd2a575adbf18c8318fb88a0514f062bf34351980539c530093ee587b300e4565db0ad7d0'
    '92537929dda8b0aa98a052a5449004a0d98dd68bd7b768b8c174c93cd50b8526ad700e33d4026f13'
    'bd2d890b4e23ab4303240430c6d5c245107367457b6dbf6e1785ec7277a41a63419b9e15ffa42946'
    'b5c699b1e43140163b555f8f2538785a3ca40c823de2a4b939cfeefb73beb8e8b667e47bb1a2030b'
    'e4d43c299b74e3c9c615efaa07cce87e74a8ea0e2a83fb74293043794818676936764eaafcdd75f6'
    '9ccb2bd6d0cf83e8ee0373d0776375819160324f0e71e2d23994f3fce30e5b1e874f3b5ca01a1d23'
    '577eb4fc3d809140e9e363dd43d3e3d173d0355d85d612c7157bf39bb14ecfd23b14d2222b08f712'
    '6337d3743ad5769a40aaaea8bb238207218bd524fbaa032256571965c68adcfe0c724110ef241672'
    'cdecadd933a55a78894b02d622655c23e6e086ee57640d1f70a44140e65223dbac49c691b1dadcfd'
    'be8fb0be598a9515c9baede467c31d44e1a0f019406f6d4da1a2eabe753493e1d1566d975d248244'
    '3b69461ec2bd9a346453426d3032f444c22683c79e1b1c309854825aa259411347af39b3ae282c6c'
    '6b78d42fd80ddc25f08a941a78a5673a2a9cea40465d6c2ae4b6ba30914fdffc1b1ff959e223cf7d'
    '53c42d9eb6442125400000030003d7019e386491ff00000300000300017d4721d624ab5e2ea8a225'
    'a984a2e641efc50f20de6c8ea2a032a192d466e37b8ff93b25cf6ef50d1bb375972cfdb57410d0e8'
    '373643a41124e27c8c8d9b900b2f9d0b94fc9e03edf00c83d2eb8040c643a39223a7be90ba67b4f0'
    'c03a9f272cc93033fa8cf9052dc2799e5093c21331333189ab45639a83c03d30aa0d562df0a05efa'
    '1e4caa35ad2c37fd032fcc28000003000003006f40419a3d3c21fe4ca600433ffe38400000030000'
    '030001065a8ec01918f08fb40c2d5f1597cd255a82a9f6138fe799f746fa6065b90f149deef17336'
    '93bc27dfb3ad2b0f8d3b244b71409f8cce142bc1ee4a648dfca2479fdfdde37675bebfb2ed953dc3'
    '5a616c502771af72658740e173ef2dae67ac7d706579a6e7400161bad30f63c82fd8828d74203fdf'
    '60b387ee2f85a4a45fc8da864d327808170cedfae2766425a6e4bf1d43a8da1e0ad4d1dad0be62cf'
    'c28c1f753ecec0b971abb319394d0ab20e8321ceca859ec012d335a562c7e3fc3c6bd9234a7f59f8'
    'caae40680e5e6debdb352d25f293465300857dbff26a795862e30485b480eca8434387c1553dafcf'
    'a6022889af3404b6b99aa22c83ac2727a8338b5dfa5214cd609b243cab8b8231b82717bc63a043f6'
    '4525d9716067d238bbe5792025f99451f3f3fbdb5bba453aa4752b43da37460bea7107ad78832ad7'
    '8a5d124c928145b0d78d3247adffcf51471f32903654c2d10b6a451d95c06e796a9de618a56e4eb8'
    '13ce7d42215cd20eef57967d38b34a1e872b1d3c691e5168b91e13276864b268ad385b039ec1408d'
    'd942cb9b62a7fe5d128636d09944fa9fccd1804ca4dac8c6c3767b38579b3d1bc67c261170eb864b'
    '86e37b54ee5de1c7e3d96eb0c4f2fb9bc50beb2a286dfb1cc03b93dca7a5f390fb2a40a6b3a5cbe9'
    'c6e1b45a60fa1464538c43e79f7fbc5fba35a3ff3d01bb886673e8d48dacd9942c70e3f5ef2630e7'
    'dac910e2f45618ee2cf715c355978ba4ebe19ef9684f4549ba3549f05af30dceb9d4d624ac588588'
    '4b2764dd64cfc9253ab62d9f779aebd8c71265ce60df33e99837cdfef5283e452517478f1c106922'
    '44a70340222309e5362f9cd5d43a32e11528b2b1d1980e0259884c4fa0459d5bdb2c60377157384e'
    '3f12bbc6f3a670c8381a3f1eb889aceb5a5830da37bc9bb2b36b6dc4291d6aaf85d004d00df46403'
    'a4e72280044051424c15adb618e7cbc625e734456a587ed2f7d657395e965a6c7bec3d015611e50d'
    'dacf4e983fba4002a2f9a4f0bd5a7e4b0707e98904d18bfcf4e44546d3d7c516bcfedbe4d611f3f4'
    '96d7c7f2c228e0fc02b4f55c98473386de34237a55504d9f5dab874df0d5fb98a00d4a2b01a1a041'
    'cd4081be2e131b6ad4c64d10e9284f3b24fa2c27ceb4ea590abd9f38dbc15aa5a616197c653a85ae'
    'a509fdc62ce19b2eb0f686e225589b578333b34445cc11bd8c9ded03f4296fbc851c000003000003'
    '008781',
  ),
  <int>[
    98,
    640,
    159,
    118,
    673,
    119,
    522,
    646,
    987,
    616,
    768,
    760,
    857,
    703,
    965,
    864,
    1024,
    694,
    1180,
    934,
    1114,
    1170,
    921,
    797,
    1262,
    1261,
    1068,
    1510,
    1105,
    166,
    902,
  ],
);

final List<_ExpectedAu> _au92To122 = <_ExpectedAu>[
  _ExpectedAu(
    decodeIndex: 92,
    presentationIndex: 91,
    nal: _au92To122Nals[0],
    nalLength: 98,
    nalHash: '1b4143bab56d2ac1086d27794ff81134624b0d1763cae902e503668086690db0',
    frameHash:
        '5208b729402c6ab3bdf45ba0f615097a0d9dc1d26f78f49603b4b6f88b89d4a0',
    frameNumber: 7,
    pictureOrderCount: 182,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 12,
    interMacroblocks: 17,
    skippedMacroblocks: 3481,
  ),
  _ExpectedAu(
    decodeIndex: 93,
    presentationIndex: 95,
    nal: _au92To122Nals[1],
    nalLength: 640,
    nalHash: 'd44f56055aa43abcd8eceb31327567ee6a79de79799f0252cce96bfc6a0b1052',
    frameHash:
        '7460dce20bf98f17b2c8f7f0bf4e82f39bd68f900cfcca56cd0784459fa9d0a6',
    frameNumber: 7,
    pictureOrderCount: 190,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 18,
    interMacroblocks: 69,
    skippedMacroblocks: 3423,
  ),
  _ExpectedAu(
    decodeIndex: 94,
    presentationIndex: 93,
    nal: _au92To122Nals[2],
    nalLength: 159,
    nalHash: '504e0e8bbf29503e32c0ddfc707774c5c22c4f8e46f51b84da0fe467cac52152',
    frameHash:
        '9a009ae661418067d34b6414ac903f0706a7a0b27726edbb75fa6a339b9e5722',
    frameNumber: 8,
    pictureOrderCount: 186,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 14,
    interMacroblocks: 27,
    skippedMacroblocks: 3469,
  ),
  _ExpectedAu(
    decodeIndex: 95,
    presentationIndex: 94,
    nal: _au92To122Nals[3],
    nalLength: 118,
    nalHash: '2a2bd5aaadb872e8e1be7087b1b3d27feb4cf3b92304bdb1034d70fb59c7aba1',
    frameHash:
        'c6acd88c41d78a063297963c68c09d275aba08ee28c995f523d65a9636246fce',
    frameNumber: 9,
    pictureOrderCount: 188,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 9,
    interMacroblocks: 30,
    skippedMacroblocks: 3471,
  ),
  _ExpectedAu(
    decodeIndex: 96,
    presentationIndex: 97,
    nal: _au92To122Nals[4],
    nalLength: 673,
    nalHash: '92cded6633c59929fb7fe2c49f64614171dde44d0d1ed084d90220166790f8f3',
    frameHash:
        '420488f5ad7cfc3e8d9f654c1223b5fe78f1796dfdac2bc2ac9888e19744507e',
    frameNumber: 9,
    pictureOrderCount: 194,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 17,
    interMacroblocks: 82,
    skippedMacroblocks: 3411,
  ),
  _ExpectedAu(
    decodeIndex: 97,
    presentationIndex: 96,
    nal: _au92To122Nals[5],
    nalLength: 119,
    nalHash: 'bedeae96c71382531b5f3680f3faf5711e6a4a0cbba7ba8bc5a306aee7a35816',
    frameHash:
        'be7aee830795e38370e8e530adb2b19cc9ded4ef6e2637d03503017019dc28a7',
    frameNumber: 10,
    pictureOrderCount: 192,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 6,
    interMacroblocks: 51,
    skippedMacroblocks: 3453,
  ),
  _ExpectedAu(
    decodeIndex: 98,
    presentationIndex: 98,
    nal: _au92To122Nals[6],
    nalLength: 522,
    nalHash: 'ea455913fb9b6a49ecf6d6c527f406dc5bcfad361fbd4ec512e7869f8fa03052',
    frameHash:
        '5f1b7fcff04484ef16b46773a32207698212d0688f98b0b1bd0573093217bf76',
    frameNumber: 10,
    pictureOrderCount: 196,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 11,
    interMacroblocks: 70,
    skippedMacroblocks: 3429,
  ),
  _ExpectedAu(
    decodeIndex: 99,
    presentationIndex: 99,
    nal: _au92To122Nals[7],
    nalLength: 646,
    nalHash: '08734978a63af0606c7037f75c1aaab59076a9b937e21f7aab0b05a5c1ceaa60',
    frameHash:
        'aac9588ae9aad625b8bb4116ad9b266a124efb6639c6295cd61efdefb761ec36',
    frameNumber: 11,
    pictureOrderCount: 198,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 20,
    interMacroblocks: 98,
    skippedMacroblocks: 3392,
  ),
  _ExpectedAu(
    decodeIndex: 100,
    presentationIndex: 100,
    nal: _au92To122Nals[8],
    nalLength: 987,
    nalHash: 'd0e0093cea2a50f197d5454e7e6592dc42d0c518cb101804b17aedfff853ffac',
    frameHash:
        'c0e20207418ea7913752f0c8c83679b900a750ec4935e41aa954d4a4d7fdfd71',
    frameNumber: 12,
    pictureOrderCount: 200,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 25,
    interMacroblocks: 116,
    skippedMacroblocks: 3369,
  ),
  _ExpectedAu(
    decodeIndex: 101,
    presentationIndex: 101,
    nal: _au92To122Nals[9],
    nalLength: 616,
    nalHash: 'ed1ed8cf3a6f44840f9831082f84c49d348b1f80c32b6bc518d87439985804e0',
    frameHash:
        '325d8297c02269dc3cff1fcd4efa68bd1ae79f551ae5fe436d1c9cd76a1858bd',
    frameNumber: 13,
    pictureOrderCount: 202,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 27,
    interMacroblocks: 85,
    skippedMacroblocks: 3398,
  ),
  _ExpectedAu(
    decodeIndex: 102,
    presentationIndex: 102,
    nal: _au92To122Nals[10],
    nalLength: 768,
    nalHash: 'a37fa59a2438540d53aaa0c3df27fb8068a74c9201013fbd866b5cda6a282317',
    frameHash:
        '929ceff34542d81e2274a98863a28428ff5f86e1b1af4dde3da3c79b242e7ea3',
    frameNumber: 14,
    pictureOrderCount: 204,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 18,
    interMacroblocks: 91,
    skippedMacroblocks: 3401,
  ),
  _ExpectedAu(
    decodeIndex: 103,
    presentationIndex: 103,
    nal: _au92To122Nals[11],
    nalLength: 760,
    nalHash: '011ec5a530be56b84b2c45b41d9709d89fa566193242774ebaeaeac8ccb8f5c7',
    frameHash:
        '5372bf5e52964c0d534234bc582ca4a368d227fdd764a96823bc27866fef4c79',
    frameNumber: 15,
    pictureOrderCount: 206,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 20,
    interMacroblocks: 87,
    skippedMacroblocks: 3403,
  ),
  _ExpectedAu(
    decodeIndex: 104,
    presentationIndex: 104,
    nal: _au92To122Nals[12],
    nalLength: 857,
    nalHash: '0e366462aa98c28413f17121872aea65ccf6911cc77817137bf63f72fc860fc4',
    frameHash:
        'deec62e98491b1cc6d2a7ffa0b3e31a1863629eee828be15623ef41dab989f3a',
    frameNumber: 0,
    pictureOrderCount: 208,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 23,
    interMacroblocks: 88,
    skippedMacroblocks: 3399,
  ),
  _ExpectedAu(
    decodeIndex: 105,
    presentationIndex: 105,
    nal: _au92To122Nals[13],
    nalLength: 703,
    nalHash: 'ed9ab999d0f1f58402eff098c49c8534405e2ec0a8226afb3aa4b18346df5104',
    frameHash:
        '00d3ab59c0d77b9f02004ffd6a68e6b4fd1fb01e69fe93d6fcdfa56e329fc427',
    frameNumber: 1,
    pictureOrderCount: 210,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 16,
    interMacroblocks: 82,
    skippedMacroblocks: 3412,
  ),
  _ExpectedAu(
    decodeIndex: 106,
    presentationIndex: 106,
    nal: _au92To122Nals[14],
    nalLength: 965,
    nalHash: '0a2b7f75e894014cca14f834f1261e15419f8186785891ab0d3bb133a9430975',
    frameHash:
        '76e8957a94b0a46e366a5a26b619f9e109fd1b80c36544ee3ab32113a5bee0bc',
    frameNumber: 2,
    pictureOrderCount: 212,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 23,
    interMacroblocks: 95,
    skippedMacroblocks: 3392,
  ),
  _ExpectedAu(
    decodeIndex: 107,
    presentationIndex: 107,
    nal: _au92To122Nals[15],
    nalLength: 864,
    nalHash: 'd6743c19069796abfd7f1e72de516a67975ee3e36eeff7f7833e218fcd5c42f0',
    frameHash:
        'fdcf5d62c786413f11c4099e928997a28fb3603397e0efa0f1d748032c3fa36d',
    frameNumber: 3,
    pictureOrderCount: 214,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 15,
    interMacroblocks: 93,
    skippedMacroblocks: 3402,
  ),
  _ExpectedAu(
    decodeIndex: 108,
    presentationIndex: 108,
    nal: _au92To122Nals[16],
    nalLength: 1024,
    nalHash: 'a1d6ebde7e2e50ba471ae9f4f194111024f5bd732e9fd6e781c9a98fa4aff6de',
    frameHash:
        '9a697b009a562b25727f336c8c1a513f91273a8540207a794027febfa3560c44',
    frameNumber: 4,
    pictureOrderCount: 216,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 29,
    interMacroblocks: 88,
    skippedMacroblocks: 3393,
  ),
  _ExpectedAu(
    decodeIndex: 109,
    presentationIndex: 109,
    nal: _au92To122Nals[17],
    nalLength: 694,
    nalHash: 'f0fac5850fdaad4bb5a528100b79af1a8d7d09584367abdece72cc20e920d5ad',
    frameHash:
        '6d4867b4fba299278b540d7af76c633dff691a6ddb8e20377000eede74333f48',
    frameNumber: 5,
    pictureOrderCount: 218,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 11,
    interMacroblocks: 74,
    skippedMacroblocks: 3425,
  ),
  _ExpectedAu(
    decodeIndex: 110,
    presentationIndex: 110,
    nal: _au92To122Nals[18],
    nalLength: 1180,
    nalHash: 'fc077b305e69132921a9920d9f0ab34fa8e2904a09c90ee68aaaf751202cb669',
    frameHash:
        'b466b5d0be070d04e588e686ac2330100a3eb8bf87e677ed514916be8629cda1',
    frameNumber: 6,
    pictureOrderCount: 220,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 21,
    interMacroblocks: 103,
    skippedMacroblocks: 3386,
  ),
  _ExpectedAu(
    decodeIndex: 111,
    presentationIndex: 111,
    nal: _au92To122Nals[19],
    nalLength: 934,
    nalHash: 'ea8ab4ac7aee48a6f05bf4155804604444326e1cb84c38c60f960336823e3a06',
    frameHash:
        '83bc7df7529b3f296aab377ea00d6d6f483778a2f29f0d8f6196e7db1a9d546a',
    frameNumber: 7,
    pictureOrderCount: 222,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 22,
    interMacroblocks: 94,
    skippedMacroblocks: 3394,
  ),
  _ExpectedAu(
    decodeIndex: 112,
    presentationIndex: 112,
    nal: _au92To122Nals[20],
    nalLength: 1114,
    nalHash: '54deca62ca285baa80b30868acd836410ef195397f2adc45fa5b156fb3547361',
    frameHash:
        '85e4f8fa8d2ea95aed973c7ded13325ecfc2867e5330b7e78c8011690464f986',
    frameNumber: 8,
    pictureOrderCount: 224,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 25,
    interMacroblocks: 91,
    skippedMacroblocks: 3394,
  ),
  _ExpectedAu(
    decodeIndex: 113,
    presentationIndex: 113,
    nal: _au92To122Nals[21],
    nalLength: 1170,
    nalHash: 'b035111590e4e18b205b3be0d10885f2f7a27bbc104151d572ea824ca639cd38',
    frameHash:
        'a3703076c94f4c1b2e5cc78140e50af6e9197dfd769a50bee40aac2c495a775d',
    frameNumber: 9,
    pictureOrderCount: 226,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 40,
    interMacroblocks: 92,
    skippedMacroblocks: 3378,
  ),
  _ExpectedAu(
    decodeIndex: 114,
    presentationIndex: 114,
    nal: _au92To122Nals[22],
    nalLength: 921,
    nalHash: '1780edf3a9e322fbf06e007347e66abcc230d424e70d59cd42f7cf73e872543b',
    frameHash:
        'c0657f71b673684a2c9eeb73de195f98ed7d2cf5e1bf2776c5c9d0dfe5f4ea0a',
    frameNumber: 10,
    pictureOrderCount: 228,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 13,
    interMacroblocks: 94,
    skippedMacroblocks: 3403,
  ),
  _ExpectedAu(
    decodeIndex: 115,
    presentationIndex: 115,
    nal: _au92To122Nals[23],
    nalLength: 797,
    nalHash: 'd567b69b9611d20ad714d74c2853163bea2b091706e1ece9890cbed2d3b5185f',
    frameHash:
        'fe71ddcee2d551820ea0d68d4a20a5b432bc2b31439c5faefee2122f58871a19',
    frameNumber: 11,
    pictureOrderCount: 230,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 18,
    interMacroblocks: 96,
    skippedMacroblocks: 3396,
  ),
  _ExpectedAu(
    decodeIndex: 116,
    presentationIndex: 116,
    nal: _au92To122Nals[24],
    nalLength: 1262,
    nalHash: '0b4a151b904ac1abecad9dd11dee975ffba1ab95a21cfa6b06894840772e4643',
    frameHash:
        '017b19fb23e165ba897c62d313afdcfee4ca66ae47fd449acd3d0d6e0af740d6',
    frameNumber: 12,
    pictureOrderCount: 232,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 28,
    interMacroblocks: 104,
    skippedMacroblocks: 3378,
  ),
  _ExpectedAu(
    decodeIndex: 117,
    presentationIndex: 117,
    nal: _au92To122Nals[25],
    nalLength: 1261,
    nalHash: 'a9f61952c4b13072e391da9f052a5e744c1b186bf34fd328099fe2774c90bb19',
    frameHash:
        'd8b5140a0dbbc55a7a5e7255a2ee20dff548419e5d6efa12323c0c0b545d05cd',
    frameNumber: 13,
    pictureOrderCount: 234,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 27,
    interMacroblocks: 100,
    skippedMacroblocks: 3383,
  ),
  _ExpectedAu(
    decodeIndex: 118,
    presentationIndex: 118,
    nal: _au92To122Nals[26],
    nalLength: 1068,
    nalHash: '9b232d7a1e2ed6f93d91e1235f2eadf12868f03dfe5f9f9bedaccc46f4057c0d',
    frameHash:
        'a3d8996bcd704fda060017bec15f72f1e5fa0d38d30a666d1c5420a3bbf4a0a3',
    frameNumber: 14,
    pictureOrderCount: 236,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 31,
    interMacroblocks: 121,
    skippedMacroblocks: 3358,
  ),
  _ExpectedAu(
    decodeIndex: 119,
    presentationIndex: 119,
    nal: _au92To122Nals[27],
    nalLength: 1510,
    nalHash: '9c49cc2b1006c13b850c4770909600eaf7df5c2aaeaaecb6490bbb54cf287f73',
    frameHash:
        'ee4caa7832e231ab9cea893cf07dcda9db3e82076436f0ca6bbb84bf98ae3df7',
    frameNumber: 15,
    pictureOrderCount: 238,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 31,
    interMacroblocks: 112,
    skippedMacroblocks: 3367,
  ),
  _ExpectedAu(
    decodeIndex: 120,
    presentationIndex: 121,
    nal: _au92To122Nals[28],
    nalLength: 1105,
    nalHash: '1948c5d659c059dcaed0328242f8af6be777883bb24b435f3faae09ebdf06ee7',
    frameHash:
        '7d981f5d7f8eab7e887283885a7fc55594d23cc7ec69e38dff57d4c128ee270a',
    frameNumber: 0,
    pictureOrderCount: 242,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 33,
    interMacroblocks: 89,
    skippedMacroblocks: 3388,
  ),
  _ExpectedAu(
    decodeIndex: 121,
    presentationIndex: 120,
    nal: _au92To122Nals[29],
    nalLength: 166,
    nalHash: 'fbf274cd8eae14c2653a31873867405e0449e23da07959aa94006e703a083542',
    frameHash:
        '9bbee32fed2efa31449b9861c88bbc523e7753a7a39d1de82f5f66944019ba83',
    frameNumber: 1,
    pictureOrderCount: 240,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 12,
    interMacroblocks: 73,
    skippedMacroblocks: 3425,
  ),
  _ExpectedAu(
    decodeIndex: 122,
    presentationIndex: 125,
    nal: _au92To122Nals[30],
    nalLength: 902,
    nalHash: '91794e7090f60a4cb489242b3138ef927fc7dd76f6826762b6368abfe9f34650',
    frameHash:
        '00d8ac879f82094d6d063d8f1a6732d39dfb38a37bc75fb65ce12621a7a24e28',
    frameNumber: 1,
    pictureOrderCount: 250,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 19,
    interMacroblocks: 89,
    skippedMacroblocks: 3402,
  ),
];

final List<_ExpectedAu> _au56To90 = <_ExpectedAu>[
  _ExpectedAu(
    decodeIndex: 56,
    presentationIndex: 56,
    nal: _au56To90Nals[0],
    nalLength: 178,
    nalHash: '2565bfdd8391a768d7d479da0083dfc99ee166140166e640a95c3a1172c05471',
    frameHash:
        'e210c2d9111225c316f1909aa78723192c15304f25085423a7c396d2c633e46c',
    frameNumber: 3,
    pictureOrderCount: 112,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 22,
    interMacroblocks: 8,
    skippedMacroblocks: 3480,
  ),
  _ExpectedAu(
    decodeIndex: 57,
    presentationIndex: 58,
    nal: _au56To90Nals[1],
    nalLength: 212,
    nalHash: 'bb03d1ef6aa8eadb93b336fc804ad887fa2d81714389b3c136a9de3f940eb0ae',
    frameHash:
        'adec13c7f925002d7eca9b3c5292cc3418de94838c6d23c129e1198464f71f9c',
    frameNumber: 4,
    pictureOrderCount: 116,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 15,
    interMacroblocks: 6,
    skippedMacroblocks: 3489,
  ),
  _ExpectedAu(
    decodeIndex: 58,
    presentationIndex: 57,
    nal: _au56To90Nals[2],
    nalLength: 86,
    nalHash: '62998a8ecc631d0ad762abe84f66163d27238e227f3f3000711ff54262929103',
    frameHash:
        'e25f7e96932a572bda22e6902045cefee671629828652b8d116e170e59b1e51c',
    frameNumber: 5,
    pictureOrderCount: 114,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 6,
    interMacroblocks: 29,
    skippedMacroblocks: 3475,
  ),
  _ExpectedAu(
    decodeIndex: 59,
    presentationIndex: 62,
    nal: _au56To90Nals[3],
    nalLength: 134,
    nalHash: 'f5fcea597aa7350f1bc9649ec53b3e27456c2aad0b53a8016c10eb809fb4eb30',
    frameHash:
        '0ab9be178925708473d9ff0398c8aa9580fcd4b570a16acc9fa557b083d6fa99',
    frameNumber: 5,
    pictureOrderCount: 124,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 6,
    interMacroblocks: 13,
    skippedMacroblocks: 3491,
  ),
  _ExpectedAu(
    decodeIndex: 60,
    presentationIndex: 60,
    nal: _au56To90Nals[4],
    nalLength: 94,
    nalHash: '25d9d555a1c6325838d08ebd1c5ebcd3860507eacabcf44bd8bd8ad671e21ba0',
    frameHash:
        '1d553ffb2f6c0fe66c3a6dfbe317bb4cd8c00b58a6b5a20507c126af2d21abf1',
    frameNumber: 6,
    pictureOrderCount: 120,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 9,
    interMacroblocks: 28,
    skippedMacroblocks: 3473,
  ),
  _ExpectedAu(
    decodeIndex: 61,
    presentationIndex: 59,
    nal: _au56To90Nals[5],
    nalLength: 74,
    nalHash: '2c0c3c4a0d973c021b2534f54a2af01ad47af56ed7f2b4f757ebcb945f7b9b17',
    frameHash:
        '6a4552f1bfbd7eaab7f13f08e7697cd1536aa2f8f312e3e41cddc0a09d5e52ec',
    frameNumber: 7,
    pictureOrderCount: 118,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 5,
    interMacroblocks: 24,
    skippedMacroblocks: 3481,
  ),
  _ExpectedAu(
    decodeIndex: 62,
    presentationIndex: 61,
    nal: _au56To90Nals[6],
    nalLength: 69,
    nalHash: '1ac82e725a03a7f994d2a801ab33c1d6e995801af75f18e4251ff4ad3fe1b827',
    frameHash:
        '5a5a3c8ad4a154f56a4792d39b0a1543894ce780b27f0a94ce19f5b98adf5f9e',
    frameNumber: 7,
    pictureOrderCount: 122,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 5,
    interMacroblocks: 21,
    skippedMacroblocks: 3484,
  ),
  _ExpectedAu(
    decodeIndex: 63,
    presentationIndex: 63,
    nal: _au56To90Nals[7],
    nalLength: 109,
    nalHash: 'a006c949c1320208654f30f61515efb8f97857e041601955a2277e72f649e168',
    frameHash:
        '94d2c22d3a2c5031ce75d7155bad6cc9deb4c7faf627a29d9a21f80840861c31',
    frameNumber: 7,
    pictureOrderCount: 126,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 16,
    interMacroblocks: 2,
    skippedMacroblocks: 3492,
  ),
  _ExpectedAu(
    decodeIndex: 64,
    presentationIndex: 65,
    nal: _au56To90Nals[8],
    nalLength: 313,
    nalHash: '908e3467d49717bf35b7a5465b89329e087d7372aad4b77264ea3095d3de62ab',
    frameHash:
        '3ecaad6b34247622c5e96cb7f025ef2a8839491dda3384394614e7bd4f063fa6',
    frameNumber: 8,
    pictureOrderCount: 130,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 30,
    interMacroblocks: 7,
    skippedMacroblocks: 3473,
  ),
  _ExpectedAu(
    decodeIndex: 65,
    presentationIndex: 64,
    nal: _au56To90Nals[9],
    nalLength: 118,
    nalHash: 'edb176f1beac90effef79c825ca949a4079bc7f75fdfeb0bde637ad3abc48e37',
    frameHash:
        '5d0329b21c5fadacde08f4d635092c12937487357c07ed2ba2d21f22bf20be7e',
    frameNumber: 9,
    pictureOrderCount: 128,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 13,
    interMacroblocks: 41,
    skippedMacroblocks: 3456,
  ),
  _ExpectedAu(
    decodeIndex: 66,
    presentationIndex: 69,
    nal: _au56To90Nals[10],
    nalLength: 368,
    nalHash: 'd5657105d1cef72664c53d1f25ba5f4cfb5a34351f883f97820e41d2bcd79e77',
    frameHash:
        '78f0aef4e3ce95e5aaaf13870b314df6f69c5ec6745dc842ae97ce6ac7330ead',
    frameNumber: 9,
    pictureOrderCount: 138,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 18,
    interMacroblocks: 11,
    skippedMacroblocks: 3481,
  ),
  _ExpectedAu(
    decodeIndex: 67,
    presentationIndex: 67,
    nal: _au56To90Nals[11],
    nalLength: 118,
    nalHash: 'bb8707ccae04e2d661404464a431dc6634b44c6c375b27b0d80a2cf97ae73d00',
    frameHash:
        'a953fcf92b6e1dde01a78f211a89128be06614b97f9f89ac23746e0208e13fe2',
    frameNumber: 10,
    pictureOrderCount: 134,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 11,
    interMacroblocks: 37,
    skippedMacroblocks: 3462,
  ),
  _ExpectedAu(
    decodeIndex: 68,
    presentationIndex: 66,
    nal: _au56To90Nals[12],
    nalLength: 93,
    nalHash: 'e85529ccdafc1231dcd04286bdf4ed2b12c6cc48a0f00455f86d1cbf00b09078',
    frameHash:
        'f5ca62c49661898a46774cae7ba707226d1c18aef77dabd8d667cfa1e6892aef',
    frameNumber: 11,
    pictureOrderCount: 132,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 6,
    interMacroblocks: 30,
    skippedMacroblocks: 3474,
  ),
  _ExpectedAu(
    decodeIndex: 69,
    presentationIndex: 68,
    nal: _au56To90Nals[13],
    nalLength: 92,
    nalHash: '724f82e1e2ce6fdc075ccdc629e10647656908654c9e1b0fcff144b8a3d0e1f3',
    frameHash:
        '6c193f17b80a7d539c2d14ee97bcc48fbe4f7c6b5c8768a100f75d64c0f69d0d',
    frameNumber: 11,
    pictureOrderCount: 136,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 9,
    interMacroblocks: 23,
    skippedMacroblocks: 3478,
  ),
  _ExpectedAu(
    decodeIndex: 70,
    presentationIndex: 73,
    nal: _au56To90Nals[14],
    nalLength: 449,
    nalHash: '1846d8c4dfeab863fa0cb27914f03f7f272a380d8da8d956616835ec7b04c0d5',
    frameHash:
        'e0a68992fa0ad4513faaeb310a1088c9b22307aa2e9c072044dd5ee1f1e56535',
    frameNumber: 11,
    pictureOrderCount: 146,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 38,
    interMacroblocks: 2,
    skippedMacroblocks: 3470,
  ),
  _ExpectedAu(
    decodeIndex: 71,
    presentationIndex: 71,
    nal: _au56To90Nals[15],
    nalLength: 129,
    nalHash: 'b2e5ad4c6902fe30c107480274d3426e6809277d971ddc2cc97094febbb9aedf',
    frameHash:
        '666e30da26091d6306552f2e090b41b3c5f30a774ffcd770ede6ec127ad88d47',
    frameNumber: 12,
    pictureOrderCount: 142,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 14,
    interMacroblocks: 45,
    skippedMacroblocks: 3451,
  ),
  _ExpectedAu(
    decodeIndex: 72,
    presentationIndex: 70,
    nal: _au56To90Nals[16],
    nalLength: 106,
    nalHash: 'c2165c0d7af1b955b74833cf95a033fb08f57b5cc9991f8fc656f14167a4ed8b',
    frameHash:
        'cb51c98473938fa631b61b7a2c7b69df58af4c4a8621c7b29788674f6820fdb2',
    frameNumber: 13,
    pictureOrderCount: 140,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 8,
    interMacroblocks: 41,
    skippedMacroblocks: 3461,
  ),
  _ExpectedAu(
    decodeIndex: 73,
    presentationIndex: 72,
    nal: _au56To90Nals[17],
    nalLength: 120,
    nalHash: 'f9fe839f4beb652c6ac82b4ab4d4deb4d645a4c914162185b27930d7d524112d',
    frameHash:
        'db32b610f24d7f32f8597b3a342edaf4126d5fc93514e7a0b6c696b2bfae8fc6',
    frameNumber: 13,
    pictureOrderCount: 144,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 15,
    interMacroblocks: 33,
    skippedMacroblocks: 3462,
  ),
  _ExpectedAu(
    decodeIndex: 74,
    presentationIndex: 77,
    nal: _au56To90Nals[18],
    nalLength: 99,
    nalHash: '2a2bb95a7e38044befa2d79c0d771181dc8ee134a06702cdf776a06899d8e1d7',
    frameHash:
        '2b617fc2b403f37732852387ab1787bda4fb3e860473e969eb62a275f9273c18',
    frameNumber: 13,
    pictureOrderCount: 154,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 8,
    interMacroblocks: 5,
    skippedMacroblocks: 3497,
  ),
  _ExpectedAu(
    decodeIndex: 75,
    presentationIndex: 75,
    nal: _au56To90Nals[19],
    nalLength: 84,
    nalHash: '65d2959bc1808df5543f24bb1fa875fc045b78cdb3184ebe594cac7689cfccca',
    frameHash:
        'dd08daa0709ff6b08f031972546a64cdc306378427b5cb729bf026d382db36c0',
    frameNumber: 14,
    pictureOrderCount: 150,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 8,
    interMacroblocks: 22,
    skippedMacroblocks: 3480,
  ),
  _ExpectedAu(
    decodeIndex: 76,
    presentationIndex: 74,
    nal: _au56To90Nals[20],
    nalLength: 64,
    nalHash: '82b2490dd045a2a0af7faf9009b37dc6dfd1a9dc07930584b7e4c331c0de0496',
    frameHash:
        '94c8863eda8fd29f0b40b7074b7bf849212a21bf8d97a7748348b4a4f507c1a1',
    frameNumber: 15,
    pictureOrderCount: 148,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 21,
    skippedMacroblocks: 3485,
  ),
  _ExpectedAu(
    decodeIndex: 77,
    presentationIndex: 76,
    nal: _au56To90Nals[21],
    nalLength: 64,
    nalHash: 'd9aaddc314e45e94dab4ddea5ce5db9300da45f24d5798a92934cad4abfb1bff',
    frameHash:
        '901405ba0450acd5bf485b0e421f859d4e5192964467aefda1f44dd081b11b01',
    frameNumber: 15,
    pictureOrderCount: 152,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 20,
    skippedMacroblocks: 3486,
  ),
  _ExpectedAu(
    decodeIndex: 78,
    presentationIndex: 81,
    nal: _au56To90Nals[22],
    nalLength: 43,
    nalHash: '232e5f147bc16c5a6fb307c8e94c20eea4aaab8722bfdb975d5a798bfb468d9c',
    frameHash:
        '2aba3f03ab1aa1dd51e43cf390ea5ba4f18963c3fa4cde5f099456c863254ee1',
    frameNumber: 15,
    pictureOrderCount: 162,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 0,
    interMacroblocks: 1,
    skippedMacroblocks: 3509,
  ),
  _ExpectedAu(
    decodeIndex: 79,
    presentationIndex: 79,
    nal: _au56To90Nals[23],
    nalLength: 78,
    nalHash: '632af9821be01083d54cca3f187aa91f452d03e373b2925f35e9c4bc7dd7e10e',
    frameHash:
        '8279d17c30f89f0e5e8afbb982e0ce2cac93f769daf9df7bca1c45d3bcece4d6',
    frameNumber: 0,
    pictureOrderCount: 158,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 7,
    interMacroblocks: 19,
    skippedMacroblocks: 3484,
  ),
  _ExpectedAu(
    decodeIndex: 80,
    presentationIndex: 78,
    nal: _au56To90Nals[24],
    nalLength: 56,
    nalHash: '85166ca7be540758a501909c76002254646a3cf18db31c1ff7ca4660dd021d6b',
    frameHash:
        'b5a14971e3e84f3623a61d716e9dd4e26c5fdf981ecb367431024c639fea4bc8',
    frameNumber: 1,
    pictureOrderCount: 156,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 12,
    skippedMacroblocks: 3494,
  ),
  _ExpectedAu(
    decodeIndex: 81,
    presentationIndex: 80,
    nal: _au56To90Nals[25],
    nalLength: 56,
    nalHash: 'c6ad7a9ec209f80c22a9317f115abf9e67ebf58d69089ec25a02c819f466951d',
    frameHash:
        'd70f8738152ee79e02c8f7f6928afc7311482cd67400e4b3775f1bd278ba0084',
    frameNumber: 1,
    pictureOrderCount: 160,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 12,
    skippedMacroblocks: 3494,
  ),
  _ExpectedAu(
    decodeIndex: 82,
    presentationIndex: 85,
    nal: _au56To90Nals[26],
    nalLength: 44,
    nalHash: '8e9bc9178cec7af97455d95ecb404993d0c5fff48490f55507061a14973fa4bb',
    frameHash:
        '04831db5753128f2d5b1e87fcf063e4a4b5290fe141b36f31aed3232e9499355',
    frameNumber: 1,
    pictureOrderCount: 170,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 0,
    interMacroblocks: 1,
    skippedMacroblocks: 3509,
  ),
  _ExpectedAu(
    decodeIndex: 83,
    presentationIndex: 83,
    nal: _au56To90Nals[27],
    nalLength: 79,
    nalHash: '6d922cb3159614c6a61f339a0e84c42eee538daa96c8e7eabdaa550c1099eef6',
    frameHash:
        'bde31258e62c17d3c98c4f7a4b21f0194a8e384d9494c9c4fe3dd5fd4d80c77b',
    frameNumber: 2,
    pictureOrderCount: 166,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 9,
    interMacroblocks: 17,
    skippedMacroblocks: 3484,
  ),
  _ExpectedAu(
    decodeIndex: 84,
    presentationIndex: 82,
    nal: _au56To90Nals[28],
    nalLength: 55,
    nalHash: 'cb6bad200b7b0d9fba48fd9088b7033c8c1837dfc56edd5caa4e17728adf2829',
    frameHash:
        '916c3fc5eca179fc83f28f7e5e1504ff5ae071083e3c7680e94398c8426babda',
    frameNumber: 3,
    pictureOrderCount: 164,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 12,
    skippedMacroblocks: 3494,
  ),
  _ExpectedAu(
    decodeIndex: 85,
    presentationIndex: 84,
    nal: _au56To90Nals[29],
    nalLength: 56,
    nalHash: '59870c6e9faa579a98cad241e73db384de47e9875643006a1b71ac0889db792f',
    frameHash:
        '8174048b0396642cac8f119b3cccd9d5a8ec076bd41d2602dcfa56a0fdcf11bb',
    frameNumber: 3,
    pictureOrderCount: 168,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 12,
    skippedMacroblocks: 3494,
  ),
  _ExpectedAu(
    decodeIndex: 86,
    presentationIndex: 89,
    nal: _au56To90Nals[30],
    nalLength: 73,
    nalHash: 'f6d74159a8f1977ea455637301db42b82c007dd9f78d98e0c0b942a4cb1edf73',
    frameHash:
        '17daf7b9b2a05f412a29a5f40ff55c20b35749020978aa616ee7298c5dc6b415',
    frameNumber: 3,
    pictureOrderCount: 178,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 0,
    interMacroblocks: 9,
    skippedMacroblocks: 3501,
  ),
  _ExpectedAu(
    decodeIndex: 87,
    presentationIndex: 87,
    nal: _au56To90Nals[31],
    nalLength: 77,
    nalHash: '77e7c94511e41ab91a6ef930b84e9ed00a66dd874979db4b39d0f9a2fc49d305',
    frameHash:
        'c6a9d70f0269c16129b4c3a99ae4013fa2f5e90fb3b7e760cf5fb8a2fe62deb9',
    frameNumber: 4,
    pictureOrderCount: 174,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 7,
    interMacroblocks: 19,
    skippedMacroblocks: 3484,
  ),
  _ExpectedAu(
    decodeIndex: 88,
    presentationIndex: 86,
    nal: _au56To90Nals[32],
    nalLength: 56,
    nalHash: '1f5d420fc85ecda3543ccc00615b2e505877573e67a163b3787312caf43cefed',
    frameHash:
        '06689bedf3f90bb58b16381ac4f1d505233edf0bb8db2e0c684dc8aa6d06f9d9',
    frameNumber: 5,
    pictureOrderCount: 172,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 12,
    skippedMacroblocks: 3494,
  ),
  _ExpectedAu(
    decodeIndex: 89,
    presentationIndex: 88,
    nal: _au56To90Nals[33],
    nalLength: 57,
    nalHash: '0f674b736d6f9640671d84b4e19776fdc8e4f0f2a3e67b61e0f5c02b13682065',
    frameHash:
        'd517352f8a272a228f4ea70b4dfce211c3f4049ac9a9b246599641470c293eb9',
    frameNumber: 5,
    pictureOrderCount: 176,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 12,
    skippedMacroblocks: 3494,
  ),
  _ExpectedAu(
    decodeIndex: 90,
    presentationIndex: 92,
    nal: _au56To90Nals[34],
    nalLength: 382,
    nalHash: 'cbe425227eae4a01bddae94670a8add8523c5f5c26cd427fe0ee2b7f1c2758c9',
    frameHash:
        '4de433075a8606415764a9d8a5c094570f7a4e03a30360525fe5ec8f8c56e6e8',
    frameNumber: 5,
    pictureOrderCount: 184,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 17,
    interMacroblocks: 47,
    skippedMacroblocks: 3446,
  ),
];

final List<_ExpectedAu> _au26To33 = <_ExpectedAu>[
  _ExpectedAu(
    decodeIndex: 26,
    presentationIndex: 25,
    nal: _au26,
    nalLength: 49,
    nalHash: 'e753ab8bc11c53cf12bd4c8a0592b61e740806a2890e4b17c5af2adbf510bed5',
    frameHash:
        '155a27c4f1bf42a6e5a2d62785bba153d6cb8f525b652f7e241b2d7946ad16ca',
    frameNumber: 3,
    pictureOrderCount: 50,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 5,
    interMacroblocks: 1,
    skippedMacroblocks: 3504,
  ),
  _ExpectedAu(
    decodeIndex: 27,
    presentationIndex: 28,
    nal: _au27,
    nalLength: 2384,
    nalHash: 'd4af5bed650841911ce3cf5bb0a8cebb840a0b47d40b90c7b75ed8fd296d9b98',
    frameHash:
        'cdc3173596f84cc3d6bb80317b054ae91396ee2494c8477d83bd2fffbfc0df80',
    frameNumber: 3,
    pictureOrderCount: 56,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 39,
    interMacroblocks: 127,
    skippedMacroblocks: 3344,
  ),
  _ExpectedAu(
    decodeIndex: 28,
    presentationIndex: 27,
    nal: _au28,
    nalLength: 66,
    nalHash: '5354ddfe9f2217558c7662e56bdc5ca1b9ba88108d87db25231f0c5934c08f99',
    frameHash:
        '5e3e3745ee231d6b095c92df2e88f7a75d045202da7b8378d55f8a27b7e6cc02',
    frameNumber: 4,
    pictureOrderCount: 54,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 14,
    interMacroblocks: 1,
    skippedMacroblocks: 3495,
  ),
  _ExpectedAu(
    decodeIndex: 29,
    presentationIndex: 30,
    nal: _au29,
    nalLength: 2914,
    nalHash: '088d3bc5780f14be9cce47038f3c0ae373a9cebdd4293727827bf4fe6be6c140',
    frameHash:
        '185c2e4e42af0abb37983715aa24f23ae922cd603f95473815838f9eafbeb936',
    frameNumber: 4,
    pictureOrderCount: 60,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 66,
    interMacroblocks: 127,
    skippedMacroblocks: 3317,
  ),
  _ExpectedAu(
    decodeIndex: 30,
    presentationIndex: 29,
    nal: _au30,
    nalLength: 70,
    nalHash: '987837ab4b12f917c29722ac9f0413035cfd6d0a034a13d7b0d85dbdc67dc357',
    frameHash:
        '39661e4535c5b981da14a15b5dc9c51850d100231fc4bb41b4384fac4ef402bc',
    frameNumber: 5,
    pictureOrderCount: 58,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 11,
    interMacroblocks: 1,
    skippedMacroblocks: 3498,
  ),
  _ExpectedAu(
    decodeIndex: 31,
    presentationIndex: 32,
    nal: _au31,
    nalLength: 2235,
    nalHash: '253702cfb775a2f3d647f8a3041a8cdd0e80363daca8dce685c6bf061beec42c',
    frameHash:
        '40f34eff7435a61839e355ee643125143e8b99750f384054fcc558cc474d380a',
    frameNumber: 5,
    pictureOrderCount: 64,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 50,
    interMacroblocks: 110,
    skippedMacroblocks: 3350,
  ),
  _ExpectedAu(
    decodeIndex: 32,
    presentationIndex: 31,
    nal: _au32,
    nalLength: 70,
    nalHash: '2c60c9d69f239748e25d5e3f3fc9712f6aa8c98901039b4ea99942c2f68916f5',
    frameHash:
        '85942ffe92cf174bb9de0939442a51a0d25efa524c8e1a35a07ab16632aacb22',
    frameNumber: 6,
    pictureOrderCount: 62,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 9,
    interMacroblocks: 16,
    skippedMacroblocks: 3485,
  ),
  _ExpectedAu(
    decodeIndex: 33,
    presentationIndex: 34,
    nal: _au33,
    nalLength: 3717,
    nalHash: 'd1953bf929ffa7ea8398a6629c7b07421c1618c636c2b08aededb8417c1bac1e',
    frameHash:
        '85bec9f9ff6457eeccf2a925b1d88a650e484dc225db00e4a08b2893ffc6388d',
    frameNumber: 6,
    pictureOrderCount: 68,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 63,
    interMacroblocks: 113,
    skippedMacroblocks: 3334,
  ),
];

final List<_ExpectedAu> _au38To46 = <_ExpectedAu>[
  _ExpectedAu(
    decodeIndex: 38,
    presentationIndex: 37,
    nal: _au38,
    nalLength: 58,
    nalHash: 'fae9a15654ca43aac22cdf099d07c36ff637166c249711da33942e785c6bdefc',
    frameHash:
        '38d9ee16e29f64592b0ceaf4dcd3398b8ef7ee288dfee09fa4764a536b51a45f',
    frameNumber: 9,
    pictureOrderCount: 74,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 10,
    interMacroblocks: 4,
    skippedMacroblocks: 3496,
  ),
  _ExpectedAu(
    decodeIndex: 39,
    presentationIndex: 42,
    nal: _au39,
    nalLength: 227,
    nalHash: '7067cfef6ef85cf2ce9cc0d1fbe4cd073a39aa115ba6fc3fcf2314f5b4949acb',
    frameHash:
        '7860989529a78712d60ddccd48c3a6517525e891f4313a8de2714e5603473747',
    frameNumber: 9,
    pictureOrderCount: 84,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 15,
    interMacroblocks: 16,
    skippedMacroblocks: 3479,
  ),
  _ExpectedAu(
    decodeIndex: 40,
    presentationIndex: 40,
    nal: _au40,
    nalLength: 67,
    nalHash: '0582c6aaa2f95392a56cb0436f91b4b684428535f35f5f3200451c003c1c6ed2',
    frameHash:
        'c6258bff77a577ddd68410be57fb157c219f950650a54d8bdaad4f61c41fa2d2',
    frameNumber: 10,
    pictureOrderCount: 80,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 7,
    interMacroblocks: 12,
    skippedMacroblocks: 3491,
  ),
  _ExpectedAu(
    decodeIndex: 41,
    presentationIndex: 39,
    nal: _au41,
    nalLength: 57,
    nalHash: '457937816a3d9d9d489c70eeadb7ded9e4c17359cda7e72ef9cd5f405685a8ea',
    frameHash:
        '352cd06a9824dc2338f623d514d0c5e89a525f877aa3d7c6fce6fafd20b294d2',
    frameNumber: 11,
    pictureOrderCount: 78,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 6,
    interMacroblocks: 9,
    skippedMacroblocks: 3495,
  ),
  _ExpectedAu(
    decodeIndex: 42,
    presentationIndex: 41,
    nal: _au42,
    nalLength: 57,
    nalHash: 'd0e59090cb16ebcd4b9e04f0aeae2d0f4bd45154359c92a5d97ed9ef2a242788',
    frameHash:
        '89f8f380464b0abbe9e5a61480e41aa539f79b323a582960912d3a4ddd7ba54f',
    frameNumber: 11,
    pictureOrderCount: 82,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 6,
    interMacroblocks: 8,
    skippedMacroblocks: 3496,
  ),
  _ExpectedAu(
    decodeIndex: 43,
    presentationIndex: 43,
    nal: _au43,
    nalLength: 353,
    nalHash: 'cd37277f4f787590c266e50161d2b275a2d2f1b75f44483d6c2e8efa25e9e2dc',
    frameHash:
        '2c3ef734574ca02b9c984e2fabd2137f04f3edfb5d7b9192381e750bf0fbac8f',
    frameNumber: 11,
    pictureOrderCount: 86,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 19,
    interMacroblocks: 12,
    skippedMacroblocks: 3479,
  ),
  _ExpectedAu(
    decodeIndex: 44,
    presentationIndex: 44,
    nal: _au44,
    nalLength: 253,
    nalHash: '6cfb0d3ce3f3e2af00d855437158e416fc45463ae0d5c2a4a104165a8d3650ec',
    frameHash:
        'ade20c49961fa9e5b6cb8baeba88a04b54fad41856763900f6fd6a7479a16d14',
    frameNumber: 12,
    pictureOrderCount: 88,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 14,
    interMacroblocks: 8,
    skippedMacroblocks: 3488,
  ),
  _ExpectedAu(
    decodeIndex: 45,
    presentationIndex: 45,
    nal: _au45,
    nalLength: 323,
    nalHash: 'f2df050c00d911175cc747670b1c185443a8cfe33d85c3b505fda40bff522134',
    frameHash:
        '4ad895d96c5d2809db8d0d2c075c056392888229e1b25345d8639704e1ba3f19',
    frameNumber: 13,
    pictureOrderCount: 90,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 20,
    interMacroblocks: 14,
    skippedMacroblocks: 3476,
  ),
  _ExpectedAu(
    decodeIndex: 46,
    presentationIndex: 47,
    nal: _au46,
    nalLength: 539,
    nalHash: '6588a59d0c7edcb2ccab7645cffd9b90a12a94bc16f93c8be35d3b6425464559',
    frameHash:
        '43f406ca8e23a7a62026897eddb7f50d3a0e652accfb65d7ef449e08ef5e077e',
    frameNumber: 14,
    pictureOrderCount: 94,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 20,
    interMacroblocks: 19,
    skippedMacroblocks: 3471,
  ),
];

final List<_ExpectedAu> _au48To54 = <_ExpectedAu>[
  _ExpectedAu(
    decodeIndex: 48,
    presentationIndex: 49,
    nal: _au48,
    nalLength: 512,
    nalHash: '701147c152bdb6ebe4f2f2961765f712d0688ce707e4219e429611d9f12cf35e',
    frameHash:
        'dccb30666c75951515d7d492fe4fefc651787e0a3b08d42961d3417a9e50f13a',
    frameNumber: 15,
    pictureOrderCount: 98,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 16,
    interMacroblocks: 46,
    skippedMacroblocks: 3448,
  ),
  _ExpectedAu(
    decodeIndex: 49,
    presentationIndex: 48,
    nal: _au49,
    nalLength: 134,
    nalHash: '82b1efabbe6a7bee66286a16eca647499dbbe6b3f2804cf94aa94c56bfeb02b0',
    frameHash:
        'a8270df6aac8f5d553261ce3da326237b279d6d702f358a958a37c7ce462b9c7',
    frameNumber: 0,
    pictureOrderCount: 96,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 4,
    interMacroblocks: 44,
    skippedMacroblocks: 3462,
  ),
  _ExpectedAu(
    decodeIndex: 50,
    presentationIndex: 53,
    nal: _au50,
    nalLength: 485,
    nalHash: '0b3526081afe97d8e5eb4c68a73a292071819502a115a506fea2035b438b1063',
    frameHash:
        'b58b3ceee15709ea54f70c27a12340739483dbc0b0e0b503035892015c0970ba',
    frameNumber: 0,
    pictureOrderCount: 106,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 23,
    interMacroblocks: 17,
    skippedMacroblocks: 3470,
  ),
  _ExpectedAu(
    decodeIndex: 51,
    presentationIndex: 51,
    nal: _au51,
    nalLength: 97,
    nalHash: '1ac23e52ad56fae12d43fa2b56a01227a01a8471cd7b9012b41627b548087682',
    frameHash:
        '7ceb24891e093d89213e808bca9ddf9307c2fc4e8be8a069a52997012a251326',
    frameNumber: 1,
    pictureOrderCount: 102,
    sliceType: H264SliceType.b,
    isReference: true,
    intraMacroblocks: 6,
    interMacroblocks: 49,
    skippedMacroblocks: 3455,
  ),
  _ExpectedAu(
    decodeIndex: 52,
    presentationIndex: 50,
    nal: _au52,
    nalLength: 86,
    nalHash: '866c130e669971c45ca0716e4f2f953a96edc00afebf5f18be22969e3975f230',
    frameHash:
        '9b32a5ef5264ae54014a8ef1faf7b25b97f69771351559b42196bc812940a54c',
    frameNumber: 2,
    pictureOrderCount: 100,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 11,
    interMacroblocks: 21,
    skippedMacroblocks: 3478,
  ),
  _ExpectedAu(
    decodeIndex: 53,
    presentationIndex: 52,
    nal: _au53,
    nalLength: 73,
    nalHash: '6dc6747c14d4083d7906c83cdf058cba27f5008630fd5f41a70880f1c99b8719',
    frameHash:
        'c13aaa8ae7b3b79bb9e9c78e8bb524ab863c0a4288cccfab08df86fa3c0c22d7',
    frameNumber: 2,
    pictureOrderCount: 104,
    sliceType: H264SliceType.b,
    isReference: false,
    intraMacroblocks: 6,
    interMacroblocks: 32,
    skippedMacroblocks: 3472,
  ),
  _ExpectedAu(
    decodeIndex: 54,
    presentationIndex: 55,
    nal: _au54,
    nalLength: 203,
    nalHash: 'c4f4bd4901f55089e1849b3c1b2bb551a0a38a7c5288f02883a86dc4817bcb76',
    frameHash:
        'f24e7497a96167f01635bb4a3938dfbaf06a33d6ffc393ab932661525eee62c4',
    frameNumber: 2,
    pictureOrderCount: 110,
    sliceType: H264SliceType.p,
    isReference: true,
    intraMacroblocks: 29,
    interMacroblocks: 4,
    skippedMacroblocks: 3477,
  ),
];

final class _ExpectedAu {
  const _ExpectedAu({
    required this.decodeIndex,
    required this.presentationIndex,
    required this.nal,
    required this.nalLength,
    required this.nalHash,
    required this.frameHash,
    required this.frameNumber,
    required this.pictureOrderCount,
    required this.sliceType,
    required this.isReference,
    required this.intraMacroblocks,
    required this.interMacroblocks,
    required this.skippedMacroblocks,
  });

  final int decodeIndex;
  final int presentationIndex;
  final Uint8List nal;
  final int nalLength;
  final String nalHash;
  final String frameHash;
  final int frameNumber;
  final int pictureOrderCount;
  final H264SliceType sliceType;
  final bool isReference;
  final int intraMacroblocks;
  final int interMacroblocks;
  final int skippedMacroblocks;
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
}

List<Uint8List> _splitNalBlob(Uint8List blob, List<int> lengths) {
  final output = <Uint8List>[];
  var offset = 0;
  for (final length in lengths) {
    final end = offset + length;
    if (length <= 0 || end > blob.length) {
      throw ArgumentError.value(lengths, 'lengths', 'Invalid NAL boundary');
    }
    output.add(Uint8List.sublistView(blob, offset, end));
    offset = end;
  }
  if (offset != blob.length) {
    throw ArgumentError.value(lengths, 'lengths', 'NAL blob has trailing data');
  }
  return List<Uint8List>.unmodifiable(output);
}

Uint8List _removedPicNum0Probe() {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(0) // P slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(6, 4) // frame_num
    ..writeBits(20, 6) // pic_order_cnt_lsb
    ..writeBit(1) // num_ref_idx_active_override_flag
    ..writeUe(0) // one active List0 entry
    ..writeBit(1) // ref_pic_list_modification_flag_l0
    ..writeUe(0) // modification_of_pic_nums_idc: subtract
    ..writeUe(5) // abs_diff_pic_num_minus1: CurrPicNum 6 -> PicNum 0
    ..writeUe(3) // end list modification
    ..writeUe(0) // luma_log2_weight_denom
    ..writeUe(0) // chroma_log2_weight_denom
    ..writeBit(0) // identity luma weight
    ..writeBit(0) // identity chroma weights
    ..writeBit(0) // adaptive_ref_pic_marking_mode_flag
    ..writeUe(0) // cabac_init_idc
    ..writeSe(-10) // SliceQPY 15
    ..writeUe(0) // disable_deblocking_filter_idc
    ..writeSe(0) // slice_alpha_c0_offset_div2
    ..writeSe(0); // slice_beta_offset_div2
  return _nalFromRbsp(0x41, bits.finishRbsp());
}

Uint8List _removedFrame2AfterAu12Probe() {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(0) // P slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(9, 4) // frame_num
    ..writeBits(28, 6) // pic_order_cnt_lsb
    ..writeBit(1) // num_ref_idx_active_override_flag
    ..writeUe(0) // one active List0 entry
    ..writeBit(1) // ref_pic_list_modification_flag_l0
    ..writeUe(0) // modification_of_pic_nums_idc: subtract
    ..writeUe(6) // abs_diff_pic_num_minus1: CurrPicNum 9 -> PicNum 2
    ..writeUe(3) // end list modification
    ..writeUe(0) // luma_log2_weight_denom
    ..writeUe(0) // chroma_log2_weight_denom
    ..writeBit(0) // identity luma weight
    ..writeBit(0) // identity chroma weights
    ..writeBit(0) // adaptive_ref_pic_marking_mode_flag
    ..writeUe(0) // cabac_init_idc
    ..writeSe(-10) // SliceQPY 15
    ..writeUe(0) // disable_deblocking_filter_idc
    ..writeSe(0) // slice_alpha_c0_offset_div2
    ..writeSe(0); // slice_beta_offset_div2
  return _nalFromRbsp(0x41, bits.finishRbsp());
}

Uint8List _removedAu25ReferenceProbe(int differenceOfPicNumsMinus1) {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(0) // P slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(3, 4) // next reference frame_num after AU25 frame2
    ..writeBits(54, 6) // monotonic type-0 pic_order_cnt_lsb candidate
    ..writeBit(1) // num_ref_idx_active_override_flag
    ..writeUe(0) // one active List0 entry
    ..writeBit(1) // ref_pic_list_modification_flag_l0
    ..writeUe(0) // modification_of_pic_nums_idc: subtract
    ..writeUe(differenceOfPicNumsMinus1)
    ..writeUe(3) // end list modification
    ..writeUe(0) // luma_log2_weight_denom
    ..writeUe(0) // chroma_log2_weight_denom
    ..writeBit(0) // identity luma weight
    ..writeBit(0) // identity chroma weights
    ..writeBit(0) // adaptive_ref_pic_marking_mode_flag
    ..writeUe(0) // cabac_init_idc
    ..writeSe(-10) // SliceQPY 15
    ..writeUe(0) // disable_deblocking_filter_idc
    ..writeSe(0) // slice_alpha_c0_offset_div2
    ..writeSe(0); // slice_beta_offset_div2
  return _nalFromRbsp(0x41, bits.finishRbsp());
}

Uint8List _removedAu36ReferenceProbe(int differenceOfPicNumsMinus1) {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(0) // P slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(9, 4) // next reference frame_num after AU36 frame8
    ..writeBits(14, 6) // monotonic type-0 POC candidate after POC72
    ..writeBit(1) // num_ref_idx_active_override_flag
    ..writeUe(0) // one active List0 entry
    ..writeBit(1) // ref_pic_list_modification_flag_l0
    ..writeUe(0) // modification_of_pic_nums_idc: subtract
    ..writeUe(differenceOfPicNumsMinus1)
    ..writeUe(3) // end list modification
    ..writeUe(0) // luma_log2_weight_denom
    ..writeUe(0) // chroma_log2_weight_denom
    ..writeBit(0) // identity luma weight
    ..writeBit(0) // identity chroma weights
    ..writeBit(0) // adaptive_ref_pic_marking_mode_flag
    ..writeUe(0) // cabac_init_idc
    ..writeSe(-10) // SliceQPY 15
    ..writeUe(0) // disable_deblocking_filter_idc
    ..writeSe(0) // slice_alpha_c0_offset_div2
    ..writeSe(0); // slice_beta_offset_div2
  return _nalFromRbsp(0x41, bits.finishRbsp());
}

Uint8List _removedAu91ReferenceProbe(int differenceOfPicNumsMinus1) {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(0) // P slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(7, 4) // next reference frame_num after AU91 frame6
    ..writeBits(58, 6) // monotonic type-0 POC candidate after POC180
    ..writeBit(1) // num_ref_idx_active_override_flag
    ..writeUe(0) // one active List0 entry
    ..writeBit(1) // ref_pic_list_modification_flag_l0
    ..writeUe(0) // modification_of_pic_nums_idc: subtract
    ..writeUe(differenceOfPicNumsMinus1)
    ..writeUe(3) // end list modification
    ..writeUe(0) // luma_log2_weight_denom
    ..writeUe(0) // chroma_log2_weight_denom
    ..writeBit(0) // identity luma weight
    ..writeBit(0) // identity chroma weights
    ..writeBit(0) // adaptive_ref_pic_marking_mode_flag
    ..writeUe(0) // cabac_init_idc
    ..writeSe(-10) // SliceQPY 15
    ..writeUe(0) // disable_deblocking_filter_idc
    ..writeSe(0) // slice_alpha_c0_offset_div2
    ..writeSe(0); // slice_beta_offset_div2
  return _nalFromRbsp(0x41, bits.finishRbsp());
}

Uint8List _removedAu123ReferenceProbe(int differenceOfPicNumsMinus1) {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(0) // P slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(3, 4) // next reference frame_num after AU123 frame2
    ..writeBits(60, 6) // monotonic type-0 POC candidate after POC246
    ..writeBit(1) // num_ref_idx_active_override_flag
    ..writeUe(0) // one active List0 entry
    ..writeBit(1) // ref_pic_list_modification_flag_l0
    ..writeUe(0) // modification_of_pic_nums_idc: subtract
    ..writeUe(differenceOfPicNumsMinus1)
    ..writeUe(3) // end list modification
    ..writeUe(0) // luma_log2_weight_denom
    ..writeUe(0) // chroma_log2_weight_denom
    ..writeBit(0) // identity luma weight
    ..writeBit(0) // identity chroma weights
    ..writeBit(0) // adaptive_ref_pic_marking_mode_flag
    ..writeUe(0) // cabac_init_idc
    ..writeSe(-10) // SliceQPY 15
    ..writeUe(0) // disable_deblocking_filter_idc
    ..writeSe(0) // slice_alpha_c0_offset_div2
    ..writeSe(0); // slice_beta_offset_div2
  return _nalFromRbsp(0x41, bits.finishRbsp());
}

Uint8List _nalFromRbsp(int header, Uint8List rbsp) {
  final escaped = <int>[header];
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

final class _BitWriter {
  final List<int> _bits = <int>[];

  void writeBit(int value) => _bits.add(value & 1);

  void writeBits(int value, int count) {
    for (var shift = count - 1; shift >= 0; shift--) {
      writeBit(value >> shift);
    }
  }

  void writeUe(int value) {
    final codeNum = value + 1;
    var significantBits = 0;
    for (var remaining = codeNum; remaining != 0; remaining >>= 1) {
      significantBits++;
    }
    for (var index = 1; index < significantBits; index++) {
      writeBit(0);
    }
    writeBits(codeNum, significantBits);
  }

  void writeSe(int value) => writeUe(value <= 0 ? -2 * value : 2 * value - 1);

  Uint8List finishRbsp() {
    writeBit(1);
    while ((_bits.length & 7) != 0) {
      writeBit(0);
    }
    final bytes = Uint8List(_bits.length >> 3);
    for (var index = 0; index < _bits.length; index++) {
      bytes[index >> 3] |= _bits[index] << (7 - (index & 7));
    }
    return bytes;
  }
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
