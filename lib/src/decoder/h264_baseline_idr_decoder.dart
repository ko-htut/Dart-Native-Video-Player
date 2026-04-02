import 'package:flutter/foundation.dart';

import '../yuv.dart';
import 'bitreader.dart';
import 'exp_golomb.dart';
import 'rbsp.dart';
import 'sps.dart';
import 'pps.dart';
import 'nc_context.dart';
import 'cavlc.dart';
import 'inv_transform.dart';
import 'intra16_dc.dart';
import 'intra_pred.dart';
import 'intra4x4_mpm.dart';
import 'chroma_pred.dart';

const bool _kAlignDebug = true;
const int _kAlignDebugMaxMb = 256;
const int _kAlignDebugMaxLines = 4000;
const bool _kStopOnFirstMbError = false;
const bool _kStopOnUnsupportedMbType = true;

class _MbTrace {
  final int mbAddr;
  final int startBit;
  final Map<String, int> _cp = <String, int>{};

  _MbTrace(this.mbAddr, this.startBit) {
    _cp['mb_start'] = startBit;
  }

  void hit(String name, int bitPos) {
    _cp[name] = bitPos;
  }

  String summary() {
    final parts = <String>[];
    _cp.forEach((k, v) => parts.add('$k=$v'));
    return parts.join(',');
  }
}

class H264IdrDecoder {
  String? lastError;
  SpsInfo? _sps;
  PpsInfo? _pps;
  final Map<int, SpsInfo> _spsById = <int, SpsInfo>{};
  final Map<int, PpsInfo> _ppsById = <int, PpsInfo>{};
  int _alignLogCount = 0;

  // Frame-level storage for intra4x4 modes (needed for MPM across MB boundaries)
  late List<int> _frameIntra4x4Modes; // length = mbCount * 16

  // H.264 Table 9-4(a) coded_block_pattern mapping for Intra4x4/Intra8x8.
  static const List<int> _cbpIntraMap = <int>[
    47,
    31,
    15,
    0,
    23,
    27,
    29,
    30,
    7,
    11,
    13,
    14,
    39,
    43,
    45,
    46,
    16,
    3,
    5,
    10,
    12,
    19,
    21,
    26,
    28,
    35,
    37,
    42,
    44,
    1,
    2,
    4,
    8,
    17,
    18,
    20,
    24,
    6,
    9,
    22,
    25,
    32,
    33,
    34,
    36,
    40,
    38,
    41,
  ];

  // residual_luma() syntax order is by 8x8 group, then 4x4 blocks in each group.
  static const List<List<int>> _luma4x4ParseOrderBy8x8 = <List<int>>[
    <int>[0, 1, 4, 5], // top-left 8x8
    <int>[2, 3, 6, 7], // top-right 8x8
    <int>[8, 9, 12, 13], // bottom-left 8x8
    <int>[10, 11, 14, 15], // bottom-right 8x8
  ];

  bool _shouldLogMbAlign(int mbAddr) {
    if (!_kAlignDebug) return false;
    return mbAddr < _kAlignDebugMaxMb || (mbAddr % 128) == 0;
  }

  void _alignLog(String msg) {
    if (!_kAlignDebug) return;
    if (_alignLogCount < _kAlignDebugMaxLines) {
      _alignLogCount++;
      debugPrint(msg);
      return;
    }
    if (_alignLogCount == _kAlignDebugMaxLines) {
      _alignLogCount++;
      debugPrint('[ALIGN] suppressing further alignment logs');
    }
  }

  void _logResidualStart({
    required BitReader br,
    required int mbAddr,
    required String label,
    required int nC,
    required int startIdx,
    required int maxCoeff,
  }) {
    if (!_shouldLogMbAlign(mbAddr)) return;
    _alignLog(
      '[ALIGN][RES-START] mb=$mbAddr bit=${br.bitPos} '
      'label=$label nC=$nC startIdx=$startIdx maxCoeff=$maxCoeff '
      'next24=${br.peekBitsStr(24)}',
    );
  }

  Yuv420Frame? decodeIdrAccessUnit(List<Uint8List> nals) {
    try {
      lastError = null;
      _alignLogCount = 0;
      int coeffDbgCount = 0;
      coeffTokenDebugLog = (message) {
        if (coeffDbgCount < 12) {
          coeffDbgCount++;
          debugPrint('[CAVLC] $message');
        }
      };

      // Parse SPS/PPS if present in this AU
      for (final nal in nals) {
        if (nal.isEmpty) continue;
        final t = nal[0] & 0x1F;
        if (t == 7) {
          final s = parseSpsNal(nal);
          _sps = s;
          _spsById[s.spsId] = s;
        }
        if (t == 8) {
          final p = parsePpsNal(nal);
          _pps = p;
          _ppsById[p.ppsId] = p;
          debugPrint(
            'entropyCodingModeFlag=${_pps!.entropyCodingModeFlag} '
            'ppsId=${_pps!.ppsId} spsId=${_pps!.spsId} '
            'sliceGroups=${_pps!.numSliceGroupsMinus1} mapType=${_pps!.sliceGroupMapType} '
            't8x8=${_pps!.transform8x8ModeFlag} '
            'deblock=${_pps!.deblockingFilterControlPresentFlag} '
            'redundant=${_pps!.redundantPicCntPresentFlag}',
          );
        }
      }

      final sps = _sps;
      final pps = _pps;
      if (sps == null || pps == null) {
        lastError = 'missing SPS/PPS for AU';
        return null;
      }

      // Collect all IDR slices in this AU (one frame may use multiple slices).
      final idrSlices = <Uint8List>[];
      for (final nal in nals) {
        if (nal.isNotEmpty && ((nal[0] & 0x1F) == 5)) {
          idrSlices.add(nal);
        }
      }
      if (idrSlices.isEmpty) {
        lastError = 'no IDR slices in AU';
        return null;
      }
      debugPrint('idrSlicesInAu=${idrSlices.length}');

      final w = sps.width;
      final h = sps.height;

      final y = Uint8List(w * h);
      final u = Uint8List((w >> 1) * (h >> 1));
      final v = Uint8List((w >> 1) * (h >> 1));

      // Neutral initialize
      y.fillRange(0, y.length, 128);
      u.fillRange(0, u.length, 128);
      v.fillRange(0, v.length, 128);

      final mbW = (w + 15) >> 4;
      final mbH = (h + 15) >> 4;
      final mbCount = mbW * mbH;

      _frameIntra4x4Modes = List<int>.filled(mbCount * 16, 2);

      final nc = NcContext(mbWidth: mbW, mbHeight: mbH);

      for (final idr in idrSlices) {
        try {
          _decodeIdrSlice(idr, sps, pps, y, u, v, nc, mbW, mbH);
        } catch (e, st) {
          lastError = 'slice decode error: $e';
          debugPrint('_decodeIdrSlice error: $e\n$st');
          break;
        }
      }
      return Yuv420Frame(width: w, height: h, y: y, u: u, v: v);
    } catch (e, st) {
      lastError = 'decode exception: $e';
      debugPrint('decodeIdrAccessUnit error: $e\n$st');
      // Fail-soft: caller can skip this AU and keep playback alive.
      return null;
    } finally {
      coeffTokenDebugLog = null;
      coeffTokenDebugContext = '';
    }
  }

  void _decodeIdrSlice(
    Uint8List idrNal,
    SpsInfo sps,
    PpsInfo pps,
    Uint8List yPlane,
    Uint8List uPlane,
    Uint8List vPlane,
    NcContext nc,
    int mbW,
    int mbH,
  ) {
    // Keep full NAL payload bytes. Trimming trailing 0x00 can corrupt valid
    // length-prefixed (MP4/avcC) NAL units and desync CAVLC bit parsing.
    final rbsp = ebspToRbsp(idrNal.sublist(1));
    final br = BitReader(rbsp);
    final sliceHdrStartBit = br.bitPos;
    final nalRefIdc = (idrNal[0] >> 5) & 0x03;
    final nalUnitType = idrNal[0] & 0x1F;
    final isIdr = nalUnitType == 5;

    // --- slice header (minimal) ---
    final firstMbInSlice = readUE(br);
    final rawSliceType = readUE(br);
    final sliceType = rawSliceType % 5; // 2 = I, 4 = SI
    final picParameterSetId = readUE(br);
    final ppsUsed = _ppsById[picParameterSetId] ?? pps;
    final spsUsed = _spsById[ppsUsed.spsId] ?? sps;
    br.readBits(spsUsed.log2MaxFrameNumMinus4 + 4); // frame_num
    debugPrint(
      '[SLICE] firstMb=$firstMbInSlice rawType=$rawSliceType type=$sliceType '
      'ppsId=$picParameterSetId ppsSpsId=${ppsUsed.spsId} '
      'cabac=${ppsUsed.entropyCodingModeFlag} t8x8=${ppsUsed.transform8x8ModeFlag}',
    );

    // This decoder only supports I/SI slices.
    if (sliceType != 2 && sliceType != 4) {
      debugPrint('[SLICE] skip unsupported sliceType=$sliceType');
      return;
    }
    if (ppsUsed.entropyCodingModeFlag) {
      debugPrint('[SLICE] skip CABAC ppsId=$picParameterSetId');
      return;
    }
    if (ppsUsed.numSliceGroupsMinus1 != 0) {
      debugPrint(
        '[SLICE] skip FMO ppsId=$picParameterSetId groups=${ppsUsed.numSliceGroupsMinus1}',
      );
      return;
    }
    if (ppsUsed.transform8x8ModeFlag) {
      debugPrint(
        '[SLICE] warning transform8x8 stream ppsId=$picParameterSetId (partial support)',
      );
    }

    bool fieldPicFlag = false;
    if (!spsUsed.frameMbsOnlyFlag) {
      fieldPicFlag = br.readBit() == 1;
      if (fieldPicFlag) br.readBit(); // bottom_field_flag
    }

    if (isIdr) {
      readUE(br); // idr_pic_id
    }

    if (spsUsed.picOrderCntType == 0) {
      br.readBits(spsUsed.log2MaxPicOrderCntLsbMinus4 + 4); // pic_order_cnt_lsb
      if (ppsUsed.bottomFieldPicOrderInFramePresentFlag && !fieldPicFlag) {
        readSE(br); // delta_pic_order_cnt_bottom
      }
    } else if (spsUsed.picOrderCntType == 1 &&
        !spsUsed.deltaPicOrderAlwaysZeroFlag) {
      readSE(br); // delta_pic_order_cnt[0]
      if (ppsUsed.bottomFieldPicOrderInFramePresentFlag && !fieldPicFlag) {
        readSE(br); // delta_pic_order_cnt[1]
      }
    }

    if (ppsUsed.redundantPicCntPresentFlag) {
      readUE(br); // redundant_pic_cnt
    }

    if (nalRefIdc != 0) {
      if (isIdr) {
        br.readBit(); // no_output_of_prior_pics_flag
        br.readBit(); // long_term_reference_flag
      }
    }

    if (ppsUsed.entropyCodingModeFlag && sliceType != 2 && sliceType != 4) {
      readUE(br); // cabac_init_idc (not expected in this decoder path)
    }
    final sliceQpDelta = readSE(br);

    if (ppsUsed.deblockingFilterControlPresentFlag) {
      final disableDeblockingFilterIdc = readUE(br);
      if (disableDeblockingFilterIdc != 1) {
        readSE(br); // slice_alpha_c0_offset_div2
        readSE(br); // slice_beta_offset_div2
      }
    }
    if (ppsUsed.numSliceGroupsMinus1 > 0 &&
        (ppsUsed.sliceGroupMapType == 3 ||
            ppsUsed.sliceGroupMapType == 4 ||
            ppsUsed.sliceGroupMapType == 5)) {
      final rate = ppsUsed.sliceGroupChangeRateMinus1 + 1;
      final picSizeInMapUnits = mbW * mbH;
      final x = ((picSizeInMapUnits + rate - 1) ~/ rate) + 1;
      int bits = 0;
      while ((1 << bits) < x) {
        bits++;
      }
      if (bits > 0) {
        br.readBits(bits); // slice_group_change_cycle
      }
    }
    final sliceHdrEndBit = br.bitPos;
    _alignLog(
      '[ALIGN][SLICE-HDR] firstMb=$firstMbInSlice ppsId=$picParameterSetId '
      'start=$sliceHdrStartBit end=$sliceHdrEndBit len=${sliceHdrEndBit - sliceHdrStartBit} '
      'bitsLeft=${br.bitsLeft} next24=${br.peekBitsStr(24)}',
    );

    int mbQpY = 26 + ppsUsed.picInitQpMinus26 + sliceQpDelta;
    if (mbQpY < 0) mbQpY = 0;
    if (mbQpY > 51) mbQpY = 51;

    final mbCount = mbW * mbH;
    int decodedMbs = 0;
    int intra4Count = 0;
    int intra16Count = 0;
    int pcmCount = 0;
    int unsupportedCount = 0;
    int mbErrorCount = 0;
    final unsupportedTypes = <int>[];

    int mbAddr = firstMbInSlice;
    if (mbAddr < 0) mbAddr = 0;
    if (mbAddr >= mbCount) return;

    bool sliceAborted = false;
    while (!br.eof && mbAddr < mbCount && moreRbspData(br)) {
      if (br.bitsLeft <= 0) {
        lastError = 'bitstream exhausted at mb=$mbAddr';
        break;
      }
      final mbTrace = _MbTrace(mbAddr, br.bitPos);
      if (_shouldLogMbAlign(mbAddr)) {
        _alignLog(
          '[ALIGN][MB-START] mb=$mbAddr bit=${br.bitPos} '
          'bitsLeft=${br.bitsLeft} next24=${br.peekBitsStr(24)}',
        );
      }
      try {
        final mbType = readUE(br);
        mbTrace.hit('after_mb_type', br.bitPos);
        final mbTypeVal = mbType;
        final mbX = mbAddr % mbW;
        final mbY = mbAddr ~/ mbW;
        final mbIndex = mbY * mbW + mbX;

        // I_PCM
        if (mbType == 25) {
          pcmCount++;
          br.byteAlign();
          final luma = br.readBytes(256);
          final cb = br.readBytes(64);
          final cr = br.readBytes(64);
          _writeIpcm(
            mbX,
            mbY,
            spsUsed.width,
            spsUsed.height,
            luma,
            cb,
            cr,
            yPlane,
            uPlane,
            vPlane,
          );

          // reset contexts for this MB
          nc.setLumaDc(mbX, mbY, 0);
          for (int i = 0; i < 16; i++) nc.setLuma(mbX, mbY, i, 0);
          for (int i = 0; i < 4; i++) {
            nc.setChromaU(mbX, mbY, i, 0);
            nc.setChromaV(mbX, mbY, i, 0);
          }
          for (int i = 0; i < 16; i++)
            _frameIntra4x4Modes[mbIndex * 16 + i] = 2;

          mbAddr++;
          decodedMbs++;
          continue;
        }

        final isIntra4x4 = (mbType == 0);
        final isIntra16x16 = (mbType >= 1 && mbType <= 24);

        if (!isIntra4x4 && !isIntra16x16) {
          if (_kStopOnUnsupportedMbType) {
            throw StateError(
              'unsupported mb_type=$mbType at mb=$mbAddr bit=${br.bitPos} '
              'cp=${mbTrace.summary()} next32=${br.peekBitsStr(32)}',
            );
          }
          unsupportedCount++;
          if (unsupportedTypes.length < 12) {
            unsupportedTypes.add(mbType);
          }
          if (!moreRbspData(br)) {
            break;
          }
          nc.setLumaDc(mbX, mbY, 0);
          for (int i = 0; i < 16; i++) nc.setLuma(mbX, mbY, i, 0);
          for (int i = 0; i < 4; i++) {
            nc.setChromaU(mbX, mbY, i, 0);
            nc.setChromaV(mbX, mbY, i, 0);
          }
          for (int i = 0; i < 16; i++)
            _frameIntra4x4Modes[mbIndex * 16 + i] = 2;
          mbAddr++;
          decodedMbs++;
          continue;
        }
        if (isIntra4x4) {
          intra4Count++;
        } else {
          intra16Count++;
        }

        // ---------- parse prediction modes + CBP ----------
        final intra4x4Modes = List<int>.filled(16, 2); // filled as we parse
        int intra16Mode = 2; // DC
        int intraChromaPredMode = 0; // DC
        int codedBlockPatternLuma = 0; // 0 => none
        int codedBlockPatternChroma = 0; // 0 => none
        int transform8x8Flag = 0;

        if (isIntra16x16) {
          final i16 = mbType - 1; // 0..23
          // I_16x16 mb_type encoding carries Intra16x16PredMode directly:
          // 0=Vertical, 1=Horizontal, 2=DC, 3=Plane.
          const i16PredModeMap = <int>[0, 1, 2, 3];
          intra16Mode = i16PredModeMap[i16 & 0x3];

          // Intra16x16 mb_type coding:
          // group = floor(i16/4) in 0..5, where:
          //   chroma = group % 3  (0..2)
          //   lumaAC = floor(group/3) (0 or 1) -> CodedBlockPatternLuma 0 or 15
          final group = i16 ~/ 4;
          codedBlockPatternChroma = group % 3; // 0..2
          codedBlockPatternLuma = (group ~/ 3) != 0 ? 15 : 0;

          intraChromaPredMode = readUE(br);
          if (intraChromaPredMode < 0 || intraChromaPredMode > 3) {
            intraChromaPredMode = 0;
          }
          mbTrace.hit('after_intra_pred', br.bitPos);
          mbTrace.hit('after_cbp', br.bitPos);
        } else {
          if (ppsUsed.transform8x8ModeFlag) {
            // Required syntax element for I_NxN when PPS enables 8x8 transform.
            transform8x8Flag = br.readBit();
          }

          // --- Correct Intra4x4 MPM parsing (B1.3) ---
          int getLeftMode(int blk) {
            final bx = blk & 3;
            final by = blk >> 2;
            if (bx > 0) return intra4x4Modes[blk - 1];
            if (mbX > 0) {
              // left MB, same block-row => block (by*4 + 3)
              final leftMbIndex = (mbY * mbW + (mbX - 1));
              return _frameIntra4x4Modes[leftMbIndex * 16 + (by * 4 + 3)];
            }
            return 2;
          }

          int getTopMode(int blk) {
            final bx = blk & 3;
            final by = blk >> 2;
            if (by > 0) return intra4x4Modes[blk - 4];
            if (mbY > 0) {
              // top MB bottom block row => blocks 12..15
              final topMbIndex = ((mbY - 1) * mbW + mbX);
              return _frameIntra4x4Modes[topMbIndex * 16 + (12 + bx)];
            }
            return 2;
          }

          if (transform8x8Flag == 1) {
            // Intra8x8 syntax: consume prediction mode bits to stay in sync.
            // Decode path remains 4x4-only for now; abort this slice gracefully.
            for (int b8 = 0; b8 < 4; b8++) {
              final prev = br.readBit();
              if (prev == 0) {
                br.readBits(3); // rem_intra8x8_pred_mode
              }
            }
            lastError = 'unsupported Intra8x8 residual (t8x8)';
            debugPrint(
              '[SLICE] abort unsupported Intra8x8 residual at mb=$mbAddr x=$mbX y=$mbY',
            );
            sliceAborted = true;
            break;
          } else {
            for (int b = 0; b < 16; b++) {
              final bx = b & 3;
              final by = b >> 2;

              final leftAvail = (bx > 0) || (mbX > 0);
              final topAvail = (by > 0) || (mbY > 0);

              final leftMode = getLeftMode(b);
              final topMode = getTopMode(b);

              final mpm = mostProbableIntra4x4Mode(
                leftAvail: leftAvail,
                topAvail: topAvail,
                leftMode: leftMode,
                topMode: topMode,
              );

              final prevFlag = br.readBit();
              if (prevFlag == 1) {
                intra4x4Modes[b] = mpm;
              } else {
                final rem = br.readBits(3); // 0..7
                intra4x4Modes[b] = mapRemToMode(mpm, rem); // 0..8
              }
            }
          }
          mbTrace.hit('after_intra_pred', br.bitPos);

          // Store modes for future MPM across MBs
          for (int i = 0; i < 16; i++) {
            _frameIntra4x4Modes[mbIndex * 16 + i] = intra4x4Modes[i];
          }

          intraChromaPredMode = readUE(br);
          if (intraChromaPredMode < 0 || intraChromaPredMode > 3) {
            intraChromaPredMode = 0;
          }

          // coded_block_pattern (UE)
          final cbpCodeNum = readUE(br);
          final cbp = (cbpCodeNum >= 0 && cbpCodeNum < _cbpIntraMap.length)
              ? _cbpIntraMap[cbpCodeNum]
              : 0;
          codedBlockPatternLuma = cbp & 0x0F; // 4 bits for luma
          codedBlockPatternChroma = (cbp >> 4) & 0x03; // 2 bits for chroma
          mbTrace.hit('after_cbp', br.bitPos);
        }

        // mb_qp_delta if any residual present
        int? mbQpDeltaVal;
        if (isIntra16x16 ||
            codedBlockPatternLuma != 0 ||
            codedBlockPatternChroma != 0) {
          final mbQpDelta = readSE(br);
          mbQpDeltaVal = mbQpDelta;
          mbQpY = (mbQpY + mbQpDelta + 104) % 52;
          mbTrace.hit('after_mb_qp_delta', br.bitPos);
        } else {
          mbTrace.hit('mb_qp_delta_skipped', br.bitPos);
        }

        // ---------- decode LUMA ----------
        mbTrace.hit('residual_start', br.bitPos);
        if (isIntra16x16) {
          // Intra16 pred
          final pred16 = List<int>.filled(256, 128);
          final yInts = yPlane.map((e) => e).toList();
          predictIntra16(
            mode: intra16Mode,
            mbX: mbX,
            mbY: mbY,
            width: spsUsed.width,
            height: spsUsed.height,
            yPlane: yInts,
            out16: pred16,
          );

          final resBlocks = List<List<int>>.generate(
            16,
            (_) => List<int>.filled(16, 0),
          );
          final coeffBlocks = List<List<int>>.generate(
            16,
            (_) => List<int>.filled(16, 0),
          );

          // Intra16x16 luma DC block is always present in syntax.
          final nCDc = nc.calcNCForLuma16Dc(mbX, mbY);
          coeffTokenDebugContext = 'mb=$mbAddr x=$mbX y=$mbY I16DC nC=$nCDc';
          _logResidualStart(
            br: br,
            mbAddr: mbAddr,
            label: 'I16DC',
            nC: nCDc,
            startIdx: 0,
            maxCoeff: 16,
          );
          final dc = decodeResidual4x4(br, nCDc);
          nc.setLumaDc(mbX, mbY, dc.totalCoeff);
          if (dc.coeffs.length >= 16) {
            for (int b = 0; b < 16; b++) {
              coeffBlocks[b][0] = dc.coeffs[b];
            }
          }

          // Parse I16 AC in residual_luma() syntax order.
          for (int g = 0; g < 4; g++) {
            final groupCoded = ((codedBlockPatternLuma >> g) & 1) != 0;
            final group = _luma4x4ParseOrderBy8x8[g];
            if (!groupCoded) {
              for (final blk in group) {
                nc.setLuma(mbX, mbY, blk, 0);
              }
              continue;
            }

            for (final blk in group) {
              final bx = blk & 3;
              final by = blk >> 2;
              final nCval = nc.calcNCForLuma4x4(mbX, mbY, bx, by);
              coeffTokenDebugContext =
                  'mb=$mbAddr x=$mbX y=$mbY I16AC blk=$blk bx=$bx by=$by nC=$nCval';
              _logResidualStart(
                br: br,
                mbAddr: mbAddr,
                label: 'I16AC blk=$blk',
                nC: nCval,
                startIdx: 1,
                maxCoeff: 15,
              );
              final r = decodeResidual4x4Ac(br, nCval);
              nc.setLuma(mbX, mbY, blk, r.totalCoeff);

              final coeff = r.coeffs;
              if (coeff.length >= 16) {
                for (int k = 1; k < 16; k++) {
                  coeffBlocks[blk][k] = coeff[k];
                }
              } else {
                for (int k = 1; k < coeff.length && k < 16; k++) {
                  coeffBlocks[blk][k] = coeff[k];
                }
              }
            }
          }

          // Intra16x16 luma DC path:
          // gather 16 block DCs, inverse Hadamard + scaling, then merge back.
          applyIntra16LumaDcHadamard(coeffBlocks);

          for (int b = 0; b < 16; b++) {
            resBlocks[b] = invTransform4x4(coeffBlocks[b], qp: mbQpY);
          }

          _writePredPlusRes16(
            mbX,
            mbY,
            spsUsed.width,
            spsUsed.height,
            pred16,
            resBlocks,
            yPlane,
          );

          // Intra16x16 doesn't set intra4x4 modes—set to DC for safety
          for (int i = 0; i < 16; i++)
            _frameIntra4x4Modes[mbIndex * 16 + i] = 2;
        } else {
          nc.setLumaDc(mbX, mbY, 0);
          // Parse residual first in residual_luma() syntax order.
          final coeffBlocks = List<List<int>>.generate(
            16,
            (_) => List<int>.filled(16, 0),
          );
          for (int g = 0; g < 4; g++) {
            final groupCoded = ((codedBlockPatternLuma >> g) & 1) != 0;
            final group = _luma4x4ParseOrderBy8x8[g];
            if (!groupCoded) {
              for (final blk in group) {
                nc.setLuma(mbX, mbY, blk, 0);
              }
              continue;
            }

            for (final blk in group) {
              final bx = blk & 3;
              final by = blk >> 2;
              final nCval = nc.calcNCForLuma4x4(mbX, mbY, bx, by);
              coeffTokenDebugContext =
                  'mb=$mbAddr x=$mbX y=$mbY I4 blk=$blk bx=$bx by=$by nC=$nCval';
              _logResidualStart(
                br: br,
                mbAddr: mbAddr,
                label: 'I4 blk=$blk',
                nC: nCval,
                startIdx: 0,
                maxCoeff: 16,
              );
              final r = decodeResidual4x4(br, nCval);
              nc.setLuma(mbX, mbY, blk, r.totalCoeff);
              if (r.coeffs.length >= 16) {
                coeffBlocks[blk] = List<int>.from(r.coeffs);
              } else {
                final safe = List<int>.filled(16, 0);
                for (int i = 0; i < r.coeffs.length; i++) {
                  safe[i] = r.coeffs[i];
                }
                coeffBlocks[blk] = safe;
              }
            }
          }

          // Intra4x4: reconstruct in raster order so neighbor pixels are ready.
          for (int by = 0; by < 4; by++) {
            for (int bx = 0; bx < 4; bx++) {
              final blk = by * 4 + bx;

              final top8 = _sampleTop8(
                yPlane,
                spsUsed.width,
                spsUsed.height,
                mbX,
                mbY,
                bx,
                by,
              );
              final left4 = _sampleLeft4(
                yPlane,
                spsUsed.width,
                spsUsed.height,
                mbX,
                mbY,
                bx,
                by,
              );
              final topLeft = _sampleTopLeft(
                yPlane,
                spsUsed.width,
                spsUsed.height,
                mbX,
                mbY,
                bx,
                by,
              );

              final pred4 = List<int>.filled(16, 128);
              predictIntra4x4(
                mode: intra4x4Modes[blk],
                top: top8,
                left: left4,
                topLeft: topLeft,
                out: pred4,
              );

              final res = invTransform4x4(coeffBlocks[blk], qp: mbQpY);

              _write4x4(
                mbX,
                mbY,
                bx,
                by,
                spsUsed.width,
                spsUsed.height,
                pred4,
                res,
                yPlane,
              );
            }
          }
        }

        // ---------- decode CHROMA 4:2:0 ----------
        _decodeChroma420(
          br,
          mbAddr,
          mbX,
          mbY,
          spsUsed.width,
          spsUsed.height,
          uPlane,
          vPlane,
          intraChromaPredMode,
          codedBlockPatternChroma,
          _calcQpC(mbQpY, ppsUsed.chromaQpIndexOffset),
          nc,
        );

        mbTrace.hit('mb_end', br.bitPos);
        if (br.bitPos <= mbTrace.startBit) {
          throw StateError(
            'macroblock consumed no bits '
            '(mb=$mbAddr start=${mbTrace.startBit} end=${br.bitPos} cp=${mbTrace.summary()})',
          );
        }
        if (_shouldLogMbAlign(mbAddr)) {
          _alignLog(
            '[ALIGN][MB-END] mb=$mbAddr used=${br.bitPos - mbTrace.startBit} '
            'cp=${mbTrace.summary()} next16=${br.peekBitsStr(16)}',
          );
          _alignLog(
            '[ALIGN][MB-META] mb=$mbAddr type=$mbTypeVal '
            'i16=$isIntra16x16 cbpL=$codedBlockPatternLuma cbpC=$codedBlockPatternChroma '
            'chromaPred=$intraChromaPredMode mbQpY=$mbQpY mbQpDelta=${mbQpDeltaVal ?? 'skip'}',
          );
        }

        mbAddr++;
        decodedMbs++;
      } catch (e, st) {
        mbErrorCount++;
        lastError = 'slice parse error at mb=$mbAddr: $e';
        _alignLog(
          '[ALIGN][MB-ERR] mb=$mbAddr bit=${br.bitPos} bitsLeft=${br.bitsLeft} '
          'cp=${mbTrace.summary()} next32=${br.peekBitsStr(32)} err=$e',
        );
        if (_kStopOnFirstMbError) {
          debugPrint('[SLICE] abort on first mb error at mb=$mbAddr: $e');
          sliceAborted = true;
          break;
        }
        if (mbErrorCount <= 16) {
          debugPrint('[SLICE] recover at mb=$mbAddr: $e\n$st');
        } else if (mbErrorCount == 17) {
          debugPrint('[SLICE] recover: suppressing further MB error traces');
        }

        // Keep decoder running: neutralize this MB context and advance.
        final mbX = mbAddr % mbW;
        final mbY = mbAddr ~/ mbW;
        final mbIndex = mbY * mbW + mbX;
        nc.setLumaDc(mbX, mbY, 0);
        for (int i = 0; i < 16; i++) {
          nc.setLuma(mbX, mbY, i, 0);
          _frameIntra4x4Modes[mbIndex * 16 + i] = 2;
        }
        for (int i = 0; i < 4; i++) {
          nc.setChromaU(mbX, mbY, i, 0);
          nc.setChromaV(mbX, mbY, i, 0);
        }

        mbAddr++;
        decodedMbs++;

        // Hard-stop if stream is fully exhausted or too damaged.
        if (br.eof || mbErrorCount > (mbCount >> 1)) {
          sliceAborted = true;
          break;
        }
        continue;
      }
    }

    debugPrint(
      '[SLICE] decoded mbs=$mbAddr / $mbCount moreRbsp=${moreRbspData(br)} bitsLeft=${br.bitsLeft}',
    );
    _alignLog(
      '[ALIGN][SLICE-END] decodedMbs=$decodedMbs mbAddr=$mbAddr '
      'bit=${br.bitPos} bitsLeft=${br.bitsLeft} moreRbsp=${moreRbspData(br)} '
      'next32=${br.peekBitsStr(32)}',
    );
    debugPrint(
      '[IDR] firstMb=$firstMbInSlice ${spsUsed.width}x${spsUsed.height} mbs=$decodedMbs/$mbCount '
      'i4=$intra4Count i16=$intra16Count pcm=$pcmCount '
      'unsupported=$unsupportedCount types=$unsupportedTypes eof=${br.eof}',
    );
    if (sliceAborted && lastError == null) {
      lastError = 'slice aborted';
    }
  }

  // ===============================
  // Chroma decode (simple B1.2/B1.3)
  // ===============================
  void _decodeChroma420(
    BitReader br,
    int mbAddr,
    int mbX,
    int mbY,
    int w,
    int h,
    Uint8List u,
    Uint8List v,
    int intraChromaPredMode,
    int codedBlockPatternChroma,
    int chromaQp,
    NcContext nc,
  ) {
    final predU = predictIntraChroma8x8(
      mode: intraChromaPredMode,
      plane: u,
      width: w,
      height: h,
      mbX: mbX,
      mbY: mbY,
    );
    final predV = predictIntraChroma8x8(
      mode: intraChromaPredMode,
      plane: v,
      width: w,
      height: h,
      mbX: mbX,
      mbY: mbY,
    );

    final coeffU = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
    final coeffV = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));

    List<int> dcU = List<int>.filled(4, 0);
    List<int> dcV = List<int>.filled(4, 0);
    if (codedBlockPatternChroma > 0) {
      coeffTokenDebugContext = 'mb=$mbAddr x=$mbX y=$mbY ChromaDC U';
      _logResidualStart(
        br: br,
        mbAddr: mbAddr,
        label: 'ChromaDC U',
        nC: -1,
        startIdx: 0,
        maxCoeff: 4,
      );
      dcU = inverseChromaDc2x2(decodeChromaDC2x2(br).coeffs4);
      coeffTokenDebugContext = 'mb=$mbAddr x=$mbX y=$mbY ChromaDC V';
      _logResidualStart(
        br: br,
        mbAddr: mbAddr,
        label: 'ChromaDC V',
        nC: -1,
        startIdx: 0,
        maxCoeff: 4,
      );
      dcV = inverseChromaDc2x2(decodeChromaDC2x2(br).coeffs4);
    }

    if (codedBlockPatternChroma == 2) {
      // residual() syntax is component-major for chroma AC:
      // decode all Cb(=U) blocks first, then all Cr(=V) blocks.
      for (int blk = 0; blk < 4; blk++) {
        final bx = blk & 1;
        final by = blk >> 1;
        final nCu = nc.calcNCForChroma4x4(
          mbX: mbX,
          mbY: mbY,
          bx: bx,
          by: by,
          isU: true,
        );
        coeffTokenDebugContext =
            'mb=$mbAddr x=$mbX y=$mbY ChromaAC U blk=$blk bx=$bx by=$by nC=$nCu';
        _logResidualStart(
          br: br,
          mbAddr: mbAddr,
          label: 'ChromaAC U blk=$blk',
          nC: nCu,
          startIdx: 1,
          maxCoeff: 15,
        );
        final rU = decodeResidual4x4Ac(br, nCu);
        nc.setChromaU(mbX, mbY, blk, rU.totalCoeff);
        if (rU.coeffs.length >= 16) {
          coeffU[blk] = List<int>.from(rU.coeffs);
        } else {
          final safe = List<int>.filled(16, 0);
          for (int i = 0; i < rU.coeffs.length; i++) {
            safe[i] = rU.coeffs[i];
          }
          coeffU[blk] = safe;
        }
      }

      for (int blk = 0; blk < 4; blk++) {
        final bx = blk & 1;
        final by = blk >> 1;
        final nCv = nc.calcNCForChroma4x4(
          mbX: mbX,
          mbY: mbY,
          bx: bx,
          by: by,
          isU: false,
        );
        coeffTokenDebugContext =
            'mb=$mbAddr x=$mbX y=$mbY ChromaAC V blk=$blk bx=$bx by=$by nC=$nCv';
        _logResidualStart(
          br: br,
          mbAddr: mbAddr,
          label: 'ChromaAC V blk=$blk',
          nC: nCv,
          startIdx: 1,
          maxCoeff: 15,
        );
        final rV = decodeResidual4x4Ac(br, nCv);
        nc.setChromaV(mbX, mbY, blk, rV.totalCoeff);
        if (rV.coeffs.length >= 16) {
          coeffV[blk] = List<int>.from(rV.coeffs);
        } else {
          final safe = List<int>.filled(16, 0);
          for (int i = 0; i < rV.coeffs.length; i++) {
            safe[i] = rV.coeffs[i];
          }
          coeffV[blk] = safe;
        }
      }
    } else {
      for (int i = 0; i < 4; i++) {
        nc.setChromaU(mbX, mbY, i, 0);
        nc.setChromaV(mbX, mbY, i, 0);
      }
    }

    mergeChromaDcIntoCoeffBlocks(coeffU, dcU);
    mergeChromaDcIntoCoeffBlocks(coeffV, dcV);

    final resU = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
    final resV = List<List<int>>.generate(4, (_) => List<int>.filled(16, 0));
    for (int i = 0; i < 4; i++) {
      resU[i] = invTransform4x4(coeffU[i], qp: chromaQp);
      resV[i] = invTransform4x4(coeffV[i], qp: chromaQp);
    }

    _writeChroma8x8PredRes(mbX, mbY, w, h, u, predU, resU);
    _writeChroma8x8PredRes(mbX, mbY, w, h, v, predV, resV);
  }

  void _writeChroma8x8PredRes(
    int mbX,
    int mbY,
    int w,
    int h,
    Uint8List plane,
    List<int> pred8x8,
    List<List<int>> resBlocks4x4,
  ) {
    final cw = w >> 1;
    final ch = h >> 1;
    final x0 = mbX * 8;
    final y0 = mbY * 8;

    for (int by = 0; by < 2; by++) {
      for (int bx = 0; bx < 2; bx++) {
        final blk = by * 2 + bx;
        final block = resBlocks4x4[blk];
        final baseX = x0 + bx * 4;
        final baseY = y0 + by * 4;

        for (int j = 0; j < 4; j++) {
          final yy = baseY + j;
          if (yy >= ch) continue;
          final row = yy * cw;
          final predRow = (by * 4 + j) * 8;
          for (int i = 0; i < 4; i++) {
            final xx = baseX + i;
            if (xx >= cw) continue;

            final pred = pred8x8[predRow + bx * 4 + i];
            final res = block[j * 4 + i];
            plane[row + xx] = clip8(pred + res);
          }
        }
      }
    }
  }

  int _calcQpC(int qpY, int chromaOffset) {
    int qPi = qpY + chromaOffset;
    if (qPi < 0) qPi = 0;
    if (qPi > 51) qPi = 51;
    if (qPi < 30) return qPi;
    const table = <int>[
      29,
      30,
      31,
      32,
      32,
      33,
      34,
      34,
      35,
      35,
      36,
      36,
      37,
      37,
      37,
      38,
      38,
      38,
      39,
      39,
      39,
      39,
    ];
    return table[qPi - 30];
  }

  // ===============================
  // Neighbor sampling helpers (safe)
  // ===============================
  List<int> _sampleTop8(
    Uint8List y,
    int w,
    int h,
    int mbX,
    int mbY,
    int bx,
    int by,
  ) {
    final out = List<int>.filled(8, 128);
    final x0 = mbX * 16 + bx * 4;
    final y0 = mbY * 16 + by * 4;
    if (y0 <= 0 || y0 - 1 >= h) return out;

    final row = (y0 - 1) * w;
    int last = 128;

    for (int i = 0; i < 8; i++) {
      final xx = x0 + i;
      if (xx >= 0 && xx < w) {
        last = y[row + xx];
        out[i] = last;
      } else {
        out[i] = last; // repeat last sample for top-right padding
      }
    }
    return out;
  }

  List<int> _sampleLeft4(
    Uint8List y,
    int w,
    int h,
    int mbX,
    int mbY,
    int bx,
    int by,
  ) {
    final out = List<int>.filled(4, 128);
    final x0 = mbX * 16 + bx * 4;
    final y0 = mbY * 16 + by * 4;
    if (x0 <= 0 || x0 - 1 >= w) return out;

    for (int j = 0; j < 4; j++) {
      final yy = y0 + j;
      if (yy >= 0 && yy < h) {
        out[j] = y[yy * w + (x0 - 1)];
      }
    }
    return out;
  }

  int _sampleTopLeft(
    Uint8List y,
    int w,
    int h,
    int mbX,
    int mbY,
    int bx,
    int by,
  ) {
    final x0 = mbX * 16 + bx * 4;
    final y0 = mbY * 16 + by * 4;
    if (x0 <= 0 || y0 <= 0) return 128;
    if (x0 - 1 >= w || y0 - 1 >= h) return 128;
    return y[(y0 - 1) * w + (x0 - 1)];
  }

  // ===============================
  // Write helpers
  // ===============================
  void _write4x4(
    int mbX,
    int mbY,
    int bx,
    int by,
    int w,
    int h,
    List<int> pred,
    List<int> res,
    Uint8List yPlane,
  ) {
    final x0 = mbX * 16 + bx * 4;
    final y0 = mbY * 16 + by * 4;

    for (int j = 0; j < 4; j++) {
      final yy = y0 + j;
      if (yy >= h) continue;
      final row = yy * w;
      for (int i = 0; i < 4; i++) {
        final xx = x0 + i;
        if (xx >= w) continue;
        yPlane[row + xx] = clip8(pred[j * 4 + i] + res[j * 4 + i]);
      }
    }
  }

  void _writePredPlusRes16(
    int mbX,
    int mbY,
    int w,
    int h,
    List<int> pred16,
    List<List<int>> resBlocks,
    Uint8List yOut,
  ) {
    final x0 = mbX * 16;
    final y0 = mbY * 16;

    for (int j = 0; j < 16; j++) {
      final yy = y0 + j;
      if (yy >= h) continue;
      final row = yy * w;
      for (int i = 0; i < 16; i++) {
        final xx = x0 + i;
        if (xx >= w) continue;
        final bx = i >> 2;
        final by = j >> 2;
        final bi = (j & 3) * 4 + (i & 3);
        final block = resBlocks[by * 4 + bx];
        yOut[row + xx] = clip8(pred16[j * 16 + i] + block[bi]);
      }
    }
  }

  void _writeIpcm(
    int mbX,
    int mbY,
    int w,
    int h,
    Uint8List luma,
    Uint8List cb,
    Uint8List cr,
    Uint8List y,
    Uint8List u,
    Uint8List v,
  ) {
    // luma 16x16
    final x0 = mbX * 16;
    final y0 = mbY * 16;
    for (int j = 0; j < 16; j++) {
      final yy = y0 + j;
      if (yy >= h) break;
      final row = yy * w;
      for (int i = 0; i < 16; i++) {
        final xx = x0 + i;
        if (xx >= w) break;
        y[row + xx] = luma[j * 16 + i];
      }
    }

    // chroma 8x8
    final cw = w >> 1;
    final ch = h >> 1;
    final cx0 = mbX * 8;
    final cy0 = mbY * 8;
    for (int j = 0; j < 8; j++) {
      final yy = cy0 + j;
      if (yy >= ch) break;
      final row = yy * cw;
      for (int i = 0; i < 8; i++) {
        final xx = cx0 + i;
        if (xx >= cw) break;
        u[row + xx] = cb[j * 8 + i];
        v[row + xx] = cr[j * 8 + i];
      }
    }
  }
}
