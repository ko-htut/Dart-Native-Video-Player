# Current Work Changelog

Date: 2026-03-03

## Scope
Checkpoint commit for the current pure-Dart H.264 Baseline (CAVLC) playback/decoder work in `ndvy_player`.

## Added
- New pure-Dart playback UI path and frame view:
  - `lib/player_page.dart`
  - `lib/pure_frame_view.dart`
- Decoder support modules:
  - `lib/src/decoder/vlc.dart`
  - `lib/src/decoder/scan.dart`
  - `lib/src/decoder/inv_transform.dart`
  - `lib/src/decoder/intra_pred.dart`
  - `lib/src/decoder/intra4x4_mpm.dart`
  - `lib/src/decoder/intra16_dc.dart`
  - `lib/src/decoder/chroma_pred.dart`
  - `lib/src/decoder/nc_context.dart`
- CAVLC table files:
  - `lib/src/decoder/cavlc_coeff_token_tables.dart`
  - `lib/src/decoder/cavlc_totalzeros_tables.dart`
  - `lib/src/decoder/cavlc_runbefore_tables.dart`

## Changed
- Core decoder path updates:
  - `lib/src/decoder/h264_baseline_idr_decoder.dart`
  - `lib/src/decoder/cavlc.dart`
  - `lib/src/decoder/bitreader.dart`
  - `lib/src/decoder/exp_golomb.dart`
  - `lib/src/decoder/rbsp.dart`
  - `lib/src/decoder/sps.dart`
  - `lib/src/decoder/pps.dart`
- TS/PES ingest and AU building updates:
  - `lib/src/ts_packets.dart`
  - `lib/src/pes_pts.dart`
  - `lib/src/h264_nal.dart`
  - `lib/player_page.dart`
- App wiring and docs updates:
  - `lib/main.dart`
  - `README.md`
  - `DEBUGGING.md`
  - `ROADMAP.md`
  - `MP4_PLAYBACK_PLAN.md`

## Decoder/Parsing Improvements Included
- Added SPS/PPS cache injection for AUs.
- Added strict UE/SE EOF handling and improved RBSP-more-data checks.
- Added extended decoder logging (`[SLICE]`, `[IDR]`, `[CAVLC]` contexts).
- Added fail-soft residual handling to keep playback alive.
- Implemented broader CAVLC coeff_token and total_zeros table coverage.
- Replaced run_before table with FFmpeg/spec-style table generation.
- Updated level decoding logic toward spec/FFmpeg behavior.
- Improved TS/PES assembly robustness:
  - ignore transport-error packets
  - avoid false PES starts on empty/non-PES payload
  - keep PMT/video PID cache across segments

## Known Issue (Not Fully Resolved Yet)
- Playback still shows visible macroblock corruption on some streams.
- Logs still show intermittent CAVLC desync patterns such as:
  - `coeff_token no match`
  - `coeff_token unexpected EOF`
  - `VLC dead end`
- This commit is a checkpoint of current work, not a final decode-quality fix.

## Validation Snapshot
- `flutter analyze` passes for updated ingest/changelog-related files.
- Remaining analyzer infos are style-only in decoder file (`curly_braces_in_flow_control_structures`).
