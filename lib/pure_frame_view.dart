import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'dart:async';

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
  int _decodeGeneration = 0;

  @override
  void didUpdateWidget(covariant PureFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rgba != widget.rgba) {
      _makeImage();
    }
  }

  @override
  void initState() {
    super.initState();
    _makeImage();
  }

  Future<void> _makeImage() async {
    final generation = ++_decodeGeneration;
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      widget.rgba,
      widget.width,
      widget.height,
      ui.PixelFormat.rgba8888,
      (img) => c.complete(img),
    );
    final img = await c.future;
    if (!mounted || generation != _decodeGeneration) {
      img.dispose();
      return;
    }
    final previous = _img;
    setState(() => _img = img);
    previous?.dispose();
  }

  @override
  void dispose() {
    _decodeGeneration++;
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_img == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return FittedBox(
      fit: BoxFit.contain, // keep aspect ratio, fill as much as possible
      alignment: Alignment.center,
      child: SizedBox(
        width: widget.width.toDouble(),
        height: widget.height.toDouble(),
        child: RawImage(image: _img, filterQuality: FilterQuality.none),
      ),
    );
  }
}
