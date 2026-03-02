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
  HlsSegment({
    required this.uri,
    required this.duration,
    required this.sequence,
  });
}

class HlsMediaPlaylist {
  final int targetDuration;
  final int mediaSequence;
  final bool isEndList;
  final List<HlsSegment> segments;

  HlsMediaPlaylist({
    required this.targetDuration,
    required this.mediaSequence,
    required this.isEndList,
    required this.segments,
  });
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
        HlsSegment(uri: segUrl, duration: dur, sequence: seqCounter),
      );
      pendingDur = null;
      seqCounter++;
    }
  }

  return HlsMediaPlaylist(
    targetDuration: target,
    mediaSequence: mediaSeq,
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
