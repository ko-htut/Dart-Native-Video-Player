# AAC PCM golden

`baby_aac_s16_stride251.base64` contains every 251st interleaved signed
16-bit sample from an independent FFmpeg decode of `assets/baby_aac.mp4`.
The reference contains 282,624 stereo frames after dropping the AAC encoder's
first 1,024 priming frames; the final AAC access unit remains a full 1,024
frames. The complete little-endian reference had SHA-256
`f301d89e63f60b6a3cd35693662f7db3b16a61a295053c14ebf5ed1d08eb0e7e`.

The decoder test compares all 2,252 sparse samples with a small numeric
tolerance so harmless `libm` differences between x64 and ARM builds do not
make the golden architecture-specific.

`mux_x36xhzz_hq_segment_000_s16_stride251.base64` contains every 251st
interleaved signed 16-bit sample from an independent FFmpeg 7.1.1 decode of
the 431 AAC-LC access units in
`test/fixtures/hls/mux_x36xhzz/hq_848x480_segment_000.ts`. FFmpeg removes the
first 1,024 encoder-priming frames, leaving 430 complete frames (440,320
stereo PCM frames). The complete little-endian reference had SHA-256
`f0d9d484d393b09601e330fcb795bae84cf56c8afa122aaf8909820dd91318db`.

The corresponding low rendition carries HE-AAC, so the cross-variant test
also verifies that this AAC-LC sibling begins 909 MPEG-clock ticks (10.100 ms)
after the low rendition's first video PTS and is placed on that shared media
timeline before PCM comparison.
