import 'dart:typed_data';

class TsPacket {
  final int pid;
  final bool payloadUnitStart;
  final Uint8List payload;
  final int continuityCounter;
  final bool hasPayload;
  final bool discontinuityIndicator;
  final int transportScramblingControl;

  TsPacket({
    required this.pid,
    required this.payloadUnitStart,
    required this.payload,
    this.continuityCounter = -1,
    bool? hasPayload,
    this.discontinuityIndicator = false,
    this.transportScramblingControl = 0,
  }) : hasPayload = hasPayload ?? payload.isNotEmpty;
}

Iterable<TsPacket> parseTsPackets(Uint8List data) sync* {
  const int packetSize = 188;
  for (int off = 0; off + packetSize <= data.length; off += packetSize) {
    final p = data.sublist(off, off + packetSize);
    if (p[0] != 0x47) continue;
    if ((p[1] & 0x80) != 0) continue; // transport_error_indicator

    final payloadUnitStart = (p[1] & 0x40) != 0;
    final pid = ((p[1] & 0x1F) << 8) | p[2];

    final afc = (p[3] >> 4) & 0x03;
    if (afc == 0) continue; // reserved
    final transportScramblingControl = (p[3] >> 6) & 0x03;
    final continuityCounter = p[3] & 0x0f;
    final hasPayload = afc == 1 || afc == 3;
    int idx = 4;
    var discontinuityIndicator = false;

    if (afc == 2 || afc == 3) {
      final adapLen = p[idx];
      if (adapLen > 0 && idx + 1 < p.length) {
        discontinuityIndicator = (p[idx + 1] & 0x80) != 0;
      }
      idx += 1 + adapLen;
      if (idx > 188) continue;
    }

    Uint8List payload = Uint8List(0);
    if (hasPayload && idx < 188) {
      payload = p.sublist(idx);
    }

    yield TsPacket(
      pid: pid,
      payloadUnitStart: payloadUnitStart,
      payload: payload,
      continuityCounter: continuityCounter,
      hasPayload: hasPayload,
      discontinuityIndicator: discontinuityIndicator,
      transportScramblingControl: transportScramblingControl,
    );
  }
}
