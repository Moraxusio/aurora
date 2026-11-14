import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

enum PdfPointerMode { select, hand }

/// Page-relative coordinates survive switching between one and two columns.
class PdfReadingPlace {
  final int page;
  final Offset relativeCenter;
  final double zoom;
  const PdfReadingPlace(this.page, this.relativeCenter, this.zoom);

  static PdfReadingPlace? capture(PdfViewerController controller) {
    if (!controller.isReady || controller.layout.pageLayouts.isEmpty) {
      return null;
    }
    final page = controller.pageNumber ?? 1;
    final rect = controller.layout.pageLayouts[page - 1];
    final center = controller.centerPosition;
    return PdfReadingPlace(
      page,
      Offset(
        (center.dx - rect.left) / rect.width,
        (center.dy - rect.top) / rect.height,
      ),
      controller.currentZoom,
    );
  }

  Future<void> restore(PdfViewerController controller) async {
    if (!controller.isReady || controller.layout.pageLayouts.isEmpty) return;
    final rect =
        controller.layout.pageLayouts[page.clamp(1, controller.pageCount) - 1];
    final center = Offset(
      rect.left + rect.width * relativeCenter.dx,
      rect.top + rect.height * relativeCenter.dy,
    );
    await controller.goTo(
      controller.calcMatrixFor(center, zoom: zoom),
      duration: Duration.zero,
    );
  }
}

class PdfReaderMemory {
  PdfReadingPlace? place;
  bool facing = false;
  final Set<int> bookmarks = {};
}

/// Session-only navigation state, scoped by server/root/path/revision and bounded.
final _readers = <String, PdfReaderMemory>{};
PdfReaderMemory pdfReaderMemory(String identity) {
  final memory = _readers.remove(identity) ?? PdfReaderMemory();
  _readers[identity] = memory;
  while (_readers.length > 64) {
    _readers.remove(_readers.keys.first);
  }
  return memory;
}

void clearPdfReaderMemory() => _readers.clear();

/// Cache the page arrangement, rather than walking a large document on every pan.
/// The owner invalidates this on document page/geometry events.
class PdfFacingLayout {
  PdfPageLayout? _cached;
  List<PdfPage>? _pages;
  double? _margin;
  void invalidate() => _cached = null;

  PdfPageLayout call(List<PdfPage> pages, PdfViewerParams params) {
    if (_cached != null &&
        identical(_pages, pages) &&
        _margin == params.margin) {
      return _cached!;
    }
    _pages = pages;
    _margin = params.margin;
    final gap = params.margin;
    final column = pages.fold<double>(
      0,
      (width, page) => math.max(width, page.width),
    );
    final width = column * 2 + gap * 3;
    final rects = <Rect>[];
    var y = gap;
    // The cover stands alone; subsequent pages form even/odd spreads.
    if (pages.isNotEmpty) {
      final cover = pages.first;
      rects.add(
        Rect.fromLTWH((width - cover.width) / 2, y, cover.width, cover.height),
      );
      y += cover.height + gap;
    }
    for (var i = 1; i < pages.length; i += 2) {
      final left = pages[i], right = i + 1 < pages.length ? pages[i + 1] : null;
      rects.add(
        Rect.fromLTWH(gap + column - left.width, y, left.width, left.height),
      );
      if (right != null) {
        rects.add(
          Rect.fromLTWH(column + gap * 2, y, right.width, right.height),
        );
      }
      y += math.max(left.height, right?.height ?? 0) + gap;
    }
    return _cached = PdfPageLayout(
      pageLayouts: rects,
      documentSize: Size(width, y),
    );
  }
}
