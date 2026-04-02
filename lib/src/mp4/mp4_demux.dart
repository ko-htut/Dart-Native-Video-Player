import 'dart:typed_data';
import 'dart:convert';

class Mp4AvcConfig {
  final int nalLengthSize; // 1,2,4
  final List<Uint8List> sps;
  final List<Uint8List> pps;

  Mp4AvcConfig({
    required this.nalLengthSize,
    required this.sps,
    required this.pps,
  });
}

class Mp4VideoTrack {
  final int timescale;
  final Mp4AvcConfig avc;
  final List<int> sampleSizes;
  final List<int> sampleOffsets; // absolute file offsets per sample
  final List<int> dts; // decode timestamp in track timescale units per sample

  Mp4VideoTrack({
    required this.timescale,
    required this.avc,
    required this.sampleSizes,
    required this.sampleOffsets,
    required this.dts,
  });
}

class Mp4Demux {
  static Mp4VideoTrack parseH264Track(Uint8List fileBytes) {
    // Find moov box
    final moov = _findBox(fileBytes, 0, fileBytes.length, 'moov');
    if (moov == null) throw StateError('MP4: moov not found');

    // Find video trak by locating stsd->avc1
    final traks = _findBoxes(fileBytes, moov.dataStart, moov.end, 'trak');
    if (traks.isEmpty) throw StateError('MP4: no trak');

    _Box? videoTrak;
    for (final t in traks) {
      final stsd = _findBoxDeep(fileBytes, t.dataStart, t.end, 'stsd');
      if (stsd == null) continue;
      if (_stsdHasH264SampleEntry(fileBytes, stsd)) {
        videoTrak = t;
        break;
      }
    }
    if (videoTrak == null) throw StateError('MP4: video avc1 trak not found');

    // timescale (mdhd)
    final mdhd = _findBoxDeep(
      fileBytes,
      videoTrak.dataStart,
      videoTrak.end,
      'mdhd',
    );
    if (mdhd == null) throw StateError('MP4: mdhd not found');
    final timescale = _parseMdhdTimescale(fileBytes, mdhd);

    // avcC (inside avc1 sample entry)
    final avcC = _findAvcCInTrack(fileBytes, videoTrak);
    if (avcC == null) throw StateError('MP4: avcC not found');
    final avc = _parseAvcC(fileBytes.sublist(avcC.dataStart, avcC.end));

    // Sample tables
    final stsz = _findBoxDeep(
      fileBytes,
      videoTrak.dataStart,
      videoTrak.end,
      'stsz',
    );
    if (stsz == null) throw StateError('MP4: stsz not found');
    final sampleSizes = _parseStsz(fileBytes, stsz);

    final stco = _findBoxDeep(
      fileBytes,
      videoTrak.dataStart,
      videoTrak.end,
      'stco',
    );
    final co64 = _findBoxDeep(
      fileBytes,
      videoTrak.dataStart,
      videoTrak.end,
      'co64',
    );
    if (stco == null && co64 == null)
      throw StateError('MP4: stco/co64 not found');
    final chunkOffsets = stco != null
        ? _parseStco(fileBytes, stco)
        : _parseCo64(fileBytes, co64!);

    final stsc = _findBoxDeep(
      fileBytes,
      videoTrak.dataStart,
      videoTrak.end,
      'stsc',
    );
    if (stsc == null) throw StateError('MP4: stsc not found');
    final stscEntries = _parseStsc(fileBytes, stsc);

    final stts = _findBoxDeep(
      fileBytes,
      videoTrak.dataStart,
      videoTrak.end,
      'stts',
    );
    if (stts == null) throw StateError('MP4: stts not found');
    final dts = _buildDtsFromStts(fileBytes, stts, sampleSizes.length);

    // Build sample offsets from chunk layout
    final sampleOffsets = _buildSampleOffsets(
      sampleSizes: sampleSizes,
      chunkOffsets: chunkOffsets,
      stsc: stscEntries,
    );

    if (sampleOffsets.length != sampleSizes.length) {
      throw StateError(
        'MP4: sampleOffsets mismatch ${sampleOffsets.length} vs ${sampleSizes.length}',
      );
    }

    return Mp4VideoTrack(
      timescale: timescale,
      avc: avc,
      sampleSizes: sampleSizes,
      sampleOffsets: sampleOffsets,
      dts: dts,
    );
  }

  static List<Uint8List> readSampleNalUnits(
    Uint8List fileBytes,
    Mp4VideoTrack track,
    int sampleIndex,
  ) {
    final off = track.sampleOffsets[sampleIndex];
    final size = track.sampleSizes[sampleIndex];
    final sample = fileBytes.sublist(off, off + size);

    final out = <Uint8List>[];
    final br = _ByteReader(sample);

    while (br.remaining > 0) {
      final n = _readNalLength(br, track.avc.nalLengthSize);
      if (n <= 0 || n > br.remaining) {
        throw StateError('MP4: bad NAL length=$n remaining=${br.remaining}');
      }
      out.add(Uint8List.fromList(br.readBytes(n)));
    }

    return out;
  }
}

/* ----------------- helpers ----------------- */

int _readNalLength(_ByteReader br, int lenSize) {
  if (lenSize == 1) return br.readU8();
  if (lenSize == 2) return br.readU16();
  if (lenSize == 4) return br.readU32();
  throw StateError('Unsupported nalLengthSize=$lenSize');
}

Mp4AvcConfig _parseAvcC(Uint8List avcCData) {
  final br = _ByteReader(avcCData);
  final configurationVersion = br.readU8();
  if (configurationVersion != 1) throw StateError('avcC: version != 1');

  br.readU8(); // AVCProfileIndication
  br.readU8(); // profile_compatibility
  br.readU8(); // AVCLevelIndication

  final lengthSizeMinusOne = br.readU8() & 0x03;
  final nalLengthSize = lengthSizeMinusOne + 1;

  final numSps = br.readU8() & 0x1F;
  final sps = <Uint8List>[];
  for (int i = 0; i < numSps; i++) {
    final len = br.readU16();
    sps.add(Uint8List.fromList(br.readBytes(len)));
  }

  final numPps = br.readU8();
  final pps = <Uint8List>[];
  for (int i = 0; i < numPps; i++) {
    final len = br.readU16();
    pps.add(Uint8List.fromList(br.readBytes(len)));
  }

  return Mp4AvcConfig(nalLengthSize: nalLengthSize, sps: sps, pps: pps);
}

int _parseMdhdTimescale(Uint8List bytes, _Box mdhd) {
  final br = _ByteReader(bytes, offset: mdhd.dataStart);
  final version = br.readU8();
  br.readU24(); // flags

  if (version == 1) {
    br.readU64(); // creation
    br.readU64(); // modification
    final timescale = br.readU32();
    return timescale;
  } else {
    br.readU32(); // creation
    br.readU32(); // modification
    final timescale = br.readU32();
    return timescale;
  }
}

List<int> _parseStsz(Uint8List bytes, _Box stsz) {
  final br = _ByteReader(bytes, offset: stsz.dataStart);
  br.readU8();
  br.readU24(); // version + flags
  final sampleSize = br.readU32();
  final sampleCount = br.readU32();

  final sizes = <int>[];
  if (sampleSize != 0) {
    for (int i = 0; i < sampleCount; i++) sizes.add(sampleSize);
  } else {
    for (int i = 0; i < sampleCount; i++) sizes.add(br.readU32());
  }
  return sizes;
}

List<int> _parseStco(Uint8List bytes, _Box stco) {
  final br = _ByteReader(bytes, offset: stco.dataStart);
  br.readU8();
  br.readU24();
  final count = br.readU32();
  final out = <int>[];
  for (int i = 0; i < count; i++) out.add(br.readU32());
  return out;
}

List<int> _parseCo64(Uint8List bytes, _Box co64) {
  final br = _ByteReader(bytes, offset: co64.dataStart);
  br.readU8();
  br.readU24();
  final count = br.readU32();
  final out = <int>[];
  for (int i = 0; i < count; i++) out.add(br.readU64().toInt());
  return out;
}

class _StscEntry {
  final int firstChunk; // 1-based
  final int samplesPerChunk;
  _StscEntry(this.firstChunk, this.samplesPerChunk);
}

List<_StscEntry> _parseStsc(Uint8List bytes, _Box stsc) {
  final br = _ByteReader(bytes, offset: stsc.dataStart);
  br.readU8();
  br.readU24();
  final count = br.readU32();
  final out = <_StscEntry>[];
  for (int i = 0; i < count; i++) {
    final firstChunk = br.readU32();
    final samplesPerChunk = br.readU32();
    br.readU32(); // sample_description_index
    out.add(_StscEntry(firstChunk, samplesPerChunk));
  }
  return out;
}

List<int> _buildDtsFromStts(Uint8List bytes, _Box stts, int sampleCount) {
  final br = _ByteReader(bytes, offset: stts.dataStart);
  br.readU8();
  br.readU24();
  final entryCount = br.readU32();

  final dts = List<int>.filled(sampleCount, 0);
  int cur = 0;
  int acc = 0;

  for (int i = 0; i < entryCount; i++) {
    final count = br.readU32();
    final delta = br.readU32();
    for (int j = 0; j < count && cur < sampleCount; j++) {
      dts[cur] = acc;
      acc += delta;
      cur++;
    }
  }
  // If fewer filled, keep last acc stepping not required for our use.
  return dts;
}

List<int> _buildSampleOffsets({
  required List<int> sampleSizes,
  required List<int> chunkOffsets,
  required List<_StscEntry> stsc,
}) {
  // For each chunk, determine samplesPerChunk from stsc entries.
  int stscIdx = 0;

  final out = <int>[];
  int sampleIndex = 0;

  for (int chunkIndex0 = 0; chunkIndex0 < chunkOffsets.length; chunkIndex0++) {
    final chunkNumber = chunkIndex0 + 1; // 1-based
    while (stscIdx + 1 < stsc.length &&
        chunkNumber >= stsc[stscIdx + 1].firstChunk) {
      stscIdx++;
    }
    final spc = stsc[stscIdx].samplesPerChunk;

    int off = chunkOffsets[chunkIndex0];
    for (int i = 0; i < spc && sampleIndex < sampleSizes.length; i++) {
      out.add(off);
      off += sampleSizes[sampleIndex];
      sampleIndex++;
    }
    if (sampleIndex >= sampleSizes.length) break;
  }

  return out;
}

class _Box {
  final int start;
  final int end;
  final int headerSize;
  final String type;
  _Box(this.start, this.end, this.headerSize, this.type);
  int get dataStart => start + headerSize;
}

bool _stsdHasH264SampleEntry(Uint8List bytes, _Box stsd) {
  final br = _ByteReader(bytes, offset: stsd.dataStart);
  if (br.offset + 8 > stsd.end) return false;

  br.readU8(); // version
  br.readU24(); // flags
  final entryCount = br.readU32();

  for (int i = 0; i < entryCount && br.offset + 8 <= stsd.end; i++) {
    final entryStart = br.offset;
    final size = br.readU32();
    final typ = latin1.decode(br.readBytes(4));
    if (size < 8) return false;
    final entryEnd = entryStart + size;
    if (entryEnd > stsd.end) return false;

    if (typ == 'avc1' || typ == 'avc3') return true;
    br.offset = entryEnd;
  }
  return false;
}

_Box? _findAvcCInTrack(Uint8List bytes, _Box trak) {
  final stsd = _findBoxDeep(bytes, trak.dataStart, trak.end, 'stsd');
  if (stsd == null) return null;

  final br = _ByteReader(bytes, offset: stsd.dataStart);
  if (br.offset + 8 > stsd.end) return null;

  br.readU8(); // version
  br.readU24(); // flags
  final entryCount = br.readU32();

  for (int i = 0; i < entryCount && br.offset + 8 <= stsd.end; i++) {
    final entryStart = br.offset;
    final size = br.readU32();
    final typ = latin1.decode(br.readBytes(4));
    if (size < 8) return null;
    final entryEnd = entryStart + size;
    if (entryEnd > stsd.end) return null;

    if (typ == 'avc1' || typ == 'avc3') {
      // VisualSampleEntry fixed header is 78 bytes after size+type.
      int childStart = entryStart + 86;
      if (childStart > entryEnd) {
        childStart = entryStart + 8;
      }

      final avcC =
          _findBox(bytes, childStart, entryEnd, 'avcC') ??
          _findBoxDeep(bytes, childStart, entryEnd, 'avcC');
      if (avcC != null) return avcC;
    }

    br.offset = entryEnd;
  }

  // Fallback: search inside stsd payload after fullbox header.
  return _findBoxDeep(bytes, stsd.dataStart + 8, stsd.end, 'avcC');
}

_Box? _findBox(Uint8List bytes, int start, int end, String type) {
  final br = _ByteReader(bytes, offset: start);
  while (br.offset + 8 <= end) {
    final boxStart = br.offset;
    int size = br.readU32();
    final t = latin1.decode(br.readBytes(4));
    int headerSize = 8;

    if (size == 1) {
      size = br.readU64().toInt();
      headerSize = 16;
    } else if (size == 0) {
      size = end - boxStart;
    }
    if (size < headerSize) break;

    final boxEnd = boxStart + size;
    if (boxEnd > end) break;

    if (t == type) return _Box(boxStart, boxEnd, headerSize, t);
    br.offset = boxEnd;
  }
  return null;
}

List<_Box> _findBoxes(Uint8List bytes, int start, int end, String type) {
  final out = <_Box>[];
  final br = _ByteReader(bytes, offset: start);
  while (br.offset + 8 <= end) {
    final boxStart = br.offset;
    int size = br.readU32();
    final t = latin1.decode(br.readBytes(4));
    int headerSize = 8;

    if (size == 1) {
      size = br.readU64().toInt();
      headerSize = 16;
    } else if (size == 0) {
      size = end - boxStart;
    }
    if (size < headerSize) break;

    final boxEnd = boxStart + size;
    if (boxEnd > end) break;

    if (t == type) out.add(_Box(boxStart, boxEnd, headerSize, t));
    br.offset = boxEnd;
  }
  return out;
}

_Box? _findBoxDeep(Uint8List bytes, int start, int end, String type) {
  final direct = _findBox(bytes, start, end, type);
  if (direct != null) return direct;

  final br = _ByteReader(bytes, offset: start);
  while (br.offset + 8 <= end) {
    final boxStart = br.offset;
    int size = br.readU32();
    br.readBytes(4);
    int headerSize = 8;

    if (size == 1) {
      size = br.readU64().toInt();
      headerSize = 16;
    } else if (size == 0) {
      size = end - boxStart;
    }
    if (size < headerSize) break;

    final boxEnd = boxStart + size;
    if (boxEnd > end) break;

    final nested = _findBoxDeep(bytes, boxStart + headerSize, boxEnd, type);
    if (nested != null) return nested;

    br.offset = boxEnd;
  }
  return null;
}

class _ByteReader {
  final Uint8List b;
  int offset;
  _ByteReader(this.b, {this.offset = 0});

  int get remaining => b.length - offset;

  int readU8() => b[offset++];

  int readU16() {
    final v = (b[offset] << 8) | b[offset + 1];
    offset += 2;
    return v;
  }

  int readU24() {
    final v = (b[offset] << 16) | (b[offset + 1] << 8) | b[offset + 2];
    offset += 3;
    return v;
  }

  int readU32() {
    final v =
        (b[offset] << 24) |
        (b[offset + 1] << 16) |
        (b[offset + 2] << 8) |
        b[offset + 3];
    offset += 4;
    return v >>> 0;
  }

  int readU64() {
    final hi = readU32();
    final lo = readU32();
    return (hi * 4294967296) + lo;
  }

  List<int> readBytes(int n) {
    final out = b.sublist(offset, offset + n);
    offset += n;
    return out;
  }
}
