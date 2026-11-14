import 'dart:ui';

import 'package:aurora/kernel/workbench_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('three workbench hosts stay disjoint through narrow, short and maximized layouts', () {
    for (final width in [390.0, 879.0, 880.0, 1000.0, 1440.0]) {
      for (final height in [240.0, 360.0, 700.0]) {
        for (final wanted in [320.0, 800.0, double.nan]) {
          for (var flags = 0; flags < 64; flags++) {
            final geometry = WorkbenchGeometry(size: Size(width, height), preferredHeight: 260,
              panelVisible: flags & 1 != 0, panelFocused: flags & 2 != 0, panelMaximized: flags & 4 != 0,
              assistantVisible: flags & 8 != 0, assistantFocused: flags & 16 != 0, assistantMaximized: flags & 32 != 0,
              assistantWidth: wanted);
            final rects = [geometry.editor, geometry.terminal, geometry.divider, geometry.assistant, geometry.assistantDivider].whereType<Rect>().toList();
            for (var i = 0; i < rects.length; i++) {
              final rect = rects[i];
              expect(rect.isFinite, isTrue); expect(rect.width, greaterThanOrEqualTo(0)); expect(rect.height, greaterThanOrEqualTo(0));
              expect(rect.left, greaterThanOrEqualTo(0)); expect(rect.top, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(width)); expect(rect.bottom, lessThanOrEqualTo(height));
              for (final other in rects.skip(i + 1)) { expect(rect.overlaps(other), isFalse); }
            }
          }
        }
      }
    }
  });

  test('editor and panel rectangles are disjoint and bounded for every window state', () {
    var cases = 0;
    for (final width in [0.0, 240.0, 390.0, 600.0, 900.0, 1440.0]) {
      for (final height in [0.0, 200.0, 359.0, 360.0, 500.0, 900.0]) {
        for (final wanted in [120.0, 260.0, 1200.0, double.nan]) {
          for (final shown in [false, true]) {
            for (final focused in [false, true]) {
              for (final maximized in [false, true]) {
                final g = WorkbenchGeometry(
                  size: Size(width, height),
                  panelVisible: shown,
                  panelFocused: focused,
                  panelMaximized: maximized,
                  preferredHeight: wanted,
                );
                final rectangles = [
                  g.editor,
                  g.terminal,
                  g.divider,
                ].whereType<Rect>().toList();
                for (final r in rectangles) {
                  expect(r.isFinite, isTrue);
                  expect(r.width, greaterThanOrEqualTo(0));
                  expect(r.height, greaterThanOrEqualTo(0));
                  expect(r.left, greaterThanOrEqualTo(0));
                  expect(r.top, greaterThanOrEqualTo(0));
                  expect(r.right, lessThanOrEqualTo(width));
                  expect(r.bottom, lessThanOrEqualTo(height));
                }
                for (var a = 0; a < rectangles.length; a++) {
                  for (var b = a + 1; b < rectangles.length; b++) {
                    expect(rectangles[a].overlaps(rectangles[b]), isFalse);
                  }
                }
                if (!shown) {
                  expect(g.editor, isNotNull);
                  expect(g.terminal, isNull);
                }
                cases++;
              }
            }
          }
        }
      }
    }
    expect(cases, 1152);
  });

  test('opening an editor in a compact window returns it to the front without altering panel preferences', () {
    final terminal = WorkbenchGeometry(
      size: const Size(390, 700),
      panelVisible: true,
      panelFocused: true,
      panelMaximized: false,
      preferredHeight: 310,
    );
    final editor = WorkbenchGeometry(
      size: const Size(390, 700),
      panelVisible: true,
      panelFocused: false,
      panelMaximized: false,
      preferredHeight: 310,
    );
    expect(terminal.editor, isNull);
    expect(terminal.terminal, const Rect.fromLTWH(0, 0, 390, 700));
    expect(editor.terminal, isNull);
    expect(editor.editor, const Rect.fromLTWH(0, 0, 390, 700));
    final wide = WorkbenchGeometry(
      size: const Size(1200, 900),
      panelVisible: true,
      panelFocused: false,
      panelMaximized: false,
      preferredHeight: 310,
    );
    expect(wide.terminal!.height, 310);
    expect(
      wide.editor!.bottom,
      wide.terminal!.top - WorkbenchGeometry.dividerSize,
    );
  });
}
