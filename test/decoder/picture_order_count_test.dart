import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/picture_order_count.dart';

void main() {
  group('progressive POC type 0', () {
    test('uses the normative asymmetric half-range wrap rules', () {
      final tracker = H264PocType0Tracker();

      expect(_idr(tracker, max: 16).pictureOrderCount, 0);
      expect(_reference(tracker, lsb: 8, max: 16).pictureOrderCount, 8);

      final wrapped = _reference(tracker, lsb: 0, max: 16);
      expect(wrapped.picOrderCntMsb, 16);
      expect(wrapped.pictureOrderCount, 16);

      tracker.reset();
      _idr(tracker, max: 16);
      final exactlyHalfRange = tracker.derivePictureOrderCount(
        picOrderCntLsb: 8,
        maxPicOrderCntLsb: 16,
        isIdr: false,
        isReference: false,
      );
      expect(exactlyHalfRange.picOrderCntMsb, 0);
      expect(exactlyHalfRange.pictureOrderCount, 8);
    });

    test(
      'non-reference B pictures do not advance previous-reference state',
      () {
        final tracker = H264PocType0Tracker();
        _idr(tracker, max: 64);
        _reference(tracker, lsb: 28, max: 64);
        _reference(tracker, lsb: 60, max: 64);

        final firstB = tracker.derivePictureOrderCount(
          picOrderCntLsb: 2,
          maxPicOrderCntLsb: 64,
          isIdr: false,
          isReference: false,
        );
        final secondB = tracker.derivePictureOrderCount(
          picOrderCntLsb: 4,
          maxPicOrderCntLsb: 64,
          isIdr: false,
          isReference: false,
        );

        expect(firstB.pictureOrderCount, 66);
        expect(secondB.pictureOrderCount, 68);
        expect(tracker.previousReferenceState!.picOrderCntLsb, 60);
        expect(tracker.previousReferenceState!.picOrderCntMsb, 0);

        final nextReference = _reference(tracker, lsb: 6, max: 64);
        expect(nextReference.pictureOrderCount, 70);
        expect(tracker.previousReferenceState!.picOrderCntLsb, 6);
        expect(tracker.previousReferenceState!.picOrderCntMsb, 64);
      },
    );

    test('derives frame POC from both fields and normalizes MMCO 5', () {
      final tracker = H264PocType0Tracker();
      _idr(tracker, max: 16);

      final resetPicture = tracker.derivePictureOrderCount(
        picOrderCntLsb: 4,
        maxPicOrderCntLsb: 16,
        isIdr: false,
        isReference: true,
        deltaPicOrderCntBottom: -2,
        memoryManagementControlOperation5: true,
      );
      expect(resetPicture.topFieldOrderCount, 2);
      expect(resetPicture.bottomFieldOrderCount, 0);
      expect(resetPicture.pictureOrderCount, 0);
      expect(
        tracker.previousReferenceState!.memoryManagementControlOperation5,
        isTrue,
      );

      final afterReset = _reference(tracker, lsb: 3, max: 16);
      expect(afterReset.picOrderCntMsb, 0);
      expect(afterReset.pictureOrderCount, 3);
    });

    test('rejects dependent startup and invalid bounded inputs', () {
      final tracker = H264PocType0Tracker();
      expect(() => _reference(tracker, lsb: 0, max: 16), throwsStateError);
      expect(
        () => tracker.derivePictureOrderCount(
          picOrderCntLsb: 0,
          maxPicOrderCntLsb: 12,
          isIdr: true,
          isReference: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => tracker.derivePictureOrderCount(
          picOrderCntLsb: 16,
          maxPicOrderCntLsb: 16,
          isIdr: true,
          isReference: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => tracker.derivePictureOrderCount(
          picOrderCntLsb: 0,
          maxPicOrderCntLsb: 16,
          isIdr: true,
          isReference: false,
        ),
        throwsFormatException,
      );
    });

    test('discarded failed fork does not change canonical wrap state', () {
      final tracker = H264PocType0Tracker();
      _idr(tracker, max: 64);

      final candidate = tracker.fork();
      expect(_reference(candidate, lsb: 40, max: 64).pictureOrderCount, -24);
      expect(
        () => candidate.derivePictureOrderCount(
          picOrderCntLsb: 64,
          maxPicOrderCntLsb: 64,
          isIdr: false,
          isReference: true,
        ),
        throwsArgumentError,
      );

      expect(tracker.previousReferenceState!.picOrderCntLsb, 0);
      expect(tracker.previousReferenceState!.picOrderCntMsb, 0);
      expect(_reference(tracker, lsb: 20, max: 64).pictureOrderCount, 20);
    });

    test('committed fork atomically changes canonical wrap state', () {
      final tracker = H264PocType0Tracker();
      _idr(tracker, max: 64);

      final candidate = tracker.fork();
      expect(_reference(candidate, lsb: 40, max: 64).pictureOrderCount, -24);
      tracker.commitFrom(candidate);

      expect(tracker.previousReferenceState!.picOrderCntLsb, 40);
      expect(tracker.previousReferenceState!.picOrderCntMsb, -64);
      expect(_reference(tracker, lsb: 20, max: 64).pictureOrderCount, -44);
    });

    test('commit enforces candidate identity, freshness, and single use', () {
      final tracker = H264PocType0Tracker();
      _idr(tracker, max: 64);

      expect(() => tracker.commitFrom(tracker), throwsArgumentError);
      expect(
        () => tracker.commitFrom(H264PocType0Tracker()),
        throwsArgumentError,
      );

      final committed = tracker.fork();
      final staleSibling = tracker.fork();
      _reference(committed, lsb: 4, max: 64);
      tracker.commitFrom(committed);

      expect(() => tracker.commitFrom(committed), throwsStateError);
      expect(() => committed.reset(), throwsStateError);
      expect(() => tracker.commitFrom(staleSibling), throwsStateError);
    });
  });
}

H264PictureOrderCount _idr(H264PocType0Tracker tracker, {required int max}) =>
    tracker.derivePictureOrderCount(
      picOrderCntLsb: 0,
      maxPicOrderCntLsb: max,
      isIdr: true,
      isReference: true,
    );

H264PictureOrderCount _reference(
  H264PocType0Tracker tracker, {
  required int lsb,
  required int max,
}) => tracker.derivePictureOrderCount(
  picOrderCntLsb: lsb,
  maxPicOrderCntLsb: max,
  isIdr: false,
  isReference: true,
);
