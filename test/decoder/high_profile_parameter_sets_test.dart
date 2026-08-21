import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/bitreader.dart';
import 'package:ndvy_player/src/decoder/pps.dart';
import 'package:ndvy_player/src/decoder/scaling_list_syntax.dart';
import 'package:ndvy_player/src/decoder/sps.dart';

void main() {
  group('exact sfux High-profile parameter sets', () {
    final sps = parseSpsNal(
      _hex('67640028acd9c04e05be7f011000003e90000ea600f18319e0'),
    );
    final pps = parsePpsNal(
      _hex('68e9b8372c8b'),
      chromaFormatIdc: sps.chromaFormatIdc,
    );

    test('retains the profile-100 progressive 8-bit 4:2:0 SPS', () {
      expect((sps.spsId, sps.profileIdc, sps.levelIdc), (0, 100, 40));
      expect(sps.constraintFlags, 0);
      expect(sps.chromaFormatIdc, 1);
      expect(sps.separateColourPlaneFlag, isFalse);
      expect((sps.bitDepthLuma, sps.bitDepthChroma), (8, 8));
      expect(sps.qpprimeYZeroTransformBypassFlag, isFalse);
      expect(sps.isProgressive8Bit420, isTrue);
      expect(sps.isHighProfile8Bit420, isTrue);

      expect(sps.seqScalingMatrixPresentFlag, isFalse);
      expect(sps.usesFlatScalingMatrices, isTrue);
      expect(sps.hasExplicitScalingLists, isFalse);
      expect(sps.scalingLists, hasLength(8));
      expect(sps.scalingLists.map((list) => list.size), <int>[
        16,
        16,
        16,
        16,
        16,
        16,
        64,
        64,
      ]);
      expect(sps.scalingLists.every((list) => !list.present), isTrue);

      expect((sps.log2MaxFrameNumMinus4, sps.maxFrameNum), (0, 16));
      expect((sps.picOrderCntType, sps.maxPicOrderCntLsb), (0, 64));
      expect(sps.maxNumRefFrames, 6);
      expect((sps.codedWidth, sps.codedHeight), (1248, 720));
      expect((sps.width, sps.height), (1236, 720));
      expect(
        (
          sps.frameCropLeftOffset,
          sps.frameCropRightOffset,
          sps.frameCropTopOffset,
          sps.frameCropBottomOffset,
        ),
        (0, 6, 0, 0),
      );
      expect((sps.cropUnitX, sps.cropUnitY), (2, 2));
      expect(sps.direct8x8InferenceFlag, isTrue);
      expect(sps.vuiParametersPresentFlag, isTrue);
    });

    test('retains transform-8x8 with PPS scaling matrices absent', () {
      expect((pps.ppsId, pps.spsId), (0, 0));
      expect(pps.entropyCodingModeFlag, isTrue);
      expect(pps.bottomFieldPicOrderInFramePresentFlag, isFalse);
      expect(pps.numSliceGroupsMinus1, 0);
      expect(
        (
          pps.numRefIdxL0DefaultActiveMinus1,
          pps.numRefIdxL1DefaultActiveMinus1,
        ),
        (5, 0),
      );
      expect(pps.weightedPredFlag, isTrue);
      expect(pps.weightedBipredIdc, 2);
      expect((pps.picInitQpMinus26, pps.picInitQsMinus26), (-13, 0));
      expect(
        (pps.chromaQpIndexOffset, pps.secondChromaQpIndexOffset),
        (-2, -2),
      );
      expect(pps.deblockingFilterControlPresentFlag, isTrue);
      expect(pps.constrainedIntraPredFlag, isFalse);
      expect(pps.redundantPicCntPresentFlag, isFalse);
      expect(pps.transform8x8ModeFlag, isTrue);
      expect(pps.picScalingMatrixPresentFlag, isFalse);
      expect(pps.inheritsSequenceScalingMatrices, isTrue);
      expect(pps.hasExplicitScalingLists, isFalse);
      expect(pps.scalingLists, hasLength(8));
      expect(pps.scalingLists.every((list) => !list.present), isTrue);
    });
  });

  group('High-profile scaling-list retention', () {
    test('SPS retains an explicit 8x8 list in scan order', () {
      final sps = parseSpsNal(_highProfileSpsWithExplicitIntra8x8());

      expect(sps.seqScalingMatrixPresentFlag, isTrue);
      expect(sps.usesFlatScalingMatrices, isFalse);
      expect(sps.hasExplicitScalingLists, isTrue);
      expect(sps.scalingLists[6].present, isTrue);
      expect(sps.scalingLists[6].useDefaultScalingMatrixFlag, isFalse);
      expect(sps.scalingLists[6].scanValues, List<int>.filled(64, 16));
      expect(sps.scalingLists[7].present, isFalse);
      expect(
        () => sps.scalingLists[6].scanValues![0] = 1,
        throwsUnsupportedError,
      );
    });

    test('PPS retains an explicit transform-8x8 list in scan order', () {
      final pps = parsePpsNal(_ppsWithExplicitIntra8x8());

      expect(pps.transform8x8ModeFlag, isTrue);
      expect(pps.picScalingMatrixPresentFlag, isTrue);
      expect(pps.inheritsSequenceScalingMatrices, isFalse);
      expect(pps.hasExplicitScalingLists, isTrue);
      expect(pps.scalingLists, hasLength(8));
      expect(pps.scalingLists[6].scanValues, List<int>.filled(64, 16));
      expect(pps.scalingLists[7].present, isFalse);
    });

    test('distinguishes use-default syntax from an absent list', () {
      final writer = _BitWriter()..writeSe(-8);
      final parsed = H264ScalingListSyntax.parse(
        BitReader(writer.toBytes()),
        size: 64,
      );

      expect(parsed.present, isTrue);
      expect(parsed.useDefaultScalingMatrixFlag, isTrue);
      expect(parsed.isExplicit, isFalse);
      expect(parsed.scanValues, List<int>.filled(64, 8));
      expect(const H264ScalingListSyntax.absent(64).scanValues, isNull);
    });
  });

  group('parameter-set validation', () {
    test('rejects forbidden/reserved SPS header bits', () {
      final forbidden = _hex(
        'e7640028acd9c04e05be7f011000003e90000ea600f18319e0',
      );
      final reserved = _hex(
        '67640128acd9c04e05be7f011000003e90000ea600f18319e0',
      );

      expect(() => parseSpsNal(forbidden), throwsFormatException);
      expect(() => parseSpsNal(reserved), throwsFormatException);
    });

    test('rejects reserved weighted_bipred_idc and invalid trailing bits', () {
      expect(() => parsePpsNal(_hex('68e9bc372c8b')), throwsFormatException);
      expect(() => parsePpsNal(_hex('68e9b8372c8a')), throwsFormatException);
      expect(
        () => parsePpsNal(_hex('68e9b8372c8b'), chromaFormatIdc: 4),
        throwsArgumentError,
      );
    });

    test('rejects scaling-list deltas outside the normative range', () {
      final writer = _BitWriter()..writeSe(129);
      expect(
        () =>
            H264ScalingListSyntax.parse(BitReader(writer.toBytes()), size: 16),
        throwsFormatException,
      );
    });

    test('rejects max_num_ref_frames above the universal frame-DPB cap', () {
      expect(parseSpsNal(_spsWithMaxNumRefFrames(16)).maxNumRefFrames, 16);
      expect(
        () => parseSpsNal(_spsWithMaxNumRefFrames(17)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('max_num_ref_frames=17'),
          ),
        ),
      );
    });
  });
}

Uint8List _spsWithMaxNumRefFrames(int maxNumRefFrames) {
  final bits = _BitWriter()
    ..writeBits(66, 8) // profile_idc: Baseline
    ..writeBits(0, 8) // constraint flags and reserved_zero_2bits
    ..writeBits(10, 8) // level_idc
    ..writeUe(0) // seq_parameter_set_id
    ..writeUe(0) // log2_max_frame_num_minus4
    ..writeUe(2) // pic_order_cnt_type
    ..writeUe(maxNumRefFrames)
    ..writeBit(0) // gaps_in_frame_num_value_allowed_flag
    ..writeUe(0) // pic_width_in_mbs_minus1
    ..writeUe(0) // pic_height_in_map_units_minus1
    ..writeBit(1) // frame_mbs_only_flag
    ..writeBit(1) // direct_8x8_inference_flag
    ..writeBit(0) // frame_cropping_flag
    ..writeBit(0); // vui_parameters_present_flag
  return bits.toNal(7);
}

Uint8List _highProfileSpsWithExplicitIntra8x8() {
  final bits = _BitWriter()
    ..writeBits(100, 8) // profile_idc
    ..writeBits(0, 8) // constraint flags and reserved_zero_2bits
    ..writeBits(40, 8) // level_idc
    ..writeUe(0) // seq_parameter_set_id
    ..writeUe(1) // chroma_format_idc: 4:2:0
    ..writeUe(0) // bit_depth_luma_minus8
    ..writeUe(0) // bit_depth_chroma_minus8
    ..writeBit(0) // qpprime_y_zero_transform_bypass_flag
    ..writeBit(1); // seq_scaling_matrix_present_flag
  for (var index = 0; index < 8; index++) {
    bits.writeBit(index == 6 ? 1 : 0);
    if (index == 6) _writeFlat16ScalingList(bits, 64);
  }
  bits
    ..writeUe(0) // log2_max_frame_num_minus4
    ..writeUe(0) // pic_order_cnt_type
    ..writeUe(0) // log2_max_pic_order_cnt_lsb_minus4
    ..writeUe(1) // max_num_ref_frames
    ..writeBit(0) // gaps_in_frame_num_value_allowed_flag
    ..writeUe(0) // pic_width_in_mbs_minus1
    ..writeUe(0) // pic_height_in_map_units_minus1
    ..writeBit(1) // frame_mbs_only_flag
    ..writeBit(1) // direct_8x8_inference_flag
    ..writeBit(0) // frame_cropping_flag
    ..writeBit(0); // vui_parameters_present_flag
  return bits.toNal(7);
}

Uint8List _ppsWithExplicitIntra8x8() {
  final bits = _BitWriter()
    ..writeUe(0) // pic_parameter_set_id
    ..writeUe(0) // seq_parameter_set_id
    ..writeBit(1) // entropy_coding_mode_flag
    ..writeBit(0) // bottom_field_pic_order_in_frame_present_flag
    ..writeUe(0) // num_slice_groups_minus1
    ..writeUe(0) // num_ref_idx_l0_default_active_minus1
    ..writeUe(0) // num_ref_idx_l1_default_active_minus1
    ..writeBit(0) // weighted_pred_flag
    ..writeBits(0, 2) // weighted_bipred_idc
    ..writeSe(0) // pic_init_qp_minus26
    ..writeSe(0) // pic_init_qs_minus26
    ..writeSe(0) // chroma_qp_index_offset
    ..writeBit(1) // deblocking_filter_control_present_flag
    ..writeBit(0) // constrained_intra_pred_flag
    ..writeBit(0) // redundant_pic_cnt_present_flag
    ..writeBit(1) // transform_8x8_mode_flag
    ..writeBit(1); // pic_scaling_matrix_present_flag
  for (var index = 0; index < 8; index++) {
    bits.writeBit(index == 6 ? 1 : 0);
    if (index == 6) _writeFlat16ScalingList(bits, 64);
  }
  bits.writeSe(0); // second_chroma_qp_index_offset
  return bits.toNal(8);
}

void _writeFlat16ScalingList(_BitWriter writer, int size) {
  writer.writeSe(8); // lastScale 8 -> first scale 16.
  for (var index = 1; index < size; index++) {
    writer.writeSe(0);
  }
}

Uint8List _hex(String value) {
  if (value.length.isOdd) throw ArgumentError.value(value, 'value');
  return Uint8List.fromList(<int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ]);
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
    final width = codeNum.bitLength;
    for (var index = 1; index < width; index++) {
      writeBit(0);
    }
    writeBits(codeNum, width);
  }

  void writeSe(int value) => writeUe(value <= 0 ? -2 * value : 2 * value - 1);

  Uint8List toBytes() {
    final padded = List<int>.of(_bits);
    while (padded.length % 8 != 0) {
      padded.add(0);
    }
    return _pack(padded);
  }

  Uint8List toNal(int nalUnitType) {
    writeBit(1); // rbsp_stop_one_bit
    while (_bits.length % 8 != 0) {
      writeBit(0); // rbsp_alignment_zero_bit
    }
    return Uint8List.fromList(<int>[(3 << 5) | nalUnitType, ..._pack(_bits)]);
  }

  Uint8List _pack(List<int> bits) {
    return Uint8List.fromList(<int>[
      for (var offset = 0; offset < bits.length; offset += 8)
        bits
            .skip(offset)
            .take(8)
            .fold<int>(0, (byte, bit) => (byte << 1) | bit),
    ]);
  }
}
