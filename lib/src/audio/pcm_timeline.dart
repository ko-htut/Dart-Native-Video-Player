import 'dart:math' as math;
import 'dart:typed_data';

/// A bounded packet of signed, interleaved, little-endian-ready PCM16.
final class PcmAudioChunk {
  const PcmAudioChunk({
    required this.startFrame,
    required this.frameCount,
    required this.samples,
  });

  final int startFrame;
  final int frameCount;
  final Int16List samples;
}

/// Decoded audio on one monotonic media timeline.
final class PcmAudioTimeline {
  PcmAudioTimeline({
    required this.sampleRate,
    required this.channels,
    required this.basePtsUs,
    required Int16List interleavedSamples,
  }) : samples = Int16List.fromList(interleavedSamples) {
    _validate();
  }

  PcmAudioTimeline._owned({
    required this.sampleRate,
    required this.channels,
    required this.basePtsUs,
    required this.samples,
  }) {
    _validate();
  }

  void _validate() {
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels <= 0) throw ArgumentError.value(channels, 'channels');
    if (samples.length % channels != 0) {
      throw ArgumentError(
        'Interleaved sample count ${samples.length} is not divisible by '
        '$channels channels',
      );
    }
  }

  final int sampleRate;
  final int channels;
  final int basePtsUs;
  final Int16List samples;

  int get frameCount => samples.length ~/ channels;
  int get durationUs =>
      frameCount * Duration.microsecondsPerSecond ~/ sampleRate;
  int get endPtsUs => basePtsUs + durationUs;

  int mediaTimeUsForFrame(int frame) {
    final bounded = frame.clamp(0, frameCount);
    return basePtsUs + bounded * Duration.microsecondsPerSecond ~/ sampleRate;
  }

  int frameForMediaTimeUs(int mediaTimeUs) {
    if (mediaTimeUs <= basePtsUs) return 0;
    if (mediaTimeUs >= endPtsUs) return frameCount;
    return ((mediaTimeUs - basePtsUs) *
            sampleRate ~/
            Duration.microsecondsPerSecond)
        .clamp(0, frameCount);
  }

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
      yield PcmAudioChunk(
        startFrame: frame,
        frameCount: count,
        samples: Int16List.fromList(samples.sublist(firstSample, lastSample)),
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

int floatSampleToPcm16(double sample) {
  if (!sample.isFinite) return 0;
  if (sample <= -1.0) return -32768;
  if (sample >= 1.0) return 32767;
  return (sample * 32768.0).round().clamp(-32768, 32767);
}
