# Mux `x36xhzz` cross-variant fixtures

These are unchanged first MPEG-TS segments from Mux's public HLS test stream,
frozen locally so codec and synchronization regressions do not depend on the
network.

Master playlist:

```text
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
```

## Baseline video fixture

Local file: `low_320x184_segment_000.ts`

- Media playlist:
  `https://test-streams.mux.dev/x36xhzz/url_2/193039199_mp4_h264_aac_ld_7.m3u8`
- Segment URI from that playlist:
  `url_526/193039199_mp4_h264_aac_ld_7.ts`
- Resolved segment URL:
  `https://test-streams.mux.dev/x36xhzz/url_2/url_526/193039199_mp4_h264_aac_ld_7.ts`
- Segment duration: 10 seconds
- SHA-256:
  `b82fcf4dbcec2d8fab7d94bdd48b070aa6e74d7240b1965a0b28c128d6858477`
- Video: H.264 Constrained Baseline, level 1.3, 320x184, 30 fps
- Pictures: 300
- Maximum short-term references advertised by SPS: 5

The multi-reference decoder test ignores the multiplexed HE-AAC PID and checks
the complete 300-picture I420 sequence against an independent FFmpeg hash.

## AAC-LC sibling fixture

Local file: `hq_848x480_segment_000.ts`

- Media playlist:
  `https://test-streams.mux.dev/x36xhzz/url_6/193039199_mp4_h264_aac_hq_7.m3u8`
- Segment URI from that playlist:
  `url_846/193039199_mp4_h264_aac_hq_7.ts`
- Resolved segment URL:
  `https://test-streams.mux.dev/x36xhzz/url_6/url_846/193039199_mp4_h264_aac_hq_7.ts`
- Segment duration: 10 seconds
- Size: 905,784 bytes
- SHA-256:
  `ae5f75bb810f13a22346d5b730dfc18f05efe95539bd5376fc7525314832327d`
- Audio: AAC-LC, Audio Object Type 2, 44.1 kHz, stereo
- AAC access units: 431

The sibling's first audio PTS is 900909. The Baseline fixture's first video PTS
is 900000, so audio starts 909 ticks, or 10.100 ms, later on the shared 90 kHz
clock. The cross-variant test verifies that placement and compares 3,509 sparse
PCM samples with the independently decoded FFmpeg reference documented in
`test/audio/goldens/README.md`.

The AAC fixture's High-profile video PID is ignored. At runtime NDVY Player
combines only these compatible components after playlist and first-PTS
alignment checks; it does not transcode either source.
