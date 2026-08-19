# NDVY Player Phase 1 White Paper

## Dart-native H.264/AAC playback for MP4 and HLS/MPEG-TS

**Status:** Phase 1 complete

**Snapshot date:** 2026-08-19

**Validation baseline:** 210 automated tests

## Abstract

NDVY Player is an experimental Flutter media pipeline that implements container
parsing, compressed-video decoding, compressed-audio decoding, timestamp
handling, and audio/video synchronization in Dart.

Phase 1 demonstrates two end-to-end paths:

- MP4 files carrying AVC/H.264 video and AAC-LC audio.
- HLS video-on-demand playlists carrying H.264 and ADTS AAC in MPEG transport
  streams.

The runtime does not use `video_player`, FFmpeg, MediaCodec, AVPlayer, or an
operating-system codec. Compressed media remains in Dart through demux and
decode. Flutter presents decoded RGBA frames. Decoded signed 16-bit PCM crosses
a narrow `dart:ffi` boundary to AAudio on Android or AudioQueue on Apple
platforms so that the operating system can drive the speaker.

This is a constrained software decoder, not a general-purpose replacement for
all H.264, AAC, MP4, or HLS implementations. Unsupported syntax is rejected
explicitly instead of being guessed.

## 1. Phase 1 outcome

Phase 1 establishes that a useful audiovisual playback pipeline can be built
without delegating compressed-media decoding to a native codec. The completed
system can:

1. Read a local Flutter asset or an HTTP(S) media source.
2. Demultiplex supported MP4 or HLS/MPEG-TS input.
3. Build timestamped H.264 and AAC access units.
4. Decode supported H.264 I/P pictures into planar YUV 4:2:0.
5. Decode AAC-LC access units into interleaved PCM.
6. Apply MP4 edit timing or transport-stream PTS alignment.
7. Use consumed PCM frames as the master media clock.
8. Decode dependent video pictures sequentially and present the newest picture
   due at that clock position.
9. Pause, replay, return to the start, and navigate to adjacent IDRs while
   flushing stale audio generations when state is reset.

Phase 1 intentionally does not claim full codec, container, adaptive-streaming,
or hardware-accelerated coverage.

## 2. Design principles

### 2.1 Compressed media stays in Dart

MP4 boxes, HLS playlists, MPEG-TS packets, PES packets, H.264 NAL units, and
AAC access units are parsed in Dart. H.264 reconstruction and AAC synthesis are
also performed in Dart. Only already-decoded PCM is sent to a platform API.

### 2.2 Decode order is preserved

H.264 reference pictures make decode order a correctness requirement. Access
units are never sorted merely to make their presentation timestamps look
monotonic. The sequential decode pump advances only after the current access
unit succeeds.

### 2.3 Malformed and unsupported input fails closed

Variable-length codes, RBSP trailing data, parameter-set relationships,
reference state, dimensions, timestamps, AAC transport continuity, and
platform sink generations are validated. A malformed stream raises a
contextual error instead of silently substituting coefficients or stale
references.

### 2.4 Tests use independent references

Important output is compared with independently decoded pixel and PCM data.
Network fixtures are frozen locally with source hashes so a remote playlist
change cannot alter deterministic tests.

## 3. End-to-end architecture

```text
Flutter asset / HTTP(S)
          |
          +---------------------------+
          |                           |
          v                           v
   MP4 box demux              HLS master/media parser
   avcC + esds                variant compatibility probe
   sample tables              MPEG-TS PAT/PMT/PES/ADTS
          |                           |
          +-------------+-------------+
                        |
             timestamped access units
                 /              \
                v                v
       Dart H.264 decoder   Dart AAC-LC decoder
       YUV 4:2:0 pictures   timestamped float PCM
                |                |
       limited-range       gap/overlap/edit trim
       BT.601 RGBA
       YUV -> RGBA          interleaved PCM16 timeline
                |                |
       Flutter frame view   bounded FFI PCM sink
                |                |
                +------ audio-master clock ------+
```

The current video decoder and RGBA conversion run serially in the Flutter Dart
isolate. AAC timeline construction runs in a worker isolate. Native sink queues
are bounded and apply backpressure.

## 4. MP4 pipeline

The MP4 path supports the classic sample-table layout used by the project
fixtures:

- AVC sample entries: `avc1` and `avc3` with `avcC` configuration.
- AAC sample entries: `mp4a` with `esds` and AudioSpecificConfig.
- Sample size and location: `stsz`, `stsc`, and `stco` or `co64`.
- Decode and presentation timing: `stts`, optional `ctts`, and `elst` edits.

AVC samples are split using the configured length-prefix size. SPS and PPS NAL
units are attached at random-access boundaries. AAC samples are passed as raw
AAC payloads using their parsed AudioSpecificConfig.

MP4 edit timing is applied in sample frames. AAC encoder priming before movie
time zero is decoded to preserve overlap state and then trimmed. Declared final
sample duration removes end padding without converting through a lossy
millisecond representation.

## 5. HLS and MPEG-TS pipeline

### 5.1 Playlist and variant selection

The HLS path parses master and media playlists, resolves relative URLs, and
prioritizes variants advertising Baseline AVC. A limited preflight reads up to
the first two transport-stream segments. It checks PAT, PMT, H.264 presence,
available SPS/PPS data, CAVLC flags, supported SPS fields when present, and
known unsupported PPS tools such as slice groups or 8x8 transforms. It does
not prove that every later slice is supported; the decoder remains the final
compatibility check.

This is a fixed compatibility selection, not adaptive bitrate switching.

### 5.2 Aligned component selection

Some older muxed masters place decoder-compatible Baseline video beside
HE-AAC, while a different synchronized muxed variant carries AAC-LC. When that
layout is advertised, NDVY Player can select video and audio from separate
variants after all of these checks pass:

1. Matching media-sequence numbers.
2. Matching discontinuity epochs.
3. Per-segment duration difference no greater than 0.5 seconds.
4. Cumulative boundary drift no greater than 0.5 seconds.
5. First demuxed audio/video PTS difference within 45,000 ticks of the shared
   90 kHz clock, with 33-bit rollover handled correctly.

If alignment fails, the AAC-LC component is rejected. The player does not
silently decode the advertised HE-AAC track as AAC-LC. This mechanism combines
aligned muxed variants; it is not `EXT-X-MEDIA` alternate-audio support.

### 5.3 Transport demultiplexing

The MPEG-TS packet model validates packet framing and exposes continuity,
discontinuity, and scrambling metadata. The reusable stateful PES assembler,
used by the AAC path and transport tests, discards partial data on gaps,
duplicates, discontinuities, or scrambled packets. PAT/PMT parsing identifies
H.264 stream type `0x1b` and ADTS AAC stream type `0x0f`.

PES assembly spans transport packets and segment boundaries. The start-code
prefix, declared PES length, PTS/DTS marker bits, and payload boundaries are
checked. The stream ID is retained as metadata rather than used as an
acceptance check. Annex-B H.264 data and ADTS AAC data may cross PES boundaries
without losing access-unit state.

The H.264 access-unit builder handles 3-byte and 4-byte Annex-B start codes,
AUD-delimited streams, slice boundary detection, SPS/PPS caching, and 90 kHz
timestamp unwrapping. Missing picture timestamps are interpolated while
retaining elementary-stream decode order.

## 6. H.264 decoder

### 6.1 Supported subset

The decoder targets progressive, 8-bit, YUV 4:2:0 syntax for H.264 profile IDs
66, 77, and 88 when the stream uses CAVLC and only I/P pictures. Implemented
reconstruction includes:

- Strict bit reading, EBSP-to-RBSP conversion, and Exp-Golomb parsing.
- SPS, PPS, and I/P slice-header parsing.
- CAVLC coefficient token, level, total-zero, and run decoding.
- I4x4, I16x16, chroma intra prediction, and I_PCM handling.
- Inverse quantization, luma/chroma DC transforms, and 4x4 inverse transform.
- P skips and supported inter partitions/subpartitions.
- Quarter-pixel six-tap luma interpolation and bilinear chroma interpolation.
- Edge extension for motion-compensated samples.
- In-loop luma/chroma deblocking with boundary strengths 0 through 4.
- Multiple slices belonging to the same picture.
- A sliding short-term decoded-picture buffer.
- Multiple active List 0 references with frame-number wrap, PicNum ordering,
  reference-list reordering, and per-partition reference selection.

The default resource guard limits a coded dimension to 4096 pixels and luma to
`4096 x 2304` samples. Callers may lower or raise these limits explicitly.

### 6.2 Explicit exclusions

The decoder rejects CABAC, B pictures, weighted prediction, long-term
references, adaptive reference marking, unsupported frame-number gaps, FMO,
interlaced pictures, 8x8 transforms or scaling matrices, high bit depth, and
chroma formats other than 4:2:0.

These exclusions are part of the correctness model. They prevent an apparently
successful decode from propagating corrupted reference pictures.

## 7. AAC-LC decoder

The AAC decoder accepts Audio Object Type 2 with one 1024-sample raw-data block
and channel configuration 1 or 2. The implementation includes:

- Single-channel and common-window channel-pair elements.
- Long and eight-short window sequences.
- Sine and KBD windows.
- Scale-factor and spectral Huffman codebooks 1 through 11.
- Pulse data, mid/side stereo, intensity stereo, PNS, and TNS.
- IMDCT, windowing, overlap-add state, and normalized float output.

AAC frames are converted to interleaved signed PCM16 after timestamp placement.
Timestamp gaps become silence; overlaps are trimmed. MP4 and ADTS inputs share
the same raw AAC decode path.

The decoder explicitly rejects HE-AAC/SBR/PS, 960-sample frames, PCE-based or
other multichannel layouts, CCE/LFE elements, gain control, and multiple raw
data blocks per access unit.

## 8. Synchronization and playback

### 8.1 Audio is the master clock

Once a PCM sink is active, its consumed-frame position is the authoritative
media clock. Video presentation follows that position instead of a separate
wall clock. Video-only input falls back to a Stopwatch-based clock.

The player polls the audio position, converts frames to media time, and asks a
serial decode pump to process every H.264 access unit due at that time. If the
clock advances during a slow decode, the pump continues in dependency order
and presents only the latest completed due picture.

### 8.2 Transport safety

Play, pause, IDR navigation, and replay commands are serialized so overlapping
UI actions cannot overtake an in-flight sink operation. Every audio load or
position reset uses a new generation. Stale queued PCM from an older generation
is rejected.

Seek Start and Previous/Next IDR navigation reset decoder reference state at an
IDR, flush or reposition PCM as required, and re-establish the shared clock.
Phase 1 does not expose arbitrary timeline scrubbing. If audio ends before valid
video, video can finish against a wall clock instead of freezing on the final
audio timestamp.

## 9. Platform boundary

The operating-system layer is intentionally codec-free:

- Android API 26 and newer use AAudio in streaming mode.
- iOS and macOS use AudioQueue through AudioToolbox.
- Both paths accept interleaved signed 16-bit PCM and report consumed frames.
- Sink queues are bounded and `enqueue` applies backpressure.

There is no Kotlin or Swift decoder and no method-channel media path. This
boundary is still native I/O, so the accurate description is a **Dart-native
codec pipeline**, not a wholly pure-Dart application.

## 10. Mux `x36xhzz` case study

The public Mux test master demonstrates why compatibility selection must inspect
both codec features and component timing:

```text
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
```

No single advertised variant matches the current Dart decoder completely. The
compatible 320x184 Constrained Baseline video variant uses CAVLC and I/P
pictures but carries HE-AAC. AAC-LC is available in a synchronized sibling
variant whose video is unsupported High-profile syntax.

At runtime the player therefore selects:

- 320x184 Baseline/CAVLC video with multiple short-term references.
- 44.1 kHz stereo AAC-LC from the lowest-bandwidth aligned AAC-LC sibling.

For the frozen first segment:

- The video segment SHA-256 is
  `b82fcf4dbcec2d8fab7d94bdd48b070aa6e74d7240b1965a0b28c128d6858477`.
- All 300 pictures decode at 320x184.
- The complete planar I420 sequence SHA-256 is
  `dce6f07c2d502b9ccde7ea41a4095261fea7957f1b04d4c845cbd827226641ec`,
  exactly matching an independent FFmpeg decode.
- The AAC sibling segment SHA-256 is
  `ae5f75bb810f13a22346d5b730dfc18f05efe95539bd5376fc7525314832327d`.
- It contains 431 AAC-LC access units.
- Its first audio PTS is 900909; the selected video's first PTS is 900000.
  The +909 tick difference is 10.100 ms and becomes 445 leading PCM frames at
  44.1 kHz.

A manual macOS release-app smoke test dynamically selected these components and
observed 6,000 video access units plus 8,329 AAC access units for the safety
window. Playback advanced under the audio clock, displayed decoded P pictures
through approximately 11 seconds in the final run, and held a stable position
after pause. This manual observation does not claim that the complete 3:20
window was watched.

## 11. Deterministic validation

The Phase 1 suite contains 210 tests. Its important end-to-end references are:

| Fixture | Coverage | Validation/reference |
| --- | --- | --- |
| `baby.mp4` | 141 H.264 pictures, IDR restarts, missing-reference rejection | Full I420 sequence SHA-256 `ccd20c092507bb8150d0d8759de51658e6314e5c3a6360f7bc18b7f438f23bf9` |
| `baby_aac.mp4` | 277 AAC-LC access units and exact 1024-frame priming trim | 2,252 sparse FFmpeg PCM samples plus RMS, peak, and channel-tone checks |
| `butterfly_dart.mp4` | 226 video pictures and 353 AAC-LC access units | Structural end-to-end MP4 decode; no independent full-output golden |
| Butterfly HLS fixture | Master/media HTTP fetch, 4 TS segments, 226 video pictures, 353 AAC units | Structural end-to-end decode with no continuity/scrambling errors; no independent full-output golden |
| Mux low segment | 300 multi-reference H.264 pictures | Full I420 hash equals FFmpeg |
| Mux AAC-LC sibling | 431 AAC units and +909-tick cross-variant alignment | 3,509 sparse FFmpeg 7.1.1 PCM samples |

Focused suites also cover CAVLC tables and malformed inputs, prediction modes,
inverse transforms, motion-vector prediction, fractional interpolation,
deblocking, reference-list construction, MP4 sample tables, ADTS splitting,
TS continuity, PCM timeline placement, sink generations, playback scheduling,
and media-type UI routing.

The Phase 1 completion snapshot passed:

```sh
fvm flutter analyze
fvm flutter test --reporter compact
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  fvm flutter build macos --release
```

## 12. Reliability and resource controls

- H.264 parsing never rewinds and retries a different VLC table.
- Truncated codes report bit offset and syntax context.
- Reference-picture continuity is checked before P-picture reconstruction.
- Cross-rendition audio is admitted only after playlist and PTS validation.
- PES and ADTS assemblers retain state across packet and segment boundaries.
- Audio sink writes are generation-scoped and bounded.
- Decoder dimensions are checked before large picture allocation.
- Network playback is enabled only through the required platform entitlements
  and manifest permissions.

## 13. Known limitations

Phase 1 has deliberate boundaries:

- HLS queues at most the first 20 MPEG-TS segments. For the Mux case study this
  is approximately 3 minutes 20 seconds, not the full 10 minute 34 second VOD.
- HLS is VOD-oriented and does not refresh a moving live window.
- There is no adaptive bitrate switching after the initial selection.
- `EXT-X-MEDIA`, LATM/LOAS, fMP4/CMAF, encryption, and DRM are unsupported.
- AAC is decoded into an in-memory PCM timeline before playback. Loading the
  full Mux VOD this way would create an unsafe mobile memory peak.
- Video decode and color conversion are software paths and may miss real-time
  deadlines at high resolution or frame rate.
- Rendering currently uses fixed limited-range BT.601 conversion; VUI color
  metadata is not propagated.
- HLS picture detection assumes AUDs or normal raster-order slice boundaries.
- Runtime video PES concatenation does not yet enforce continuity-counter,
  discontinuity, or scrambling metadata; the stateful AAC assembler and
  transport test pipeline do.
- The H.264 and AAC exclusions listed above remain unsupported.
- PCM output is implemented only for Android API 26+, iOS, and macOS.
- Android audio focus and Apple interruption notifications are not yet a full
  production media-session implementation.

## 14. Phase 2 direction

The recommended Phase 2 sequence is:

1. Replace the long in-memory PCM timeline with a file-backed or incremental
   audio source, then allow the full VOD segment list.
2. Add incremental HLS segment loading, retry policy, bounded compressed-media
   caches, and live-window refresh.
3. Add `EXT-X-MEDIA` audio groups and fMP4/CMAF demultiplexing.
4. Move video decode and color conversion off the UI isolate and measure
   device-specific frame budgets.
5. Propagate VUI color metadata and add color-reference goldens.
6. Expand H.264 coverage only behind independent pixel goldens: weighted
   prediction, adaptive reference marking, 8x8 tools, CABAC, then B pictures.
7. Add platform audio-focus, interruption, route-change, and lifecycle policy.

Phase 2 should preserve the Phase 1 rule that new syntax is enabled only when
malformed-input tests and an independent decoded-output reference exist.

## 15. Repository map

- `lib/src/mp4/mp4_demux.dart` — MP4 boxes and AVC/AAC sample tables.
- `lib/src/hls.dart` — playlists, variant selection, and alignment validation.
- `lib/src/ts_*.dart`, `lib/src/pes_pts.dart` — MPEG-TS, PSI, PES, and PTS.
- `lib/src/h264_nal.dart`, `lib/src/access_unit_pts.dart` — NAL/access-unit and
  timestamp association.
- `lib/src/decoder/` — H.264 parsing, reconstruction, references, motion
  compensation, and deblocking.
- `lib/src/audio/aac/` — AAC-LC syntax, spectral decode, and filterbank.
- `lib/src/audio/pcm_timeline.dart` — timestamped PCM placement and trimming.
- `lib/src/audio/pcm_sink*.dart` — codec-free AAudio/AudioQueue FFI sinks.
- `lib/src/audio/audio_playback_controller.dart` — bounded PCM feeding and
  playback-head tracking.
- `lib/src/player_clock.dart` — audio-master clock and sequential video pump.
- `lib/player_page.dart` — source selection, queue construction, and controls.

## 16. Reproducibility and attribution

Use FVM for every Flutter command:

```sh
fvm flutter pub get
fvm flutter analyze
fvm flutter test
```

Fixture generation or source-retrieval details, source hashes, encoder-priming
conventions, and golden-data descriptions are retained beside the fixtures
under `test/`.

AAC Huffman and scale-factor-band tables were independently ported to Dart from
the MIT-licensed OxideAV AAC project. The required attribution is retained in
`lib/src/audio/aac/NOTICE`.

The archived `third_party/h264_0_3_0` package is not the active decoder and is
not part of the Phase 1 runtime pipeline.
