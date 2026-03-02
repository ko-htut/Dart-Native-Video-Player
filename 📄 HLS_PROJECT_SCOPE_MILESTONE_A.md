# HLS Custom Decoder (Pure Dart)
## Milestone A — IDR-Only H.264 Frame Rendering

---

# 1. Project Overview

This project aims to build a **pure Dart HLS pipeline** inside Flutter that:

- Parses `.m3u8` playlists
- Downloads `.ts` segments
- Demuxes MPEG-TS
- Extracts H.264 video stream
- Decodes **IDR frames only**
- Renders a frame in Flutter as an image

⚠️ Audio decoding is NOT included in Milestone A.

⚠️ Only H.264 Baseline/Main profile streams without complex B-frames are supported initially.

---

# 2. Goal of Milestone A

Deliver a working Flutter app that:

1. Loads an HLS `.m3u8`
2. Selects a variant
3. Downloads the first `.ts` segment
4. Extracts:
   - SPS
   - PPS
   - IDR frame
5. Decodes ONE full IDR frame in pure Dart
6. Converts YUV → RGBA
7. Displays the frame using `RawImage`

---

# 3. What Milestone A WILL Support

✅ HLS Master & Media playlist parsing  
✅ MPEG-TS PAT & PMT parsing  
✅ Video PID extraction  
✅ PES reassembly  
✅ H.264 NAL extraction  
✅ SPS parsing (width/height detection)  
✅ IDR slice decoding (Baseline, CAVLC)  
✅ YUV420 frame buffer output  
✅ RGB conversion  
✅ Flutter rendering  

---

# 4. What Milestone A Will NOT Support

❌ Audio (AAC) decoding  
❌ B-frames  
❌ CABAC decoding (High profile complex streams may fail)  
❌ DRM / AES-128 encryption  
❌ fMP4 segments  
❌ Full playback timeline  

---

# 5. Architecture Overview

## Data Flow

.m3u8
   ↓
Playlist Parser
   ↓
.ts Segment Download
   ↓
TS Packet Parser (188-byte packets)
   ↓
PAT → PMT
   ↓
Video PID Detection
   ↓
PES Reassembly
   ↓
H.264 Byte Stream
   ↓
NAL Unit Extraction
   ↓
SPS Parsing
   ↓
IDR Slice Decode
   ↓
YUV420 Frame Buffer
   ↓
YUV → RGBA
   ↓
Flutter RawImage Render

---

# 6. Technical Modules

## 6.1 HLS Layer
- detect master/media playlist
- parse variants
- resolve relative URLs
- parse segment durations
- segment queue

## 6.2 MPEG-TS Layer
- sync byte detection (0x47)
- PID extraction
- adaptation field handling
- PAT parsing
- PMT parsing
- stream_type filtering (0x1B for H.264)

## 6.3 PES Layer
- detect start code 0x000001
- strip PES headers
- ignore PTS/DTS initially

## 6.4 H.264 Layer

### Required NAL Types
- 7 → SPS
- 8 → PPS
- 5 → IDR slice

### Required Parsing
- Exp-Golomb decoding
- Slice header parsing
- CAVLC residual decoding
- Inverse transform
- Intra prediction

---

# 7. IDR-Only Strategy

Milestone A will:

- Ignore non-IDR frames
- Decode only keyframes
- Display still frame output
- No frame timing
- No continuous playback

This reduces complexity drastically.

---

# 8. H.264 Decoder Requirements

## 8.1 Bit Reader
- bit-level reading
- unsigned Exp-Golomb (UE)
- signed Exp-Golomb (SE)

## 8.2 SPS Parsing
- profile_idc
- level_idc
- width
- height
- cropping

## 8.3 Slice Decoding (Baseline)
- Intra16x16 mode
- Intra4x4 mode
- CAVLC residual decoding
- No CABAC support in Milestone A

---

# 9. Frame Buffer Format

Internal format:
- YUV420 planar

Memory layout:
- Y plane
- U plane
- V plane

Conversion:
- YUV420 → RGBA8888

Render via:
ui.decodeImageFromPixels()

---

# 10. Performance Expectations

Target:
- Decode single 720p IDR in < 300ms
- Memory under 50MB
- No GPU acceleration

Limitations:
- Dart software decoding will be slow
- Not suitable for full 30fps playback yet

---

# 11. Testing Requirements

Use a test stream with:
- H.264 Baseline profile
- No encryption
- .ts segments
- No fMP4

Recommended test stream:
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8

---

# 12. Milestone A Deliverables

- Flutter project
- Playlist parser
- TS demuxer
- H.264 NAL parser
- IDR decoder
- Frame renderer
- Logging + debug panel

---

# 13. Risks

- Stream may use CABAC (complex)
- Stream may use High profile
- Stream may use B-frames
- Dart decode performance may be insufficient
- Memory usage may spike

---

# 14. Success Criteria

Milestone A is successful when:

- App loads HLS stream
- Extracts SPS
- Decodes IDR
- Displays visible frame in Flutter
- No native plugins used

---

# 15. Estimated Complexity

| Component            | Difficulty |
|----------------------|------------|
| HLS parsing          | Low        |
| TS demux             | Medium     |
| PES handling         | Medium     |
| H.264 parsing        | High       |
| CAVLC decode         | Very High  |
| Frame reconstruction | Very High  |
| RGB conversion       | Medium     |

---

# 16. Next Milestone (B)

After Milestone A:

- Decode P-frames
- Implement basic frame timing
- Continuous playback (low fps)
- Optional AAC decode
- Live stream refresh handling

---

# 17. Summary

Milestone A is a proof-of-concept for:

Pure Dart HLS → H.264 software decoding → Flutter rendering.

It focuses on:
- Architecture correctness
- Decoder pipeline foundation
- IDR-only rendering

This milestone builds the foundation for a full custom player.
