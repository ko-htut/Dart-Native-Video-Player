import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/audio/pcm_sink_api.dart';
import 'package:ndvy_player/src/audio/pcm_sink_audio_queue.dart';

void main() {
  final enabled =
      Platform.isMacOS &&
      Platform.environment['NDVY_NATIVE_AUDIO_SMOKE'] == '1';

  test(
    'AudioQueue restarts after an open-tail underrun and refill',
    () async {
      final sink = await AudioQueuePcmAudioSink.create();
      addTearDown(sink.dispose);
      final events = <PcmSinkEvent>[];
      final consumed = StreamController<PcmSinkEvent>();
      final subscription = sink.events.listen((event) {
        events.add(event);
        if (event.type == PcmSinkEventType.bufferConsumed) {
          consumed.add(event);
        }
      });
      addTearDown(subscription.cancel);
      addTearDown(consumed.close);

      final format = PcmAudioFormat(sampleRate: 48000, channelCount: 2);
      await sink.configure(format, generation: 1);
      final oneBuffer = Uint8List(2048 * format.bytesPerFrame);
      expect(await sink.enqueue(oneBuffer, generation: 1), 2048);
      await sink.play();

      final iterator = StreamIterator<PcmSinkEvent>(consumed.stream);
      addTearDown(iterator.cancel);
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 3)),
        isTrue,
      );

      // Leave the queue empty long enough for AudioQueue to report stopped.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await sink.enqueue(oneBuffer, generation: 1), 2048);
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 3)),
        isTrue,
      );

      // macOS may keep the queue running at an empty tail; iOS commonly stops
      // it. In either case refill must be consumed without another play call.
      expect(sink.state, PcmSinkState.playing);
    },
    skip: enabled
        ? false
        : 'Set NDVY_NATIVE_AUDIO_SMOKE=1 on macOS for native AudioQueue I/O',
  );
}
