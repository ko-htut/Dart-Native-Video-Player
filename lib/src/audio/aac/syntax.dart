import 'dart:math' as math;
import 'dart:typed_data';

import 'bit_reader.dart';
import 'huffman_tables.dart';

const int zeroHcb = 0;
const int escapeHcb = 11;
const int noiseHcb = 13;
const int intensityHcb2 = 14;
const int intensityHcb = 15;

enum AacWindowSequence { onlyLong, longStart, eightShort, longStop }

enum AacWindowShape { sine, kbd }

final class AacIcsInfo {
  const AacIcsInfo({
    required this.windowSequence,
    required this.windowShape,
    required this.maxSfb,
    required this.windowGroupLength,
  });

  final AacWindowSequence windowSequence;
  final AacWindowShape windowShape;
  final int maxSfb;
  final List<int> windowGroupLength;

  bool get isShort => windowSequence == AacWindowSequence.eightShort;
  int get windowLength => isShort ? 128 : 1024;
  int get numberOfWindows => isShort ? 8 : 1;
  int get numberOfWindowGroups => windowGroupLength.length;

  static AacIcsInfo parse(AacBitReader reader, int samplingFrequencyIndex) {
    if (samplingFrequencyIndex < 0 || samplingFrequencyIndex > 11) {
      throw AacDecoderException(
        'AAC-LC requires an indexed sampling frequency in 0..11',
        bitOffset: reader.bitOffset,
      );
    }
    if (reader.readBool()) {
      throw AacDecoderException(
        'ics_reserved_bit must be zero',
        bitOffset: reader.bitOffset - 1,
      );
    }
    final sequence = AacWindowSequence.values[reader.readBits(2)];
    final shape = AacWindowShape.values[reader.readBit()];
    if (sequence == AacWindowSequence.eightShort) {
      final maxSfb = reader.readBits(4);
      final grouping = reader.readBits(7);
      final groups = <int>[1];
      for (var i = 0; i < 7; i++) {
        if (((grouping >> (6 - i)) & 1) != 0) {
          groups[groups.length - 1]++;
        } else {
          groups.add(1);
        }
      }
      final numSwb = shortSwbOffsets(samplingFrequencyIndex).length - 1;
      if (maxSfb > numSwb) {
        throw AacDecoderException(
          'Short-window max_sfb=$maxSfb exceeds $numSwb',
          bitOffset: reader.bitOffset,
        );
      }
      return AacIcsInfo(
        windowSequence: sequence,
        windowShape: shape,
        maxSfb: maxSfb,
        windowGroupLength: List<int>.unmodifiable(groups),
      );
    }

    final maxSfb = reader.readBits(6);
    final numSwb = longSwbOffsets(samplingFrequencyIndex).length - 1;
    if (maxSfb > numSwb) {
      throw AacDecoderException(
        'Long-window max_sfb=$maxSfb exceeds $numSwb',
        bitOffset: reader.bitOffset,
      );
    }
    if (reader.readBool()) {
      throw AacDecoderException(
        'Prediction/LTP is not part of AAC-LC',
        bitOffset: reader.bitOffset - 1,
      );
    }
    return AacIcsInfo(
      windowSequence: sequence,
      windowShape: shape,
      maxSfb: maxSfb,
      windowGroupLength: const <int>[1],
    );
  }
}

final class AacSection {
  const AacSection(this.codebook, this.startSfb, this.endSfb);

  final int codebook;
  final int startSfb;
  final int endSfb;
}

final class AacTnsFilter {
  const AacTnsFilter({
    required this.length,
    required this.order,
    required this.direction,
    required this.coefficientResolution,
    required this.coefficientCompression,
    required this.coefficients,
  });

  final int length;
  final int order;
  final bool direction;
  final int coefficientResolution;
  final bool coefficientCompression;
  final List<int> coefficients;
}

final class AacTnsWindow {
  const AacTnsWindow(this.filters);
  final List<AacTnsFilter> filters;
}

final class AacPulse {
  const AacPulse(this.offset, this.amplitude);
  final int offset;
  final int amplitude;
}

final class AacPulseData {
  const AacPulseData(this.startSfb, this.pulses);
  final int startSfb;
  final List<AacPulse> pulses;
}

final class AacChannelData {
  const AacChannelData({
    required this.info,
    required this.codebooks,
    required this.scaleFactors,
    required this.intensityPositions,
    required this.noiseEnergies,
    required this.quantizedGroups,
    required this.pulseData,
    required this.tnsWindows,
  });

  final AacIcsInfo info;
  final List<List<int>> codebooks;
  final List<List<int?>> scaleFactors;
  final List<List<int?>> intensityPositions;
  final List<List<int?>> noiseEnergies;
  final List<Int32List> quantizedGroups;
  final AacPulseData? pulseData;
  final List<AacTnsWindow>? tnsWindows;

  Float64List reconstructSpectrum({required int samplingFrequencyIndex}) {
    final quant = <Int32List>[
      for (final group in quantizedGroups) Int32List.fromList(group),
    ];
    final pulse = pulseData;
    if (pulse != null) {
      final offsets = longSwbOffsets(samplingFrequencyIndex);
      if (pulse.startSfb >= offsets.length - 1) {
        throw const AacDecoderException('pulse_start_sfb is out of range');
      }
      var index = offsets[pulse.startSfb];
      for (final item in pulse.pulses) {
        index += item.offset;
        if (index >= 1024) {
          throw const AacDecoderException('AAC pulse exceeds spectrum');
        }
        quant[0][index] += quant[0][index] > 0
            ? item.amplitude
            : -item.amplitude;
      }
    }

    final groupSpectra = <Float64List>[];
    final bandOffsets = info.isShort
        ? shortSwbOffsets(samplingFrequencyIndex)
        : longSwbOffsets(samplingFrequencyIndex);
    for (var group = 0; group < info.numberOfWindowGroups; group++) {
      final source = quant[group];
      final decoded = Float64List(source.length);
      var groupOffset = 0;
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        final width = bandOffsets[sfb + 1] - bandOffsets[sfb];
        final count = width * info.windowGroupLength[group];
        final sf = scaleFactors[group][sfb];
        if (sf != null) {
          final gain = math.pow(2.0, 0.25 * (sf - 100)).toDouble();
          for (var i = 0; i < count; i++) {
            final value = source[groupOffset + i];
            final magnitude = math.pow(value.abs(), 4.0 / 3.0).toDouble();
            decoded[groupOffset + i] =
                (value < 0 ? -magnitude : magnitude) * gain;
          }
        }
        groupOffset += count;
      }
      groupSpectra.add(decoded);
    }

    final result = Float64List(1024);
    if (!info.isShort) {
      result.setAll(0, groupSpectra.single);
    } else {
      var firstWindow = 0;
      for (var group = 0; group < info.numberOfWindowGroups; group++) {
        final source = groupSpectra[group];
        var sourceOffset = 0;
        final windows = info.windowGroupLength[group];
        for (var sfb = 0; sfb < bandOffsets.length - 1; sfb++) {
          final start = bandOffsets[sfb];
          final width = bandOffsets[sfb + 1] - start;
          for (var window = 0; window < windows; window++) {
            result.setRange(
              (firstWindow + window) * 128 + start,
              (firstWindow + window) * 128 + start + width,
              source,
              sourceOffset,
            );
            sourceOffset += width;
          }
        }
        firstWindow += windows;
      }
    }
    return result;
  }
}

final class AacChannelParser {
  const AacChannelParser(this.samplingFrequencyIndex);

  final int samplingFrequencyIndex;

  AacChannelData parse(AacBitReader reader, {AacIcsInfo? commonInfo}) {
    final globalGain = reader.readBits(8);
    final info = commonInfo ?? AacIcsInfo.parse(reader, samplingFrequencyIndex);
    final sections = _parseSections(reader, info);
    final codebooks = <List<int>>[
      for (var g = 0; g < info.numberOfWindowGroups; g++)
        List<int>.filled(info.maxSfb, zeroHcb),
    ];
    for (var g = 0; g < sections.length; g++) {
      for (final section in sections[g]) {
        for (var sfb = section.startSfb; sfb < section.endSfb; sfb++) {
          codebooks[g][sfb] = section.codebook;
        }
      }
    }

    final scaleFactors = <List<int?>>[
      for (var g = 0; g < info.numberOfWindowGroups; g++)
        List<int?>.filled(info.maxSfb, null),
    ];
    final intensity = <List<int?>>[
      for (var g = 0; g < info.numberOfWindowGroups; g++)
        List<int?>.filled(info.maxSfb, null),
    ];
    final noise = <List<int?>>[
      for (var g = 0; g < info.numberOfWindowGroups; g++)
        List<int?>.filled(info.maxSfb, null),
    ];
    var lastSf = globalGain;
    var lastIntensity = 0;
    var lastNoise = globalGain - 90 - 256;
    var firstNoise = true;
    for (var g = 0; g < info.numberOfWindowGroups; g++) {
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        final cb = codebooks[g][sfb];
        if (cb == zeroHcb) continue;
        if (cb == 12) {
          throw AacDecoderException(
            'Reserved AAC codebook 12',
            bitOffset: reader.bitOffset,
          );
        }
        if (cb == intensityHcb || cb == intensityHcb2) {
          lastIntensity += _decodeScaleFactorDelta(reader);
          intensity[g][sfb] = lastIntensity;
        } else if (cb == noiseHcb) {
          lastNoise += firstNoise
              ? reader.readBits(9)
              : _decodeScaleFactorDelta(reader);
          firstNoise = false;
          noise[g][sfb] = lastNoise;
        } else {
          lastSf += _decodeScaleFactorDelta(reader);
          if (lastSf < 0 || lastSf > 255) {
            throw AacDecoderException(
              'AAC scalefactor accumulator escaped 0..255',
              bitOffset: reader.bitOffset,
            );
          }
          scaleFactors[g][sfb] = lastSf;
        }
      }
    }

    AacPulseData? pulse;
    if (reader.readBool()) {
      if (info.isShort) {
        throw AacDecoderException(
          'pulse_data is forbidden on EIGHT_SHORT_SEQUENCE',
          bitOffset: reader.bitOffset - 1,
        );
      }
      final count = reader.readBits(2) + 1;
      final startSfb = reader.readBits(6);
      pulse = AacPulseData(
        startSfb,
        List<AacPulse>.generate(
          count,
          (_) => AacPulse(reader.readBits(5), reader.readBits(4)),
          growable: false,
        ),
      );
    }

    List<AacTnsWindow>? tns;
    if (reader.readBool()) {
      tns = _parseTns(reader, info);
    }
    if (reader.readBool()) {
      throw AacDecoderException(
        'gain_control_data is not supported by AAC-LC',
        bitOffset: reader.bitOffset - 1,
      );
    }

    final quantized = _parseSpectral(reader, info, sections);
    return AacChannelData(
      info: info,
      codebooks: codebooks,
      scaleFactors: scaleFactors,
      intensityPositions: intensity,
      noiseEnergies: noise,
      quantizedGroups: quantized,
      pulseData: pulse,
      tnsWindows: tns,
    );
  }

  List<List<AacSection>> _parseSections(AacBitReader reader, AacIcsInfo info) {
    final lengthBits = info.isShort ? 3 : 5;
    final escape = (1 << lengthBits) - 1;
    final result = <List<AacSection>>[];
    for (var group = 0; group < info.numberOfWindowGroups; group++) {
      final list = <AacSection>[];
      var start = 0;
      while (start < info.maxSfb) {
        final codebook = reader.readBits(4);
        var length = 0;
        while (true) {
          final increment = reader.readBits(lengthBits);
          length += increment;
          if (increment != escape) break;
          if (length > info.maxSfb) {
            throw AacDecoderException(
              'AAC section escape run exceeds max_sfb',
              bitOffset: reader.bitOffset,
            );
          }
        }
        if (length <= 0 || start + length > info.maxSfb) {
          throw AacDecoderException(
            'Invalid AAC section length=$length at sfb=$start',
            bitOffset: reader.bitOffset,
          );
        }
        list.add(AacSection(codebook, start, start + length));
        start += length;
      }
      result.add(list);
    }
    return result;
  }

  List<AacTnsWindow> _parseTns(AacBitReader reader, AacIcsInfo info) {
    final short = info.isShort;
    final nFiltBits = short ? 1 : 2;
    final lengthBits = short ? 4 : 6;
    final orderBits = short ? 3 : 5;
    return List<AacTnsWindow>.generate(info.numberOfWindows, (_) {
      final filterCount = reader.readBits(nFiltBits);
      final coefficientResolution = filterCount == 0 ? 3 : 3 + reader.readBit();
      final filters = List<AacTnsFilter>.generate(filterCount, (_) {
        final length = reader.readBits(lengthBits);
        final order = reader.readBits(orderBits);
        if (order == 0) {
          return AacTnsFilter(
            length: length,
            order: 0,
            direction: false,
            coefficientResolution: coefficientResolution,
            coefficientCompression: false,
            coefficients: const <int>[],
          );
        }
        final direction = reader.readBool();
        final compressed = reader.readBool();
        final coefficientBits = coefficientResolution - (compressed ? 1 : 0);
        return AacTnsFilter(
          length: length,
          order: order,
          direction: direction,
          coefficientResolution: coefficientResolution,
          coefficientCompression: compressed,
          coefficients: List<int>.generate(
            order,
            (_) => reader.readBits(coefficientBits),
            growable: false,
          ),
        );
      }, growable: false);
      return AacTnsWindow(filters);
    }, growable: false);
  }

  List<Int32List> _parseSpectral(
    AacBitReader reader,
    AacIcsInfo info,
    List<List<AacSection>> sections,
  ) {
    final swb = info.isShort
        ? shortSwbOffsets(samplingFrequencyIndex)
        : longSwbOffsets(samplingFrequencyIndex);
    final result = <Int32List>[];
    for (var group = 0; group < info.numberOfWindowGroups; group++) {
      final groupLength = info.windowGroupLength[group];
      final data = Int32List(info.windowLength * groupLength);
      final offsets = List<int>.filled(info.maxSfb + 1, 0);
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        offsets[sfb + 1] =
            offsets[sfb] + (swb[sfb + 1] - swb[sfb]) * groupLength;
      }
      for (final section in sections[group]) {
        final cb = section.codebook;
        if (cb == 0 || cb >= 13) continue;
        if (cb == 12) {
          throw AacDecoderException(
            'Reserved spectral codebook 12',
            bitOffset: reader.bitOffset,
          );
        }
        final dimension = cb <= 4 ? 4 : 2;
        var index = offsets[section.startSfb];
        final end = offsets[section.endSfb];
        if ((end - index) % dimension != 0) {
          throw const AacDecoderException(
            'AAC section does not contain complete Huffman tuples',
          );
        }
        while (index < end) {
          final table = aacSpectralHuffman[cb]!;
          final codewordIndex = table.decode(
            reader,
            label: 'spectral codebook $cb',
          );
          final tuple = _decodeTuple(cb, codewordIndex);
          if (_isUnsignedCodebook(cb)) {
            for (var i = 0; i < dimension; i++) {
              if (tuple[i] != 0 && reader.readBool()) tuple[i] = -tuple[i];
            }
          }
          if (cb == escapeHcb) {
            for (var i = 0; i < dimension; i++) {
              if (tuple[i].abs() == 16) {
                final sign = tuple[i].isNegative ? -1 : 1;
                tuple[i] = sign * _decodeEscape(reader);
              }
            }
          }
          for (var i = 0; i < dimension; i++) {
            data[index + i] = tuple[i];
          }
          index += dimension;
        }
      }
      result.add(data);
    }
    return result;
  }
}

int _decodeScaleFactorDelta(AacBitReader reader) =>
    aacScaleFactorHuffman.decode(reader, label: 'scale factors') - 60;

List<int> _decodeTuple(int codebook, int index) {
  late final int dimension;
  late final int largestAbsoluteValue;
  if (codebook <= 2) {
    dimension = 4;
    largestAbsoluteValue = 1;
  } else if (codebook <= 4) {
    dimension = 4;
    largestAbsoluteValue = 2;
  } else if (codebook <= 6) {
    dimension = 2;
    largestAbsoluteValue = 4;
  } else if (codebook <= 8) {
    dimension = 2;
    largestAbsoluteValue = 7;
  } else if (codebook <= 10) {
    dimension = 2;
    largestAbsoluteValue = 12;
  } else {
    dimension = 2;
    largestAbsoluteValue = 16;
  }
  final unsigned = _isUnsignedCodebook(codebook);
  final modulus = unsigned
      ? largestAbsoluteValue + 1
      : 2 * largestAbsoluteValue + 1;
  final offset = unsigned ? 0 : largestAbsoluteValue;
  final values = List<int>.filled(dimension, 0);
  var remaining = index;
  for (var i = dimension - 1; i >= 0; i--) {
    values[i] = remaining % modulus - offset;
    remaining ~/= modulus;
  }
  if (remaining != 0) {
    throw AacDecoderException(
      'Huffman tuple index is invalid for codebook $codebook',
    );
  }
  return values;
}

bool _isUnsignedCodebook(int codebook) =>
    codebook == 3 || codebook == 4 || (codebook >= 7 && codebook <= 11);

int _decodeEscape(AacBitReader reader) {
  var prefix = 0;
  while (reader.readBool()) {
    prefix++;
    if (prefix > 24) {
      throw AacDecoderException(
        'AAC escape sequence is unreasonably large',
        bitOffset: reader.bitOffset,
      );
    }
  }
  final bits = prefix + 4;
  return (1 << bits) + reader.readBits(bits);
}

const List<int> _long44100And48000 = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  32,
  36,
  40,
  48,
  56,
  64,
  72,
  80,
  88,
  96,
  108,
  120,
  132,
  144,
  160,
  176,
  196,
  216,
  240,
  264,
  292,
  320,
  352,
  384,
  416,
  448,
  480,
  512,
  544,
  576,
  608,
  640,
  672,
  704,
  736,
  768,
  800,
  832,
  864,
  896,
  928,
  1024,
];
const List<int> _long32000 = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  32,
  36,
  40,
  48,
  56,
  64,
  72,
  80,
  88,
  96,
  108,
  120,
  132,
  144,
  160,
  176,
  196,
  216,
  240,
  264,
  292,
  320,
  352,
  384,
  416,
  448,
  480,
  512,
  544,
  576,
  608,
  640,
  672,
  704,
  736,
  768,
  800,
  832,
  864,
  896,
  928,
  960,
  992,
  1024,
];
const List<int> _long8000 = <int>[
  0,
  12,
  24,
  36,
  48,
  60,
  72,
  84,
  96,
  108,
  120,
  132,
  144,
  156,
  172,
  188,
  204,
  220,
  236,
  252,
  268,
  288,
  308,
  328,
  348,
  372,
  396,
  420,
  448,
  476,
  508,
  544,
  580,
  620,
  664,
  712,
  764,
  820,
  880,
  944,
  1024,
];
const List<int> _longLow = <int>[
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  72,
  80,
  88,
  100,
  112,
  124,
  136,
  148,
  160,
  172,
  184,
  196,
  212,
  228,
  244,
  260,
  280,
  300,
  320,
  344,
  368,
  396,
  424,
  456,
  492,
  532,
  572,
  616,
  664,
  716,
  772,
  832,
  896,
  960,
  1024,
];
const List<int> _long22050And24000 = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  32,
  36,
  40,
  44,
  52,
  60,
  68,
  76,
  84,
  92,
  100,
  108,
  116,
  124,
  136,
  148,
  160,
  172,
  188,
  204,
  220,
  240,
  260,
  284,
  308,
  336,
  364,
  396,
  432,
  468,
  508,
  552,
  600,
  652,
  704,
  768,
  832,
  896,
  960,
  1024,
];
const List<int> _long64000 = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  32,
  36,
  40,
  44,
  48,
  52,
  56,
  64,
  72,
  80,
  88,
  100,
  112,
  124,
  140,
  156,
  172,
  192,
  216,
  240,
  268,
  304,
  344,
  384,
  424,
  464,
  504,
  544,
  584,
  624,
  664,
  704,
  744,
  784,
  824,
  864,
  904,
  944,
  984,
  1024,
];
const List<int> _longHigh = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  32,
  36,
  40,
  44,
  48,
  52,
  56,
  64,
  72,
  80,
  88,
  96,
  108,
  120,
  132,
  144,
  156,
  172,
  188,
  212,
  240,
  276,
  320,
  384,
  448,
  512,
  576,
  640,
  704,
  768,
  832,
  896,
  960,
  1024,
];

const List<int> _shortCommon = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  28,
  36,
  44,
  56,
  68,
  80,
  96,
  112,
  128,
];
const List<int> _short8000 = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  36,
  44,
  52,
  60,
  72,
  88,
  108,
  128,
];
const List<int> _shortLow = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  32,
  40,
  48,
  60,
  72,
  88,
  108,
  128,
];
const List<int> _shortMid = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  28,
  36,
  44,
  52,
  64,
  76,
  92,
  108,
  128,
];
const List<int> _shortHigh = <int>[
  0,
  4,
  8,
  12,
  16,
  20,
  24,
  32,
  40,
  48,
  64,
  92,
  128,
];

List<int> longSwbOffsets(int index) => switch (index) {
  0 || 1 => _longHigh,
  2 => _long64000,
  3 || 4 => _long44100And48000,
  5 => _long32000,
  6 || 7 => _long22050And24000,
  8 || 9 || 10 => _longLow,
  11 => _long8000,
  _ => throw AacDecoderException(
    'Unsupported AAC samplingFrequencyIndex=$index',
  ),
};

List<int> shortSwbOffsets(int index) => switch (index) {
  0 || 1 || 2 => _shortHigh,
  3 || 4 || 5 => _shortCommon,
  6 || 7 => _shortMid,
  8 || 9 || 10 => _shortLow,
  11 => _short8000,
  _ => throw AacDecoderException(
    'Unsupported AAC samplingFrequencyIndex=$index',
  ),
};
