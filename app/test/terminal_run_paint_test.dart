import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/painter.dart';

Future<Uint8List> terminalPixels(
  Terminal terminal,
  TerminalPainter painter,
  double dpr,
  bool runs,
) async {
  final width = (painter.cellSize.width * terminal.viewWidth * dpr).ceil();
  final height = (painter.cellSize.height * terminal.viewHeight * dpr).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(dpr);
  canvas.drawColor(TerminalThemes.defaultTheme.background, BlendMode.src);
  final cell = CellData.empty();
  double snap(double y) => (y * dpr).floorToDouble() / dpr;
  for (var y = 0; y < terminal.viewHeight; y++) {
    final top = snap(y * painter.cellSize.height);
    final next = snap((y + 1) * painter.cellSize.height);
    final line = terminal.buffer.lines[y];
    if (runs) {
      painter.paintLine(canvas, Offset(0, top), line, lineHeight: next - top);
    } else {
      // Reference fixed-cell renderer, background pass then foreground pass.
      // CJK/emoji must still occupy exactly the original terminal cells.
      for (var x = 0; x < line.length; x++) {
        line.getCellData(x, cell);
        painter.paintCellBackground(
          canvas,
          Offset(x * painter.cellSize.width, top),
          cell,
          lineHeight: next - top,
        );
        if (cell.content >> CellContent.widthShift == 2) x++;
      }
      for (var x = 0; x < line.length; x++) {
        line.getCellData(x, cell);
        painter.paintCellForeground(
          canvas,
          Offset(x * painter.cellSize.width, top),
          cell,
        );
        if (cell.content >> CellContent.widthShift == 2) x++;
      }
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final result = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  image.dispose();
  picture.dispose();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    test(
      'batched backgrounds and text preserve the fixed-cell pixels at scale $dpr',
      () async {
        final terminal = Terminal()..resize(60, 8);
        terminal.write(
          'ASCII azAZ 0123456789 !=-> /path/file.txt\r\n'
          '\x1b[38;2;180;210;240m\x1b[48;2;17;24;39mcoloured spaces   END\x1b[0m\r\n'
          '\x1b[1mBOLD ASCII\x1b[0m / \x1b[2mFAINT\x1b[0m\r\n'
          '\x1b[7mINVERSE\x1b[0m \x1b[3mITALIC\x1b[0m \x1b[4mUNDER LINE\x1b[0m\r\n'
          'ASCII 中文 🙂 XYZ\r\n'
          '\x1b[41mRED\x1b[44mBLUE\x1b[0mNORMAL\r\n'
          'iiii WWWW ..... proportional fallback',
        );
        for (final font in ['Ahem', 'Consolas', 'Arial']) {
          TerminalPainter painter() => TerminalPainter(
            theme: TerminalThemes.defaultTheme,
            textStyle: TerminalStyle(fontFamily: font, fontSize: 14),
            textScaler: TextScaler.noScaling,
          );
          final refPainter = painter(), runPainter = painter();
          final reference = await terminalPixels(
            terminal,
            refPainter,
            dpr,
            false,
          );
          final batched = await terminalPixels(terminal, runPainter, dpr, true);
          var changed = 0, worst = 0;
          for (var i = 0; i < reference.length; i++) {
            final delta = (reference[i] - batched[i]).abs();
            if (delta > 3) changed++;
            if (delta > worst) worst = delta;
          }
          expect(
            changed,
            0,
            reason:
                '$font / $dpr: changed channels $changed, worst delta $worst',
          );
          refPainter.dispose();
          runPainter.dispose();
        }
      },
    );
  }
}
