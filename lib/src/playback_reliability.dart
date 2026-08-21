/// Small, allocation-free session counters for production playback health.
///
/// The player keeps this separate from widgets so lifecycle and buffering
/// transitions are counted once even when the UI is rebuilt many times.
final class PlaybackReliabilityTelemetry {
  int videoStarvationCount = 0;
  int audioUnderrunCount = 0;
  int decoderRecoveryCount = 0;
  int qualitySwitchCount = 0;
  int presentationUpdateCount = 0;
  int peakResidentAccessUnits = 0;
  int rebufferDurationMs = 0;
  int? _rebufferStartedAtMs;

  bool get isRebuffering => _rebufferStartedAtMs != null;

  void reset() {
    videoStarvationCount = 0;
    audioUnderrunCount = 0;
    decoderRecoveryCount = 0;
    qualitySwitchCount = 0;
    presentationUpdateCount = 0;
    peakResidentAccessUnits = 0;
    rebufferDurationMs = 0;
    _rebufferStartedAtMs = null;
  }

  void recordVideoStarvation(int mediaTimeMs) {
    if (_rebufferStartedAtMs != null) return;
    videoStarvationCount++;
    _rebufferStartedAtMs = mediaTimeMs;
  }

  void recordAudioUnderrun(int mediaTimeMs) {
    audioUnderrunCount++;
    _rebufferStartedAtMs ??= mediaTimeMs;
  }

  void recordBufferRecovered(int mediaTimeMs) {
    final startedAtMs = _rebufferStartedAtMs;
    if (startedAtMs == null) return;
    rebufferDurationMs += mediaTimeMs > startedAtMs
        ? mediaTimeMs - startedAtMs
        : 0;
    _rebufferStartedAtMs = null;
  }

  void recordDecoderRecovery() => decoderRecoveryCount++;

  void recordQualitySwitch() => qualitySwitchCount++;

  void recordPresentationUpdate() => presentationUpdateCount++;

  void observeResidentAccessUnits(int value) {
    if (value > peakResidentAccessUnits) peakResidentAccessUnits = value;
  }

  String summary({required int droppedFrames, required int coalescedFrames}) {
    final totalRebufferMs = rebufferDurationMs;
    return 'Health: ${videoStarvationCount + audioUnderrunCount} rebuffers'
        ' / ${(totalRebufferMs / 1000).toStringAsFixed(1)}s'
        ' • recoveries $decoderRecoveryCount'
        ' • switches $qualitySwitchCount'
        ' • dropped $droppedFrames'
        ' • coalesced $coalescedFrames'
        ' • peak AU $peakResidentAccessUnits';
  }
}
