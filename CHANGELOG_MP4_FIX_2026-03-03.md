# MP4 Fix Changelog (2026-03-03)

## Issue
- MP4 playback failed with:
  - `MP4 ERROR: Bad state: MP4: no trak`

## Root Cause
- MP4 box parsing scanned from container box start (including the container header), not from container payload (`dataStart`), so child boxes like `trak` could be skipped.
- Nested boxes were looked up only one level deep in several places (`stsd`, `avcC`, `mdhd`, `stsz`, `stco/co64`, `stsc`, `stts`), which is invalid for MP4 hierarchy.

## Fixes Applied
- Updated MP4 demux parsing to:
  - scan `trak` boxes from `moov.dataStart`
  - use deep box lookup for nested required boxes
  - keep avc1 detection robust inside `stsd`
- Added recursive `_findBoxDeep(...)` helper.
- Cleaned unused parser code introduced during patching.

## Files Changed
- `lib/src/mp4/mp4_demux.dart` (new)
- `lib/player_page.dart` (import + MP4 queue mode integration currently in working tree)

## Notes
- This fix addresses MP4 container parsing (`no trak`) only.
- H.264 CAVLC visual corruption in TS/HLS path remains a separate decoder issue.
