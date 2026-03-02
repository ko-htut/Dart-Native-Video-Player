import 'dart:typed_data';

class TsPacket {
  final int pid;
  final bool payloadUnitStart;
  final Uint8List payload;

  TsPacket({
    required this.pid,
    required this.payloadUnitStart,
    required this.payload,
  });
}

Iterable<TsPacket> parseTsPackets(Uint8List data) sync* {
  const int packetSize = 188;
  for (int off = 0; off + packetSize <= data.length; off += packetSize) {
    final p = data.sublist(off, off + packetSize);
    if (p[0] != 0x47) continue;

    final payloadUnitStart = (p[1] & 0x40) != 0;
    final pid = ((p[1] & 0x1F) << 8) | p[2];

    final afc = (p[3] >> 4) & 0x03;
    int idx = 4;

    if (afc == 2 || afc == 3) {
      final adapLen = p[idx];
      idx += 1 + adapLen;
      if (idx > 188) continue;
    }

    Uint8List payload = Uint8List(0);
    if (afc == 1 || afc == 3) {
      payload = p.sublist(idx);
    }

    yield TsPacket(
      pid: pid,
      payloadUnitStart: payloadUnitStart,
      payload: payload,
    );
  }
}
