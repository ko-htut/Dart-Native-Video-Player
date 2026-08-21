import 'slice_header.dart';

/// One decoded short-term reference and the `frame_num` signalled for it.
final class H264ShortTermReference<T> {
  const H264ShortTermReference({
    required this.frameNum,
    required this.value,
    this.pictureOrderCount,
  });

  final int frameNum;
  final T value;

  /// Frame picture order count used to initialize B-slice List0/List1.
  ///
  /// P-slice callers may omit it. B-slice construction rejects an omitted POC
  /// instead of silently substituting decode order.
  final int? pictureOrderCount;
}

final class _ReferenceWithPicNum<T> {
  const _ReferenceWithPicNum(this.reference, this.picNum);

  final H264ShortTermReference<T> reference;
  final int picNum;
}

/// Result of marking one short-term reference unused through MMCO 1.
final class H264Mmco1Result<T> {
  const H264Mmco1Result({
    required this.remaining,
    required this.removed,
    required this.picNumX,
  });

  final List<H264ShortTermReference<T>> remaining;
  final H264ShortTermReference<T> removed;

  /// The signed short-term picture number selected by the operation.
  final int picNumX;
}

/// Pure result of progressive short-term decoded-picture marking.
///
/// [references] and [removed] retain the exact input/current reference objects,
/// including their typed payload identities. Both lists are unmodifiable.
final class H264ShortTermDpbMarkingResult<T> {
  const H264ShortTermDpbMarkingResult({
    required this.references,
    required this.removed,
    required this.appendedCurrentPicture,
  });

  final List<H264ShortTermReference<T>> references;
  final List<H264ShortTermReference<T>> removed;
  final bool appendedCurrentPicture;
}

/// Derives the next progressive short-term DPB without mutating its input.
///
/// This bounded subset supports only short-term frame references. A
/// non-reference picture returns an unchanged snapshot. A reference picture
/// either applies the non-adaptive sliding-window process or every parsed MMCO
/// 1 operation in syntax order, then appends [currentPicture]. Adaptive
/// operations other than MMCO 1 are rejected rather than partially committed.
///
/// For an IDR picture, the caller supplies an empty [shortTermReferences]
/// working set. This lets a failed IDR discard the result without clearing the
/// canonical DPB.
H264ShortTermDpbMarkingResult<T> applyShortTermDpbMarking<T>({
  required Iterable<H264ShortTermReference<T>> shortTermReferences,
  required H264ShortTermReference<T> currentPicture,
  required int maxFrameNum,
  required int maxNumRefFrames,
  required int nalRefIdc,
  required bool adaptiveRefPicMarkingModeFlag,
  Iterable<MemoryManagementOperation> memoryManagementOperations = const [],
}) {
  if (maxNumRefFrames < 0) {
    throw ArgumentError.value(
      maxNumRefFrames,
      'maxNumRefFrames',
      'must be non-negative',
    );
  }
  if (nalRefIdc < 0 || nalRefIdc > 3) {
    throw ArgumentError.value(nalRefIdc, 'nalRefIdc', 'must be in 0..3');
  }
  final references = _validatedShortTermReferences(
    shortTermReferences: shortTermReferences,
    currentFrameNum: currentPicture.frameNum,
    maxFrameNum: maxFrameNum,
  );
  final operations = List<MemoryManagementOperation>.of(
    memoryManagementOperations,
  );

  if (nalRefIdc == 0) {
    return H264ShortTermDpbMarkingResult<T>(
      references: List<H264ShortTermReference<T>>.unmodifiable(references),
      removed: List<H264ShortTermReference<T>>.empty(growable: false),
      appendedCurrentPicture: false,
    );
  }
  if (maxNumRefFrames == 0) {
    throw const FormatException(
      'A reference picture cannot be retained when max_num_ref_frames is zero',
    );
  }
  if (references.any(
    (reference) => reference.frameNum == currentPicture.frameNum,
  )) {
    throw FormatException(
      'Current reference frame_num=${currentPicture.frameNum} already exists '
      'in the short-term DPB',
    );
  }

  var working = List<H264ShortTermReference<T>>.of(references);
  final removed = <H264ShortTermReference<T>>[];
  if (adaptiveRefPicMarkingModeFlag) {
    for (final operation in operations) {
      final result = applyShortTermMmco1<T>(
        shortTermReferences: working,
        currentFrameNum: currentPicture.frameNum,
        maxFrameNum: maxFrameNum,
        operation: operation,
      );
      working = List<H264ShortTermReference<T>>.of(result.remaining);
      removed.add(result.removed);
    }
    if (working.length >= maxNumRefFrames) {
      throw FormatException(
        'Adaptive marking leaves ${working.length + 1} short-term references '
        'after appending the current picture; max_num_ref_frames is '
        '$maxNumRefFrames',
      );
    }
  } else {
    if (operations.isNotEmpty) {
      throw const FormatException(
        'Memory-management operations require adaptive marking mode',
      );
    }
    while (working.length >= maxNumRefFrames) {
      removed.add(
        working.removeAt(
          _oldestShortTermReferenceIndex(
            working,
            currentFrameNum: currentPicture.frameNum,
            maxFrameNum: maxFrameNum,
          ),
        ),
      );
    }
  }

  working.add(currentPicture);
  return H264ShortTermDpbMarkingResult<T>(
    references: List<H264ShortTermReference<T>>.unmodifiable(working),
    removed: List<H264ShortTermReference<T>>.unmodifiable(removed),
    appendedCurrentPicture: true,
  );
}

/// Applies progressive-frame memory-management control operation 1.
///
/// `difference_of_pic_nums_minus1` is interpreted relative to CurrPicNum. A
/// negative [H264Mmco1Result.picNumX] selects a reference whose `frame_num`
/// wrapped at [maxFrameNum]. Other MMCO operations and long-term pictures are
/// deliberately outside this helper's bounded scope.
H264Mmco1Result<T> applyShortTermMmco1<T>({
  required Iterable<H264ShortTermReference<T>> shortTermReferences,
  required int currentFrameNum,
  required int maxFrameNum,
  required MemoryManagementOperation operation,
}) {
  final references = _validatedShortTermReferences(
    shortTermReferences: shortTermReferences,
    currentFrameNum: currentFrameNum,
    maxFrameNum: maxFrameNum,
  );
  if (operation.operation != 1 || operation.differenceOfPicNumsMinus1 == null) {
    throw FormatException(
      'Expected MMCO 1 with difference_of_pic_nums_minus1, got '
      'operation ${operation.operation}',
    );
  }
  final differenceOfPicNumsMinus1 = operation.differenceOfPicNumsMinus1!;
  if (differenceOfPicNumsMinus1 < 0 ||
      differenceOfPicNumsMinus1 >= maxFrameNum) {
    throw FormatException(
      'Invalid MMCO 1 difference_of_pic_nums_minus1='
      '$differenceOfPicNumsMinus1',
    );
  }

  final picNumX = currentFrameNum - (differenceOfPicNumsMinus1 + 1);
  final matchingIndexes = <int>[];
  for (var index = 0; index < references.length; index++) {
    if (_frameNumWrap(
          references[index].frameNum,
          currentFrameNum,
          maxFrameNum,
        ) ==
        picNumX) {
      matchingIndexes.add(index);
    }
  }
  if (matchingIndexes.length != 1) {
    throw FormatException(
      matchingIndexes.isEmpty
          ? 'MMCO 1 selects unavailable PicNum $picNumX'
          : 'MMCO 1 PicNum $picNumX is ambiguous in the short-term DPB',
    );
  }

  final removed = references.removeAt(matchingIndexes.single);
  return H264Mmco1Result<T>(
    remaining: List<H264ShortTermReference<T>>.unmodifiable(references),
    removed: removed,
    picNumX: picNumX,
  );
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
  final references = _validatedShortTermReferences(
    shortTermReferences: shortTermReferences,
    currentFrameNum: currentFrameNum,
    maxFrameNum: maxFrameNum,
  );
  if (activeReferenceCount <= 0) {
    throw ArgumentError.value(
      activeReferenceCount,
      'activeReferenceCount',
      'must be positive',
    );
  }

  final available = <_ReferenceWithPicNum<T>>[
    for (final reference in references)
      _ReferenceWithPicNum<T>(
        reference,
        reference.frameNum > currentFrameNum
            ? reference.frameNum - maxFrameNum
            : reference.frameNum,
      ),
  ]..sort((left, right) => right.picNum.compareTo(left.picNum));
  final list = _applyShortTermModifications<T>(
    initial: available,
    available: available,
    currentFrameNum: currentFrameNum,
    maxFrameNum: maxFrameNum,
    modifications: modifications,
  );

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

/// Builds the initial and modified short-term reference lists for a
/// progressive B picture.
///
/// List0 begins with earlier pictures in descending POC followed by later
/// pictures in ascending POC. List1 uses the opposite order; if the two lists
/// would otherwise be identical, its first two entries are exchanged as
/// required by H.264 8.2.4.2.3. Long-term pictures are deliberately outside
/// this decoder subset.
({List<H264ShortTermReference<T>> list0, List<H264ShortTermReference<T>> list1})
buildBReferenceLists<T>({
  required Iterable<H264ShortTermReference<T>> shortTermReferences,
  required int currentFrameNum,
  required int currentPictureOrderCount,
  required int maxFrameNum,
  required int activeReferenceCountL0,
  required int activeReferenceCountL1,
  Iterable<RefPicListModification> modificationsL0 = const [],
  Iterable<RefPicListModification> modificationsL1 = const [],
}) {
  final references = _validatedShortTermReferences(
    shortTermReferences: shortTermReferences,
    currentFrameNum: currentFrameNum,
    maxFrameNum: maxFrameNum,
  );
  if (activeReferenceCountL0 <= 0 || activeReferenceCountL1 <= 0) {
    throw ArgumentError('B reference-list active counts must both be positive');
  }

  final available = <_ReferenceWithPicNum<T>>[
    for (final reference in references)
      _ReferenceWithPicNum<T>(
        reference,
        reference.frameNum > currentFrameNum
            ? reference.frameNum - maxFrameNum
            : reference.frameNum,
      ),
  ];
  for (final candidate in available) {
    if (candidate.reference.pictureOrderCount == null) {
      throw const FormatException(
        'B reference-list construction requires picture order counts',
      );
    }
  }

  final beforeCurrent =
      available
          .where(
            (candidate) =>
                candidate.reference.pictureOrderCount! <
                currentPictureOrderCount,
          )
          .toList()
        ..sort(
          (left, right) => right.reference.pictureOrderCount!.compareTo(
            left.reference.pictureOrderCount!,
          ),
        );
  final atOrAfterCurrent =
      available
          .where(
            (candidate) =>
                candidate.reference.pictureOrderCount! >=
                currentPictureOrderCount,
          )
          .toList()
        ..sort(
          (left, right) => left.reference.pictureOrderCount!.compareTo(
            right.reference.pictureOrderCount!,
          ),
        );
  final afterCurrent =
      available
          .where(
            (candidate) =>
                candidate.reference.pictureOrderCount! >
                currentPictureOrderCount,
          )
          .toList()
        ..sort(
          (left, right) => left.reference.pictureOrderCount!.compareTo(
            right.reference.pictureOrderCount!,
          ),
        );
  final atOrBeforeCurrent =
      available
          .where(
            (candidate) =>
                candidate.reference.pictureOrderCount! <=
                currentPictureOrderCount,
          )
          .toList()
        ..sort(
          (left, right) => right.reference.pictureOrderCount!.compareTo(
            left.reference.pictureOrderCount!,
          ),
        );

  final initialL0 = <_ReferenceWithPicNum<T>>[
    ...beforeCurrent,
    ...atOrAfterCurrent,
  ];
  final initialL1 = <_ReferenceWithPicNum<T>>[
    ...afterCurrent,
    ...atOrBeforeCurrent,
  ];
  if (_sameReferences(initialL0, initialL1) && initialL1.length > 1) {
    final first = initialL1[0];
    initialL1[0] = initialL1[1];
    initialL1[1] = first;
  }

  final list0 = _applyShortTermModifications<T>(
    initial: initialL0,
    available: available,
    currentFrameNum: currentFrameNum,
    maxFrameNum: maxFrameNum,
    modifications: modificationsL0,
  );
  final list1 = _applyShortTermModifications<T>(
    initial: initialL1,
    available: available,
    currentFrameNum: currentFrameNum,
    maxFrameNum: maxFrameNum,
    modifications: modificationsL1,
  );
  if (list0.length < activeReferenceCountL0 ||
      list1.length < activeReferenceCountL1) {
    throw FormatException(
      'B picture requests $activeReferenceCountL0/$activeReferenceCountL1 '
      'active references but only ${list0.length}/${list1.length} '
      'short-term reference picture(s) are decoded',
    );
  }
  return (
    list0: List<H264ShortTermReference<T>>.unmodifiable(
      list0
          .take(activeReferenceCountL0)
          .map((candidate) => candidate.reference),
    ),
    list1: List<H264ShortTermReference<T>>.unmodifiable(
      list1
          .take(activeReferenceCountL1)
          .map((candidate) => candidate.reference),
    ),
  );
}

List<_ReferenceWithPicNum<T>> _applyShortTermModifications<T>({
  required Iterable<_ReferenceWithPicNum<T>> initial,
  required List<_ReferenceWithPicNum<T>> available,
  required int currentFrameNum,
  required int maxFrameNum,
  required Iterable<RefPicListModification> modifications,
}) {
  final list = List<_ReferenceWithPicNum<T>>.of(initial);
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
  return list;
}

bool _sameReferences<T>(
  List<_ReferenceWithPicNum<T>> left,
  List<_ReferenceWithPicNum<T>> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

List<H264ShortTermReference<T>> _validatedShortTermReferences<T>({
  required Iterable<H264ShortTermReference<T>> shortTermReferences,
  required int currentFrameNum,
  required int maxFrameNum,
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
  final references = List<H264ShortTermReference<T>>.of(shortTermReferences);
  final seenFrameNumbers = <int>{};
  for (final reference in references) {
    if (reference.frameNum < 0 || reference.frameNum >= maxFrameNum) {
      throw ArgumentError.value(
        reference.frameNum,
        'shortTermReferences.frameNum',
        'must be in 0..${maxFrameNum - 1}',
      );
    }
    if (!seenFrameNumbers.add(reference.frameNum)) {
      throw FormatException(
        'Duplicate short-term reference frame_num=${reference.frameNum}',
      );
    }
  }
  return references;
}

int _frameNumWrap(int frameNum, int currentFrameNum, int maxFrameNum) =>
    frameNum > currentFrameNum ? frameNum - maxFrameNum : frameNum;

int _oldestShortTermReferenceIndex<T>(
  List<H264ShortTermReference<T>> references, {
  required int currentFrameNum,
  required int maxFrameNum,
}) {
  if (references.isEmpty) {
    throw StateError('Cannot evict from an empty short-term DPB');
  }
  var oldestIndex = 0;
  var oldestPicNum = _frameNumWrap(
    references.first.frameNum,
    currentFrameNum,
    maxFrameNum,
  );
  for (var index = 1; index < references.length; index++) {
    final picNum = _frameNumWrap(
      references[index].frameNum,
      currentFrameNum,
      maxFrameNum,
    );
    if (picNum < oldestPicNum) {
      oldestIndex = index;
      oldestPicNum = picNum;
    }
  }
  return oldestIndex;
}
