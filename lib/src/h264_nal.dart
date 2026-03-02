import 'dart:typed_data';

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

      // include the IDR slice + possible additional slices/SEI until next AUD or next IDR
      while (i < nals.length) {
        final tt = nalType(nals[i]);
        if (i != 0 && (tt == 9 || tt == 5) && au.length > 0 && (tt == 9)) {
          // AUD indicates next access unit boundary
          break;
        }
        au.add(nals[i]);
        i++;
        // stop if next is AUD (9)
        if (i < nals.length && nalType(nals[i]) == 9) break;
      }

      aus.add(AccessUnit(au, isIdr: true));
      continue;
    }

    i++;
  }

  return aus;
}
