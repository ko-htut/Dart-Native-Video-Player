# NDVY Player — Pure Dart Video Playback (MP4 First)

This project is an experiment to build a **pure Dart** video playback pipeline (no `video_player`, no native codecs).
Because HLS+TS adds a lot of complexity, we first validate the decoder using **MP4** (clean sample boundaries).
After MP4 works, we return to HLS/TS with confidence.

---

## Goal

✅ Render a **correct picture** from H.264 Baseline streams using pure Dart.

Non-goals (for now):
- Audio decode (AAC)
- P-frames / motion compensation
- Hardware acceleration
- Full HLS live streaming features

---

## Why MP4 First?

HLS TS pipeline includes:
- playlist logic
- TS packets
- PAT/PMT PID detection
- PES reassembly
- PTS stitching
- access unit boundary detection

MP4 removes most of that and lets us focus on:
- MP4 demux
- H.264 NAL extraction
- decoder correctness
- renderer correctness

---

## Project Structure (Suggested)

---
mp4/
  mp4_demux.dart
  mp4_boxes.dart
  mp4_samples.dart

h264/
  bitreader.dart
  exp_golomb.dart
  rbsp.dart
  sps.dart
  pps.dart
  cavlc.dart
  cavlc_coeff_token_tables.dart
  inv_transform.dart
  h264_baseline_idr_decoder.dart

yuv/
  yuv420_to_rgba.dart

---


---

## Milestones

### M0 — MP4 Mode Switch + Debug Overlay
**Goal:** Add MP4 build path without touching the decoder.

Features:
- [ ] Add UI button: **Build Queue (MP4)**
- [ ] Keep existing: Play / Pause / Seek
- [ ] Debug overlay:
  - [ ] Frame width/height
  - [ ] avgY/minY/maxY
  - [ ] PPS entropyCodingModeFlag (CABAC check)
  - [ ] Queue size and current PTS

Done when:
- MP4 queue builds and playback loop runs
- At least 30 frames in queue

---

### M1 — Minimal MP4 Demux (Video Only, avc1)
**Goal:** Parse MP4 boxes enough to extract video samples.

Features:
- [ ] Parse MP4 top-level boxes:
  - [ ] `ftyp` (optional)
  - [ ] `moov`
  - [ ] `trak` (video)
- [ ] Parse sample tables:
  - [ ] `stsz` sample sizes
  - [ ] `stco` or `co64` chunk offsets
  - [ ] `stsc` sample-to-chunk map
  - [ ] `stts` decode time deltas (PTS)
  - [ ] `ctts` (optional, skip first version)
- [ ] Parse codec config:
  - [ ] `stsd` -> `avc1` -> `avcC`
  - [ ] Extract SPS/PPS
  - [ ] Read NAL length prefix size (1/2/4 bytes)

Done when:
- Log shows:
  - SPS count, PPS count
  - nalLengthSize
  - video sampleCount

---

### M2 — Build Access Units from MP4 Samples
**Goal:** Convert MP4 samples into the same `TimestampedAccessUnit` format used by your player.

Features:
- [ ] Read each sample bytes from `mdat` using computed offsets
- [ ] Split into NAL units using AVCC length prefix
- [ ] AU building:
  - [ ] Include SPS/PPS at start (and before IDR if needed)
  - [ ] `hasIdr = true` when `nal_unit_type == 5`
  - [ ] PTS from `stts` + timescale conversion to ms
- [ ] Sort AUs by PTS
- [ ] Feed into existing `queue` and `clock`

Done when:
- queue builds with consistent PTS
- first AU contains SPS/PPS + IDR (or at least SPS/PPS delivered before first IDR)

---

### M3 — Render Correct Grayscale (Decoder Sanity)
**Goal:** Confirm decoder correctness without chroma complexity.

Features:
- [ ] Decode IDR-only frames (skip others)
- [ ] Optional: force chroma neutral for debugging
  - U/V = 128 so you see stable grayscale
- [ ] Verify luma stats:
  - avgY should not be locked near 128
  - min/max should show contrast

Done when:
- a recognizable picture appears (even grayscale)
- no repeated `coeff_token no match ... bits=0000...` spam

---

### M4 — Fix Decoder Alignment (If Any Corruption)
**Goal:** Eliminate bitstream desync.

Features:
- [ ] Ensure slice header fully consumed:
  - pic_order_cnt_lsb for POC type 0
  - deblocking filter params when present
  - slice_qp_delta (SE)
  - dec_ref_pic_marking for IDR
- [ ] Ensure macroblock syntax consumption:
  - transform_size_8x8_flag if PPS transform8x8 is enabled
  - intra_chroma_pred_mode (UE) for intra MBs
  - consume Intra8x8 pred bits even if unsupported
- [ ] Implement `more_rbsp_data()` and stop parsing at rbsp trailing bits

Done when:
- mb types stay sane
- decoding does not drift into long zeros
- image no longer mosaics

---

### M5 — Chroma Correctness (B1.4.4)
**Goal:** Make color correct.

Features:
- [ ] chroma intra prediction (DC / H / V; plane optional)
- [ ] chroma nC neighbor tracking
- [ ] chroma DC 2x2 inverse transform + scaling
- [ ] proper chroma residual add + clamp

Done when:
- colors are stable and natural

---

### M6 — MP4 Playback Polish
**Goal:** Smooth playback loop.

Features:
- [ ] buffering queue limit
- [ ] optional decoding isolate to avoid UI jank
- [ ] better scheduling from PTS

Done when:
- stable FPS and smooth playback

---

### M7 — Return to HLS/TS
**Goal:** Use the validated decoder with TS pipeline.

Features:
- [ ] feed TS-built AUs into the same decode/render loop
- [ ] compare MP4 output vs HLS output to identify TS issues
- [ ] fix AU boundaries and PTS mapping only (decoder stays same)

Done when:
- HLS matches MP4 output

---

## Debug Checklist

When picture is wrong:
- [ ] Confirm PPS `entropyCodingModeFlag == false` (CABAC would break CAVLC decoder)
- [ ] Log avgY/min/max:
  - avg near 128 + min/max tight => residual missing
  - random mosaic => bitstream desync (missing slice/MB fields)
- [ ] If coeff_token shows bits=0000... => decoding into trailing bits or misaligned syntax

---

## Current Status
- [ ] M0
- [ ] M1
- [ ] M2
- [ ] M3
- [ ] M4
- [ ] M5
- [ ] M6
- [ ] M7

---

## Next Task (Recommended)
Start **M1**: implement minimal MP4 demux for `avc1 + avcC`, then build AU queue from samples.