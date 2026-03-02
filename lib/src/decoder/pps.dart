import 'dart:typed_data';
import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';

class PpsInfo {
  final int ppsId;
  final int spsId;
  final bool entropyCodingModeFlag; // false => CAVLC
  final int picInitQpMinus26;

  const PpsInfo({
    required this.ppsId,
    required this.spsId,
    required this.entropyCodingModeFlag,
    required this.picInitQpMinus26,
  });
}

PpsInfo parsePpsNal(Uint8List ppsNal) {
  final rbsp = ebspToRbsp(ppsNal.sublist(1));
  final br = BitReader(rbsp);

  final ppsId = readUE(br);
  final spsId = readUE(br);
  final entropyCodingModeFlag = br.readBit() == 1;
  br.readBit(); // bottom_field_pic_order_in_frame_present_flag

  final numSliceGroupsMinus1 = readUE(br);
  if (numSliceGroupsMinus1 != 0) {
    // Not supported in this milestone
    // You can still continue parsing roughly, but decode may fail.
  }

  readUE(br); // num_ref_idx_l0_default_active_minus1
  readUE(br); // num_ref_idx_l1_default_active_minus1
  br.readBit(); // weighted_pred_flag
  br.readBits(2); // weighted_bipred_idc
  final picInitQpMinus26 = readSE(br);
  readSE(br); // pic_init_qs_minus26
  readSE(br); // chroma_qp_index_offset
  br.readBit(); // deblocking_filter_control_present_flag
  br.readBit(); // constrained_intra_pred_flag
  br.readBit(); // redundant_pic_cnt_present_flag

  return PpsInfo(
    ppsId: ppsId,
    spsId: spsId,
    entropyCodingModeFlag: entropyCodingModeFlag,
    picInitQpMinus26: picInitQpMinus26,
  );
}
