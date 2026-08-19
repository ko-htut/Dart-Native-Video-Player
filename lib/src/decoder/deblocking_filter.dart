import 'dart:typed_data';

/// A motion vector in quarter-luma-sample units.
final class H264MotionVector {
  const H264MotionVector(this.x, this.y);

  static const zero = H264MotionVector(0, 0);

  final int x;
  final int y;
}

/// Information used to derive boundary strength for one luma 4x4 block.
///
/// [referencePictureId] is optional because a decoder with an unreordered P
/// reference list can compare [referenceIndexL0] directly.  When either side
/// supplies a picture id, both sides must supply the same id to be considered
/// the same reference picture.
final class H264DeblockingBlock {
  const H264DeblockingBlock({
    this.totalCoeff = 0,
    this.referenceIndexL0 = 0,
    this.referencePictureId,
    this.motionVectorL0 = H264MotionVector.zero,
  });

  final int totalCoeff;
  final int referenceIndexL0;
  final int? referencePictureId;
  final H264MotionVector motionVectorL0;

  bool get hasResidual => totalCoeff != 0;

  bool hasSameReferenceAs(H264DeblockingBlock other) {
    if (referencePictureId != null || other.referencePictureId != null) {
      return referencePictureId != null &&
          referencePictureId == other.referencePictureId;
    }
    return referenceIndexL0 == other.referenceIndexL0;
  }
}

/// Deblocking metadata for one 16x16 luma / 8x8 chroma macroblock.
///
/// [lumaBlocks] is raster ordered and must contain 16 entries.  The chroma
/// TotalCoeff arrays are raster ordered 2x2 arrays.  H.264 4:2:0 derives the
/// boundary strength shared by luma and chroma from the associated luma 4x4
/// blocks; the chroma counts are retained here so reconstruction metadata is
/// complete and can be inspected by callers. [qpCb] and [qpCr] must already be
/// mapped through H.264 table 8-15 using the PPS chroma QP offsets.
final class H264DeblockingMacroblock {
  const H264DeblockingMacroblock({
    required this.isIntra,
    required this.qpY,
    required this.qpCb,
    required this.qpCr,
    required this.lumaBlocks,
    this.cbTotalCoeff = const <int>[0, 0, 0, 0],
    this.crTotalCoeff = const <int>[0, 0, 0, 0],
    this.sliceId = 0,
  });

  final bool isIntra;
  final int qpY;
  final int qpCb;
  final int qpCr;
  final List<H264DeblockingBlock> lumaBlocks;
  final List<int> cbTotalCoeff;
  final List<int> crTotalCoeff;
  final int sliceId;

  bool get hasChromaResidual =>
      cbTotalCoeff.any((value) => value != 0) ||
      crTotalCoeff.any((value) => value != 0);
}

/// Slice-level syntax that controls the in-loop deblocking filter.
final class H264DeblockingSliceParameters {
  const H264DeblockingSliceParameters({
    this.disableDeblockingFilterIdc = 0,
    this.sliceAlphaC0OffsetDiv2 = 0,
    this.sliceBetaOffsetDiv2 = 0,
  });

  /// 0 filters every available edge, 1 disables filtering, and 2 prevents
  /// filtering only across slice boundaries.
  final int disableDeblockingFilterIdc;

  /// The bitstream syntax value, in the inclusive range -6 through 6.
  final int sliceAlphaC0OffsetDiv2;

  /// The bitstream syntax value, in the inclusive range -6 through 6.
  final int sliceBetaOffsetDiv2;
}

/// H.264/AVC 8-bit, progressive, 4:2:0 in-loop deblocking (clause 8.7).
///
/// The coded dimensions must be whole macroblocks.  Planes may have padding at
/// the end of each row by passing explicit strides; the filter never reads
/// outside the coded rectangle.  Macroblocks are supplied in raster order.
abstract final class H264DeblockingFilter {
  /// Filters [luma], [cb], and [cr] in place.
  ///
  /// [defaultSliceParameters] is used when [sliceParametersById] has no entry
  /// for a macroblock's [H264DeblockingMacroblock.sliceId].  This keeps the
  /// common one-slice integration call small while supporting multi-slice
  /// pictures and `disable_deblocking_filter_idc == 2` correctly.
  static void apply420({
    required Uint8List luma,
    required Uint8List cb,
    required Uint8List cr,
    required int codedWidth,
    required int codedHeight,
    int? lumaStride,
    int? chromaStride,
    required List<H264DeblockingMacroblock> macroblocks,
    H264DeblockingSliceParameters defaultSliceParameters =
        const H264DeblockingSliceParameters(),
    Map<int, H264DeblockingSliceParameters> sliceParametersById = const {},
  }) {
    final yStride = lumaStride ?? codedWidth;
    final chromaWidth = codedWidth >> 1;
    final chromaHeight = codedHeight >> 1;
    final cStride = chromaStride ?? chromaWidth;

    _validatePicture(
      luma: luma,
      cb: cb,
      cr: cr,
      codedWidth: codedWidth,
      codedHeight: codedHeight,
      lumaStride: yStride,
      chromaStride: cStride,
      macroblocks: macroblocks,
    );

    final mbWidth = codedWidth >> 4;
    final mbHeight = codedHeight >> 4;
    final strengths = Uint8List(4);

    H264DeblockingSliceParameters parametersFor(
      H264DeblockingMacroblock macroblock,
    ) {
      final parameters =
          sliceParametersById[macroblock.sliceId] ?? defaultSliceParameters;
      _validateSliceParameters(parameters);
      return parameters;
    }

    for (var mbY = 0; mbY < mbHeight; mbY++) {
      for (var mbX = 0; mbX < mbWidth; mbX++) {
        final current = macroblocks[mbY * mbWidth + mbX];
        final parameters = parametersFor(current);
        if (parameters.disableDeblockingFilterIdc == 1) {
          continue;
        }

        // H.264 specifies all vertical edges of a macroblock before all of its
        // horizontal edges.  The ordering matters because filtering is in-loop.
        for (var edge = 0; edge < 4; edge++) {
          if (!_verticalEdgeAvailable(
            edge: edge,
            mbX: mbX,
            mbY: mbY,
            mbWidth: mbWidth,
            macroblocks: macroblocks,
            parameters: parameters,
          )) {
            continue;
          }
          _writeVerticalBoundaryStrengths(
            edge: edge,
            mbX: mbX,
            mbY: mbY,
            mbWidth: mbWidth,
            macroblocks: macroblocks,
            output: strengths,
          );
          if (_allZero(strengths)) {
            continue;
          }

          final neighbor = edge == 0
              ? macroblocks[mbY * mbWidth + mbX - 1]
              : current;
          final qpY = edge == 0
              ? _averageQp(neighbor.qpY, current.qpY)
              : current.qpY;
          _filterLumaEdge(
            plane: luma,
            stride: yStride,
            qX: mbX * 16 + edge * 4,
            qY: mbY * 16,
            vertical: true,
            strengths: strengths,
            qp: qpY,
            parameters: parameters,
          );

          // 4:2:0 chroma has only the external edge and the edge at luma edge
          // index 2.  It reuses the four luma boundary strengths, two chroma
          // samples per strength.
          if (edge.isEven) {
            final qpCb = edge == 0
                ? _averageQp(neighbor.qpCb, current.qpCb)
                : current.qpCb;
            final qpCr = edge == 0
                ? _averageQp(neighbor.qpCr, current.qpCr)
                : current.qpCr;
            final chromaX = mbX * 8 + (edge >> 1) * 4;
            final chromaY = mbY * 8;
            _filterChromaEdge(
              plane: cb,
              stride: cStride,
              qX: chromaX,
              qY: chromaY,
              vertical: true,
              strengths: strengths,
              qp: qpCb,
              parameters: parameters,
            );
            _filterChromaEdge(
              plane: cr,
              stride: cStride,
              qX: chromaX,
              qY: chromaY,
              vertical: true,
              strengths: strengths,
              qp: qpCr,
              parameters: parameters,
            );
          }
        }

        for (var edge = 0; edge < 4; edge++) {
          if (!_horizontalEdgeAvailable(
            edge: edge,
            mbX: mbX,
            mbY: mbY,
            mbWidth: mbWidth,
            macroblocks: macroblocks,
            parameters: parameters,
          )) {
            continue;
          }
          _writeHorizontalBoundaryStrengths(
            edge: edge,
            mbX: mbX,
            mbY: mbY,
            mbWidth: mbWidth,
            macroblocks: macroblocks,
            output: strengths,
          );
          if (_allZero(strengths)) {
            continue;
          }

          final neighbor = edge == 0
              ? macroblocks[(mbY - 1) * mbWidth + mbX]
              : current;
          final qpY = edge == 0
              ? _averageQp(neighbor.qpY, current.qpY)
              : current.qpY;
          _filterLumaEdge(
            plane: luma,
            stride: yStride,
            qX: mbX * 16,
            qY: mbY * 16 + edge * 4,
            vertical: false,
            strengths: strengths,
            qp: qpY,
            parameters: parameters,
          );

          if (edge.isEven) {
            final qpCb = edge == 0
                ? _averageQp(neighbor.qpCb, current.qpCb)
                : current.qpCb;
            final qpCr = edge == 0
                ? _averageQp(neighbor.qpCr, current.qpCr)
                : current.qpCr;
            final chromaX = mbX * 8;
            final chromaY = mbY * 8 + (edge >> 1) * 4;
            _filterChromaEdge(
              plane: cb,
              stride: cStride,
              qX: chromaX,
              qY: chromaY,
              vertical: false,
              strengths: strengths,
              qp: qpCb,
              parameters: parameters,
            );
            _filterChromaEdge(
              plane: cr,
              stride: cStride,
              qX: chromaX,
              qY: chromaY,
              vertical: false,
              strengths: strengths,
              qp: qpCr,
              parameters: parameters,
            );
          }
        }
      }
    }

    // Keep these values part of the validation contract even when assertions
    // are disabled and document the exact filtered chroma rectangle.
    assert(chromaWidth > 0 && chromaHeight > 0);
  }

  /// Derives bS for a pair of adjacent luma 4x4 blocks.
  static int deriveBoundaryStrength({
    required H264DeblockingBlock p,
    required H264DeblockingBlock q,
    required bool pMacroblockIsIntra,
    required bool qMacroblockIsIntra,
    required bool isMacroblockBoundary,
  }) {
    if (pMacroblockIsIntra || qMacroblockIsIntra) {
      return isMacroblockBoundary ? 4 : 3;
    }
    if (p.hasResidual || q.hasResidual) {
      return 2;
    }
    if (!p.hasSameReferenceAs(q)) {
      return 1;
    }
    final pMv = p.motionVectorL0;
    final qMv = q.motionVectorL0;
    if ((pMv.x - qMv.x).abs() >= 4 || (pMv.y - qMv.y).abs() >= 4) {
      return 1;
    }
    return 0;
  }

  static void _validatePicture({
    required Uint8List luma,
    required Uint8List cb,
    required Uint8List cr,
    required int codedWidth,
    required int codedHeight,
    required int lumaStride,
    required int chromaStride,
    required List<H264DeblockingMacroblock> macroblocks,
  }) {
    if (codedWidth <= 0 ||
        codedHeight <= 0 ||
        codedWidth.isOdd ||
        codedHeight.isOdd ||
        codedWidth % 16 != 0 ||
        codedHeight % 16 != 0) {
      throw ArgumentError(
        'Coded dimensions must be positive multiples of 16: '
        '${codedWidth}x$codedHeight',
      );
    }
    final chromaWidth = codedWidth >> 1;
    final chromaHeight = codedHeight >> 1;
    if (lumaStride < codedWidth || chromaStride < chromaWidth) {
      throw ArgumentError('Plane stride is smaller than its coded width');
    }
    final requiredLumaLength = (codedHeight - 1) * lumaStride + codedWidth;
    final requiredChromaLength =
        (chromaHeight - 1) * chromaStride + chromaWidth;
    if (luma.length < requiredLumaLength ||
        cb.length < requiredChromaLength ||
        cr.length < requiredChromaLength) {
      throw ArgumentError('A plane is smaller than its coded rectangle');
    }
    final requiredMacroblocks = (codedWidth >> 4) * (codedHeight >> 4);
    if (macroblocks.length != requiredMacroblocks) {
      throw ArgumentError.value(
        macroblocks.length,
        'macroblocks.length',
        'Expected $requiredMacroblocks raster-ordered macroblocks',
      );
    }
    for (var index = 0; index < macroblocks.length; index++) {
      final macroblock = macroblocks[index];
      if (macroblock.lumaBlocks.length != 16 ||
          macroblock.cbTotalCoeff.length != 4 ||
          macroblock.crTotalCoeff.length != 4) {
        throw ArgumentError(
          'Macroblock $index needs 16 luma and 4+4 chroma block entries',
        );
      }
      if (!_validQp(macroblock.qpY) ||
          !_validQp(macroblock.qpCb) ||
          !_validQp(macroblock.qpCr)) {
        throw ArgumentError('Macroblock $index has a QP outside 0...51');
      }
      for (final block in macroblock.lumaBlocks) {
        if (block.totalCoeff < 0) {
          throw ArgumentError('Macroblock $index has a negative TotalCoeff');
        }
      }
      if (macroblock.cbTotalCoeff.any((value) => value < 0) ||
          macroblock.crTotalCoeff.any((value) => value < 0)) {
        throw ArgumentError(
          'Macroblock $index has a negative chroma TotalCoeff',
        );
      }
    }
  }

  static void _validateSliceParameters(
    H264DeblockingSliceParameters parameters,
  ) {
    if (parameters.disableDeblockingFilterIdc < 0 ||
        parameters.disableDeblockingFilterIdc > 2) {
      throw ArgumentError.value(
        parameters.disableDeblockingFilterIdc,
        'disableDeblockingFilterIdc',
        'Expected 0, 1, or 2',
      );
    }
    if (parameters.sliceAlphaC0OffsetDiv2 < -6 ||
        parameters.sliceAlphaC0OffsetDiv2 > 6 ||
        parameters.sliceBetaOffsetDiv2 < -6 ||
        parameters.sliceBetaOffsetDiv2 > 6) {
      throw ArgumentError('Deblocking slice offsets must be in -6...6');
    }
  }

  static bool _verticalEdgeAvailable({
    required int edge,
    required int mbX,
    required int mbY,
    required int mbWidth,
    required List<H264DeblockingMacroblock> macroblocks,
    required H264DeblockingSliceParameters parameters,
  }) {
    if (edge != 0) {
      return true;
    }
    if (mbX == 0) {
      return false;
    }
    if (parameters.disableDeblockingFilterIdc != 2) {
      return true;
    }
    final q = macroblocks[mbY * mbWidth + mbX];
    final p = macroblocks[mbY * mbWidth + mbX - 1];
    return p.sliceId == q.sliceId;
  }

  static bool _horizontalEdgeAvailable({
    required int edge,
    required int mbX,
    required int mbY,
    required int mbWidth,
    required List<H264DeblockingMacroblock> macroblocks,
    required H264DeblockingSliceParameters parameters,
  }) {
    if (edge != 0) {
      return true;
    }
    if (mbY == 0) {
      return false;
    }
    if (parameters.disableDeblockingFilterIdc != 2) {
      return true;
    }
    final q = macroblocks[mbY * mbWidth + mbX];
    final p = macroblocks[(mbY - 1) * mbWidth + mbX];
    return p.sliceId == q.sliceId;
  }

  static void _writeVerticalBoundaryStrengths({
    required int edge,
    required int mbX,
    required int mbY,
    required int mbWidth,
    required List<H264DeblockingMacroblock> macroblocks,
    required Uint8List output,
  }) {
    final qMacroblock = macroblocks[mbY * mbWidth + mbX];
    final pMacroblock = edge == 0
        ? macroblocks[mbY * mbWidth + mbX - 1]
        : qMacroblock;
    for (var blockY = 0; blockY < 4; blockY++) {
      final pBlockX = edge == 0 ? 3 : edge - 1;
      final qBlockX = edge;
      output[blockY] = deriveBoundaryStrength(
        p: pMacroblock.lumaBlocks[blockY * 4 + pBlockX],
        q: qMacroblock.lumaBlocks[blockY * 4 + qBlockX],
        pMacroblockIsIntra: pMacroblock.isIntra,
        qMacroblockIsIntra: qMacroblock.isIntra,
        isMacroblockBoundary: edge == 0,
      );
    }
  }

  static void _writeHorizontalBoundaryStrengths({
    required int edge,
    required int mbX,
    required int mbY,
    required int mbWidth,
    required List<H264DeblockingMacroblock> macroblocks,
    required Uint8List output,
  }) {
    final qMacroblock = macroblocks[mbY * mbWidth + mbX];
    final pMacroblock = edge == 0
        ? macroblocks[(mbY - 1) * mbWidth + mbX]
        : qMacroblock;
    for (var blockX = 0; blockX < 4; blockX++) {
      final pBlockY = edge == 0 ? 3 : edge - 1;
      final qBlockY = edge;
      output[blockX] = deriveBoundaryStrength(
        p: pMacroblock.lumaBlocks[pBlockY * 4 + blockX],
        q: qMacroblock.lumaBlocks[qBlockY * 4 + blockX],
        pMacroblockIsIntra: pMacroblock.isIntra,
        qMacroblockIsIntra: qMacroblock.isIntra,
        isMacroblockBoundary: edge == 0,
      );
    }
  }

  static void _filterLumaEdge({
    required Uint8List plane,
    required int stride,
    required int qX,
    required int qY,
    required bool vertical,
    required List<int> strengths,
    required int qp,
    required H264DeblockingSliceParameters parameters,
  }) {
    final indexA = _clip3(0, 51, qp + parameters.sliceAlphaC0OffsetDiv2 * 2);
    final indexB = _clip3(0, 51, qp + parameters.sliceBetaOffsetDiv2 * 2);
    final alpha = _alphaTable[indexA];
    final beta = _betaTable[indexB];
    if (alpha == 0 || beta == 0) {
      return;
    }
    final acrossStep = vertical ? 1 : stride;
    final alongStep = vertical ? stride : 1;
    final firstQ = qY * stride + qX;
    for (var segment = 0; segment < 4; segment++) {
      final strength = strengths[segment];
      if (strength == 0) {
        continue;
      }
      var qIndex = firstQ + segment * 4 * alongStep;
      for (var sample = 0; sample < 4; sample++) {
        if (strength == 4) {
          _filterStrongLumaSample(plane, qIndex, acrossStep, alpha, beta);
        } else {
          _filterWeakLumaSample(
            plane,
            qIndex,
            acrossStep,
            alpha,
            beta,
            _tc0Table[indexA][strength - 1],
          );
        }
        qIndex += alongStep;
      }
    }
  }

  static void _filterChromaEdge({
    required Uint8List plane,
    required int stride,
    required int qX,
    required int qY,
    required bool vertical,
    required List<int> strengths,
    required int qp,
    required H264DeblockingSliceParameters parameters,
  }) {
    final indexA = _clip3(0, 51, qp + parameters.sliceAlphaC0OffsetDiv2 * 2);
    final indexB = _clip3(0, 51, qp + parameters.sliceBetaOffsetDiv2 * 2);
    final alpha = _alphaTable[indexA];
    final beta = _betaTable[indexB];
    if (alpha == 0 || beta == 0) {
      return;
    }
    final acrossStep = vertical ? 1 : stride;
    final alongStep = vertical ? stride : 1;
    final firstQ = qY * stride + qX;
    for (var segment = 0; segment < 4; segment++) {
      final strength = strengths[segment];
      if (strength == 0) {
        continue;
      }
      var qIndex = firstQ + segment * 2 * alongStep;
      for (var sample = 0; sample < 2; sample++) {
        if (strength == 4) {
          _filterStrongChromaSample(plane, qIndex, acrossStep, alpha, beta);
        } else {
          _filterWeakChromaSample(
            plane,
            qIndex,
            acrossStep,
            alpha,
            beta,
            _tc0Table[indexA][strength - 1] + 1,
          );
        }
        qIndex += alongStep;
      }
    }
  }

  static void _filterWeakLumaSample(
    Uint8List plane,
    int qIndex,
    int step,
    int alpha,
    int beta,
    int tc0,
  ) {
    final p0 = plane[qIndex - step];
    final p1 = plane[qIndex - 2 * step];
    final p2 = plane[qIndex - 3 * step];
    final q0 = plane[qIndex];
    final q1 = plane[qIndex + step];
    final q2 = plane[qIndex + 2 * step];
    if ((p0 - q0).abs() >= alpha ||
        (p1 - p0).abs() >= beta ||
        (q1 - q0).abs() >= beta) {
      return;
    }

    final ap = (p2 - p0).abs() < beta;
    final aq = (q2 - q0).abs() < beta;
    if (ap && tc0 != 0) {
      final adjustment = _clip3(
        -tc0,
        tc0,
        ((p2 + ((p0 + q0 + 1) >> 1)) >> 1) - p1,
      );
      plane[qIndex - 2 * step] = _clipSample(p1 + adjustment);
    }
    if (aq && tc0 != 0) {
      final adjustment = _clip3(
        -tc0,
        tc0,
        ((q2 + ((p0 + q0 + 1) >> 1)) >> 1) - q1,
      );
      plane[qIndex + step] = _clipSample(q1 + adjustment);
    }
    final tc = tc0 + (ap ? 1 : 0) + (aq ? 1 : 0);
    final delta = _clip3(-tc, tc, (((q0 - p0) * 4) + (p1 - q1) + 4) >> 3);
    plane[qIndex - step] = _clipSample(p0 + delta);
    plane[qIndex] = _clipSample(q0 - delta);
  }

  static void _filterStrongLumaSample(
    Uint8List plane,
    int qIndex,
    int step,
    int alpha,
    int beta,
  ) {
    final p0 = plane[qIndex - step];
    final p1 = plane[qIndex - 2 * step];
    final p2 = plane[qIndex - 3 * step];
    final q0 = plane[qIndex];
    final q1 = plane[qIndex + step];
    final q2 = plane[qIndex + 2 * step];
    if ((p0 - q0).abs() >= alpha ||
        (p1 - p0).abs() >= beta ||
        (q1 - q0).abs() >= beta) {
      return;
    }

    if ((p0 - q0).abs() < (alpha >> 2) + 2) {
      if ((p2 - p0).abs() < beta) {
        final p3 = plane[qIndex - 4 * step];
        plane[qIndex - step] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3;
        plane[qIndex - 2 * step] = (p2 + p1 + p0 + q0 + 2) >> 2;
        plane[qIndex - 3 * step] = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3;
      } else {
        plane[qIndex - step] = (2 * p1 + p0 + q1 + 2) >> 2;
      }
      if ((q2 - q0).abs() < beta) {
        final q3 = plane[qIndex + 3 * step];
        plane[qIndex] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3;
        plane[qIndex + step] = (p0 + q0 + q1 + q2 + 2) >> 2;
        plane[qIndex + 2 * step] = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3;
      } else {
        plane[qIndex] = (2 * q1 + q0 + p1 + 2) >> 2;
      }
    } else {
      plane[qIndex - step] = (2 * p1 + p0 + q1 + 2) >> 2;
      plane[qIndex] = (2 * q1 + q0 + p1 + 2) >> 2;
    }
  }

  static void _filterWeakChromaSample(
    Uint8List plane,
    int qIndex,
    int step,
    int alpha,
    int beta,
    int tc,
  ) {
    final p0 = plane[qIndex - step];
    final p1 = plane[qIndex - 2 * step];
    final q0 = plane[qIndex];
    final q1 = plane[qIndex + step];
    if ((p0 - q0).abs() >= alpha ||
        (p1 - p0).abs() >= beta ||
        (q1 - q0).abs() >= beta) {
      return;
    }
    final delta = _clip3(-tc, tc, (((q0 - p0) * 4) + (p1 - q1) + 4) >> 3);
    plane[qIndex - step] = _clipSample(p0 + delta);
    plane[qIndex] = _clipSample(q0 - delta);
  }

  static void _filterStrongChromaSample(
    Uint8List plane,
    int qIndex,
    int step,
    int alpha,
    int beta,
  ) {
    final p0 = plane[qIndex - step];
    final p1 = plane[qIndex - 2 * step];
    final q0 = plane[qIndex];
    final q1 = plane[qIndex + step];
    if ((p0 - q0).abs() >= alpha ||
        (p1 - p0).abs() >= beta ||
        (q1 - q0).abs() >= beta) {
      return;
    }
    plane[qIndex - step] = (2 * p1 + p0 + q1 + 2) >> 2;
    plane[qIndex] = (2 * q1 + q0 + p1 + 2) >> 2;
  }

  static bool _allZero(List<int> values) =>
      values[0] == 0 && values[1] == 0 && values[2] == 0 && values[3] == 0;

  static bool _validQp(int qp) => qp >= 0 && qp <= 51;

  static int _averageQp(int p, int q) => (p + q + 1) >> 1;

  static int _clipSample(int value) => _clip3(0, 255, value);

  static int _clip3(int minimum, int maximum, int value) {
    if (value < minimum) {
      return minimum;
    }
    if (value > maximum) {
      return maximum;
    }
    return value;
  }
}

// H.264 tables 8-16 and 8-17 for 8-bit samples.
const List<int> _alphaTable = <int>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  4,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  12,
  13,
  15,
  17,
  20,
  22,
  25,
  28,
  32,
  36,
  40,
  45,
  50,
  56,
  63,
  71,
  80,
  90,
  101,
  113,
  127,
  144,
  162,
  182,
  203,
  226,
  255,
  255,
];

const List<int> _betaTable = <int>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
  14,
  14,
  15,
  15,
  16,
  16,
  17,
  17,
  18,
  18,
];

const List<List<int>> _tc0Table = <List<int>>[
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 0],
  <int>[0, 0, 1],
  <int>[0, 0, 1],
  <int>[0, 0, 1],
  <int>[0, 0, 1],
  <int>[0, 1, 1],
  <int>[0, 1, 1],
  <int>[1, 1, 1],
  <int>[1, 1, 1],
  <int>[1, 1, 1],
  <int>[1, 1, 1],
  <int>[1, 1, 2],
  <int>[1, 1, 2],
  <int>[1, 1, 2],
  <int>[1, 1, 2],
  <int>[1, 2, 3],
  <int>[1, 2, 3],
  <int>[2, 2, 3],
  <int>[2, 2, 4],
  <int>[2, 3, 4],
  <int>[2, 3, 4],
  <int>[3, 3, 5],
  <int>[3, 4, 6],
  <int>[3, 4, 6],
  <int>[4, 5, 7],
  <int>[4, 5, 8],
  <int>[4, 6, 9],
  <int>[5, 7, 10],
  <int>[6, 8, 11],
  <int>[6, 8, 13],
  <int>[7, 10, 14],
  <int>[8, 11, 16],
  <int>[9, 12, 18],
  <int>[10, 13, 20],
  <int>[11, 15, 23],
  <int>[13, 17, 25],
];
