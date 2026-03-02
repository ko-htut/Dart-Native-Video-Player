import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'src/hls.dart';
import 'src/ts_packets.dart';
import 'src/ts_psi.dart';
import 'src/ts_pes.dart';
import 'src/pes_pts.dart';
import 'src/access_unit_pts.dart';
import 'src/player_clock.dart';
import 'src/yuv.dart';
import 'src/decoder/h264_baseline_idr_decoder.dart';
import 'dart:ui' as ui;
import 'src/yuv.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: const PureDartPlaybackScreen(),
    );
  }
}

class PureDartPlaybackScreen extends StatefulWidget {
  const PureDartPlaybackScreen({super.key});
  @override
  State<PureDartPlaybackScreen> createState() => _PureDartPlaybackScreenState();
}

class _PureDartPlaybackScreenState extends State<PureDartPlaybackScreen> {
  final urlCtrl = TextEditingController(
    text:
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    // text: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    // text: 'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
    // text:'https://sfux-ext.sfux.info/hls/chapter/105/1588724110/1588724110.m3u8',
  );

  bool loading = false;
  String log = '';

  // Playback
  final clock = PlayerClock();
  List<TimestampedAccessUnit> queue = [];
  TimestampedAccessUnit? current;

  final decoder = H264IdrDecoderB11();
  ui.Image? currentImage;
  String decodeInfo = '';
  bool _decoding = false;

  void append(String s) => setState(() => log = '$log$s\n');

  @override
  void initState() {
    super.initState();

    clock.onFrameDue = (t) async {
      bool changed = false;
      while (queue.isNotEmpty && queue.first.ptsMs <= t) {
        current = queue.removeAt(0);
        changed = true;
      }
      if (!changed || current == null) {
        setState(() {});
        return;
      }

      if (_decoding) return; // prevent overlap
      _decoding = true;

      try {
        final au = current!;
        final frame = decoder.decodeIdrAccessUnit(au.nals);
        if (frame == null) {
          setState(() {
            decodeInfo = 'Decode null (maybe CABAC stream or missing SPS/PPS)';
          });
          return;
        }
        final rgba = yuv420ToRgba(frame);
        final img = await _rgbaToImage(rgba, frame.width, frame.height);
        setState(() {
          currentImage = img;
          decodeInfo =
              'B1.1: IDR I16x16+CAVLC (grayscale), ${frame.width}x${frame.height}';
        });
      } finally {
        _decoding = false;
      }
    };
  }

  @override
  void dispose() {
    urlCtrl.dispose();
    clock.dispose();
    super.dispose();
  }

  String _fmtMs(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  Future<ui.Image> rgbaToImage(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      (img) => c.complete(img),
    );
    return c.future;
  }

  Future<void> buildQueue() async {
    setState(() {
      loading = true;
      log = '';
      queue = [];
      current = null;
    });

    try {
      final url = Uri.parse(urlCtrl.text.trim());
      append('Load: $url');

      // 1) Resolve playlist
      final kind = await detectPlaylistKind(url);
      HlsMediaPlaylist media;

      if (kind == HlsPlaylistKind.master) {
        final vars = await fetchHlsVariants(url);
        append('Master playlist. Variants=${vars.length}');
        if (vars.isEmpty) throw Exception('No variants found.');

        // pick first variant
        append(
          'Pick variant: ${vars.first.resolution ?? "?"} bw=${vars.first.bandwidth ?? 0}',
        );
        media = await fetchMediaPlaylist(vars.first.uri);
      } else {
        media = await fetchMediaPlaylist(url);
      }

      append('Media segments=${media.segments.length}');
      if (media.segments.isEmpty) return;

      // 2) Download & parse first N segments to build a queue
      //    (increase later when you add buffering + continuous download)
      const int maxSegments = 10;
      final int segLimit = media.segments.length < maxSegments
          ? media.segments.length
          : maxSegments;

      final out = <TimestampedAccessUnit>[];
      int? basePts90k; // for ms normalization

      for (int s = 0; s < segLimit; s++) {
        final seg = media.segments[s];
        append(
          '\nSEG $s seq=${seg.sequence} dur=${seg.duration.toStringAsFixed(2)}',
        );
        final tsBytes = await fetchBytes(seg.uri);

        final packets = parseTsPackets(tsBytes).toList();

        // PAT/PMT → find video PID
        final pat = TsPat.find(packets);
        if (pat == null || pat.programs.isEmpty) {
          append('  PAT missing');
          continue;
        }
        final pmtPid = pat.programs.values.first;
        final pmt = TsPmt.find(packets, pmtPid);
        if (pmt == null) {
          append('  PMT missing');
          continue;
        }

        final videoStream = pmt.streams.firstWhere(
          (x) => x.streamType == 0x1B, // H.264
          orElse: () => const TsStreamInfo(pid: -1, streamType: -1),
        );
        if (videoStream.pid == -1) {
          append('  No H.264 in PMT');
          continue;
        }
        final videoPid = videoStream.pid;

        // 3) Reassemble PES for video PID
        final pesPackets = assemblePesPackets(packets, videoPid).toList();
        append('  PES packets=${pesPackets.length}');

        // 4) Parse PES: extract PTS + payload bytes, accumulate ES and map pts to AU boundaries
        final ptsChunks = <PtsChunk>[];
        for (final pes in pesPackets) {
          final parsed = parsePes(pes);
          if (parsed == null) continue;
          if (parsed.pts90k != null) {
            basePts90k ??= parsed.pts90k;
          }
          ptsChunks.add(
            PtsChunk(pts90k: parsed.pts90k, payload: parsed.esPayload),
          );
        }

        // 5) Build timestamped Access Units from chunks
        final aus = buildTimestampedIdrAusFromPtsChunks(
          ptsChunks: ptsChunks,
          basePts90k: basePts90k,
        );

        append('  IDR AUs=${aus.length}');
        out.addAll(aus);
      }

      out.sort((a, b) => a.ptsMs.compareTo(b.ptsMs));
      queue = out;

      append('\nQueue built: ${queue.length} frames (IDR-only)');
      if (queue.isNotEmpty) {
        append(
          'First PTS=${queue.first.ptsMs}ms Last PTS=${queue.last.ptsMs}ms',
        );
      }

      setState(() {});
    } catch (e) {
      append('ERROR: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<ui.Image> _rgbaToImage(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      (img) => c.complete(img),
    );
    return c.future;
  }

  void play() {
    if (queue.isEmpty) return;
    // Start clock at first frame time (or current)
    final startMs = current?.ptsMs ?? queue.first.ptsMs;
    clock.play(fromMs: startMs);
  }

  void pause() => clock.pause();

  void seekToStart() {
    if (queue.isEmpty) return;
    clock.pause();
    setState(() {
      current = null;
    });
    clock.setTime(queue.first.ptsMs);
  }

  @override
  Widget build(BuildContext context) {
    final nowMs = clock.nowMs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pure Dart Playback (B0: PTS + Scheduler)'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: '.m3u8 URL',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: loading ? null : buildQueue,
                    child: Text(
                      loading ? 'Building…' : 'Build Queue (10 segments)',
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: play,
                    child: const Text('Play'),
                  ),
                  FilledButton.tonal(
                    onPressed: pause,
                    child: const Text('Pause'),
                  ),
                  FilledButton.tonal(
                    onPressed: seekToStart,
                    child: const Text('Seek Start'),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // “Player view” (placeholder until decoder exists)
              SizedBox(
                height: 200,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Center(
                      child: Stack(
                        children: [
                          SizedBox(
                            child: AspectRatio(
                              aspectRatio: 4 / 3,
                              child: Center(
                                child: Stack(
                                  // crossAxisAlignment:
                                  //     CrossAxisAlignment.center,
                                  // mainAxisAlignment:
                                  //     MainAxisAlignment.center,
                                  children: [
                                    Column(
                                       crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          current == null
                                              ? 'No frame yet'
                                              : 'FRAME PTS ${_fmtMs(current!.ptsMs)}\nNALs: ${current!.nals.length}\nHas IDR: ${current!.hasIdr}',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 14,
                                          ),
                                        ),
                                        Text(
                                          current == null
                                              ? 'No frame yet'
                                              : 'Clock: ${_fmtMs(nowMs)}  (${nowMs}ms)\nFrame due @ ${current!.ptsMs}ms\n$decodeInfo',
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),

                                    currentImage != null
                                        ? Container(
                                            decoration: BoxDecoration(
                                              color: Colors.grey[50],
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: RawImage(
                                              image: currentImage,
                                            ),
                                          )
                                        : SizedBox(),
                                  ],

                                  // : Stack(
                                  //     // mainAxisSize: MainAxisSize.min,
                                  //     children: [
                                  //       Text(
                                  //         decodeInfo,
                                  //         style: const TextStyle(
                                  //           fontFamily: 'monospace',
                                  //         ),
                                  //       ),
                                  //       const SizedBox(height: 7),

                                  //       Container(
                                  //         decoration: BoxDecoration(
                                  //           color: Colors.grey[50],
                                  //           borderRadius:
                                  //               BorderRadius.circular(12),
                                  //         ),
                                  //         child: RawImage(
                                  //           image: currentImage,
                                  //         ),
                                  //       ),
                                  //     ],
                                ),
                              ),
                            ),
                          ),
                          // Column(
                          //   mainAxisSize: MainAxisSize.min,
                          //   children: [
                          //     Text(
                          //       'Clock: ${_fmtMs(nowMs)}  (${nowMs}ms)',
                          //       style: const TextStyle(fontFamily: 'monospace'),
                          //     ),
                          //     const SizedBox(height: 8),
                          //     Text(
                          //       'Queue: ${queue.length}',
                          //       style: const TextStyle(fontFamily: 'monospace'),
                          //     ),
                          //     const SizedBox(height: 16),
                          //     Text(
                          //       current == null
                          //           ? 'No frame yet'
                          //           : 'FRAME PTS ${_fmtMs(current!.ptsMs)}\nNALs: ${current!.nals.length}\nHas IDR: ${current!.hasIdr}',
                          //       textAlign: TextAlign.center,
                          //       style: const TextStyle(
                          //         fontFamily: 'monospace',
                          //         fontSize: 14,
                          //       ),
                          //     ),
                          //     const SizedBox(height: 16),
                          //     const Text(
                          //       'Next step: decode current.nals (SPS/PPS/IDR/P) into pixels',
                          //       textAlign: TextAlign.center,
                          //     ),
                          //   ],
                          // ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const Divider(),
              SingleChildScrollView(
                child: Text(
                  log,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
