# Current Work Changelog

Date: 2026-03-03

## Update: 2026-03-04 (CAVLC Prefix>=15 Formula Correction)

### Changed
- Updated `lib/src/decoder/cavlc.dart`:
  - Reworked `readLevelsCavlc()` again to strict spec/JM form:
    - `suffixSize` selection:
      - `prefix == 14 && suffixLength == 0` -> `4`
      - `prefix >= 15` -> `prefix - 3`
      - else -> `suffixLength`
    - `levelCode` construction:
      - base `(min(prefix, 15) << suffixLength)`
      - `+suffix` when `(suffixLength > 0 || prefix >= 14)`
      - `+15` when `(prefix == 15 && suffixLength == 0)`
      - `+(1 << (prefix - 3)) - 4096` when `prefix >= 16`
  - Kept first non-trailing level `+2` adjustment.

### Why this matters
- The prior escape branch could still consume the wrong number of suffix bits for `prefix >= 15`, which desynced residual parsing and cascaded into:
  - `coeffNum out of range`
  - `total_zeros/run_before VLC dead end`
  - `coeff_token no match`

### Validation
- `fvm flutter analyze lib/src/decoder/cavlc.dart` passed.

## Update: 2026-03-04 (CAVLC Canonical Run Placement)

### Changed
- Updated `lib/src/decoder/cavlc.dart`:
  - Replaced incremental/decrement placement with strict spec/JM canonical flow:
    - decode `run_before[i]` for `i=0..totalCoeff-2`
    - assign `run_before[totalCoeff-1] = zerosLeft`
    - place coeffs using reverse loop:
      - `coeffNum = -1`
      - `for i=totalCoeff-1..0: coeffNum += run[i] + 1`
  - Applied same canonical flow to chroma DC 2x2 residual placement.
  - Switched `total_zeros` handling from clamp to strict range validation.
  - Added strict `run_before <= zerosLeft` validation.

### Why this matters
- Previous negative `coeffNum` errors showed run/placement drift symptoms.
- Canonical run placement removes indexing ambiguity and enforces spec-consistent bounds.

### Validation
- `fvm flutter analyze lib/src/decoder/cavlc.dart` passed.

## Update: 2026-03-04 (AC total_zeros Table Selection)

### Changed
- Updated `lib/src/decoder/cavlc_totalzeros_tables.dart`:
  - Added `totalZeros4x4Ac` table set for AC-only residual blocks (`startIdx=1`, 15 coeff positions).
  - AC table keeps only valid `totalZeros` range `0..(15-totalCoeff)` from the full 4x4 table.
- Updated `lib/src/decoder/cavlc.dart`:
  - `_readTotalZeros4x4()` now selects:
    - full table for `maxCoeff=16`
    - AC table for `maxCoeff=15`
  - Added separate VLC tree cache for AC total_zeros.

### Why this matters
- First failure line showed:
  - `startIdx=1 maxCoeff=15 totalCoeff=8 totalZeros=8` (invalid; max is 7)
- This indicates AC blocks were still decoded with the full-16 total_zeros domain.
- Using AC-specific table should remove these immediate out-of-range cases and reduce downstream desync.

### Validation
- `fvm flutter analyze lib/src/decoder/cavlc.dart lib/src/decoder/cavlc_totalzeros_tables.dart` passed.

## Update: 2026-03-04 (LevelCode +15 Condition Fix)

### Changed
- Updated `lib/src/decoder/cavlc.dart`:
  - In `readLevelsCavlc()`, corrected:
    - from `if (prefix == 15 && suffixLength == 0) levelCode += 15`
    - to `if (prefix >= 15 && suffixLength == 0) levelCode += 15`

### Why this matters
- For `prefix >= 16` with `suffixLength == 0`, missing `+15` underestimates decoded level magnitude.
- That can corrupt `suffixLength` evolution for subsequent levels and cause later CAVLC bitstream desync.

### Validation
- `fvm flutter analyze lib/src/decoder/cavlc.dart` passed.

## Update: 2026-03-04 (CAVLC Remaining-Level Escape Fix)

### Changed
- Updated `lib/src/decoder/cavlc.dart`:
  - Replaced `readLevelsCavlc()` remaining-level (`i > trailingOnes`) escape path with FFmpeg/spec logic.
  - Fixed `level_prefix >= 15` handling for remaining levels:
    - use `prefixAdj = level_prefix - 15`
    - use `suffixSize = prefixAdj + suffixLength`
    - read `suffixSize` bits (instead of incorrect `level_prefix - 3` path)
  - Kept first-level escape path separate from remaining-level path (as required by spec).
  - Updated level sign mapping to FFmpeg/JM mapping:
    - even `levelCode` => positive
    - odd `levelCode` => negative

### Why this matters
- The previous remaining-level escape formula could over-read bits and desynchronize residual parsing.
- That desync directly cascades to:
  - `total_zeros decode failed`
  - `run_before decode failed`
  - `coeff_token no match`

### Validation
- `fvm flutter analyze lib/src/decoder/cavlc.dart lib/src/decoder/h264_baseline_idr_decoder.dart`
  - no errors; only existing style infos in `h264_baseline_idr_decoder.dart`.

## Update: 2026-03-04 (CAVLC Level Escape Fix)

### Changed
- Updated `lib/src/decoder/cavlc.dart`:
  - Replaced `readLevelsCavlc()` level escape handling with FFmpeg/spec-consistent logic.
  - Fixed `level_prefix >= 15` handling:
    - `suffixLength == 0`: `levelCode = 30 + level_suffix(12 bits)`
    - `suffixLength > 0`: `levelCode = (15 << suffixLength) + level_suffix + (1 << (suffixLength - 1)) - 4096`
  - Kept first-non-trailing level offset (`+2` when `trailingOnes < 3`) and corrected suffix-length growth thresholds via explicit limits.

### Why this matters
- The previous escape-path math could desync residual parsing on large levels, which then cascaded into:
  - `coeff_token no match`
  - `VLC dead end`
  - unstable macroblock decode output

### Validation
- `fvm flutter analyze lib/src/decoder/cavlc.dart` passed with no issues.

## Update: 2026-03-04 (Residual Parse Order Fix)

### Changed
- Updated `lib/src/decoder/h264_baseline_idr_decoder.dart`:
  - Added explicit luma residual parse order by 8x8 group:
    - `[0,1,4,5]`, `[2,3,6,7]`, `[8,9,12,13]`, `[10,11,14,15]`
  - Intra16 AC parsing now follows residual syntax order instead of raster order.
  - Intra4 residual parsing now follows residual syntax order, while reconstruction remains raster-order (to keep intra predictors valid with top-right neighbors).
  - Chroma AC parsing order changed to component-major (all U blocks first, then all V blocks), matching residual syntax.

### Why this matters
- Previous raster/interleaved residual parsing could desync bitstream consumption and cascade into:
  - `VLC dead end`
  - `coeff_token no match`
  - invalid/unsupported `mb_type` values later in the same slice

### Validation
- `fvm flutter analyze lib/src/decoder/h264_baseline_idr_decoder.dart lib/src/decoder/cavlc.dart`:
  - no warnings/errors for these changes
  - remaining findings are existing style infos only (`curly_braces_in_flow_control_structures`)

## Update: 2026-03-04 (CAVLC Level/Placement Correction)

### Changed
- Updated `lib/src/decoder/cavlc.dart`:
  - Reworked `readLevelsCavlc()` to follow spec/JM flow for `level_prefix`/`level_suffix` handling:
    - `levelSuffixSize` derivation for `prefix == 14` and `prefix >= 15`
    - `levelCode` construction restored to JM-style formulas
  - Fixed level sign mapping:
    - even `levelCode` => negative level
    - odd `levelCode` => positive level
  - Fixed coefficient placement order:
    - now places levels/runs in forward decoded order (`i=0..totalCoeff-1`) for both 4x4 and chroma DC.

### Why this matters
- Previous level/placement logic could consume wrong suffix bits for escape cases and distort residual reconstruction, increasing downstream CAVLC desync.

### Validation
- `fvm flutter analyze lib/src/decoder/cavlc.dart` passed.

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

## Update (CAVLC Sync Attempt: level_prefix/level_suffix)

### Changed
- Updated `lib/src/decoder/cavlc.dart`:
  - Rewrote `readLevelsCavlc()` with JM/FFmpeg-aligned flow for:
    - `level_prefix == 14 && suffixLength == 0`
    - `level_prefix >= 15` escape handling
    - first non-trailing level `+2` adjustment
  - Fixed `levelCode` construction for `level_prefix >= 16` by using `levelPrefix << suffixLength` before escape offsets.
  - Switched to canonical signed mapping (`odd => positive`, `even => negative`).

### Why
- The first deterministic failure you reported (`ChromaAC ... total_zeros decode failed`) indicates likely bitstream desync before `total_zeros`; this patch targets the most likely desync source: level decode escape/suffix handling.

### Validation
- Ran:
  - `fvm flutter analyze lib/src/decoder/cavlc.dart lib/src/decoder/h264_baseline_idr_decoder.dart lib/src/decoder/vlc.dart`
- Result:
  - no analyzer errors in changed decode logic
  - only existing style infos in `h264_baseline_idr_decoder.dart`.
