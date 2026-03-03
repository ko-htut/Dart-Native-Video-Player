import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ndvy_player/pure_frame_view.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

import 'src/hls.dart';
import 'src/ts_packets.dart';
import 'src/ts_psi.dart';
import 'src/ts_pes.dart';
import 'src/pes_pts.dart';
import 'src/access_unit_pts.dart';
import 'src/player_clock.dart';
import 'src/yuv.dart';
import 'src/decoder/h264_baseline_idr_decoder.dart';
import 'src/decoder/pps.dart';
import 'src/decoder/sps.dart';
import 'src/decoder/bitreader.dart';
import 'src/decoder/exp_golomb.dart';
import 'src/decoder/rbsp.dart';
import 'src/h264_nal.dart';
import 'dart:ui' as ui;

class _VariantProbeResult {
  final bool ok;
  final String reason;
  const _VariantProbeResult(this.ok, this.reason);
}

class PureDartPlaybackScreen extends StatefulWidget {
  const PureDartPlaybackScreen({super.key});
  @override
  State<PureDartPlaybackScreen> createState() => _PureDartPlaybackScreenState();
}

class _PureDartPlaybackScreenState extends State<PureDartPlaybackScreen> {
  final urlCtrl = TextEditingController(
    // text: 'https://filesamples.com/samples/video/mp4/sample_640x360.mp4',
    // HLS example:
    // text: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',

    // text: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    // text: 'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
    // text:'https://sfux-ext.sfux.info/hls/chapter/105/1588724110/1588724110.m3u8',
  
  );

  bool loading = false;
  String log = '';

  final clock = PlayerClock();
  List<TimestampedAccessUnit> queue = [];
  TimestampedAccessUnit? current;
  int _nextAuIndex = 0;
  int _lastUiUpdateMs = 0;

  final decoder = H264IdrDecoder();
  ui.Image? currentImage;
  String decodeInfo = '';
  bool _decoding = false;

  Uint8List? _currentRgba;
  int _frameWidth = 0;
  int _frameHeight = 0;

  void append(String s) => setState(() => log = '$log$s\n');

  @override
  void initState() {
    super.initState();

    clock.onFrameDue = (t) async {
      bool changed = false;
      while (_nextAuIndex < queue.length && queue[_nextAuIndex].ptsMs <= t) {
        current = queue[_nextAuIndex];
        _nextAuIndex++;
        changed = true;
      }
      if (!changed || current == null) {
        if (t - _lastUiUpdateMs >= 100 && mounted) {
          _lastUiUpdateMs = t;
          setState(() {});
        }
        return;
      }

      if (_decoding) return;
      _decoding = true;

      try {
        final au = current!;
        Yuv420Frame? frame;

        try {
          frame = decoder.decodeIdrAccessUnit(au.nals);
        } catch (e, st) {
          debugPrint('decodeIdrAccessUnit error: $e\n$st');
          if (!mounted) return;
          setState(() {
            decodeInfo = 'Decoder error at ${au.ptsMs}ms: $e';
            _currentRgba = null;
            _frameWidth = 0;
            _frameHeight = 0;
            currentImage = null;
          });
          return;
        }

        if (frame == null) {
          if (!mounted) return;
          setState(() {
            decodeInfo = 'Decode null: ${decoder.lastError ?? "unknown"}';
            _currentRgba = null;
            _frameWidth = 0;
            _frameHeight = 0;
            currentImage = null;
          });
          return;
        }

        final rgba = yuv420ToRgba(frame);

        debugPrint("Frame: ${frame.width}x${frame.height} rgba=${rgba.length}");
        int sum = 0, mn = 255, mx = 0;
        for (final p in frame.y) {
          sum += p;
          if (p < mn) mn = p;
          if (p > mx) mx = p;
        }
        debugPrint("Y avg=${sum ~/ frame.y.length} min=$mn max=$mx");

        if (!mounted) return;
        setState(() {
          _currentRgba = rgba;
          _frameWidth = frame!.width;
          _frameHeight = frame.height;
          decodeInfo = decoder.lastError == null
              ? 'Decoded: ${frame.width}x${frame.height}'
              : 'Decoded: ${frame.width}x${frame.height} (${decoder.lastError})';
          currentImage = null;
        });
      } catch (e, st) {
        debugPrint('onFrameDue error: $e\n$st');
        if (!mounted) return;
        setState(() {
          decodeInfo = 'Playback error: $e';
          _currentRgba = null;
          _frameWidth = 0;
          _frameHeight = 0;
          currentImage = null;
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

  Future<_VariantProbeResult> _probeVariantCompatibility(Uri mediaUri) async {
    try {
      final media = await fetchMediaPlaylist(mediaUri);
      if (media.segments.isEmpty) {
        return const _VariantProbeResult(false, 'incompatible: empty media');
      }

      final ppsById = <int, PpsInfo>{};
      final spsById = <int, SpsInfo>{};
      final usedPpsIds = <int>{};
      int idrSliceCount = 0;
      bool hasT8x8 = false;

      final probeSegCount = media.segments.length < 2
          ? media.segments.length
          : 2;
      for (int i = 0; i < probeSegCount; i++) {
        final tsBytes = await fetchBytes(media.segments[i].uri);
        final packets = parseTsPackets(tsBytes).toList();

        final pat = TsPat.find(packets);
        if (pat == null || pat.programs.isEmpty) {
          return const _VariantProbeResult(false, 'incompatible: PAT missing');
        }
        final pmtPid = pat.programs.values.first;
        final pmt = TsPmt.find(packets, pmtPid);
        if (pmt == null) {
          return const _VariantProbeResult(false, 'incompatible: PMT missing');
        }

        final videoStream = pmt.streams.firstWhere(
          (x) => x.streamType == 0x1B,
          orElse: () => const TsStreamInfo(pid: -1, streamType: -1),
        );
        if (videoStream.pid == -1) {
          return const _VariantProbeResult(false, 'incompatible: no H.264');
        }

        final pesPackets = assemblePesPackets(
          packets,
          videoStream.pid,
        ).toList();
        if (pesPackets.isEmpty) continue;

        final es = BytesBuilder(copy: false);
        for (final pes in pesPackets) {
          final parsed = parsePes(pes);
          if (parsed == null) continue;
          es.add(parsed.esPayload);
        }

        final nals = splitAnnexBNals(es.toBytes());
        for (final nal in nals) {
          if (nal.isEmpty) continue;
          final t = nal[0] & 0x1F;
          if (t == 7) {
            final sps = parseSpsNal(nal);
            spsById[sps.spsId] = sps;
          } else if (t == 8) {
            final pps = parsePpsNal(nal);
            ppsById[pps.ppsId] = pps;
          } else if (t == 5) {
            idrSliceCount++;
            final ppsId = _tryReadSlicePpsId(nal);
            if (ppsId != null) usedPpsIds.add(ppsId);
          }
        }
      }

      if (ppsById.isEmpty)
        return const _VariantProbeResult(false, 'incompatible: PPS missing');

      final idsToCheck = usedPpsIds.isNotEmpty
          ? usedPpsIds
          : ppsById.keys.toSet();
      for (final ppsId in idsToCheck) {
        final pps = ppsById[ppsId];
        if (pps == null) {
          return _VariantProbeResult(
            false,
            'incompatible: slice references missing PPS id=$ppsId',
          );
        }
        if (pps.entropyCodingModeFlag) {
          return _VariantProbeResult(
            false,
            'incompatible: CABAC (ppsId=$ppsId)',
          );
        }
        if (pps.numSliceGroupsMinus1 != 0) {
          return _VariantProbeResult(
            false,
            'incompatible: slice_groups=${pps.numSliceGroupsMinus1} (ppsId=$ppsId)',
          );
        }
        if (pps.transform8x8ModeFlag) hasT8x8 = true;

        final sps = spsById[pps.spsId];
        if (sps != null && !sps.frameMbsOnlyFlag) {
          return _VariantProbeResult(
            false,
            'incompatible: field-coded SPS (spsId=${pps.spsId})',
          );
        }
      }

      if (idrSliceCount == 0) {
        return hasT8x8
            ? const _VariantProbeResult(
                true,
                'compatible (no IDR in probe, t8x8=true warning)',
              )
            : const _VariantProbeResult(true, 'compatible (no IDR in probe)');
      }
      return hasT8x8
          ? const _VariantProbeResult(true, 'compatible (t8x8=true warning)')
          : const _VariantProbeResult(true, 'compatible');
    } catch (e) {
      return _VariantProbeResult(false, 'incompatible: probe error ($e)');
    }
  }

  int? _tryReadSlicePpsId(Uint8List sliceNal) {
    try {
      if (sliceNal.isEmpty) return null;
      final t = sliceNal[0] & 0x1F;
      if (t != 1 && t != 5) return null;
      final rbsp = ebspToRbsp(sliceNal.sublist(1));
      final br = BitReader(rbsp);
      readUE(br);
      readUE(br);
      return readUE(br);
    } catch (_) {
      return null;
    }
  }

  Future<void> buildQueue() async {
    setState(() {
      loading = true;
      log = '';
      queue = [];
      current = null;
      _nextAuIndex = 0;
      _lastUiUpdateMs = 0;
    });

    try {
      final url = Uri.parse(urlCtrl.text.trim());
      append('Load: $url');

      final kind = await detectPlaylistKind(url);
      HlsMediaPlaylist media;

      if (kind == HlsPlaylistKind.master) {
        final vars = await fetchHlsVariants(url);
        append('Master playlist. Variants=${vars.length}');
        if (vars.isEmpty) throw Exception('No variants found.');

        final baselineVars = vars
            .where((v) => (v.codecs ?? '').toLowerCase().contains('avc1.42'))
            .toList();
        final nonBaseline = vars
            .where((v) => !(v.codecs ?? '').toLowerCase().contains('avc1.42'))
            .toList();
        final candidates = <HlsVariant>[...baselineVars, ...nonBaseline];

        HlsVariant? pick;
        for (final v in candidates) {
          append(
            'Probe variant: ${v.resolution ?? "?"} bw=${v.bandwidth ?? 0} codecs=${v.codecs ?? "?"}',
          );
          final probe = await _probeVariantCompatibility(v.uri);
          append('  -> ${probe.reason}');
          if (probe.ok) {
            pick = v;
            break;
          }
        }
        if (pick == null) {
          append(
            'No decoder-compatible variant found.\nNeed: CAVLC + no slice groups.',
          );
          return;
        }
        append(
          'Pick variant: ${pick.resolution ?? "?"} bw=${pick.bandwidth ?? 0} codecs=${pick.codecs ?? "?"}',
        );
        media = await fetchMediaPlaylist(pick.uri);
      } else {
        final probe = await _probeVariantCompatibility(url);
        append('Probe media: ${probe.reason}');
        if (!probe.ok) {
          append(
            'Media playlist is not decoder-compatible.\nNeed: CAVLC + no slice groups.',
          );
          return;
        }
        media = await fetchMediaPlaylist(url);
      }

      append('Media segments=${media.segments.length}');
      if (media.segments.isEmpty) return;

      const int maxSegments = 20;
      final int segLimit = media.segments.length < maxSegments
          ? media.segments.length
          : maxSegments;

      final allPtsChunks = <PtsChunk>[];
      int? basePts90k;
      BytesBuilder? pendingPes;
      int? cachedPmtPid;
      int? cachedVideoPid;

      for (int s = 0; s < segLimit; s++) {
        final seg = media.segments[s];
        append(
          '\nSEG $s seq=${seg.sequence} dur=${seg.duration.toStringAsFixed(2)}',
        );
        final tsBytes = await fetchBytes(seg.uri);
        final packets = parseTsPackets(tsBytes).toList();

        final pat = TsPat.find(packets);
        if (pat != null && pat.programs.isNotEmpty)
          cachedPmtPid = pat.programs.values.first;
        if (cachedPmtPid == null) {
          append('  PAT missing (no cached PMT PID)');
          continue;
        }

        final pmt = TsPmt.find(packets, cachedPmtPid);
        if (pmt != null) {
          final videoStream = pmt.streams.firstWhere(
            (x) => x.streamType == 0x1B,
            orElse: () => const TsStreamInfo(pid: -1, streamType: -1),
          );
          if (videoStream.pid != -1) cachedVideoPid = videoStream.pid;
        }
        if (cachedVideoPid == null) {
          append('  PMT/video PID missing (no cached video PID)');
          continue;
        }
        final videoPid = cachedVideoPid;

        int pesCompleted = 0;
        for (final pkt in packets) {
          if (pkt.pid != videoPid) continue;
          if (pkt.payload.isEmpty) continue;

          final isPesStart =
              pkt.payload.length >= 3 &&
              pkt.payload[0] == 0x00 &&
              pkt.payload[1] == 0x00 &&
              pkt.payload[2] == 0x01;

          if (pkt.payloadUnitStart && isPesStart) {
            if (pendingPes != null) {
              final parsed = parsePes(pendingPes.toBytes());
              if (parsed != null) {
                if (parsed.pts90k != null) basePts90k ??= parsed.pts90k;
                allPtsChunks.add(
                  PtsChunk(pts90k: parsed.pts90k, payload: parsed.esPayload),
                );
                pesCompleted++;
              }
            }
            pendingPes = BytesBuilder(copy: false);
            pendingPes.add(pkt.payload);
          } else {
            if (pendingPes == null) continue;
            pendingPes.add(pkt.payload);
          }
        }
        append('  PES completed=$pesCompleted');
      }

      final out = buildTimestampedIdrAusFromPtsChunks(
        ptsChunks: allPtsChunks,
        basePts90k: basePts90k,
      );

      out.sort((a, b) => a.ptsMs.compareTo(b.ptsMs));
      queue = _ensureAuHasCachedParamSets(out);

      _nextAuIndex = 0;
      _lastUiUpdateMs = 0;

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

  List<TimestampedAccessUnit> _ensureAuHasCachedParamSets(
    List<TimestampedAccessUnit> input,
  ) {
    Uint8List? cachedSps;
    Uint8List? cachedPps;
    final out = <TimestampedAccessUnit>[];

    for (final au in input) {
      bool hasSps = false;
      bool hasPps = false;
      for (final nal in au.nals) {
        if (nal.isEmpty) continue;
        final t = nal[0] & 0x1F;
        if (t == 7) {
          cachedSps = nal;
          hasSps = true;
        } else if (t == 8) {
          cachedPps = nal;
          hasPps = true;
        }
      }

      final fixedNals = <Uint8List>[];
      if (!hasSps && cachedSps != null) fixedNals.add(cachedSps);
      if (!hasPps && cachedPps != null) fixedNals.add(cachedPps);
      fixedNals.addAll(au.nals);

      out.add(
        TimestampedAccessUnit(
          ptsMs: au.ptsMs,
          nals: fixedNals,
          hasIdr: au.hasIdr,
        ),
      );
    }
    return out;
  }

  Future<void> buildQueueFromMp4(Uri mp4Url) async {
    setState(() {
      loading = true;
      log = '';
      queue = [];
      current = null;
      _nextAuIndex = 0;
      _lastUiUpdateMs = 0;
    });

    try {
      append("Load MP4: $mp4Url");
      final bytes = await fetchBytes(mp4Url);

      final track = Mp4Demux.parseH264Track(bytes);
      append("MP4 timescale=${track.timescale}");
      append(
        "avcC nalLen=${track.avc.nalLengthSize} SPS=${track.avc.sps.length} PPS=${track.avc.pps.length}",
      );
      append("samples=${track.sampleSizes.length}");

      final out = <TimestampedAccessUnit>[];

      for (int i = 0; i < track.sampleSizes.length; i++) {
        final sampleNals = Mp4Demux.readSampleNalUnits(bytes, track, i);

        bool hasIdr = false;
        for (final n in sampleNals) {
          final nalType = n.isEmpty ? 0 : (n[0] & 0x1F);
          if (nalType == 5) {
            hasIdr = true;
            break;
          }
        }

        final nals = <Uint8List>[
          ...track.avc.sps,
          ...track.avc.pps,
          ...sampleNals,
        ];

        final dts = track.dts[i];
        final ptsMs = (dts * 1000 ~/ track.timescale);

        out.add(
          TimestampedAccessUnit(ptsMs: ptsMs, nals: nals, hasIdr: hasIdr),
        );
      }

      out.sort((a, b) => a.ptsMs.compareTo(b.ptsMs));
      queue = out;

      append("MP4 Queue built: ${queue.length} samples");
      if (queue.isNotEmpty) {
        append(
          "First PTS=${queue.first.ptsMs}ms Last PTS=${queue.last.ptsMs}ms",
        );
      }

      setState(() {});
    } catch (e) {
      append("MP4 ERROR: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  void play() {
    if (queue.isEmpty) return;
    if (_nextAuIndex >= queue.length) _nextAuIndex = 0;
    final startMs = current?.ptsMs ?? queue[_nextAuIndex].ptsMs;
    clock.play(fromMs: startMs);
  }

  void pause() => clock.pause();

  void seekToStart() {
    if (queue.isEmpty) return;
    clock.pause();
    setState(() {
      current = null;
      _nextAuIndex = 0;
      _lastUiUpdateMs = queue.first.ptsMs;
    });
    clock.setTime(queue.first.ptsMs);
  }

  @override
  Widget build(BuildContext context) {
    final url = urlCtrl.text.trim().toLowerCase();
    final isMp4 = url.endsWith('.mp4');

    return Scaffold(
      appBar: AppBar(title: const Text('Pure Dart Playback')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: '.m3u8 or .mp4 URL',
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
                    child: Text(loading ? 'Building…' : 'Build Queue (HLS/TS)'),
                  ),
                  FilledButton(
                    onPressed: loading
                        ? null
                        : () =>
                              buildQueueFromMp4(Uri.parse(urlCtrl.text.trim())),
                    child: const Text('Build Queue (MP4)'),
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
                  if (isMp4)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text(
                        'Mode: MP4',
                        style: TextStyle(fontFamily: 'monospace'),
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text(
                        'Mode: HLS',
                        style: TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 220,
                width: double.infinity,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.black12),
                    color: Colors.black,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child:
                            (_currentRgba == null ||
                                _frameWidth == 0 ||
                                _frameHeight == 0)
                            ? Center(
                                child: Text(
                                  "info : $decodeInfo",
                                  style: const TextStyle(color: Colors.white),
                                ),
                              )
                            : PureFrameView(
                                rgba: _currentRgba!,
                                width: _frameWidth,
                                height: _frameHeight,
                              ),
                      ),
                      Positioned(
                        left: 10,
                        bottom: 10,
                        right: 10,
                        child: Text(
                          current == null
                              ? 'No frame yet'
                              : 'PTS ${_fmtMs(current!.ptsMs)} | NALs ${current!.nals.length} | ${_frameWidth}x$_frameHeight\n$decodeInfo',
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(),
              Text(
                log,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
