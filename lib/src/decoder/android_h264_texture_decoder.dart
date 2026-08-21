import 'dart:async';
import 'package:flutter/services.dart';

import 'sps.dart';

/// One frame that Android reports as rendered into the Flutter texture.
final class AndroidH264RenderedFrame {
  const AndroidH264RenderedFrame({
    required this.presentationTimeUs,
    required this.width,
    required this.height,
  });

  final int presentationTimeUs;
  final int width;
  final int height;
}

/// Result of accepting one compressed access unit into MediaCodec.
final class AndroidH264QueueReceipt {
  const AndroidH264QueueReceipt({
    required this.textureId,
    required this.width,
    required this.height,
    required this.decoderName,
  });

  final int textureId;
  final int width;
  final int height;
  final String decoderName;
}

/// Decoder limits reported by Android's selected AVC codec.
final class AndroidH264Capabilities {
  const AndroidH264Capabilities({
    required this.supported,
    required this.hardwareAccelerated,
    required this.decoderName,
    required this.maximumWidth,
    required this.maximumHeight,
    required this.maximumFrameRate,
    required this.maximumBitrate,
  });

  final bool supported;
  final bool hardwareAccelerated;
  final String decoderName;
  final int maximumWidth;
  final int maximumHeight;
  final double maximumFrameRate;
  final int maximumBitrate;

  int get maximumPixels => maximumWidth * maximumHeight;
}

/// Android MediaCodec H.264 decoder whose output is a Flutter texture.
///
/// The Dart HLS/MP4 demuxers still own compressed access-unit order. Native
/// code receives Annex-B access units, decodes into a Surface-backed texture,
/// and schedules frames against a media-time/monotonic-time anchor supplied by
/// the existing audio-master clock. No decoded YUV or RGBA picture crosses the
/// platform channel.
final class AndroidH264TextureDecoder {
  AndroidH264TextureDecoder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const String _channelName = 'ndvy_player/h264_hardware';

  final MethodChannel _channel;
  final StreamController<AndroidH264RenderedFrame> _renderedFrames =
      StreamController<AndroidH264RenderedFrame>.broadcast(sync: true);
  final StreamController<Object> _errors = StreamController<Object>.broadcast(
    sync: true,
  );
  final StreamController<bool> _surfaceAvailability =
      StreamController<bool>.broadcast(sync: true);

  Uint8List? _sequenceParameterSet;
  Uint8List? _pictureParameterSet;
  Uint8List? _configuredSequenceParameterSet;
  Uint8List? _configuredPictureParameterSet;
  int? _textureId;
  int? _width;
  int? _height;
  String _decoderName = 'MediaCodec';
  bool _disposed = false;

  Stream<AndroidH264RenderedFrame> get renderedFrames => _renderedFrames.stream;

  Stream<Object> get errors => _errors.stream;

  /// Emits false before Android releases a background texture surface and
  /// true after Flutter supplies its replacement on foreground resume.
  Stream<bool> get surfaceAvailability => _surfaceAvailability.stream;

  int? get textureId => _textureId;

  bool get isConfigured => _textureId != null;

  Future<bool> isSupported() async {
    return (await capabilities()).supported;
  }

  Future<AndroidH264Capabilities> capabilities() async {
    _ensureActive();
    final response = await _channel.invokeMapMethod<String, Object?>(
      'getCapabilities',
    );
    if (response == null) {
      throw StateError('Android returned no H.264 decoder capabilities');
    }
    return AndroidH264Capabilities(
      supported: response['supported'] as bool? ?? false,
      hardwareAccelerated: response['hardwareAccelerated'] as bool? ?? false,
      decoderName: response['decoderName'] as String? ?? 'MediaCodec',
      maximumWidth: response['maximumWidth'] as int? ?? 0,
      maximumHeight: response['maximumHeight'] as int? ?? 0,
      maximumFrameRate: (response['maximumFrameRate'] as num?)?.toDouble() ?? 0,
      maximumBitrate: response['maximumBitrate'] as int? ?? 0,
    );
  }

  /// Queues one access unit and lazily configures MediaCodec from its SPS/PPS.
  Future<AndroidH264QueueReceipt> queueAccessUnit({
    required List<Uint8List> nals,
    required int presentationTimeUs,
    required int clockMediaTimeUs,
    required bool playing,
  }) async {
    _ensureActive();
    if (nals.isEmpty) {
      throw const FormatException('Cannot queue an empty H.264 access unit');
    }

    for (final nal in nals) {
      if (nal.isEmpty || (nal.first & 0x80) != 0) {
        throw const FormatException('Malformed H.264 NAL header');
      }
      switch (nal.first & 0x1f) {
        case 7:
          _sequenceParameterSet = Uint8List.fromList(nal);
          break;
        case 8:
          _pictureParameterSet = Uint8List.fromList(nal);
          break;
      }
    }

    final sps = _sequenceParameterSet;
    final pps = _pictureParameterSet;
    if (sps == null || pps == null) {
      throw const FormatException(
        'MediaCodec requires SPS and PPS before the first access unit',
      );
    }

    final needsConfigure =
        _textureId == null ||
        !_bytesEqual(sps, _configuredSequenceParameterSet) ||
        !_bytesEqual(pps, _configuredPictureParameterSet);
    if (needsConfigure) {
      final parsed = parseSpsNal(sps);
      final response = await _channel
          .invokeMapMethod<String, Object?>('configure', <String, Object?>{
            'width': parsed.width,
            'height': parsed.height,
            'codedWidth': parsed.codedWidth,
            'codedHeight': parsed.codedHeight,
            'sps': sps,
            'pps': pps,
          });
      if (response == null || response['textureId'] is! int) {
        throw StateError('Android returned an invalid MediaCodec texture');
      }
      _textureId = response['textureId']! as int;
      _width = (response['width'] as int?) ?? parsed.width;
      _height = (response['height'] as int?) ?? parsed.height;
      _decoderName = (response['decoderName'] as String?) ?? 'MediaCodec';
      _configuredSequenceParameterSet = Uint8List.fromList(sps);
      _configuredPictureParameterSet = Uint8List.fromList(pps);
    }

    await _channel.invokeMethod<void>('queueAccessUnit', <String, Object?>{
      'data': _annexB(nals),
      'presentationTimeUs': presentationTimeUs,
      'clockMediaTimeUs': clockMediaTimeUs,
      'playing': playing,
    });

    return AndroidH264QueueReceipt(
      textureId: _textureId!,
      width: _width!,
      height: _height!,
      decoderName: _decoderName,
    );
  }

  Future<void> updateClock({
    required int mediaTimeUs,
    required bool playing,
  }) async {
    if (_disposed || _textureId == null) return;
    await _channel.invokeMethod<void>('setClock', <String, Object?>{
      'mediaTimeUs': mediaTimeUs,
      'playing': playing,
    });
  }

  /// Flushes queued codec state but keeps the texture and parameter sets.
  Future<void> reset() async {
    if (_disposed || _textureId == null) return;
    await _channel.invokeMethod<void>('flush');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod<void>('dispose');
    } finally {
      _channel.setMethodCallHandler(null);
      await _renderedFrames.close();
      await _errors.close();
      await _surfaceAvailability.close();
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    switch (call.method) {
      case 'frameRendered':
        if (arguments is! Map<Object?, Object?>) return null;
        final presentationTimeUs = arguments['presentationTimeUs'];
        final width = arguments['width'];
        final height = arguments['height'];
        if (presentationTimeUs is int && width is int && height is int) {
          if (!_disposed) {
            _renderedFrames.add(
              AndroidH264RenderedFrame(
                presentationTimeUs: presentationTimeUs,
                width: width,
                height: height,
              ),
            );
          }
        }
        return null;
      case 'decoderError':
        final message = arguments is Map<Object?, Object?>
            ? arguments['message']?.toString()
            : arguments?.toString();
        if (!_disposed) {
          _errors.add(StateError(message ?? 'Android MediaCodec failed'));
        }
        return null;
      case 'surfaceAvailabilityChanged':
        if (arguments is! Map<Object?, Object?>) return null;
        final available = arguments['available'];
        if (available is! bool || _disposed) return null;
        if (!available) {
          // The native codec is released before the old Surface becomes
          // invalid. Force the next IDR replay to configure against the new
          // Surface instead of assuming the previous codec still exists.
          _textureId = null;
          _configuredSequenceParameterSet = null;
          _configuredPictureParameterSet = null;
        }
        _surfaceAvailability.add(available);
        return null;
    }
    return null;
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('Android H.264 texture decoder is disposed');
    }
  }
}

Uint8List _annexB(List<Uint8List> nals) {
  var length = 0;
  for (final nal in nals) {
    length += 4 + nal.length;
  }
  final result = Uint8List(length);
  var offset = 0;
  for (final nal in nals) {
    result[offset + 3] = 1;
    offset += 4;
    result.setRange(offset, offset + nal.length, nal);
    offset += nal.length;
  }
  return result;
}

bool _bytesEqual(Uint8List value, Uint8List? other) {
  if (other == null || value.length != other.length) return false;
  for (var index = 0; index < value.length; index++) {
    if (value[index] != other[index]) return false;
  }
  return true;
}
