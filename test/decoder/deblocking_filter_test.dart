import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/deblocking_filter.dart';

void main() {
  group('H.264 boundary strength', () {
    const plain = H264DeblockingBlock();

    test('uses the normative intra strengths', () {
      expect(
        H264DeblockingFilter.deriveBoundaryStrength(
          p: plain,
          q: plain,
          pMacroblockIsIntra: true,
          qMacroblockIsIntra: false,
          isMacroblockBoundary: true,
        ),
        4,
      );
      expect(
        H264DeblockingFilter.deriveBoundaryStrength(
          p: plain,
          q: plain,
          pMacroblockIsIntra: true,
          qMacroblockIsIntra: true,
          isMacroblockBoundary: false,
        ),
        3,
      );
    });

    test('prioritises residual, then reference and quarter-pel MV changes', () {
      const residual = H264DeblockingBlock(totalCoeff: 1);
      expect(
        H264DeblockingFilter.deriveBoundaryStrength(
          p: residual,
          q: plain,
          pMacroblockIsIntra: false,
          qMacroblockIsIntra: false,
          isMacroblockBoundary: false,
        ),
        2,
      );

      const otherReference = H264DeblockingBlock(referenceIndexL0: 1);
      expect(
        H264DeblockingFilter.deriveBoundaryStrength(
          p: plain,
          q: otherReference,
          pMacroblockIsIntra: false,
          qMacroblockIsIntra: false,
          isMacroblockBoundary: false,
        ),
        1,
      );

      const mvBelowThreshold = H264DeblockingBlock(
        motionVectorL0: H264MotionVector(3, -3),
      );
      const mvAtThreshold = H264DeblockingBlock(
        motionVectorL0: H264MotionVector(4, 0),
      );
      expect(
        H264DeblockingFilter.deriveBoundaryStrength(
          p: plain,
          q: mvBelowThreshold,
          pMacroblockIsIntra: false,
          qMacroblockIsIntra: false,
          isMacroblockBoundary: false,
        ),
        0,
      );
      expect(
        H264DeblockingFilter.deriveBoundaryStrength(
          p: plain,
          q: mvAtThreshold,
          pMacroblockIsIntra: false,
          qMacroblockIsIntra: false,
          isMacroblockBoundary: false,
        ),
        1,
      );
    });

    test(
      'exact reference-picture identity overrides reordered list indices',
      () {
        const p = H264DeblockingBlock(
          referenceIndexL0: 0,
          referencePictureId: 7,
        );
        const q = H264DeblockingBlock(
          referenceIndexL0: 1,
          referencePictureId: 7,
        );
        expect(
          H264DeblockingFilter.deriveBoundaryStrength(
            p: p,
            q: q,
            pMacroblockIsIntra: false,
            qMacroblockIsIntra: false,
            isMacroblockBoundary: true,
          ),
          0,
        );
      },
    );
  });

  group('H.264 luma filtering', () {
    test('bS=2 applies the normative weak filter and tc0 clipping', () {
      final luma = Uint8List(16 * 16);
      for (var y = 0; y < 16; y++) {
        final row = y * 16;
        final values = <int>[
          100,
          100,
          102,
          105,
          112,
          114,
          116,
          116,
          116,
          116,
          116,
          116,
          116,
          116,
          116,
          116,
        ];
        luma.setRange(row, row + 16, values);
      }
      final cb = Uint8List(8 * 8)..fillRange(0, 64, 128);
      final cr = Uint8List(8 * 8)..fillRange(0, 64, 128);

      H264DeblockingFilter.apply420(
        luma: luma,
        cb: cb,
        cr: cr,
        codedWidth: 16,
        codedHeight: 16,
        macroblocks: <H264DeblockingMacroblock>[
          _macroblock(qp: 40, residualBlockIndexes: <int>{0, 4, 8, 12}),
        ],
      );

      expect(luma.sublist(0, 8), <int>[100, 100, 104, 107, 110, 112, 116, 116]);
      expect(luma.sublist(15 * 16, 15 * 16 + 8), <int>[
        100,
        100,
        104,
        107,
        110,
        112,
        116,
        116,
      ]);
    });

    test('bS=4 applies strong luma and strong 4:2:0 chroma filtering', () {
      final luma = Uint8List(32 * 16);
      const lumaRow = <int>[
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        94,
        98,
        100,
        104,
        106,
        108,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
      ];
      for (var y = 0; y < 16; y++) {
        luma.setRange(y * 32, y * 32 + 32, lumaRow);
      }

      final cb = Uint8List(16 * 8);
      final cr = Uint8List(16 * 8);
      const chromaRow = <int>[
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        100,
        104,
        108,
        108,
        108,
        108,
        108,
        108,
        108,
      ];
      for (var y = 0; y < 8; y++) {
        cb.setRange(y * 16, y * 16 + 16, chromaRow);
        cr.setRange(y * 16, y * 16 + 16, chromaRow);
      }

      H264DeblockingFilter.apply420(
        luma: luma,
        cb: cb,
        cr: cr,
        codedWidth: 32,
        codedHeight: 16,
        macroblocks: <H264DeblockingMacroblock>[
          _macroblock(intra: true, qp: 40),
          _macroblock(qp: 40),
        ],
      );

      // p2, p1, p0, q0, q1, q2 from the strong-filter equations.
      expect(luma.sublist(13, 19), <int>[96, 99, 101, 103, 105, 107]);
      expect(cb.sublist(6, 10), <int>[98, 101, 105, 108]);
      expect(cr.sublist(6, 10), <int>[98, 101, 105, 108]);
    });

    test('filters horizontal edges with the normative sample order', () {
      final luma = Uint8List(16 * 32);
      const lumaValues = <int>[
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        90,
        94,
        98,
        100,
        104,
        106,
        108,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
        112,
      ];
      for (var y = 0; y < 32; y++) {
        luma.fillRange(y * 16, y * 16 + 16, lumaValues[y]);
      }

      final cb = Uint8List(8 * 16);
      final cr = Uint8List(8 * 16);
      const chromaValues = <int>[
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        100,
        104,
        108,
        108,
        108,
        108,
        108,
        108,
        108,
      ];
      for (var y = 0; y < 16; y++) {
        cb.fillRange(y * 8, y * 8 + 8, chromaValues[y]);
        cr.fillRange(y * 8, y * 8 + 8, chromaValues[y]);
      }

      H264DeblockingFilter.apply420(
        luma: luma,
        cb: cb,
        cr: cr,
        codedWidth: 16,
        codedHeight: 32,
        macroblocks: <H264DeblockingMacroblock>[
          _macroblock(intra: true, qp: 40),
          _macroblock(qp: 40),
        ],
      );

      expect(
        <int>[for (var y = 13; y <= 18; y++) luma[y * 16]],
        <int>[96, 99, 101, 103, 105, 107],
      );
      expect(
        <int>[for (var y = 6; y <= 9; y++) cb[y * 8]],
        <int>[98, 101, 105, 108],
      );
      expect(
        <int>[for (var y = 6; y <= 9; y++) cr[y * 8]],
        <int>[98, 101, 105, 108],
      );
    });

    test(
      'disable_deblocking_filter_idc=1 leaves all planes byte-identical',
      () {
        final luma = Uint8List.fromList(List<int>.generate(256, (i) => i));
        final cb = Uint8List.fromList(
          List<int>.generate(64, (i) => i * 3 & 255),
        );
        final cr = Uint8List.fromList(List<int>.generate(64, (i) => 255 - i));
        final originalLuma = Uint8List.fromList(luma);
        final originalCb = Uint8List.fromList(cb);
        final originalCr = Uint8List.fromList(cr);

        H264DeblockingFilter.apply420(
          luma: luma,
          cb: cb,
          cr: cr,
          codedWidth: 16,
          codedHeight: 16,
          macroblocks: <H264DeblockingMacroblock>[
            _macroblock(intra: true, qp: 51),
          ],
          defaultSliceParameters: const H264DeblockingSliceParameters(
            disableDeblockingFilterIdc: 1,
          ),
        );

        expect(luma, originalLuma);
        expect(cb, originalCb);
        expect(cr, originalCr);
      },
    );

    test('idc=2 does not cross a slice boundary', () {
      final luma = Uint8List(32 * 16);
      for (var y = 0; y < 16; y++) {
        luma.fillRange(y * 32, y * 32 + 16, 100);
        luma.fillRange(y * 32 + 16, y * 32 + 32, 108);
      }
      final cb = Uint8List(16 * 8);
      final cr = Uint8List(16 * 8);
      for (var y = 0; y < 8; y++) {
        cb.fillRange(y * 16, y * 16 + 8, 100);
        cb.fillRange(y * 16 + 8, y * 16 + 16, 108);
        cr.fillRange(y * 16, y * 16 + 8, 100);
        cr.fillRange(y * 16 + 8, y * 16 + 16, 108);
      }

      H264DeblockingFilter.apply420(
        luma: luma,
        cb: cb,
        cr: cr,
        codedWidth: 32,
        codedHeight: 16,
        macroblocks: <H264DeblockingMacroblock>[
          _macroblock(intra: true, qp: 40, sliceId: 10),
          _macroblock(intra: true, qp: 40, sliceId: 20),
        ],
        sliceParametersById: const <int, H264DeblockingSliceParameters>{
          20: H264DeblockingSliceParameters(disableDeblockingFilterIdc: 2),
        },
      );

      for (var y = 0; y < 16; y++) {
        expect(luma[y * 32 + 15], 100);
        expect(luma[y * 32 + 16], 108);
      }
      for (var y = 0; y < 8; y++) {
        expect(cb[y * 16 + 7], 100);
        expect(cb[y * 16 + 8], 108);
        expect(cr[y * 16 + 7], 100);
        expect(cr[y * 16 + 8], 108);
      }
    });
  });

  group('input contract', () {
    test('accepts padded strides without touching row padding', () {
      final luma = Uint8List(20 * 16)..fillRange(0, 20 * 16, 77);
      final cb = Uint8List(12 * 8)..fillRange(0, 12 * 8, 88);
      final cr = Uint8List(12 * 8)..fillRange(0, 12 * 8, 99);

      H264DeblockingFilter.apply420(
        luma: luma,
        cb: cb,
        cr: cr,
        codedWidth: 16,
        codedHeight: 16,
        lumaStride: 20,
        chromaStride: 12,
        macroblocks: <H264DeblockingMacroblock>[
          _macroblock(intra: true, qp: 40),
        ],
      );

      expect(luma, everyElement(77));
      expect(cb, everyElement(88));
      expect(cr, everyElement(99));
    });

    test('rejects non-macroblock dimensions and incomplete metadata', () {
      expect(
        () => H264DeblockingFilter.apply420(
          luma: Uint8List(17 * 16),
          cb: Uint8List(9 * 8),
          cr: Uint8List(9 * 8),
          codedWidth: 17,
          codedHeight: 16,
          macroblocks: const <H264DeblockingMacroblock>[],
        ),
        throwsArgumentError,
      );
      expect(
        () => H264DeblockingFilter.apply420(
          luma: Uint8List(16 * 16),
          cb: Uint8List(8 * 8),
          cr: Uint8List(8 * 8),
          codedWidth: 16,
          codedHeight: 16,
          macroblocks: const <H264DeblockingMacroblock>[],
        ),
        throwsArgumentError,
      );
    });
  });
}

H264DeblockingMacroblock _macroblock({
  bool intra = false,
  int qp = 0,
  int sliceId = 0,
  Set<int> residualBlockIndexes = const <int>{},
}) {
  return H264DeblockingMacroblock(
    isIntra: intra,
    qpY: qp,
    qpCb: qp,
    qpCr: qp,
    sliceId: sliceId,
    lumaBlocks: List<H264DeblockingBlock>.generate(
      16,
      (index) => H264DeblockingBlock(
        totalCoeff: residualBlockIndexes.contains(index) ? 1 : 0,
      ),
      growable: false,
    ),
  );
}
