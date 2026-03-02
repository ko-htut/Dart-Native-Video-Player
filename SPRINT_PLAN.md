# Sprint Plan — Milestone A

Duration: 3–5 Weeks (Realistic for custom decoder)

---

# Week 1 — HLS + TS Foundation

Goal:
✔ Load playlist
✔ Download segment
✔ Extract video PID
✔ Extract H.264 ES stream

Deliverable:
Log NAL statistics

---

# Week 2 — SPS + IDR Extraction

Goal:
✔ Parse SPS
✔ Get resolution
✔ Extract IDR NAL
✔ Prepare slice data

Deliverable:
Successfully detect IDR + parse header

---

# Week 3 — IDR Slice Decode

Goal:
✔ Implement BitReader
✔ Implement CAVLC
✔ Implement Intra prediction
✔ Generate YUV buffer

Deliverable:
Decoded YUV frame

---

# Week 4 — Rendering Layer

Goal:
✔ Convert YUV → RGBA
✔ Render via RawImage
✔ Optimize memory allocations

Deliverable:
Visible decoded frame

---

# Optional Week 5 — Optimization

✔ Move decode to isolate
✔ Profile memory
✔ Optimize loops
✔ Improve decode speed

---

# Success Metric

Decode 720p IDR frame under 300ms.