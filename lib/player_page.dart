import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:ndvy_player/pure_frame_view.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

import 'src/audio/audio_decode_pipeline.dart';
import 'src/audio/audio_playback_controller.dart';
import 'src/audio/pcm_sink.dart';
import 'src/audio/pcm_source.dart';
import 'src/audio/streaming_aac_decoder.dart';
import 'src/hls.dart';
import 'src/hls_quality.dart';
import 'src/ts_packets.dart';
import 'src/ts_psi.dart';
import 'src/ts_pes.dart';
import 'src/pes_pts.dart';
import 'src/access_unit_pts.dart';
import 'src/player_clock.dart';
import 'src/decoder/h264_decode_worker.dart';
import 'src/decoder/android_h264_texture_decoder.dart';
import 'src/decoder/pps.dart';
import 'src/decoder/slice_header.dart';
import 'src/decoder/sps.dart';
import 'src/decoder/bitreader.dart';
import 'src/decoder/exp_golomb.dart';
import 'src/decoder/rbsp.dart';
import 'src/h264_nal.dart';
import 'src/hls_http_data_source.dart';
import 'src/hls_live_playlist.dart';
import 'src/hls_live_session.dart';
import 'src/hls_vod_session.dart';
import 'src/render/yuv_rgba_worker.dart';
import 'src/ts_h264_demux.dart';

class _VariantProbeResult {
  final bool ok;
  final String reason;
  const _VariantProbeResult(this.ok, this.reason);
}

final class _StaleQueueBuild implements Exception {
  const _StaleQueueBuild();
}

final class _DetachedHlsResources {
  const _DetachedHlsResources({
    required this.session,
    required this.liveSession,
    required this.streamingDecoder,
    required this.streamingSourceWasInstalled,
    required this.dataSource,
    required this.client,
  });

  final HlsVodRollingSession? session;
  final HlsLiveRollingSession? liveSession;
  final StreamingAacPcmDecoder? streamingDecoder;
  final bool streamingSourceWasInstalled;
  final HlsHttpDataSource? dataSource;
  final http.Client? client;
}

final class _PresentedVideoFrame {
  const _PresentedVideoFrame.software({
    required this.accessUnit,
    required this.rgba,
    required this.width,
    required this.height,
    required this.decodeInfo,
  }) : textureId = null;

  const _PresentedVideoFrame.hardware({
    required this.accessUnit,
    required this.textureId,
    required this.width,
    required this.height,
    required this.decodeInfo,
  }) : rgba = null;

  final TimestampedAccessUnit accessUnit;
  final Uint8List? rgba;
  final int? textureId;
  final int width;
  final int height;
  final String decodeInfo;
}

sealed class _VideoDecodeResult {
  const _VideoDecodeResult();
}

final class _SoftwareVideoDecodeResult extends _VideoDecodeResult {
  const _SoftwareVideoDecodeResult(this.decoded);

  final H264WorkerDecodeResult decoded;
}

final class _HardwareVideoDecodeResult extends _VideoDecodeResult {
  const _HardwareVideoDecodeResult(this.receipt);

  final AndroidH264QueueReceipt receipt;
}

final class _HardwareFallbackPending implements Exception {
  const _HardwareFallbackPending(this.cause);

  final Object cause;
}

bool _shouldRetryHlsSegment(Object error) {
  if (error is HlsHttpResponseTooLargeException ||
      error is HlsHttpCancelledException ||
      error is HlsHttpDisposedException) {
    return false;
  }
  if (error is HlsHttpStatusException) {
    return error.statusCode == 408 ||
        error.statusCode == 429 ||
        error.statusCode >= 500;
  }
  return true;
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
    // text: 'assets/sample.mp4',
    // text: 'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
    // text: 'https://filesamples.com/samples/video/mp4/sample_640x360.mp4',

    // --- HLS (use "Build Queue (HLS/TS)" button) ---
    text: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    // text: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    // text:'https://sfux-ext.sfux.info/hls/chapter/105/1588724110/1588724110.m3u8',
  );

  bool loading = false;
  String log = '';

  final clock = PlayerClock();
  // Fixed MP4 queues remain fully resident. Rolling HLS uses only the bounded
  // retained window owned by [_decodePump], so this list never grows with a
  // long VOD.
  List<TimestampedAccessUnit> queue = [];
  TimestampedAccessUnit? current;

  final decoder = H264DecodeWorker();
  final AndroidH264TextureDecoder? hardwareDecoder = io.Platform.isAndroid
      ? AndroidH264TextureDecoder()
      : null;
  final frameRenderer = YuvRgbaRenderWorker();
  late SequentialDecodePump<TimestampedAccessUnit, _VideoDecodeResult>
  _decodePump;
  bool _hasDecodePump = false;
  bool _hardwareVideoSupported = false;
  bool _hardwareVideoActive = false;
  AndroidH264Capabilities? _hardwareVideoCapabilities;
  bool _hardwareFallbackPending = false;
  Object? _hardwareFallbackCause;
  StreamSubscription<AndroidH264RenderedFrame>? _hardwareFrames;
  StreamSubscription<Object>? _hardwareErrors;
  final SplayTreeMap<int, TimestampedAccessUnit> _hardwareQueuedFrames =
      SplayTreeMap<int, TimestampedAccessUnit>();
  String _hardwareDecoderName = 'MediaCodec';
  final Stopwatch _abrHealthClock = Stopwatch()..start();
  int _lastAbrHealthSampleMs = -1000;
  String decodeInfo = '';
  String audioInfo = 'Audio: none';

  AudioPlaybackController? _audioController;
  StreamSubscription<AudioPlaybackEvent>? _audioEvents;
  Future<void> _transportTail = Future<void>.value();
  int _queueBuildEpoch = 0;
  HlsHttpDataSource? _activeHlsDataSource;
  http.Client? _activeHlsClient;
  HlsVodRollingSession? _activeHlsSession;
  HlsLiveRollingSession? _activeLiveHlsSession;
  StreamingAacPcmDecoder? _activeStreamingAudioDecoder;
  bool _streamingAudioSourceInstalled = false;
  bool _rollingHls = false;
  bool _liveHls = false;
  bool _rollingReady = false;
  bool _rollingSealed = false;
  bool _rollingFailed = false;
  bool _rollingAudioClockLocked = false;
  bool _resumeVideoOnlyAfterStarvation = false;
  int _rollingVideoAccessUnits = 0;
  int? _rollingLastIdrAccessUnitIndex;
  Completer<void>? _videoAppendCapacityWaiter;

  static const String _autoQualityId = 'auto';
  String _qualitySelectionId = _autoQualityId;
  Uri? _qualityMasterUri;
  List<HlsVariant> _qualityVariants = const <HlsVariant>[];
  HlsQualityController? _qualityController;
  HlsQualityRendition? _activeQualityRendition;
  HlsQualityRendition? _displayedQualityRendition;
  final SplayTreeMap<int, HlsQualityRendition> _qualityTimeline =
      SplayTreeMap<int, HlsQualityRendition>();
  String _qualityInfo = 'Quality: Auto';

  static const int _rollingMaxResidentAccessUnits = 1200;
  static const int _rollingRetainedConsumedAccessUnits = 90;
  static const int _lateNonReferenceBSkipThresholdMs = 100;
  static const int _highResolutionBSkipThresholdMs = 0;
  static const int _highResolutionPixelThreshold = 1280 * 720;
  static const int _hardwareDecodeLeadMs = 500;
  static const Duration _livePcmRetentionDuration = Duration(minutes: 5);
  static const int _livePcmMaxBytes = 64 * 1024 * 1024;

  final ValueNotifier<_PresentedVideoFrame?> _presentedVideo = ValueNotifier(
    null,
  );

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
    final hardware = hardwareDecoder;
    if (hardware != null) {
      _hardwareFrames = hardware.renderedFrames.listen(
        _handleHardwareFrameRendered,
      );
      _hardwareErrors = hardware.errors.listen(_handleHardwareDecoderError);
      unawaited(_probeHardwareVideo(hardware));
    }
    _configureDecodePump(rolling: false);
  }

  Future<void> _probeHardwareVideo(AndroidH264TextureDecoder hardware) async {
    try {
      final capabilities = await hardware.capabilities();
      if (!mounted) return;
      _hardwareVideoCapabilities = capabilities;
      _hardwareVideoSupported = capabilities.supported;
      if (capabilities.supported) {
        append(
          'Android H.264 decoder ${capabilities.decoderName}: '
          '${capabilities.maximumWidth}x${capabilities.maximumHeight} @ '
          '${capabilities.maximumFrameRate.toStringAsFixed(0)} fps '
          '(${capabilities.hardwareAccelerated ? "hardware" : "software"})',
        );
      }
    } catch (error) {
      if (mounted) append('Hardware H.264 probe failed; using Dart: $error');
    }
  }

  void _configureDecodePump({required bool rolling}) {
    if (_hasDecodePump) _decodePump.dispose();
    _decodePump =
        SequentialDecodePump<TimestampedAccessUnit, _VideoDecodeResult>(
          timestampOf: (au) => au.ptsMs,
          decode: _decodeVideoAccessUnit,
          onLatestDecoded: _presentDecodedFrame,
          onDecodeError: _handleDecodeError,
          onQueueDrained: _handleQueueDrained,
          onQueueStateChanged: _handleDecodeQueueState,
          onAppendCapacityAvailable: _handleVideoAppendCapacity,
          maxResidentItems: rolling ? _rollingMaxResidentAccessUnits : null,
          retainedConsumedItems: rolling
              ? _rollingRetainedConsumedAccessUnits
              : 0,
          isDependencyBoundary: rolling ? (au) => au.hasIdr : null,
          presentationMayBeReordered: true,
          shouldSkipDecode: (au, requestedThroughMs) {
            if (_hardwareVideoActive) return false;
            final resolution = _qualityRenditionDimensions(
              _qualityRenditionAt(au.ptsMs),
            );
            return shouldSkipH264AccessUnitForSmoothPlayback(
              nals: au.nals,
              latenessMs: requestedThroughMs - au.ptsMs,
              highResolution:
                  resolution != null &&
                  resolution.width * resolution.height >=
                      _highResolutionPixelThreshold,
              normalLateThresholdMs: _lateNonReferenceBSkipThresholdMs,
              highResolutionLateThresholdMs: _highResolutionBSkipThresholdMs,
            );
          },
        );
    _hasDecodePump = true;
    clock.onFrameDue = _requestVideoThrough;
    clock.onPlaybackStateChanged = _syncHardwareClock;
  }

  void _requestVideoThrough(int nowMs) {
    final lead = _hardwareVideoActive && clock.isPlaying
        ? _hardwareDecodeLeadMs
        : 0;
    _decodePump.requestThrough(nowMs + lead);
    _sampleAbrBufferHealth();
  }

  void _syncHardwareClock(int nowMs, bool playing) {
    final hardware = hardwareDecoder;
    if (!_hardwareVideoActive || hardware == null) return;
    unawaited(
      hardware
          .updateClock(mediaTimeUs: nowMs * 1000, playing: playing)
          .catchError((Object error, StackTrace stackTrace) {
            _handleHardwareDecoderError(error);
          }),
    );
  }

  Future<_VideoDecodeResult> _decodeVideoAccessUnit(
    TimestampedAccessUnit accessUnit,
  ) async {
    if (_hardwareFallbackPending) {
      throw _HardwareFallbackPending(
        _hardwareFallbackCause ?? 'MediaCodec failed',
      );
    }
    final hardware = hardwareDecoder;
    if (_hardwareVideoActive && hardware != null) {
      try {
        final receipt = await hardware.queueAccessUnit(
          nals: accessUnit.nals,
          presentationTimeUs: accessUnit.ptsMs * 1000,
          clockMediaTimeUs: clock.nowMs * 1000,
          playing: clock.isPlaying,
        );
        _hardwareDecoderName = receipt.decoderName;
        _hardwareQueuedFrames[accessUnit.ptsMs] = accessUnit;
        return _HardwareVideoDecodeResult(receipt);
      } catch (error) {
        // A first-IDR configure failure can safely retry through the Dart
        // decoder. A later dependent picture cannot switch decoder state
        // mid-GOP, so it is reported and recovered by the normal IDR rebuild.
        if (accessUnit.hasIdr) {
          _hardwareVideoSupported = false;
          _hardwareVideoActive = false;
          decoder.reset();
          if (mounted) append('MediaCodec unavailable; using Dart: $error');
        } else {
          _handleHardwareDecoderError(error);
          throw _HardwareFallbackPending(error);
        }
      }
    }
    return _SoftwareVideoDecodeResult(
      await decoder.decodeAccessUnitOrThrow(accessUnit.nals),
    );
  }

  void _handleDecodeQueueState(SequentialDecodeQueueState state) {
    if (!mounted || !_rollingHls || _rollingFailed) return;
    switch (state) {
      case SequentialDecodeQueueState.starved:
        _sampleAbrBufferHealth(starved: true, force: true);
        if (!_rollingAudioClockLocked && clock.isPlaying) {
          _resumeVideoOnlyAfterStarvation = true;
          clock.pause();
        }
        setState(() => decodeInfo = 'Buffering video…');
        break;
      case SequentialDecodeQueueState.ready:
        if (_resumeVideoOnlyAfterStarvation && !_rollingAudioClockLocked) {
          _resumeVideoOnlyAfterStarvation = false;
          clock.play(fromMs: clock.nowMs);
        }
        if (_rollingReady) {
          setState(() {
            decodeInfo =
                'Streaming — ${_decodePump.residentLength} buffered access units';
          });
        }
        break;
      case SequentialDecodeQueueState.ended:
        _resumeVideoOnlyAfterStarvation = false;
        break;
      case SequentialDecodeQueueState.disposed:
        break;
    }
  }

  void _handleVideoAppendCapacity(int _) {
    final waiter = _videoAppendCapacityWaiter;
    _videoAppendCapacityWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<void> _appendRollingVideoBatch(
    List<TimestampedAccessUnit> accessUnits,
    int epoch,
  ) async {
    if (accessUnits.isEmpty) return;

    final availableBeforeReady = _decodePump.remainingItemCapacity;
    if (!_rollingReady &&
        availableBeforeReady != null &&
        accessUnits.length > availableBeforeReady) {
      throw SequentialDecodeQueueCapacityException(
        requestedItems: accessUnits.length,
        availableItems: availableBeforeReady,
        maximumItems: _rollingMaxResidentAccessUnits,
      );
    }

    // Validate the complete batch before retaining any prefix. This reserves
    // room for the next IDR and converts an overlong GOP into a clear terminal
    // error instead of filling the queue while its retained IDR prevents
    // compaction forever.
    final validatedLastIdr = validateSequentialDecodeDependencyWindow(
      items: accessUnits,
      startIndex: _rollingVideoAccessUnits,
      previousBoundaryIndex: _rollingLastIdrAccessUnitIndex,
      maximumItems: _rollingMaxResidentAccessUnits,
      isDependencyBoundary: (au) => au.hasIdr,
    );

    var offset = 0;
    while (offset < accessUnits.length) {
      _ensureBuildCurrent(epoch);
      if (!_rollingHls || _decodePump.isQueueFinal) {
        throw const _StaleQueueBuild();
      }

      final available = _decodePump.remainingItemCapacity;
      if (available != null && available == 0) {
        final waiter = Completer<void>();
        _videoAppendCapacityWaiter = waiter;
        // Decode completion can free and announce capacity around this handoff.
        // Recheck after publishing the waiter so no producer wake-up is lost.
        if ((_decodePump.remainingItemCapacity ?? 0) > 0) {
          if (identical(_videoAppendCapacityWaiter, waiter)) {
            _videoAppendCapacityWaiter = null;
          }
          continue;
        }
        await waiter.future;
        if (identical(_videoAppendCapacityWaiter, waiter)) {
          _videoAppendCapacityWaiter = null;
        }
        continue;
      }

      final count = math.min(
        accessUnits.length - offset,
        available ?? accessUnits.length,
      );
      _decodePump.appendItems(accessUnits.sublist(offset, offset + count));
      _rollingVideoAccessUnits += count;
      offset += count;
    }
    _rollingLastIdrAccessUnitIndex = validatedLastIdr;
  }

  void _prepareRollingPlayback({required bool live}) {
    clock.pause();
    _resetDecodeAndRender();
    _configureDecodePump(rolling: true);
    _decodePump.replaceQueue(const <TimestampedAccessUnit>[], isFinal: false);
    queue = const <TimestampedAccessUnit>[];
    _rollingHls = true;
    _liveHls = live;
    _rollingReady = false;
    _rollingSealed = false;
    _rollingFailed = false;
    _rollingAudioClockLocked = false;
    _resumeVideoOnlyAfterStarvation = false;
    _rollingVideoAccessUnits = 0;
    _rollingLastIdrAccessUnitIndex = null;
    _displayedQualityRendition = null;
    _qualityTimeline.clear();
  }

  void _presentDecodedFrame(
    TimestampedAccessUnit au,
    _VideoDecodeResult result,
  ) {
    if (result case _HardwareVideoDecodeResult(:final receipt)) {
      _hardwareDecoderName = receipt.decoderName;
      return;
    }
    final decoded = (result as _SoftwareVideoDecodeResult).decoded;
    final frame = decoded.frame;
    final stats = decoded.stats;
    if (!mounted) return;
    final rendition = _qualityRenditionAt(au.ptsMs);
    if (rendition != null &&
        !identical(_displayedQualityRendition, rendition)) {
      _displayedQualityRendition = rendition;
      _refreshQualityInfo();
      append('Quality now visible: ${rendition.label}');
    }
    final renderSize = _qualityRenderSize(frame.width, frame.height, rendition);
    _observeAutoQuality(
      starved: false,
      latenessMs: math.max(0, clock.nowMs - au.ptsMs),
    );
    final frameDecodeInfo =
        'Decoded ${stats.sliceType.name.toUpperCase()}: '
        '${frame.width}x${frame.height}'
        '${renderSize.width == frame.width && renderSize.height == frame.height ? "" : " → display ${renderSize.width}x${renderSize.height}"}'
        '${_decodePump.skippedDecodeCount == 0 ? "" : " • "
                  "dropped ${_decodePump.skippedDecodeCount} disposable B"}';
    frameRenderer.submit(
      frame,
      outputWidth: renderSize.width,
      outputHeight: renderSize.height,
      onFrame: (rgba) {
        if (!mounted) return;
        current = au;
        final coalesced = frameRenderer.coalescedFrameCount;
        decodeInfo =
            '$frameDecodeInfo'
            '${coalesced == 0 ? "" : " • render-coalesced $coalesced"}';
        _presentedVideo.value = _PresentedVideoFrame.software(
          accessUnit: au,
          rgba: rgba,
          width: renderSize.width,
          height: renderSize.height,
          decodeInfo: decodeInfo,
        );
      },
      onError: (error, stackTrace) {
        debugPrint('YUV render worker error: $error\n$stackTrace');
        if (mounted) {
          setState(() => decodeInfo = 'Frame render failed: $error');
        }
      },
    );
  }

  void _handleHardwareFrameRendered(AndroidH264RenderedFrame frame) {
    if (!mounted || !_hardwareVideoActive) return;
    final ptsMs =
        frame.presentationTimeUs ~/ Duration.microsecondsPerMillisecond;
    final accessUnit = _hardwareQueuedFrames[ptsMs];
    if (accessUnit == null) return;
    final stale = <int>[
      for (final queuedPts in _hardwareQueuedFrames.keys)
        if (queuedPts <= ptsMs) queuedPts,
    ];
    for (final queuedPts in stale) {
      _hardwareQueuedFrames.remove(queuedPts);
    }

    final textureId = hardwareDecoder?.textureId;
    if (textureId == null) return;
    final rendition = _qualityRenditionAt(ptsMs);
    if (rendition != null &&
        !identical(_displayedQualityRendition, rendition)) {
      _displayedQualityRendition = rendition;
      _refreshQualityInfo();
      append('Quality now visible: ${rendition.label}');
    }
    _observeAutoQuality(
      starved: false,
      latenessMs: math.max(0, clock.nowMs - ptsMs),
    );
    current = accessUnit;
    decodeInfo =
        'Hardware H.264 ($_hardwareDecoderName): '
        '${frame.width}x${frame.height}';
    _presentedVideo.value = _PresentedVideoFrame.hardware(
      accessUnit: accessUnit,
      textureId: textureId,
      width: frame.width,
      height: frame.height,
      decodeInfo: decodeInfo,
    );
  }

  void _handleHardwareDecoderError(Object error) {
    if (!mounted || !_hardwareVideoActive) return;
    final resumeAfterRecovery =
        clock.isPlaying || (_audioController?.isPlaying ?? false);
    _hardwareVideoSupported = false;
    _hardwareVideoActive = false;
    _hardwareFallbackPending = true;
    _hardwareFallbackCause = error;
    setState(() {
      decodeInfo = 'Hardware decoder failed; switching to Dart…';
    });
    unawaited(
      _serializeTransport(
        () => _recoverWithSoftwareDecoder(
          error,
          resumeAfterRecovery: resumeAfterRecovery,
        ),
      ),
    );
  }

  Future<void> _recoverWithSoftwareDecoder(
    Object error, {
    required bool resumeAfterRecovery,
  }) async {
    final targetMs = clock.nowMs;
    clock.pause();
    final audio = _audioController;
    if (audio != null && audio.isPlaying) await audio.pause();

    final targetIndex = _latestAccessUnitAtOrBefore(targetMs);
    _hardwareFallbackPending = false;
    _hardwareFallbackCause = null;
    if (targetIndex == null ||
        !await _seekToAccessUnit(
          targetIndex,
          resumeAfterSeekOverride: resumeAfterRecovery,
        )) {
      if (mounted) {
        setState(() {
          decodeInfo = 'Hardware decoder failed: $error. Rebuild to retry.';
        });
      }
      return;
    }
    if (mounted) {
      append('MediaCodec failed; resumed with the Pure Dart decoder: $error');
    }
  }

  int? _latestAccessUnitAtOrBefore(int targetMs) {
    int? selectedIndex;
    int? selectedPts;
    for (
      var index = _decodePump.firstRetainedIndex;
      index < _decodePump.endIndex;
      index++
    ) {
      final pts = _decodePump.itemAt(index).ptsMs;
      if (pts <= targetMs && (selectedPts == null || pts >= selectedPts)) {
        selectedIndex = index;
        selectedPts = pts;
      }
    }
    return selectedIndex ?? _firstRetainedIdrIndex();
  }

  ({int width, int height}) _qualityRenderSize(
    int sourceWidth,
    int sourceHeight,
    HlsQualityRendition? rendition,
  ) {
    var targetWidth = sourceWidth;
    var targetHeight = sourceHeight;
    final resolution = rendition?.variant.resolution;
    if (resolution != null) {
      final separator = resolution.toLowerCase().indexOf('x');
      if (separator > 0 && separator < resolution.length - 1) {
        final advertisedWidth = int.tryParse(
          resolution.substring(0, separator),
        );
        final advertisedHeight = int.tryParse(
          resolution.substring(separator + 1),
        );
        if (advertisedWidth != null &&
            advertisedHeight != null &&
            advertisedWidth > 0 &&
            advertisedHeight > 0 &&
            advertisedWidth < targetWidth &&
            advertisedHeight < targetHeight) {
          targetWidth = advertisedWidth;
          targetHeight = advertisedHeight;
        }
      }
    }

    // Decode retains the selected source quality, but uploading more RGBA
    // pixels than the physical viewport can display only burns CPU/native
    // texture memory. Keep dimensions even for YUV420 and preserve the source
    // aspect ratio when capping high-quality presentation frames.
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery != null) {
      final viewportPixels =
          (mediaQuery.size.width * mediaQuery.devicePixelRatio).floor() & ~1;
      if (viewportPixels >= 2 && viewportPixels < targetWidth) {
        targetWidth = viewportPixels;
        targetHeight = ((sourceHeight * targetWidth / sourceWidth).round() & ~1)
            .clamp(2, sourceHeight);
      }
    }
    return (width: targetWidth, height: targetHeight);
  }

  HlsQualityRendition? _qualityRenditionAt(int ptsMs) {
    final key = _qualityTimeline.lastKeyBefore(ptsMs + 1);
    return key == null
        ? _displayedQualityRendition ?? _activeQualityRendition
        : _qualityTimeline[key];
  }

  ({int width, int height})? _qualityRenditionDimensions(
    HlsQualityRendition? rendition,
  ) {
    final resolution = rendition?.variant.resolution;
    if (resolution == null) return null;
    final separator = resolution.toLowerCase().indexOf('x');
    if (separator <= 0 || separator >= resolution.length - 1) return null;
    final width = int.tryParse(resolution.substring(0, separator));
    final height = int.tryParse(resolution.substring(separator + 1));
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width: width, height: height);
  }

  void _recordQualityBoundary(
    List<TimestampedAccessUnit> accessUnits,
    HlsQualityRendition? rendition,
  ) {
    if (accessUnits.isEmpty || rendition == null) return;
    final previous = _qualityTimeline.isEmpty
        ? null
        : _qualityTimeline.values.last;
    if (!identical(previous, rendition)) {
      _qualityTimeline[accessUnits.first.ptsMs] = rendition;
    }
  }

  void _resetDecodeAndRender() {
    decoder.reset();
    _hardwareQueuedFrames.clear();
    final hardware = hardwareDecoder;
    if (hardware != null) {
      unawaited(
        hardware.reset().catchError((Object error, StackTrace stackTrace) {
          if (mounted) append('Hardware decoder reset failed: $error');
        }),
      );
    }
    frameRenderer.reset();
  }

  void _observeAutoQuality({required bool starved, required int latenessMs}) {
    final controller = _qualityController;
    if (controller == null) return;
    final change = controller.observePlayback(
      latenessMs: latenessMs,
      starved: starved,
    );
    if (change != null) _handleQualityDecision(change);
  }

  void _sampleAbrBufferHealth({bool starved = false, bool force = false}) {
    final controller = _qualityController;
    if (controller == null) return;
    final sampleMs = _abrHealthClock.elapsedMilliseconds;
    if (!force && sampleMs - _lastAbrHealthSampleMs < 500) return;
    _lastAbrHealthSampleMs = sampleMs;

    final videoBufferedMs = _videoBufferedAheadMs();
    final audio = _audioController;
    final source = audio?.source;
    int? audioBufferedMs;
    if (audio != null && source != null && audio.hasAudio) {
      final endUs = audio.seekableEndMediaTimeUs ?? source.endPtsUs;
      final currentUs =
          audio.currentMediaTimeMs * Duration.microsecondsPerMillisecond;
      audioBufferedMs = math.max(
        0,
        (endUs - currentUs) ~/ Duration.microsecondsPerMillisecond,
      );
    }
    final change = controller.observeBuffer(
      videoBufferedMs: videoBufferedMs,
      audioBufferedMs: audioBufferedMs,
      playing: clock.isPlaying || (audio?.isPlaying ?? false),
      starved: starved,
    );
    if (change != null) _handleQualityDecision(change);
  }

  int _videoBufferedAheadMs() {
    final nowMs = clock.nowMs;
    var furthestPtsMs = nowMs;
    for (
      var index = math.max(
        _decodePump.nextIndex,
        _decodePump.firstRetainedIndex,
      );
      index < _decodePump.endIndex;
      index++
    ) {
      furthestPtsMs = math.max(furthestPtsMs, _decodePump.itemAt(index).ptsMs);
    }
    if (_hardwareQueuedFrames.isNotEmpty) {
      furthestPtsMs = math.max(furthestPtsMs, _hardwareQueuedFrames.lastKey()!);
    }
    return math.max(0, furthestPtsMs - nowMs);
  }

  int get _maximumAutomaticQualityPixels {
    final capabilities = _hardwareVideoCapabilities;
    if (!_hardwareVideoActive || capabilities == null) return 848 * 480;
    final designLimit = capabilities.hardwareAccelerated
        ? 1920 * 1080
        : 1280 * 720;
    final codecLimit = capabilities.maximumPixels;
    return codecLimit <= 0 ? designLimit : math.min(codecLimit, designLimit);
  }

  int? get _maximumAutomaticQualityBandwidth {
    final capabilities = _hardwareVideoCapabilities;
    if (!_hardwareVideoActive || capabilities == null) return null;
    return capabilities.maximumBitrate > 0 ? capabilities.maximumBitrate : null;
  }

  void _handleQualityDecision(HlsQualityChange change) {
    if (!mounted) return;
    _refreshQualityInfo();
    append(
      'Quality target ${change.previous.label} -> ${change.current.label}: '
      '${change.reason}',
    );
  }

  void _handleActiveQuality(HlsQualityRendition rendition) {
    if (!mounted || identical(_activeQualityRendition, rendition)) return;
    final previous = _activeQualityRendition;
    _activeQualityRendition = rendition;
    _refreshQualityInfo();
    append(
      previous == null
          ? 'Quality buffered: ${rendition.label}'
          : 'Quality buffered at IDR: '
                '${previous.label} -> ${rendition.label}',
    );
  }

  void _refreshQualityInfo() {
    if (!mounted) return;
    final controller = _qualityController;
    final visible = _displayedQualityRendition ?? _activeQualityRendition;
    setState(() {
      if (controller == null) {
        _qualityInfo = _qualitySelectionId == _autoQualityId
            ? 'Quality: Auto'
            : 'Quality: selected for next build';
        return;
      }
      final mode = controller.mode == HlsQualityMode.automatic
          ? 'Auto'
          : 'Manual';
      final target = controller.selected;
      final estimate = controller.estimatedBitsPerSecond;
      final health = controller.bufferAheadMs;
      final telemetry =
          '${estimate == null ? "" : " · net ${(estimate / 1000000).toStringAsFixed(1)} Mbps"}'
          '${health == null ? "" : " · buffer ${(health / 1000).toStringAsFixed(1)}s"}';
      _qualityInfo = visible == null || identical(visible, target)
          ? 'Quality: $mode · ${target.label}'
                '$telemetry'
          : 'Quality: $mode · ${visible.label} → pending ${target.label}'
                '$telemetry';
    });
  }

  void _selectQuality(String? selectionId) {
    if (selectionId == null || selectionId == _qualitySelectionId) return;
    setState(() => _qualitySelectionId = selectionId);
    final controller = _qualityController;
    if (controller == null) {
      _refreshQualityInfo();
      return;
    }
    final change = selectionId == _autoQualityId
        ? controller.selectAutomatic()
        : controller.selectManual(Uri.parse(selectionId));
    if (change != null) {
      _handleQualityDecision(change);
    } else {
      _refreshQualityInfo();
    }
    if (_rollingHls && !_liveHls && !_rollingFailed) {
      append(
        'Quality switch queued for the next decoder-safe TS boundary; '
        'playback continues.',
      );
    }
  }

  void _handleUrlChanged(String value) {
    final uri = Uri.tryParse(value.trim());
    if (_qualityMasterUri != null && uri != _qualityMasterUri) {
      _qualityMasterUri = null;
      _qualityVariants = const <HlsVariant>[];
      _qualityController = null;
      _activeQualityRendition = null;
      _displayedQualityRendition = null;
      _qualityTimeline.clear();
      _qualitySelectionId = _autoQualityId;
      _qualityInfo = 'Quality: Auto';
    }
    setState(() {});
  }

  bool _segmentStartsWithIdr(Uint8List bytes) {
    try {
      final demuxer = TsH264Demuxer();
      final accessUnits = <TimestampedAccessUnit>[
        ...demuxer.pushSegment(bytes),
        ...demuxer.finish(),
      ];
      return accessUnits.isNotEmpty && accessUnits.first.hasIdr;
    } catch (_) {
      return false;
    }
  }

  void _handleDecodeError(
    TimestampedAccessUnit au,
    Object error,
    StackTrace stackTrace,
  ) {
    if (error is _HardwareFallbackPending) {
      debugPrint(
        'MediaCodec failed at ${au.ptsMs}ms; Dart fallback scheduled: '
        '${error.cause}\n$stackTrace',
      );
      return;
    }
    if (_rollingHls) {
      _failRollingPlayback(
        'Decoder stopped at ${au.ptsMs}ms: $error',
        audioMessage: _rollingAudioClockLocked
            ? 'Audio stopped with the failed HLS session'
            : null,
      );
      debugPrint(
        'decodeAccessUnit error at ${au.ptsMs}ms: $error\n$stackTrace',
      );
      return;
    }
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
    _queueBuildEpoch++;
    unawaited(_cancelActiveHlsBuild());
    urlCtrl.dispose();
    _presentedVideo.dispose();
    unawaited(_hardwareFrames?.cancel());
    unawaited(_hardwareErrors?.cancel());
    clock.dispose();
    _decodePump.dispose();
    frameRenderer.dispose();
    decoder.dispose();
    final hardware = hardwareDecoder;
    if (hardware != null) unawaited(hardware.dispose());
    unawaited(_disposeAudio());
    super.dispose();
  }

  String _fmtMs(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  Future<int> _beginQueueBuild() async {
    final epoch = ++_queueBuildEpoch;
    await _cancelActiveHlsBuild();
    _ensureBuildCurrent(epoch);
    _hardwareVideoActive = _hardwareVideoSupported;
    _hardwareFallbackPending = false;
    _hardwareFallbackCause = null;
    setState(() {
      loading = true;
      log = '';
      queue = [];
      current = null;
      _qualityController = null;
      _activeQualityRendition = null;
      _qualityInfo = _qualitySelectionId == _autoQualityId
          ? 'Quality: Auto'
          : 'Quality: loading manual selection…';
      decodeInfo = 'Building playback queue…';
      audioInfo = 'Audio: probing…';
      _presentedVideo.value = null;
    });
    await _serializeTransport(() async {
      _ensureBuildCurrent(epoch);
      clock.pause();
      final audio = _audioController;
      if (audio != null && audio.isPlaying) await audio.pause();
      _ensureBuildCurrent(epoch);
      await _disposeAudio();
      _ensureBuildCurrent(epoch);
      _resetDecodeAndRender();
      _configureDecodePump(rolling: false);
    });
    _ensureBuildCurrent(epoch);
    return epoch;
  }

  Future<void> _cancelActiveHlsBuild() async {
    final resources = _detachActiveHlsResources(resetRollingState: true);
    await _disposeDetachedHlsResources(resources);
  }

  Future<void> cancelQueueBuild() async {
    if (!loading) return;

    // Invalidate every pending network, demux, decode, and audio-install
    // completion before detaching the resources that belong to this build.
    // The UI becomes usable immediately; cleanup below only owns snapshots, so
    // it cannot dispose a replacement build started while cleanup is pending.
    _queueBuildEpoch++;
    final resources = _detachActiveHlsResources(resetRollingState: true);
    final audioEvents = _audioEvents;
    final audioController = _audioController;
    _audioEvents = null;
    _audioController = null;

    clock.pause();
    _resetDecodeAndRender();
    _configureDecodePump(rolling: false);
    queue = [];
    current = null;
    _presentedVideo.value = null;

    if (mounted) {
      setState(() {
        loading = false;
        decodeInfo = 'Queue build cancelled';
        audioInfo = 'Audio: none';
      });
    }

    try {
      await _disposeDetachedHlsResources(resources);
      await audioEvents?.cancel();
      await audioController?.dispose();
    } catch (error, stackTrace) {
      debugPrint('Queue-build cancellation cleanup error: $error\n$stackTrace');
    }
  }

  _DetachedHlsResources _detachActiveHlsResources({
    required bool resetRollingState,
  }) {
    final capacityWaiter = _videoAppendCapacityWaiter;
    _videoAppendCapacityWaiter = null;
    if (capacityWaiter != null && !capacityWaiter.isCompleted) {
      capacityWaiter.complete();
    }

    final session = _activeHlsSession;
    final liveSession = _activeLiveHlsSession;
    final streamingDecoder = _activeStreamingAudioDecoder;
    final sourceWasInstalled = _streamingAudioSourceInstalled;
    final dataSource = _activeHlsDataSource;
    final client = _activeHlsClient;

    // Detach every resource synchronously before the first await. Otherwise an
    // older cancellation can resume later and dispose a newer build's client,
    // decoder, or session.
    _activeHlsSession = null;
    _activeLiveHlsSession = null;
    _activeStreamingAudioDecoder = null;
    _streamingAudioSourceInstalled = false;
    _activeHlsDataSource = null;
    _activeHlsClient = null;

    if (resetRollingState) {
      _rollingHls = false;
      _liveHls = false;
      _rollingReady = false;
      _rollingSealed = false;
      _rollingFailed = false;
      _rollingAudioClockLocked = false;
      _resumeVideoOnlyAfterStarvation = false;
      _rollingVideoAccessUnits = 0;
      _rollingLastIdrAccessUnitIndex = null;
      _displayedQualityRendition = null;
      _qualityTimeline.clear();
    }

    return _DetachedHlsResources(
      session: session,
      liveSession: liveSession,
      streamingDecoder: streamingDecoder,
      streamingSourceWasInstalled: sourceWasInstalled,
      dataSource: dataSource,
      client: client,
    );
  }

  Future<void> _disposeDetachedHlsResources(
    _DetachedHlsResources resources,
  ) async {
    try {
      await Future.wait(<Future<void>>[
        if (resources.session case final session?) session.dispose(),
        if (resources.liveSession case final session?) session.dispose(),
      ]);
    } finally {
      try {
        await resources.streamingDecoder?.dispose(
          disposeSource: !resources.streamingSourceWasInstalled,
        );
      } finally {
        resources.dataSource?.dispose();
        resources.client?.close();
      }
    }
  }

  void _failRollingPlayback(String message, {String? audioMessage}) {
    if (!_rollingHls || _rollingFailed) return;

    // Invalidate the producer before detaching it so no pending network or AAC
    // completion can commit more data after a terminal playback failure.
    _queueBuildEpoch++;
    final resources = _detachActiveHlsResources(resetRollingState: false);
    final failedAudioEvents = _audioEvents;
    final failedAudioController = _audioController;
    _audioEvents = null;
    _audioController = null;
    _rollingFailed = true;
    _resumeVideoOnlyAfterStarvation = false;
    loading = false;
    clock.pause();

    if (mounted) {
      setState(() {
        decodeInfo = message;
        if (audioMessage != null) audioInfo = audioMessage;
      });
    }

    unawaited(() async {
      try {
        await _disposeDetachedHlsResources(resources);
      } catch (error, stackTrace) {
        debugPrint('HLS failure cleanup error: $error\n$stackTrace');
      }
      try {
        try {
          await failedAudioEvents?.cancel();
        } finally {
          await failedAudioController?.dispose();
        }
      } catch (error, stackTrace) {
        debugPrint('HLS audio cleanup error: $error\n$stackTrace');
      }
    }());
  }

  void _ensureBuildCurrent(int epoch) {
    if (!mounted || epoch != _queueBuildEpoch) {
      throw const _StaleQueueBuild();
    }
  }

  void _installQueue(List<TimestampedAccessUnit> accessUnits) {
    clock.pause();
    _resetDecodeAndRender();
    queue = List<TimestampedAccessUnit>.unmodifiable(accessUnits);
    _decodePump.replaceQueue(queue);
    current = null;
    decodeInfo = queue.isEmpty
        ? 'No access units found'
        : 'Ready — ${queue.length} access units';
    _presentedVideo.value = null;
  }

  Future<Uint8List> loadAssetBytes(String path) async {
    final bd = await rootBundle.load(path);
    return bd.buffer.asUint8List();
  }

  Future<void> _installAudioSource(
    PcmAudioSource source, {
    required int buildEpoch,
  }) async {
    try {
      _ensureBuildCurrent(buildEpoch);
    } catch (_) {
      await source.dispose();
      rethrow;
    }

    AudioPlaybackController? controller;
    StreamSubscription<AudioPlaybackEvent>? events;
    var installed = false;
    try {
      final sink = await createNativePcmAudioSink();
      controller = AudioPlaybackController(sink);
      await controller.load(source);
      _ensureBuildCurrent(buildEpoch);
      final candidateController = controller;
      events = candidateController.events.listen((event) {
        // A cancelled controller can still deliver an already-scheduled event.
        // Ignore it once ownership has moved to another build.
        if (identical(_audioController, candidateController)) {
          _handleAudioEvent(event);
        }
      });

      await _serializeTransport(() async {
        _ensureBuildCurrent(buildEpoch);
        final oldEvents = _audioEvents;
        final oldController = _audioController;
        _audioEvents = null;
        _audioController = null;
        if (oldEvents != null) await oldEvents.cancel();
        if (oldController != null) await oldController.dispose();
        _ensureBuildCurrent(buildEpoch);
        _audioEvents = events;
        _audioController = candidateController;
        installed = true;
      });
      _ensureBuildCurrent(buildEpoch);
    } catch (_) {
      if (installed && identical(_audioController, controller)) {
        _audioController = null;
        _audioEvents = null;
      }
      await events?.cancel();
      if (controller != null) {
        await controller.dispose();
      } else {
        await source.dispose();
      }
      rethrow;
    }

    _ensureBuildCurrent(buildEpoch);
    setState(() {
      final duration = source is GrowingPcmAudioSource
          ? 'growing PCM stream'
          : _fmtMs(source.durationUs ~/ 1000);
      audioInfo =
          'Audio: AAC-LC ${source.sampleRate} Hz, '
          '${source.channels == 1 ? "mono" : "stereo"}, $duration';
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
        final videoComplete = _decodePump.isEnded;
        if (videoComplete) {
          clock.pause();
          setState(() {
            decodeInfo = 'Playback complete — press Play to replay';
          });
        } else if (_rollingAudioClockLocked) {
          clock.pause();
          setState(() {
            decodeInfo = 'Audio clock complete — video stopped at audio EOS';
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
        _sampleAbrBufferHealth(starved: true, force: true);
        setState(() {
          audioInfo = 'Audio underrun: ${event.message ?? "buffer starved"}';
          if (_rollingAudioClockLocked) decodeInfo = 'Buffering audio…';
        });
      case AudioPlaybackEventType.error:
        final message = event.message ?? 'unknown error';
        if (_rollingHls && _rollingAudioClockLocked) {
          _failRollingPlayback(
            'Streaming stopped because the audio output failed',
            audioMessage: 'Audio stopped: $message',
          );
          break;
        }
        clock.pause();
        setState(() {
          audioInfo = 'Audio stopped: $message';
        });
      case AudioPlaybackEventType.ready:
      case AudioPlaybackEventType.position:
        break;
    }
  }

  Future<_VariantProbeResult> _probeVariantCompatibility(
    Uri mediaUri, {
    HlsByteFetcher? byteFetcher,
  }) async {
    try {
      final media = await fetchMediaPlaylist(
        mediaUri,
        byteFetcher: byteFetcher,
        requireEndList: false,
      );
      if (media.segments.isEmpty) {
        if (!media.isEndList) {
          return const _VariantProbeResult(
            true,
            'compatible pending (live window is currently empty)',
          );
        }
        return const _VariantProbeResult(false, 'incompatible: empty media');
      }

      final ppsById = <int, PpsInfo>{};
      final spsById = <int, SpsInfo>{};
      final usedPpsIds = <int>{};
      final sliceNals = <Uint8List>[];
      int idrSliceCount = 0;
      var sawPSlice = false;
      var sawBSlice = false;

      final probeSegCount = math.min(media.segments.length, 2);
      final probeStart = media.isEndList
          ? 0
          : media.segments.length - probeSegCount;
      for (int i = probeStart; i < probeStart + probeSegCount; i++) {
        final tsBytes = await (byteFetcher ?? fetchBytes)(
          media.segments[i].uri,
        );
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
          } else if (t == 1 || t == 5) {
            sliceNals.add(nal);
            if (t == 5) idrSliceCount++;
            final syntax = _tryReadSliceProbe(nal);
            if (syntax != null) {
              usedPpsIds.add(syntax.ppsId);
              sawPSlice = sawPSlice || syntax.sliceTypeCode == 0;
              sawBSlice = sawBSlice || syntax.sliceTypeCode == 1;
            }
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
        final unsupported = <String>[];
        final sps = spsById[pps.spsId];
        if (sps == null) {
          unsupported.add('missing SPS ${pps.spsId}');
        } else if (pps.entropyCodingModeFlag) {
          if (!sps.isHighProfile8Bit420 ||
              !sps.usesFlatScalingMatrices ||
              pps.picScalingMatrixPresentFlag) {
            unsupported.add(
              'CABAC profile=${sps.profileIdc}/'
              'chroma=${sps.chromaFormatIdc}/'
              '${sps.bitDepthLumaMinus8 + 8}-bit/scaling-matrix',
            );
          }
          if (sawPSlice && !pps.weightedPredFlag) {
            unsupported.add('CABAC P without weighted prediction');
          }
          if (sawBSlice) {
            if (!sps.direct8x8InferenceFlag) {
              unsupported.add('CABAC B without direct-8x8 inference');
            }
            if (sps.picOrderCntType != 0) {
              unsupported.add(
                'CABAC B pic_order_cnt_type=${sps.picOrderCntType}',
              );
            }
            if (pps.weightedBipredIdc != 2) {
              unsupported.add(
                'CABAC B weighted_bipred_idc=${pps.weightedBipredIdc}',
              );
            }
          }
        } else {
          if (!sps.isSupportedBaseline420) {
            unsupported.add(
              'profile=${sps.profileIdc}/chroma=${sps.chromaFormatIdc}/'
              '${sps.bitDepthLumaMinus8 + 8}-bit',
            );
          }
          if (sawBSlice) unsupported.add('B pictures');
          if (pps.weightedPredFlag || pps.weightedBipredIdc != 0) {
            unsupported.add('weighted prediction');
          }
          if (pps.transform8x8ModeFlag || pps.picScalingMatrixPresentFlag) {
            unsupported.add('8x8 transform/scaling matrix');
          }
        }
        if (pps.numSliceGroupsMinus1 != 0) {
          unsupported.add('slice_groups=${pps.numSliceGroupsMinus1}');
        }
        if (unsupported.isNotEmpty) {
          return _VariantProbeResult(
            false,
            'unsupported decoder syntax: ${unsupported.join(', ')} '
            '(ppsId=$ppsId)',
          );
        }
      }

      if (idrSliceCount == 0) {
        return const _VariantProbeResult(true, 'compatible (no IDR in probe)');
      }
      for (final nal in sliceNals) {
        final SliceHeader header;
        try {
          header = parseSliceHeader(nal, ppsById: ppsById, spsById: spsById);
        } catch (error) {
          return _VariantProbeResult(false, 'unsupported slice header: $error');
        }
        final unsupported = _unsupportedProbeSliceHeader(header);
        if (unsupported != null) {
          return _VariantProbeResult(
            false,
            'unsupported slice header: $unsupported',
          );
        }
      }
      return const _VariantProbeResult(
        true,
        'compatible (parameter sets + slice headers)',
      );
    } catch (e) {
      final kind = e is HlsHttpException ? 'transport failure' : 'probe error';
      return _VariantProbeResult(false, '$kind: $e');
    }
  }

  String? _unsupportedProbeSliceHeader(SliceHeader header) {
    final sps = header.sps;
    final pps = header.pps;
    final cabacHigh = pps.entropyCodingModeFlag;
    final isP = !header.isIdr && header.sliceType == H264SliceType.p;
    final isB = !header.isIdr && header.sliceType == H264SliceType.b;

    if (cabacHigh && header.sliceType != H264SliceType.i && !isP && !isB) {
      return 'CABAC ${header.sliceType.name} pictures are not supported';
    }
    if (!cabacHigh &&
        header.sliceType != H264SliceType.i &&
        header.sliceType != H264SliceType.p) {
      return 'CAVLC ${header.sliceType.name} pictures are not supported';
    }
    if (cabacHigh && isP) {
      if (header.nalRefIdc == 0) {
        return 'CABAC P picture is not a short-term reference';
      }
      if (header.cabacInitIdc != 0) {
        return 'CABAC P cabac_init_idc=${header.cabacInitIdc}';
      }
      if (!pps.weightedPredFlag || header.predictionWeightTable == null) {
        return 'CABAC P picture has no explicit weighted prediction';
      }
    }
    if (cabacHigh && isB) {
      if (!sps.direct8x8InferenceFlag) {
        return 'CABAC B direct_8x8_inference_flag=0';
      }
      if (pps.weightedBipredIdc != 2) {
        return 'CABAC B weighted_bipred_idc=${pps.weightedBipredIdc}';
      }
      if (header.cabacInitIdc != 0) {
        return 'CABAC B cabac_init_idc=${header.cabacInitIdc}';
      }
      if (header.refPicListModificationsL0.isNotEmpty ||
          header.refPicListModificationsL1.isNotEmpty) {
        return 'CABAC B uses modified reference lists';
      }
      if (sps.picOrderCntType != 0 || header.picOrderCntLsb == null) {
        return 'CABAC B pic_order_cnt_type=${sps.picOrderCntType}';
      }
      if (header.numRefIdxL1ActiveMinus1 + 1 > 2) {
        return 'CABAC B uses ${header.numRefIdxL1ActiveMinus1 + 1} List1 references';
      }
    }
    if ((header.redundantPicCnt ?? 0) > 0) {
      return 'redundant pictures are not supported';
    }
    if (header.longTermReferenceFlag) {
      return 'long-term IDR references are not supported';
    }
    if ((header.sliceType == H264SliceType.p || isB) &&
        header.numRefIdxL0ActiveMinus1 > 31) {
      return 'num_ref_idx_l0_active_minus1=${header.numRefIdxL0ActiveMinus1}';
    }
    if (isB && header.numRefIdxL1ActiveMinus1 > 31) {
      return 'num_ref_idx_l1_active_minus1=${header.numRefIdxL1ActiveMinus1}';
    }
    if (header.adaptiveRefPicMarkingModeFlag &&
        (header.memoryManagementOperations.isEmpty ||
            header.memoryManagementOperations.any(
              (operation) => operation.operation != 1,
            ))) {
      return 'adaptive reference marking uses unsupported MMCO';
    }
    return null;
  }

  ({int ppsId, int sliceTypeCode})? _tryReadSliceProbe(Uint8List sliceNal) {
    try {
      if (sliceNal.isEmpty) return null;
      final t = sliceNal[0] & 0x1F;
      if (t != 1 && t != 5) return null;
      final rbsp = ebspToRbsp(sliceNal.sublist(1));
      final br = BitReader(rbsp);
      readUE(br);
      final sliceTypeCode = readUE(br) % 5;
      return (ppsId: readUE(br), sliceTypeCode: sliceTypeCode);
    } catch (_) {
      return null;
    }
  }

  Future<void> buildQueue() async {
    late final int epoch;
    try {
      epoch = await _beginQueueBuild();
    } on _StaleQueueBuild {
      return;
    }
    final httpClient = http.Client();
    final dataSource = HlsHttpDataSource(client: httpClient);
    try {
      _ensureBuildCurrent(epoch);
    } on _StaleQueueBuild {
      dataSource.dispose();
      httpClient.close();
      return;
    }
    _activeHlsClient = httpClient;
    _activeHlsDataSource = dataSource;

    try {
      final url = Uri.parse(urlCtrl.text.trim());
      append('Load: $url');

      final kind = await detectPlaylistKind(url, byteFetcher: dataSource.fetch);
      _ensureBuildCurrent(epoch);
      HlsMediaPlaylist media;
      var mediaPlaylistUri = url;
      HlsMediaPlaylist? separateAudioMedia;
      HlsAdaptiveSegmentFetcher? adaptiveVideoFetcher;
      var primaryUsesUnsupportedHeAac = false;
      String? unsupportedAudioReason;

      if (kind == HlsPlaylistKind.master) {
        final variants = await fetchHlsVariants(
          url,
          byteFetcher: dataSource.fetch,
        );
        _ensureBuildCurrent(epoch);
        append('Master playlist. Variants=${variants.length}');
        if (variants.isEmpty) throw Exception('No variants found.');

        final baselineVariants = variants
            .where(
              (variant) =>
                  (variant.codecs ?? '').toLowerCase().contains('avc1.42'),
            )
            .toList();
        final otherVariants = variants
            .where(
              (variant) =>
                  !(variant.codecs ?? '').toLowerCase().contains('avc1.42'),
            )
            .toList();
        final candidates = <HlsVariant>[...baselineVariants, ...otherVariants];

        final compatibleVariants = <HlsVariant>[];
        final rejectedReasons = <String>{};
        final probeResults = await Future.wait<_VariantProbeResult>([
          for (final variant in candidates)
            _probeVariantCompatibility(
              variant.uri,
              byteFetcher: dataSource.fetch,
            ),
        ]);
        _ensureBuildCurrent(epoch);
        for (var index = 0; index < candidates.length; index++) {
          final variant = candidates[index];
          append(
            'Probe variant: ${variant.resolution ?? "?"} '
            'bw=${variant.bandwidth ?? 0} codecs=${variant.codecs ?? "?"}',
          );
          final probe = probeResults[index];
          append('  -> ${probe.reason}');
          if (probe.ok) {
            compatibleVariants.add(variant);
          } else {
            rejectedReasons.add(probe.reason);
          }
        }
        if (compatibleVariants.isEmpty) {
          final details = rejectedReasons.isEmpty
              ? 'no probe result'
              : rejectedReasons.join('; ');
          final message =
              'No HLS variant passed compatibility probing: $details';
          append(message);
          setState(() {
            decodeInfo = message;
            audioInfo = 'Audio not started because no video variant passed';
          });
          return;
        }

        compatibleVariants.sort((a, b) {
          final bandwidthOrder = (a.bandwidth ?? 0x7fffffff).compareTo(
            b.bandwidth ?? 0x7fffffff,
          );
          if (bandwidthOrder != 0) return bandwidthOrder;
          return a.uri.toString().compareTo(b.uri.toString());
        });
        final requestedManualUri = _qualitySelectionId == _autoQualityId
            ? null
            : Uri.tryParse(_qualitySelectionId);
        var selectedVariant = requestedManualUri == null
            ? compatibleVariants.first
            : compatibleVariants
                  .where((variant) => variant.uri == requestedManualUri)
                  .firstOrNull;
        if (selectedVariant == null) {
          selectedVariant = compatibleVariants.first;
          _qualitySelectionId = _autoQualityId;
          append(
            'Requested manual quality is unavailable; falling back to Auto.',
          );
        }
        _qualityMasterUri = url;
        _qualityVariants = List<HlsVariant>.unmodifiable(compatibleVariants);
        if (mounted) setState(() {});

        append(
          'Pick variant: ${selectedVariant.resolution ?? "?"} '
          'bw=${selectedVariant.bandwidth ?? 0} '
          'codecs=${selectedVariant.codecs ?? "?"}',
        );
        mediaPlaylistUri = selectedVariant.uri;
        media = await fetchMediaPlaylist(
          mediaPlaylistUri,
          byteFetcher: dataSource.fetch,
          requireEndList: false,
        );
        _ensureBuildCurrent(epoch);

        if (media.isEndList) {
          final loadedRenditions = <HlsQualityRendition>[];
          final renditionLoads =
              await Future.wait<
                ({
                  HlsVariant variant,
                  HlsMediaPlaylist? playlist,
                  Object? error,
                })
              >([
                for (final variant in compatibleVariants)
                  () async {
                    try {
                      final playlist = variant.uri == selectedVariant!.uri
                          ? media
                          : await fetchMediaPlaylist(
                              variant.uri,
                              byteFetcher: dataSource.fetch,
                            );
                      return (
                        variant: variant,
                        playlist: playlist,
                        error: null,
                      );
                    } catch (error) {
                      return (variant: variant, playlist: null, error: error);
                    }
                  }(),
              ]);
          _ensureBuildCurrent(epoch);
          for (final load in renditionLoads) {
            final playlist = load.playlist;
            if (playlist != null) {
              loadedRenditions.add(
                HlsQualityRendition(variant: load.variant, playlist: playlist),
              );
            } else {
              append(
                'Quality ${load.variant.resolution ?? load.variant.uri}: '
                '${load.error}',
              );
            }
          }

          HlsQualityController controller;
          try {
            controller = HlsQualityController(
              renditions: loadedRenditions,
              initialManualVariantUri: _qualitySelectionId == _autoQualityId
                  ? null
                  : selectedVariant.uri,
              maximumAutomaticPixels: _maximumAutomaticQualityPixels,
              maximumAutomaticBandwidth: _maximumAutomaticQualityBandwidth,
            );
          } catch (error) {
            append(
              'Adaptive alignment unavailable; locking '
              '${selectedVariant.resolution ?? selectedVariant.uri}: $error',
            );
            _qualitySelectionId = selectedVariant.uri.toString();
            controller = HlsQualityController(
              renditions: <HlsQualityRendition>[
                HlsQualityRendition(variant: selectedVariant, playlist: media),
              ],
              initialManualVariantUri: selectedVariant.uri,
            );
          }
          _qualityController = controller;
          _activeQualityRendition = null;
          _displayedQualityRendition = null;
          _qualityTimeline.clear();
          _qualityVariants = List<HlsVariant>.unmodifiable(
            controller.renditions.map((rendition) => rendition.variant),
          );
          media = controller.canonical.playlist;
          adaptiveVideoFetcher = HlsAdaptiveSegmentFetcher(
            controller: controller,
            fetcher: dataSource.fetch,
            switchBoundaryValidator: _segmentStartsWithIdr,
            onDecision: (change) {
              if (epoch == _queueBuildEpoch &&
                  identical(_qualityController, controller)) {
                _handleQualityDecision(change);
              }
            },
            onActiveRendition: (rendition) {
              if (epoch == _queueBuildEpoch &&
                  identical(_qualityController, controller)) {
                _handleActiveQuality(rendition);
              }
            },
          );
          append(
            'Auto quality ceiling: ${controller.automaticCeiling.label} '
            'for the active decode device',
          );
          _refreshQualityInfo();
        } else {
          _qualityController = null;
          _activeQualityRendition = null;
          setState(() {
            _qualityInfo = _qualitySelectionId == _autoQualityId
                ? 'Quality: Auto initial · ${selectedVariant!.resolution ?? "?"}'
                : 'Quality: Manual · ${selectedVariant!.resolution ?? "?"}';
          });
        }
        primaryUsesUnsupportedHeAac =
            hlsVariantAdvertisesHeAac(selectedVariant) &&
            !hlsVariantAdvertisesAacLc(selectedVariant);

        final audioVariant = selectHlsAacLcVariant(
          variants,
          preferred: selectedVariant,
        );
        if (audioVariant != null && audioVariant.uri != selectedVariant.uri) {
          append(
            'Pick AAC-LC audio rendition: ${audioVariant.resolution ?? "?"} '
            'bw=${audioVariant.bandwidth ?? 0} '
            'codecs=${audioVariant.codecs ?? "?"}',
          );
          if (!media.isEndList) {
            if (primaryUsesUnsupportedHeAac) {
              unsupportedAudioReason =
                  'Audio unavailable for live HLS: the compatible video '
                  'rendition uses HE-AAC, and synchronized separate live '
                  'playlist refresh is outside Phase 2C.';
              append(unsupportedAudioReason);
            } else {
              append(
                'Separate live AAC rendition is not selected in Phase 2C; '
                'probing muxed primary audio instead.',
              );
            }
          } else {
            try {
              separateAudioMedia = await fetchMediaPlaylist(
                audioVariant.uri,
                byteFetcher: dataSource.fetch,
              );
              _ensureBuildCurrent(epoch);
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
          }
        } else if (audioVariant == null && primaryUsesUnsupportedHeAac) {
          unsupportedAudioReason =
              'Audio unavailable: selected HLS rendition advertises HE-AAC, '
              'but the Dart decoder supports AAC-LC only and this master '
              'has no AAC-LC fallback rendition.';
          append(unsupportedAudioReason);
        }
      } else {
        _qualityMasterUri = null;
        _qualityVariants = const <HlsVariant>[];
        _qualityController = null;
        _activeQualityRendition = null;
        _displayedQualityRendition = null;
        _qualityTimeline.clear();
        _qualitySelectionId = _autoQualityId;
        _qualityInfo = 'Quality: source';
        final probe = await _probeVariantCompatibility(
          url,
          byteFetcher: dataSource.fetch,
        );
        _ensureBuildCurrent(epoch);
        append('Probe media: ${probe.reason}');
        if (!probe.ok) {
          append('Media playlist probe failed: ${probe.reason}');
          return;
        }
        media = await fetchMediaPlaylist(
          url,
          byteFetcher: dataSource.fetch,
          requireEndList: false,
        );
        _ensureBuildCurrent(epoch);
      }

      append('Media segments=${media.segments.length}');
      if (media.segments.isEmpty && media.isEndList) return;
      if (!media.isEndList) {
        await _runLiveHlsSession(
          playlistUri: mediaPlaylistUri,
          dataSource: dataSource,
          epoch: epoch,
          audioFromVideoSegments: !primaryUsesUnsupportedHeAac,
          unsupportedAudioReason: unsupportedAudioReason,
        );
        return;
      }
      requireSingleHlsDiscontinuityEpoch(media);
      final audioMedia = separateAudioMedia;
      if (audioMedia != null) requireSingleHlsDiscontinuityEpoch(audioMedia);

      final segmentCount = media.segments.length;
      final vodDurationMs =
          (media.segments.fold<double>(
                    0,
                    (sum, segment) => sum + segment.duration,
                  ) *
                  1000)
              .round();
      append(
        'Rolling VOD: $segmentCount segments, ${_fmtMs(vodDurationMs)}, '
        'prebuffer=2, prefetch window=4, compressed window='
        '$_rollingMaxResidentAccessUnits AUs',
      );

      List<HlsSegmentPair>? separateAudioPairs;
      var usePrimaryAudio =
          separateAudioMedia == null && !primaryUsesUnsupportedHeAac;
      if (separateAudioMedia != null) {
        try {
          separateAudioPairs = pairHlsVariantSegments(
            media,
            separateAudioMedia,
            limit: segmentCount,
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
            usePrimaryAudio = true;
            append(
              'Falling back to the primary rendition audio because it is not '
              'advertised as HE-AAC.',
            );
          }
        }
      }

      _ensureBuildCurrent(epoch);
      _prepareRollingPlayback(live: false);

      final audioPairs = separateAudioPairs;
      final session = HlsVodRollingSession(
        videoSegments: media.segments,
        audioSegments: audioPairs?.map((pair) => pair.audio),
        audioFromVideoSegments: audioPairs == null && usePrimaryAudio,
        fetcher: adaptiveVideoFetcher?.call ?? dataSource.fetch,
        epoch: epoch,
        prebufferSegments: 2,
        prefetchWindow: 4,
        retryPredicate: (_, _, error) => _shouldRetryHlsSegment(error),
      );
      _activeHlsSession = session;
      final sessionDone = session.start();

      await for (final update in session.updates) {
        _ensureBuildCurrent(epoch);
        if (update.epoch != epoch) throw const _StaleQueueBuild();
        if (update.cancelled) throw const _StaleQueueBuild();

        final sessionError = update.error;
        if (sessionError != null) {
          _failRollingPlayback(
            'Streaming stopped: $sessionError',
            audioMessage: _rollingAudioClockLocked
                ? 'Audio stopped with the HLS session'
                : null,
          );
          throw const _StaleQueueBuild();
        }

        if (update.progress.audioState ==
                HlsVodAudioState.downgradedVideoOnly &&
            !_rollingAudioClockLocked) {
          final streamingDecoder = _activeStreamingAudioDecoder;
          _activeStreamingAudioDecoder = null;
          if (streamingDecoder != null) {
            await streamingDecoder.dispose(disposeSource: true);
          }
          _streamingAudioSourceInstalled = false;
          final downgrade = update.audioDowngradeReason;
          audioInfo = unsupportedAudioReason ?? 'Audio: video-only HLS';
          if (downgrade != null) {
            append('Audio downgraded before ready: $downgrade');
          }
        } else if (update.audioAccessUnits.isNotEmpty) {
          var streamingDecoder = _activeStreamingAudioDecoder;
          if (streamingDecoder == null) {
            final config =
                update.audioConfig ?? update.audioAccessUnits.first.config;
            final firstVideoPts90k = update.firstVideoPts90k;
            final firstVideoPtsMs = update.firstVideoPtsMs;
            if (firstVideoPts90k == null || firstVideoPtsMs == null) {
              throw const FormatException(
                'Cannot start rolling AAC before the video PTS origin exists',
              );
            }
            final startedDecoder = await StreamingAacPcmDecoder.start(
              config: config,
              originPts90k: firstVideoPts90k,
              basePtsUs: firstVideoPtsMs * Duration.microsecondsPerMillisecond,
            );
            try {
              _ensureBuildCurrent(epoch);
            } catch (_) {
              await startedDecoder.dispose(disposeSource: true);
              rethrow;
            }
            streamingDecoder = startedDecoder;
            _activeStreamingAudioDecoder = streamingDecoder;
            _streamingAudioSourceInstalled = false;
            append(
              'Persistent Dart AAC decoder: ${config.samplingFrequency} Hz, '
              '${config.channelCount ?? 0} channel(s)',
            );
          }
          await streamingDecoder.pushAllChunked(update.audioAccessUnits);
          _ensureBuildCurrent(epoch);
        }

        final mediaSequence = update.mediaSequence;
        _recordQualityBoundary(
          update.videoAccessUnits,
          mediaSequence == null
              ? null
              : adaptiveVideoFetcher?.renditionForSequence(mediaSequence),
        );
        await _appendRollingVideoBatch(update.videoAccessUnits, epoch);
        _sampleAbrBufferHealth(force: true);

        final progress = update.progress;
        if (progress.videoSegmentsLoaded == 1 ||
            progress.videoSegmentsLoaded == progress.totalSegments ||
            progress.videoSegmentsLoaded % 8 == 0) {
          append(
            'Segments ${progress.videoSegmentsLoaded}/${progress.totalSegments} '
            '(seq=${update.mediaSequence ?? "tail"}, '
            'video AUs=$_rollingVideoAccessUnits, '
            'AAC AUs=${progress.audioAccessUnitsEmitted}, '
            'resident=${_decodePump.residentLength})',
          );
        }

        if (update.becameReady) {
          if (progress.audioState == HlsVodAudioState.active) {
            final streamingDecoder = _activeStreamingAudioDecoder;
            if (streamingDecoder == null) {
              throw StateError(
                'HLS audio became active without a streaming decoder',
              );
            }
            await streamingDecoder.source.waitForFrameCount(1);
            _ensureBuildCurrent(epoch);
            await _installAudioSource(
              streamingDecoder.source,
              buildEpoch: epoch,
            );
            _streamingAudioSourceInstalled = true;
            _rollingAudioClockLocked = true;
            final delta = update.audioVideoPtsDelta90k ?? 0;
            append(
              'A/V ready: audio-video delta '
              '${(delta * 1000 / 90000).toStringAsFixed(3)}ms; '
              'audio is the locked master clock',
            );
          } else {
            audioInfo = unsupportedAudioReason ?? 'Audio: video-only HLS';
          }

          _ensureBuildCurrent(epoch);
          _rollingReady = true;
          setState(() {
            loading = false;
            decodeInfo =
                'Ready after ${progress.videoSegmentsLoaded} segments — '
                'press Play (download continues)';
          });
          append(
            'Playback ready before EOS: ${progress.videoSegmentsLoaded}/'
            '${progress.totalSegments} segments',
          );
        }

        if (update.sealed) {
          final streamingDecoder = _activeStreamingAudioDecoder;
          if (streamingDecoder != null) {
            await streamingDecoder.seal();
            _ensureBuildCurrent(epoch);
            await streamingDecoder.dispose();
            if (identical(_activeStreamingAudioDecoder, streamingDecoder)) {
              _activeStreamingAudioDecoder = null;
              _streamingAudioSourceInstalled = false;
            }
          }
          _decodePump.closeQueue();
          _rollingSealed = true;
          append(
            'HLS VOD sealed: $_rollingVideoAccessUnits video AUs, '
            '${progress.audioAccessUnitsEmitted} AAC AUs; '
            'resident compressed window=${_decodePump.residentLength}',
          );
        }
      }

      await sessionDone;
      _ensureBuildCurrent(epoch);
      if (!_rollingReady) {
        throw StateError('HLS session ended before playback became ready');
      }
    } on _StaleQueueBuild {
      // A newer queue build or widget disposal owns the UI and transport now.
    } catch (e) {
      if (epoch == _queueBuildEpoch) {
        if (_rollingHls && !_rollingSealed) {
          _failRollingPlayback(
            'Streaming failed: $e',
            audioMessage: _rollingAudioClockLocked
                ? 'Audio stopped with the failed HLS session'
                : null,
          );
        }
        if (mounted) {
          setState(() {
            decodeInfo = 'HLS build failed: $e';
            if (!_rollingAudioClockLocked) {
              audioInfo = 'Audio not started';
            }
          });
        }
        append('ERROR: $e');
      }
    } finally {
      final session = _activeHlsSession;
      if (session != null && session.epoch == epoch) {
        _activeHlsSession = null;
        await session.dispose();
      }
      final liveSession = _activeLiveHlsSession;
      if (liveSession != null && liveSession.epoch == epoch) {
        _activeLiveHlsSession = null;
        await liveSession.dispose();
      }
      final streamingDecoder = _activeStreamingAudioDecoder;
      if (streamingDecoder != null && epoch == _queueBuildEpoch) {
        final sourceWasInstalled = _streamingAudioSourceInstalled;
        _activeStreamingAudioDecoder = null;
        _streamingAudioSourceInstalled = false;
        await streamingDecoder.dispose(disposeSource: !sourceWasInstalled);
      }
      if (identical(_activeHlsDataSource, dataSource)) {
        _activeHlsDataSource = null;
        _activeHlsClient = null;
        dataSource.dispose();
        httpClient.close();
      }
      if (mounted && epoch == _queueBuildEpoch) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _runLiveHlsSession({
    required Uri playlistUri,
    required HlsHttpDataSource dataSource,
    required int epoch,
    required bool audioFromVideoSegments,
    required String? unsupportedAudioReason,
  }) async {
    append(
      'Live HLS: refresh window, hold-back=3 segments, prebuffer=2, '
      'prefetch window=4, PCM retention=5 minutes / 64 MiB',
    );
    if (!audioFromVideoSegments && unsupportedAudioReason != null) {
      audioInfo = unsupportedAudioReason;
    }

    _ensureBuildCurrent(epoch);
    _prepareRollingPlayback(live: true);

    final coordinator = HlsLivePlaylistCoordinator(
      playlistUri: playlistUri,
      fetcher: dataSource.fetch,
      epoch: epoch,
      initialHoldBackSegments: 3,
    );
    final session = HlsLiveRollingSession(
      playlistCoordinator: coordinator,
      fetcher: dataSource.fetch,
      audioFromVideoSegments: audioFromVideoSegments,
      prebufferSegments: 2,
      prefetchWindow: 4,
      retryPredicate: (_, _, error) => _shouldRetryHlsSegment(error),
    );
    _activeLiveHlsSession = session;
    final sessionDone = session.start();

    await for (final update in session.updates) {
      _ensureBuildCurrent(epoch);
      if (update.epoch != epoch || update.cancelled) {
        throw const _StaleQueueBuild();
      }

      final sessionError = update.error;
      if (sessionError != null) {
        _failRollingPlayback(
          'Live streaming stopped: $sessionError',
          audioMessage: _rollingAudioClockLocked
              ? 'Audio stopped with the live HLS session'
              : null,
        );
        throw const _StaleQueueBuild();
      }

      final progress = update.progress;
      if (update.playlistRefreshed) {
        append(
          'Live refresh ${progress.playlistRefreshesCompleted}: '
          'window=${progress.windowFirstSequence ?? "?"}..'
          '${progress.windowLastSequence ?? "?"}, '
          'new/pending=${progress.pendingSegmentCount}, '
          'ENDLIST=${progress.endListSeen}',
        );
      }

      if (progress.audioState == HlsLiveAudioState.downgradedVideoOnly &&
          !_rollingAudioClockLocked) {
        final streamingDecoder = _activeStreamingAudioDecoder;
        _activeStreamingAudioDecoder = null;
        if (streamingDecoder != null) {
          await streamingDecoder.dispose(disposeSource: true);
        }
        _streamingAudioSourceInstalled = false;
        audioInfo = unsupportedAudioReason ?? 'Audio: video-only live HLS';
        final downgrade = update.audioDowngradeReason;
        if (downgrade != null) {
          append('Live audio downgraded before ready: $downgrade');
        }
      } else if (update.audioAccessUnits.isNotEmpty) {
        var streamingDecoder = _activeStreamingAudioDecoder;
        if (streamingDecoder == null) {
          final config =
              update.audioConfig ?? update.audioAccessUnits.first.config;
          final baseVideoPts90k = update.baseVideoPts90k;
          if (baseVideoPts90k == null) {
            throw const FormatException(
              'Cannot start live AAC before the video PTS origin exists',
            );
          }
          final startedDecoder = await StreamingAacPcmDecoder.start(
            config: config,
            originPts90k: baseVideoPts90k,
            maxRetainedPcmDuration: _livePcmRetentionDuration,
            maxRetainedPcmBytes: _livePcmMaxBytes,
          );
          try {
            _ensureBuildCurrent(epoch);
          } catch (_) {
            await startedDecoder.dispose(disposeSource: true);
            rethrow;
          }
          streamingDecoder = startedDecoder;
          _activeStreamingAudioDecoder = streamingDecoder;
          _streamingAudioSourceInstalled = false;
          append(
            'Persistent bounded Dart AAC decoder: '
            '${config.samplingFrequency} Hz, '
            '${config.channelCount ?? 0} channel(s)',
          );
        }
        await streamingDecoder.pushAllChunked(update.audioAccessUnits);
        _ensureBuildCurrent(epoch);
      }

      await _appendRollingVideoBatch(update.videoAccessUnits, epoch);

      if (update.mediaSequence != null &&
          (progress.videoSegmentsLoaded == 1 ||
              progress.videoSegmentsLoaded % 8 == 0)) {
        append(
          'Live seq=${update.mediaSequence}: '
          'segments=${progress.videoSegmentsLoaded}, '
          'video AUs=$_rollingVideoAccessUnits, '
          'AAC AUs=${progress.audioAccessUnitsEmitted}, '
          'resident=${_decodePump.residentLength}',
        );
      }

      if (update.becameReady) {
        if (progress.audioState == HlsLiveAudioState.active) {
          final streamingDecoder = _activeStreamingAudioDecoder;
          if (streamingDecoder == null) {
            throw StateError(
              'Live HLS audio became active without a streaming decoder',
            );
          }
          await streamingDecoder.source.waitForFrameCount(1);
          _ensureBuildCurrent(epoch);
          await _installAudioSource(streamingDecoder.source, buildEpoch: epoch);
          _streamingAudioSourceInstalled = true;
          _rollingAudioClockLocked = true;
          final delta = update.audioVideoPtsDelta90k ?? 0;
          append(
            'Live A/V ready: audio-video delta '
            '${(delta * 1000 / 90000).toStringAsFixed(3)}ms; '
            'audio is the locked master clock',
          );
        } else {
          audioInfo = unsupportedAudioReason ?? 'Audio: video-only live HLS';
        }

        _ensureBuildCurrent(epoch);
        _rollingReady = true;
        setState(() {
          loading = false;
          decodeInfo =
              'Live ready at sequence ${update.mediaSequence ?? "?"} — '
              'press Play';
        });
        append(
          'Live playback ready after ${progress.videoSegmentsLoaded} '
          'segments; playlist refresh continues',
        );
      }

      if (update.sealed) {
        final streamingDecoder = _activeStreamingAudioDecoder;
        if (streamingDecoder != null) {
          await streamingDecoder.seal();
          _ensureBuildCurrent(epoch);
          await streamingDecoder.dispose();
          if (identical(_activeStreamingAudioDecoder, streamingDecoder)) {
            _activeStreamingAudioDecoder = null;
            _streamingAudioSourceInstalled = false;
          }
        }
        _decodePump.closeQueue();
        _rollingSealed = true;
        append(
          'Live playlist ended: $_rollingVideoAccessUnits video AUs, '
          '${progress.audioAccessUnitsEmitted} AAC AUs; '
          'resident compressed window=${_decodePump.residentLength}',
        );
      }
    }

    await sessionDone;
    _ensureBuildCurrent(epoch);
    if (!_rollingReady) {
      throw StateError('Live HLS session ended before playback became ready');
    }
  }

  Future<void> buildQueueFromMp4(Uri mp4Url) async {
    late final int epoch;
    try {
      epoch = await _beginQueueBuild();
    } on _StaleQueueBuild {
      return;
    }

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
      _ensureBuildCurrent(epoch);

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
      _ensureBuildCurrent(epoch);
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
          final source = await decodeMp4AacToFilePcmInBackground(
            bytes,
            playableAudioTrack,
          );
          await _installAudioSource(source, buildEpoch: epoch);
          append(
            'Audio ready: ${source.frameCount} PCM frames, '
            '${_fmtMs(source.durationUs ~/ 1000)}, file-backed',
          );
        } on _StaleQueueBuild {
          rethrow;
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

      _ensureBuildCurrent(epoch);
      setState(() {});
    } on _StaleQueueBuild {
      // A newer queue build or widget disposal owns the UI and transport now.
    } catch (e) {
      if (epoch == _queueBuildEpoch) append("MP4 ERROR: $e");
    } finally {
      if (mounted && epoch == _queueBuildEpoch) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> play() => _serializeTransport(_play);

  Future<void> _play() async {
    if (_rollingFailed || _decodePump.residentLength == 0) return;
    final audio = _audioController;
    if (_decodePump.isEnded) {
      final audioStartUs = _rollingAudioClockLocked
          ? audio?.seekableStartMediaTimeUs
          : null;
      final restartIndex = _firstRetainedIdrIndex(
        atOrAfterMs: audioStartUs == null
            ? null
            : (audioStartUs + Duration.microsecondsPerMillisecond - 1) ~/
                  Duration.microsecondsPerMillisecond,
      );
      if (restartIndex == null) return;
      final restart = _decodePump.itemAt(restartIndex);
      _resetDecodePosition(
        restartIndex,
        message: _rollingHls && restartIndex > 0
            ? 'Replaying retained window…'
            : 'Replaying from start…',
      );
      if (audio != null) {
        await audio.seekToMediaTimeUs(restart.ptsMs * 1000);
      }
    }

    final atOpenTail =
        !_decodePump.isQueueFinal &&
        _decodePump.nextIndex == _decodePump.endIndex;
    if (atOpenTail && !_rollingAudioClockLocked) {
      _resumeVideoOnlyAfterStarvation = true;
      clock.pause();
      if (mounted) setState(() => decodeInfo = 'Buffering video…');
      return;
    }

    var startMs =
        current == null && _decodePump.nextIndex < _decodePump.endIndex
        ? _decodePump.itemAt(_decodePump.nextIndex).ptsMs
        : clock.nowMs;
    if (_rollingAudioClockLocked) {
      if (audio == null || !audio.hasAudio) {
        clock.pause();
        if (mounted) {
          setState(() {
            decodeInfo = 'Waiting for the locked HLS audio clock…';
          });
        }
        return;
      }
      final audioStartUs = audio.seekableStartMediaTimeUs;
      if (audioStartUs != null && startMs * 1000 < audioStartUs) {
        final recoveryIndex = _firstRetainedIdrIndex(
          atOrAfterMs:
              (audioStartUs + Duration.microsecondsPerMillisecond - 1) ~/
              Duration.microsecondsPerMillisecond,
        );
        if (recoveryIndex == null) {
          clock.pause();
          if (mounted) {
            setState(() {
              decodeInfo = 'Waiting for a common live audio/video keyframe…';
            });
          }
          return;
        }
        if (!await _seekToAccessUnit(recoveryIndex)) return;
        startMs = _decodePump.itemAt(recoveryIndex).ptsMs;
      }
      if (!atOpenTail && !_audioCovers(audio, startMs)) {
        clock.pause();
        if (mounted) {
          setState(() {
            decodeInfo = 'Buffering audio for ${_fmtMs(startMs)}…';
          });
        }
        return;
      }
      if (!atOpenTail) {
        final driftMs = (audio.currentMediaTimeMs - startMs).abs();
        if (driftMs > 50) {
          await audio.seekToMediaTimeUs(startMs * 1000);
        }
      }
      await audio.play();
      clock.play(
        fromMs: audio.currentMediaTimeMs,
        timeSource: () => audio.currentMediaTimeMs,
      );
      return;
    }

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
    _resumeVideoOnlyAfterStarvation = false;
    final audio = _audioController;
    if (audio != null && audio.isPlaying) await audio.pause();
    clock.pause();
  }

  Future<void> nextIdr() => _serializeTransport(_nextIdr);

  Future<void> _nextIdr() async {
    if (_decodePump.residentLength == 0) return;
    final first = _decodePump.firstRetainedIndex;
    final start = math.max(_decodePump.nextIndex, first);
    for (int i = start; i < _decodePump.endIndex; i++) {
      if (!_decodePump.itemAt(i).hasIdr) continue;
      await _seekToAccessUnit(i);
      return;
    }
  }

  Future<void> prevIdr() => _serializeTransport(_prevIdr);

  Future<void> _prevIdr() async {
    if (_decodePump.residentLength == 0) return;
    final curMs = clock.nowMs;
    int start = _decodePump.nextIndex - 2;
    final first = _decodePump.firstRetainedIndex;
    if (start < first) start = first;
    if (start >= _decodePump.endIndex) start = _decodePump.endIndex - 1;

    for (int i = start; i >= first; i--) {
      final accessUnit = _decodePump.itemAt(i);
      if (accessUnit.hasIdr && accessUnit.ptsMs < curMs) {
        await _seekToAccessUnit(i);
        return;
      }
    }
  }

  void _resetDecodePosition(int index, {required String message}) {
    clock.pause();
    _resumeVideoOnlyAfterStarvation = false;
    _resetDecodeAndRender();
    _decodePump.seekToIndex(index);
    setState(() {
      current = null;
      decodeInfo = message;
      _presentedVideo.value = null;
    });
  }

  Future<bool> _seekToAccessUnit(
    int index, {
    bool? resumeAfterSeekOverride,
  }) async {
    if (index < _decodePump.firstRetainedIndex ||
        index >= _decodePump.endIndex) {
      return false;
    }
    final audio = _audioController;
    final targetMs = _decodePump.itemAt(index).ptsMs;
    if (_rollingAudioClockLocked &&
        (audio == null || !_audioCovers(audio, targetMs))) {
      if (mounted) {
        setState(() {
          decodeInfo =
              'Cannot seek to ${_fmtMs(targetMs)} until its audio '
              'is buffered';
        });
      }
      return false;
    }
    final decodeStart = _nearestPrecedingIdr(index);
    if (decodeStart == null) return false;
    final resumeAfterSeek =
        resumeAfterSeekOverride ??
        (clock.isPlaying || (audio?.isPlaying ?? false));
    clock.pause();
    if (audio != null && audio.isPlaying) await audio.pause();
    if (audio != null) {
      try {
        await audio.seekToMediaTimeUs(targetMs * 1000);
      } on PcmFramesEvictedException {
        if (resumeAfterSeek && audio.hasAudio) {
          await audio.play();
          clock.play(
            fromMs: audio.currentMediaTimeMs,
            timeSource: () => audio.currentMediaTimeMs,
          );
        }
        if (mounted) {
          setState(() {
            decodeInfo = 'That live position has left the audio buffer';
          });
        }
        return false;
      }
    }
    _resetDecodePosition(
      decodeStart,
      message: 'Seeking to ${_fmtMs(targetMs)}…',
    );
    // Decode dependencies from the keyframe through the requested AU. The
    // serial pump presents only the latest completed frame.
    clock.setTime(targetMs);
    if (resumeAfterSeek) {
      if (_rollingAudioClockLocked) {
        await audio!.play();
        clock.play(
          fromMs: audio.currentMediaTimeMs,
          timeSource: () => audio.currentMediaTimeMs,
        );
      } else if (audio != null && _audioCovers(audio, targetMs)) {
        await audio.play();
        clock.play(
          fromMs: audio.currentMediaTimeMs,
          timeSource: () => audio.currentMediaTimeMs,
        );
      } else {
        clock.play(fromMs: targetMs);
      }
    }
    return true;
  }

  bool _audioCovers(AudioPlaybackController audio, int mediaTimeMs) {
    final source = audio.source;
    if (source == null || !audio.hasAudio) return false;
    final mediaTimeUs = mediaTimeMs * Duration.microsecondsPerMillisecond;
    final seekableStartUs = audio.seekableStartMediaTimeUs ?? source.basePtsUs;
    final seekableEndUs = audio.seekableEndMediaTimeUs ?? source.endPtsUs;
    return mediaTimeUs >= seekableStartUs && mediaTimeUs < seekableEndUs;
  }

  int? _nearestPrecedingIdr(int index) {
    for (int i = index; i >= _decodePump.firstRetainedIndex; i--) {
      if (_decodePump.itemAt(i).hasIdr) return i;
    }
    return null;
  }

  int? _firstRetainedIdrIndex({int? atOrAfterMs}) {
    for (
      int i = _decodePump.firstRetainedIndex;
      i < _decodePump.endIndex;
      i++
    ) {
      final accessUnit = _decodePump.itemAt(i);
      if (accessUnit.hasIdr &&
          (atOrAfterMs == null || accessUnit.ptsMs >= atOrAfterMs)) {
        return i;
      }
    }
    return null;
  }

  Future<void> seekToStart() => _serializeTransport(_seekToStart);

  Future<void> _seekToStart() async {
    if (!_rollingHls) {
      if (queue.isEmpty) return;
      final audio = _audioController;
      if (audio != null && audio.isPlaying) await audio.pause();
      _resetDecodePosition(0, message: 'At start');
      if (audio != null) {
        await audio.seekToMediaTimeUs(queue.first.ptsMs * 1000);
      }
      clock.setTime(queue.first.ptsMs);
      return;
    }

    final audioStartUs = _rollingAudioClockLocked
        ? _audioController?.seekableStartMediaTimeUs
        : null;
    final firstIdr = _firstRetainedIdrIndex(
      atOrAfterMs: audioStartUs == null
          ? null
          : (audioStartUs + Duration.microsecondsPerMillisecond - 1) ~/
                Duration.microsecondsPerMillisecond,
    );
    if (firstIdr == null) return;
    final didSeek = await _seekToAccessUnit(firstIdr);
    if (!didSeek) return;
    if (mounted && !clock.isPlaying) {
      setState(() {
        decodeInfo = _rollingHls && firstIdr > 0
            ? 'At earliest retained keyframe'
            : 'At start';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = urlCtrl.text.trim();
    final inputPath = (Uri.tryParse(input)?.path ?? input).toLowerCase();
    final isMp4 = inputPath.endsWith('.mp4');
    final hasPlayableVideo = _decodePump.residentLength > 0;
    final transportEnabled = !loading && !_rollingFailed && hasPlayableVideo;
    final audio = _audioController;
    final audioSource = audio?.source;
    final audioWindowMoved =
        audioSource != null &&
        (audio?.seekableStartMediaTimeUs ?? audioSource.basePtsUs) >
            audioSource.basePtsUs;
    final retainedStartWasCompacted =
        _rollingHls && (_decodePump.firstRetainedIndex > 0 || audioWindowMoved);

    return Scaffold(
      appBar: AppBar(title: const Text('NDVY Playback')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: urlCtrl,
                onChanged: _handleUrlChanged,
                decoration: const InputDecoration(
                  labelText: '.m3u8 or .mp4 URL',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('HLS quality: '),
                  Expanded(
                    child: DropdownButton<String>(
                      key: const Key('hls-quality'),
                      isExpanded: true,
                      value: _qualitySelectionId,
                      onChanged: isMp4 || loading ? null : _selectQuality,
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(
                          value: _autoQualityId,
                          child: Text('Auto'),
                        ),
                        for (final variant in _qualityVariants)
                          DropdownMenuItem<String>(
                            value: variant.uri.toString(),
                            child: Text(
                              '${variant.resolution ?? "Unknown"} · '
                              '${variant.bandwidth == null ? "?" : (variant.bandwidth! / 1000).round()} kbps',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
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
                    key: const Key('cancel-build'),
                    onPressed: loading ? cancelQueueBuild : null,
                    child: const Text('Cancel Build'),
                  ),
                  FilledButton.tonal(
                    onPressed: transportEnabled ? play : null,
                    child: const Text('Play'),
                  ),
                  FilledButton.tonal(
                    onPressed: transportEnabled ? pause : null,
                    child: const Text('Pause'),
                  ),
                  FilledButton.tonal(
                    onPressed: transportEnabled ? seekToStart : null,
                    child: Text(
                      retainedStartWasCompacted
                          ? 'Seek Buffer Start'
                          : 'Seek Start',
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: transportEnabled ? prevIdr : null,
                    child: const Text('Prev IDR'),
                  ),
                  FilledButton.tonal(
                    onPressed: transportEnabled ? nextIdr : null,
                    child: const Text('Next IDR'),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text(
                      'Decode: sequential I/P/B',
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
                    Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text(
                        _rollingHls
                            ? _rollingFailed
                                  ? 'Mode: HLS failed'
                                  : _rollingSealed
                                  ? _liveHls
                                        ? 'Mode: HLS live ended'
                                        : 'Mode: HLS VOD sealed'
                                  : _liveHls
                                  ? 'Mode: HLS live'
                                  : 'Mode: HLS rolling VOD'
                            : 'Mode: HLS',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      audioInfo,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      _qualityInfo,
                      key: const Key('quality-info'),
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
                  child: ValueListenableBuilder<_PresentedVideoFrame?>(
                    valueListenable: _presentedVideo,
                    builder: (context, presented, _) => Stack(
                      children: [
                        Positioned.fill(
                          child: presented == null
                              ? Center(
                                  child: Text(
                                    'info : $decodeInfo',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                )
                              : presented.textureId != null
                              ? FittedBox(
                                  fit: BoxFit.contain,
                                  child: SizedBox(
                                    width: presented.width.toDouble(),
                                    height: presented.height.toDouble(),
                                    child: Texture(
                                      textureId: presented.textureId!,
                                    ),
                                  ),
                                )
                              : PureFrameView(
                                  rgba: presented.rgba!,
                                  width: presented.width,
                                  height: presented.height,
                                ),
                        ),
                        Positioned(
                          left: 10,
                          bottom: 10,
                          right: 10,
                          child: Text(
                            presented == null
                                ? 'No frame yet'
                                : 'PTS ${_fmtMs(presented.accessUnit.ptsMs)} | '
                                      'NALs ${presented.accessUnit.nals.length} | '
                                      '${presented.width}x${presented.height}\n'
                                      '${presented.decodeInfo}',
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
