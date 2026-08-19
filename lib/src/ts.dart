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
    if (p[0] != 0x47) continue; // sync

    final payloadUnitStart = (p[1] & 0x40) != 0;
    final pid = ((p[1] & 0x1F) << 8) | p[2];

    final afc = (p[3] >> 4) & 0x03; // 1=payload,2=adaptation,3=both
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

// ==========================
// PAT / PMT parsing (minimal)
// ==========================

class TsPat {
  final Map<int, int> programs; // programNumber -> pmtPid
  TsPat(this.programs);

  static TsPat? find(List<TsPacket> packets) {
    // PID 0 is PAT
    for (final pkt in packets) {
      if (pkt.pid != 0) continue;
      final sec = _extractPsiSection(pkt.payload);
      if (sec == null) continue;

      // section[0] = table_id (0x00 for PAT)
      if (sec[0] != 0x00) continue;

      final sectionLength = ((sec[1] & 0x0F) << 8) | sec[2];
      if (sectionLength + 3 > sec.length) continue;

      // programs start at offset 8, end before CRC (last 4 bytes)
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

      // table_id for PMT is 0x02
      if (sec[0] != 0x02) continue;

      final sectionLength = ((sec[1] & 0x0F) << 8) | sec[2];
      if (sectionLength + 3 > sec.length) continue;

      final programInfoLength = ((sec[10] & 0x0F) << 8) | sec[11];
      int i = 12 + programInfoLength;

      final end = 3 + sectionLength - 4; // before CRC
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

// PSI section extraction (handles pointer_field)
Uint8List? _extractPsiSection(Uint8List payload) {
  if (payload.isEmpty) return null;
  int idx = 0;

  final pointerField = payload[idx];
  idx += 1 + pointerField;
  if (idx >= payload.length) return null;

  return payload.sublist(idx);
}

// ==========================
// PES -> Elementary Stream
// ==========================

Uint8List extractElementaryStream(List<TsPacket> packets, int pid) {
  final out = BytesBuilder(copy: false);

  BytesBuilder? curPes;
  for (final pkt in packets) {
    if (pkt.pid != pid) continue;

    if (pkt.payloadUnitStart) {
      if (curPes != null) {
        _appendPesPayload(out, curPes.toBytes());
      }
      curPes = BytesBuilder(copy: false);
      curPes.add(pkt.payload);
    } else {
      curPes?.add(pkt.payload);
    }
  }

  if (curPes != null) {
    _appendPesPayload(out, curPes.toBytes());
  }

  return out.toBytes();
}

void _appendPesPayload(BytesBuilder out, Uint8List pes) {
  // PES header start code: 00 00 01
  if (pes.length < 9) return;
  if (!(pes[0] == 0x00 && pes[1] == 0x00 && pes[2] == 0x01)) return;

  final headerDataLen = pes[8];

  // payload starts after 9 + headerDataLen
  final payloadStart = 9 + headerDataLen;
  if (payloadStart >= pes.length) return;

  // NOTE: the PES flags byte (pes[7]) can advertise PTS/DTS; it is ignored.
  out.add(pes.sublist(payloadStart));
}
