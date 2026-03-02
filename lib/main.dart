import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:h264/h264.dart';
import 'package:path_provider/path_provider.dart';

import 'src/hls.dart';
import 'src/ts.dart';
import 'src/h264_nal.dart';
import 'src/decoder/sps_parser.dart';
import 'src/thumb.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: const IdrTimelineScreen(),
    );
  }
}

class IdrTimelineScreen extends StatefulWidget {
  const IdrTimelineScreen({super.key});

  @override
  State<IdrTimelineScreen> createState() => _IdrTimelineScreenState();
}

class _IdrTimelineScreenState extends State<IdrTimelineScreen> {
  final urlCtrl = TextEditingController(
    text: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
  );

  bool loading = false;
  String log = '';

  final List<IdrThumb> _thumbs = [];
  IdrThumb? _selected;

  // Cached parameter sets (SPS/PPS) across segments
  Uint8List? _cachedSps;
  Uint8List? _cachedPps;
  SpsInfo? _cachedSpsInfo;

  void append(String s) => setState(() => log = '$log$s\n');

  // ---------------------------
  // Helpers
  // ---------------------------

  String _fmtTime(double sec) {
    final s = sec.floor();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  void _updateParamSetCacheFromNals(List<Uint8List> nals) {
    for (final nal in nals) {
      if (nal.isEmpty) continue;
      final t = nal[0] & 0x1F;
      if (t == 7) {
        _cachedSps = nal;
        _cachedSpsInfo = parseSps(nal);
      } else if (t == 8) {
        _cachedPps = nal;
      }
    }
  }

  List<Uint8List> _ensureAuHasSpsPps(List<Uint8List> auNals) {
    bool hasSps = false;
    bool hasPps = false;

    for (final nal in auNals) {
      if (nal.isEmpty) continue;
      final t = nal[0] & 0x1F;
      if (t == 7) hasSps = true;
      if (t == 8) hasPps = true;
    }

    final out = <Uint8List>[];
    if (!hasSps && _cachedSps != null) out.add(_cachedSps!);
    if (!hasPps && _cachedPps != null) out.add(_cachedPps!);
    out.addAll(auNals);
    return out;
  }

  SpsInfo? _findSpsInfo(List<Uint8List> auNals) {
    for (final nal in auNals) {
      if (nal.isEmpty) continue;
      final t = nal[0] & 0x1F;
      if (t == 7) return parseSps(nal);
    }
    return null;
  }

  Future<File> _decodeIdrAuToPng({
    required List<Uint8List> auNals,
    required int width,
    required int height,
    required int index,
  }) async {
    final dir = await getTemporaryDirectory();
    final src = File('${dir.path}/au_$index.h264');
    final dst = File('${dir.path}/au_$index.png');

    final b = BytesBuilder(copy: false);
    for (final nal in auNals) {
      b.add(const [0, 0, 0, 1]);
      b.add(nal);
    }
    await src.writeAsBytes(b.toBytes(), flush: true);

    await H264.decodeFrame(src.path, dst.path, width, height);
    return dst;
  }

  Future<void> _selectThumb(IdrThumb t) async {
    setState(() => _selected = t);
  }

  // ---------------------------
  // ✅ Milestone A + Timeline
  // ---------------------------

  Future<void> runMilestoneA() async {
    setState(() {
      loading = true;
      log = '';
      _thumbs.clear();
      _selected = null;
      _cachedSps = null;
      _cachedPps = null;
      _cachedSpsInfo = null;
    });

    const int maxThumbs = 20;
    const int maxSegmentsToScan = 50;

    try {
      final url = Uri.parse(urlCtrl.text.trim());
      append('Load: $url');

      final kind = await detectPlaylistKind(url);
      HlsMediaPlaylist media;

      if (kind == HlsPlaylistKind.master) {
        final vars = await fetchHlsVariants(url);
        append('Master playlist. Variants=${vars.length}');
        if (vars.isEmpty) throw Exception('No variants found.');

        append(
          'Pick variant: res=${vars.first.resolution ?? "?"} bw=${vars.first.bandwidth ?? 0}',
        );
        media = await fetchMediaPlaylist(vars.first.uri);
      } else {
        media = await fetchMediaPlaylist(url);
      }

      append(
        'Media: segments=${media.segments.length} target=${media.targetDuration}s seq=${media.mediaSequence}',
      );
      if (media.segments.isEmpty) return;

      final segLimit = media.segments.length < maxSegmentsToScan
          ? media.segments.length
          : maxSegmentsToScan;

      // Track approximate segment time offsets using EXTINF
      double timeOffset = 0.0;

      // Optional duplicate avoidance
      final seenIdrSignatures = <int>{};

      for (int s = 0; s < segLimit; s++) {
        if (_thumbs.length >= maxThumbs) break;

        final seg = media.segments[s];
        final segStart = timeOffset;
        timeOffset += seg.duration;

        append(
          '\n[SEG $s/$segLimit] seq=${seg.sequence} t=${_fmtTime(segStart)} dur=${seg.duration.toStringAsFixed(2)}',
        );
        Uint8List tsBytes;
        try {
          tsBytes = await fetchBytes(seg.uri);
        } catch (e) {
          append('  download failed: $e');
          continue;
        }

        final packets = parseTsPackets(tsBytes).toList();
        if (packets.isEmpty) {
          append('  TS parse: 0 packets');
          continue;
        }

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

        final videoStreams = pmt.streams
            .where((x) => x.streamType == 0x1B)
            .toList();
        if (videoStreams.isEmpty) {
          append('  no H.264 stream in PMT');
          continue;
        }
        final videoPid = videoStreams.first.pid;

        final es = extractElementaryStream(packets, videoPid);
        if (es.isEmpty) {
          append('  ES empty');
          continue;
        }

        final nals = splitAnnexBNals(es);
        if (nals.isEmpty) {
          append('  NALs: 0');
          continue;
        }

        _updateParamSetCacheFromNals(nals);
        if (_cachedSpsInfo != null) {
          append(
            '  cached SPS: ${_cachedSpsInfo!.width}x${_cachedSpsInfo!.height} pps=${_cachedPps != null}',
          );
        } else {
          append('  cached SPS: none');
        }

        final idrAus = buildIdrAccessUnits(nals);
        append('  IDR AUs: ${idrAus.length}');

        for (int i = 0; i < idrAus.length; i++) {
          if (_thumbs.length >= maxThumbs) break;

          final au = idrAus[i];
          final fixedAuNals = _ensureAuHasSpsPps(au.nals);
          final spsInfo = _findSpsInfo(fixedAuNals) ?? _cachedSpsInfo;

          if (spsInfo == null) {
            append('    AU#$i: no SPS available, skip');
            continue;
          }

          // Duplicate check (signature from first IDR NAL)
          final idrNal = fixedAuNals.firstWhere(
            (n) => n.isNotEmpty && ((n[0] & 0x1F) == 5),
            orElse: () => Uint8List(0),
          );
          if (idrNal.isNotEmpty) {
            int sig = idrNal.length;
            for (int k = 0; k < 12 && k < idrNal.length; k++) {
              sig = (sig * 31) ^ idrNal[k];
            }
            if (seenIdrSignatures.contains(sig)) {
              append('    AU#$i: duplicate IDR, skip');
              continue;
            }
            seenIdrSignatures.add(sig);
          }

          append('    AU#$i: decode ${spsInfo.width}x${spsInfo.height}');
          try {
            final pngFile = await _decodeIdrAuToPng(
              auNals: fixedAuNals,
              width: spsInfo.width,
              height: spsInfo.height,
              index: _thumbs.length,
            );

            final thumb = IdrThumb(
              segmentIndex: s,
              sequence: seg.sequence,
              timeSec: segStart,
              pngPath: pngFile.path,
            );

            setState(() {
              _thumbs.add(thumb);
              _selected ??= thumb;
            });

            append('    -> OK thumb#${_thumbs.length} @ ${_fmtTime(segStart)}');
          } catch (e) {
            append('    -> decode failed: $e');
          }

          // tiny yield for UI responsiveness
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      append('\nDONE: thumbs=${_thumbs.length}');
    } catch (e) {
      append('ERROR: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;

    return Scaffold(
      appBar: AppBar(title: const Text('IDR Timeline (Milestone A)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
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
            Row(
              children: [
                FilledButton(
                  onPressed: loading ? null : runMilestoneA,
                  child: Text(loading ? 'Scanning…' : 'Scan & Build Timeline'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Thumbs: ${_thumbs.length}  '
                    '${selected == null ? "" : "Selected: ${_fmtTime(selected.timeSec)}"}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Main preview
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: selected == null
                    ? const Center(child: Text('No preview yet'))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.file(
                          File(selected.pngPath),
                          fit: BoxFit.contain,
                        ),
                      ),
              ),
            ),

            const SizedBox(height: 10),

            // Timeline thumbnails
            SizedBox(
              height: 160,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _thumbs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final t = _thumbs[i];
                  final isSel = selected?.pngPath == t.pngPath;

                  return GestureDetector(
                    onTap: () => _selectThumb(t),
                    child: Container(
                      width: 160,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSel ? Colors.blue : Colors.black12,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              File(t.pngPath),
                              width: 148,
                              height: 96,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _fmtTime(t.timeSec),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'seg ${t.segmentIndex} / seq ${t.sequence}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.black54,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const Divider(),

            // Logs
            SizedBox(
              height: 140,
              child: SingleChildScrollView(
                child: Text(
                  log.isEmpty ? 'No logs yet.' : log,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
