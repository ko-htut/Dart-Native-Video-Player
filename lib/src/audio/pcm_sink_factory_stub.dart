import 'pcm_sink_api.dart';

Future<PcmAudioSink> createNativePcmAudioSink() => Future<PcmAudioSink>.error(
  UnsupportedError('Native PCM playback is unavailable on this platform'),
);
