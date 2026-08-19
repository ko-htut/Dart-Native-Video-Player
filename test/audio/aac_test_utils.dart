import 'dart:typed_data';

Uint8List makeAdtsFrame(
  List<int> payload, {
  int audioObjectType = 2,
  int samplingFrequencyIndex = 4,
  int channelConfiguration = 2,
  int numberOfRawDataBlocks = 0,
  bool protectionAbsent = true,
}) {
  final headerLength = protectionAbsent ? 7 : 9 + 2 * numberOfRawDataBlocks;
  final frameLength = headerLength + payload.length;
  final result = Uint8List(frameLength);
  result[0] = 0xff;
  result[1] = 0xf0 | (protectionAbsent ? 1 : 0);
  result[2] =
      ((audioObjectType - 1) << 6) |
      (samplingFrequencyIndex << 2) |
      (channelConfiguration >> 2);
  result[3] = ((channelConfiguration & 3) << 6) | ((frameLength >> 11) & 3);
  result[4] = (frameLength >> 3) & 0xff;
  result[5] = ((frameLength & 7) << 5) | 0x1f;
  result[6] = 0xfc | (numberOfRawDataBlocks & 3);
  if (!protectionAbsent) {
    for (var i = 7; i < headerLength; i++) {
      result[i] = i;
    }
  }
  result.setRange(headerLength, result.length, payload);
  return result;
}

Uint8List makePes(Uint8List payload, {int pts90k = 0, int streamId = 0xc0}) {
  final encodedPts = encodePts(pts90k, prefix: 0x02);
  final packetLength = 3 + encodedPts.length + payload.length;
  final result = Uint8List(6 + packetLength);
  result.setRange(0, 6, <int>[
    0x00,
    0x00,
    0x01,
    streamId,
    packetLength >> 8,
    packetLength & 0xff,
  ]);
  result[6] = 0x80;
  result[7] = 0x80;
  result[8] = encodedPts.length;
  result.setRange(9, 14, encodedPts);
  result.setRange(14, result.length, payload);
  return result;
}

Uint8List encodePts(int pts, {required int prefix}) {
  final value = pts & ((1 << 33) - 1);
  return Uint8List.fromList(<int>[
    (prefix << 4) | (((value >> 30) & 7) << 1) | 1,
    (value >> 22) & 0xff,
    (((value >> 15) & 0x7f) << 1) | 1,
    (value >> 7) & 0xff,
    ((value & 0x7f) << 1) | 1,
  ]);
}
