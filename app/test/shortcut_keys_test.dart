import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shortcutKeys', () {
    test('ordinary shortcuts split on the plus', () {
      expect(shortcutKeys('Ctrl+Shift+P'), ['Ctrl', 'Shift', 'P']);
      expect(shortcutKeys('Ctrl+B'), ['Ctrl', 'B']);
      expect(shortcutKeys('F2'), ['F2']);
      expect(shortcutKeys('Alt+↑'), ['Alt', '↑']);
    });

    test('the plus key is a key, not three empty ones', () {
      expect(shortcutKeys('Ctrl++'), ['Ctrl', '+']);
      expect(shortcutKeys('Ctrl+Shift++'), ['Ctrl', 'Shift', '+']);
      expect(shortcutKeys('+'), ['+']);
    });

    test('minus, backslash and backquote are keys too', () {
      expect(shortcutKeys('Ctrl+-'), ['Ctrl', '-']);
      expect(shortcutKeys('Ctrl+Shift+\\'), ['Ctrl', 'Shift', '\\']);
      expect(shortcutKeys('Ctrl+`'), ['Ctrl', '`']);
      expect(shortcutKeys('Ctrl+Shift+`'), ['Ctrl', 'Shift', '`']);
    });

    test('no result ever holds an empty key', () {
      for (final s in ['Ctrl++', 'Ctrl+', '+Ctrl', 'Ctrl+ +', '', '++', 'A++B', 'Ctrl+Shift+Enter']) {
        expect(shortcutKeys(s).where((k) => k.isEmpty), isEmpty, reason: '"$s" -> ${shortcutKeys(s)}');
      }
    });
  });

  testWidgets('KeyCaps draws one cap per key, and Ctrl++ has two', (t) async {
    Future<int> caps(String keys) async {
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: Center(child: KeyCaps(keys)))));
      return find.descendant(of: find.byType(KeyCaps), matching: find.byType(Text)).evaluate().length;
    }

    expect(await caps('Ctrl+Shift+P'), 3);
    expect(await caps('Ctrl++'), 2);
    expect(find.text('+'), findsOneWidget);
    expect(await caps('Ctrl+-'), 2);
    expect(find.text('-'), findsOneWidget);
  });
}
