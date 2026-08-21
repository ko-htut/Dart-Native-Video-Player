import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/hls.dart';
import 'package:ndvy_player/src/hls_quality.dart';

void main() {
  test('auto quality keeps stepping down while decoder lateness persists', () {
    final controller = _controller();

    expect(controller.mode, HlsQualityMode.automatic);
    expect(controller.selected.bandwidth, 250000);
    controller.observeBuffer(
      videoBufferedMs: 12000,
      audioBufferedMs: 11000,
      playing: true,
    );
    for (var i = 0; i < 3; i++) {
      expect(
        controller.recordDownload(
          byteCount: 200000,
          elapsed: const Duration(milliseconds: 100),
        ),
        isNull,
      );
    }
    final firstUpgrade = controller.recordDownload(
      byteCount: 200000,
      elapsed: const Duration(milliseconds: 100),
    );
    expect(firstUpgrade?.current.bandwidth, 500000);

    for (var i = 0; i < 4; i++) {
      controller.recordDownload(
        byteCount: 200000,
        elapsed: const Duration(milliseconds: 100),
      );
    }
    expect(controller.selected.bandwidth, 1500000);

    final down = controller.observePlayback(latenessMs: 220, starved: false);
    expect(down?.current.bandwidth, 500000);
    expect(controller.observePlayback(latenessMs: 240, starved: false), isNull);
    expect(controller.selected.bandwidth, 500000);
    expect(controller.observePlayback(latenessMs: 240, starved: false), isNull);
    final secondDown = controller.observePlayback(
      latenessMs: 240,
      starved: false,
    );
    expect(secondDown?.current.bandwidth, 250000);
    expect(controller.selected.bandwidth, 250000);
  });

  test('manual quality remains fixed across network and playback samples', () {
    final controller = _controller();
    final high = controller.renditions.last;

    controller.selectManual(high.variant.uri);
    expect(controller.mode, HlsQualityMode.manual);
    expect(controller.selected, same(high));
    expect(controller.recordNetworkFailure(), isNull);
    expect(controller.observePlayback(latenessMs: 500, starved: true), isNull);
    expect(
      controller.observeBuffer(
        videoBufferedMs: 0,
        audioBufferedMs: 0,
        playing: true,
        starved: true,
      ),
      isNull,
    );
    expect(controller.selected, same(high));

    final auto = controller.selectAutomatic();
    expect(auto?.current.bandwidth, 250000);
    expect(controller.mode, HlsQualityMode.automatic);
  });

  test('buffer starvation drops two levels and blocks rebound oscillation', () {
    final controller = _controller();
    controller.observeBuffer(videoBufferedMs: 12000, playing: true);
    for (var i = 0; i < 8; i++) {
      controller.recordDownload(
        byteCount: 200000,
        elapsed: const Duration(milliseconds: 100),
        segmentDuration: const Duration(seconds: 4),
      );
    }
    expect(controller.selected.bandwidth, 1500000);

    final emergency = controller.observeBuffer(
      videoBufferedMs: 0,
      audioBufferedMs: 0,
      playing: true,
      starved: true,
    );
    expect(emergency?.current.bandwidth, 250000);
    expect(controller.playbackConstrained, isTrue);

    for (var i = 0; i < 8; i++) {
      expect(
        controller.recordDownload(
          byteCount: 200000,
          elapsed: const Duration(milliseconds: 100),
          segmentDuration: const Duration(seconds: 4),
        ),
        isNull,
      );
    }
    expect(controller.selected.bandwidth, 250000);

    for (var i = 0; i < 8; i++) {
      controller.observeBuffer(videoBufferedMs: 12000, playing: true);
    }
    expect(controller.playbackConstrained, isFalse);
    for (var i = 0; i < 4; i++) {
      controller.recordDownload(
        byteCount: 200000,
        elapsed: const Duration(milliseconds: 100),
        segmentDuration: const Duration(seconds: 4),
      );
    }
    expect(controller.selected.bandwidth, 500000);
  });

  test('automatic quality respects the decode-device pixel ceiling', () {
    final controller = HlsQualityController(
      renditions: <HlsQualityRendition>[
        _rendition(1500000),
        _rendition(250000),
        _rendition(500000),
      ],
      maximumAutomaticPixels: 640 * 360,
    );
    expect(controller.automaticCeiling.bandwidth, 500000);
    controller.observeBuffer(videoBufferedMs: 12000, playing: true);
    for (var i = 0; i < 20; i++) {
      controller.recordDownload(
        byteCount: 200000,
        elapsed: const Duration(milliseconds: 100),
        segmentDuration: const Duration(seconds: 4),
      );
    }
    expect(controller.selected.bandwidth, 500000);

    controller.selectManual(controller.renditions.last.variant.uri);
    expect(controller.selected.bandwidth, 1500000);
  });

  test('a segment slower than its media duration forces a downshift', () {
    final controller = _controller();
    controller.selectManual(controller.renditions[1].variant.uri);
    controller.selectAutomatic();
    controller.observeBuffer(videoBufferedMs: 12000, playing: true);
    for (var i = 0; i < 4; i++) {
      controller.recordDownload(
        byteCount: 200000,
        elapsed: const Duration(milliseconds: 100),
        segmentDuration: const Duration(seconds: 4),
      );
    }
    expect(controller.selected.bandwidth, 500000);

    final down = controller.recordDownload(
      byteCount: 200000,
      elapsed: const Duration(seconds: 4),
      segmentDuration: const Duration(seconds: 4),
    );
    expect(down?.current.bandwidth, 250000);
  });

  test(
    'adaptive fetcher resolves aligned variants at safe boundaries',
    () async {
      final controller = _controller();
      final fetched = <Uri>[];
      final active = <int>[];
      final fetcher = HlsAdaptiveSegmentFetcher(
        controller: controller,
        fetcher: (uri) async {
          fetched.add(uri);
          return Uint8List.fromList(<int>[1, 2, 3]);
        },
        switchBoundaryValidator: (_) => true,
        onActiveRendition: (rendition) => active.add(rendition.bandwidth),
      );
      final canonical = controller.canonical.playlist.segments;

      await fetcher.call(canonical[0].uri);
      controller.selectManual(controller.renditions[1].variant.uri);
      await fetcher.call(canonical[1].uri);

      expect(fetched[0].path, contains('/250000/'));
      expect(fetched[1].path, contains('/500000/'));
      expect(active, <int>[250000, 500000]);
    },
  );

  test(
    'manual selection replaces an in-flight next segment without a restart',
    () async {
      final controller = _controller();
      final fetched = <Uri>[];
      final pendingLowSegment = Completer<Uint8List>();
      final fetcher = HlsAdaptiveSegmentFetcher(
        controller: controller,
        fetcher: (uri) async {
          fetched.add(uri);
          if (uri.path.endsWith('/11.ts') && uri.path.contains('/250000/')) {
            return pendingLowSegment.future;
          }
          return Uint8List.fromList(
            uri.path.contains('/500000/') ? <int>[5] : <int>[2],
          );
        },
        switchBoundaryValidator: (_) => true,
      );
      final canonical = controller.canonical.playlist.segments;

      final first = await fetcher.call(canonical[0].uri);
      expect(first, <int>[2]);

      final next = fetcher.call(canonical[1].uri);
      await Future<void>.delayed(Duration.zero);
      controller.selectManual(controller.renditions[1].variant.uri);
      pendingLowSegment.complete(Uint8List.fromList(<int>[2]));
      final switched = await next;

      expect(switched, <int>[5]);
      expect(
        fetched.map((uri) => uri.path),
        containsAllInOrder(<String>[
          '/250000/10.ts',
          '/250000/11.ts',
          '/500000/11.ts',
        ]),
      );
      expect(fetcher.renditionForSequence(10)?.bandwidth, 250000);
      expect(fetcher.renditionForSequence(11)?.bandwidth, 500000);
      expect(fetcher.activeRendition, same(controller.renditions[1]));
    },
  );

  test(
    'unsafe switch boundary keeps playback on the active rendition',
    () async {
      final controller = _controller();
      final fetched = <Uri>[];
      final fetcher = HlsAdaptiveSegmentFetcher(
        controller: controller,
        fetcher: (uri) async {
          fetched.add(uri);
          return Uint8List.fromList(
            uri.path.contains('/500000/') ? <int>[5] : <int>[2],
          );
        },
        switchBoundaryValidator: (_) => false,
      );
      final canonical = controller.canonical.playlist.segments;

      await fetcher.call(canonical[0].uri);
      controller.selectManual(controller.renditions[1].variant.uri);
      final bytes = await fetcher.call(canonical[1].uri);

      expect(bytes, <int>[2]);
      expect(controller.selected, same(controller.renditions[1]));
      expect(fetcher.activeRendition, same(controller.renditions[0]));
      expect(fetcher.renditionForSequence(11), same(controller.renditions[0]));
      expect(fetched[fetched.length - 2].path, contains('/500000/11.ts'));
      expect(fetched.last.path, contains('/250000/11.ts'));
    },
  );

  test(
    'prefetched quality transitions are committed in segment order',
    () async {
      final controller = _controller();
      final lowGate = Completer<Uint8List>();
      final active = <int>[];
      final fetcher = HlsAdaptiveSegmentFetcher(
        controller: controller,
        fetcher: (uri) {
          if (uri.path.contains('/250000/')) return lowGate.future;
          return Future<Uint8List>.value(Uint8List.fromList(<int>[2]));
        },
        switchBoundaryValidator: (_) => true,
        onActiveRendition: (rendition) => active.add(rendition.bandwidth),
      );
      final canonical = controller.canonical.playlist.segments;

      final first = fetcher.call(canonical[0].uri);
      controller.selectManual(controller.renditions[1].variant.uri);
      var secondCompleted = false;
      final second = fetcher.call(canonical[1].uri).then((bytes) {
        secondCompleted = true;
        return bytes;
      });
      await Future<void>.delayed(Duration.zero);
      expect(secondCompleted, isFalse);

      lowGate.complete(Uint8List.fromList(<int>[1]));
      await Future.wait(<Future<Uint8List>>[first, second]);

      // The first segment had not committed yet, so both pending requests
      // converge on the newly selected rendition without an out-of-order
      // intermediate activation.
      expect(active, <int>[500000]);
    },
  );

  test('rejects variant playlists whose segment boundaries do not align', () {
    final low = _rendition(250000);
    final badVariant = HlsVariant(
      uri: Uri.parse('https://example.test/500/index.m3u8'),
      bandwidth: 500000,
      resolution: '640x360',
    );
    final badPlaylist = HlsMediaPlaylist(
      targetDuration: 4,
      mediaSequence: 10,
      isEndList: true,
      segments: <HlsSegment>[
        HlsSegment(
          uri: Uri.parse('https://example.test/500/10.ts'),
          duration: 2,
          sequence: 10,
        ),
        for (var i = 1; i < 3; i++)
          HlsSegment(
            uri: Uri.parse('https://example.test/500/${10 + i}.ts'),
            duration: 4,
            sequence: 10 + i,
          ),
      ],
    );

    expect(
      () => HlsQualityController(
        renditions: <HlsQualityRendition>[
          low,
          HlsQualityRendition(variant: badVariant, playlist: badPlaylist),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

HlsQualityController _controller() => HlsQualityController(
  renditions: <HlsQualityRendition>[
    _rendition(1500000),
    _rendition(250000),
    _rendition(500000),
  ],
);

HlsQualityRendition _rendition(int bandwidth) {
  final resolution = switch (bandwidth) {
    250000 => '426x240',
    500000 => '640x360',
    _ => '1280x720',
  };
  final variant = HlsVariant(
    uri: Uri.parse('https://example.test/$bandwidth/index.m3u8'),
    bandwidth: bandwidth,
    resolution: resolution,
  );
  final playlist = HlsMediaPlaylist(
    targetDuration: 4,
    mediaSequence: 10,
    isEndList: true,
    segments: <HlsSegment>[
      for (var i = 0; i < 3; i++)
        HlsSegment(
          uri: Uri.parse('https://example.test/$bandwidth/${10 + i}.ts'),
          duration: 4,
          sequence: 10 + i,
        ),
    ],
  );
  return HlsQualityRendition(variant: variant, playlist: playlist);
}
