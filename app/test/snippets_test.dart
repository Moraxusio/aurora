import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/kernel/document_model.dart';
import 'package:aurora/kernel/document_recovery.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/snippets.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/workspace_fixture.dart';
import 'support/text_fixture.dart';

Future<DocumentModel> snippetDocument(
  String template, {
  String prefix = '',
}) async {
  final link = FileTreeLink();
  final doc = DocumentModel(
    DocumentKey('server', 'home', '/main.dart'),
    () => link,
    MemoryDocumentRecoveryStore(),
  );
  await doc.load();
  final expansion = expandSnippet(template, {});
  doc.replaceText('$prefix${expansion.text}', expectedVersion: doc.version);
  doc.startSnippet(expansion, prefix.length);
  return doc;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('snippet grammar handles escapes, forward mirrors, variables, nested fields and numeric boundaries', () {
    final expansion = expandSnippet(
      r'\$ ${2:two ${3:inner}} $1x ${1|one,two\,three,four\|five|} $2 ${TM_FILENAME} ${EMPTY:fallback} ${UNKNOWN} $0',
      {'TM_FILENAME': '中文.dart', 'EMPTY': ''},
    );
    expect(
      expansion.text,
      r'$ two inner onex one two inner 中文.dart fallback UNKNOWN ',
    );
    final one = expansion.ranges.where((r) => r.group == 1);
    expect(one.length, 2);
    expect(one.first.choices, ['one', 'two,three', 'four|five']);
    expect(expansion.ranges.firstWhere((r) => r.group == 3).ancestors, [2]);
    for (final r in expansion.ranges) {
      expect(r.start <= r.end && r.end <= expansion.text.length, isTrue);
    }
    for (final invalid in [
      r'${1:missing',
      r'${1:$1}',
      r'${1/./x/g}',
      r'${1:x}' * 257,
    ]) {
      expect(() => expandSnippet(invalid, {}), throwsStateError);
    }
  });

  test(
    'mirror edit is one genuine undo step and undo cannot reschedule a mirror',
    () async {
      final doc = await snippetDocument(r'${1:name}($1);$0');
      expect(doc.selectedText, 'name');
      doc.controller.replaceSelection('中文😀');
      await Future<void>.value();
      expect(doc.text, '中文😀(中文😀);');
      doc.controller.undo();
      await Future<void>.value();
      expect(doc.text, 'name(name);');
      expect(doc.snippet, isNull);
      doc.controller.redo();
      expect(doc.text, '中文😀(中文😀);');
      doc.controller.undo();
      doc.controller.undo();
      expect(doc.text, 'synthetic original\n');
      await doc.close();
    },
  );

  test('IME composition delays mirrors and commits them without corrupting composing text', () async {
    final doc = await snippetDocument(r'${1:x} $1 $0');
    doc.controller.edit(
      const TextEditingValue(
        text: '中 x ',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await Future<void>.value();
    expect(doc.text, '中 x ');
    expect(doc.snippet, isNotNull);
    doc.snippet!.advance();
    expect(doc.snippet, isNotNull);
    doc.controller.clearComposing();
    await Future<void>.value();
    expect(doc.text, '中 中 ');
    expect(doc.controller.composing.isCollapsed, isTrue);
    doc.controller.undo();
    expect(doc.text, 'x x ');
    await doc.close();
  });

  test('nested edits update parent mirrors, replacing a parent removes its children only', () async {
    final doc = await snippetDocument(
      r'${1:hello ${2:world}} | $1 | ${3:end}$0',
    );
    doc.snippet!.advance();
    expect(doc.selectedText, 'world');
    doc.controller.replaceSelection('朋友');
    await Future<void>.value();
    expect(doc.text, 'hello 朋友 | hello 朋友 | end');
    doc.snippet!.advance(backward: true);
    expect(doc.selectedText, 'hello 朋友');
    doc.controller.replaceSelection('new');
    await Future<void>.value();
    expect(doc.text, 'new | new | end');
    doc.snippet!.advance();
    expect(doc.selectedText, 'end');
    doc.snippet!.advance();
    expect(doc.snippet, isNull);
    expect(doc.controller.selection.extentOffset, doc.text.length);
    await doc.close();
  });

  test(
    'adjacent empty fields and repeated characters keep the correct final stop',
    () async {
      final doc = await snippetDocument(r'$1$2$0');
      doc.controller.replaceSelection('a');
      await Future<void>.value();
      doc.snippet!.advance();
      doc.controller.replaceSelection('a');
      await Future<void>.value();
      expect(doc.text, 'aa');
      doc.snippet!.advance();
      expect(doc.snippet, isNull);
      expect(doc.controller.selection.extentOffset, 2);
      await doc.close();
    },
  );

  test('CRLF selections and cursor changes preserve offsets without materializing document text', () async {
    final controller = CodeLineEditingController.fromText(
      'before\r\na\r\na\r\nb',
      const CodeLineOptions(lineBreak: TextLineBreak.crlf),
    );
    var version = 0;
    var prior = controller.text;
    controller.addListener(() {
      if (controller.text != prior) {
        version++;
        prior = controller.text;
      }
    });
    final expansion = expandSnippet(
      'before\r\n\${1:a}\r\n\$1\r\n\${2:b}\$0',
      {},
    );
    final session = SnippetSession(
      controller,
      expansion,
      0,
      version: () => version,
      onClosed: () {},
    );
    session.selectFirst();
    controller.replaceSelection('中文');
    await Future<void>.value();
    expect(controller.text, 'before\r\n中文\r\n中文\r\nb');
    session.advance();
    expect(controller.selection.baseIndex, 3);
    expect(controller.selectedText, 'b');
    session.close();
    controller.dispose();
    final plain = await snippetDocument(r'${1:abc} $0');
    final materializations = plain.textMaterializations;
    for (var i = 0; i < 20; i++) {
      plain.controller.selection = CodeLineSelection.collapsed(
        index: 0,
        offset: i % 3,
      );
    }
    expect(plain.textMaterializations, materializations);
    await plain.close();
  });

  testWidgets(
    'real editor Tab, Shift+Tab, choices, Esc and encoding status stay live',
    (t) async {
      final input = InputMode(), link = TextFixtureLink();
      final app = WorkspaceApp(wire: link);
      final ws = Workspace(app, 'server');
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: FileEditor(ws: ws, root: 'home', path: '/main.dart'),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final doc = ws.documents.find('home', '/main.dart')!;
      final expansion = expandSnippet(r'${1|red,blue|} $1 ${2:second}$0', {});
      doc.replaceText(expansion.text, expectedVersion: doc.version);
      doc.startSnippet(expansion, 0);
      await t.pumpAndSettle();
      await t.tap(find.text('选择字段值…'));
      await t.pumpAndSettle();
      await t.tap(find.text('blue'));
      await t.pumpAndSettle();
      expect(doc.text, 'blue blue second');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(doc.selectedText, 'second');
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pumpAndSettle();
      expect(doc.selectedText, 'blue');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(doc.snippet, isNull);
      expect(find.text('选择字段值…'), findsNothing);
      doc.setSaveEncoding('gb18030');
      await t.pumpAndSettle();
      expect(find.text('GB18030'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await ws.documents.flush();
      ws.dispose();
      app.dispose();
      input.dispose();
      link.disposeFixture();
    },
  );
}
