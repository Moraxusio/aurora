import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/painter.dart';

import '../test/terminal_run_paint_test.dart' show terminalPixels;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real system fonts keep their fixed-cell placement in batched runs',
    (t) async {
      await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
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
      for (final font in ['Consolas', 'Courier New', 'Arial']) {
        for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
          TerminalPainter painter() => TerminalPainter(
            theme: TerminalThemes.defaultTheme,
            textStyle: TerminalStyle(
              fontFamily: font,
              fontFamilyFallback: const ['Microsoft YaHei', 'Segoe UI Emoji'],
              fontSize: 14,
            ),
            textScaler: TextScaler.noScaling,
          );
          final a = painter(), b = painter();
          final reference = await terminalPixels(terminal, a, dpr, false);
          final batched = await terminalPixels(terminal, b, dpr, true);
          var changed = 0, worst = 0;
          for (var i = 0; i < reference.length; i++) {
            final delta = (reference[i] - batched[i]).abs();
            if (delta > 3) changed++;
            if (delta > worst) worst = delta;
          }
          a.dispose();
          b.dispose();
          // Native subpixel glyph rasterization can differ slightly when the
          // same glyph is drawn inside a paragraph run; never permit a shifted
          // cell or a visibly changed colour/background.
          expect(
            changed,
            0,
            reason: '$font / $dpr: $changed changed channels, worst $worst',
          );
        }
      }
    },
  );
}
