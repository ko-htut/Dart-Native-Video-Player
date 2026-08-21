import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../mp4/mp4_demux.dart';
import 'aac/adts.dart';
import 'aac/decoder.dart';
import 'pcm_source.dart';
import 'pcm_timeline.dart';

/// Runs MP4 AAC decoding on a worker isolate without capturing widget state.
Future<PcmAudioTimeline> decodeMp4AacToPcmInBackground(
  Uint8List fileBytes,
  Mp4AudioTrack track,
) => Isolate.run(_Mp4AudioDecodeJob(fileBytes, track).call);

/// Runs transport AAC decoding on a worker isolate without capturing the
/// caller's async context, which can contain unsendable Flutter objects.
Future<PcmAudioTimeline> decodeTransportAacToPcmInBackground(
  List<AacAccessUnit> accessUnits, {
  required int originPts90k,
}) => Isolate.run(
  _TransportAudioDecodeJob(
    List<AacAccessUnit>.unmodifiable(accessUnits),
    originPts90k,
  ).call,
);

/// Decodes MP4 AAC on a worker isolate into an owned temporary PCM16LE file.
///
/// The returned source deletes that file when it is disposed. Unlike
/// [decodeMp4AacToPcmInBackground], decoded audio is never flattened into one
/// large Dart-heap allocation.
Future<FilePcmAudioSource> decodeMp4AacToFilePcmInBackground(
  Uint8List fileBytes,
  Mp4AudioTrack track,
) async {
  final descriptor = await Isolate.run(
    _Mp4FileAudioDecodeJob(fileBytes, track).call,
  );
  return descriptor.openSource();
}

/// Decodes timestamped transport AAC into an owned temporary PCM16LE file.
Future<FilePcmAudioSource> decodeTransportAacToFilePcmInBackground(
  List<AacAccessUnit> accessUnits, {
  required int originPts90k,
}) async {
  final descriptor = await Isolate.run(
    _TransportFileAudioDecodeJob(
      List<AacAccessUnit>.unmodifiable(accessUnits),
      originPts90k,
    ).call,
  );
  return descriptor.openSource();
}

/// Decodes one MP4 AAC track entirely in Dart and applies its movie timeline.
///
/// Every compressed sample is decoded, including negative-PTS encoder priming,
/// so AAC overlap state remains correct. PCM before movie time zero and final
/// padding excluded by the sample duration are then trimmed exactly in sample
/// frames, without lossy microsecond conversion.
PcmAudioTimeline decodeMp4AacToPcm(Uint8List fileBytes, Mp4AudioTrack track) {
  final builder = PcmAudioTimelineBuilder(
    sampleRate: track.sampleRate,
    channels: track.channelCount,
    basePtsUs: 0,
  );
  _decodeMp4Frames(fileBytes, track, builder.addFloatFrameAtFrame);
  return builder.build();
}

/// Synchronous counterpart to [decodeMp4AacToFilePcmInBackground].
///
/// This is intended for worker isolates and deterministic tests. UI callers
/// should use the background entrypoint.
FilePcmAudioSource decodeMp4AacToFilePcm(
  Uint8List fileBytes,
  Mp4AudioTrack track,
) {
  final builder = FilePcmAudioSourceBuilder(
    sampleRate: track.sampleRate,
    channels: track.channelCount,
    basePtsUs: 0,
  );
  try {
    _decodeMp4Frames(fileBytes, track, builder.addFloatFrameAtFrame);
    return builder.build();
  } catch (_) {
    builder.abort();
    rethrow;
  }
}

/// Decodes timestamped raw AAC access units extracted from MPEG-TS/ADTS.
///
/// [originPts90k] must be the same unwrapped MPEG clock origin used by the
/// video access-unit queue. Missing audio PTS continues from the prior frame.
PcmAudioTimeline decodeTransportAacToPcm(
  List<AacAccessUnit> accessUnits, {
  required int originPts90k,
}) {
  if (accessUnits.isEmpty) {
    throw const FormatException('No AAC access units to decode');
  }
  final first = accessUnits.first;
  final builder = PcmAudioTimelineBuilder(
    sampleRate: first.config.samplingFrequency,
    channels: first.config.channelConfiguration,
    basePtsUs: 0,
  );
  _decodeTransportFrames(
    accessUnits,
    originPts90k: originPts90k,
    frameCount: () => builder.frameCount,
    addFrame: builder.addFloatFrameAtFrame,
  );
  return builder.build();
}

/// Synchronous counterpart to [decodeTransportAacToFilePcmInBackground].
FilePcmAudioSource decodeTransportAacToFilePcm(
  List<AacAccessUnit> accessUnits, {
  required int originPts90k,
}) {
  if (accessUnits.isEmpty) {
    throw const FormatException('No AAC access units to decode');
  }
  final first = accessUnits.first;
  final builder = FilePcmAudioSourceBuilder(
    sampleRate: first.config.samplingFrequency,
    channels: first.config.channelConfiguration,
    basePtsUs: 0,
  );
  try {
    _decodeTransportFrames(
      accessUnits,
      originPts90k: originPts90k,
      frameCount: () => builder.frameCount,
      addFrame: builder.addFloatFrameAtFrame,
    );
    return builder.build();
  } catch (_) {
    builder.abort();
    rethrow;
  }
}

void _decodeMp4Frames(
  Uint8List fileBytes,
  Mp4AudioTrack track,
  void Function(
    Float32List samples, {
    required int startFrame,
    int? validFrames,
  })
  addFrame,
) {
  final decoder = AacLcDecoder(track.config);
  for (var index = 0; index < track.sampleSizes.length; index++) {
    final decoded = decoder.decodeRawAccessUnit(
      Mp4Demux.readAudioSample(fileBytes, track, index),
      pts90k: _scaleTimestamp(track.pts[index], track.timescale, 90000),
    );
    final startFrame = _scaleTimestamp(
      track.pts[index],
      track.timescale,
      track.sampleRate,
    );
    final declaredFrames = _scaleTimestamp(
      track.sampleDurations[index],
      track.timescale,
      track.sampleRate,
    );
    addFrame(
      decoded.samples,
      startFrame: startFrame,
      validFrames: math.min(decoded.samplesPerChannel, declaredFrames),
    );
  }
}

void _decodeTransportFrames(
  List<AacAccessUnit> accessUnits, {
  required int originPts90k,
  required int Function() frameCount,
  required void Function(
    Float32List samples, {
    required int startFrame,
    int? validFrames,
  })
  addFrame,
}) {
  if (accessUnits.isEmpty) {
    throw const FormatException('No AAC access units to decode');
  }
  final first = accessUnits.first;
  final decoder = AacLcDecoder(first.config);
  final firstAnchoredPts = accessUnits
      .map((accessUnit) => accessUnit.pts90k)
      .whereType<int>()
      .firstOrNull;
  final epochOffset = firstAnchoredPts == null
      ? 0
      : _nearestMpegEpochOffset(firstAnchoredPts, originPts90k);

  for (final accessUnit in accessUnits) {
    final decoded = decoder.decode(accessUnit);
    final pts = accessUnit.pts90k;
    final startFrame = pts == null
        ? frameCount()
        : _scaleTimestamp(
            pts + epochOffset - originPts90k,
            90000,
            decoded.sampleRate,
          );
    addFrame(
      decoded.samples,
      startFrame: startFrame,
      validFrames: decoded.samplesPerChannel,
    );
  }
}

const int _mpegPtsModulus = 1 << 33;

/// Maps an independently unwrapped PTS series to the epoch nearest the other
/// stream's origin. Audio and video parsers can each begin on opposite sides
/// of the 33-bit rollover, even though their timestamps are only milliseconds
/// apart on the shared transport clock.
int _nearestMpegEpochOffset(int firstPts90k, int originPts90k) {
  final delta = originPts90k - firstPts90k;
  final half = _mpegPtsModulus ~/ 2;
  final epochs = delta >= 0
      ? (delta + half) ~/ _mpegPtsModulus
      : -((-delta + half) ~/ _mpegPtsModulus);
  return epochs * _mpegPtsModulus;
}

int _scaleTimestamp(int value, int sourceTimescale, int targetTimescale) {
  if (sourceTimescale <= 0 || targetTimescale <= 0) {
    throw ArgumentError('Timestamp scales must be positive');
  }
  final product = value * targetTimescale;
  if (product >= 0) {
    return (product + sourceTimescale ~/ 2) ~/ sourceTimescale;
  }
  return -((-product + sourceTimescale ~/ 2) ~/ sourceTimescale);
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

final class _Mp4AudioDecodeJob {
  const _Mp4AudioDecodeJob(this.fileBytes, this.track);

  final Uint8List fileBytes;
  final Mp4AudioTrack track;

  PcmAudioTimeline call() => decodeMp4AacToPcm(fileBytes, track);
}

final class _TransportAudioDecodeJob {
  const _TransportAudioDecodeJob(this.accessUnits, this.originPts90k);

  final List<AacAccessUnit> accessUnits;
  final int originPts90k;

  PcmAudioTimeline call() =>
      decodeTransportAacToPcm(accessUnits, originPts90k: originPts90k);
}

final class _Mp4FileAudioDecodeJob {
  const _Mp4FileAudioDecodeJob(this.fileBytes, this.track);

  final Uint8List fileBytes;
  final Mp4AudioTrack track;

  _FilePcmDescriptor call() =>
      _FilePcmDescriptor.fromSource(decodeMp4AacToFilePcm(fileBytes, track));
}

final class _TransportFileAudioDecodeJob {
  const _TransportFileAudioDecodeJob(this.accessUnits, this.originPts90k);

  final List<AacAccessUnit> accessUnits;
  final int originPts90k;

  _FilePcmDescriptor call() => _FilePcmDescriptor.fromSource(
    decodeTransportAacToFilePcm(accessUnits, originPts90k: originPts90k),
  );
}

final class _FilePcmDescriptor {
  const _FilePcmDescriptor({
    required this.filePath,
    required this.ownedDirectoryPath,
    required this.sampleRate,
    required this.channels,
    required this.basePtsUs,
    required this.frameCount,
  });

  factory _FilePcmDescriptor.fromSource(FilePcmAudioSource source) {
    final directory = source.ownedDirectoryPath;
    if (directory == null) {
      throw StateError('Decoded PCM source does not own its temporary file');
    }
    return _FilePcmDescriptor(
      filePath: source.filePath,
      ownedDirectoryPath: directory,
      sampleRate: source.sampleRate,
      channels: source.channels,
      basePtsUs: source.basePtsUs,
      frameCount: source.frameCount,
    );
  }

  final String filePath;
  final String ownedDirectoryPath;
  final int sampleRate;
  final int channels;
  final int basePtsUs;
  final int frameCount;

  FilePcmAudioSource openSource() => FilePcmAudioSource.ownedTemp(
    filePath: filePath,
    ownedDirectoryPath: ownedDirectoryPath,
    sampleRate: sampleRate,
    channels: channels,
    basePtsUs: basePtsUs,
    frameCount: frameCount,
  );
}
