import 'dart:typed_data';
import 'ts_packets.dart';

Iterable<Uint8List> assemblePesPackets(List<TsPacket> packets, int pid) sync* {
  final assembler = TsPesAssembler(pid);
  yield* assembler.pushPackets(packets);
  final finalPacket = assembler.flush();
  if (finalPacket != null) yield finalPacket;
}

/// Stateful, continuity-aware PES reassembler for one MPEG-TS PID.
///
/// State deliberately survives [pushPackets] calls so a PES packet split at an
/// HLS segment boundary is completed by the next segment. A gap, duplicate, or
/// explicit discontinuity never mixes bytes from different PES packets.
final class TsPesAssembler {
  TsPesAssembler(this.pid);

  final int pid;
  BytesBuilder? _current;
  int? _lastContinuityCounter;

  int continuityErrorCount = 0;
  int duplicatePacketCount = 0;
  int scrambledPacketCount = 0;
  int discontinuityCount = 0;

  List<Uint8List> pushPackets(Iterable<TsPacket> packets) {
    final completed = <Uint8List>[];
    for (final packet in packets) {
      if (packet.pid != pid || !packet.hasPayload) continue;

      if (packet.transportScramblingControl != 0) {
        scrambledPacketCount++;
        discontinuityCount++;
        _discardPartial();
        _lastContinuityCounter = packet.continuityCounter >= 0
            ? packet.continuityCounter
            : null;
        continue;
      }

      if (packet.discontinuityIndicator) {
        discontinuityCount++;
        _discardPartial();
        _lastContinuityCounter = null;
      }

      final previousCounter = _lastContinuityCounter;
      if (previousCounter != null && packet.continuityCounter >= 0) {
        if (packet.continuityCounter == previousCounter) {
          duplicatePacketCount++;
          continue;
        }
        final expected = (previousCounter + 1) & 0x0f;
        if (packet.continuityCounter != expected) {
          continuityErrorCount++;
          discontinuityCount++;
          _discardPartial();
        }
      }
      _lastContinuityCounter = packet.continuityCounter >= 0
          ? packet.continuityCounter
          : null;

      if (packet.payloadUnitStart) {
        final previous = _takeCurrent();
        if (previous != null) completed.add(previous);
        if (_isPesStart(packet.payload)) {
          _current = BytesBuilder(copy: false)..add(packet.payload);
        }
      } else {
        _current?.add(packet.payload);
      }
    }
    return List<Uint8List>.unmodifiable(completed);
  }

  Uint8List? flush() => _takeCurrent();

  void reset() {
    _current = null;
    _lastContinuityCounter = null;
    continuityErrorCount = 0;
    duplicatePacketCount = 0;
    scrambledPacketCount = 0;
    discontinuityCount = 0;
  }

  Uint8List? _takeCurrent() {
    final current = _current;
    _current = null;
    if (current == null) return null;
    final bytes = current.toBytes();
    return _isPesStart(bytes) ? bytes : null;
  }

  void _discardPartial() => _current = null;
}

bool _isPesStart(Uint8List bytes) {
  return bytes.length >= 3 &&
      bytes[0] == 0x00 &&
      bytes[1] == 0x00 &&
      bytes[2] == 0x01;
}
