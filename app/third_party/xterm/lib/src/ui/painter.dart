import 'dart:collection';
import 'dart:ui';
import 'package:flutter/painting.dart';

import 'package:xterm/src/utils/hash_values.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);
  // Aurora patch: keep bounded, exact-key runs as well as single glyphs. A
  // dense TUI used to issue one drawRect + drawParagraph per cell per frame.
  final _runs = LinkedHashMap<(String, int, int, int), Paragraph?>();

  void _clearRuns() {
    for (final p in _runs.values) {
      p?.dispose();
    }
    _runs.clear();
  }

  void dispose() {
    _clearRuns();
    _paragraphCache.clear();
  }

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _clearRuns();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _clearRuns();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _clearRuns();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _clearRuns();
  }

  /// Paints the cursor based on the current cursor type. [under] is the cell the
  /// cursor is on: a block cursor draws that character again in the
  /// background colour (Aurora patch; the original left the block opaque over
  /// it, so the character under the cursor disappeared).
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
    CellData? under,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        if (under != null &&
            (under.content & CellContent.codepointMask) > 0x20) {
          paintCellForeground(canvas, offset, under,
              colorOverride: _theme.background);
        }
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, _cellSize.height - 1),
          Offset(offset.dx + _cellSize.width, _cellSize.height - 1),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, 0),
          Offset(offset.dx, _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line, {
    double? lineHeight,
  }) {
    final cellData = CellData.empty();
    final next = CellData.empty();
    final cellWidth = _cellSize.width;
    // Paint background spans before foreground. Besides reducing draw calls,
    // this prevents the following cell's background covering an overhanging
    // italic/wide glyph from the previous cell.
    var start = 0;
    Color? background;
    void flushBackground(int end) {
      if (background != null && end > start) {
        canvas.drawRect(
          Rect.fromLTWH(offset.dx + start * cellWidth, offset.dy,
              (end - start) * cellWidth + 1, lineHeight ?? _cellSize.height),
          Paint()..color = background!,
        );
      }
    }

    for (var i = 0; i < line.length;) {
      line.getCellData(i, cellData);
      final color = cellData.flags & CellFlags.inverse != 0
          ? resolveForegroundColor(cellData.foreground)
          : cellData.background & CellColor.typeMask == CellColor.normal
              ? null
              : resolveBackgroundColor(cellData.background);
      if (color != background) {
        flushBackground(i);
        start = i;
        background = color;
      }
      i += cellData.content >> CellContent.widthShift == 2 ? 2 : 1;
    }
    flushBackground(line.length);

    for (var i = 0; i < line.length;) {
      line.getCellData(i, cellData);
      final code = cellData.content & CellContent.codepointMask;
      final width = cellData.content >> CellContent.widthShift;
      if (code <= 0x20 && cellData.flags & CellFlags.underline == 0) {
        i += width == 2 ? 2 : 1;
        continue;
      }
      var end = i + 1;
      if (_canRun(cellData)) {
        while (end < line.length && end - i < 64) {
          line.getCellData(end, next);
          if (!_canRun(next) ||
              next.foreground != cellData.foreground ||
              next.background != cellData.background ||
              next.flags != cellData.flags) break;
          end++;
        }
      }
      if (end - i >= 2) {
        final chars = <int>[];
        for (var c = i; c < end; c++) {
          line.getCellData(c, next);
          chars.add(next.content & CellContent.codepointMask);
        }
        final text = String.fromCharCodes(chars);
        final key =
            (text, cellData.foreground, cellData.background, cellData.flags);
        Paragraph? run;
        if (_runs.containsKey(key)) {
          run = _runs.remove(key);
        } else {
          run = _buildRun(text, cellData);
        }
        _runs[key] = run;
        if (_runs.length > 2048) _runs.remove(_runs.keys.first)?.dispose();
        if (run != null) {
          canvas.drawParagraph(run, offset.translate(i * cellWidth, 0));
          i = end;
          continue;
        }
        // Proportional/fallback fonts that fail the exact cell advance check
        // use the original fixed-cell renderer; never squeeze/stretch a run.
        for (; i < end; i++) {
          line.getCellData(i, next);
          paintCellForeground(canvas, offset.translate(i * cellWidth, 0), next);
        }
        continue;
      }
      paintCellForeground(canvas, offset.translate(i * cellWidth, 0), cellData);
      i += width == 2 ? 2 : 1;
    }
  }

  bool _canRun(CellData cell) {
    final code = cell.content & CellContent.codepointMask;
    return code >= 0x20 &&
        code <= 0x7e &&
        cell.content >> CellContent.widthShift == 1 &&
        cell.flags & (CellFlags.italic | CellFlags.underline) == 0;
  }

  Paragraph? _buildRun(String text, CellData cell) {
    var color = cell.flags & CellFlags.inverse == 0
        ? resolveForegroundColor(cell.foreground)
        : resolveBackgroundColor(cell.background);
    if (cell.flags & CellFlags.faint != 0) color = color.withValues(alpha: 0.5);
    final style = _textStyle
        .toTextStyle(color: color, bold: cell.flags & CellFlags.bold != 0)
        .copyWith(fontFeatures: const [
      FontFeature.disable('liga'),
      FontFeature.disable('calt'),
      FontFeature.disable('kern')
    ]);
    final builder = ParagraphBuilder(style.getParagraphStyle())
      ..pushStyle(style.getTextStyle(textScaler: _textScaler))
      ..addText(text);
    final paragraph = builder.build()
      ..layout(const ParagraphConstraints(width: double.infinity));
    // Exact grid validation once on cache miss. ASCII in a true monospace
    // font passes; CJK, emoji, combining marks and proportional fonts never
    // enter the fast path or fall back without changing their position.
    for (var i = 0; i < text.length; i++) {
      final boxes = paragraph.getBoxesForRange(i, i + 1);
      if (boxes.length != 1 ||
          (boxes.single.left - i * _cellSize.width).abs() > 0.05 ||
          (boxes.single.right - (i + 1) * _cellSize.width).abs() > 0.05) {
        paragraph.dispose();
        return null;
      }
    }
    return paragraph;
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData,
      {double? lineHeight}) {
    paintCellBackground(canvas, offset, cellData, lineHeight: lineHeight);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData,
      {Color? colorOverride}) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    // an override colour is not the cell's own, so its glyph is not cached under the cell's key
    final cacheKey = colorOverride == null
        ? cellData.getHash() ^ _textScaler.hashCode
        : hashValues(cellData.getHash(), colorOverride.toARGB32(), 7) ^
            _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;

      var color = colorOverride ??
          (cellFlags & CellFlags.inverse == 0
              ? resolveForegroundColor(cellData.foreground)
              : resolveBackgroundColor(cellData.background));

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData,
      {double? lineHeight}) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    // Aurora patch: the background covers the line down to the next line's top
    // (render.dart snaps both to the pixel grid), not the nominal cell height.
    final size =
        Size(_cellSize.width * widthScale + 1, lineHeight ?? _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
