# NDVY Player White Paper

## Dart-first H.264/AAC playback for MP4 and HLS/MPEG-TS

**Status:** completed implementation snapshot

**Snapshot date:** 2026-08-21

**Validation snapshot:** 633 tests passed; 2 opt-in network tests intentionally
skipped; all five Mux `x36xhzz` rendition regressions passed pixel-exactly

## Abstract

NDVY Player is an experimental Dart-first Flutter playback system. Container
parsing, transport demultiplexing, access-unit construction, AAC-LC decoding,
timestamp management, adaptive quality policy, and audio/video scheduling are
implemented in Dart without `video_player` or FFmpeg. Video has two backends:
an asynchronous Android MediaCodec-to-texture path and a custom Pure Dart
H.264 decoder used as the correctness reference and automatic fallback.

The current implementation extends the earlier bounded I/P proof into a
rolling HLS player with a verified CABAC I/P/B software decoder, Android
hardware acceleration, manual and basic automatic quality selection, seamless
rendition-boundary changes, bounded storage, lifecycle recovery, telemetry,
and late-frame/render coalescing. All five renditions of the public Mux test
master decode pixel-exactly through the Pure Dart reference path.

Correct decode and real-time throughput are separate properties. This work
establishes software correctness through 1080p and uses MediaCodec as the
preferred Android production path. It does not claim smooth software-only
720p60 or 1080p60 playback, nor identical hardware performance on every
device. Automatic quality selection responds to network, buffer, and device
health by stepping down.

## 1. Current outcome

The current implementation demonstrates an end-to-end system that can:

1. Read local or HTTP(S) MP4 and HLS inputs.
2. Parse HLS master/media playlists and probe advertised MPEG-TS renditions.
3. Deliver segments in order with bounded prefetch, retry, cancellation, and
   backpressure.
4. Preserve PAT/PMT/PES, Annex-B, ADTS, continuity, timestamp, parameter-set,
   and access-unit state across TS segment boundaries.
5. Decode H.264 through asynchronous Android MediaCodec when supported, or
   through the validated progressive 8-bit 4:2:0 CAVLC/CABAC I/P/B Pure Dart
   implementation in a persistent worker isolate.
6. Decode AAC-LC to file-backed PCM and use consumed PCM as the master clock.
7. Reorder decoded video by PTS while preserving compressed decode order.
8. Select HLS quality manually or automatically.
9. Stage a rendition change for a safe future segment/IDR boundary without
   stopping playback or discarding the current clock.
10. Coalesce late presentation and image-upload work to the most recent useful
    frame.
11. Recover Android surface/lifecycle failures from a dependency-safe keyframe
    and fall back to the Dart decoder on terminal hardware errors.
12. Reject unsupported codec advertisements, playlist features, or malformed
    syntax before they can silently corrupt canonical decoder state.

It remains a constrained player and codec implementation, not a general media
framework replacement.

## 2. Design principles

### 2.1 The control plane stays in Dart

MP4 boxes, playlists, MPEG-TS packets, PES, H.264 NAL units, and AAC access
units are parsed in Dart. Quality policy, timestamps, queueing, and playback
state also remain in Dart. AAC synthesis and the fallback H.264 reconstruction
are Pure Dart implementations. On Android, selected compressed H.264 access
units may cross a MethodChannel to MediaCodec and render to a Flutter texture.
Already-decoded signed PCM crosses a narrow `dart:ffi` boundary to AAudio.
Apple audio uses AudioQueue, while video currently remains on the Pure Dart
path there.

### 2.2 Decode order and state are transactional

In the Pure Dart backend, reference pictures require compressed decode order
even when presentation PTS is reordered. POC, DPB, frame number, picture
identity, statistics, and memory management are staged locally. A candidate
picture publishes them only after the entire picture has decoded,
reconstructed, filtered, cropped, and passed reference marking. A failure
leaves the prior canonical state reusable. MediaCodec uses generation-checked
input and resumes from a dependency-safe keyframe after a surface or backend
transition.

### 2.3 Unsupported syntax fails closed

The parameter-set and slice probe removes known-incompatible renditions before
playback. Runtime parsing remains authoritative. Bit offsets and syntax context
are reported on malformed input; no alternative VLC table, prediction mode,
reference, or coefficient value is guessed.

### 2.4 Audio owns media time

The consumed PCM position is the master media clock whenever audio is present.
Video follows that clock. Slow decode does not stall audio; the presenter keeps
the newest completed frame due at the current audio position.

### 2.5 Correctness, hardware capability, and smoothness are separate

Independent I420 hashes establish Pure Dart reconstruction correctness.
MediaCodec capability queries establish only advertised hardware limits;
device benchmarks, buffer health, frame-render callbacks, and lateness counters
establish whether playback meets a real-time budget. A correct or accepted
1080p stream is not described as smooth unless it also meets timing on the
target device.

## 3. End-to-end architecture

```text
Flutter asset / HTTP(S)
          |
          +-----------------------------+
          |                             |
          v                             v
     MP4 demux                  HLS master/media parser
  avcC/esds/tables         compatibility + quality policy
          |                             |
          |                   bounded MPEG-TS loader
          |                   PAT/PMT/PES/ADTS/Annex-B
          +--------------+--------------+
                         |
              timestamped access units
                  /                \
                 v                  v
                  video backend             AAC-LC worker
                  /           \             file-backed PCM
                 v             v                   |
       Android MediaCodec   Pure Dart worker   AAudio/AudioQueue
        Surface texture    reordered YUV          master clock
                 |         render worker              |
                 |       latest-frame mailbox         |
                 +---------------+--------------------+
                                 |
                           PTS scheduler
                                 |
                       Flutter Texture/Image
```

Network demultiplexing is small relative to video reconstruction. The dominant
video cost is pixel-domain motion compensation, weighting, and deblocking.

## 4. H.264 video backends and scope

### 4.1 Pure Dart reference and fallback decoder

The Pure Dart decoder accepts the bounded progressive, 8-bit, YUV 4:2:0
syntax needed by the verified Baseline/Main/High streams. Implemented tools
include:

- CAVLC and CABAC entropy decoding.
- I, P, and B pictures.
- Intra 4x4, 8x8, and 16x16 prediction plus chroma intra prediction.
- 4x4 and 8x8 inverse quantization/transform paths.
- P and B skips, 16x16, 16x8, 8x16, and verified 8x8 subpartitions.
- Quarter-pixel luma and bilinear chroma motion compensation with edge
  extension.
- Explicit weighted P prediction and implicit weighted bi-prediction.
- Spatial and temporal Direct B prediction.
- Short-term reference lists, PicNum wrap/reordering, selected references,
  picture-order-count type 0, and sequential MMCO 1 marking.
- In-loop luma/chroma deblocking with stable reference-picture identity.
- Multiple slices belonging to one picture where supported by the stream.

This list describes an evidence-backed subset, not complete H.264 compliance.
Interlaced coding, high bit depth, non-4:2:0 chroma, long-term-reference tools,
and syntax outside the implemented bounds are rejected.

The default resource guard caps each coded dimension at 4096 pixels and luma
storage at `4096 x 2304` samples. Callers may choose tighter limits.

### 4.2 Android MediaCodec texture backend

Android first probes an H.264 decoder's surface support, maximum dimensions,
and achievable frame rate. Accepted Annex-B access units are queued through a
bounded asynchronous bridge; MediaCodec renders output directly to a Flutter
`SurfaceProducer` texture rather than copying decoded YUV/RGBA frames through
Dart. Input acceptance and rendered-frame callbacks retain the existing Dart
PTS scheduler and telemetry.

SPS/PPS configure the codec lazily at a dependency-safe point. A recreated
Flutter surface invalidates the codec generation and triggers replay from a
safe keyframe. Terminal codec errors disable the hardware backend and resume
through the Pure Dart decoder. Hardware decode is therefore an acceleration
backend, not a replacement for the reference implementation or its tests.

The Android hardware route accepts compatible CABAC MP4 video within the
queried codec geometry. The Pure Dart MP4 route retains its stricter bounded
syntax validation.

## 5. AAC-LC and the media clock

The pure-Dart AAC decoder supports Audio Object Type 2, 1024-sample access
units, mono/stereo layouts, long and short windows, sine/KBD windows, spectral
codebooks 1–11, pulse data, mid/side and intensity stereo, PNS, and TNS.

Decoded audio is written to a growing file for finite rolling VOD or a bounded
circular file for live playback. Gap/overlap placement and MP4 priming/final
padding are applied in sample frames. The playback controller feeds bounded
PCM chunks to AAudio on Android or AudioQueue on Apple platforms and derives
the shared media time from samples actually consumed.

HE-AAC/SBR/PS, 960-sample frames, general multichannel/PCE layouts, CCE/LFE,
gain control, and multiple raw-data blocks remain unsupported.

## 6. Rolling HLS pipeline

### 6.1 Bounded delivery

Each selected media playlist uses an ordered loader with a default four-segment
prefetch window, a 32 MiB response cap, bounded retries, cancellation, and
consumer backpressure. Completed responses waiting behind an earlier media
sequence count against the same window.

The video queue is appendable and capped at 1,200 resident access units.
Consumed-prefix compaction retains a dependency-safe IDR tail. Persistent AAC
decode writes bounded chunks to file-backed PCM rather than accumulating the
entire decoded timeline in the Dart heap.

### 6.2 Stateful transport boundaries

The transport demuxers carry PSI, PID, continuity, PES, elementary byte tails,
parameter sets, access-unit construction, ADTS, and unwrapped 90 kHz timestamps
across ordinary segment boundaries. A new segment explicitly starts a boundary
epoch without treating a new-PES continuity jump as damaged concatenation.
Actual corruption drops partial state and gates dependent video until a valid
random-access point.

### 6.3 Finite and live sessions

Finite VOD begins after a two-segment dependency-safe readiness gate and keeps
loading behind playback. Live HLS refreshes the selected media playlist,
de-duplicates media sequences, handles `#EXT-X-ENDLIST`, and rejects expiry,
rewind, or mutation that cannot be reconciled safely. The live audio window is
capped by the smaller of five minutes or 64 MiB.

The current scope targets clear MPEG-TS H.264 and ADTS AAC. Playlist parsing
fails early on encryption/session keys, fMP4 initialization maps, byte-range
segments, declared gaps, and I-frame-only media. Explicit HEVC/H.265, AV1,
VP9, and Dolby Vision codec advertisements are removed before rendition
probing. General fMP4/CMAF, DRM, and alternate-audio group handling remain
outside scope.

## 7. Quality selection and seamless changes

The public Mux master advertises five compatible tested renditions:

| Resolution | Bandwidth | Pictures in first complete segment | Result |
| --- | ---: | ---: | --- |
| 320x184 | 246 kbps | 300 | Pixel-exact |
| 512x288 | 461 kbps | 300 | Pixel-exact |
| 848x480 | 836 kbps | 600 | Pixel-exact |
| 1280x720 | 2149 kbps | 600 | Pixel-exact |
| 1920x1080 | 6222 kbps | 600 | Pixel-exact |

Manual selection records a target rendition. It does not stop or rebuild the
active decoder immediately. The session finishes already-buffered media and
joins the new rendition at a safe upcoming segment/IDR boundary, preserving
audio-clock continuity. The UI reports `active -> pending` during the change.

Automatic selection combines measured download throughput, buffered duration,
playback health, and the active Android codec's advertised limits. It can
upgrade after sustained headroom. Persistent decode/render lateness or buffer
pressure can trigger repeated step-downs rather than only one downgrade per
incident. Compatibility probing and explicit `CODECS` filtering prevent a
bitrate decision from selecting a rendition outside the active backend's
validated envelope.

## 8. Scheduling and rendering

On Android hardware, MediaCodec owns compressed decode asynchronously and
renders directly to a texture. Its input queue is bounded, output callbacks
feed playback telemetry, and surface generations reject stale work. On the
software path, one persistent worker isolate owns H.264 state so picture
references never cross generations accidentally and synchronous
reconstruction does not run on the Flutter UI isolate. Software-decoded
pictures enter a bounded presentation-order structure.

For high-resolution playback, a conservative lateness policy may omit an
access unit only when every VCL NAL proves it is a non-reference B picture.
IDR, P, reference B, SPS, and PPS units are never omitted. Original indices and
timestamps are retained, so playback and audio time are not renumbered.

YUV-to-RGBA conversion also runs off the UI isolate and targets the physical
viewport rather than allocating a full-resolution upload unnecessarily. The
view permits exactly one image decode/upload in flight and replaces a single
pending snapshot with the newest frame. Superseded render work is discarded
without queue growth, and the video subtree is isolated behind a repaint
boundary. This conversion/upload path is bypassed by the Android texture
backend.

The player observes app lifecycle and surface availability. Backgrounding
pauses the media clock/audio sink; resuming restores playback, and a recreated
hardware surface re-enters from a safe keyframe. Telemetry records rebuffers,
rebuffer duration, recoveries, rendition switches, dropped/coalesced frames,
and peak retained access units.

## 9. Validation evidence

The completion commands were:

```sh
fvm flutter analyze
fvm flutter test
fvm flutter test \
  --dart-define=MUX_FULL_RENDITION_REGRESSION=true \
  test/decoder/mux_x36xhzz_all_renditions_network_test.dart
```

The deterministic suite passed **633 tests**, with **2 intentional opt-in
network tests skipped**. The network rendition regression passed all five
resolutions and every picture listed in Section 7 matched independent
FFmpeg/VideoToolbox cropped-I420 output.

Coverage includes:

- Parameter-set, CAVLC, CABAC, and truncated-input validation.
- Exact I/P/B reconstruction over full reference segments.
- POC, DPB, list ordering/reordering, MMCO, weighted prediction, spatial and
  temporal Direct, transforms, motion compensation, and deblocking.
- Candidate-picture failure followed by exact retry, proving transactional
  state rollback.
- MPEG-TS continuity, segment-boundary PES/ADTS/Annex-B carry, discontinuity
  epochs, and timestamp alignment.
- Rolling and live queue bounds, cancellation, starvation/resume, and sealing.
- Manual/automatic rendition policy and seamless boundary transitions.
- Worker isolate lifecycle, disposable-B classification, presentation bounds,
  render coalescing, widget disposal, MediaCodec bridge behavior, surface
  recovery, and long-running rolling-pump retention.
- Explicit codec and unsupported HLS-feature compatibility gates.
- AAC syntax, file-backed PCM, sample placement, native sink generations, and
  audio-master scheduling.

An Android emulator smoke test loaded and played the public Mux master through
`c2.goldfish.h264.decoder`, rendered through the Flutter texture, and reported
zero rebuffers, recoveries, and codec errors during the observed run. This is
an integration check, not a physical-device throughput benchmark.

## 10. Performance evidence

On an Apple M5 Max, a warmed standalone Dart JIT decode of the frozen
1236x720/approximately-30-fps 250-picture SFUX segment took 6.468 seconds
(38.65 decoded pictures/s). A self-contained AOT executable stabilized near
36.36 pictures/s. YUV-to-RGBA conversion averaged 2.804 ms per full 1236x720
frame in the earlier SFUX benchmark; decoder reconstruction remained the
dominant cost.

Sampling attributed most exclusive Dart-source time to motion compensation,
weighted prediction, and deblocking. CABAC arithmetic and transforms were a
small fraction. The luma/chroma hot loops were subsequently reduced to direct
indexing for in-bounds blocks while retaining the normative border path and
pixel-exact regressions.

On a physical Pixel 10 Pro Fold, the 720p60 Mux segment contains 600 pictures
over ten seconds. Conservative removal of 282 disposable non-reference B
pictures leaves 318 pictures required for reference-correct reconstruction.
The worker decoded them in 14.319 seconds, or 22.21 pictures/s, below the
roughly 31.8 pictures/s retained cadence needed for real time. 1080p has a
larger deficit.

For the Pure Dart path, therefore:

- 720p and 1080p correctness is verified.
- Smooth phone 720p60/1080p60 is not a current implementation claim.
- Auto mode may settle on a lower device-capable rendition.
- Manual high-resolution selection remains available as best effort.

Android MediaCodec removes the Pure Dart reconstruction and RGBA-upload costs
from the normal Android path. It is the preferred route for 720p/1080p, but
smoothness still depends on the physical device codec, source cadence, network,
and rendering budget. The emulator smoke test is not used to claim universal
high-resolution throughput.

## 11. Resource controls

- Playlist responses default to 1 MiB; TS segment responses default to 32 MiB.
- Segment prefetch and delivery are bounded and ordered.
- Video access-unit retention is capped and compacted at dependency boundaries.
- Reference pictures are bounded by H.264 DPB validation.
- Live PCM uses a circular retained window; finite PCM is file-backed.
- Worker messages preserve ordering and generations reject stale results.
- Presentation reordering, render conversion, pending uploads, and decoded
  output each have explicit bounded retention.
- Decoder dimension/sample guards run before large picture allocation.
- MediaCodec input, surface generations, pending presentation, and hardware
  fallback transitions are bounded or generation-checked.

These controls bound individual subsystems. They do not make high-resolution
software decode inexpensive; motion-compensation and frame storage still scale
with coded area and frame cadence.

## 12. Known limitations

- The Pure Dart decoder implements the validated H.264 subset, not all
  profiles, levels, supplemental tools, or malformed encoder behaviors.
- Smooth software-only 720p60/1080p60 playback is outside the measured mobile
  envelope.
- Android hardware behavior and limits vary by device; MediaCodec support does
  not guarantee every advertised resolution/frame-rate combination is smooth.
- VUI color metadata is not propagated; rendering uses limited-range BT.601.
- HLS support is MPEG-TS oriented. fMP4/CMAF, encryption, DRM, and general
  alternate-audio groups are unsupported.
- HEVC/H.265, AV1, VP9, and Dolby Vision are rejected rather than decoded.
- Live refresh follows one selected media playlist; it does not provide a DVR
  archive after expired data has left the retained window.
- Seek operations are constrained to retained dependency-safe audio/video
  ranges.
- Android audio requires API 26 or newer; other supported PCM sinks are iOS
  and macOS.
- Audio focus, route changes, interruptions, and system media controls are not
  yet a complete production media-session implementation.

## 13. Current boundary and next direction

The current implementation closes with:

- Verified multi-rendition CABAC I/P/B software decoding.
- Pixel-exact output through 1080p for the reference master.
- Android MediaCodec-to-texture acceleration with capability probing, surface
  recovery, and automatic Pure Dart fallback.
- Seamless manual and basic automatic quality changes.
- Buffer/device-aware downgrade behavior, lifecycle recovery, and playback
  health telemetry.
- Background software decode/render work and bounded latest-frame
  presentation.
- Strict early compatibility gates for unsupported codecs and HLS features.

MediaCodec is included in the current Android completion claim. The Pure Dart
decoder remains the correctness reference, diagnostic path, and fallback. A
future native Apple video backend such as VideoToolbox could provide the same
division of responsibilities on iOS/macOS.

Other future work may include VUI-aware color conversion, fMP4/CMAF,
alternate-audio groups, richer ABR estimation, full media-session policy, and
additional independently verified codec syntax.

## 14. Repository map

- `lib/player_page.dart` — source preparation, compatibility probing, quality
  selection, controls, and frame presentation.
- `lib/src/hls*.dart` — playlists, bounded fetch, rolling/live sessions, and
  rendition policy.
- `lib/src/ts_h264_demux.dart`, `lib/src/ts_*.dart`, and
  `lib/src/pes_pts.dart` — stateful MPEG-TS, PES, Annex-B, ADTS, continuity,
  and timestamps.
- `lib/src/decoder/` — H.264 syntax, prediction, reconstruction, DPB, POC,
  motion, transforms, and filtering.
- `lib/src/decoder/h264_decode_worker.dart` — persistent decode isolate.
- `lib/src/decoder/android_h264_texture_decoder.dart` — Dart-facing MediaCodec
  backend, generation handling, and texture events.
- `android/app/src/main/kotlin/com/example/ndvy_player/MainActivity.kt` —
  asynchronous MediaCodec and `SurfaceProducer` implementation.
- `lib/src/playback_reliability.dart` — rebuffer/recovery/switch/drop telemetry.
- `lib/src/audio/` — AAC-LC, file-backed PCM, playback clock, and FFI sinks.
- `lib/src/render/`, `lib/src/yuv.dart`, and `lib/pure_frame_view.dart` —
  conversion, coalescing, and Flutter image display.
- `lib/src/player_clock.dart` — compressed-order decode and PTS presentation.
- `test/decoder/mux_x36xhzz_all_renditions_network_test.dart` — opt-in complete
  first-segment multi-rendition pixel regression.

## 15. Reproducibility and attribution

Use FVM for all Flutter commands:

```sh
fvm flutter pub get
fvm flutter analyze
fvm flutter test
```

The public network regression is opt-in and depends on the external Mux test
master remaining available. Deterministic frozen fixtures, identities, source
hashes, and golden notes are retained beside their tests.

AAC Huffman and scale-factor-band tables were independently ported to Dart from
the MIT-licensed OxideAV AAC project. The required attribution is retained in
`lib/src/audio/aac/NOTICE`.

The archived `third_party/h264_0_3_0` package is not the active decoder.
