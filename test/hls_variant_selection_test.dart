import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/hls.dart';

void main() {
  HlsVariant variant({
    required String path,
    required int bandwidth,
    required String codecs,
  }) => HlsVariant(
    uri: Uri.parse('https://example.test/$path'),
    bandwidth: bandwidth,
    codecs: codecs,
  );

  test('selects the lowest-bandwidth AAC-LC fallback rendition', () {
    final baselineHeAac = variant(
      path: 'low.m3u8',
      bandwidth: 246440,
      codecs: 'mp4a.40.5,avc1.42000d',
    );
    final highAacLc = variant(
      path: 'high.m3u8',
      bandwidth: 2149280,
      codecs: 'mp4a.40.2,avc1.64001f',
    );
    final mediumAacLc = variant(
      path: 'medium.m3u8',
      bandwidth: 836280,
      codecs: 'avc1.64001f, MP4A.40.2',
    );

    expect(hlsVariantAdvertisesHeAac(baselineHeAac), isTrue);
    expect(hlsVariantAdvertisesAacLc(baselineHeAac), isFalse);
    expect(
      selectHlsAacLcVariant(<HlsVariant>[
        baselineHeAac,
        highAacLc,
        mediumAacLc,
      ], preferred: baselineHeAac)?.uri,
      mediumAacLc.uri,
    );
    expect(
      selectHlsAacLcVariant(<HlsVariant>[
        baselineHeAac,
        highAacLc,
        mediumAacLc,
      ], preferred: highAacLc),
      same(highAacLc),
    );
  });

  test(
    'prefilters explicit non-AVC video codecs but probes missing metadata',
    () {
      final avc = variant(
        path: 'avc.m3u8',
        bandwidth: 100,
        codecs: 'avc3.640028,mp4a.40.2',
      );
      final hevc = variant(
        path: 'hevc.m3u8',
        bandwidth: 100,
        codecs: 'hvc1.2.4.L153.B0,mp4a.40.2',
      );
      final unknown = HlsVariant(
        uri: Uri.parse('https://example.test/unknown.m3u8'),
      );

      expect(hlsVariantUnsupportedVideoCodecReason(avc), isNull);
      expect(hlsVariantUnsupportedVideoCodecReason(unknown), isNull);
      expect(hlsVariantUnsupportedVideoCodecReason(hevc), contains('hvc1'));
    },
  );

  test(
    'rejects encrypted master session keys before variant fetching',
    () async {
      final masterUri = Uri.parse('https://example.test/master.m3u8');
      final bytes = Uint8List.fromList(
        '#EXTM3U\n'
                '#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="key"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=100,CODECS="avc1.640028"\n'
                'video.m3u8\n'
            .codeUnits,
      );

      await expectLater(
        fetchHlsVariants(masterUri, byteFetcher: (_) async => bytes),
        throwsA(
          isA<HlsMediaFeatureUnsupportedException>().having(
            (error) => error.feature,
            'feature',
            contains('SAMPLE-AES'),
          ),
        ),
      );
    },
  );

  test('pairs synchronized component renditions by media sequence', () {
    HlsMediaPlaylist playlist(double middleDuration) => HlsMediaPlaylist(
      targetDuration: 10,
      mediaSequence: 42,
      isEndList: true,
      segments: <HlsSegment>[
        for (var i = 0; i < 3; i++)
          HlsSegment(
            uri: Uri.parse('https://example.test/$middleDuration/$i.ts'),
            duration: i == 1 ? middleDuration : 10,
            sequence: 42 + i,
          ),
      ],
    );

    final pairs = pairHlsVariantSegments(
      playlist(10),
      playlist(9.95),
      limit: 2,
    );
    expect(pairs, hasLength(2));
    expect(pairs.first.video.sequence, 42);
    expect(pairs.first.audio.sequence, 42);
    expect(pairs.last.video.sequence, 43);
    expect(pairs.last.audio.duration, 9.95);
  });

  test('rejects component renditions with incompatible boundaries', () {
    final video = HlsMediaPlaylist(
      targetDuration: 10,
      mediaSequence: 0,
      isEndList: true,
      segments: <HlsSegment>[
        HlsSegment(
          uri: Uri.parse('https://example.test/video.ts'),
          duration: 10,
          sequence: 0,
        ),
      ],
    );
    final audio = HlsMediaPlaylist(
      targetDuration: 6,
      mediaSequence: 0,
      isEndList: true,
      segments: <HlsSegment>[
        HlsSegment(
          uri: Uri.parse('https://example.test/audio.ts'),
          duration: 6,
          sequence: 0,
        ),
      ],
    );

    expect(
      () => pairHlsVariantSegments(video, audio),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects cumulative boundary drift hidden by per-segment tolerance', () {
    HlsMediaPlaylist playlist(String name, double duration) => HlsMediaPlaylist(
      targetDuration: 10,
      mediaSequence: 7,
      isEndList: true,
      segments: <HlsSegment>[
        for (var i = 0; i < 3; i++)
          HlsSegment(
            uri: Uri.parse('https://example.test/$name/$i.ts'),
            duration: duration,
            sequence: 7 + i,
          ),
      ],
    );

    expect(
      () =>
          pairHlsVariantSegments(playlist('video', 10), playlist('audio', 9.7)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('boundary drift'),
        ),
      ),
    );

    expect(
      pairHlsVariantSegments(
        playlist('video', 10),
        playlist('audio', 9.7),
        cumulativeBoundaryToleranceSeconds: 1,
      ),
      hasLength(3),
    );
  });

  test('rejects mismatched discontinuity epochs', () {
    HlsMediaPlaylist playlist(String name, int discontinuitySequence) =>
        HlsMediaPlaylist(
          targetDuration: 10,
          mediaSequence: 12,
          discontinuitySequence: discontinuitySequence,
          isEndList: true,
          segments: <HlsSegment>[
            HlsSegment(
              uri: Uri.parse('https://example.test/$name.ts'),
              duration: 10,
              sequence: 12,
              discontinuitySequence: discontinuitySequence,
            ),
          ],
        );

    expect(
      () => pairHlsVariantSegments(playlist('video', 3), playlist('audio', 4)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('discontinuity'),
        ),
      ),
    );
  });

  test('accepts Mux component PTS offset and handles 33-bit rollover', () {
    expect(
      validateHlsFirstPtsAlignment(videoPts90k: 900000, audioPts90k: 900909),
      909,
    );

    const modulus = 1 << 33;
    expect(
      hlsAudioVideoPtsDelta90k(videoPts90k: modulus - 100, audioPts90k: 50),
      150,
    );
    expect(
      hlsAudioVideoPtsDelta90k(videoPts90k: 50, audioPts90k: modulus - 100),
      -150,
    );
  });

  test('rejects component PTS offsets beyond the playback tolerance', () {
    expect(
      () => validateHlsFirstPtsAlignment(
        videoPts90k: 100000,
        audioPts90k: 145001,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('first PTS values are not aligned'),
        ),
      ),
    );
  });
}
