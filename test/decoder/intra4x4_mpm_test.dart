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
}
