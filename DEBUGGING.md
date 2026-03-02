# DEBUGGING — What logs mean

## 1) CABAC vs CAVLC
If PPS entropyCodingModeFlag is true => CABAC.
A pure CAVLC decoder cannot decode CABAC.

Log:
- entropyCodingModeFlag=true  => choose Baseline variant (CODECS avc1.42xxxx) or use CABAC support.

---

## 2) Flat gray picture (no detail)
Typical log:
- avgY ~ 128
- min/max close to 128

Meaning:
- residuals are missing or always zero:
  - coded_block_pattern always 0
  - coeff_token always returns totalCoeff=0
  - level decoding broken

Action:
- validate CBP
- validate coeff_token tables
- validate suffixLength level decoding

---

## 3) Mosaic / block corruption
Meaning:
- bitstream desync (wrong syntax parsing order)
Common causes:
- missing slice header fields (pic_order_cnt_lsb, slice_qp_delta, deblock params)
- missing macroblock fields (transform_size_8x8_flag, intra_chroma_pred_mode)
- consuming Intra8x8 wrong/skip bits

Action:
- enable fail-fast on residual decode
- log slice header flags and field consumption
- implement more_rbsp_data stop condition

---

## 4) coeff_token no match + bits=0000...
Example:
- coeff_token no match nC=2 bits16=0000000000000

Meaning:
- you are not at coeff_token boundary OR decoding into rbsp trailing bits.

Action:
- implement more_rbsp_data and stop MB decode when false
- verify all required syntax elements are consumed before residual
- log MB index where it happens and inspect missing fields

---

## 5) YUV->RGBA shows black/green/purple
Meaning:
- conversion bug (U/V indexing, range offset, wrong stride)

Action:
- force U/V = 128, check grayscale stability
- test pattern RGBA render to validate UI

---

## Recommended debug logs
- frame size + rgba length
- avgY / min / max
- entropyCodingModeFlag
- slice: first_mb_in_slice, slice_type, pic_order_cnt_lsb
- MB: mbAddr, mbType, transform8x8Flag, intraChromaPredMode, cbp, qpDelta