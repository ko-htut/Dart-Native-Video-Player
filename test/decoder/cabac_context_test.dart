import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_context.dart';
import 'package:ndvy_player/src/decoder/cabac/cabac_tables.dart';

void main() {
  group('H.264 CABAC normative tables', () {
    test('cover all 4:2:0 macroblock and residual contexts', () {
      expect(h264CabacContextCount, 460);
      expect(h264CabacContextInitMn, hasLength(460 * 4 * 2));
      expect(h264CabacRangeLps, hasLength(64));
      expect(h264CabacStateTransitions, hasLength(64));

      for (final row in h264CabacRangeLps) {
        expect(row, hasLength(4));
        expect(row.every((value) => value >= 2 && value <= 240), isTrue);
      }
      for (final row in h264CabacStateTransitions) {
        expect(row, hasLength(2));
        expect(row.every((value) => value >= 0 && value <= 63), isTrue);
      }
    });

    test('Table 9-44 range/LPS boundary rows are exact', () {
      expect(h264CabacRangeLps[0], <int>[128, 176, 208, 240]);
      expect(h264CabacRangeLps[31], <int>[29, 35, 41, 48]);
      expect(h264CabacRangeLps[62], <int>[6, 7, 8, 9]);
      expect(h264CabacRangeLps[63], <int>[2, 2, 2, 2]);
    });

    test('Tables 9-12 through 9-24 sentinel m/n pairs are exact', () {
      expect(
        h264CabacContextInitParameters(
          sliceType: H264CabacSliceType.i,
          contextIndex: 0,
        ),
        (m: 20, n: -15),
      );
      expect(
        h264CabacContextInitParameters(
          sliceType: H264CabacSliceType.p,
          cabacInitIdc: 0,
          contextIndex: 11,
        ),
        (m: 23, n: 33),
      );
      expect(
        h264CabacContextInitParameters(
          sliceType: H264CabacSliceType.b,
          cabacInitIdc: 1,
          contextIndex: 399,
        ),
        (m: 25, n: 32),
      );
      expect(
        h264CabacContextInitParameters(
          sliceType: H264CabacSliceType.p,
          cabacInitIdc: 2,
          contextIndex: 459,
        ),
        (m: 20, n: 64),
      );
    });

    test('all 460 context rows match the normative canonical table', () {
      // Canonical encoding: every signed m/n value is biased by 128 and
      // serialized in ctxIdx/model/m/n order. This checks every table entry,
      // while the sentinel test above keeps failures human-readable.
      final canonical = Uint8List.fromList(
        h264CabacContextInitMn.map((value) => value + 128).toList(),
      );
      expect(
        sha256.convert(canonical).toString(),
        '3fc17acfbfbcb6545e2be1c5e03c1a6e9e0658162399cf005594cfab188da39f',
      );
    });
  });

  group('CabacContextModel', () {
    test('initializes pStateIdx and valMPS using clause 9.3.1.1', () {
      final lowPreState = CabacContextModel.initialize(
        m: 20,
        n: -15,
        sliceQpY: 26,
      );
      expect(lowPreState.probabilityStateIndex, 46);
      expect(lowPreState.mostProbableSymbol, 0);

      final highPreState = CabacContextModel.initialize(
        m: 3,
        n: 74,
        sliceQpY: 26,
      );
      expect(highPreState.probabilityStateIndex, 14);
      expect(highPreState.mostProbableSymbol, 1);
    });

    test('clips SliceQPY to the normative 0 through 51 interval', () {
      final below = CabacContextModel.initialize(m: 20, n: -15, sliceQpY: -20);
      final atZero = CabacContextModel.initialize(m: 20, n: -15, sliceQpY: 0);
      final above = CabacContextModel.initialize(m: 20, n: -15, sliceQpY: 100);
      final at51 = CabacContextModel.initialize(m: 20, n: -15, sliceQpY: 51);

      expect(below.packedState, atZero.packedState);
      expect(above.packedState, at51.packedState);
    });

    test('applies MPS and LPS state transitions including state-zero flip', () {
      final context = CabacContextModel(
        probabilityStateIndex: 1,
        mostProbableSymbol: 0,
      );
      context.updateForMps();
      expect(context.probabilityStateIndex, 2);
      expect(context.mostProbableSymbol, 0);

      context.updateForLps();
      expect(context.probabilityStateIndex, 1);
      expect(context.mostProbableSymbol, 0);

      final zero = CabacContextModel(
        probabilityStateIndex: 0,
        mostProbableSymbol: 0,
      );
      zero.updateForLps();
      expect(zero.probabilityStateIndex, 0);
      expect(zero.mostProbableSymbol, 1);
    });

    test('rejects impossible probability states', () {
      expect(
        () =>
            CabacContextModel(probabilityStateIndex: 64, mostProbableSymbol: 0),
        throwsRangeError,
      );
      expect(
        () =>
            CabacContextModel(probabilityStateIndex: 0, mostProbableSymbol: 2),
        throwsRangeError,
      );
    });
  });

  group('H264CabacContextSet', () {
    test('builds 460 independent contexts for I/P/B slice models', () {
      final intra = H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.i,
        sliceQpY: 26,
      );
      final predictive = H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.p,
        sliceQpY: 26,
        cabacInitIdc: 1,
      );
      final biPredictive = H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.b,
        sliceQpY: 26,
        cabacInitIdc: 1,
      );

      expect(intra.length, 460);
      expect(predictive.length, 460);
      expect(
        biPredictive.contexts.map((context) => context.packedState),
        predictive.contexts.map((context) => context.packedState),
      );
      expect(intra[0].packedState, 92);
      expect(intra[1].packedState, 12);
      expect(intra[2].packedState, 29);
    });

    test('retains original QP and records the clipped effective QP', () {
      final contexts = H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.p,
        sliceQpY: 80,
        cabacInitIdc: 2,
      );
      expect(contexts.sliceQpY, 80);
      expect(contexts.effectiveSliceQpY, 51);
    });

    test('validates cabac_init_idc and context indices', () {
      expect(
        () => H264CabacContextSet.initialize(
          sliceType: H264CabacSliceType.p,
          sliceQpY: 26,
          cabacInitIdc: 3,
        ),
        throwsRangeError,
      );
      expect(
        () => H264CabacContextSet.initialize(
          sliceType: H264CabacSliceType.i,
          sliceQpY: 26,
          cabacInitIdc: 1,
        ),
        throwsArgumentError,
      );
      final contexts = H264CabacContextSet.initialize(
        sliceType: H264CabacSliceType.b,
        sliceQpY: 26,
      );
      expect(() => contexts[-1], throwsRangeError);
      expect(() => contexts[460], throwsRangeError);
    });
  });
}
