import 'dart:typed_data';
import 'dart:convert';

import '../audio/aac/audio_specific_config.dart';

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
  final List<int> sampleDurations;
  final List<int> pts; // presentation timestamp (DTS + CTTS offset)
  final int presentationTimeOffset;

  Mp4VideoTrack({
    required this.timescale,
    required this.avc,
    required this.sampleSizes,
    required this.sampleOffsets,
    required this.dts,
    List<int>? sampleDurations,
    List<int>? pts,
    this.presentationTimeOffset = 0,
  }) : sampleDurations =
           sampleDurations ??
           List<int>.filled(sampleSizes.length, 0, growable: false),
       pts = pts ?? List<int>.unmodifiable(dts);
}

/// AAC decoder configuration carried by an MP4 `mp4a` sample entry.
final class Mp4AacConfig {
  Mp4AacConfig({
    required this.objectTypeIndication,
    required this.config,
    required this.maxBitrate,
    required this.averageBitrate,
  });

  /// MPEG-4 systems object type. AAC commonly uses 0x40.
  final int objectTypeIndication;
  final AudioSpecificConfig config;
  final int maxBitrate;
  final int averageBitrate;
}

/// One AAC audio track and the classic MP4 sample tables needed to extract it.
final class Mp4AudioTrack {
  Mp4AudioTrack({
    required this.timescale,
    required this.channelCount,
    required this.sampleSizeBits,
    required this.sampleRate,
    required this.aac,
    required this.sampleSizes,
    required this.sampleOffsets,
    required this.dts,
    required this.sampleDurations,
    required this.pts,
    required this.presentationTimeOffset,
  });

  final int timescale;
  final int channelCount;
  final int sampleSizeBits;
  final int sampleRate;
  final Mp4AacConfig aac;
  AudioSpecificConfig get config => aac.config;
  final List<int> sampleSizes;
  final List<int> sampleOffsets;
  final List<int> dts;
  final List<int> sampleDurations;
  final List<int> pts;
  final int presentationTimeOffset;
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

    final table = _parseTrackSampleTable(fileBytes, videoTrak, timescale);

    return Mp4VideoTrack(
      timescale: timescale,
      avc: avc,
      sampleSizes: table.sampleSizes,
      sampleOffsets: table.sampleOffsets,
      dts: table.dts,
      sampleDurations: table.sampleDurations,
      pts: table.pts,
      presentationTimeOffset: table.presentationTimeOffset,
    );
  }

  /// Parses the first MPEG-4 AAC (`soun`/`mp4a`) track, if present.
  ///
  /// MP4 stores AAC samples without ADTS headers. [readAudioSample] therefore
  /// returns one raw AAC access unit configured by [Mp4AudioTrack.config].
  static Mp4AudioTrack? parseAacTrack(Uint8List fileBytes) {
    final moov = _findBox(fileBytes, 0, fileBytes.length, 'moov');
    if (moov == null) throw StateError('MP4: moov not found');

    final traks = _findBoxes(fileBytes, moov.dataStart, moov.end, 'trak');
    for (final trak in traks) {
      final handlerType = _trackHandlerType(fileBytes, trak);
      if (handlerType != null && handlerType != 'soun') continue;

      final entry = _findSampleEntryInTrack(fileBytes, trak, const <String>{
        'mp4a',
      });
      if (entry == null) continue;

      final audioEntry = _parseMp4aSampleEntry(fileBytes, entry);
      final esds = _findEsdsInAudioSampleEntry(fileBytes, entry);
      if (esds == null) {
        throw StateError('MP4: mp4a track has no esds box');
      }
      final aac = _parseEsds(fileBytes, esds);
      final mdhd = _findBoxDeep(fileBytes, trak.dataStart, trak.end, 'mdhd');
      if (mdhd == null) throw StateError('MP4: audio mdhd not found');
      final timescale = _parseMdhdTimescale(fileBytes, mdhd);
      final table = _parseTrackSampleTable(fileBytes, trak, timescale);

      if (audioEntry.sampleRate != aac.config.samplingFrequency) {
        throw FormatException(
          'MP4: mp4a sample rate ${audioEntry.sampleRate} disagrees with '
          'AudioSpecificConfig ${aac.config.samplingFrequency}',
        );
      }
      final configuredChannelCount = aac.config.channelCount;
      if (configuredChannelCount != null &&
          audioEntry.channelCount != configuredChannelCount) {
        throw FormatException(
          'MP4: mp4a channel count ${audioEntry.channelCount} disagrees with '
          'AudioSpecificConfig $configuredChannelCount',
        );
      }

      return Mp4AudioTrack(
        timescale: timescale,
        channelCount: audioEntry.channelCount,
        sampleSizeBits: audioEntry.sampleSizeBits,
        sampleRate: audioEntry.sampleRate,
        aac: aac,
        sampleSizes: table.sampleSizes,
        sampleOffsets: table.sampleOffsets,
        dts: table.dts,
        sampleDurations: table.sampleDurations,
        pts: table.pts,
        presentationTimeOffset: table.presentationTimeOffset,
      );
    }
    return null;
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

  static Uint8List readAudioSample(
    Uint8List fileBytes,
    Mp4AudioTrack track,
    int sampleIndex,
  ) {
    if (sampleIndex < 0 || sampleIndex >= track.sampleSizes.length) {
      throw RangeError.range(
        sampleIndex,
        0,
        track.sampleSizes.length - 1,
        'sampleIndex',
      );
    }
    final offset = track.sampleOffsets[sampleIndex];
    final end = offset + track.sampleSizes[sampleIndex];
    if (offset < 0 || end < offset || end > fileBytes.length) {
      throw FormatException(
        'MP4: audio sample $sampleIndex range $offset..$end is outside file',
      );
    }
    return Uint8List.fromList(fileBytes.sublist(offset, end));
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

_Mp4SampleTable _parseTrackSampleTable(
  Uint8List bytes,
  _Box trak,
  int trackTimescale,
) {
  final stsz = _findBoxDeep(bytes, trak.dataStart, trak.end, 'stsz');
  if (stsz == null) throw StateError('MP4: stsz not found');
  final sampleSizes = _parseStsz(bytes, stsz);

  final stco = _findBoxDeep(bytes, trak.dataStart, trak.end, 'stco');
  final co64 = _findBoxDeep(bytes, trak.dataStart, trak.end, 'co64');
  if (stco == null && co64 == null) {
    throw StateError('MP4: stco/co64 not found');
  }
  final chunkOffsets = stco != null
      ? _parseStco(bytes, stco)
      : _parseCo64(bytes, co64!);

  final stsc = _findBoxDeep(bytes, trak.dataStart, trak.end, 'stsc');
  if (stsc == null) throw StateError('MP4: stsc not found');
  final stscEntries = _parseStsc(bytes, stsc);
  if (sampleSizes.isNotEmpty && stscEntries.isEmpty) {
    throw const FormatException('MP4: stsc contains no entries');
  }

  final stts = _findBoxDeep(bytes, trak.dataStart, trak.end, 'stts');
  if (stts == null) throw StateError('MP4: stts not found');
  final timing = _parseStts(bytes, stts, sampleSizes.length);

  final sampleOffsets = _buildSampleOffsets(
    sampleSizes: sampleSizes,
    chunkOffsets: chunkOffsets,
    stsc: stscEntries,
  );
  if (sampleOffsets.length != sampleSizes.length) {
    throw StateError(
      'MP4: sampleOffsets mismatch ${sampleOffsets.length} vs '
      '${sampleSizes.length}',
    );
  }
  for (var i = 0; i < sampleOffsets.length; i++) {
    final end = sampleOffsets[i] + sampleSizes[i];
    if (sampleOffsets[i] < 0 || end < sampleOffsets[i] || end > bytes.length) {
      throw FormatException(
        'MP4: sample $i range ${sampleOffsets[i]}..$end is outside file',
      );
    }
  }

  final ctts = _findBoxDeep(bytes, trak.dataStart, trak.end, 'ctts');
  final compositionOffsets = ctts == null
      ? List<int>.filled(sampleSizes.length, 0, growable: false)
      : _parseCtts(bytes, ctts, sampleSizes.length);
  final presentationTimeOffset = _parseEditListPresentationOffset(
    bytes,
    trak,
    trackTimescale,
  );
  final pts = List<int>.generate(
    sampleSizes.length,
    (index) =>
        timing.dts[index] + compositionOffsets[index] + presentationTimeOffset,
    growable: false,
  );

  return _Mp4SampleTable(
    sampleSizes: List<int>.unmodifiable(sampleSizes),
    sampleOffsets: List<int>.unmodifiable(sampleOffsets),
    dts: List<int>.unmodifiable(timing.dts),
    sampleDurations: List<int>.unmodifiable(timing.durations),
    pts: List<int>.unmodifiable(pts),
    presentationTimeOffset: presentationTimeOffset,
  );
}

int _parseEditListPresentationOffset(
  Uint8List bytes,
  _Box trak,
  int trackTimescale,
) {
  final elst = _findBoxDeep(bytes, trak.dataStart, trak.end, 'elst');
  if (elst == null) return 0;
  final reader = _ByteReader(bytes, offset: elst.dataStart);
  final version = reader.readU8();
  reader.readU24();
  if (version != 0 && version != 1) {
    throw FormatException('MP4: unsupported elst version=$version');
  }
  final entryCount = reader.readU32();
  var leadingEmptyDuration = 0;

  for (var index = 0; index < entryCount; index++) {
    final segmentDuration = version == 1 ? reader.readU64() : reader.readU32();
    final mediaTime = version == 1 ? reader.readI64() : reader.readI32();
    final mediaRateInteger = reader.readI16();
    final mediaRateFraction = reader.readI16();
    if (mediaRateInteger != 1 || mediaRateFraction != 0) {
      throw UnsupportedError(
        'MP4: edit-list media rate $mediaRateInteger.$mediaRateFraction '
        'is not supported',
      );
    }
    if (mediaTime == -1) {
      leadingEmptyDuration += segmentDuration;
      continue;
    }

    var emptyTrackDuration = 0;
    if (leadingEmptyDuration != 0) {
      final mvhd = _findBoxDeep(bytes, 0, bytes.length, 'mvhd');
      if (mvhd == null) {
        throw StateError('MP4: mvhd required for an empty edit');
      }
      final movieTimescale = _parseMvhdTimescale(bytes, mvhd);
      emptyTrackDuration =
          (leadingEmptyDuration * trackTimescale + movieTimescale ~/ 2) ~/
          movieTimescale;
    }
    return emptyTrackDuration - mediaTime;
  }
  return 0;
}

String? _trackHandlerType(Uint8List bytes, _Box trak) {
  final hdlr = _findBoxDeep(bytes, trak.dataStart, trak.end, 'hdlr');
  if (hdlr == null || hdlr.end - hdlr.dataStart < 12) return null;
  final reader = _ByteReader(bytes, offset: hdlr.dataStart);
  reader.readU32(); // version + flags
  reader.readU32(); // pre_defined
  return latin1.decode(reader.readBytes(4));
}

_SampleEntry? _findSampleEntryInTrack(
  Uint8List bytes,
  _Box trak,
  Set<String> acceptedTypes,
) {
  final stsd = _findBoxDeep(bytes, trak.dataStart, trak.end, 'stsd');
  if (stsd == null || stsd.end - stsd.dataStart < 8) return null;
  final reader = _ByteReader(bytes, offset: stsd.dataStart);
  reader.readU32(); // version + flags
  final entryCount = reader.readU32();

  for (var i = 0; i < entryCount; i++) {
    if (reader.offset + 8 > stsd.end) {
      throw const FormatException('MP4: truncated stsd sample entry');
    }
    final start = reader.offset;
    final size = reader.readU32();
    final type = latin1.decode(reader.readBytes(4));
    if (size < 8 || start + size > stsd.end) {
      throw FormatException('MP4: invalid $type sample entry size=$size');
    }
    if (acceptedTypes.contains(type)) {
      return _SampleEntry(start, start + size, type);
    }
    reader.offset = start + size;
  }
  return null;
}

_Mp4aSampleEntry _parseMp4aSampleEntry(Uint8List bytes, _SampleEntry entry) {
  if (entry.end - entry.start < 36) {
    throw const FormatException('MP4: truncated mp4a AudioSampleEntry');
  }
  final reader = _ByteReader(bytes, offset: entry.start + 8);
  reader.readBytes(6); // reserved
  reader.readU16(); // data_reference_index
  final version = reader.readU16();
  reader.readU16(); // revision_level
  reader.readU32(); // vendor
  final channelCount = reader.readU16();
  final sampleSizeBits = reader.readU16();
  reader.readU16(); // compression_id
  reader.readU16(); // packet_size
  final sampleRateFixed = reader.readU32();
  final sampleRate = sampleRateFixed >>> 16;

  if (version != 0 && version != 1 && version != 2) {
    throw FormatException('MP4: unsupported mp4a entry version=$version');
  }
  if (version == 1 && reader.offset + 16 > entry.end) {
    throw const FormatException('MP4: truncated version-1 mp4a extension');
  }
  if (version == 2 && reader.offset + 36 > entry.end) {
    throw const FormatException('MP4: truncated version-2 mp4a extension');
  }
  if (channelCount == 0 || sampleRate == 0) {
    throw FormatException(
      'MP4: invalid mp4a channelCount=$channelCount sampleRate=$sampleRate',
    );
  }
  return _Mp4aSampleEntry(
    version: version,
    channelCount: channelCount,
    sampleSizeBits: sampleSizeBits,
    sampleRate: sampleRate,
  );
}

_Box? _findEsdsInAudioSampleEntry(Uint8List bytes, _SampleEntry entry) {
  if (entry.end - entry.start < 36) return null;
  final version = (bytes[entry.start + 16] << 8) | bytes[entry.start + 17];
  final childStart = switch (version) {
    0 => entry.start + 36,
    1 => entry.start + 52,
    2 => entry.start + 72,
    _ => entry.end,
  };
  if (childStart > entry.end) return null;
  return _findBox(bytes, childStart, entry.end, 'esds');
}

Mp4AacConfig _parseEsds(Uint8List bytes, _Box esds) {
  if (esds.end - esds.dataStart < 6) {
    throw const FormatException('MP4: truncated esds box');
  }
  final data = bytes.sublist(esds.dataStart + 4, esds.end); // FullBox header
  var rootOffset = 0;
  final root = _readDescriptor(data, rootOffset);
  rootOffset = root.payloadStart;

  _Descriptor decoderConfig;
  if (root.tag == 0x03) {
    if (root.payloadLength < 3) {
      throw const FormatException('MP4: truncated ES_Descriptor');
    }
    var childOffset = rootOffset + 2; // ES_ID
    final flags = data[childOffset++];
    if ((flags & 0x80) != 0) childOffset += 2; // dependsOn_ES_ID
    if ((flags & 0x40) != 0) {
      if (childOffset >= root.payloadEnd) {
        throw const FormatException('MP4: truncated ES URL flag');
      }
      childOffset += 1 + data[childOffset];
    }
    if ((flags & 0x20) != 0) childOffset += 2; // OCR_ES_Id
    if (childOffset >= root.payloadEnd) {
      throw const FormatException('MP4: missing DecoderConfigDescriptor');
    }
    decoderConfig = _readDescriptor(data, childOffset);
  } else if (root.tag == 0x04) {
    decoderConfig = root;
  } else {
    throw FormatException(
      'MP4: expected ES/DecoderConfig descriptor, got 0x'
      '${root.tag.toRadixString(16)}',
    );
  }

  if (decoderConfig.tag != 0x04 || decoderConfig.payloadLength < 13) {
    throw const FormatException('MP4: invalid DecoderConfigDescriptor');
  }
  final reader = _ByteReader(data, offset: decoderConfig.payloadStart);
  final objectTypeIndication = reader.readU8();
  reader.readU8(); // streamType/upStream/reserved
  reader.readU24(); // bufferSizeDB
  final maxBitrate = reader.readU32();
  final averageBitrate = reader.readU32();

  final specific = _readDescriptor(data, reader.offset);
  if (specific.tag != 0x05 || specific.payloadLength == 0) {
    throw const FormatException('MP4: DecoderSpecificInfo (ASC) missing');
  }
  final ascBytes = Uint8List.fromList(
    data.sublist(specific.payloadStart, specific.payloadEnd),
  );
  return Mp4AacConfig(
    objectTypeIndication: objectTypeIndication,
    config: AudioSpecificConfig.parse(ascBytes),
    maxBitrate: maxBitrate,
    averageBitrate: averageBitrate,
  );
}

_Descriptor _readDescriptor(Uint8List bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) {
    throw const FormatException('MP4: truncated descriptor tag');
  }
  final tag = bytes[offset++];
  var length = 0;
  var terminated = false;
  for (var i = 0; i < 4; i++) {
    if (offset >= bytes.length) {
      throw const FormatException('MP4: truncated descriptor length');
    }
    final value = bytes[offset++];
    length = (length << 7) | (value & 0x7f);
    if ((value & 0x80) == 0) {
      terminated = true;
      break;
    }
  }
  if (!terminated) {
    throw const FormatException('MP4: descriptor length exceeds four bytes');
  }
  final end = offset + length;
  if (end < offset || end > bytes.length) {
    throw const FormatException('MP4: descriptor payload is truncated');
  }
  return _Descriptor(tag, offset, end);
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

int _parseMvhdTimescale(Uint8List bytes, _Box mvhd) {
  final reader = _ByteReader(bytes, offset: mvhd.dataStart);
  final version = reader.readU8();
  reader.readU24();
  if (version == 1) {
    reader.readU64();
    reader.readU64();
  } else if (version == 0) {
    reader.readU32();
    reader.readU32();
  } else {
    throw FormatException('MP4: unsupported mvhd version=$version');
  }
  final timescale = reader.readU32();
  if (timescale == 0) {
    throw const FormatException('MP4: mvhd timescale is zero');
  }
  return timescale;
}

List<int> _parseStsz(Uint8List bytes, _Box stsz) {
  final br = _ByteReader(bytes, offset: stsz.dataStart);
  br.readU8();
  br.readU24(); // version + flags
  final sampleSize = br.readU32();
  final sampleCount = br.readU32();

  final sizes = <int>[];
  if (sampleSize != 0) {
    for (int i = 0; i < sampleCount; i++) {
      sizes.add(sampleSize);
    }
  } else {
    for (int i = 0; i < sampleCount; i++) {
      sizes.add(br.readU32());
    }
  }
  return sizes;
}

List<int> _parseStco(Uint8List bytes, _Box stco) {
  final br = _ByteReader(bytes, offset: stco.dataStart);
  br.readU8();
  br.readU24();
  final count = br.readU32();
  final out = <int>[];
  for (int i = 0; i < count; i++) {
    out.add(br.readU32());
  }
  return out;
}

List<int> _parseCo64(Uint8List bytes, _Box co64) {
  final br = _ByteReader(bytes, offset: co64.dataStart);
  br.readU8();
  br.readU24();
  final count = br.readU32();
  final out = <int>[];
  for (int i = 0; i < count; i++) {
    out.add(br.readU64().toInt());
  }
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

({List<int> dts, List<int> durations}) _parseStts(
  Uint8List bytes,
  _Box stts,
  int sampleCount,
) {
  final br = _ByteReader(bytes, offset: stts.dataStart);
  br.readU8();
  br.readU24();
  final entryCount = br.readU32();

  final dts = List<int>.filled(sampleCount, 0);
  final durations = List<int>.filled(sampleCount, 0);
  int cur = 0;
  int acc = 0;

  for (int i = 0; i < entryCount; i++) {
    final count = br.readU32();
    final delta = br.readU32();
    if (count > sampleCount - cur) {
      throw FormatException(
        'MP4: stts describes more than $sampleCount samples',
      );
    }
    for (int j = 0; j < count; j++) {
      dts[cur] = acc;
      durations[cur] = delta;
      acc += delta;
      cur++;
    }
  }
  if (cur != sampleCount) {
    throw FormatException('MP4: stts describes $cur of $sampleCount samples');
  }
  return (dts: dts, durations: durations);
}

List<int> _parseCtts(Uint8List bytes, _Box ctts, int sampleCount) {
  final br = _ByteReader(bytes, offset: ctts.dataStart);
  final version = br.readU8();
  br.readU24();
  if (version != 0 && version != 1) {
    throw FormatException('MP4: unsupported ctts version=$version');
  }
  final entryCount = br.readU32();
  final offsets = List<int>.filled(sampleCount, 0);
  var cursor = 0;
  for (var i = 0; i < entryCount; i++) {
    final count = br.readU32();
    final encodedOffset = br.readU32();
    final offset = version == 1 && (encodedOffset & 0x80000000) != 0
        ? encodedOffset - 0x100000000
        : encodedOffset;
    if (count > sampleCount - cursor) {
      throw FormatException(
        'MP4: ctts describes more than $sampleCount samples',
      );
    }
    offsets.fillRange(cursor, cursor + count, offset);
    cursor += count;
  }
  if (cursor != sampleCount) {
    throw FormatException(
      'MP4: ctts describes $cursor of $sampleCount samples',
    );
  }
  return offsets;
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

final class _Mp4SampleTable {
  const _Mp4SampleTable({
    required this.sampleSizes,
    required this.sampleOffsets,
    required this.dts,
    required this.sampleDurations,
    required this.pts,
    required this.presentationTimeOffset,
  });

  final List<int> sampleSizes;
  final List<int> sampleOffsets;
  final List<int> dts;
  final List<int> sampleDurations;
  final List<int> pts;
  final int presentationTimeOffset;
}

final class _SampleEntry {
  const _SampleEntry(this.start, this.end, this.type);

  final int start;
  final int end;
  final String type;
}

final class _Mp4aSampleEntry {
  const _Mp4aSampleEntry({
    required this.version,
    required this.channelCount,
    required this.sampleSizeBits,
    required this.sampleRate,
  });

  final int version;
  final int channelCount;
  final int sampleSizeBits;
  final int sampleRate;
}

final class _Descriptor {
  const _Descriptor(this.tag, this.payloadStart, this.payloadEnd);

  final int tag;
  final int payloadStart;
  final int payloadEnd;
  int get payloadLength => payloadEnd - payloadStart;
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

  int readI16() {
    final value = readU16();
    return (value & 0x8000) == 0 ? value : value - 0x10000;
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

  int readI32() {
    final value = readU32();
    return (value & 0x80000000) == 0 ? value : value - 0x100000000;
  }

  int readU64() {
    final hi = readU32();
    final lo = readU32();
    return (hi * 4294967296) + lo;
  }

  int readI64() {
    final high = readU32();
    final low = readU32();
    final signedHigh = (high & 0x80000000) == 0 ? high : high - 0x100000000;
    return signedHigh * 4294967296 + low;
  }

  List<int> readBytes(int n) {
    final out = b.sublist(offset, offset + n);
    offset += n;
    return out;
  }
}
