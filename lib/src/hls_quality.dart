import 'dart:async';
import 'dart:typed_data';

import 'hls.dart';

enum HlsQualityMode { automatic, manual }

/// One probed, decoder-compatible variant and its aligned VOD playlist.
final class HlsQualityRendition {
  HlsQualityRendition({required this.variant, required this.playlist})
    : segmentsBySequence = <int, HlsSegment>{
        for (final segment in playlist.segments) segment.sequence: segment,
      };

  final HlsVariant variant;
  final HlsMediaPlaylist playlist;
  final Map<int, HlsSegment> segmentsBySequence;

  int get bandwidth => variant.bandwidth ?? 0;

  String get label {
    final resolution = variant.resolution;
    final kbps = bandwidth <= 0 ? '?' : (bandwidth / 1000).round().toString();
    return resolution == null || resolution.isEmpty
        ? '$kbps kbps'
        : '$resolution · $kbps kbps';
  }
}

final class HlsQualityChange {
  const HlsQualityChange({
    required this.previous,
    required this.current,
    required this.reason,
  });

  final HlsQualityRendition previous;
  final HlsQualityRendition current;
  final String reason;
}

/// Conservative throughput + playback-health controller for aligned HLS VOD.
///
/// Automatic mode starts at the lowest compatible rendition, upgrades one
/// level after three fast segment downloads, immediately steps down on a
/// network failure or a newly observed playback-lateness episode, and keeps
/// stepping down when decoder pressure persists. Manual mode never changes
/// quality without an explicit selection.
final class HlsQualityController {
  HlsQualityController({
    required Iterable<HlsQualityRendition> renditions,
    Uri? initialManualVariantUri,
  }) : _renditions = _validateAndSortRenditions(renditions) {
    final manualUri = initialManualVariantUri;
    if (manualUri != null) {
      final manualIndex = _indexForUri(manualUri);
      if (manualIndex < 0) {
        throw ArgumentError.value(
          manualUri,
          'initialManualVariantUri',
          'is not an aligned compatible rendition',
        );
      }
      _mode = HlsQualityMode.manual;
      _selectedIndex = manualIndex;
    }
  }

  static const double _safeThroughputFraction = 0.65;
  static const int _fastDownloadsBeforeUpgrade = 3;
  static const int _smoothPresentationsToRecover = 90;
  static const int _troubledPresentationsBeforeFurtherStepDown = 3;
  static const int _latePlaybackThresholdMs = 180;
  static const int _smoothPlaybackThresholdMs = 60;

  final List<HlsQualityRendition> _renditions;
  HlsQualityMode _mode = HlsQualityMode.automatic;
  int _selectedIndex = 0;
  double? _estimatedBitsPerSecond;
  int _consecutiveFastDownloads = 0;
  int _smoothPresentations = 0;
  int _consecutiveTroubledPresentations = 0;
  bool _playbackConstrained = false;

  HlsQualityMode get mode => _mode;
  List<HlsQualityRendition> get renditions => _renditions;
  HlsQualityRendition get selected => _renditions[_selectedIndex];
  HlsQualityRendition get canonical => _renditions.first;
  double? get estimatedBitsPerSecond => _estimatedBitsPerSecond;
  bool get playbackConstrained => _playbackConstrained;

  HlsQualityChange? selectAutomatic() {
    final previous = selected;
    _mode = HlsQualityMode.automatic;
    _selectedIndex = 0;
    _resetHysteresis();
    return identical(previous, selected)
        ? null
        : HlsQualityChange(
            previous: previous,
            current: selected,
            reason: 'automatic mode starts from the safest rendition',
          );
  }

  HlsQualityChange? selectManual(Uri variantUri) {
    final index = _indexForUri(variantUri);
    if (index < 0) {
      throw ArgumentError.value(
        variantUri,
        'variantUri',
        'is not an aligned compatible rendition',
      );
    }
    final previous = selected;
    _mode = HlsQualityMode.manual;
    _selectedIndex = index;
    _resetHysteresis();
    return identical(previous, selected)
        ? null
        : HlsQualityChange(
            previous: previous,
            current: selected,
            reason: 'manual quality selection',
          );
  }

  /// Updates the measured network budget after one successful media segment.
  HlsQualityChange? recordDownload({
    required int byteCount,
    required Duration elapsed,
  }) {
    if (byteCount < 0) {
      throw ArgumentError.value(byteCount, 'byteCount');
    }
    final elapsedUs = elapsed.inMicroseconds <= 0 ? 1 : elapsed.inMicroseconds;
    final sample = byteCount * 8 * Duration.microsecondsPerSecond / elapsedUs;
    final previousEstimate = _estimatedBitsPerSecond;
    _estimatedBitsPerSecond = previousEstimate == null
        ? sample
        : previousEstimate * 0.7 + sample * 0.3;
    if (_mode == HlsQualityMode.manual) return null;

    final currentBandwidth = selected.bandwidth;
    final estimate = _estimatedBitsPerSecond!;
    if (_selectedIndex > 0 &&
        currentBandwidth > 0 &&
        estimate < currentBandwidth * 1.10) {
      _consecutiveFastDownloads = 0;
      return _stepDown('measured bandwidth fell below the safety margin');
    }
    if (_playbackConstrained || _selectedIndex >= _renditions.length - 1) {
      _consecutiveFastDownloads = 0;
      return null;
    }

    final nextBandwidth = _renditions[_selectedIndex + 1].bandwidth;
    if (nextBandwidth > 0 &&
        estimate * _safeThroughputFraction >= nextBandwidth) {
      _consecutiveFastDownloads++;
      if (_consecutiveFastDownloads >= _fastDownloadsBeforeUpgrade) {
        _consecutiveFastDownloads = 0;
        return _stepUp('sustained segment throughput has safe headroom');
      }
    } else {
      _consecutiveFastDownloads = 0;
    }
    return null;
  }

  HlsQualityChange? recordNetworkFailure() {
    if (_mode == HlsQualityMode.manual) return null;
    _consecutiveFastDownloads = 0;
    return _stepDown('segment download failed');
  }

  /// Feeds audio-clock lateness and starvation into automatic hysteresis.
  HlsQualityChange? observePlayback({
    required int latenessMs,
    required bool starved,
  }) {
    if (latenessMs < 0) {
      throw ArgumentError.value(latenessMs, 'latenessMs');
    }
    if (_mode == HlsQualityMode.manual) return null;
    final troubled = starved || latenessMs >= _latePlaybackThresholdMs;
    if (troubled) {
      _smoothPresentations = 0;
      _consecutiveFastDownloads = 0;
      _consecutiveTroubledPresentations++;
      if (_playbackConstrained &&
          _consecutiveTroubledPresentations <
              _troubledPresentationsBeforeFurtherStepDown) {
        return null;
      }
      _playbackConstrained = true;
      _consecutiveTroubledPresentations = 0;
      return _stepDown(
        starved
            ? 'video queue starved'
            : 'decoder presentation remained ${latenessMs}ms behind',
      );
    }

    _consecutiveTroubledPresentations = 0;
    if (latenessMs <= _smoothPlaybackThresholdMs) {
      _smoothPresentations++;
      if (_smoothPresentations >= _smoothPresentationsToRecover) {
        _playbackConstrained = false;
        _smoothPresentations = 0;
      }
    } else {
      _smoothPresentations = 0;
    }
    return null;
  }

  HlsResolvedQualitySegment resolve(Uri canonicalSegmentUri) {
    return _resolveForRendition(canonicalSegmentUri, selected);
  }

  HlsResolvedQualitySegment _resolveForRendition(
    Uri canonicalSegmentUri,
    HlsQualityRendition rendition,
  ) {
    final canonicalIndex = canonical.playlist.segments.indexWhere(
      (segment) => segment.uri == canonicalSegmentUri,
    );
    if (canonicalIndex < 0) {
      return HlsResolvedQualitySegment.passthrough(canonicalSegmentUri);
    }
    final sequence = canonical.playlist.segments[canonicalIndex].sequence;
    final selectedSegment = rendition.segmentsBySequence[sequence];
    if (selectedSegment == null) {
      throw StateError(
        'Selected rendition ${rendition.variant.uri} is missing sequence '
        '$sequence',
      );
    }
    return HlsResolvedQualitySegment(
      requestedUri: canonicalSegmentUri,
      canonicalIndex: canonicalIndex,
      segment: selectedSegment,
      rendition: rendition,
    );
  }

  int _indexForUri(Uri uri) =>
      _renditions.indexWhere((rendition) => rendition.variant.uri == uri);

  void _resetHysteresis() {
    _consecutiveFastDownloads = 0;
    _smoothPresentations = 0;
    _consecutiveTroubledPresentations = 0;
    _playbackConstrained = false;
  }

  HlsQualityChange? _stepDown(String reason) {
    if (_selectedIndex == 0) return null;
    final previous = selected;
    _selectedIndex--;
    return HlsQualityChange(
      previous: previous,
      current: selected,
      reason: reason,
    );
  }

  HlsQualityChange? _stepUp(String reason) {
    if (_selectedIndex >= _renditions.length - 1) return null;
    final previous = selected;
    _selectedIndex++;
    return HlsQualityChange(
      previous: previous,
      current: selected,
      reason: reason,
    );
  }
}

final class HlsResolvedQualitySegment {
  const HlsResolvedQualitySegment({
    required this.requestedUri,
    required this.canonicalIndex,
    required this.segment,
    required this.rendition,
  });

  const HlsResolvedQualitySegment.passthrough(this.requestedUri)
    : canonicalIndex = null,
      segment = null,
      rendition = null;

  final Uri requestedUri;
  final int? canonicalIndex;
  final HlsSegment? segment;
  final HlsQualityRendition? rendition;

  Uri get fetchUri => segment?.uri ?? requestedUri;
  bool get isAdaptiveVideoSegment => segment != null;
}

typedef HlsSwitchBoundaryValidator = bool Function(Uint8List bytes);
typedef HlsQualityChangeCallback = void Function(HlsQualityChange change);
typedef HlsActiveRenditionCallback =
    void Function(HlsQualityRendition rendition);

/// Fetch adapter used by the existing bounded VOD session.
///
/// The session continues to own one canonical, sequence-ordered playlist.
/// Immediately before each not-yet-prefetched request this adapter resolves
/// the same media sequence against the controller's selected rendition. A
/// rendition transition is accepted only when the fetched segment passes the
/// caller's random-access-boundary validation.
final class HlsAdaptiveSegmentFetcher {
  HlsAdaptiveSegmentFetcher({
    required this.controller,
    required Future<Uint8List> Function(Uri uri) fetcher,
    required this.switchBoundaryValidator,
    this.onDecision,
    this.onActiveRendition,
  }) : _fetcher = fetcher;

  final HlsQualityController controller;
  final Future<Uint8List> Function(Uri uri) _fetcher;
  final HlsSwitchBoundaryValidator switchBoundaryValidator;
  final HlsQualityChangeCallback? onDecision;
  final HlsActiveRenditionCallback? onActiveRendition;

  HlsQualityRendition? _activeRendition;
  final Map<int, Completer<void>> _orderedGates = <int, Completer<void>>{};
  final Map<int, HlsQualityRendition> _renditionsBySequence =
      <int, HlsQualityRendition>{};

  HlsQualityRendition? get activeRendition => _activeRendition;

  /// Rendition that supplied the already-committed [mediaSequence].
  ///
  /// The player uses this to keep buffered old-quality access units at their
  /// original display size until the seamless segment-boundary transition is
  /// actually presented.
  HlsQualityRendition? renditionForSequence(int mediaSequence) =>
      _renditionsBySequence[mediaSequence];

  Future<Uint8List> call(Uri requestedUri) async {
    var resolved = controller.resolve(requestedUri);
    if (!resolved.isAdaptiveVideoSegment) return _fetcher(requestedUri);

    var download = await _download(resolved);

    final canonicalIndex = resolved.canonicalIndex!;
    final gate = _orderedGates.putIfAbsent(canonicalIndex, Completer<void>.new);
    if (canonicalIndex > 0) {
      final previousGate = _orderedGates.putIfAbsent(
        canonicalIndex - 1,
        Completer<void>.new,
      );
      await previousGate.future;
    }

    try {
      // Prefetch requests may have started before a manual/automatic quality
      // decision. Re-resolve only after the preceding segment commits; if the
      // target changed, replace those unconsumed bytes now. Playback and the
      // decoder queue continue uninterrupted while this happens.
      final latest = controller.resolve(requestedUri);
      if (!identical(latest.rendition, resolved.rendition)) {
        resolved = latest;
        download = await _download(resolved);
      }

      var target = resolved.rendition!;
      var bytes = download.bytes;
      var elapsed = download.elapsed;
      final active = _activeRendition;
      if (active != null && !identical(active, target)) {
        if (!switchBoundaryValidator(bytes)) {
          // A quality choice must never terminate otherwise-valid playback.
          // Keep this segment on the active rendition and retry the still-
          // pending controller target at the next segment boundary.
          resolved = controller._resolveForRendition(requestedUri, active);
          final fallback = await _download(resolved);
          target = active;
          bytes = fallback.bytes;
          elapsed = fallback.elapsed;
        }
      }
      if (!identical(active, target)) {
        _activeRendition = target;
        onActiveRendition?.call(target);
      }
      _renditionsBySequence[resolved.segment!.sequence] = target;

      final decision = controller.recordDownload(
        byteCount: bytes.length,
        elapsed: elapsed,
      );
      if (decision != null) onDecision?.call(decision);
      return bytes;
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<({Uint8List bytes, Duration elapsed})> _download(
    HlsResolvedQualitySegment resolved,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final bytes = await _fetcher(resolved.fetchUri);
      stopwatch.stop();
      return (bytes: bytes, elapsed: stopwatch.elapsed);
    } catch (_) {
      stopwatch.stop();
      final change = controller.recordNetworkFailure();
      if (change != null) onDecision?.call(change);
      rethrow;
    }
  }
}

List<HlsQualityRendition> _validateAndSortRenditions(
  Iterable<HlsQualityRendition> input,
) {
  final renditions = input.toList(growable: false)
    ..sort((a, b) {
      final aBandwidth = a.bandwidth <= 0 ? 0x7fffffff : a.bandwidth;
      final bBandwidth = b.bandwidth <= 0 ? 0x7fffffff : b.bandwidth;
      final bandwidthOrder = aBandwidth.compareTo(bBandwidth);
      if (bandwidthOrder != 0) return bandwidthOrder;
      return a.variant.uri.toString().compareTo(b.variant.uri.toString());
    });
  if (renditions.isEmpty) {
    throw ArgumentError.value(input, 'renditions', 'must not be empty');
  }
  final canonical = renditions.first.playlist;
  if (!canonical.isEndList || canonical.segments.isEmpty) {
    throw const FormatException(
      'Adaptive quality currently requires a non-empty finalized VOD',
    );
  }
  requireSingleHlsDiscontinuityEpoch(canonical);
  final seenUris = <Uri>{};
  for (final rendition in renditions) {
    if (!seenUris.add(rendition.variant.uri)) {
      throw FormatException(
        'Duplicate HLS quality rendition ${rendition.variant.uri}',
      );
    }
    final playlist = rendition.playlist;
    if (!playlist.isEndList ||
        playlist.segments.length != canonical.segments.length) {
      throw FormatException(
        'HLS quality rendition ${rendition.variant.uri} is not a complete '
        'segment-aligned VOD',
      );
    }
    requireSingleHlsDiscontinuityEpoch(playlist);
    pairHlsVariantSegments(canonical, playlist);
  }
  return List<HlsQualityRendition>.unmodifiable(renditions);
}
