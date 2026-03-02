import 'dart:typed_data';
import '../yuv.dart';
import 'sps_parser.dart';

/// Milestone A decoder:
/// Input: Access Unit NALs [SPS,PPS,IDR,...]
/// Output: a single decoded YUV420 frame (IDR)
class H264BaselineIdrDecoder {
  SpsInfo? _sps;

  void pushParameterSets(List<Uint8List> nals) {
    for (final nal in nals) {
      final t = nal.isEmpty ? -1 : (nal[0] & 0x1F);
      if (t == 7) {
        _sps = parseSps(nal);
      }
    }
  }

  Yuv420Frame? decodeAccessUnit(List<Uint8List> nals) {
    pushParameterSets(nals);

    // TODO (core):
    // 1) Find IDR slice(s) (NAL type 5)
    // 2) Parse slice header (Exp-Golomb)
    // 3) Decode macroblocks (Intra only)
    // 4) CAVLC residual decode
    // 5) Inverse transform + prediction
    // 6) Output YUV420

    return null;
  }

  SpsInfo? get sps => _sps;
}
