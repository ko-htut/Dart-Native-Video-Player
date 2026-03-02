# Task Breakdown — Milestone A

---

# Phase 1 — HLS Layer

- [ ] Detect master vs media playlist
- [ ] Parse EXT-X-STREAM-INF
- [ ] Parse EXTINF
- [ ] Handle relative paths
- [ ] Select variant
- [ ] Build segment queue

---

# Phase 2 — TS Demux

- [ ] Parse 188-byte TS packets
- [ ] Extract PID
- [ ] Handle adaptation fields
- [ ] Parse PAT
- [ ] Parse PMT
- [ ] Detect video PID (stream_type 0x1B)

---

# Phase 3 — PES Layer

- [ ] Detect PES start code
- [ ] Strip header
- [ ] Extract elementary stream

---

# Phase 4 — H.264 Parsing

- [ ] Split Annex-B NAL units
- [ ] Detect SPS
- [ ] Parse SPS width/height
- [ ] Detect IDR
- [ ] Extract IDR payload

---

# Phase 5 — IDR Decoder (Core)

- [ ] Build BitReader
- [ ] Implement Exp-Golomb UE/SE
- [ ] Parse slice header
- [ ] Implement Intra16x16
- [ ] Implement CAVLC residual decoding
- [ ] Implement inverse transform
- [ ] Build YUV420 frame buffer

---

# Phase 6 — Rendering

- [ ] Convert YUV → RGB
- [ ] Create Uint8List RGBA
- [ ] Render with RawImage
- [ ] Display width/height debug

---

# Phase 7 — Validation

- [ ] Test with baseline profile stream
- [ ] Validate resolution
- [ ] Validate color correctness
- [ ] Measure decode time

---

# Deliverable

Decode and display one IDR frame from HLS stream.