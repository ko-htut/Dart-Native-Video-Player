import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/playback_reliability.dart';

void main() {
  test('counts one starvation episode and its recovered media duration', () {
    final telemetry = PlaybackReliabilityTelemetry();

    telemetry.recordVideoStarvation(1000);
    telemetry.recordVideoStarvation(1100);
    telemetry.recordBufferRecovered(1750);

    expect(telemetry.videoStarvationCount, 1);
    expect(telemetry.rebufferDurationMs, 750);
    expect(telemetry.isRebuffering, isFalse);
  });

  test('tracks bounded-session health and resets atomically', () {
    final telemetry = PlaybackReliabilityTelemetry();
    telemetry
      ..recordAudioUnderrun(2000)
      ..recordDecoderRecovery()
      ..recordQualitySwitch()
      ..recordPresentationUpdate()
      ..observeResidentAccessUnits(12)
      ..observeResidentAccessUnits(9)
      ..recordBufferRecovered(2300);

    expect(telemetry.audioUnderrunCount, 1);
    expect(telemetry.decoderRecoveryCount, 1);
    expect(telemetry.qualitySwitchCount, 1);
    expect(telemetry.presentationUpdateCount, 1);
    expect(telemetry.peakResidentAccessUnits, 12);
    expect(
      telemetry.summary(droppedFrames: 3, coalescedFrames: 4),
      contains('dropped 3'),
    );

    telemetry.reset();
    expect(telemetry.audioUnderrunCount, 0);
    expect(telemetry.peakResidentAccessUnits, 0);
    expect(telemetry.rebufferDurationMs, 0);
  });
}
