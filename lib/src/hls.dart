import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

enum HlsPlaylistKind { master, media }

class HlsVariant {
  final Uri uri;
  final int? bandwidth;
  final String? resolution;
  final String? codecs;
  HlsVariant({required this.uri, this.bandwidth, this.resolution, this.codecs});
}

class HlsSegment {
  final Uri uri;
  final double duration;
  final int sequence;
  final int discontinuitySequence;
  HlsSegment({
    required this.uri,
    required this.duration,
    required this.sequence,
    this.discontinuitySequence = 0,
  });
}

class HlsMediaPlaylist {
  final int targetDuration;
  final int mediaSequence;
  final int discontinuitySequence;
  final bool isEndList;
  final List<HlsSegment> segments;

  HlsMediaPlaylist({
    required this.targetDuration,
    required this.mediaSequence,
    this.discontinuitySequence = 0,
    required this.isEndList,
    required this.segments,
  });
}

/// Returns the RFC 6381 codec identifiers advertised by an HLS variant.
///
/// Codec identifiers are compared case-insensitively by the selection helpers,
/// but the original spelling is retained here for diagnostics.
List<String> hlsVariantCodecIds(HlsVariant variant) {
  final codecs = variant.codecs;
  if (codecs == null || codecs.trim().isEmpty) return const <String>[];
  return codecs
      .split(',')
      .map((codec) => codec.trim().replaceAll('"', ''))
      .where((codec) => codec.isNotEmpty)
      .toList(growable: false);
}

bool hlsVariantAdvertisesAacLc(HlsVariant variant) => hlsVariantCodecIds(
  variant,
).any((codec) => codec.toLowerCase() == 'mp4a.40.2');

bool hlsVariantAdvertisesHeAac(HlsVariant variant) =>
    hlsVariantCodecIds(variant).any((codec) {
      final normalized = codec.toLowerCase();
      return normalized == 'mp4a.40.5' || normalized == 'mp4a.40.29';
    });

/// Picks the cheapest AAC-LC rendition, preferring [preferred] when it already
/// carries AAC-LC.
///
/// Some older muxed masters pair decoder-compatible Baseline AVC variants
/// with HE-AAC while another synchronized variant carries AAC-LC. HLS variant
/// streams share a presentation timeline, so the player can demux video and
/// audio from separate compatible renditions after validating their segment
/// alignment.
HlsVariant? selectHlsAacLcVariant(
  Iterable<HlsVariant> variants, {
  HlsVariant? preferred,
}) {
  if (preferred != null && hlsVariantAdvertisesAacLc(preferred)) {
    return preferred;
  }
  final candidates = variants
      .where(hlsVariantAdvertisesAacLc)
      .toList(growable: false);
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final bandwidthOrder = (a.bandwidth ?? 0x7fffffff).compareTo(
      b.bandwidth ?? 0x7fffffff,
    );
    if (bandwidthOrder != 0) return bandwidthOrder;
    return a.uri.toString().compareTo(b.uri.toString());
  });
  return candidates.first;
}

typedef HlsSegmentPair = ({HlsSegment video, HlsSegment audio});

const int _mpegPtsModulus = 1 << 33;
const int _mpegPtsMask = _mpegPtsModulus - 1;
const int _mpegPtsHalfRange = _mpegPtsModulus >> 1;

/// Returns `audioPts90k - videoPts90k` in the nearest 33-bit MPEG PTS epoch.
///
/// Independently demuxed HLS renditions can represent adjacent timestamps on
/// opposite sides of the 33-bit rollover. Comparing their raw integers would
/// incorrectly report a gap of roughly 26.5 hours.
int hlsAudioVideoPtsDelta90k({
  required int videoPts90k,
  required int audioPts90k,
}) {
  final videoRaw = videoPts90k & _mpegPtsMask;
  final audioRaw = audioPts90k & _mpegPtsMask;
  var delta = audioRaw - videoRaw;
  if (delta > _mpegPtsHalfRange) {
    delta -= _mpegPtsModulus;
  } else if (delta < -_mpegPtsHalfRange) {
    delta += _mpegPtsModulus;
  }
  return delta;
}

/// Validates the first demuxed audio/video timestamps for component playback.
///
/// Returns the signed audio offset in 90 kHz ticks when it is within
/// [tolerance90k], otherwise throws a [FormatException].
int validateHlsFirstPtsAlignment({
  required int videoPts90k,
  required int audioPts90k,
  int tolerance90k = 45000,
}) {
  if (tolerance90k < 0) {
    throw ArgumentError.value(tolerance90k, 'tolerance90k');
  }
  final delta = hlsAudioVideoPtsDelta90k(
    videoPts90k: videoPts90k,
    audioPts90k: audioPts90k,
  );
  if (delta.abs() > tolerance90k) {
    final deltaMs = delta * 1000 / 90000;
    throw FormatException(
      'HLS component first PTS values are not aligned: '
      'video=$videoPts90k, audio=$audioPts90k, '
      'delta=${deltaMs.toStringAsFixed(3)}ms',
    );
  }
  return delta;
}

/// Matches muxed video and audio renditions by media sequence and verifies
/// that their segment boundaries describe the same presentation timeline.
List<HlsSegmentPair> pairHlsVariantSegments(
  HlsMediaPlaylist video,
  HlsMediaPlaylist audio, {
  int? limit,
  double durationToleranceSeconds = 0.5,
  double cumulativeBoundaryToleranceSeconds = 0.5,
}) {
  if (durationToleranceSeconds < 0) {
    throw ArgumentError.value(
      durationToleranceSeconds,
      'durationToleranceSeconds',
    );
  }
  if (cumulativeBoundaryToleranceSeconds < 0) {
    throw ArgumentError.value(
      cumulativeBoundaryToleranceSeconds,
      'cumulativeBoundaryToleranceSeconds',
    );
  }
  final audioBySequence = <int, HlsSegment>{
    for (final segment in audio.segments) segment.sequence: segment,
  };
  final pairs = <HlsSegmentPair>[];
  var cumulativeVideoDuration = 0.0;
  var cumulativeAudioDuration = 0.0;
  final wanted = limit == null
      ? video.segments.length
      : limit.clamp(0, video.segments.length);
  for (final videoSegment in video.segments.take(wanted)) {
    final audioSegment = audioBySequence[videoSegment.sequence];
    if (audioSegment == null) {
      throw FormatException(
        'Audio rendition is missing media sequence ${videoSegment.sequence}',
      );
    }
    if (videoSegment.discontinuitySequence !=
        audioSegment.discontinuitySequence) {
      throw FormatException(
        'HLS renditions disagree on discontinuity at sequence '
        '${videoSegment.sequence}: '
        'video=${videoSegment.discontinuitySequence}, '
        'audio=${audioSegment.discontinuitySequence}',
      );
    }
    final durationDelta = (videoSegment.duration - audioSegment.duration).abs();
    if (durationDelta > durationToleranceSeconds) {
      throw FormatException(
        'HLS renditions are not segment-aligned at sequence '
        '${videoSegment.sequence}: video=${videoSegment.duration}s, '
        'audio=${audioSegment.duration}s',
      );
    }
    cumulativeVideoDuration += videoSegment.duration;
    cumulativeAudioDuration += audioSegment.duration;
    final boundaryDrift = (cumulativeVideoDuration - cumulativeAudioDuration)
        .abs();
    if (boundaryDrift > cumulativeBoundaryToleranceSeconds) {
      throw FormatException(
        'HLS rendition boundary drift exceeds tolerance after sequence '
        '${videoSegment.sequence}: video=${cumulativeVideoDuration}s, '
        'audio=${cumulativeAudioDuration}s, drift=${boundaryDrift}s',
      );
    }
    pairs.add((video: videoSegment, audio: audioSegment));
  }
  if (pairs.isEmpty && wanted > 0) {
    throw const FormatException('HLS renditions have no overlapping segments');
  }
  return List<HlsSegmentPair>.unmodifiable(pairs);
}

Future<Uint8List> fetchBytes(Uri url) async {
  final res = await http.get(url, headers: {'User-Agent': 'DartHLS/0.1'});
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode} for $url');
  return res.bodyBytes;
}

Future<String> fetchText(Uri url) async {
  final bytes = await fetchBytes(url);
  return utf8.decode(bytes);
}

Future<HlsPlaylistKind> detectPlaylistKind(Uri url) async {
  final text = await fetchText(url);
  // If it has EXT-X-STREAM-INF, it's typically a master playlist
  if (text.contains('#EXT-X-STREAM-INF')) return HlsPlaylistKind.master;
  return HlsPlaylistKind.media;
}

Future<List<HlsVariant>> fetchHlsVariants(Uri masterUrl) async {
  final text = await fetchText(masterUrl);
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  final variants = <HlsVariant>[];
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      final attrs = _parseAttrs(line.substring('#EXT-X-STREAM-INF:'.length));
      final next = (i + 1 < lines.length) ? lines[i + 1] : null;
      if (next == null || next.startsWith('#')) continue;

      variants.add(
        HlsVariant(
          uri: masterUrl.resolve(next),
          bandwidth: int.tryParse(attrs['BANDWIDTH'] ?? ''),
          resolution: attrs['RESOLUTION'],
          codecs: attrs['CODECS']?.replaceAll('"', ''),
        ),
      );
    }
  }
  return variants;
}

Future<HlsMediaPlaylist> fetchMediaPlaylist(Uri playlistUrl) async {
  final text = await fetchText(playlistUrl);
  final lines = text.split('\n').map((l) => l.trim()).toList();

  int target = 0;
  int mediaSeq = 0;
  int discontinuitySeq = 0;
  bool endList = false;

  final segments = <HlsSegment>[];
  double? pendingDur;
  int seqCounter = 0;

  for (final line in lines) {
    if (line.isEmpty) continue;

    if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      target = int.parse(line.split(':')[1]);
    } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      mediaSeq = int.parse(line.split(':')[1]);
      seqCounter = mediaSeq;
    } else if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
      discontinuitySeq = int.parse(line.split(':')[1]);
    } else if (line == '#EXT-X-DISCONTINUITY') {
      discontinuitySeq++;
    } else if (line.startsWith('#EXTINF:')) {
      final raw = line.substring('#EXTINF:'.length);
      final durStr = raw.split(',').first;
      pendingDur = double.parse(durStr);
    } else if (line.startsWith('#EXT-X-ENDLIST')) {
      endList = true;
    } else if (!line.startsWith('#')) {
      final dur = pendingDur ?? 0.0;
      final segUrl = playlistUrl.resolve(line);
      segments.add(
        HlsSegment(
          uri: segUrl,
          duration: dur,
          sequence: seqCounter,
          discontinuitySequence: discontinuitySeq,
        ),
      );
      pendingDur = null;
      seqCounter++;
    }
  }

  return HlsMediaPlaylist(
    targetDuration: target,
    mediaSequence: mediaSeq,
    discontinuitySequence: segments.isEmpty
        ? discontinuitySeq
        : segments.first.discontinuitySequence,
    isEndList: endList,
    segments: segments,
  );
}

Map<String, String> _parseAttrs(String s) {
  final out = <String, String>{};
  final parts = <String>[];
  final buf = StringBuffer();
  bool inQuotes = false;

  for (int i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '"') inQuotes = !inQuotes;
    if (c == ',' && !inQuotes) {
      parts.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  if (buf.isNotEmpty) parts.add(buf.toString());

  for (final p in parts) {
    final idx = p.indexOf('=');
    if (idx <= 0) continue;
    out[p.substring(0, idx).trim()] = p.substring(idx + 1).trim();
  }
  return out;
}
