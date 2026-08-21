import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/hls.dart';

void main() {
  final uri = Uri.parse('https://media.example/live/playlist.m3u8');

  Future<Uint8List> fetch(String playlist) async =>
      Uint8List.fromList(utf8.encode(playlist));

  const liveSnapshot = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:41
#EXTINF:6,
segment-41.ts
#EXTINF:6,
segment-42.ts
''';

  test('rejects a non-finalized media playlist by default', () async {
    await expectLater(
      fetchMediaPlaylist(uri, byteFetcher: (_) => fetch(liveSnapshot)),
      throwsA(
        isA<HlsVodPlaylistRequiredException>()
            .having((error) => error.playlistUri, 'playlistUri', uri)
            .having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('missing #EXT-X-ENDLIST'),
                contains('Live/event playlist refresh is not supported yet'),
              ),
            ),
      ),
    );
  });

  test('does not mistake a similarly prefixed tag for ENDLIST', () async {
    final playlist = '$liveSnapshot#EXT-X-ENDLIST-NOT-REAL\n';

    await expectLater(
      fetchMediaPlaylist(uri, byteFetcher: (_) => fetch(playlist)),
      throwsA(isA<HlsVodPlaylistRequiredException>()),
    );
  });

  test(
    'allows explicit snapshot parsing for future refresh coordinators',
    () async {
      final playlist = await fetchMediaPlaylist(
        uri,
        byteFetcher: (_) => fetch(liveSnapshot),
        requireEndList: false,
      );

      expect(playlist.isEndList, isFalse);
      expect(playlist.mediaSequence, 41);
      expect(
        playlist.segments.map((segment) => segment.sequence),
        orderedEquals(<int>[41, 42]),
      );
    },
  );

  test('accepts a finalized VOD playlist', () async {
    final playlist = await fetchMediaPlaylist(
      uri,
      byteFetcher: (_) => fetch('$liveSnapshot#EXT-X-ENDLIST\n'),
    );

    expect(playlist.isEndList, isTrue);
    expect(playlist.segments, hasLength(2));
  });

  test('rejects encrypted, fMP4, byte-range, and gap media early', () async {
    final tags = <String, String>{
      '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"': 'encrypted media',
      '#EXT-X-MAP:URI="init.mp4"': 'fragmented MP4',
      '#EXT-X-BYTERANGE:100@0': 'byte-range',
      '#EXT-X-GAP': 'gap segments',
      '#EXT-X-I-FRAMES-ONLY': 'I-frame-only',
    };

    for (final entry in tags.entries) {
      await expectLater(
        fetchMediaPlaylist(
          uri,
          byteFetcher: (_) => fetch('''
#EXTM3U
${entry.key}
#EXTINF:6,
segment.ts
#EXT-X-ENDLIST
'''),
        ),
        throwsA(
          isA<HlsMediaFeatureUnsupportedException>()
              .having((error) => error.playlistUri, 'playlistUri', uri)
              .having(
                (error) => error.feature,
                'feature',
                contains(entry.value),
              ),
        ),
      );
    }
  });

  test('allows METHOD=NONE because following TS segments are clear', () async {
    final playlist = await fetchMediaPlaylist(
      uri,
      byteFetcher: (_) => fetch('''
#EXTM3U
#EXT-X-KEY:METHOD=NONE
#EXTINF:6,
segment.ts
#EXT-X-ENDLIST
'''),
    );

    expect(playlist.segments.single.uri.path, endsWith('segment.ts'));
  });

  test('accepts one non-zero discontinuity epoch', () async {
    final playlist = await fetchMediaPlaylist(
      uri,
      byteFetcher: (_) => fetch('''
#EXTM3U
#EXT-X-DISCONTINUITY-SEQUENCE:7
#EXTINF:6,
segment-41.ts
#EXTINF:6,
segment-42.ts
#EXT-X-ENDLIST
'''),
    );

    expect(() => requireSingleHlsDiscontinuityEpoch(playlist), returnsNormally);
  });

  test('rejects a VOD that crosses a discontinuity epoch', () async {
    final playlist = await fetchMediaPlaylist(
      uri,
      byteFetcher: (_) => fetch('''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:41
#EXTINF:6,
segment-41.ts
#EXT-X-DISCONTINUITY
#EXTINF:6,
segment-42.ts
#EXT-X-ENDLIST
'''),
    );

    expect(
      () => requireSingleHlsDiscontinuityEpoch(playlist),
      throwsA(
        isA<HlsDiscontinuityUnsupportedException>()
            .having((error) => error.firstSequence, 'firstSequence', 42)
            .having(
              (error) => error.discontinuitySequence,
              'discontinuitySequence',
              1,
            ),
      ),
    );
  });
}
