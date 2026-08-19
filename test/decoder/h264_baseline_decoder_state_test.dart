import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/h264_baseline_idr_decoder.dart';

void main() {
  group('H264BaselineDecoder reference lifecycle', () {
    test('rejects weighted P prediction instead of decoding wrong pixels', () {
      final decoder = H264BaselineDecoder();

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _sps(),
        _pps(weightedPrediction: true),
        _pSkip(frameNum: 1, weightedPrediction: true),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('Weighted P prediction'));
    });

    test('rejects a P picture after a missing reference picture', () {
      final decoder = H264BaselineDecoder();
      expect(
        decoder.decodeAccessUnit(<Uint8List>[_sps(), _pps(), _pcmIdr()]),
        isNotNull,
      );

      final frame = decoder.decodeAccessUnit(<Uint8List>[_pSkip(frameNum: 2)]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('frame_num gap'));
    });

    test('accepts the identity short-term reordering emitted by OpenH264', () {
      final decoder = H264BaselineDecoder();
      final idr = decoder.decodeAccessUnit(<Uint8List>[
        _sps(),
        _pps(),
        _pcmIdr(),
      ]);
      expect(idr, isNotNull);

      final predicted = decoder.decodeAccessUnit(<Uint8List>[
        _pSkip(frameNum: 1, modificationIdc: 0, modificationValue: 0),
      ]);

      expect(predicted, isNotNull, reason: decoder.lastError);
      expect(predicted!.y, everyElement(128));
      expect(predicted.u, everyElement(128));
      expect(predicted.v, everyElement(128));
    });

    test('rejects reordering that selects an unavailable reference', () {
      final decoder = H264BaselineDecoder();
      expect(
        decoder.decodeAccessUnit(<Uint8List>[_sps(), _pps(), _pcmIdr()]),
        isNotNull,
      );

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _pSkip(frameNum: 1, modificationIdc: 0, modificationValue: 1),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('unavailable PicNum'));
    });

    test('non-reference P pictures do not advance PrevRefFrameNum', () {
      final decoder = H264BaselineDecoder();
      expect(
        decoder.decodeAccessUnit(<Uint8List>[_sps(), _pps(), _pcmIdr()]),
        isNotNull,
      );

      expect(
        decoder.decodeAccessUnit(<Uint8List>[
          _pSkip(frameNum: 1, nalRefIdc: 0),
        ]),
        isNotNull,
      );
      expect(
        decoder.decodeAccessUnit(<Uint8List>[
          _pSkip(frameNum: 1, nalRefIdc: 2),
        ]),
        isNotNull,
        reason: decoder.lastError,
      );
    });

    test('rejects redundant pictures instead of treating them as primary', () {
      final decoder = H264BaselineDecoder();

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _sps(),
        _pps(redundantPicCntPresent: true),
        _pSkip(frameNum: 0, redundantPicCntPresent: true, redundantPicCnt: 1),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('Redundant pictures'));
    });

    test('rejects IDRs marked as long-term references', () {
      final decoder = H264BaselineDecoder();

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _sps(),
        _pps(),
        _pcmIdr(longTermReference: true),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('Long-term IDR'));
    });

    test('rejects adaptive marking even when its operation list is empty', () {
      final decoder = H264BaselineDecoder();
      expect(
        decoder.decodeAccessUnit(<Uint8List>[_sps(), _pps(), _pcmIdr()]),
        isNotNull,
      );

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _pSkip(frameNum: 1, adaptiveRefPicMarking: true),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('Adaptive reference marking'));
    });

    test('rejects slices with different IDR picture identifiers', () {
      final decoder = H264BaselineDecoder();

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _sps(),
        _pps(),
        _pcmIdr(idrPicId: 0),
        _pcmIdr(idrPicId: 1),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('different pictures'));
    });

    test('rejects slices with different nal_ref_idc values', () {
      final decoder = H264BaselineDecoder();

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _sps(),
        _pps(),
        _pcmIdr(nalRefIdc: 3),
        _pcmIdr(nalRefIdc: 2),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('different pictures'));
    });

    test('rejects slices with different picture-order fields', () {
      final decoder = H264BaselineDecoder();
      expect(
        decoder.decodeAccessUnit(<Uint8List>[
          _sps(picOrderCntType: 0),
          _pps(),
          _pcmIdr(picOrderCntLsb: 0),
        ]),
        isNotNull,
      );

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _pSkip(frameNum: 1, picOrderCntLsb: 2),
        _pSkip(frameNum: 1, picOrderCntLsb: 4),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('different pictures'));
    });

    test('rejects oversized SPS dimensions before picture allocation', () {
      final decoder = H264BaselineDecoder();

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _sps(widthInMbsMinus1: 256),
        _pps(),
        _pcmIdr(),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('configured limit'));
    });

    test('rejects pictures over the configured luma-sample budget', () {
      final decoder = H264BaselineDecoder();

      final frame = decoder.decodeAccessUnit(<Uint8List>[
        _sps(widthInMbsMinus1: 255, heightInMapUnitsMinus1: 144),
        _pps(),
        _pcmIdr(),
      ]);

      expect(frame, isNull);
      expect(decoder.lastError, contains('luma samples'));
    });
  });
}

Uint8List _sps({
  int picOrderCntType = 2,
  int widthInMbsMinus1 = 0,
  int heightInMapUnitsMinus1 = 0,
}) {
  final bits = _BitWriter()
    ..writeBits(66, 8) // profile_idc: Baseline
    ..writeBits(0, 8) // constraint flags and reserved bits
    ..writeBits(10, 8) // level_idc
    ..writeUe(0) // seq_parameter_set_id
    ..writeUe(0) // log2_max_frame_num_minus4 (MaxFrameNum=16)
    ..writeUe(picOrderCntType);
  if (picOrderCntType == 0) {
    bits.writeUe(0); // log2_max_pic_order_cnt_lsb_minus4
  } else if (picOrderCntType != 2) {
    throw ArgumentError.value(picOrderCntType, 'picOrderCntType');
  }
  bits
    ..writeUe(1) // max_num_ref_frames
    ..writeBit(0) // gaps_in_frame_num_value_allowed_flag
    ..writeUe(widthInMbsMinus1)
    ..writeUe(heightInMapUnitsMinus1)
    ..writeBit(1) // frame_mbs_only_flag
    ..writeBit(1) // direct_8x8_inference_flag
    ..writeBit(0) // frame_cropping_flag
    ..writeBit(0); // vui_parameters_present_flag
  return _nal(0x67, bits.finishRbsp());
}

Uint8List _pps({
  bool weightedPrediction = false,
  bool redundantPicCntPresent = false,
}) {
  final bits = _BitWriter()
    ..writeUe(0) // pic_parameter_set_id
    ..writeUe(0) // seq_parameter_set_id
    ..writeBit(0) // entropy_coding_mode_flag: CAVLC
    ..writeBit(0) // bottom_field_pic_order_in_frame_present_flag
    ..writeUe(0) // num_slice_groups_minus1
    ..writeUe(0) // num_ref_idx_l0_default_active_minus1
    ..writeUe(0) // num_ref_idx_l1_default_active_minus1
    ..writeBit(weightedPrediction ? 1 : 0)
    ..writeBits(0, 2) // weighted_bipred_idc
    ..writeSe(0) // pic_init_qp_minus26
    ..writeSe(0) // pic_init_qs_minus26
    ..writeSe(0) // chroma_qp_index_offset
    ..writeBit(0) // deblocking_filter_control_present_flag
    ..writeBit(0) // constrained_intra_pred_flag
    ..writeBit(redundantPicCntPresent ? 1 : 0);
  return _nal(0x68, bits.finishRbsp());
}

Uint8List _pcmIdr({
  int nalRefIdc = 3,
  int idrPicId = 0,
  int? picOrderCntLsb,
  bool redundantPicCntPresent = false,
  int redundantPicCnt = 0,
  bool longTermReference = false,
}) {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(2) // I slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(0, 4) // frame_num
    ..writeUe(idrPicId);
  if (picOrderCntLsb != null) bits.writeBits(picOrderCntLsb, 4);
  if (redundantPicCntPresent) bits.writeUe(redundantPicCnt);
  bits
    ..writeBit(0) // no_output_of_prior_pics_flag
    ..writeBit(longTermReference ? 1 : 0)
    ..writeSe(0) // slice_qp_delta
    ..writeUe(25) // I_PCM
    ..alignWithZero();
  for (var index = 0; index < 256 + 64 + 64; index++) {
    bits.writeBits(128, 8);
  }
  return _nal((nalRefIdc << 5) | 5, bits.finishRbsp());
}

Uint8List _pSkip({
  required int frameNum,
  int nalRefIdc = 2,
  bool weightedPrediction = false,
  int? modificationIdc,
  int modificationValue = 0,
  int? picOrderCntLsb,
  bool redundantPicCntPresent = false,
  int redundantPicCnt = 0,
  bool adaptiveRefPicMarking = false,
}) {
  final bits = _BitWriter()
    ..writeUe(0) // first_mb_in_slice
    ..writeUe(0) // P slice
    ..writeUe(0) // pic_parameter_set_id
    ..writeBits(frameNum, 4);
  if (picOrderCntLsb != null) bits.writeBits(picOrderCntLsb, 4);
  if (redundantPicCntPresent) bits.writeUe(redundantPicCnt);
  bits.writeBit(0); // num_ref_idx_active_override_flag

  if (modificationIdc == null) {
    bits.writeBit(0); // ref_pic_list_modification_flag_l0
  } else {
    bits
      ..writeBit(1)
      ..writeUe(modificationIdc)
      ..writeUe(modificationValue)
      ..writeUe(3); // end of list modification syntax
  }

  if (weightedPrediction) {
    bits
      ..writeUe(0) // luma_log2_weight_denom
      ..writeUe(0) // chroma_log2_weight_denom
      ..writeBit(0) // luma_weight_l0_flag[0]
      ..writeBit(0); // chroma_weight_l0_flag[0]
  }
  if (nalRefIdc != 0) {
    bits.writeBit(adaptiveRefPicMarking ? 1 : 0);
    if (adaptiveRefPicMarking) {
      bits.writeUe(0); // end of memory-management operations
    }
  }
  bits
    ..writeSe(0) // slice_qp_delta
    ..writeUe(1); // mb_skip_run
  return _nal((nalRefIdc << 5) | 1, bits.finishRbsp());
}

Uint8List _nal(int header, Uint8List rbsp) {
  final output = <int>[header];
  var zeroCount = 0;
  for (final byte in rbsp) {
    if (zeroCount >= 2 && byte <= 3) {
      output.add(3);
      zeroCount = 0;
    }
    output.add(byte);
    zeroCount = byte == 0 ? zeroCount + 1 : 0;
  }
  return Uint8List.fromList(output);
}

class _BitWriter {
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

  void alignWithZero() {
    while (_bits.isNotEmpty && (_bits.length & 7) != 0) {
      writeBit(0);
    }
  }

  Uint8List finishRbsp() {
    writeBit(1);
    alignWithZero();
    final bytes = Uint8List(_bits.length >> 3);
    for (var index = 0; index < _bits.length; index++) {
      bytes[index >> 3] |= _bits[index] << (7 - (index & 7));
    }
    return bytes;
  }
}
