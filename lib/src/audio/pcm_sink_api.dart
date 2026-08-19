import 'dart:typed_data';

/// PCM encodings accepted by [PcmAudioSink].
enum PcmSampleFormat { signedInt16LittleEndian }

enum PcmSinkState { unconfigured, paused, playing, disposed }

/// Interleaved PCM format passed to the native speaker sink.
final class PcmAudioFormat {
  PcmAudioFormat({
    required this.sampleRate,
    required this.channelCount,
    this.sampleFormat = PcmSampleFormat.signedInt16LittleEndian,
  }) {
    if (sampleRate < 8000 || sampleRate > 192000) {
      throw RangeError.range(sampleRate, 8000, 192000, 'sampleRate');
    }
    if (channelCount < 1 || channelCount > 8) {
      throw RangeError.range(channelCount, 1, 8, 'channelCount');
    }
  }

  final int sampleRate;
  final int channelCount;
  final PcmSampleFormat sampleFormat;

  int get bytesPerSample => switch (sampleFormat) {
    PcmSampleFormat.signedInt16LittleEndian => 2,
  };

  int get bytesPerFrame => bytesPerSample * channelCount;

  @override
  bool operator ==(Object other) =>
      other is PcmAudioFormat &&
      other.sampleRate == sampleRate &&
      other.channelCount == channelCount &&
      other.sampleFormat == sampleFormat;

  @override
  int get hashCode => Object.hash(sampleRate, channelCount, sampleFormat);

  @override
  String toString() =>
      'PcmAudioFormat(${sampleRate}Hz, $channelCount channels, '
      '${sampleFormat.name})';
}

final class PcmPlaybackPosition {
  const PcmPlaybackPosition({
    required this.generation,
    required this.frames,
    required this.sampleRate,
  });

  final int generation;
  final int frames;
  final int sampleRate;

  Duration get mediaDuration => Duration(
    microseconds: (frames * Duration.microsecondsPerSecond) ~/ sampleRate,
  );
}

enum PcmSinkEventType { stateChanged, bufferConsumed, underrun, error }

final class PcmSinkEvent {
  const PcmSinkEvent({
    required this.type,
    required this.generation,
    this.frames = 0,
    this.message,
  });

  final PcmSinkEventType type;
  final int generation;
  final int frames;
  final String? message;
}

/// A bounded speaker sink for decoded, interleaved PCM.
///
/// [enqueue] completes only after the platform output queue accepts the bytes.
/// Callers should await it to inherit the sink's backpressure. A successful
/// [flush] discards queued audio, changes [generation], and resets [position]
/// to frame zero. Writes from an older generation are rejected.
abstract interface class PcmAudioSink {
  PcmAudioFormat? get format;
  int get generation;
  PcmSinkState get state;
  Stream<PcmSinkEvent> get events;

  Future<void> configure(PcmAudioFormat format, {required int generation});

  Future<int> enqueue(Uint8List interleavedPcm, {required int generation});

  Future<void> play();
  Future<void> pause();

  Future<void> flush({required int generation});

  Future<PcmPlaybackPosition> position();
  Future<void> dispose();
}

final class PcmSinkStateException implements Exception {
  const PcmSinkStateException(this.message);

  final String message;

  @override
  String toString() => 'PcmSinkStateException: $message';
}

void validatePcmWrite(
  PcmAudioFormat? format,
  PcmSinkState state,
  int activeGeneration,
  Uint8List bytes,
  int writeGeneration,
) {
  if (state == PcmSinkState.disposed) {
    throw const PcmSinkStateException('sink has been disposed');
  }
  if (format == null || state == PcmSinkState.unconfigured) {
    throw const PcmSinkStateException('sink is not configured');
  }
  if (writeGeneration != activeGeneration) {
    throw PcmSinkStateException(
      'stale PCM generation $writeGeneration; active generation is '
      '$activeGeneration',
    );
  }
  if (bytes.lengthInBytes % format.bytesPerFrame != 0) {
    throw ArgumentError.value(
      bytes.lengthInBytes,
      'interleavedPcm.lengthInBytes',
      'must be a whole number of ${format.bytesPerFrame}-byte PCM frames',
    );
  }
}
