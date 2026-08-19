import 'bitreader.dart';

class VlcNode {
  VlcNode? zero;
  VlcNode? one;
  int? value;
}

VlcNode buildVlcTree(Map<String, int> table) {
  if (table.isEmpty) {
    throw ArgumentError.value(table, 'table', 'must not be empty');
  }

  final root = VlcNode();
  for (final entry in table.entries) {
    final code = entry.key;
    if (code.isEmpty) {
      throw ArgumentError.value(code, 'table code', 'must not be empty');
    }

    var node = root;
    for (var index = 0; index < code.length; index++) {
      if (node.value != null) {
        throw ArgumentError(
          'VLC table is not prefix-free: an existing code prefixes "$code"',
        );
      }

      final bit = code.codeUnitAt(index);
      if (bit == 0x30) {
        node.zero ??= VlcNode();
        node = node.zero!;
      } else if (bit == 0x31) {
        node.one ??= VlcNode();
        node = node.one!;
      } else {
        throw ArgumentError.value(
          code,
          'table code',
          'may contain only 0 and 1',
        );
      }
    }

    if (node.value != null) {
      throw ArgumentError('duplicate VLC code "$code"');
    }
    if (node.zero != null || node.one != null) {
      throw ArgumentError(
        'VLC table is not prefix-free: "$code" prefixes another code',
      );
    }
    node.value = entry.value;
  }
  return root;
}

/// Reads one value from a prefix-free VLC tree.
///
/// Failures are intentionally not transactional. A dead-end or truncated VLC
/// means the enclosing syntax structure is corrupt and its caller must abort.
int readVlc(BitReader reader, VlcNode root, {int maxBits = 32}) {
  if (maxBits <= 0) {
    throw RangeError.range(maxBits, 1, null, 'maxBits');
  }

  var node = root;
  final code = StringBuffer();
  final startBit = reader.bitPos;

  for (var length = 1; length <= maxBits; length++) {
    if (reader.eof) {
      throw BitstreamFormatException(
        'truncated VLC starting at bit $startBit after "${code.toString()}"',
        reader.bitPos,
      );
    }

    final bit = reader.readBit();
    code.write(bit);
    final next = bit == 0 ? node.zero : node.one;
    if (next == null) {
      throw BitstreamFormatException(
        'invalid VLC starting at bit $startBit: no code has prefix '
        '"${code.toString()}"',
        reader.bitPos,
      );
    }
    node = next;

    final value = node.value;
    if (value != null) return value;
  }

  throw BitstreamFormatException(
    'VLC starting at bit $startBit exceeds $maxBits bits '
    '(prefix "${code.toString()}")',
    reader.bitPos,
  );
}
