import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class PureFrameView extends StatefulWidget {
  final Uint8List rgba; // length = w*h*4
  final int width;
  final int height;

  const PureFrameView({
    super.key,
    required this.rgba,
    required this.width,
    required this.height,
  });

  @override
  State<PureFrameView> createState() => _PureFrameViewState();
}

class _PureFrameViewState extends State<PureFrameView> {
  ui.Image? _img;
  int _imageWidth = 0;
  int _imageHeight = 0;
  _PendingRgbaFrame? _pendingFrame;
  bool _decodeInFlight = false;

  @override
  void didUpdateWidget(covariant PureFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rgba, widget.rgba) ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _scheduleLatestFrame();
    }
  }

  @override
  void initState() {
    super.initState();
    _scheduleLatestFrame();
  }

  void _scheduleLatestFrame() {
    _pendingFrame = _PendingRgbaFrame(
      rgba: widget.rgba,
      width: widget.width,
      height: widget.height,
    );
    _startDecodeIfNeeded();
  }

  void _startDecodeIfNeeded() {
    if (_decodeInFlight || _pendingFrame == null || !mounted) return;
    _decodeInFlight = true;
    unawaited(_drainPendingFrames());
  }

  Future<void> _drainPendingFrames() async {
    try {
      while (mounted) {
        final frame = _pendingFrame;
        if (frame == null) return;
        _pendingFrame = null;

        final img = await _decodeFrame(frame);
        if (!mounted) {
          img.dispose();
          return;
        }

        // A newer frame arrived while this conversion was running. Do not
        // upload the stale result into the widget; decode only the newest
        // pending snapshot on the next iteration.
        if (_pendingFrame != null) {
          img.dispose();
          continue;
        }

        final previous = _img;
        setState(() {
          _img = img;
          _imageWidth = frame.width;
          _imageHeight = frame.height;
        });
        previous?.dispose();
      }
    } finally {
      _decodeInFlight = false;
      _startDecodeIfNeeded();
    }
  }

  Future<ui.Image> _decodeFrame(_PendingRgbaFrame frame) {
    final completion = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      completion.complete,
    );
    return completion.future;
  }

  @override
  void dispose() {
    _pendingFrame = null;
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: _img == null
          ? const Center(child: CircularProgressIndicator())
          : FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.center,
              child: SizedBox(
                width: _imageWidth.toDouble(),
                height: _imageHeight.toDouble(),
                child: RawImage(image: _img, filterQuality: FilterQuality.none),
              ),
            ),
    );
  }
}

final class _PendingRgbaFrame {
  const _PendingRgbaFrame({
    required this.rgba,
    required this.width,
    required this.height,
  });

  final Uint8List rgba;
  final int width;
  final int height;
}
