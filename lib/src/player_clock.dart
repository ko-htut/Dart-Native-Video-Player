import 'dart:async';

class PlayerClock {
  Timer? _t;
  int _nowMs = 0;
  bool _playing = false;

  int get nowMs => _nowMs;
  bool get isPlaying => _playing;

  void Function(int nowMs)? onFrameDue;

  void setTime(int ms) {
    _nowMs = ms;
    onFrameDue?.call(_nowMs);
  }

  void play({required int fromMs}) {
    _nowMs = fromMs;
    _playing = true;

    _t?.cancel();
    _t = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _nowMs += 16;
      onFrameDue?.call(_nowMs);
    });
  }

  void pause() {
    _playing = false;
    _t?.cancel();
    _t = null;
  }

  void dispose() {
    _t?.cancel();
  }
}
