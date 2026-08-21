import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// A bounded packet of signed, interleaved PCM16 little-endian audio.
final class PcmAudioChunk {
  PcmAudioChunk({
    required this.startFrame,
    required this.frameCount,
    required Int16List samples,
  }) : pcm16le = pcm16SamplesToLittleEndianBytes(samples) {
    _validate();
  }

  PcmAudioChunk.pcm16le({
    required this.startFrame,
    required this.frameCount,
    required this.pcm16le,
  }) {
    _validate();
  }

  final int startFrame;
  final int frameCount;
  final Uint8List pcm16le;

  /// Decodes [pcm16le] for diagnostics and timeline compatibility.
  ///
  /// Playback should pass [pcm16le] directly to the sink so a file-backed
  /// source does not allocate and then re-encode a second sample buffer.
  Int16List get samples {
    final values = Int16List(pcm16le.lengthInBytes ~/ 2);
    final data = ByteData.sublistView(pcm16le);
    for (var index = 0; index < values.length; index++) {
      values[index] = data.getInt16(index * 2, Endian.little);
    }
    return values;
  }

  void _validate() {
    if (startFrame < 0) {
      throw ArgumentError.value(startFrame, 'startFrame');
    }
    if (frameCount < 0) {
      throw ArgumentError.value(frameCount, 'frameCount');
    }
    if (pcm16le.lengthInBytes.isOdd) {
      throw ArgumentError.value(
        pcm16le.lengthInBytes,
        'pcm16le.lengthInBytes',
        'must contain complete PCM16 samples',
      );
    }
  }
}

/// Random-access decoded audio with one monotonic media timeline.
///
/// A source owns any storage behind [readFrames]. Callers must invoke
/// [dispose] when replacing it. Reads are bounded by [maxFrames] and may
/// return fewer frames at end-of-file.
abstract interface class PcmAudioSource {
  int get sampleRate;
  int get channels;
  int get basePtsUs;
  int get frameCount;
  int get durationUs;
  int get endPtsUs;

  int mediaTimeUsForFrame(int frame);
  int frameForMediaTimeUs(int mediaTimeUs);

  Future<PcmAudioChunk> readFrames(int firstFrame, {required int maxFrames});

  Future<void> dispose();
}

/// Lifecycle of a PCM source whose committed prefix can grow over time.
enum GrowingPcmAudioState { open, sealed, failed, disposed }

/// A producer-side change to a [GrowingPcmAudioSource].
final class GrowingPcmAudioUpdate {
  const GrowingPcmAudioUpdate({
    required this.frameCount,
    required this.state,
    this.firstAvailableFrame = 0,
    this.error,
  });

  /// Absolute exclusive end of the committed media timeline.
  final int frameCount;

  /// Absolute first frame that remains readable after bounded eviction.
  final int firstAvailableFrame;
  final GrowingPcmAudioState state;
  final Object? error;
}

/// A random-access PCM source with a monotonically growing committed prefix.
///
/// A read at the temporary tail waits for more committed frames. It returns an
/// empty chunk only at a sealed tail, and throws at a failed or disposed tail.
/// Existing fixed [PcmAudioSource] implementations retain their exact EOF
/// behavior and do not need to implement this interface.
abstract interface class GrowingPcmAudioSource implements PcmAudioSource {
  GrowingPcmAudioState get state;
  bool get isSealed;
  Object? get terminalError;
  Stream<GrowingPcmAudioUpdate> get updates;

  /// Waits until at least [minimumFrames] have been committed.
  ///
  /// Throws when the source seals below that threshold, fails, or is disposed.
  Future<void> waitForFrameCount(int minimumFrames);
}

/// A growing source whose readable prefix may move forward after eviction.
///
/// Frame indices remain absolute for the lifetime of the source. In
/// particular, [PcmAudioSource.frameCount] is the exclusive committed end and
/// never decreases when old storage is reclaimed. Callers must not interpret
/// it as the number of currently retained frames.
abstract interface class WindowedGrowingPcmAudioSource
    implements GrowingPcmAudioSource {
  int get firstAvailableFrame;
  int get retainedFrameCount;
  int get firstAvailablePtsUs;
}

/// A read or seek requested media that has left a bounded PCM window.
///
/// This is deliberately an error instead of silently clamping. A playback
/// controller can invalidate the affected sink generation rather than joining
/// old queued audio to unrelated newer PCM.
final class PcmFramesEvictedException implements Exception {
  const PcmFramesEvictedException({
    required this.requestedFrame,
    required this.firstAvailableFrame,
    required this.endFrame,
  });

  final int requestedFrame;
  final int firstAvailableFrame;
  final int endFrame;

  @override
  String toString() =>
      'PcmFramesEvictedException: frame $requestedFrame is no longer '
      'available; retained range is [$firstAvailableFrame, $endFrame)';
}

/// Shared format validation and integer-exact media-time mapping.
abstract base class PcmAudioSourceBase implements PcmAudioSource {
  PcmAudioSourceBase({
    required this.sampleRate,
    required this.channels,
    required this.basePtsUs,
  }) {
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels <= 0) throw ArgumentError.value(channels, 'channels');
  }

  @override
  final int sampleRate;

  @override
  final int channels;

  @override
  final int basePtsUs;

  @override
  int get durationUs =>
      frameCount * Duration.microsecondsPerSecond ~/ sampleRate;

  @override
  int get endPtsUs => basePtsUs + durationUs;

  @override
  int mediaTimeUsForFrame(int frame) {
    final bounded = frame.clamp(0, frameCount);
    return basePtsUs + bounded * Duration.microsecondsPerSecond ~/ sampleRate;
  }

  @override
  int frameForMediaTimeUs(int mediaTimeUs) {
    if (mediaTimeUs <= basePtsUs) return 0;
    if (mediaTimeUs >= endPtsUs) return frameCount;
    return ((mediaTimeUs - basePtsUs) *
            sampleRate ~/
            Duration.microsecondsPerSecond)
        .clamp(0, frameCount);
  }

  int validateRead(int firstFrame, int maxFrames) {
    if (maxFrames <= 0) {
      throw ArgumentError.value(maxFrames, 'maxFrames');
    }
    return firstFrame.clamp(0, frameCount);
  }
}

/// Random-access PCM16LE stored in a file instead of the Dart heap.
///
/// Reads through one lazily opened handle are serialized, so seek/replay can
/// safely issue a new read while a prior playback generation is winding down.
final class FilePcmAudioSource extends PcmAudioSourceBase {
  FilePcmAudioSource.open({
    required this.filePath,
    required super.sampleRate,
    required super.channels,
    required super.basePtsUs,
    required this.frameCount,
  }) : _ownedDirectoryPath = null {
    _validateFrameCount();
  }

  factory FilePcmAudioSource.ownedTemp({
    required String filePath,
    required String ownedDirectoryPath,
    required int sampleRate,
    required int channels,
    required int basePtsUs,
    required int frameCount,
  }) {
    _validateOwnedTempPaths(filePath, ownedDirectoryPath);
    return FilePcmAudioSource._ownedTemp(
      filePath: filePath,
      ownedDirectoryPath: ownedDirectoryPath,
      sampleRate: sampleRate,
      channels: channels,
      basePtsUs: basePtsUs,
      frameCount: frameCount,
    );
  }

  FilePcmAudioSource._ownedTemp({
    required this.filePath,
    required String ownedDirectoryPath,
    required super.sampleRate,
    required super.channels,
    required super.basePtsUs,
    required this.frameCount,
  }) : _ownedDirectoryPath = ownedDirectoryPath {
    _validateFrameCount();
  }

  final String filePath;
  final String? _ownedDirectoryPath;

  @override
  final int frameCount;

  RandomAccessFile? _reader;
  Future<void> _operationTail = Future<void>.value();
  bool _disposed = false;

  bool get ownsFile => _ownedDirectoryPath != null;
  String? get ownedDirectoryPath => _ownedDirectoryPath;
  bool get isDisposed => _disposed;

  void _validateFrameCount() {
    if (frameCount < 0) throw ArgumentError.value(frameCount, 'frameCount');
  }

  @override
  Future<PcmAudioChunk> readFrames(int firstFrame, {required int maxFrames}) {
    if (_disposed) {
      return Future<PcmAudioChunk>.error(
        StateError('PCM audio source is disposed'),
      );
    }
    final startFrame = validateRead(firstFrame, maxFrames);
    final result = _operationTail.then((_) async {
      if (_disposed) throw StateError('PCM audio source is disposed');
      final count = math.min(maxFrames, frameCount - startFrame);
      if (count == 0) {
        return PcmAudioChunk.pcm16le(
          startFrame: startFrame,
          frameCount: 0,
          pcm16le: Uint8List(0),
        );
      }

      final bytesPerFrame = channels * 2;
      final expectedBytes = count * bytesPerFrame;
      final reader = _reader ??= await File(filePath).open();
      await reader.setPosition(startFrame * bytesPerFrame);
      final bytes = await reader.read(expectedBytes);
      if (bytes.lengthInBytes != expectedBytes) {
        throw FileSystemException(
          'PCM file ended during a $count-frame read '
          '(${bytes.lengthInBytes} of $expectedBytes bytes)',
          filePath,
        );
      }
      return PcmAudioChunk.pcm16le(
        startFrame: startFrame,
        frameCount: count,
        pcm16le: bytes,
      );
    });
    _operationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _operationTail;
    final reader = _reader;
    _reader = null;
    if (reader != null) await reader.close();

    final ownedDirectoryPath = _ownedDirectoryPath;
    if (ownedDirectoryPath == null) return;
    final fileType = await FileSystemEntity.type(filePath, followLinks: false);
    if (fileType == FileSystemEntityType.file) {
      await File(filePath).delete();
    }
    final directory = Directory(ownedDirectoryPath);
    final directoryType = await FileSystemEntity.type(
      ownedDirectoryPath,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.directory) {
      // This is deliberately non-recursive. The validated directory is unique
      // and must contain only audio.pcm; unexpected contents are not ours.
      await directory.delete();
    }
  }
}

/// A producer-owned temporary PCM16LE file exposed as a growing audio source.
///
/// [frameCount] is advanced only after all bytes for an append have been
/// written. Appends use the same gap filling, negative-PTS trimming, and
/// overlap trimming rules as [FilePcmAudioSourceBuilder]. Calls are expected
/// from one isolate and are synchronous so one append is committed atomically.
///
/// Loading this source into `AudioPlaybackController` transfers storage
/// ownership to that controller. Producer shutdown should call [fail] or
/// [seal], not [dispose]; disposing both sides remains safe and idempotent.
final class GrowingFilePcmAudioSource extends PcmAudioSourceBase
    implements WindowedGrowingPcmAudioSource {
  factory GrowingFilePcmAudioSource.create({
    required int sampleRate,
    required int channels,
    Duration maxGap = const Duration(seconds: 10),
    int basePtsUs = 0,
    Duration? maxRetainedDuration,
    int? maxRetainedBytes,
  }) {
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels <= 0) throw ArgumentError.value(channels, 'channels');
    if (maxGap.isNegative) throw ArgumentError.value(maxGap, 'maxGap');
    if (maxRetainedDuration != null && maxRetainedDuration <= Duration.zero) {
      throw ArgumentError.value(
        maxRetainedDuration,
        'maxRetainedDuration',
        'must be positive',
      );
    }
    final bytesPerFrame = channels * 2;
    if (maxRetainedBytes != null && maxRetainedBytes < bytesPerFrame) {
      throw ArgumentError.value(
        maxRetainedBytes,
        'maxRetainedBytes',
        'must hold at least one complete $bytesPerFrame-byte PCM frame',
      );
    }
    final durationCapacity = maxRetainedDuration == null
        ? null
        : math.max(
            1,
            maxRetainedDuration.inMicroseconds *
                sampleRate ~/
                Duration.microsecondsPerSecond,
          );
    final byteCapacity = maxRetainedBytes == null
        ? null
        : maxRetainedBytes ~/ bytesPerFrame;
    final capacityFrames = switch ((durationCapacity, byteCapacity)) {
      (final int duration, final int bytes) => math.min(duration, bytes),
      (final int duration, null) => duration,
      (null, final int bytes) => bytes,
      (null, null) => null,
    };

    final directory = Directory.systemTemp.createTempSync('ndvy_pcm_');
    final file = File('${directory.path}/audio.pcm');
    try {
      return GrowingFilePcmAudioSource._(
        sampleRate: sampleRate,
        channels: channels,
        basePtsUs: basePtsUs,
        maxGap: maxGap,
        maxRetainedDuration: maxRetainedDuration,
        maxRetainedBytes: maxRetainedBytes,
        capacityFrames: capacityFrames,
        directory: directory,
        file: file,
        writer: file.openSync(mode: FileMode.writeOnly),
      );
    } catch (_) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  GrowingFilePcmAudioSource._({
    required super.sampleRate,
    required super.channels,
    required super.basePtsUs,
    required this.maxGap,
    required this.maxRetainedDuration,
    required this.maxRetainedBytes,
    required int? capacityFrames,
    required Directory directory,
    required File file,
    required RandomAccessFile writer,
  }) : _capacityFrames = capacityFrames,
       _directory = directory,
       _file = file,
       _writer = writer;

  final Duration maxGap;

  /// Requested time retention limit, or `null` for no time-based limit.
  final Duration? maxRetainedDuration;

  /// Requested byte retention limit, or `null` for no byte-based limit.
  ///
  /// The effective file capacity is rounded down to a complete PCM frame and
  /// may be smaller when [maxRetainedDuration] is also supplied.
  final int? maxRetainedBytes;
  final int? _capacityFrames;
  final Directory _directory;
  final File _file;
  final StreamController<GrowingPcmAudioUpdate> _updates =
      StreamController<GrowingPcmAudioUpdate>.broadcast(sync: true);

  RandomAccessFile? _writer;
  RandomAccessFile? _reader;
  Future<void> _readOperationTail = Future<void>.value();
  Completer<void> _changed = Completer<void>();
  int _frameCount = 0;
  GrowingPcmAudioState _state = GrowingPcmAudioState.open;
  Object? _terminalError;
  StackTrace? _terminalStackTrace;
  Future<void>? _disposeFuture;

  String get filePath => _file.path;
  String get ownedDirectoryPath => _directory.path;

  bool get isBounded => _capacityFrames != null;
  int? get capacityFrames => _capacityFrames;
  int? get capacityBytes =>
      _capacityFrames == null ? null : _capacityFrames * channels * 2;

  @override
  int get frameCount => _frameCount;

  @override
  int get firstAvailableFrame {
    final capacity = _capacityFrames;
    return capacity == null ? 0 : math.max(0, frameCount - capacity);
  }

  @override
  int get retainedFrameCount => frameCount - firstAvailableFrame;

  @override
  int get firstAvailablePtsUs => mediaTimeUsForFrame(firstAvailableFrame);

  @override
  GrowingPcmAudioState get state => _state;

  @override
  bool get isSealed => _state == GrowingPcmAudioState.sealed;

  @override
  Object? get terminalError => _terminalError;

  @override
  Stream<GrowingPcmAudioUpdate> get updates => _updates.stream;

  void appendFloatFrame(Float32List interleaved, {int? ptsUs}) {
    var targetFrame = frameCount;
    if (ptsUs != null) {
      targetFrame =
          ((ptsUs - basePtsUs) * sampleRate / Duration.microsecondsPerSecond)
              .round();
    }
    appendFloatFrameAtFrame(interleaved, startFrame: targetFrame);
  }

  void appendFloatFrameAtFrame(
    Float32List interleaved, {
    required int startFrame,
    int? validFrames,
  }) {
    _ensureOpen();
    if (interleaved.length % channels != 0) {
      throw FormatException(
        'PCM frame has ${interleaved.length} samples for $channels channels',
      );
    }
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
      _writeSilence(delta);
    } else if (delta < 0) {
      skipFrames += math.min(-delta, includedFrames - skipFrames);
    }

    final firstSample = skipFrames * channels;
    final lastSample = includedFrames * channels;
    if (lastSample > firstSample) {
      final bytes = Uint8List((lastSample - firstSample) * 2);
      final data = ByteData.sublistView(bytes);
      for (var index = firstSample; index < lastSample; index++) {
        data.setInt16(
          (index - firstSample) * 2,
          floatSampleToPcm16(interleaved[index]),
          Endian.little,
        );
      }
      final appendedFrames = (lastSample - firstSample) ~/ channels;
      _writePcmBytes(bytes, startFrame: _frameCount);
      _frameCount += appendedFrames;
    }
    _signalChange();
  }

  @override
  Future<PcmAudioChunk> readFrames(
    int firstFrame, {
    required int maxFrames,
  }) async {
    if (maxFrames <= 0) {
      throw ArgumentError.value(maxFrames, 'maxFrames');
    }
    final requestedStart = math.max(0, firstFrame);

    while (true) {
      if (_state == GrowingPcmAudioState.disposed) {
        throw StateError('PCM audio source is disposed');
      }
      final availableStart = firstAvailableFrame;
      if (requestedStart < availableStart) {
        throw PcmFramesEvictedException(
          requestedFrame: requestedStart,
          firstAvailableFrame: availableStart,
          endFrame: frameCount,
        );
      }
      final committedFrames = frameCount;
      if (requestedStart < committedFrames) {
        final count = math.min(maxFrames, committedFrames - requestedStart);
        return _readCommitted(requestedStart, count);
      }
      switch (_state) {
        case GrowingPcmAudioState.open:
          final changed = _changed.future;
          await changed;
        case GrowingPcmAudioState.sealed:
          return PcmAudioChunk.pcm16le(
            startFrame: math.min(requestedStart, frameCount),
            frameCount: 0,
            pcm16le: Uint8List(0),
          );
        case GrowingPcmAudioState.failed:
          Error.throwWithStackTrace(
            _terminalError ?? StateError('PCM producer failed'),
            _terminalStackTrace ?? StackTrace.current,
          );
        case GrowingPcmAudioState.disposed:
          throw StateError('PCM audio source is disposed');
      }
    }
  }

  Future<PcmAudioChunk> _readCommitted(int startFrame, int count) {
    if (_capacityFrames != null) {
      return Future<PcmAudioChunk>.sync(
        () => _readBoundedCommitted(startFrame, count),
      );
    }
    final result = _readOperationTail.then((_) async {
      if (_state == GrowingPcmAudioState.disposed) {
        throw StateError('PCM audio source is disposed');
      }
      final bytesPerFrame = channels * 2;
      final expectedBytes = count * bytesPerFrame;
      final reader = _reader ??= await _file.open();
      await reader.setPosition(startFrame * bytesPerFrame);
      final bytes = await reader.read(expectedBytes);
      if (bytes.lengthInBytes != expectedBytes) {
        throw FileSystemException(
          'PCM file ended during a $count-frame read '
          '(${bytes.lengthInBytes} of $expectedBytes bytes)',
          filePath,
        );
      }
      return PcmAudioChunk.pcm16le(
        startFrame: startFrame,
        frameCount: count,
        pcm16le: bytes,
      );
    });
    _readOperationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  PcmAudioChunk _readBoundedCommitted(int startFrame, int count) {
    if (_state == GrowingPcmAudioState.disposed) {
      throw StateError('PCM audio source is disposed');
    }
    final availableStart = firstAvailableFrame;
    if (startFrame < availableStart) {
      throw PcmFramesEvictedException(
        requestedFrame: startFrame,
        firstAvailableFrame: availableStart,
        endFrame: frameCount,
      );
    }
    if (startFrame + count > frameCount) {
      throw StateError(
        'PCM read [$startFrame, ${startFrame + count}) exceeds committed '
        'end $frameCount',
      );
    }

    final bytesPerFrame = channels * 2;
    final capacityFrames = _capacityFrames!;
    final capacityBytes = capacityFrames * bytesPerFrame;
    final expectedBytes = count * bytesPerFrame;
    final output = Uint8List(expectedBytes);
    final reader = _reader ??= _file.openSync();
    var outputOffset = 0;
    var physicalOffset = (startFrame % capacityFrames) * bytesPerFrame;
    while (outputOffset < expectedBytes) {
      final readable = math.min(
        expectedBytes - outputOffset,
        capacityBytes - physicalOffset,
      );
      reader.setPositionSync(physicalOffset);
      final bytes = reader.readSync(readable);
      if (bytes.lengthInBytes != readable) {
        throw FileSystemException(
          'Bounded PCM file ended during a $count-frame read '
          '(${outputOffset + bytes.lengthInBytes} of $expectedBytes bytes)',
          filePath,
        );
      }
      output.setRange(outputOffset, outputOffset + readable, bytes);
      outputOffset += readable;
      physicalOffset = 0;
    }
    return PcmAudioChunk.pcm16le(
      startFrame: startFrame,
      frameCount: count,
      pcm16le: output,
    );
  }

  @override
  Future<void> waitForFrameCount(int minimumFrames) async {
    if (minimumFrames < 0) {
      throw ArgumentError.value(minimumFrames, 'minimumFrames');
    }
    while (frameCount < minimumFrames) {
      switch (_state) {
        case GrowingPcmAudioState.open:
          final changed = _changed.future;
          await changed;
        case GrowingPcmAudioState.sealed:
          throw StateError(
            'PCM source sealed at $frameCount frames before the '
            '$minimumFrames-frame threshold',
          );
        case GrowingPcmAudioState.failed:
          Error.throwWithStackTrace(
            _terminalError ?? StateError('PCM producer failed'),
            _terminalStackTrace ?? StackTrace.current,
          );
        case GrowingPcmAudioState.disposed:
          throw StateError('PCM audio source is disposed');
      }
    }
  }

  void seal() {
    if (_state == GrowingPcmAudioState.sealed ||
        _state == GrowingPcmAudioState.disposed) {
      return;
    }
    if (_state == GrowingPcmAudioState.failed) return;
    _writer?.closeSync();
    _writer = null;
    _state = GrowingPcmAudioState.sealed;
    _signalChange();
  }

  void fail(Object error, [StackTrace? stackTrace]) {
    if (_state != GrowingPcmAudioState.open) return;
    _writer?.closeSync();
    _writer = null;
    _terminalError = error;
    _terminalStackTrace = stackTrace;
    _state = GrowingPcmAudioState.failed;
    _signalChange();
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeOnce();

  Future<void> _disposeOnce() async {
    _state = GrowingPcmAudioState.disposed;
    Object? firstError;
    StackTrace? firstStackTrace;
    void remember(Object error, StackTrace stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    try {
      _signalChange();
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    try {
      _writer?.closeSync();
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    } finally {
      _writer = null;
    }
    try {
      await _readOperationTail;
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    final reader = _reader;
    _reader = null;
    try {
      if (reader != null) await reader.close();
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    try {
      final fileType = await FileSystemEntity.type(
        filePath,
        followLinks: false,
      );
      if (fileType == FileSystemEntityType.file) await _file.delete();
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    try {
      final directoryType = await FileSystemEntity.type(
        ownedDirectoryPath,
        followLinks: false,
      );
      if (directoryType == FileSystemEntityType.directory) {
        await _directory.delete();
      }
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    try {
      await _updates.close();
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    final cleanupError = firstError;
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, firstStackTrace!);
    }
  }

  void _writeSilence(int frames) {
    const maximumBytesPerWrite = 16 * 1024;
    final bytesPerFrame = channels * 2;
    final framesPerWrite = math.max(1, maximumBytesPerWrite ~/ bytesPerFrame);
    final zeroes = Uint8List(framesPerWrite * bytesPerFrame);
    var remaining = frames;
    var startFrame = _frameCount;
    while (remaining > 0) {
      final count = math.min(remaining, framesPerWrite);
      _writePcmBytes(
        zeroes,
        startFrame: startFrame,
        byteCount: count * bytesPerFrame,
      );
      startFrame += count;
      remaining -= count;
    }
    _frameCount += frames;
  }

  void _writePcmBytes(
    Uint8List bytes, {
    required int startFrame,
    int? byteCount,
  }) {
    final count = byteCount ?? bytes.lengthInBytes;
    final bytesPerFrame = channels * 2;
    if (count < 0 ||
        count > bytes.lengthInBytes ||
        count % bytesPerFrame != 0) {
      throw ArgumentError.value(count, 'byteCount');
    }
    final capacity = _capacityFrames;
    if (capacity == null) {
      _writer!.writeFromSync(bytes, 0, count);
      return;
    }

    final capacityBytes = capacity * bytesPerFrame;
    var inputOffset = 0;
    var physicalOffset = (startFrame % capacity) * bytesPerFrame;
    while (inputOffset < count) {
      final writable = math.min(
        count - inputOffset,
        capacityBytes - physicalOffset,
      );
      _writer!.setPositionSync(physicalOffset);
      _writer!.writeFromSync(bytes, inputOffset, inputOffset + writable);
      inputOffset += writable;
      physicalOffset = 0;
    }
  }

  void _ensureOpen() {
    if (_state != GrowingPcmAudioState.open) {
      throw StateError('PCM source is ${_state.name}');
    }
  }

  void _signalChange() {
    final previous = _changed;
    _changed = Completer<void>();
    if (!previous.isCompleted) previous.complete();
    if (!_updates.isClosed) {
      _updates.add(
        GrowingPcmAudioUpdate(
          frameCount: frameCount,
          firstAvailableFrame: firstAvailableFrame,
          state: state,
          error: terminalError,
        ),
      );
    }
  }
}

/// Writes timestamp-aligned PCM16LE sequentially into a unique temporary file.
///
/// Each decoded AAC frame is converted directly to its final byte encoding.
/// No list of decoded chunks and no flattened second copy are retained.
final class FilePcmAudioSourceBuilder {
  factory FilePcmAudioSourceBuilder({
    required int sampleRate,
    required int channels,
    Duration maxGap = const Duration(seconds: 10),
    int? basePtsUs,
  }) {
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels <= 0) throw ArgumentError.value(channels, 'channels');
    if (maxGap.isNegative) throw ArgumentError.value(maxGap, 'maxGap');

    final directory = Directory.systemTemp.createTempSync('ndvy_pcm_');
    final file = File('${directory.path}/audio.pcm');
    try {
      return FilePcmAudioSourceBuilder._(
        sampleRate: sampleRate,
        channels: channels,
        maxGap: maxGap,
        basePtsUs: basePtsUs,
        directory: directory,
        file: file,
        writer: file.openSync(mode: FileMode.writeOnly),
      );
    } catch (_) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  FilePcmAudioSourceBuilder._({
    required this.sampleRate,
    required this.channels,
    required this.maxGap,
    required int? basePtsUs,
    required Directory directory,
    required File file,
    required RandomAccessFile writer,
  }) : _basePtsUs = basePtsUs,
       _directory = directory,
       _file = file,
       _writer = writer;

  final int sampleRate;
  final int channels;
  final Duration maxGap;
  final Directory _directory;
  final File _file;

  RandomAccessFile? _writer;
  int? _basePtsUs;
  int _frameCount = 0;
  bool _ownershipTransferred = false;

  int get frameCount => _frameCount;
  String get filePath => _file.path;

  void addFloatFrame(Float32List interleaved, {int? ptsUs}) {
    _ensureWritable();
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

  void addFloatFrameAtFrame(
    Float32List interleaved, {
    required int startFrame,
    int? validFrames,
  }) {
    _ensureWritable();
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
      _writeSilence(delta);
    } else if (delta < 0) {
      skipFrames += math.min(-delta, includedFrames - skipFrames);
    }

    final firstSample = skipFrames * channels;
    final lastSample = includedFrames * channels;
    if (lastSample <= firstSample) return;
    final bytes = Uint8List((lastSample - firstSample) * 2);
    final data = ByteData.sublistView(bytes);
    for (var index = firstSample; index < lastSample; index++) {
      data.setInt16(
        (index - firstSample) * 2,
        floatSampleToPcm16(interleaved[index]),
        Endian.little,
      );
    }
    _writer!.writeFromSync(bytes);
    _frameCount += (lastSample - firstSample) ~/ channels;
  }

  FilePcmAudioSource build() {
    _ensureWritable();
    _writer!.closeSync();
    _writer = null;
    try {
      final source = FilePcmAudioSource.ownedTemp(
        filePath: _file.path,
        ownedDirectoryPath: _directory.path,
        sampleRate: sampleRate,
        channels: channels,
        basePtsUs: _basePtsUs ?? 0,
        frameCount: frameCount,
      );
      _ownershipTransferred = true;
      return source;
    } catch (_) {
      if (_directory.existsSync()) _directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  void abort() {
    if (_ownershipTransferred) return;
    _writer?.closeSync();
    _writer = null;
    if (_directory.existsSync()) _directory.deleteSync(recursive: true);
  }

  void _writeSilence(int frames) {
    const maximumBytesPerWrite = 16 * 1024;
    final bytesPerFrame = channels * 2;
    final framesPerWrite = math.max(1, maximumBytesPerWrite ~/ bytesPerFrame);
    final zeroes = Uint8List(framesPerWrite * bytesPerFrame);
    var remaining = frames;
    while (remaining > 0) {
      final count = math.min(remaining, framesPerWrite);
      _writer!.writeFromSync(zeroes, 0, count * bytesPerFrame);
      remaining -= count;
    }
    _frameCount += frames;
  }

  void _ensureWritable() {
    if (_writer == null || _ownershipTransferred) {
      throw StateError('PCM file builder is closed');
    }
  }
}

void _validateOwnedTempPaths(String filePath, String directoryPath) {
  final temporaryRoot = Directory.systemTemp;
  final directory = Directory(directoryPath);
  final file = File(filePath);
  final separator = Platform.pathSeparator;
  final directoryName = directory.path
      .split(separator)
      .where((component) => component.isNotEmpty)
      .lastOrNull;

  if (directoryName == null ||
      !directoryName.startsWith('ndvy_pcm_') ||
      directoryName.length == 'ndvy_pcm_'.length) {
    throw ArgumentError.value(
      directoryPath,
      'ownedDirectoryPath',
      'must be an ndvy_pcm_* temporary directory',
    );
  }
  if (FileSystemEntity.typeSync(directoryPath, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw ArgumentError.value(
      directoryPath,
      'ownedDirectoryPath',
      'must be an existing, non-symlink directory',
    );
  }
  if (!FileSystemEntity.identicalSync(
    directory.parent.path,
    temporaryRoot.path,
  )) {
    throw ArgumentError.value(
      directoryPath,
      'ownedDirectoryPath',
      'must be a direct child of the system temporary directory',
    );
  }

  final fileName = file.path
      .split(separator)
      .where((component) => component.isNotEmpty)
      .lastOrNull;
  if (fileName != 'audio.pcm' ||
      !FileSystemEntity.identicalSync(file.parent.path, directory.path) ||
      FileSystemEntity.typeSync(filePath, followLinks: false) !=
          FileSystemEntityType.file) {
    throw ArgumentError.value(
      filePath,
      'filePath',
      'must be the existing, non-symlink <ownedDirectory>/audio.pcm file',
    );
  }
}

extension<T> on Iterable<T> {
  T? get lastOrNull {
    if (isEmpty) return null;
    return last;
  }
}

int floatSampleToPcm16(double sample) {
  if (!sample.isFinite) return 0;
  if (sample <= -1.0) return -32768;
  if (sample >= 1.0) return 32767;
  return (sample * 32768.0).round().clamp(-32768, 32767);
}

Uint8List pcm16SamplesToLittleEndianBytes(
  Int16List samples, {
  int start = 0,
  int? end,
}) {
  final exclusiveEnd = end ?? samples.length;
  RangeError.checkValidRange(start, exclusiveEnd, samples.length);
  final bytes = Uint8List((exclusiveEnd - start) * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = start; index < exclusiveEnd; index++) {
    data.setInt16((index - start) * 2, samples[index], Endian.little);
  }
  return bytes;
}
