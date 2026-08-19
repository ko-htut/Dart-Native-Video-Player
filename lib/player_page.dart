import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:ndvy_player/pure_frame_view.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

import 'src/audio/aac/adts.dart';
import 'src/audio/aac/ts_aac_demux.dart';
import 'src/audio/audio_decode_pipeline.dart';
import 'src/audio/audio_playback_controller.dart';
import 'src/audio/pcm_sink.dart';
import 'src/audio/pcm_timeline.dart';
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
    // --- MP4 (use "Build Queue (MP4)" button) ---
    // text: 'assets/butterfly_dart.mp4',
    // text: 'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
    // text: 'https://filesamples.com/samples/video/mp4/sample_640x360.mp4',

    // --- HLS (use "Build Queue (HLS/TS)" button) ---
    text: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    // text: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    // text: 'https://sfux-ext.sfux.info/hls/chapter/105/1588724110/1588724110.m3u8',
  );

  bool loading = false;
  String log = '';

  final clock = PlayerClock();
  List<TimestampedAccessUnit> queue = [];
  TimestampedAccessUnit? current;

  final decoder = H264BaselineDecoder();
  late final SequentialDecodePump<TimestampedAccessUnit, Yuv420Frame>
  _decodePump;
  String decodeInfo = '';
  String audioInfo = 'Audio: none';

  AudioPlaybackController? _audioController;
  StreamSubscription<AudioPlaybackEvent>? _audioEvents;
  Future<void> _transportTail = Future<void>.value();

  Uint8List? _currentRgba;
  int _frameWidth = 0;
  int _frameHeight = 0;

  void append(String s) {
    if (!mounted) return;
    setState(() => log = '$log$s\n');
  }

  /// Serializes play/pause/seek so a quick second tap cannot overtake an
  /// in-flight platform-sink command.
  Future<void> _serializeTransport(Future<void> Function() operation) {
    final previous = _transportTail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // A failed transport command must not poison every later command.
      }
      await operation();
    }();
    _transportTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  @override
  void initState() {
    super.initState();
    _decodePump = SequentialDecodePump<TimestampedAccessUnit, Yuv420Frame>(
      timestampOf: (au) => au.ptsMs,
      decode: (au) => decoder.decodeAccessUnitOrThrow(au.nals),
      onLatestDecoded: _presentDecodedFrame,
      onDecodeError: _handleDecodeError,
      onQueueDrained: _handleQueueDrained,
    );
    clock.onFrameDue = _decodePump.requestThrough;
  }

  void _presentDecodedFrame(TimestampedAccessUnit au, Yuv420Frame frame) {
    final rgba = yuv420ToRgba(frame);
    final stats = decoder.lastStats;
    debugPrint(
      'Frame ${stats?.frameNumber ?? "?"}: ${frame.width}x${frame.height} '
      '${stats?.sliceType.name ?? "?"} rgba=${rgba.length}',
    );

    if (!mounted) return;
    setState(() {
      current = au;
      _currentRgba = rgba;
      _frameWidth = frame.width;
      _frameHeight = frame.height;
      decodeInfo =
          'Decoded ${stats?.sliceType.name.toUpperCase() ?? "frame"}: '
          '${frame.width}x${frame.height}';
    });
  }

  void _handleDecodeError(
    TimestampedAccessUnit au,
    Object error,
    StackTrace stackTrace,
  ) {
    clock.pause();
    final audio = _audioController;
    if (audio != null) unawaited(audio.pause());
    debugPrint('decodeAccessUnit error at ${au.ptsMs}ms: $error\n$stackTrace');
    if (!mounted) return;
    setState(() {
      decodeInfo = 'Decoder stopped at ${au.ptsMs}ms: $error';
    });
  }

  void _handleQueueDrained() {
    final audioStillPlaying = _audioController?.isPlaying ?? false;
    if (!audioStillPlaying) clock.pause();
    if (!mounted) return;
    setState(() {
      decodeInfo = audioStillPlaying
          ? 'Video complete — audio finishing…'
          : 'Playback complete — press Play to replay';
    });
  }

  @override
  void dispose() {
    urlCtrl.dispose();
    clock.dispose();
    _decodePump.dispose();
    unawaited(_disposeAudio());
    super.dispose();
  }

  String _fmtMs(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  Future<void> _beginQueueBuild() async {
    setState(() {
      loading = true;
      log = '';
      queue = [];
      current = null;
      decodeInfo = 'Building playback queue…';
      audioInfo = 'Audio: probing…';
      _currentRgba = null;
      _frameWidth = 0;
      _frameHeight = 0;
    });
    await _serializeTransport(() async {
      clock.pause();
      final audio = _audioController;
      if (audio != null && audio.isPlaying) await audio.pause();
      await _disposeAudio();
      decoder.reset();
      _decodePump.replaceQueue(const []);
    });
  }

  void _installQueue(List<TimestampedAccessUnit> accessUnits) {
    clock.pause();
    decoder.reset();
    queue = List<TimestampedAccessUnit>.unmodifiable(accessUnits);
    _decodePump.replaceQueue(queue);
    current = null;
    decodeInfo = queue.isEmpty
        ? 'No access units found'
        : 'Ready — ${queue.length} access units';
    _currentRgba = null;
    _frameWidth = 0;
    _frameHeight = 0;
  }

  Future<Uint8List> loadAssetBytes(String path) async {
    final bd = await rootBundle.load(path);
    return bd.buffer.asUint8List();
  }

  Future<void> _installAudioTimeline(PcmAudioTimeline timeline) async {
    await _disposeAudio();
    final sink = await createNativePcmAudioSink();
    final controller = AudioPlaybackController(sink);
    final events = controller.events.listen(_handleAudioEvent);
    try {
      await controller.load(timeline);
    } catch (_) {
      await events.cancel();
      await controller.dispose();
      rethrow;
    }
    if (!mounted) {
      await events.cancel();
      await controller.dispose();
      return;
    }
    _audioController = controller;
    _audioEvents = events;
    setState(() {
      audioInfo =
          'Audio: AAC-LC ${timeline.sampleRate} Hz, '
          '${timeline.channels == 1 ? "mono" : "stereo"}, '
          '${_fmtMs(timeline.durationUs ~/ 1000)}';
    });
  }

  Future<void> _disposeAudio() async {
    final events = _audioEvents;
    final controller = _audioController;
    _audioEvents = null;
    _audioController = null;
    if (events != null) await events.cancel();
    if (controller != null) await controller.dispose();
  }

  void _handleAudioEvent(AudioPlaybackEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case AudioPlaybackEventType.complete:
        final videoComplete = _decodePump.nextIndex >= queue.length;
        if (videoComplete) {
          clock.pause();
          setState(() {
            decodeInfo = 'Playback complete — press Play to replay';
          });
        } else {
          // Audio is normally the master clock. If a valid file has a shorter
          // audio edit than video edit, finish the remaining pictures against
          // a wall clock instead of freezing on the last PCM frame.
          final endMs = event.mediaTimeUs ~/ 1000;
          clock.play(fromMs: endMs);
          setState(() {
            decodeInfo = 'Audio complete — video finishing…';
          });
        }
      case AudioPlaybackEventType.underrun:
        setState(() {
          audioInfo = 'Audio underrun: ${event.message ?? "buffer starved"}';
        });
      case AudioPlaybackEventType.error:
        clock.pause();
        setState(() {
          audioInfo = 'Audio stopped: ${event.message ?? "unknown error"}';
        });
      case AudioPlaybackEventType.ready:
      case AudioPlaybackEventType.position:
        break;
    }
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

      if (ppsById.isEmpty) {
        return const _VariantProbeResult(false, 'incompatible: PPS missing');
      }

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
        if (pps.transform8x8ModeFlag || pps.picScalingMatrixPresentFlag) {
          return _VariantProbeResult(
            false,
            'incompatible: 8x8 transform/scaling matrix (ppsId=$ppsId)',
          );
        }

        final sps = spsById[pps.spsId];
        if (sps != null && !sps.isSupportedBaseline420) {
          return _VariantProbeResult(
            false,
            'incompatible: unsupported profile/chroma/bit-depth '
            '(spsId=${pps.spsId}, profile=${sps.profileIdc})',
          );
        }
      }

      if (idrSliceCount == 0) {
        return const _VariantProbeResult(true, 'compatible (no IDR in probe)');
      }
      return const _VariantProbeResult(true, 'compatible');
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
    await _beginQueueBuild();

    try {
      final url = Uri.parse(urlCtrl.text.trim());
      append('Load: $url');

      final kind = await detectPlaylistKind(url);
      HlsMediaPlaylist media;
      HlsMediaPlaylist? separateAudioMedia;
      var primaryUsesUnsupportedHeAac = false;
      String? unsupportedAudioReason;

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
        primaryUsesUnsupportedHeAac =
            hlsVariantAdvertisesHeAac(pick) && !hlsVariantAdvertisesAacLc(pick);

        final audioPick = selectHlsAacLcVariant(vars, preferred: pick);
        if (audioPick != null && audioPick.uri != pick.uri) {
          append(
            'Pick AAC-LC audio rendition: ${audioPick.resolution ?? "?"} '
            'bw=${audioPick.bandwidth ?? 0} codecs=${audioPick.codecs ?? "?"}',
          );
          try {
            separateAudioMedia = await fetchMediaPlaylist(audioPick.uri);
          } catch (error) {
            if (primaryUsesUnsupportedHeAac) {
              unsupportedAudioReason =
                  'Audio unavailable: selected HLS rendition uses HE-AAC '
                  'and its AAC-LC fallback playlist could not be loaded '
                  '($error).';
              append(unsupportedAudioReason);
            } else {
              append(
                'AAC-LC fallback playlist could not be loaded ($error); '
                'trying primary rendition audio.',
              );
            }
          }
        } else if (audioPick == null && primaryUsesUnsupportedHeAac) {
          unsupportedAudioReason =
              'Audio unavailable: selected HLS rendition advertises HE-AAC, '
              'but the Dart decoder supports AAC-LC only and this master '
              'has no AAC-LC fallback rendition.';
          append(unsupportedAudioReason);
        }
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
      if (media.isEndList && segLimit < media.segments.length) {
        final windowDurationMs =
            (media.segments
                        .take(segLimit)
                        .fold<double>(
                          0,
                          (sum, segment) => sum + segment.duration,
                        ) *
                    1000)
                .round();
        append(
          'VOD safety window: loading first $segLimit/'
          '${media.segments.length} segments (${_fmtMs(windowDurationMs)}); '
          '${media.segments.length - segLimit} later segments are not queued.',
        );
      }
      List<HlsSegmentPair>? separateAudioPairs;
      var usePrimaryAudio =
          separateAudioMedia == null && !primaryUsesUnsupportedHeAac;
      if (separateAudioMedia != null) {
        try {
          separateAudioPairs = pairHlsVariantSegments(
            media,
            separateAudioMedia,
            limit: segLimit,
          );
          append(
            'Using synchronized component renditions: '
            '${separateAudioPairs.length} video/audio segment pairs',
          );
        } catch (error) {
          append('AAC-LC rendition rejected: $error');
          if (primaryUsesUnsupportedHeAac) {
            unsupportedAudioReason =
                'Audio unavailable: selected HLS video rendition uses '
                'unsupported HE-AAC and its AAC-LC fallback is not '
                'synchronized ($error).';
            append(unsupportedAudioReason);
          } else {
            // CODECS can be absent or incomplete. If the primary rendition is
            // not explicitly HE-AAC, retain the existing demux-and-validate
            // path rather than silently discarding a potentially valid track.
            usePrimaryAudio = true;
            append(
              'Falling back to the primary rendition audio because it is not '
              'advertised as HE-AAC.',
            );
          }
        }
      }

      final allPtsChunks = <PtsChunk>[];
      final allAudioAccessUnits = <AacAccessUnit>[];
      int? basePts90k;
      BytesBuilder? pendingPes;
      int? cachedPmtPid;
      int? cachedVideoPid;
      int? cachedAudioPmtPid;
      TsAacDemuxer? audioDemuxer;
      String? audioDemuxWarning;

      void finishAudioDemuxer(
        TsAacDemuxer demuxer, {
        required String warningPrefix,
      }) {
        try {
          allAudioAccessUnits.addAll(demuxer.finish());
        } catch (error) {
          // HLS segment selection can intentionally end between PES/ADTS
          // boundaries. Audio is optional here: retain access units that were
          // already completed and never discard the valid video queue.
          audioDemuxWarning = '$warningPrefix: $error';
          append(audioDemuxWarning!);
        }
      }

      void ingestAudioPackets(List<TsPacket> packets) {
        final pat = TsPat.find(packets);
        if (pat != null && pat.programs.isNotEmpty) {
          cachedAudioPmtPid = pat.programs.values.first;
        }
        final pmtPid = cachedAudioPmtPid;
        if (pmtPid == null) return;
        final pmt = TsPmt.find(packets, pmtPid);
        final audioStream = pmt == null ? null : findAdtsAacStream(pmt);
        if (audioStream != null && audioDemuxer?.pid != audioStream.pid) {
          final previousDemuxer = audioDemuxer;
          if (previousDemuxer != null) {
            finishAudioDemuxer(
              previousDemuxer,
              warningPrefix: 'AAC PID change dropped a partial frame',
            );
          }
          audioDemuxer = TsAacDemuxer(pid: audioStream.pid);
          append('  AAC PID=${audioStream.pid}');
        }
        final activeDemuxer = audioDemuxer;
        if (activeDemuxer != null) {
          allAudioAccessUnits.addAll(activeDemuxer.pushPackets(packets));
        }
      }

      for (int s = 0; s < segLimit; s++) {
        final seg = media.segments[s];
        append(
          '\nSEG $s seq=${seg.sequence} dur=${seg.duration.toStringAsFixed(2)}',
        );
        final tsBytes = await fetchBytes(seg.uri);
        final packets = parseTsPackets(tsBytes).toList();

        final pat = TsPat.find(packets);
        if (pat != null && pat.programs.isNotEmpty) {
          cachedPmtPid = pat.programs.values.first;
        }
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

        if (usePrimaryAudio) ingestAudioPackets(packets);

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

      final audioPairs = separateAudioPairs;
      if (audioPairs != null) {
        for (var index = 0; index < audioPairs.length; index++) {
          final pair = audioPairs[index];
          append(
            'AUDIO SEG $index seq=${pair.audio.sequence} '
            'dur=${pair.audio.duration.toStringAsFixed(2)}',
          );
          final bytes = await fetchBytes(pair.audio.uri);
          ingestAudioPackets(parseTsPackets(bytes).toList());
        }
      }

      if (pendingPes != null) {
        final parsed = parsePes(pendingPes.toBytes());
        if (parsed != null) {
          if (parsed.pts90k != null) basePts90k ??= parsed.pts90k;
          allPtsChunks.add(
            PtsChunk(pts90k: parsed.pts90k, payload: parsed.esPayload),
          );
        }
      }

      final activeAudioDemuxer = audioDemuxer;
      if (activeAudioDemuxer != null) {
        finishAudioDemuxer(
          activeAudioDemuxer,
          warningPrefix: 'AAC tail dropped at segment boundary',
        );
      }

      if (audioPairs != null) {
        final videoPts90k = basePts90k;
        final audioPts90k = allAudioAccessUnits.isEmpty
            ? null
            : allAudioAccessUnits.first.pts90k;
        if (videoPts90k == null || audioPts90k == null) {
          unsupportedAudioReason =
              'Audio unavailable: synchronized AAC-LC fallback has no '
              'verifiable first MPEG PTS (video=$videoPts90k, '
              'audio=$audioPts90k).';
          allAudioAccessUnits.clear();
          append(unsupportedAudioReason);
        } else {
          try {
            final delta90k = validateHlsFirstPtsAlignment(
              videoPts90k: videoPts90k,
              audioPts90k: audioPts90k,
            );
            append(
              'Component PTS aligned: audio-video delta '
              '${(delta90k * 1000 / 90000).toStringAsFixed(3)}ms',
            );
          } catch (error) {
            unsupportedAudioReason =
                'Audio unavailable: AAC-LC fallback is not synchronized '
                'with the selected video ($error).';
            allAudioAccessUnits.clear();
            append(unsupportedAudioReason);
          }
        }
      }

      final out = buildTimestampedAccessUnitsFromPtsChunks(
        ptsChunks: allPtsChunks,
        basePts90k: basePts90k,
      );

      // The builder returns elementary-stream decode order. Do not sort equal
      // or interpolated PTS values: reference pictures must stay in bitstream
      // order even when several access units share a presentation timestamp.
      final firstIdr = out.indexWhere((au) => au.hasIdr);
      if (firstIdr < 0) {
        append('No random-access picture found in downloaded segments.');
        return;
      }
      if (firstIdr > 0) {
        append('Dropped $firstIdr leading dependent access units.');
      }
      _installQueue(out.sublist(firstIdr));

      if (allAudioAccessUnits.isNotEmpty) {
        final originPts90k =
            basePts90k ?? allAudioAccessUnits.first.pts90k ?? 0;
        append(
          'Decoding ${allAudioAccessUnits.length} AAC access units in Dart…',
        );
        try {
          final audioAccessUnits = List<AacAccessUnit>.unmodifiable(
            allAudioAccessUnits,
          );
          final timeline = await decodeTransportAacToPcmInBackground(
            audioAccessUnits,
            originPts90k: originPts90k,
          );
          await _installAudioTimeline(timeline);
          append(
            'Audio ready: ${timeline.sampleRate} Hz, '
            '${timeline.channels} channel(s)',
          );
        } catch (error) {
          audioInfo = 'Audio unavailable: $error';
          append(audioInfo);
        }
      } else {
        audioInfo =
            unsupportedAudioReason ??
            (audioDemuxWarning != null
                ? 'Audio unavailable: incomplete AAC tail'
                : audioDemuxer == null
                ? 'Audio: no muxed ADTS AAC track'
                : 'Audio: AAC track contained no complete frames');
      }

      append('\nHLS queue built: ${queue.length} access units');
      if (queue.isNotEmpty) {
        append(
          'First PTS=${queue.first.ptsMs}ms Last PTS=${queue.last.ptsMs}ms',
        );
      }

      setState(() {});
    } catch (e) {
      append('ERROR: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> buildQueueFromMp4(Uri mp4Url) async {
    await _beginQueueBuild();

    try {
      append("Load MP4: $mp4Url");
      Uint8List bytes;

      // URL routing:
      //  1. "assets/..." or "asset:///..." → Flutter asset bundle
      //  2. http(s) URL ending in .mp4     → fetch from network
      //  3. Anything else (e.g. HLS .m3u8) → bundled A/V demo asset
      final urlStr = mp4Url.toString().trim();
      final isAssetUrl =
          urlStr.startsWith('assets/') ||
          urlStr.startsWith('asset:///') ||
          mp4Url.scheme == 'asset';
      final isNetworkMp4 =
          (mp4Url.scheme == 'http' || mp4Url.scheme == 'https') &&
          urlStr.toLowerCase().endsWith('.mp4');

      if (isAssetUrl) {
        final assetPath = urlStr.replaceFirst(RegExp(r'^asset:///'), '');
        bytes = await loadAssetBytes(assetPath);
        append("Using asset: $assetPath (${bytes.length} bytes)");
      } else if (isNetworkMp4) {
        append("Fetching MP4 from network…");
        bytes = await fetchBytes(mp4Url);
        append("Loaded ${bytes.length} bytes from URL");
      } else {
        // URL is not an MP4 (e.g. the HLS .m3u8 default) — use bundled asset.
        const fallback = 'assets/butterfly_dart.mp4';
        try {
          bytes = await loadAssetBytes(fallback);
          append(
            "URL is not MP4. Using bundled $fallback (${bytes.length} bytes)",
          );
        } catch (e) {
          throw Exception(
            'No bundled asset and URL "$urlStr" is not an .mp4. '
            'Enter an MP4 URL or "assets/butterfly_dart.mp4" to use this button.',
          );
        }
      }

      final track = Mp4Demux.parseH264Track(bytes);
      append("MP4 timescale=${track.timescale}");
      append(
        "avcC nalLen=${track.avc.nalLengthSize} SPS=${track.avc.sps.length} PPS=${track.avc.pps.length}",
      );
      append("samples=${track.sampleSizes.length}");

      if (track.avc.sps.isNotEmpty) {
        final sps = parseSpsNal(track.avc.sps.first);
        append(
          "MP4 SPS: ${sps.width}x${sps.height} profile=${sps.profileIdc} level=${sps.levelIdc}",
        );
      } else {
        append("MP4 WARN: no SPS in avcC");
      }

      if (track.avc.pps.isNotEmpty) {
        final pps = parsePpsNal(track.avc.pps.first);
        append(
          "MP4 PPS: entropyCodingModeFlag=${pps.entropyCodingModeFlag} t8x8=${pps.transform8x8ModeFlag}",
        );
        if (pps.entropyCodingModeFlag) {
          append("MP4 not supported: CABAC stream (need CAVLC/Baseline)");
          return;
        }
      } else {
        append("MP4 WARN: no PPS in avcC");
      }

      final out = <TimestampedAccessUnit>[];
      bool sentParamSets = false;
      int idrSamples = 0;

      for (int i = 0; i < track.sampleSizes.length; i++) {
        final sampleNals = Mp4Demux.readSampleNalUnits(bytes, track, i);

        bool hasIdr = false;
        for (final n in sampleNals) {
          final nalType = n.isEmpty ? 0 : (n[0] & 0x1F);
          if (nalType == 5) {
            hasIdr = true;
            idrSamples++;
            break;
          }
        }

        final nals = <Uint8List>[];
        if (!sentParamSets || hasIdr) {
          nals.addAll(track.avc.sps);
          nals.addAll(track.avc.pps);
          sentParamSets = true;
        }
        nals.addAll(sampleNals);

        final pts = track.pts[i];
        final ptsMs = (pts * 1000 ~/ track.timescale);

        out.add(
          TimestampedAccessUnit(ptsMs: ptsMs, nals: nals, hasIdr: hasIdr),
        );
      }

      append("MP4 samples with IDR: $idrSamples/${track.sampleSizes.length}");
      append("MP4 Queue: ${out.length} AUs (full I/P decode order)");
      if (out.isEmpty) {
        append("MP4 has no playable access units.");
        return;
      }

      final firstIdr = out.indexWhere((au) => au.hasIdr);
      if (firstIdr < 0) {
        append('MP4 has no random-access picture.');
        return;
      }
      if (firstIdr > 0) {
        append('Dropped $firstIdr leading dependent samples.');
      }

      // MP4 samples are already in decode order. Reordering them by timestamp
      // would break reference state for streams whose PTS differs from DTS.
      _installQueue(out.sublist(firstIdr));

      Mp4AudioTrack? audioTrack;
      try {
        audioTrack = Mp4Demux.parseAacTrack(bytes);
      } catch (error) {
        // Audio is optional. A malformed/unsupported audio sample entry must
        // not discard an otherwise valid H.264 queue.
        audioInfo = 'Audio unavailable: $error';
        append(audioInfo);
      }
      final playableAudioTrack = audioTrack;
      if (playableAudioTrack != null) {
        append(
          'MP4 audio: AAC-LC ${playableAudioTrack.sampleRate} Hz, '
          '${playableAudioTrack.channelCount} channel(s), '
          '${playableAudioTrack.sampleSizes.length} access units',
        );
        append('Decoding AAC entirely in Dart…');
        try {
          final timeline = await decodeMp4AacToPcmInBackground(
            bytes,
            playableAudioTrack,
          );
          await _installAudioTimeline(timeline);
          append(
            'Audio ready: ${timeline.frameCount} PCM frames, '
            '${_fmtMs(timeline.durationUs ~/ 1000)}',
          );
        } catch (error) {
          audioInfo = 'Audio unavailable: $error';
          append(audioInfo);
        }
      } else {
        audioInfo = 'Audio: this MP4 has no AAC track';
      }

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
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> play() => _serializeTransport(_play);

  Future<void> _play() async {
    if (queue.isEmpty) return;
    final audio = _audioController;
    if (_decodePump.nextIndex >= queue.length) {
      _resetDecodePosition(0, message: 'Replaying from start…');
      if (audio != null) {
        await audio.seekToMediaTimeUs(queue.first.ptsMs * 1000);
      }
    }
    final startMs = _decodePump.nextIndex == 0
        ? queue.first.ptsMs
        : clock.nowMs;
    if (audio != null && _audioCovers(audio, startMs)) {
      final driftMs = (audio.currentMediaTimeMs - startMs).abs();
      if (driftMs > 50) {
        await audio.seekToMediaTimeUs(startMs * 1000);
      }
      await audio.play();
      clock.play(
        fromMs: audio.currentMediaTimeMs,
        timeSource: () => audio.currentMediaTimeMs,
      );
    } else {
      clock.play(fromMs: startMs);
    }
  }

  Future<void> pause() => _serializeTransport(_pause);

  Future<void> _pause() async {
    final audio = _audioController;
    if (audio != null && audio.isPlaying) await audio.pause();
    clock.pause();
  }

  Future<void> nextIdr() => _serializeTransport(_nextIdr);

  Future<void> _nextIdr() async {
    if (queue.isEmpty) return;
    for (int i = _decodePump.nextIndex; i < queue.length; i++) {
      if (!queue[i].hasIdr) continue;
      await _seekToAccessUnit(i);
      return;
    }
  }

  Future<void> prevIdr() => _serializeTransport(_prevIdr);

  Future<void> _prevIdr() async {
    if (queue.isEmpty) return;
    final curMs = clock.nowMs;
    int start = _decodePump.nextIndex - 2;
    if (start < 0) start = 0;
    if (start >= queue.length) start = queue.length - 1;

    for (int i = start; i >= 0; i--) {
      if (queue[i].hasIdr && queue[i].ptsMs < curMs) {
        await _seekToAccessUnit(i);
        return;
      }
    }
  }

  void _resetDecodePosition(int index, {required String message}) {
    clock.pause();
    decoder.reset();
    _decodePump.seekToIndex(index);
    setState(() {
      current = null;
      decodeInfo = message;
      _currentRgba = null;
      _frameWidth = 0;
      _frameHeight = 0;
    });
  }

  Future<void> _seekToAccessUnit(int index) async {
    final audio = _audioController;
    final resumeAfterSeek = clock.isPlaying || (audio?.isPlaying ?? false);
    if (audio != null && audio.isPlaying) await audio.pause();
    final decodeStart = _nearestPrecedingIdr(index);
    final targetMs = queue[index].ptsMs;
    _resetDecodePosition(
      decodeStart,
      message: 'Seeking to ${_fmtMs(targetMs)}…',
    );
    // Decode dependencies from the keyframe through the requested AU. The
    // serial pump presents only the latest completed frame.
    if (audio != null) await audio.seekToMediaTimeUs(targetMs * 1000);
    clock.setTime(targetMs);
    if (resumeAfterSeek) {
      if (audio != null && _audioCovers(audio, targetMs)) {
        await audio.play();
        clock.play(
          fromMs: audio.currentMediaTimeMs,
          timeSource: () => audio.currentMediaTimeMs,
        );
      } else {
        clock.play(fromMs: targetMs);
      }
    }
  }

  bool _audioCovers(AudioPlaybackController audio, int mediaTimeMs) {
    final timeline = audio.timeline;
    if (timeline == null || !audio.hasAudio) return false;
    final mediaTimeUs = mediaTimeMs * Duration.microsecondsPerMillisecond;
    return mediaTimeUs >= timeline.basePtsUs && mediaTimeUs < timeline.endPtsUs;
  }

  int _nearestPrecedingIdr(int index) {
    for (int i = index; i >= 0; i--) {
      if (queue[i].hasIdr) return i;
    }
    return 0;
  }

  Future<void> seekToStart() => _serializeTransport(_seekToStart);

  Future<void> _seekToStart() async {
    if (queue.isEmpty) return;
    final audio = _audioController;
    if (audio != null && audio.isPlaying) await audio.pause();
    _resetDecodePosition(0, message: 'At start');
    if (audio != null) {
      await audio.seekToMediaTimeUs(queue.first.ptsMs * 1000);
    }
    clock.setTime(queue.first.ptsMs);
  }

  @override
  Widget build(BuildContext context) {
    final input = urlCtrl.text.trim();
    final inputPath = (Uri.tryParse(input)?.path ?? input).toLowerCase();
    final isMp4 = inputPath.endsWith('.mp4');

    return Scaffold(
      appBar: AppBar(title: const Text('Pure Dart Playback')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: urlCtrl,
                onChanged: (_) => setState(() {}),
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
                    key: const Key('build-hls'),
                    onPressed: loading || isMp4 ? null : buildQueue,
                    child: Text(loading ? 'Building…' : 'Build Queue (HLS/TS)'),
                  ),
                  FilledButton(
                    key: const Key('build-mp4'),
                    onPressed: loading || !isMp4
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
                  FilledButton.tonal(
                    onPressed: prevIdr,
                    child: const Text('Prev IDR'),
                  ),
                  FilledButton.tonal(
                    onPressed: nextIdr,
                    child: const Text('Next IDR'),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text(
                      'Decode: sequential I/P',
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
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
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      audioInfo,
                      style: const TextStyle(fontFamily: 'monospace'),
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
