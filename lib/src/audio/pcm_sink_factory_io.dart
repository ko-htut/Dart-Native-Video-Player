import 'dart:io';

import 'pcm_sink_aaudio.dart';
import 'pcm_sink_api.dart';
import 'pcm_sink_audio_queue.dart';

Future<PcmAudioSink> createNativePcmAudioSink() {
  if (Platform.isAndroid) return AAudioPcmAudioSink.create();
  if (Platform.isIOS || Platform.isMacOS) {
    return AudioQueuePcmAudioSink.create();
  }
  return Future<PcmAudioSink>.error(
    UnsupportedError(
      'Native PCM playback is unsupported on ${Platform.operatingSystem}',
    ),
  );
}
