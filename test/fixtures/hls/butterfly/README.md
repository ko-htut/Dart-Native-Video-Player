# Butterfly HLS fixture

This VOD fixture is a transport-stream remux of
`assets/butterfly_dart.mp4`. The H.264 Constrained Baseline and AAC-LC streams
are copied without transcoding.

Source SHA-256:

```text
4623d0b1f8540ce8a2eab2a7ed7fa29849548cd9ae06cc656d549e4f0d3ae26b
```

Generation command:

```sh
ffmpeg -hide_banner -loglevel error \
  -i assets/butterfly_dart.mp4 -map 0:v:0 -map 0:a:0 -c copy \
  -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod \
  -hls_segment_type mpegts -hls_flags independent_segments -start_number 0 \
  -hls_segment_filename test/fixtures/hls/butterfly/segment_%03d.ts \
  test/fixtures/hls/butterfly/media.m3u8
```

`master.m3u8` is maintained separately because the single-variant FFmpeg
command produces only the media playlist.
