import 'dart:typed_data';
import 'ts_packets.dart';

class TsPat {
  final Map<int, int> programs;
  TsPat(this.programs);

  static TsPat? find(List<TsPacket> packets) {
    for (final pkt in packets) {
      if (pkt.pid != 0) continue;
      final sec = _extractPsiSection(pkt.payload);
      if (sec == null) continue;
      if (sec[0] != 0x00) continue;

      final sectionLength = ((sec[1] & 0x0F) << 8) | sec[2];
      if (sectionLength + 3 > sec.length) continue;

      final programs = <int, int>{};
      int i = 8;
      final end = 3 + sectionLength - 4;
      while (i + 4 <= end) {
        final programNumber = (sec[i] << 8) | sec[i + 1];
        final pid = ((sec[i + 2] & 0x1F) << 8) | sec[i + 3];
        if (programNumber != 0) programs[programNumber] = pid;
        i += 4;
      }
      if (programs.isNotEmpty) return TsPat(programs);
    }
    return null;
  }
}

class TsStreamInfo {
  final int pid;
  final int streamType;
  const TsStreamInfo({required this.pid, required this.streamType});
}

class TsPmt {
  final List<TsStreamInfo> streams;
  TsPmt(this.streams);

  static TsPmt? find(List<TsPacket> packets, int pmtPid) {
    for (final pkt in packets) {
      if (pkt.pid != pmtPid) continue;
      final sec = _extractPsiSection(pkt.payload);
      if (sec == null) continue;
      if (sec[0] != 0x02) continue;

      final sectionLength = ((sec[1] & 0x0F) << 8) | sec[2];
      if (sectionLength + 3 > sec.length) continue;

      final programInfoLength = ((sec[10] & 0x0F) << 8) | sec[11];
      int i = 12 + programInfoLength;

      final end = 3 + sectionLength - 4;
      final streams = <TsStreamInfo>[];

      while (i + 5 <= end) {
        final streamType = sec[i];
        final pid = ((sec[i + 1] & 0x1F) << 8) | sec[i + 2];
        final esInfoLength = ((sec[i + 3] & 0x0F) << 8) | sec[i + 4];
        streams.add(TsStreamInfo(pid: pid, streamType: streamType));
        i += 5 + esInfoLength;
      }
      if (streams.isNotEmpty) return TsPmt(streams);
    }
    return null;
  }
}

Uint8List? _extractPsiSection(Uint8List payload) {
  if (payload.isEmpty) return null;
  int idx = 0;
  final pointerField = payload[idx];
  idx += 1 + pointerField;
  if (idx >= payload.length) return null;
  return payload.sublist(idx);
}
