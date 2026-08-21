import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/pcm_sink_aaudio.dart';
import 'package:ndvy_player/src/audio/pcm_sink_audio_queue.dart';

void main() {
  group('AAudioMediaPositionTracker', () {
    test('starved endpoint time cannot consume a later media write', () {
      final tracker = AAudioMediaPositionTracker();

      tracker.acceptMediaFrames(100);
      expect(tracker.observeRawEndpointFrames(60), 60);
      expect(tracker.observeRawEndpointFrames(100), 40);
      expect(tracker.mediaPositionFrames, 100);
      expect(tracker.outstandingAcceptedFrames, 0);

      // The endpoint renders 900 frames of underrun silence. Observing that
      // raw delta while no accepted media is outstanding advances only the raw
      // baseline, never the media clock.
      expect(tracker.observeRawEndpointFrames(1000), 0);
      expect(tracker.mediaPositionFrames, 100);

      tracker.acceptMediaFrames(100);
      expect(tracker.observeRawEndpointFrames(1000), 0);
      expect(tracker.mediaPositionFrames, 100);
      expect(tracker.outstandingAcceptedFrames, 100);

      expect(tracker.observeRawEndpointFrames(1010), 10);
      expect(tracker.mediaPositionFrames, 110);
      expect(tracker.outstandingAcceptedFrames, 90);
    });

    test('raw deltas are bounded by accepted outstanding media', () {
      final tracker = AAudioMediaPositionTracker(initialRawEndpointFrames: 500);
      tracker.acceptMediaFrames(32);

      expect(tracker.observeRawEndpointFrames(600), 32);
      expect(tracker.mediaPositionFrames, 32);
      expect(tracker.outstandingAcceptedFrames, 0);

      // A raw device counter reset starts a new endpoint epoch without
      // rewinding or advancing the accumulated media position.
      expect(tracker.observeRawEndpointFrames(4), 0);
      tracker.acceptMediaFrames(8);
      expect(tracker.observeRawEndpointFrames(12), 8);
      expect(tracker.mediaPositionFrames, 40);
    });
  });

  group('AudioQueueStarvationTracker', () {
    test('reports one underrun then requests restart only after refill', () {
      final tracker = AudioQueueStarvationTracker()..noteOpenTail();

      final stoppedEmpty = tracker.observe(
        logicallyPlaying: true,
        queueIsRunning: false,
        hasQueuedAudio: false,
      );
      expect(stoppedEmpty.emitUnderrun, isTrue);
      expect(stoppedEmpty.restartQueue, isFalse);

      final repeatedStop = tracker.observe(
        logicallyPlaying: true,
        queueIsRunning: false,
        hasQueuedAudio: false,
      );
      expect(repeatedStop.emitUnderrun, isFalse);
      expect(repeatedStop.restartQueue, isFalse);

      final refill = tracker.observe(
        logicallyPlaying: true,
        queueIsRunning: false,
        hasQueuedAudio: true,
      );
      expect(refill.emitUnderrun, isFalse);
      expect(refill.restartQueue, isTrue);

      tracker.markRecovered();
      expect(tracker.hasOpenTail, isFalse);
      expect(tracker.hasReportedUnderrun, isFalse);
    });

    test('initial buffering can restart without a false underrun', () {
      final tracker = AudioQueueStarvationTracker()
        ..noteOpenTail(reportUnderrun: false);

      final refill = tracker.observe(
        logicallyPlaying: true,
        queueIsRunning: false,
        hasQueuedAudio: true,
      );
      expect(refill.emitUnderrun, isFalse);
      expect(refill.restartQueue, isTrue);
    });

    test('refill of a still-running tail requires no restart', () {
      final tracker = AudioQueueStarvationTracker()..noteOpenTail();
      final decision = tracker.observe(
        logicallyPlaying: true,
        queueIsRunning: true,
        hasQueuedAudio: true,
      );

      expect(decision.emitUnderrun, isFalse);
      expect(decision.restartQueue, isFalse);
      tracker.markRecovered();
      expect(tracker.hasOpenTail, isFalse);
    });
  });
}
