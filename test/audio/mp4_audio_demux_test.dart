import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/mp4/mp4_demux.dart';

void main() {
  group('MP4 AAC demux', () {
    test('parses mp4a/esds/ASC and exact sample tables', () {
      final fixture = _makeAacMp4();
      final track = Mp4Demux.parseAacTrack(fixture.bytes);

      expect(track, isNotNull);
      expect(track!.timescale, 44100);
      expect(track.sampleRate, 44100);
      expect(track.channelCount, 2);
      expect(track.sampleSizeBits, 16);
      expect(track.aac.objectTypeIndication, 0x40);
      expect(track.aac.maxBitrate, 128000);
      expect(track.aac.averageBitrate, 96000);
      expect(track.config.bytes, <int>[0x12, 0x10]);
      expect(track.config.audioObjectType, 2);
      expect(track.config.isAacLc, isTrue);
      expect(track.sampleSizes, <int>[3, 4]);
      expect(track.sampleOffsets, <int>[
        fixture.firstSampleOffset,
        fixture.firstSampleOffset + 3,
      ]);
      expect(track.dts, <int>[0, 1024]);
      expect(track.sampleDurations, <int>[1024, 1024]);
      expect(track.pts, <int>[-10, 1029]);
      expect(Mp4Demux.readAudioSample(fixture.bytes, track, 0), <int>[1, 2, 3]);
      expect(Mp4Demux.readAudioSample(fixture.bytes, track, 1), <int>[
        4,
        5,
        6,
        7,
      ]);
    });

    test('returns null for the bundled video-only asset', () {
      final bytes = File('assets/baby.mp4').readAsBytesSync();
      expect(Mp4Demux.parseAacTrack(bytes), isNull);
    });

    test('extracts the deterministic AAC-LC demo asset', () {
      final bytes = File('assets/baby_aac.mp4').readAsBytesSync();
      final track = Mp4Demux.parseAacTrack(bytes)!;

      expect(track.sampleRate, 48000);
      expect(track.channelCount, 2);
      expect(track.config.audioObjectType, 2);
      expect(track.config.samplingFrequency, 48000);
      expect(track.sampleSizes, hasLength(277));
      expect(track.sampleDurations.first, 1024);
      expect(track.sampleDurations.last, 400);
      expect(track.presentationTimeOffset, -1024);
      expect(track.dts.take(2), <int>[0, 1024]);
      expect(track.pts.take(2), <int>[-1024, 0]);
      expect(Mp4Demux.readAudioSample(bytes, track, 0), hasLength(329));
    });

    test('checks audio sample indices', () {
      final fixture = _makeAacMp4();
      final track = Mp4Demux.parseAacTrack(fixture.bytes)!;
      expect(
        () => Mp4Demux.readAudioSample(fixture.bytes, track, 2),
        throwsRangeError,
      );
    });
  });
}

({Uint8List bytes, int firstSampleOffset}) _makeAacMp4() {
  final ftyp = _box('ftyp', <int>[
    ...ascii.encode('isom'),
    ..._u32(0x200),
    ...ascii.encode('isom'),
    ...ascii.encode('mp41'),
  ]);
  const samples = <int>[1, 2, 3, 4, 5, 6, 7];
  final mdat = _box('mdat', samples);
  final firstSampleOffset = ftyp.length + 8;

  final asc = <int>[0x12, 0x10];
  final decoderSpecificInfo = _descriptor(0x05, asc);
  final decoderConfig = _descriptor(0x04, <int>[
    0x40, // MPEG-4 Audio
    0x15, // AudioStream, upstream=0, reserved=1
    0x00,
    0x10,
    0x00, // bufferSizeDB
    ..._u32(128000),
    ..._u32(96000),
    ...decoderSpecificInfo,
  ]);
  final esDescriptor = _descriptor(0x03, <int>[
    ..._u16(1), // ES_ID
    0x00, // flags
    ...decoderConfig,
    ..._descriptor(0x06, <int>[0x02]),
  ]);
  final esds = _fullBox('esds', esDescriptor);

  final mp4a = _box('mp4a', <int>[
    ...List<int>.filled(6, 0),
    ..._u16(1), // data_reference_index
    ..._u16(0), // version
    ..._u16(0), // revision
    ..._u32(0), // vendor
    ..._u16(2), // channelcount
    ..._u16(16), // samplesize
    ..._u16(0), // compression id
    ..._u16(0), // packet size
    ..._u32(44100 << 16),
    ...esds,
  ]);

  final stsd = _fullBox('stsd', <int>[..._u32(1), ...mp4a]);
  final stts = _fullBox('stts', <int>[..._u32(1), ..._u32(2), ..._u32(1024)]);
  final ctts = _fullBox('ctts', <int>[
    ..._u32(2),
    ..._u32(1),
    ..._u32(0xfffffff6), // -10 in version 1
    ..._u32(1),
    ..._u32(5),
  ], version: 1);
  final stsc = _fullBox('stsc', <int>[
    ..._u32(1),
    ..._u32(1),
    ..._u32(2),
    ..._u32(1),
  ]);
  final stsz = _fullBox('stsz', <int>[
    ..._u32(0),
    ..._u32(2),
    ..._u32(3),
    ..._u32(4),
  ]);
  final stco = _fullBox('stco', <int>[..._u32(1), ..._u32(firstSampleOffset)]);
  final stbl = _box('stbl', <int>[
    ...stsd,
    ...stts,
    ...ctts,
    ...stsc,
    ...stsz,
    ...stco,
  ]);
  final minf = _box('minf', stbl);
  final mdhd = _fullBox('mdhd', <int>[
    ..._u32(0),
    ..._u32(0),
    ..._u32(44100),
    ..._u32(2048),
    ..._u16(0),
    ..._u16(0),
  ]);
  final hdlr = _fullBox('hdlr', <int>[
    ..._u32(0),
    ...ascii.encode('soun'),
    ...List<int>.filled(12, 0),
    ...ascii.encode('SoundHandler'),
    0,
  ]);
  final mdia = _box('mdia', <int>[...mdhd, ...hdlr, ...minf]);
  final trak = _box('trak', mdia);
  final moov = _box('moov', trak);

  return (
    bytes: Uint8List.fromList(<int>[...ftyp, ...mdat, ...moov]),
    firstSampleOffset: firstSampleOffset,
  );
}

Uint8List _box(String type, List<int> payload) {
  return Uint8List.fromList(<int>[
    ..._u32(payload.length + 8),
    ...ascii.encode(type),
    ...payload,
  ]);
}

Uint8List _fullBox(
  String type,
  List<int> payload, {
  int version = 0,
  int flags = 0,
}) {
  return _box(type, <int>[
    version,
    (flags >> 16) & 0xff,
    (flags >> 8) & 0xff,
    flags & 0xff,
    ...payload,
  ]);
}

List<int> _descriptor(int tag, List<int> payload) => <int>[
  tag,
  ..._descriptorLength(payload.length),
  ...payload,
];

List<int> _descriptorLength(int value) {
  if (value < 0 || value >= 1 << 28) throw RangeError.value(value);
  final groups = <int>[value & 0x7f];
  var remaining = value >> 7;
  while (remaining != 0) {
    groups.add(remaining & 0x7f);
    remaining >>= 7;
  }
  return <int>[
    for (var i = groups.length - 1; i >= 0; i--)
      groups[i] | (i == 0 ? 0 : 0x80),
  ];
}

List<int> _u16(int value) => <int>[(value >> 8) & 0xff, value & 0xff];

List<int> _u32(int value) => <int>[
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];
