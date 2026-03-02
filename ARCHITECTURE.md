# HLS Custom Decoder Architecture
## Pure Dart Implementation (Milestone A)

---

# 1. System Overview

This system implements a pure Dart HLS decoding pipeline inside Flutter.

It replaces platform video decoders with a software-based pipeline.

---

# 2. High-Level Architecture

+----------------------+
| Flutter UI Layer     |
+----------+-----------+
           |
           v
+----------------------+
| Playback Controller  |
+----------+-----------+
           |
           v
+----------------------+
| HLS Engine           |
| - Playlist parser    |
| - Segment scheduler  |
+----------+-----------+
           |
           v
+----------------------+
| TS Demuxer           |
| - PAT parser         |
| - PMT parser         |
| - PID detection      |
+----------+-----------+
           |
           v
+----------------------+
| PES Extractor        |
| - Strip headers      |
| - Extract ES         |
+----------+-----------+
           |
           v
+----------------------+
| H.264 Decoder        |
| - BitReader          |
| - SPS Parser         |
| - IDR Slice Decoder  |
| - Inverse Transform  |
| - Intra Prediction   |
+----------+-----------+
           |
           v
+----------------------+
| Frame Buffer (YUV)   |
+----------+-----------+
           |
           v
+----------------------+
| YUV → RGBA Converter |
+----------+-----------+
           |
           v
+----------------------+
| Flutter Renderer     |
+----------------------+

---

# 3. Module Responsibilities

## 3.1 HLS Engine
- Detect master/media playlist
- Parse EXT-X tags
- Handle relative URLs
- Provide segment queue

## 3.2 TS Demuxer
- 188-byte packet parsing
- Sync byte validation
- Adaptation field skip
- PAT & PMT parsing
- Extract video PID

## 3.3 PES Extractor
- Detect 0x000001 start code
- Strip PES headers
- Ignore PTS for Milestone A

## 3.4 H.264 Decoder (Milestone A)
- Parse SPS
- Decode IDR slice
- Support CAVLC only
- Produce YUV420 frame

## 3.5 Renderer
- Convert YUV420 → RGBA
- Render via RawImage

---

# 4. Data Structures

## HlsVariant
- bandwidth
- resolution
- codecs
- uri

## TsPacket
- pid
- payloadUnitStart
- payload

## NalUnit
- type
- payload

## FrameBuffer
- width
- height
- yPlane
- uPlane
- vPlane

---

# 5. Threading Model

Milestone A:
- Single isolate
- Sequential decoding

Future:
- Decoder isolate
- Rendering isolate

---

# 6. Memory Flow

Segment bytes
→ TS packets
→ PES buffer
→ ES buffer
→ NAL buffer
→ YUV buffer
→ RGBA buffer
→ Flutter image

---

# 7. Future Architecture Extensions

- Multi-segment buffer
- Frame queue
- Audio pipeline
- Hardware acceleration layer (optional later)

---