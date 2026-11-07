// Pixel tests for how the terminal view draws (third_party/xterm, patched).
// Both bugs came from a screenshot of a full-screen program (opencode) in the
// light theme at 125 % scale:
//  - thin light lines between rows: each row's top was cut to a whole logical
//    pixel while the row height is fractional (14 px x 1.2 = 16.8, and
//    16.8 x 1.25 = 21 physical), so neighbouring background rectangles left a
//    gap, and the gap shows the view's own (white) background;
//  - the character under the cursor disappeared: an opaque block was painted
//    over it.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aurora/features/terminal/terminal_colors.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

const _fontSize = 14.0;
const _dark = (10, 10, 10); // what a full-screen program paints as its background

class _Shot {
  final ByteData data;
  final int width, height;
  _Shot(this.data, this.width, this.height);
  (int, int, int) at(int x, int y) {
    final i = (y * width + x) * 4;
    return (data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
  }
}

Future<(Terminal, GlobalKey, Ide)> _show(WidgetTester t, {required Brightness brightness, double dpr = 1.25}) async {
  t.view.physicalSize = Size(700 * dpr / 1.25, 500 * dpr / 1.25);
  t.view.devicePixelRatio = dpr;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  final ide = brightness == Brightness.dark ? Ide.dark : Ide.light;
  final term = Terminal(maxLines: 100);
  final key = GlobalKey();
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(brightness),
    home: Scaffold(
      body: RepaintBoundary(
        key: key,
        child: TerminalView(
          term,
          autofocus: true,
          theme: terminalTheme(ide),
          textStyle: const TerminalStyle(fontSize: _fontSize, height: 1.2, fontFamily: 'Ahem'),
        ),
      ),
    ),
  ));
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  return (term, key, ide);
}

Future<_Shot> _grab(WidgetTester t, GlobalKey key) async {
  final shot = await t.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: t.view.devicePixelRatio);
    final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return _Shot(d, img.width, img.height);
  });
  return shot!;
}

void main() {
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('no light lines between rows of a dark full-screen program, scale $dpr', (t) async {
      final (term, key, _) = await _show(t, brightness: Brightness.light, dpr: dpr);
      final cols = term.viewWidth, rows = term.viewHeight;
      expect(rows, greaterThan(10));
      // every cell has an explicit dark background, as a full-screen TUI sets
      final b = StringBuffer('\x1b[48;2;${_dark.$1};${_dark.$2};${_dark.$3}m');
      for (var r = 0; r < rows; r++) {
        b.write('\x1b[${r + 1};1H${' ' * cols}');
      }
      b.write('\x1b[?25l'); // hide the cursor: this test is about the rows, not the cursor
      term.write(b.toString());
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      final s = await _grab(t, key);
      // The area the cells cover; the strip below the last row and to the right
      // of the last column is the view's own background and may stay white.
      const cellH = _fontSize * 1.2;
      final bottom = (rows * cellH * dpr).floor() - 2;
      final right = (cols * _fontSize * dpr).floor() - 2;
      final light = <String>[];
      for (var y = 0; y < bottom; y++) {
        for (var x = 0; x < right; x++) {
          final (r, g, bl) = s.at(x, y);
          if (r > 60 || g > 60 || bl > 60) {
            if (light.length < 6) light.add('($x,$y)=${(r, g, bl)}');
            light.add('');
          }
        }
      }
      final n = light.where((e) => e.isEmpty).length;
      if (n > 0) {
        final rowsHit = <int>{};
        for (var y = 0; y < bottom; y++) {
          final (r, g, bl) = s.at(2, y);
          if (r > 60 || g > 60 || bl > 60) rowsHit.add(y);
        }
        // ignore: avoid_print
        print('scale $dpr: light rows (x=2): ${rowsHit.take(12).toList()} of $bottom px, cell height ${cellH * dpr}');
      }
      expect(n, 0, reason: '$n light pixels inside the cell area at scale $dpr; first: ${light.where((e) => e.isNotEmpty).join(' ')}');
    });
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('the character under the cursor stays visible, ${brightness.name} theme', (t) async {
      final (term, key, ide) = await _show(t, brightness: brightness);
      term.write('A\x1b[1;1H'); // an "A", the cursor back on it
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      final s = await _grab(t, key);
      final dpr = t.view.devicePixelRatio;
      final cursor = terminalTheme(ide).cursor;
      (int, int, int) rgb(Color c) => ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());
      bool near((int, int, int) a, (int, int, int) b, [int tol = 6]) => (a.$1 - b.$1).abs() <= tol && (a.$2 - b.$2).abs() <= tol && (a.$3 - b.$3).abs() <= tol;
      // Ahem draws "A" as a solid em square, centred in the 16.8 px line: it
      // covers y 1.4..15.4. Its middle is where the block hid it; the line's
      // first pixel row is cursor only.
      final mid = s.at((7 * dpr).round(), (8.4 * dpr).round());
      final edge = s.at((7 * dpr).round(), 0);
      expect(near(edge, rgb(cursor)), isTrue, reason: 'the cursor block is drawn: edge pixel $edge, cursor ${rgb(cursor)}');
      expect(near(mid, rgb(cursor)), isFalse, reason: 'the middle of the character is not the plain cursor colour: $mid');
      expect(near(mid, rgb(ide.panel)), isTrue, reason: 'it is the character, redrawn in the background colour (${rgb(ide.panel)}): $mid');
    });
  }
}
