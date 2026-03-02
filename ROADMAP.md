# ROADMAP — Pure Dart Playback (MP4 First)

## North Star
Render a correct picture from H.264 Baseline (CAVLC) using pure Dart.

## Strategy
1) Validate decoder using MP4 (clean access unit boundaries)
2) Only then return to HLS/TS (transport problems isolated)

---

## Milestone M0 — MP4 Mode Switch
### Deliverables
- MP4 button + queue builder hook
- Debug overlay: size, avgY/min/max, entropyCodingModeFlag, AU count
### Exit criteria
- MP4 queue builder is callable
- Playback loop runs (even if frames not decoded yet)

---

## Milestone M1 — Minimal MP4 Demux (AVC1)
### Deliverables
- MP4 box reader (size, type, children)
- Track selection (video only)
- Sample table parsing: stsz, stco/co64, stsc, stts (ctts optional)
- avcC parsing: SPS/PPS + nalLengthSize
### Exit criteria
- Can print: sampleCount, timescale, SPS/PPS count, nalLengthSize

---

## Milestone M2 — Access Unit Queue from MP4
### Deliverables
- Read sample bytes from mdat
- Split sample into NALs using nalLengthSize
- AU: include SPS/PPS (at start + before first IDR)
- PTS conversion to ms using timescale
### Exit criteria
- AUs built and sorted
- First AU with SPS/PPS and at least one IDR

---

## Milestone M3 — Grayscale Picture (Decoder Sanity)
### Deliverables
- Decode IDR-only AUs and render
- Optional: force U/V = 128
- avgY/min/max logs
### Exit criteria
- Recognizable picture appears in grayscale
- No repeated coeff_token “all zeros” spam

---

## Milestone M4 — Decoder Alignment Hardening
### Deliverables
- Slice header consumption complete for common streams:
  - pic_order_cnt_lsb for POC type 0
  - slice_qp_delta
  - deblock params if present
  - IDR marking fields
- Macroblock syntax consumption fixed:
  - transform_size_8x8_flag when enabled
  - intra_chroma_pred_mode
  - consume Intra8x8 pred fields (even if unsupported)
- more_rbsp_data stop condition
### Exit criteria
- No desync mosaics
- mb types stay sane
- residual decode stable

---

## Milestone M5 — Color Correctness (Chroma)
### Deliverables
- Chroma intra prediction (DC/H/V; Plane optional)
- Chroma nC tracking
- Chroma DC 2x2 transform scaling
### Exit criteria
- Colors are stable and natural

---

## Milestone M6 — Playback Polish
### Deliverables
- Buffering
- Optional decode isolate
- Dropping/skip logic for late frames
### Exit criteria
- Smooth playback for MP4

---

## Milestone M7 — Return to HLS/TS
### Deliverables
- Feed TS-built AUs into the validated decoder
- Fix only transport (AU boundaries + PTS)
### Exit criteria
- HLS output matches MP4 output quality