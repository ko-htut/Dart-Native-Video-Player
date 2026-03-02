# H.264 Decoder Design (Milestone A)

---

# 1. Scope

This decoder only supports:
- Baseline profile
- IDR slices
- CAVLC entropy coding
- YUV420 format

No:
- CABAC
- B-frames
- Inter prediction

---

# 2. Decoder Pipeline

NAL Unit
→ Remove emulation prevention bytes
→ BitReader
→ Parse SPS
→ Parse slice header
→ Decode macroblocks
→ Reconstruct pixels
→ Output YUV420 frame

---

# 3. Required Algorithms

## 3.1 Exp-Golomb Coding
- UE (unsigned)
- SE (signed)

## 3.2 CAVLC Decoding
- coeff_token
- total_zeros
- run_before

## 3.3 Intra Prediction

Support:
- Intra16x16
- Intra4x4

---

# 4. Macroblock Processing

For each macroblock:

1. Decode mb_type
2. Predict intra mode
3. Decode residual
4. Inverse transform
5. Add prediction
6. Store in Y plane

Chroma:
- Subsampled
- Similar but reduced resolution

---

# 5. Memory Layout

Y plane: width × height
U plane: width/2 × height/2
V plane: width/2 × height/2

---

# 6. Performance Concerns

- Heavy bit operations
- Many small loops
- High GC pressure
- Dart is not SIMD optimized

---

# 7. Optimization Strategy

- Preallocate buffers
- Reuse objects
- Avoid List<dynamic>
- Use Uint8List everywhere
- Minimize bounds checks

---

# 8. Future Extensions

- P-frame decoding
- B-frame decoding
- CABAC implementation
- AAC audio decode
- Frame timing engine

---

# 9. Estimated Code Size

| Component    | Lines          |
|--------------|----------------|
| BitReader    | 200            |
| SPS Parser   | 400            |
| Slice Header | 500            |
| CAVLC        | 1500           |
| Transform    | 800            |
| Prediction   | 1200           |
| Total        | ~5000–7000 LOC |

---

# 10. Conclusion

Milestone A is a foundation-level H.264 software decoder in Dart.

It is complex but achievable for IDR-only baseline streams.

Full video playback requires significantly more work.