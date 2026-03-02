import 'dart:typed_data';
import 'decoder/bitreader.dart';
import 'decoder/exp_golomb.dart';
import 'decoder/rbsp.dart';

int nalType(Uint8List nal) => nal.isEmpty ? -1 : (nal[0] & 0x1F);

class AccessUnit {
  final List<Uint8List> nals;
  final bool isIdr;
  AccessUnit(this.nals, {required this.isIdr});
}

/// Split Annex-B byte stream into NAL payloads (without start codes)
List<Uint8List> splitAnnexBNals(Uint8List es) {
  final nals = <Uint8List>[];

  int start = _findStartCode(es, 0);
  while (start != -1) {
    final scLen = (es[start + 2] == 1) ? 3 : 4;
    final nalStart = start + scLen;

    final next = _findStartCode(es, nalStart);
    final nalEnd = (next == -1) ? es.length : next;

    if (nalEnd > nalStart) {
      nals.add(es.sublist(nalStart, nalEnd));
    }
    start = next;
  }
  return nals;
}

int _findStartCode(Uint8List b, int from) {
  for (int i = from; i + 3 < b.length; i++) {
    if (b[i] == 0 && b[i + 1] == 0) {
      if (b[i + 2] == 1) return i;
      if (i + 4 < b.length && b[i + 2] == 0 && b[i + 3] == 1) return i;
    }
  }
  return -1;
}

/// Very simplified AU builder:
/// - Buffers SPS/PPS
/// - When sees IDR (type 5), emits AU containing latest SPS/PPS + that IDR (and following non-AUD NALs until next AUD/IDR)
List<AccessUnit> buildIdrAccessUnits(List<Uint8List> nals) {
  Uint8List? lastSps;
  Uint8List? lastPps;

  final aus = <AccessUnit>[];
  int i = 0;

  while (i < nals.length) {
    final t = nalType(nals[i]);

    if (t == 7) lastSps = nals[i];
    if (t == 8) lastPps = nals[i];

    if (t == 5) {
      final au = <Uint8List>[];
      if (lastSps != null) au.add(lastSps);
      if (lastPps != null) au.add(lastPps);
      bool sawIdrSlice = false;

      // Include IDR slices for one picture.
      // Stop on next AUD, non-IDR VCL, or next IDR that starts a new picture.
      while (i < nals.length) {
        final tt = nalType(nals[i]);
        if (tt == 9 && sawIdrSlice) {
          // AUD => next AU.
          break;
        }
        if (tt >= 1 && tt <= 5 && tt != 5 && sawIdrSlice) {
          // Non-IDR VCL => next picture.
          break;
        }

        if (tt == 5 && sawIdrSlice) {
          final firstMb = _tryReadFirstMbInSlice(nals[i]);
          if (firstMb == 0) {
            // New primary coded picture starts here.
            break;
          }
        }

        au.add(nals[i]);
        if (tt == 5) sawIdrSlice = true;
        i++;
      }

      aus.add(AccessUnit(au, isIdr: true));
      continue;
    }

    i++;
  }

  return aus;
}

int? _tryReadFirstMbInSlice(Uint8List nal) {
  try {
    if (nal.isEmpty) return null;
    if ((nal[0] & 0x1F) != 5) return null;
    final rbsp = ebspToRbsp(nal.sublist(1));
    final br = BitReader(rbsp);
    return readUE(br);
  } catch (_) {
    return null;
  }
}
