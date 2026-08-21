import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/decoder/intra4x4_mpm.dart';

void main() {
  group('mostProbableIntra4x4Mode', () {
    test('defaults to DC when either neighbour is unavailable', () {
      expect(
        mostProbableIntra4x4Mode(
          leftAvail: false,
          topAvail: true,
          leftMode: 0,
          topMode: 3,
        ),
        2,
      );
      expect(
        mostProbableIntra4x4Mode(
          leftAvail: true,
          topAvail: false,
          leftMode: 1,
          topMode: 0,
        ),
        2,
      );
      expect(
        mostProbableIntra4x4Mode(
          leftAvail: false,
          topAvail: false,
          leftMode: 8,
          topMode: 8,
        ),
        2,
      );
    });

    test('selects the lower mode when both neighbours are available', () {
      expect(
        mostProbableIntra4x4Mode(
          leftAvail: true,
          topAvail: true,
          leftMode: 7,
          topMode: 4,
        ),
        4,
      );
    });
  });

  test('remapping skips the predicted mode', () {
    expect(mapRemToMode(4, 3), 3);
    expect(mapRemToMode(4, 4), 5);
  });

  test('inherits the containing Intra8x8 mode across transform sizes', () {
    const intra8x8Modes = <int>[0, 0, 1, 1];
    final facingBottomModes = <int>[
      for (var blockX = 0; blockX < 4; blockX++)
        intra8x8Modes[intra8x8BlockIndexForIntra4x4Neighbour(
          blockX: blockX,
          blockY: 3,
        )],
    ];
    expect(facingBottomModes, <int>[1, 1, 1, 1]);
    expect(
      mostProbableIntra4x4Mode(
        leftAvail: true,
        topAvail: true,
        leftMode: 2,
        topMode: facingBottomModes.first,
      ),
      1,
    );
    expect(
      () => intra8x8BlockIndexForIntra4x4Neighbour(blockX: 4, blockY: 0),
      throwsRangeError,
    );
  });

  test('selects the facing Intra4x4 mode for an Intra8x8 neighbour', () {
    expect(
      <int>[
        for (var blockY = 0; blockY < 2; blockY++)
          for (var blockX = 0; blockX < 2; blockX++)
            intra4x4BlockIndexForIntra8x8Neighbour(
              blockX: blockX,
              blockY: blockY,
              side: Intra8x8NeighbourSide.left,
            ),
      ],
      <int>[1, 3, 9, 11],
    );
    expect(
      <int>[
        for (var blockY = 0; blockY < 2; blockY++)
          for (var blockX = 0; blockX < 2; blockX++)
            intra4x4BlockIndexForIntra8x8Neighbour(
              blockX: blockX,
              blockY: blockY,
              side: Intra8x8NeighbourSide.top,
            ),
      ],
      <int>[4, 6, 12, 14],
    );
    const leftModes = <int>[2, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2];
    final facingMode =
        leftModes[intra4x4BlockIndexForIntra8x8Neighbour(
          blockX: 1,
          blockY: 0,
          side: Intra8x8NeighbourSide.left,
        )];
    expect(
      mostProbableIntra4x4Mode(
        leftAvail: true,
        topAvail: true,
        leftMode: facingMode,
        topMode: 2,
      ),
      0,
    );
  });
}
