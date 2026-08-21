import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/deblocking_filter.dart';

void main() {
  group('dual-list B boundary strength', () {
    test('preserves the legacy P constructor and stable List0 alias', () {
      const p = H264DeblockingBlock(
        referenceIndexL0: 2,
        referencePictureId: 17,
        motionVectorL0: H264MotionVector(3, -3),
      );
      const q = H264DeblockingBlock(
        referenceIndexL0: 5,
        referencePictureIdL0: 17,
      );

      expect(p.referencePictureIdL0, 17);
      expect(p.referenceIndexL1, -1);
      expect(p.referencePictureIdL1, isNull);
      expect(p.hasSameReferenceAs(q), isTrue);
      expect(_strength(p, q), 0);
    });

    test('matches straight stable pairs and checks corresponding vectors', () {
      const p = H264DeblockingBlock(
        referenceIndexL0: 0,
        referencePictureIdL0: 10,
        motionVectorL0: H264MotionVector(1, -1),
        referenceIndexL1: 0,
        referencePictureIdL1: 20,
        motionVectorL1: H264MotionVector(-2, 2),
      );
      const belowThreshold = H264DeblockingBlock(
        referenceIndexL0: 3,
        referencePictureIdL0: 10,
        motionVectorL0: H264MotionVector(4, -4),
        referenceIndexL1: 2,
        referencePictureIdL1: 20,
        motionVectorL1: H264MotionVector(1, 5),
      );
      const atThreshold = H264DeblockingBlock(
        referenceIndexL0: 3,
        referencePictureIdL0: 10,
        motionVectorL0: H264MotionVector(5, -1),
        referenceIndexL1: 2,
        referencePictureIdL1: 20,
        motionVectorL1: H264MotionVector(-2, 2),
      );

      expect(p.hasEquivalentReferencePairAs(belowThreshold), isTrue);
      expect(_strength(p, belowThreshold), 0);
      expect(_strength(p, atThreshold), 1);
    });

    test('matches swapped stable pairs and swaps MV correspondence', () {
      const p = H264DeblockingBlock(
        referenceIndexL0: 0,
        referencePictureIdL0: 10,
        motionVectorL0: H264MotionVector(2, 1),
        referenceIndexL1: 0,
        referencePictureIdL1: 20,
        motionVectorL1: H264MotionVector(-2, 0),
      );
      const swapped = H264DeblockingBlock(
        referenceIndexL0: 4,
        referencePictureIdL0: 20,
        motionVectorL0: H264MotionVector(-2, 0),
        referenceIndexL1: 3,
        referencePictureIdL1: 10,
        motionVectorL1: H264MotionVector(2, 1),
      );
      const swappedAtThreshold = H264DeblockingBlock(
        referenceIndexL0: 4,
        referencePictureIdL0: 20,
        motionVectorL0: H264MotionVector(-2, 0),
        referenceIndexL1: 3,
        referencePictureIdL1: 10,
        motionVectorL1: H264MotionVector(6, 1),
      );

      expect(p.hasEquivalentReferencePairAs(swapped), isTrue);
      expect(_strength(p, swapped), 0);
      expect(_strength(p, swappedAtThreshold), 1);
    });

    test('accepts either correspondence when all picture ids are equal', () {
      const p = H264DeblockingBlock(
        referencePictureIdL0: 7,
        motionVectorL0: H264MotionVector.zero,
        referenceIndexL1: 0,
        referencePictureIdL1: 7,
        motionVectorL1: H264MotionVector(8, 0),
      );
      const swappedMotion = H264DeblockingBlock(
        referencePictureIdL0: 7,
        motionVectorL0: H264MotionVector(8, 0),
        referenceIndexL1: 0,
        referencePictureIdL1: 7,
        motionVectorL1: H264MotionVector.zero,
      );
      const neitherMotionMatches = H264DeblockingBlock(
        referencePictureIdL0: 7,
        motionVectorL0: H264MotionVector(4, 0),
        referenceIndexL1: 0,
        referencePictureIdL1: 7,
        motionVectorL1: H264MotionVector(4, 0),
      );

      expect(_strength(p, swappedMotion), 0);
      expect(_strength(p, neitherMotionMatches), 1);
    });

    test('matches a stable uni prediction across opposite lists', () {
      const list0 = H264DeblockingBlock(
        referencePictureIdL0: 42,
        motionVectorL0: H264MotionVector(1, 2),
      );
      const list1 = H264DeblockingBlock(
        referenceIndexL0: -1,
        referenceIndexL1: 0,
        referencePictureIdL1: 42,
        motionVectorL1: H264MotionVector(1, 2),
      );
      const list1WithoutStableId = H264DeblockingBlock(
        referenceIndexL0: -1,
        referenceIndexL1: 0,
        motionVectorL1: H264MotionVector(1, 2),
      );

      expect(_strength(list0, list1), 0);
      expect(_strength(list0, list1WithoutStableId), 1);
    });

    test('rejects a different reference set before comparing motion', () {
      const p = H264DeblockingBlock(
        referencePictureIdL0: 10,
        referenceIndexL1: 0,
        referencePictureIdL1: 20,
      );
      const q = H264DeblockingBlock(
        referencePictureIdL0: 10,
        referenceIndexL1: 0,
        referencePictureIdL1: 30,
      );

      expect(p.hasEquivalentReferencePairAs(q), isFalse);
      expect(_strength(p, q), 1);
    });
  });
}

int _strength(H264DeblockingBlock p, H264DeblockingBlock q) =>
    H264DeblockingFilter.deriveBoundaryStrength(
      p: p,
      q: q,
      pMacroblockIsIntra: false,
      qMacroblockIsIntra: false,
      isMacroblockBoundary: false,
    );
