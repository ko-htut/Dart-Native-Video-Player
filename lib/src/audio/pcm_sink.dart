import 'pcm_sink_api.dart';
import 'pcm_sink_factory_stub.dart'
    if (dart.library.io) 'pcm_sink_factory_io.dart'
    as sink_factory;

export 'fake_pcm_sink.dart';
export 'pcm_sink_api.dart';

/// Creates the Dart-FFI PCM sink for the current native platform.
///
/// Android uses AAudio and therefore requires Android API 26 or newer. iOS and
/// macOS use Audio Queue Services from the system AudioToolbox framework.
Future<PcmAudioSink> createNativePcmAudioSink() =>
    sink_factory.createNativePcmAudioSink();
