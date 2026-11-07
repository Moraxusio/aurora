// The terminal's colours must be readable on the terminal's own background, in
// both brightnesses (the first version's yellow was 1.3:1 on white), and the
// selection must not hide the text under it.
import 'dart:math' as math;

import 'package:aurora/features/terminal/terminal_colors.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final (name, ide) in [('dark', Ide.dark), ('light', Ide.light)]) {
    group(name, () {
      final t = terminalTheme(ide);

      test('every colour a program uses for text is readable on the background', () {
        final text = {
          'foreground': t.foreground,
          'red': t.red,
          'green': t.green,
          'yellow': t.yellow,
          'blue': t.blue,
          'magenta': t.magenta,
          'cyan': t.cyan,
          'white': t.white,
          'brightBlack': t.brightBlack,
          'brightRed': t.brightRed,
          'brightGreen': t.brightGreen,
          'brightYellow': t.brightYellow,
          'brightBlue': t.brightBlue,
          'brightMagenta': t.brightMagenta,
          'brightCyan': t.brightCyan,
        };
        final low = {for (final e in text.entries) if (contrast(e.value, t.background) < 3.0) e.key: contrast(e.value, t.background).toStringAsFixed(2)};
        expect(low, isEmpty, reason: 'contrast under 3:1 on the $name background: $low');
      });

      test('the selection lets the text show through', () {
        expect(t.selection.a, lessThan(0.6), reason: 'an opaque selection hides the characters it covers');
        expect(t.selection.a, greaterThan(0.1), reason: 'and an invisible one selects nothing');
      });

      test('the cursor is visible against the background', () {
        expect(contrast(t.cursor, t.background), greaterThan(2.0));
      });
    });
  }

  test('one theme object per brightness: a new object makes the view drop its glyph cache', () {
    expect(identical(terminalTheme(Ide.dark), terminalTheme(Ide.dark)), isTrue);
    expect(identical(terminalTheme(Ide.light), terminalTheme(Ide.light)), isTrue);
    expect(identical(terminalTheme(Ide.dark), terminalTheme(Ide.light)), isFalse);
  });

  test('the old first-version yellow was unreadable on white (so the check above can fail)', () {
    expect(contrast(const Color(0xFFE5E510), const Color(0xFFFFFFFF)), lessThan(1.5));
  });
}
