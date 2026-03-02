Features

 Read each sample from mdat using computed offsets and sizes

 Split sample into NAL units using AVCC length prefixes

 Convert AVCC NALs into Annex-B style units or keep raw NAL payloads consistent with your decoder

You already accept NAL with first byte = header (nal_unit_type in low 5 bits)

 Build TimestampedAccessUnit list:

AU nals must include:

 SPS (once at start and/or before each IDR)

 PPS (once at start and/or before each IDR)

 sample NALs

 Compute ptsMs from stts:

accumulate durations (timescale → ms)

 Detect IDR:

nal_unit_type == 5 in sample → mark hasIdr=true

Done criteria

Queue builds with:

correct sorted PTS

non-empty NAL lists per AU

Decoder receives SPS/PPS + IDR in first frames

Milestone M3 — Render Correct Grayscale Picture (Decoder sanity)
Features

 Decode IDR frames only:

if AU has IDR → decode and render

else skip (for now)

 Force neutral chroma for debugging:

set U/V to 128 (optional)

 Add “Freeze frame” toggle:

show last decoded frame without clock running

Done criteria

You see recognizable picture (even if grayscale/blocky)

No coeff_token no match spam

Milestone M4 — Improve Decoder Alignment (If needed)
Features

 Fix slice header parsing fully (POC, deblock, qp, etc.)

 Ensure transform_size_8x8_flag and intra_chroma_pred_mode are consumed correctly

 Implement more_rbsp_data() stopping conditions

Done criteria

No bitstream desync

Macroblock types stay sane

CAVLC decoding stable

Milestone M5 — Color Correctness (Chroma path)
Features

 Implement proper chroma residual decode + DC scaling

 Implement chroma intra prediction (DC/H/V)

 Track chroma nC

Done criteria

Colors look normal (no weird tint blocks)

Milestone M6 — “Real Playback” for MP4
Features

 Support non-IDR I-slices (still intra-only)

 Add basic buffering:

decode thread/isolate (optional)

frame queue with max size

 Smooth clock sync to PTS

Done criteria

MP4 plays smoothly (intra-only)

Milestone M7 — Return to HLS/TS with Confidence
Features

 Use the same working decoder

 Compare MP4 vs HLS output

 Fix TS AU boundary logic only (if decoder is confirmed correct)

Done criteria

HLS output matches MP4 output quality

Notes / Rules

Keep scope tight: MP4 AVC only first

Skip audio until video is stable

Skip P-frames until intra-only is stable