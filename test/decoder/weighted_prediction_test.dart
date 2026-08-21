import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/slice_header.dart';
import 'package:ndvy_player/src/decoder/weighted_prediction.dart';

void main() {
  group('explicit weighted uni prediction', () {
    test('matches the sfux weighted-P luma footprint at denominator zero', () {
      const inputs = <int>[0, 100, 250];
      expect(
        <int>[
          for (final sample in inputs)
            explicitWeightedUniSample8(
              sample: sample,
              log2WeightDenom: 0,
              weight: 1,
              offset: 16,
            ),
        ],
        <int>[16, 116, 255],
      );
    });

    test('rounds, shifts, offsets, and clips defining vectors', () {
      expect(
        explicitWeightedUniSample8(
          sample: 101,
          log2WeightDenom: 2,
          weight: 3,
          offset: -10,
        ),
        66, // ((3 * 101 + 2) >> 2) - 10
      );
      expect(
        explicitWeightedUniSample8(
          sample: 173,
          log2WeightDenom: 7,
          weight: 128,
          offset: 0,
        ),
        173, // Inferred identity at the maximum denominator.
      );
      expect(
        explicitWeightedUniSample8(
          sample: 255,
          log2WeightDenom: 0,
          weight: -128,
          offset: 127,
        ),
        0,
      );
      expect(
        explicitWeightedUniSample8(
          sample: 255,
          log2WeightDenom: 0,
          weight: 128,
          offset: 127,
        ),
        255,
      );
    });
  });

  group('explicit weighted bi prediction', () {
    test('matches the two-weight defining equation', () {
      expect(
        explicitWeightedBiSample8(
          list0Sample: 40,
          list1Sample: 200,
          log2WeightDenom: 2,
          list0Weight: 3,
          list1Weight: 1,
          list0Offset: -5,
          list1Offset: 6,
        ),
        41,
      );
    });

    test('uses an arithmetic rounded average for signed offsets', () {
      expect(
        explicitWeightedBiSample8(
          list0Sample: 100,
          list1Sample: 100,
          log2WeightDenom: 0,
          list0Weight: 1,
          list1Weight: 1,
          list0Offset: -5,
          list1Offset: -5,
        ),
        95,
      );
    });

    test('identity weights equal the default rounded average', () {
      final explicit = explicitWeightedBiSample8(
        list0Sample: 10,
        list1Sample: 11,
        log2WeightDenom: 7,
        list0Weight: 128,
        list1Weight: 128,
        list0Offset: 0,
        list1Offset: 0,
      );
      expect(explicit, 11);
      expect(
        explicit,
        defaultBiPredictionSample8(list0Sample: 10, list1Sample: 11),
      );
    });

    test('clips the combined weighted result at both 8-bit boundaries', () {
      expect(
        explicitWeightedBiSample8(
          list0Sample: 255,
          list1Sample: 255,
          log2WeightDenom: 0,
          list0Weight: 128,
          list1Weight: 128,
          list0Offset: 127,
          list1Offset: 127,
        ),
        255,
      );
      expect(
        explicitWeightedBiSample8(
          list0Sample: 255,
          list1Sample: 255,
          log2WeightDenom: 0,
          list0Weight: -128,
          list1Weight: -128,
          list0Offset: -128,
          list1Offset: -128,
        ),
        0,
      );
    });
  });

  group('parsed luma and chroma weight table adapters', () {
    test('selects the correct denominator, list, and component', () {
      expect(
        explicitWeightedUniFromTable8(
          sample: 100,
          table: _weightTable,
          referenceList: H264ReferenceList.list0,
          referenceIndex: 0,
        ),
        152,
      );
      expect(
        explicitWeightedUniFromTable8(
          sample: 100,
          table: _weightTable,
          referenceList: H264ReferenceList.list1,
          referenceIndex: 0,
        ),
        47,
      );
      expect(
        explicitWeightedUniFromTable8(
          sample: 80,
          table: _weightTable,
          referenceList: H264ReferenceList.list0,
          referenceIndex: 0,
          component: H264PredictionComponent.cb,
        ),
        46,
      );
      expect(
        explicitWeightedUniFromTable8(
          sample: 80,
          table: _weightTable,
          referenceList: H264ReferenceList.list0,
          referenceIndex: 0,
          component: H264PredictionComponent.cr,
        ),
        80,
      );
    });

    test('applies component-specific explicit B weights', () {
      expect(
        explicitWeightedBiFromTable8(
          list0Sample: 40,
          list1Sample: 200,
          table: _weightTable,
          list0ReferenceIndex: 0,
          list1ReferenceIndex: 0,
        ),
        80,
      );
      expect(
        explicitWeightedBiFromTable8(
          list0Sample: 40,
          list1Sample: 200,
          table: _weightTable,
          list0ReferenceIndex: 0,
          list1ReferenceIndex: 0,
          component: H264PredictionComponent.cb,
        ),
        101,
      );
      expect(
        explicitWeightedBiFromTable8(
          list0Sample: 40,
          list1Sample: 200,
          table: _weightTable,
          list0ReferenceIndex: 0,
          list1ReferenceIndex: 0,
          component: H264PredictionComponent.cr,
        ),
        90,
      );
    });
  });

  group('implicit B prediction weights', () {
    test('sfux midpoint POC derives equal list weights', () {
      final weights = deriveImplicitBiPredictionWeights(
        currentPoc: 2,
        list0Poc: 0,
        list1Poc: 4,
      );

      expect((weights.list0Weight, weights.list1Weight), (32, 32));
      expect(weights.usesEqualWeights, isTrue);
      expect(
        implicitWeightedBiSample8(
          list0Sample: 40,
          list1Sample: 200,
          weights: weights,
        ),
        120,
      );
    });

    test('temporal distance biases toward the nearer reference', () {
      final firstQuarter = deriveImplicitBiPredictionWeights(
        currentPoc: 2,
        list0Poc: 0,
        list1Poc: 8,
      );
      final thirdQuarter = deriveImplicitBiPredictionWeights(
        currentPoc: 6,
        list0Poc: 0,
        list1Poc: 8,
      );

      expect((firstQuarter.list0Weight, firstQuarter.list1Weight), (48, 16));
      expect((thirdQuarter.list0Weight, thirdQuarter.list1Weight), (16, 48));
      expect(
        implicitWeightedBiSample8(
          list0Sample: 40,
          list1Sample: 200,
          weights: firstQuarter,
        ),
        80,
      );
      expect(
        implicitWeightedBiSample8(
          list0Sample: 40,
          list1Sample: 200,
          weights: thirdQuarter,
        ),
        160,
      );
    });

    test('negative temporal distance truncates division toward zero', () {
      final weights = deriveImplicitBiPredictionWeights(
        currentPoc: 6,
        list0Poc: 10,
        list1Poc: 3,
      );

      expect((weights.list0Weight, weights.list1Weight), (28, 36));
      expect(
        implicitWeightedBiSample8(
          list0Sample: 70,
          list1Sample: 210,
          weights: weights,
        ),
        149,
      );
    });

    test('clips POC differences before deriving temporal weights', () {
      final weights = deriveImplicitBiPredictionWeights(
        currentPoc: 250,
        list0Poc: 0,
        list1Poc: 1000,
      );

      expect((weights.list0Weight, weights.list1Weight), (0, 64));
      expect(
        implicitWeightedBiSample8(
          list0Sample: 11,
          list1Sample: 222,
          weights: weights,
        ),
        222,
      );
    });

    test('clips implicit negative-weight overshoot to 8-bit samples', () {
      final weights = deriveImplicitBiPredictionWeights(
        currentPoc: 2,
        list0Poc: 0,
        list1Poc: 1,
      );

      expect((weights.list0Weight, weights.list1Weight), (-64, 128));
      expect(
        implicitWeightedBiSample8(
          list0Sample: 255,
          list1Sample: 0,
          weights: weights,
        ),
        0,
      );
      expect(
        implicitWeightedBiSample8(
          list0Sample: 0,
          list1Sample: 255,
          weights: weights,
        ),
        255,
      );
    });

    test(
      'uses equal fallback for zero distance, long-term, or unsafe scale',
      () {
        final cases = <H264ImplicitBiWeights>[
          deriveImplicitBiPredictionWeights(
            currentPoc: 4,
            list0Poc: 2,
            list1Poc: 2,
          ),
          deriveImplicitBiPredictionWeights(
            currentPoc: 4,
            list0Poc: 0,
            list1Poc: 8,
            list0IsLongTerm: true,
          ),
          deriveImplicitBiPredictionWeights(
            currentPoc: 4,
            list0Poc: 0,
            list1Poc: 8,
            list1IsLongTerm: true,
          ),
          deriveImplicitBiPredictionWeights(
            currentPoc: -128,
            list0Poc: 0,
            list1Poc: 1,
          ),
        ];

        for (final weights in cases) {
          expect((weights.list0Weight, weights.list1Weight), (32, 32));
          expect(weights.usesEqualWeights, isTrue);
        }
      },
    );
  });

  group('weighted prediction validation', () {
    test(
      'rejects samples, denominators, weights, and offsets out of range',
      () {
        int predict({
          int sample = 10,
          int denominator = 0,
          int weight = 1,
          int offset = 0,
        }) => explicitWeightedUniSample8(
          sample: sample,
          log2WeightDenom: denominator,
          weight: weight,
          offset: offset,
        );

        expect(() => predict(sample: -1), throwsRangeError);
        expect(() => predict(sample: 256), throwsRangeError);
        expect(() => predict(denominator: -1), throwsRangeError);
        expect(() => predict(denominator: 8), throwsRangeError);
        expect(() => predict(weight: -129), throwsRangeError);
        expect(() => predict(weight: 129), throwsRangeError);
        expect(() => predict(offset: -129), throwsRangeError);
        expect(() => predict(offset: 128), throwsRangeError);

        final weights = deriveImplicitBiPredictionWeights(
          currentPoc: 1,
          list0Poc: 0,
          list1Poc: 2,
        );
        expect(
          () => implicitWeightedBiSample8(
            list0Sample: -1,
            list1Sample: 0,
            weights: weights,
          ),
          throwsRangeError,
        );
        expect(
          () => defaultBiPredictionSample8(list0Sample: 0, list1Sample: 256),
          throwsRangeError,
        );
      },
    );

    test('rejects missing table references and malformed chroma entries', () {
      expect(
        () => explicitWeightedUniFromTable8(
          sample: 10,
          table: _weightTable,
          referenceList: H264ReferenceList.list0,
          referenceIndex: 1,
        ),
        throwsRangeError,
      );

      const malformed = PredictionWeightTable(
        lumaLog2WeightDenom: 0,
        chromaLog2WeightDenom: 0,
        list0: <PredictionWeight>[
          PredictionWeight(
            lumaWeight: 1,
            lumaOffset: 0,
            chromaWeights: <int>[1],
            chromaOffsets: <int>[0],
          ),
        ],
        list1: <PredictionWeight>[],
      );
      expect(
        () => explicitWeightedUniFromTable8(
          sample: 10,
          table: malformed,
          referenceList: H264ReferenceList.list0,
          referenceIndex: 0,
          component: H264PredictionComponent.cb,
        ),
        throwsArgumentError,
      );
    });
  });
}

const _weightTable = PredictionWeightTable(
  lumaLog2WeightDenom: 1,
  chromaLog2WeightDenom: 3,
  list0: <PredictionWeight>[
    PredictionWeight(
      lumaWeight: 3,
      lumaOffset: 2,
      chromaWeights: <int>[5, -2],
      chromaOffsets: <int>[-4, 100],
    ),
  ],
  list1: <PredictionWeight>[
    PredictionWeight(
      lumaWeight: 1,
      lumaOffset: -3,
      chromaWeights: <int>[7, 4],
      chromaOffsets: <int>[5, -11],
    ),
  ],
);
