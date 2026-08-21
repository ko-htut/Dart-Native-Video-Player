# NDVY Player — Dart-first H.264 + AAC Playback

NDVY Player is an experimental Dart-first Flutter media player. HLS/MP4
parsing, MPEG-TS demultiplexing, access-unit assembly, quality policy, timing,
and playback state are implemented in Dart without `video_player` or FFmpeg.
On Android, H.264 normally uses an asynchronous MediaCodec-to-Flutter-texture
backend. A custom Pure Dart H.264 decoder remains the correctness reference
and automatic fallback. AAC-LC is decoded in Dart; decoded PCM crosses a small
`dart:ffi` boundary to AAudio or AudioQueue.

**Current status:** the documented implementation is complete as of
2026-08-21. Its validation evidence and known performance boundary are
described in
[WHITEPAPER.md](WHITEPAPER.md).

## Current video quality

<p align="center">
  <img src="docs/images/video-quality.png"
       alt="NDVY Player Pure Dart fallback playing Mux HLS at 848x480"
       width="390">
</p>

The screenshot records the Pure Dart fallback path playing the public Mux
master playlist at **848x480 / 836 kbps**. Its on-frame diagnostics show the
decoded resolution, disposable B-frame drops, and coalesced render work. The
current Android path was also smoke-tested on an emulator through
`c2.goldfish.h264.decoder`; frames were rendered directly to a Flutter texture
with no rebuffer or codec error during the verification run.

The tested master is:

```text
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
```

It advertises these verified quality choices:

| Selection | Advertised bandwidth | First complete TS segment regression |
| --- | ---: | --- |
| 320x184 | 246 kbps | 300/300 pictures pixel-exact |
| 512x288 | 461 kbps | 300/300 pictures pixel-exact |
| 848x480 | 836 kbps | 600/600 pictures pixel-exact |
| 1280x720 | 2149 kbps | 600/600 pictures pixel-exact |
| 1920x1080 | 6222 kbps | 600/600 pictures pixel-exact |

“Pixel-exact” means the cropped planar I420 output matched an independent
FFmpeg/VideoToolbox reference for every picture in the regression segment. It
proves decode correctness, not real-time speed on every phone.

## What the current implementation includes

- Rolling finite-VOD and bounded live HLS media-playlist refresh.
- MPEG-TS PAT/PMT/PES, Annex-B H.264, ADTS AAC, continuity, PTS unwrap, and
  shared discontinuity epochs.
- Progressive 8-bit YUV 4:2:0 H.264 for the bounded Baseline/Main/High syntax
  exercised by the verified streams.
- CAVLC and CABAC I, P, and B pictures, including spatial and temporal Direct,
  intra 4x4/8x8/16x16, transform 4x4/8x8, supported inter partitions,
  weighted prediction, short-term DPB/list reordering, POC, MMCO 1, and
  in-loop deblocking.
- Pure-Dart AAC-LC decode with an audio-master playback clock.
- An asynchronous Android MediaCodec H.264 backend that renders to a Flutter
  texture, probes codec limits, applies bounded input backpressure, and
  recovers a recreated surface from a dependency-safe keyframe.
- Automatic fallback to a persistent Pure Dart H.264 worker isolate when the
  Android hardware backend is unavailable or fails.
- Background YUV-to-RGBA conversion for the Pure Dart video path.
- One in-flight image upload with latest-frame coalescing and viewport-sized
  output to reduce UI-isolate work and allocation pressure.
- Conservative dropping of sufficiently late disposable non-reference B
  pictures. Reference pictures, IDRs, P pictures, SPS, and PPS are never
  skipped by this policy.
- Manual quality selection and basic automatic quality switching.
- Seamless rendition changes: a selection is staged for a safe upcoming
  segment/IDR boundary instead of stopping and rebuilding current playback.
- Compatibility probing that rejects unsupported parameter-set or slice
  syntax before a rendition is admitted.
- Early rejection of explicitly advertised HEVC, AV1, VP9, and Dolby Vision,
  plus encrypted, fMP4-map, byte-range, gap, and I-frame-only HLS input that
  the current MPEG-TS pipeline cannot represent safely.
- App lifecycle recovery, bounded retries, rebuffer/switch/drop telemetry, and
  a long-running rolling-pump soak regression.
- Bounded segment queues, compressed-video retention, decoded PCM storage, and
  presentation reordering.

Unsupported or malformed syntax fails closed rather than being guessed.

## Quality behavior

**Manual** keeps the requested compatible rendition and applies the change at
the next safe boundary. The UI can briefly show `active → pending` while the
already-buffered segment finishes; audio and playback state continue.

**Auto** uses measured network throughput, buffer health, decoder/render
lateness, and the active Android codec's advertised limits. It can step up
when healthy and repeatedly step down while the network or device remains
behind.

Android MediaCodec is the preferred phone path for 720p and 1080p. Actual
smoothness still depends on the device codec, source frame rate, network, and
render budget; the quality selector may step down when health deteriorates.

The Pure Dart fallback is decode-correct through the verified 1080p streams,
but high-resolution software playback remains best-effort. A physical-device
720p measurement decoded the retained reference cadence at 22.21 fps and took
14.319 seconds for 10 seconds of source after conservative disposable-B
skipping; real-time playback required roughly 31.8 retained pictures/s. The
Pure Dart path therefore does not claim smooth mobile 720p60 or 1080p60.

## Run

This repository uses FVM. Run Flutter commands through `fvm flutter`.

```sh
fvm flutter pub get
fvm flutter run
```

In the app:

1. Leave the default Mux `.m3u8` URL or enter another compatible HLS/MP4 URL.
2. Choose **Auto** or a manual HLS quality.
3. Select **Build Queue (HLS/TS)**.
4. When the two-segment readiness gate opens, select **Play**.
5. A later quality change is staged and joined at a safe boundary without
   restarting playback.

Android audio uses AAudio and requires Android 8.0 / API 26 or newer.

## Playback architecture

```text
HLS/MP4 input
     |
     +--> bounded playlist/segment loader
     +--> MPEG-TS or MP4 demux
                   |
          timestamped access units
             /             \
            v               v
          video backend             AAC-LC worker
          /           \             file-backed PCM
         v             v                   |
 Android MediaCodec  Pure Dart worker   AAudio / AudioQueue
   Surface texture   YUV 4:2:0 frames      master clock
         |           render worker           |
         |          latest-frame slot        |
         +--------------+--------------------+
                        |
                  PTS scheduler
                        |
                  Flutter Texture/Image
```

Important implementation locations:

- `lib/player_page.dart` — playback session, compatibility probe, quality
  selection, and UI integration.
- `lib/src/hls_quality.dart` — manual/automatic rendition policy.
- `lib/src/hls_vod_session.dart` and `lib/src/hls_live_session.dart` — rolling
  HLS coordination.
- `lib/src/ts_h264_demux.dart` — stateful H.264 transport demux.
- `lib/src/decoder/h264_baseline_idr_decoder.dart` — H.264 picture decode.
- `lib/src/decoder/h264_decode_worker.dart` — persistent video worker isolate.
- `lib/src/decoder/android_h264_texture_decoder.dart` — Dart-facing Android
  hardware-video backend and texture lifecycle.
- `android/app/src/main/kotlin/com/example/ndvy_player/MainActivity.kt` —
  asynchronous MediaCodec/Surface implementation.
- `lib/src/playback_reliability.dart` — bounded playback-health telemetry.
- `lib/src/audio/` — AAC-LC decode, file-backed PCM, clock, and native sinks.
- `lib/src/render/` and `lib/pure_frame_view.dart` — background conversion,
  upload coalescing, and frame display.
- `lib/src/player_clock.dart` — audio-master sequential decode/presentation
  scheduling.

## Validation

The current completion snapshot passed:

```sh
fvm flutter analyze
fvm flutter test
```

Result: **633 tests passed and 2 intentional opt-in network tests skipped**.

The full network rendition regression is opt-in because it downloads and
decodes large public test segments:

```sh
fvm flutter test \
  --dart-define=MUX_FULL_RENDITION_REGRESSION=true \
  test/decoder/mux_x36xhzz_all_renditions_network_test.dart
```

That command passed all five Mux renditions at the current snapshot. Focused
tests additionally cover malformed input, CABAC/CAVLC syntax, POC/DPB/MMCO,
weighted prediction, Direct motion, transforms, deblocking, TS continuity,
quality selection, queue boundaries, audio timing, worker lifecycle, frame
coalescing, MediaCodec channel/lifecycle behavior, long-running queue
retention, compatibility gates, and rollback after failed candidate pictures.
An Android emulator smoke test additionally rendered the Mux stream through
`c2.goldfish.h264.decoder` with zero reported rebuffers and codec errors.

## Known limitations

- This remains a bounded experimental codec implementation, not a general
  replacement for all H.264, AAC, MP4, or HLS content.
- Android hardware decoding depends on MediaCodec availability and advertised
  geometry/rate limits. Auto quality is the recommended phone mode.
- Smooth software-only 720p60/1080p60 playback remains outside the measured
  Pure Dart performance envelope.
- HLS currently targets MPEG-TS H.264 plus ADTS AAC. fMP4/CMAF, encryption,
  DRM, and general `EXT-X-MEDIA` alternate-audio handling are unsupported.
- HEVC/H.265, AV1, VP9, and Dolby Vision are not decoded; explicit codec
  advertisements for them are rejected before rendition probing.
- Only progressive 8-bit 4:2:0 H.264 within the validated tool envelope is
  accepted. Interlaced, high-bit-depth, and other chroma formats are rejected.
- RGBA rendering currently uses limited-range BT.601; VUI color metadata is
  not yet propagated to the renderer.
- Rolling seek is limited to the common retained audio/video window.
- Android hardware video is the only native video backend. Other platforms use
  the Pure Dart H.264 path. Audio output is implemented for Android API 26+,
  iOS, and macOS.

## Current scope boundary

The current scope ends with a Dart-first player engine, Android MediaCodec
texture playback, automatic Pure Dart fallback, verified multi-rendition
software decode, seamless manual/basic automatic quality switching, lifecycle
recovery, bounded playback state, compatibility gates, and UI/render
coalescing. It does not claim universal codec/HLS support or guaranteed
720p60/1080p60 performance on every Android device. Apple hardware-video
acceleration, richer media-session integration, and broader formats remain
future work.
