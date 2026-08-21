import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm_source.dart';

export 'pcm_source.dart' show PcmAudioChunk, PcmAudioSource, floatSampleToPcm16;

/// Decoded audio on one monotonic media timeline.
final class PcmAudioTimeline extends PcmAudioSourceBase {
  PcmAudioTimeline({
    required super.sampleRate,
    required super.channels,
    required super.basePtsUs,
    required Int16List interleavedSamples,
  }) : samples = Int16List.fromList(interleavedSamples) {
    _validateSamples();
  }

  PcmAudioTimeline._owned({
    required super.sampleRate,
    required super.channels,
    required super.basePtsUs,
    required this.samples,
  }) {
    _validateSamples();
  }

  final Int16List samples;

  @override
  int get frameCount => samples.length ~/ channels;

  void _validateSamples() {
    if (samples.length % channels != 0) {
      throw ArgumentError(
        'Interleaved sample count ${samples.length} is not divisible by '
        '$channels channels',
      );
    }
  }

  @override
  Future<PcmAudioChunk> readFrames(
    int firstFrame, {
    required int maxFrames,
  }) async {
    final startFrame = validateRead(firstFrame, maxFrames);
    final count = math.min(maxFrames, frameCount - startFrame);
    final firstSample = startFrame * channels;
    final lastSample = (startFrame + count) * channels;
    return PcmAudioChunk.pcm16le(
      startFrame: startFrame,
      frameCount: count,
      pcm16le: pcm16SamplesToLittleEndianBytes(
        samples,
        start: firstSample,
        end: lastSample,
      ),
    );
  }

  @override
  Future<void> dispose() async {}

  Iterable<PcmAudioChunk> chunksFromFrame(
    int firstFrame, {
    int framesPerChunk = 2048,
  }) sync* {
    if (framesPerChunk <= 0) {
      throw ArgumentError.value(framesPerChunk, 'framesPerChunk');
    }
    var frame = firstFrame.clamp(0, frameCount);
    while (frame < frameCount) {
      final count = math.min(framesPerChunk, frameCount - frame);
      final firstSample = frame * channels;
      final lastSample = (frame + count) * channels;
      yield PcmAudioChunk.pcm16le(
        startFrame: frame,
        frameCount: count,
        pcm16le: pcm16SamplesToLittleEndianBytes(
          samples,
          start: firstSample,
          end: lastSample,
        ),
      );
      frame += count;
    }
  }
}

/// Builds a PCM timeline from AAC-sized floating-point frames.
///
/// Explicit timestamps are converted to sample positions. Small gaps become
/// silence and overlaps are trimmed, which keeps the audio playback head a
/// stable media clock even when container timestamps are not perfectly joined.
final class PcmAudioTimelineBuilder {
  PcmAudioTimelineBuilder({
    required this.sampleRate,
    required this.channels,
    this.maxGap = const Duration(seconds: 10),
    int? basePtsUs,
  }) : _basePtsUs = basePtsUs {
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels <= 0) throw ArgumentError.value(channels, 'channels');
    if (maxGap.isNegative) throw ArgumentError.value(maxGap, 'maxGap');
  }

  final int sampleRate;
  final int channels;
  final Duration maxGap;

  final List<Int16List> _chunks = <Int16List>[];
  int _sampleCount = 0;
  int? _basePtsUs;

  int get frameCount => _sampleCount ~/ channels;

  void addFloatFrame(Float32List interleaved, {int? ptsUs}) {
    if (interleaved.length % channels != 0) {
      throw FormatException(
        'PCM frame has ${interleaved.length} samples for $channels channels',
      );
    }

    _basePtsUs ??= ptsUs ?? 0;
    var targetFrame = frameCount;
    if (ptsUs != null) {
      targetFrame =
          ((ptsUs - _basePtsUs!) * sampleRate / Duration.microsecondsPerSecond)
              .round();
    }
    addFloatFrameAtFrame(interleaved, startFrame: targetFrame);
  }

  /// Adds samples at an exact PCM-frame position relative to the timeline.
  ///
  /// This is useful for MP4 edit lists, where converting a negative priming
  /// timestamp to integer microseconds can otherwise leave a one-sample error.
  /// Negative positions are trimmed and [validFrames] can remove end padding.
  void addFloatFrameAtFrame(
    Float32List interleaved, {
    required int startFrame,
    int? validFrames,
  }) {
    if (interleaved.length % channels != 0) {
      throw FormatException(
        'PCM frame has ${interleaved.length} samples for $channels channels',
      );
    }
    _basePtsUs ??= 0;
    final inputFrames = interleaved.length ~/ channels;
    final includedFrames = validFrames ?? inputFrames;
    if (includedFrames < 0 || includedFrames > inputFrames) {
      throw RangeError.range(includedFrames, 0, inputFrames, 'validFrames');
    }

    var skipFrames = 0;
    var targetFrame = startFrame;
    if (targetFrame < 0) {
      skipFrames = math.min(-targetFrame, includedFrames);
      targetFrame = 0;
    }
    final delta = targetFrame - frameCount;
    if (delta > 0) {
      final maxGapFrames =
          maxGap.inMicroseconds * sampleRate ~/ Duration.microsecondsPerSecond;
      if (delta > maxGapFrames) {
        throw FormatException(
          'PCM timestamp gap is $delta frames; limit is $maxGapFrames',
        );
      }
      _appendChunk(Int16List(delta * channels));
    } else if (delta < 0) {
      skipFrames += math.min(-delta, includedFrames - skipFrames);
    }

    final firstSample = skipFrames * channels;
    final lastSample = includedFrames * channels;
    final converted = Int16List(lastSample - firstSample);
    for (var i = firstSample; i < lastSample; i++) {
      converted[i - firstSample] = floatSampleToPcm16(interleaved[i]);
    }
    _appendChunk(converted);
  }

  void _appendChunk(Int16List chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk);
    _sampleCount += chunk.length;
  }

  PcmAudioTimeline build() {
    final flattened = Int16List(_sampleCount);
    var offset = 0;
    for (final chunk in _chunks) {
      flattened.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return PcmAudioTimeline._owned(
      sampleRate: sampleRate,
      channels: channels,
      basePtsUs: _basePtsUs ?? 0,
      samples: flattened,
    );
  }
}
