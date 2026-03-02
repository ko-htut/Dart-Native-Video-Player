import 'bitreader.dart';

class VlcNode {
  VlcNode? zero;
  VlcNode? one;
  int? value;
}

VlcNode buildVlcTree(Map<String, int> table) {
  final root = VlcNode();
  table.forEach((code, val) {
    var n = root;
    for (final ch in code.split('')) {
      if (ch == '0') {
        n.zero ??= VlcNode();
        n = n.zero!;
      } else {
        n.one ??= VlcNode();
        n = n.one!;
      }
    }
    n.value = val;
  });
  return root;
}

int readVlc(BitReader br, VlcNode root, {int maxBits = 32}) {
  var n = root;
  for (int i = 0; i < maxBits; i++) {
    if (br.eof) {
      throw StateError('VLC unexpected EOF');
    }
    final b = br.readBit();
    n = (b == 0)
        ? (n.zero ?? (throw StateError('VLC dead end')))
        : (n.one ?? (throw StateError('VLC dead end')));
    if (n.value != null) return n.value!;
  }
  throw StateError('VLC too long');
}
