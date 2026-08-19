# NDVY Player — Dart-native H.264 + AAC Playback

NDVY Player is a Flutter experiment that demuxes, decodes, schedules, and
renders H.264 video and AAC-LC audio without `video_player`, FFmpeg, or a
platform media codec. Containers, codecs, gapless trimming, and A/V sync are
implemented in Dart. Flutter displays decoded YUV 4:2:0 frames, while a small
`dart:ffi` PCM sink sends already-decoded samples to Android AAudio or Apple
AudioQueue. There is no Kotlin/Swift codec or method-channel media path.

The completed Phase 1 design, codec boundaries, validation evidence, and Phase
2 direction are documented in [WHITEPAPER.md](WHITEPAPER.md).

## Current status

The app now defaults to `assets/butterfly_dart.mp4`: 226 H.264 I/P pictures at
854x480 and 353 stereo AAC-LC access units over 7.54 seconds. It is a
Dart-decoder-compatible rendition of the preserved High Profile source
`assets/butterfly.mp4`. The smaller `baby.mp4` supplies the independent video
pixel golden, while `baby_aac.mp4` supplies the independent AAC PCM golden.

- Golden sequence: 141 frames
- Current automated suite: 210 passing tests
- Video sequence SHA-256:
  `ccd20c092507bb8150d0d8759de51658e6314e5c3a6360f7bc18b7f438f23bf9`
- A/V fixture SHA-256:
  `32d0ff5d1efd2f69e1a3b22f0b009ceb496cbbd57a7c2db76aa7d6cda98b81c4`
- Butterfly Dart rendition SHA-256:
  `4623d0b1f8540ce8a2eab2a7ed7fa29849548cd9ae06cc656d549e4f0d3ae26b`

## Supported decoder scope

The decoder accepts the progressive, 8-bit, YUV 4:2:0 subset of H.264
Baseline, Main, and Extended profile syntax when the stream uses:

- CAVLC entropy coding
- I and P pictures only
- 4x4 intra prediction and 16x16 intra prediction
- P skips, inter partitions, and quarter-pixel motion compensation
- a sliding short-term decoded-picture buffer with multiple active List 0
  references, PicNum ordering, and P-slice reference-list reordering
- in-loop deblocking
- one or multiple slices belonging to the same picture

Unsupported syntax is rejected instead of guessed, so one malformed access
unit cannot silently desynchronize the remaining bitstream. The decoder does
not support CABAC, B pictures, weighted prediction, FMO/slice groups,
interlaced pictures, 8x8 transforms or prediction, high bit depth, or chroma
formats other than 4:2:0.

The default resource guard accepts coded dimensions up to 4096 pixels on each
axis and at most `4096 × 2304` luma samples. Applications can lower or raise
those constructor limits for their own memory budget.

## Supported audio scope

The pure-Dart decoder accepts AAC-LC (Audio Object Type 2), 1024-sample access
units, and mono or stereo channel configurations. It supports long and short
windows, sine/KBD windows, Huffman codebooks 1–11, pulse data, mid/side and
intensity stereo, PNS, and TNS. Unsupported tools fail explicitly: HE-AAC
(SBR/PS), 960-sample frames, PCE/multichannel layouts, CCE/LFE, gain control,
and multiple raw-data blocks are not decoded.

## Playback pipelines

### MP4

The MP4 path parses `avc1`/`avcC` video and `mp4a`/`esds` AAC configuration,
resolves common sample tables, and reads length-prefixed video NAL units plus
raw AAC access units. It applies edit-list timing, removes AAC encoder priming
and final padding, supplies SPS/PPS at random-access points, and preserves I/P
decode order for reference-picture correctness.

### HLS / MPEG-TS

The HLS path reads master or media playlists, performs a limited preflight of
candidate variants, and currently downloads up to the first 20 MPEG-TS
segments. If a Baseline video candidate advertises unsupported HE-AAC, the
selector can pair it with AAC-LC from another sequence-aligned muxed variant.
Segment boundaries and the first MPEG timestamps are validated before the
components share one timeline. The path parses PAT/PMT, reassembles H.264 and
ADTS AAC PES payloads, applies continuity validation to the stateful AAC path,
unwraps the shared 90 kHz clock, and constructs every I/P video and AAC audio
access unit. The decoder remains the final compatibility check.

Both inputs use one shared media timeline. The consumed PCM frame position is
the master clock; the sequential video decoder presents the newest picture due
at that audio time. Pause preserves the current decoder and queued PCM state.
Queue rebuild, replay after completion, and IDR navigation reset or flush state
as required.

## Run it

This repository uses FVM; run Flutter commands through `fvm flutter`.

```sh
fvm flutter pub get
fvm flutter run
```

Android audio uses AAudio and therefore requires Android 8.0 / API 26 or newer.

In the app:

1. Leave `assets/butterfly_dart.mp4` in the input field, or enter a compatible
   `.mp4` or `.m3u8` URL.
2. Select **Build Queue (MP4)** or **Build Queue (HLS/TS)** for that input.
3. Wait for the queue to report ready, then select **Play**.

The public Mux compatibility target is:

```text
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
```

Enter it and select **Build Queue (HLS/TS)**. Its compatible Baseline video
uses multiple short-term references, while its audible AAC-LC track is selected
from a synchronized sibling variant.

Pause preserves the current position. The exposed Seek Start, Previous IDR,
and Next IDR controls reset at a random-access picture and decode dependencies
sequentially. Phase 1 does not expose an arbitrary timeline scrubber.

## Verify

```sh
fvm flutter analyze
fvm flutter test
fvm flutter test test/hls_butterfly_playback_test.dart
fvm flutter test test/decoder/mux_x36xhzz_multireference_test.dart
fvm flutter test test/audio/hls_cross_variant_audio_test.dart
fvm flutter test test/decoder/h264_baseline_decoder_golden_test.dart
fvm flutter test test/audio/aac_decoder_test.dart
```

The deterministic butterfly HLS fixture exercises master/media playlist
fetching, four MPEG-TS segments, all 226 pictures, and all 353 AAC-LC access
units. Frozen segments from the Mux target independently verify all 300
multi-reference video pictures against an FFmpeg I420 sequence hash and 431
AAC-LC units against sparse FFmpeg PCM samples, including the cross-variant
timestamp offset.
The video golden checks the full 141-frame sequence, independent IDR restarts,
and rejection of a P picture that has no decoded reference. The AAC golden
decodes all 277 access units, applies the exact priming offset, and compares
sparse PCM samples, RMS, peak, and channel tones with FFmpeg reference data.

## Architecture

- `lib/player_page.dart` — queue construction, compatibility probing, controls,
  seek/replay state, and frame presentation
- `lib/src/mp4/mp4_demux.dart` — MP4 boxes, AVC/AAC configuration, sample
  tables, edit lists, and timestamps
- `lib/src/hls.dart`, `ts*.dart`, and `pes_pts.dart` — HLS, MPEG-TS, PES, and PTS
- `lib/src/h264_nal.dart` and `access_unit_pts.dart` — Annex-B scanning, picture
  boundaries, parameter-set attachment, and timestamp association
- `lib/src/decoder/h264_baseline_idr_decoder.dart` — picture/slice orchestration,
  reference state, macroblock reconstruction, and decoder validation
- `lib/src/decoder/reference_picture_list.dart` — short-term DPB List 0 ordering,
  frame-number wrap, and reordering
- `lib/src/decoder/cavlc*.dart` — strict CAVLC residual parsing and VLC tables
- `lib/src/decoder/intra*.dart`, `chroma_pred.dart`, and `inv_transform.dart` —
  intra prediction, coefficient transforms, and residual reconstruction
- `lib/src/decoder/motion_compensation.dart` and `deblocking_filter.dart` —
  inter prediction and the in-loop filter
- `lib/src/audio/aac/` — pure-Dart AAC-LC syntax, spectral tools, IMDCT, and
  overlap reconstruction
- `lib/src/audio/audio_decode_pipeline.dart` and `pcm_timeline.dart` — MP4/TS
  AAC decode, gapless trimming, PCM conversion, and shared media timing
- `lib/src/audio/pcm_sink*.dart` — direct FFI sinks for AAudio and AudioQueue;
  these contain no codec logic
- `lib/src/audio/audio_playback_controller.dart` and `player_clock.dart` —
  bounded PCM feeding, audio-master timing, and dependency-safe video decode
- `lib/src/yuv.dart` and `pure_frame_view.dart` — YUV 4:2:0 to RGBA conversion and
  display

## Known limitations

- Audio output is available on Android API 26+, iOS, and macOS. Other Flutter
  targets currently have no PCM sink.
- HLS currently supports muxed MPEG-TS H.264 (`stream_type 0x1b`) and ADTS AAC
  (`0x0f`). It can combine aligned muxed variants, but does not yet parse
  `EXT-X-MEDIA` alternate-audio groups, LATM/LOAS, fMP4/CMAF, encryption, or
  continuous live-window refresh.
- MP4 support targets the sample-table layout used by ordinary AVC files; the
  H.264/AAC decoder subsets above still apply regardless of container.
- AAC is currently decoded into an in-memory PCM timeline before play. Sink
  queues are bounded, and HLS limits its segment window, but MP4 timeline size
  has no fixed total bound. Long media needs an incremental or file-backed
  decode/cache layer in production.
- The runtime HLS video path does not yet apply continuity-counter or scrambling
  checks while concatenating video PES payloads; the stateful AAC assembler and
  transport test path do.
- Codec decoding and color conversion run in Dart and are not hardware
  accelerated; high-resolution/high-frame-rate streams may not play in real
  time.
- VUI color metadata is not yet propagated to rendering; RGBA conversion uses
  limited-range BT.601 coefficients.
- HLS access-unit detection supports AUDs and normal raster-order slices;
  arbitrary slice ordering without AUDs is outside the current scope.
- Streams using any unsupported H.264 tool need another compatible rendition
  or an expanded decoder implementation.
