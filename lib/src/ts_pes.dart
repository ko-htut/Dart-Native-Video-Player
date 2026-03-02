import 'dart:typed_data';
import 'ts_packets.dart';

Iterable<Uint8List> assemblePesPackets(List<TsPacket> packets, int pid) sync* {
  BytesBuilder? cur;

  for (final pkt in packets) {
    if (pkt.pid != pid) continue;

    if (pkt.payloadUnitStart) {
      if (cur != null) yield cur.toBytes();
      cur = BytesBuilder(copy: false);
      cur.add(pkt.payload);
    } else {
      cur?.add(pkt.payload);
    }
  }
  if (cur != null) yield cur.toBytes();
}
