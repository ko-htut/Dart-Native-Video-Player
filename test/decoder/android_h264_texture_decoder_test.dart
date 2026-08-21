import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/android_h264_texture_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ndvy_player/h264_hardware');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'getCapabilities' => <String, Object?>{
              'supported': true,
              'hardwareAccelerated': true,
              'decoderName': 'test.avc.decoder',
              'maximumWidth': 3840,
              'maximumHeight': 2160,
              'maximumFrameRate': 60.0,
              'maximumBitrate': 50000000,
            },
            'configure' => <String, Object?>{
              'textureId': 91,
              'width': 1236,
              'height': 720,
              'decoderName': 'test.avc.decoder',
            },
            'queueAccessUnit' || 'setClock' || 'flush' || 'dispose' => null,
            _ => throw MissingPluginException(call.method),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('configures once and queues four-byte Annex-B access units', () async {
    final decoder = AndroidH264TextureDecoder(channel: channel);
    addTearDown(decoder.dispose);

    final capabilities = await decoder.capabilities();
    expect(capabilities.supported, isTrue);
    expect(capabilities.hardwareAccelerated, isTrue);
    expect(capabilities.maximumPixels, 3840 * 2160);
    expect(capabilities.maximumFrameRate, 60);
    final receipt = await decoder.queueAccessUnit(
      nals: <Uint8List>[_sps, _pps, _idr],
      presentationTimeUs: 123000,
      clockMediaTimeUs: 100000,
      playing: true,
    );
    expect(receipt.textureId, 91);
    expect(receipt.width, 1236);
    expect(receipt.height, 720);
    expect(receipt.decoderName, 'test.avc.decoder');

    final configure = calls.singleWhere((call) => call.method == 'configure');
    final configureArguments = configure.arguments as Map<Object?, Object?>;
    expect(configureArguments['width'], 1236);
    expect(configureArguments['height'], 720);

    final queue = calls.singleWhere((call) => call.method == 'queueAccessUnit');
    final arguments = queue.arguments as Map<Object?, Object?>;
    expect(arguments['presentationTimeUs'], 123000);
    expect(arguments['clockMediaTimeUs'], 100000);
    expect(arguments['playing'], isTrue);
    expect(
      arguments['data'],
      _annexB(<Uint8List>[_sps, _pps, _idr]),
      reason: 'each NAL must use 00 00 00 01, not 00 00 01 00',
    );

    await decoder.queueAccessUnit(
      nals: <Uint8List>[_nonIdr],
      presentationTimeUs: 156000,
      clockMediaTimeUs: 120000,
      playing: false,
    );
    expect(calls.where((call) => call.method == 'configure'), hasLength(1));
    expect(
      calls.where((call) => call.method == 'queueAccessUnit'),
      hasLength(2),
    );
  });

  test('rejects malformed NAL headers before invoking Android', () async {
    final decoder = AndroidH264TextureDecoder(channel: channel);
    addTearDown(decoder.dispose);

    await expectLater(
      decoder.queueAccessUnit(
        nals: <Uint8List>[
          Uint8List.fromList(<int>[0x80]),
        ],
        presentationTimeUs: 0,
        clockMediaTimeUs: 0,
        playing: false,
      ),
      throwsFormatException,
    );
    expect(calls.where((call) => call.method == 'configure'), isEmpty);
    expect(calls.where((call) => call.method == 'queueAccessUnit'), isEmpty);
  });

  test('surface loss invalidates configuration until an IDR replay', () async {
    final decoder = AndroidH264TextureDecoder(channel: channel);
    addTearDown(decoder.dispose);
    final availability = <bool>[];
    final subscription = decoder.surfaceAvailability.listen(availability.add);
    addTearDown(subscription.cancel);

    await decoder.queueAccessUnit(
      nals: <Uint8List>[_sps, _pps, _idr],
      presentationTimeUs: 0,
      clockMediaTimeUs: 0,
      playing: true,
    );
    expect(decoder.isConfigured, isTrue);

    await _sendNativeMethod(
      channel,
      'surfaceAvailabilityChanged',
      <String, Object?>{'available': false},
    );
    expect(availability, <bool>[false]);
    expect(decoder.isConfigured, isFalse);

    await _sendNativeMethod(
      channel,
      'surfaceAvailabilityChanged',
      <String, Object?>{'available': true},
    );
    expect(availability, <bool>[false, true]);

    await decoder.queueAccessUnit(
      nals: <Uint8List>[_sps, _pps, _idr],
      presentationTimeUs: 0,
      clockMediaTimeUs: 0,
      playing: false,
    );
    expect(calls.where((call) => call.method == 'configure'), hasLength(2));
  });
}

Future<void> _sendNativeMethod(
  MethodChannel channel,
  String method,
  Object? arguments,
) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );
}

final Uint8List _sps = _hex(
  '67640028acd9c04e05be7f011000003e90000ea600f18319e0',
);
final Uint8List _pps = _hex('68e9b9cb22c0');
final Uint8List _idr = _hex('65888400');
final Uint8List _nonIdr = _hex('419a20');

Uint8List _annexB(List<Uint8List> nals) => Uint8List.fromList(<int>[
  for (final nal in nals) ...<int>[0, 0, 0, 1, ...nal],
]);

Uint8List _hex(String value) => Uint8List.fromList(<int>[
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);
