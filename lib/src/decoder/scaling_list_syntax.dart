import 'bitreader.dart';
import 'exp_golomb.dart';

/// One `seq_scaling_list_present_flag` or `pic_scaling_list_present_flag`
/// entry and, when present, its decoded scan-order values.
///
/// [useDefaultScalingMatrixFlag] preserves the special first-delta value that
/// selects a Table 7-3/Table 7-4 default matrix. An absent entry remains
/// distinct because its effective matrix is selected by scaling-list fallback
/// rule A or B rather than by that default flag.
final class H264ScalingListSyntax {
  const H264ScalingListSyntax.absent(this.size)
    : present = false,
      useDefaultScalingMatrixFlag = false,
      scanValues = null;

  H264ScalingListSyntax._present({
    required this.size,
    required this.useDefaultScalingMatrixFlag,
    required List<int> scanValues,
  }) : present = true,
       scanValues = List<int>.unmodifiable(scanValues);

  /// Number of entries: 16 for a 4x4 list or 64 for an 8x8 list.
  final int size;

  /// Whether the corresponding scaling-list-present syntax flag was one.
  final bool present;

  /// Whether the first decoded `nextScale` selected a normative default list.
  final bool useDefaultScalingMatrixFlag;

  /// Decoded values in bitstream scan order, or null when [present] is false.
  final List<int>? scanValues;

  bool get isExplicit => present && !useDefaultScalingMatrixFlag;

  /// Parses one present H.264 scaling list.
  factory H264ScalingListSyntax.parse(BitReader reader, {required int size}) {
    if (size != 16 && size != 64) {
      throw ArgumentError.value(size, 'size', 'must be 16 or 64');
    }

    var lastScale = 8;
    var nextScale = 8;
    var useDefaultScalingMatrixFlag = false;
    final values = List<int>.filled(size, 8);
    for (var index = 0; index < size; index++) {
      if (nextScale != 0) {
        final deltaScale = readSE(reader);
        if (deltaScale < -128 || deltaScale > 127) {
          throw FormatException(
            'delta_scale[$index]=$deltaScale is outside -128..127',
          );
        }
        nextScale = (lastScale + deltaScale) & 0xff;
        if (index == 0 && nextScale == 0) {
          useDefaultScalingMatrixFlag = true;
        }
      }
      values[index] = nextScale == 0 ? lastScale : nextScale;
      lastScale = values[index];
    }

    return H264ScalingListSyntax._present(
      size: size,
      useDefaultScalingMatrixFlag: useDefaultScalingMatrixFlag,
      scanValues: values,
    );
  }
}
