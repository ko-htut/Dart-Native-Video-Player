# ndvy_player

Custom Dart-native video player project in Flutter.

This repository is not only about IDR thumbnails.  
The product direction is a full custom player stack written in Dart:

- HLS playlist handling
- MPEG-TS demux
- PES extraction
- H.264 parsing/decoding
- YUV to RGB conversion
- Flutter rendering
- Later: timeline playback, P/B frames, audio, and performance optimization

## Scope And Milestones

Milestone A is the first vertical slice of the larger custom-player vision.

Milestone A target:

- Load HLS stream
- Parse TS + extract H.264
- Decode IDR/keyframes
- Render still-frame thumbnails
- No audio, no full timeline playback yet

Primary planning docs:

- `📄 PROJECT_SCOPE_MILESTONE_A.md`
- `ARCHITECTURE.md`
- `TASK_BREAKDOWN.md`
- `SPRINT_PLAN.md`
- `H264_DECODER_DESIGN.md`

## Current Implementation

Implemented pipeline pieces:

- HLS master/media parsing
- TS packet parsing, PAT/PMT parsing
- Video PID extraction and PES to ES extraction
- Annex-B NAL splitting and IDR access unit grouping
- SPS parsing for frame dimensions
- Thumbnail rendering workflow in Flutter UI with state logs

Current decode path in app:

- Uses `h264` plugin for Android hardware-assisted frame decode
- Writes IDR AU to temporary `.h264` file and decodes to image
- Displays decoded images as thumbnails

Work still in progress for full custom player:

- Pure Dart IDR slice reconstruction (CAVLC + intra prediction)
- Continuous playback engine
- P/B frame support
- Audio decode/sync
- Isolate-based performance pipeline

## Patched `h264` Dependency

The project keeps `h264` enabled with a local patched copy:

- `third_party/h264_0_3_0`

`pubspec.yaml` contains:

- `h264: ^0.3.0`
- `dependency_overrides.h264.path: third_party/h264_0_3_0`

Patch reason:

- Upstream `h264-0.3.0` Android module is not compatible with current AGP defaults (`namespace` requirement)
- Plugin code needed cleanup for modern Flutter embedding compatibility

## Requirements

- Flutter SDK (`fvm` commands are used in this repo)
- Android SDK + Java 17
- Working device/emulator for runtime decode tests

## Setup

```bash
fvm flutter pub get
```

## Run

```bash
fvm flutter run
```

## Build

```bash
fvm flutter build apk --debug
```

APK output:

- `build/app/outputs/flutter-apk/app-debug.apk`

## Test Stream

Default stream used in docs and app:

- `https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8`

## Troubleshooting

If you see `:h264` Gradle/plugin problems:

1. Verify `dependency_overrides` for `h264` is still present in `pubspec.yaml`.
2. Run:
   - `fvm flutter clean`
   - `fvm flutter pub get`
3. Confirm `.flutter-plugins-dependencies` points `h264` to `third_party/h264_0_3_0`.

If runtime decode fails (`MediaCodec BAD_VALUE`, etc.):

- Check app log lines:
  - `SPS width=... height=...`
  - `decode request ...x...`
- Check Android logcat entries from `h264Reader` and `MediaCodec`.
- Try a baseline H.264 TS stream without DRM/fMP4.
# Dart-Native-Video-Player
