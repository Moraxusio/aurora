import 'dart:math' as math;

import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.x contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  double lum(Color c) {
    double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  final la = lum(a), lb = lum(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('the ratio function is right on known pairs', () {
    expect(contrast(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrast(Colors.white, Colors.white), closeTo(1, 0.001));
    // #767676 on white is the classic 4.54:1
    expect(contrast(const Color(0xFF767676), Colors.white), closeTo(4.54, 0.02));
  });

  for (final (name, ide) in [('dark', Ide.dark), ('light', Ide.light)]) {
    group('$name palette', () {
      final backgrounds = {
        'editor': ide.editor,
        'sideBar': ide.sideBar,
        'frame': ide.frame,
        'surface': ide.surface,
        'hover': ide.hover,
        'statusBar': ide.statusBar,
      };
      // The small text in a UI: file sizes, key caps, group names, hints. It is
      // 10–12 px, so it needs the full 4.5:1 of body text.
      for (final e in backgrounds.entries) {
        test('textFaint on ${e.key} is at least 4.5:1', () {
          final r = contrast(ide.textFaint, e.value);
          expect(r, greaterThanOrEqualTo(4.5), reason: '${ide.textFaint} on ${e.value} = ${r.toStringAsFixed(2)}');
        });
        test('textDim on ${e.key} is at least 4.5:1', () {
          final r = contrast(ide.textDim, e.value);
          expect(r, greaterThanOrEqualTo(4.5), reason: '${ide.textDim} on ${e.value} = ${r.toStringAsFixed(2)}');
        });
        test('text on ${e.key} is at least 7:1', () {
          final r = contrast(ide.text, e.value);
          expect(r, greaterThanOrEqualTo(7), reason: '${ide.text} on ${e.value} = ${r.toStringAsFixed(2)}');
        });
      }

      test('textFaint stays quieter than textDim, which stays quieter than text', () {
        final bg = ide.editor;
        expect(contrast(ide.textFaint, bg), lessThan(contrast(ide.textDim, bg)));
        expect(contrast(ide.textDim, bg), lessThan(contrast(ide.text, bg)));
      });

      test('status colours are readable on the editor', () {
        for (final (label, c) in [('error', ide.error), ('warn', ide.warn), ('ok', ide.ok), ('accent', ide.accent)]) {
          final r = contrast(c, ide.editor);
          expect(r, greaterThanOrEqualTo(3), reason: '$label = ${r.toStringAsFixed(2)}');
        }
      });
    });
  }
}
