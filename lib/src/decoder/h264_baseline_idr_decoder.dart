import 'dart:typed_data';

import '../yuv.dart';
import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';
import 'sps.dart';
import 'pps.dart';
import 'cavlc.dart';
import 'intra16_recon.dart';

class H264IdrDecoderB11 {
  SpsInfo? _sps;
  PpsInfo? _pps;

  Yuv420Frame? decodeIdrAccessUnit(List<Uint8List> nals) {
    // parse SPS/PPS
    for (final nal in nals) {
      if (nal.isEmpty) continue;
      final t = nal[0] & 0x1F;
      if (t == 7) _sps = parseSpsNal(nal);
      if (t == 8) _pps = parsePpsNal(nal);
    }
    final sps = _sps;
    final pps = _pps;
    if (sps == null || pps == null) return null;
    if (pps.entropyCodingModeFlag) {
      // CABAC not supported
      return null;
    }

    // find IDR slice
    Uint8List? idr;
    for (final nal in nals) {
      if (nal.isNotEmpty && ((nal[0] & 0x1F) == 5)) {
        idr = nal;
        break;
      }
    }
    if (idr == null) return null;

    final w = sps.width;
    final h = sps.height;

    final y = Uint8List(w * h);
    final u = Uint8List((w >> 1) * (h >> 1));
    final v = Uint8List((w >> 1) * (h >> 1));
    // neutral chroma
    u.fillRange(0, u.length, 128);
    v.fillRange(0, v.length, 128);

    // decode slice (I16x16 only)
    final ok = _decodeIdrSliceI16Only(idr, sps, pps, y);
    if (!ok) {
      // at least show gray so UI doesn't break
      y.fillRange(0, y.length, 128);
    }

    return Yuv420Frame(width: w, height: h, y: y, u: u, v: v);
  }

  bool _decodeIdrSliceI16Only(
    Uint8List idrNal,
    SpsInfo sps,
    PpsInfo pps,
    Uint8List yPlane,
  ) {
    final rbsp = ebspToRbsp(idrNal.sublist(1));
    final br = BitReader(rbsp);

    // --- slice header (minimal) ---
    final firstMbInSlice = readUE(br);
    final sliceType = readUE(br); // I slice expected (2 or 7)
    readUE(br); // pic_parameter_set_id

    final frameNumBits = sps.log2MaxFrameNumMinus4 + 4;
    br.readBits(frameNumBits); // frame_num

    readUE(br); // idr_pic_id

    // QP init
    int qp = 26 + pps.picInitQpMinus26;

    final mbWidth = (sps.width + 15) >> 4;
    final mbHeight = (sps.height + 15) >> 4;
    final mbCount = mbWidth * mbHeight;

    int mbAddr = firstMbInSlice;
    if (mbAddr < 0) mbAddr = 0;
    if (mbAddr >= mbCount) return false;

    // For B1.1 we only handle I16x16 mb_type and I_PCM.
    while (!br.eof && mbAddr < mbCount) {
      final mbType = readUE(br);

      final mbX = mbAddr % mbWidth;
      final mbY = mbAddr ~/ mbWidth;

      if (mbType == 25) {
        // I_PCM (rare) - raw samples
        br.byteAlign();
        final luma = br.readBytes(256);
        if (luma.length < 256) return true;
        _writeRawLuma(mbX, mbY, sps.width, sps.height, luma, yPlane);
      } else if (mbType >= 1 && mbType <= 24) {
        // I16x16 mapping
        final intra16PredMode = (mbType - 1) % 4;
        final codedBlockPatternLuma = ((mbType - 1) ~/ 4) % 3; // 0..2
        // codedBlockPatternChroma ignored in B1.1
        // final codedBlockPatternChroma = ((mbType - 1) ~/ 12); // 0..1

        // mb_qp_delta present only if there are residuals
        final hasResidual = codedBlockPatternLuma != 0;
        if (hasResidual) {
          final mbQpDelta = readSE(br);
          qp = (qp + mbQpDelta) % 52;
          if (qp < 0) qp += 52;
        }

        // Prediction for this macroblock
        final pred16 = List<int>.filled(256, 128);
        predictIntra16(
          mode: intra16PredMode,
          mbX: mbX,
          mbY: mbY,
          width: sps.width,
          height: sps.height,
          pred: pred16,
          yPlane: yPlane.map((e) => e).toList(), // copy as int list
        );

        // Residual blocks
        final resBlocks = List<List<int>>.generate(
          16,
          (_) => List<int>.filled(16, 0),
        );

        if (hasResidual) {
          // nC estimation (very rough): use 0 for now (improves later with neighbor counting)
          // Still produces visible results for many streams.
          const nC = 0;

          for (int b = 0; b < 16; b++) {
            final coeffs = decodeResidual4x4(br, nC);
            final inv = invTransform4x4(coeffs);
            resBlocks[b] = inv;
          }
        }

        // Write to frame
        writeIntra16WithResidual(
          mbX: mbX,
          mbY: mbY,
          width: sps.width,
          height: sps.height,
          pred16: pred16,
          res4x4: resBlocks,
          yPlane: yPlane.map((e) => e).toList(), // int list target
        );

        // Copy back to Uint8List (fast path)
        _copyBackY(mbX, mbY, sps.width, sps.height, yPlane, pred16, resBlocks);
      } else {
        // Intra4x4 or other types not supported -> gray MB
        _fillGrayMb(mbX, mbY, sps.width, sps.height, yPlane);
      }

      mbAddr++;
    }

    // sliceType unused but kept to show parse
    // ignore: unused_local_variable
    final _ = sliceType;
    return true;
  }

  void _fillGrayMb(int mbX, int mbY, int w, int h, Uint8List y) {
    final x0 = mbX * 16;
    final y0 = mbY * 16;
    for (int j = 0; j < 16; j++) {
      final yy = y0 + j;
      if (yy >= h) break;
      final row = yy * w;
      for (int i = 0; i < 16; i++) {
        final xx = x0 + i;
        if (xx >= w) break;
        y[row + xx] = 128;
      }
    }
  }

  void _writeRawLuma(
    int mbX,
    int mbY,
    int w,
    int h,
    Uint8List luma,
    Uint8List y,
  ) {
    final x0 = mbX * 16;
    final y0 = mbY * 16;
    for (int j = 0; j < 16; j++) {
      final yy = y0 + j;
      if (yy >= h) break;
      final row = yy * w;
      final src = j * 16;
      for (int i = 0; i < 16; i++) {
        final xx = x0 + i;
        if (xx >= w) break;
        y[row + xx] = luma[src + i];
      }
    }
  }

  void _copyBackY(
    int mbX,
    int mbY,
    int w,
    int h,
    Uint8List yOut,
    List<int> pred16,
    List<List<int>> res,
  ) {
    // This keeps things simple; you can optimize later.
    final x0 = mbX * 16;
    final y0 = mbY * 16;

    for (int j = 0; j < 16; j++) {
      final yy = y0 + j;
      if (yy >= h) break;
      final row = yy * w;
      for (int i = 0; i < 16; i++) {
        final xx = x0 + i;
        if (xx >= w) break;
        // recompute from pred+res approx using block mapping
        final bx = i >> 2;
        final by = j >> 2;
        final bi = (i & 3) + ((j & 3) << 2);
        final block = res[by * 4 + bx];
        final val = pred16[j * 16 + i] + block[bi];
        yOut[row + xx] = val < 0 ? 0 : (val > 255 ? 255 : val);
      }
    }
  }
}
