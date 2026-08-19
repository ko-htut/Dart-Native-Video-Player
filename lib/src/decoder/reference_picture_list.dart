import 'slice_header.dart';

/// One decoded short-term reference and the `frame_num` signalled for it.
final class H264ShortTermReference<T> {
  const H264ShortTermReference({required this.frameNum, required this.value});

  final int frameNum;
  final T value;
}

final class _ReferenceWithPicNum<T> {
  const _ReferenceWithPicNum(this.reference, this.picNum);

  final H264ShortTermReference<T> reference;
  final int picNum;
}

/// Builds RefPicList0 for a progressive P picture from short-term references.
///
/// Initial ordering is descending PicNum. List-modification operations 0 and 1
/// are then applied using the normative PicNum prediction and wrap rules. This
/// decoder subset deliberately has no long-term reference pictures, so an idc
/// 2 modification is rejected rather than silently selecting the wrong frame.
List<H264ShortTermReference<T>> buildPReferenceList0<T>({
  required Iterable<H264ShortTermReference<T>> shortTermReferences,
  required int currentFrameNum,
  required int maxFrameNum,
  required int activeReferenceCount,
  Iterable<RefPicListModification> modifications = const [],
}) {
  if (maxFrameNum <= 0) {
    throw ArgumentError.value(maxFrameNum, 'maxFrameNum', 'must be positive');
  }
  if (currentFrameNum < 0 || currentFrameNum >= maxFrameNum) {
    throw ArgumentError.value(
      currentFrameNum,
      'currentFrameNum',
      'must be in 0..${maxFrameNum - 1}',
    );
  }
  if (activeReferenceCount <= 0) {
    throw ArgumentError.value(
      activeReferenceCount,
      'activeReferenceCount',
      'must be positive',
    );
  }

  final available = <_ReferenceWithPicNum<T>>[
    for (final reference in shortTermReferences)
      _ReferenceWithPicNum<T>(
        reference,
        reference.frameNum > currentFrameNum
            ? reference.frameNum - maxFrameNum
            : reference.frameNum,
      ),
  ]..sort((left, right) => right.picNum.compareTo(left.picNum));
  final list = List<_ReferenceWithPicNum<T>>.of(available);

  var predictedPicNum = currentFrameNum;
  var insertionIndex = 0;
  for (final modification in modifications) {
    if (modification.idc == 2) {
      throw const FormatException(
        'Long-term reference-list reordering is unsupported',
      );
    }
    if (modification.idc != 0 && modification.idc != 1) {
      throw FormatException(
        'Invalid modification_of_pic_nums_idc=${modification.idc}',
      );
    }

    final absoluteDifference = modification.value + 1;
    if (absoluteDifference <= 0 || absoluteDifference > maxFrameNum) {
      throw FormatException(
        'Invalid abs_diff_pic_num_minus1=${modification.value}',
      );
    }
    if (modification.idc == 0) {
      predictedPicNum -= absoluteDifference;
      if (predictedPicNum < 0) predictedPicNum += maxFrameNum;
    } else {
      predictedPicNum += absoluteDifference;
      if (predictedPicNum >= maxFrameNum) predictedPicNum -= maxFrameNum;
    }
    final selectedPicNum = predictedPicNum > currentFrameNum
        ? predictedPicNum - maxFrameNum
        : predictedPicNum;
    final selected = available.where(
      (candidate) => candidate.picNum == selectedPicNum,
    );
    if (selected.isEmpty) {
      throw FormatException(
        'Reference-list reordering selects unavailable PicNum '
        '$selectedPicNum',
      );
    }

    final reference = selected.first;
    list.insert(insertionIndex, reference);
    insertionIndex++;
    for (var index = insertionIndex; index < list.length;) {
      if (list[index].picNum == selectedPicNum) {
        list.removeAt(index);
      } else {
        index++;
      }
    }
  }

  if (list.length < activeReferenceCount) {
    throw FormatException(
      'P picture requests $activeReferenceCount active list-0 references, '
      'but only ${list.length} short-term reference picture(s) are decoded',
    );
  }
  return List<H264ShortTermReference<T>>.unmodifiable(
    list.take(activeReferenceCount).map((candidate) => candidate.reference),
  );
}
