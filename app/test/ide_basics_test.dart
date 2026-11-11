import 'dart:async';

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/search/quick_open.dart';
import 'package:aurora/features/search/search_model.dart';
import 'package:aurora/features/search/search_scope.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' show TextLineBreak;

import 'support/workspace_fixture.dart';

/// Answers the file, search and quick open operations the way the agent does,
/// and records what was asked.
class IdeLink extends FileTreeLink {
  final asked = <(String, Map)>[];
  String content = 'line 1\nline 2\n';
  String etag = 'e1';
  int fileReads = 0;
  final writes = <String>[];
  final Map<String, Completer<Object?>> hold = {};
  Map<String, dynamic> Function(Map args)? onSearch;
  Map<String, dynamic> Function(Map args)? onFind;

  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    final a = (args as Map?) ?? const {};
    if (op != 'agent.services' && op != 'fs.roots') asked.add((op, a));
    final h = hold.remove(op);
    if (h != null) return h.future;
    switch (op) {
      case 'fs.read':
        fileReads++;
        return {'content': content, 'etag': etag, 'size': content.length};
      case 'fs.write':
        writes.add(a['content'] as String);
        content = a['content'] as String;
        etag = 'e${writes.length + 1}';
        return {'etag': etag};
      case 'fs.stat':
        return {'etag': etag};
      case 'fs.search':
        return onSearch!(a);
      case 'fs.find':
        return onFind!(a);
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  late IdeLink link;
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  setUp(() {
    link = IdeLink();
    app = WorkspaceApp(wire: link);
    app.data.servers.single.selectedWorkspace = 'a';
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
  });
  tearDown(() {
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  Future<void> show(WidgetTester t, Widget w) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: InputMode.scope(mode: input, child: Scaffold(body: SizedBox(width: 800, height: 600, child: w))),
    ));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester t) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  }

  group('quick open', () {
    test(':N after the name is a line number', () {
      expect(splitLine('main.go:120'), ('main.go', 120));
      expect(splitLine(' src/a.dart '), ('src/a.dart', null));
      expect(splitLine('a:b'), ('a:b', null));
      expect(splitLine(':5'), ('', 5));
    });

    test('answers of several folders are interleaved, best of each first', () async {
      link.onFind = (a) => {
            'files': a['root'] == 'home' ? ['/project/a1', '/project/a2', '/project/a3'] : ['/other/b1'],
          };
      final r = await findFiles(link, const [SearchFolder('home', '/project', 'project'), SearchFolder('data', '/other', 'other')], 'x', fresh: true);
      expect([for (final i in r) i.path], ['/project/a1', '/other/b1', '/project/a2', '/project/a3']);
      expect(link.asked.where((c) => c.$1 == 'fs.find').every((c) => c.$2['fresh'] == true && c.$2['query'] == 'x'), isTrue);
    });

    test('a folder that fails does not hide the others', () async {
      link.onFind = (a) => a['root'] == 'home' ? throw OpError(codeNotFound, 'gone') : {'files': ['/other/b1']};
      final r = await findFiles(link, const [SearchFolder('home', '/project', 'project'), SearchFolder('data', '/other', 'other')], '');
      expect([for (final i in r) i.path], ['/other/b1']);
    });
  });

  group('search', () {
    const folder = SearchFolder('home', '/project', 'project');
    Map<String, dynamic> answer(String path) => {
          'files': [
            {
              'path': path,
              'matches': [
                {'line': 3, 'col': 5, 'text': 'let needle = 1', 'ranges': [[4, 10]]},
              ],
            },
          ],
          'total': 1,
        };

    test('results carry line, column and the match ranges; options are sent', () async {
      link.onSearch = (a) => answer('/project/src/a.dart');
      final m = SearchModel(ws, folders: (_) async => const [folder]);
      await m.search(const SearchOptions('needle', matchCase: true, word: true, include: '*.dart'));
      expect(m.running, isFalse);
      expect(m.total, 1);
      final f = m.results.single;
      expect(f.path, '/project/src/a.dart');
      expect(f.lines.single.line, 3);
      expect(f.lines.single.col, 5);
      expect(f.lines.single.ranges, [(4, 10)]);
      final args = link.asked.firstWhere((c) => c.$1 == 'fs.search').$2;
      expect(args['case'], isTrue);
      expect(args['word'], isTrue);
      expect(args['regex'], isFalse);
      expect(args['include'], '*.dart');
      expect(args.containsKey('exclude'), isFalse);
      m.dispose();
    });

    test('a newer search makes a slower older answer count for nothing', () async {
      final slow = Completer<Object?>();
      link.hold['fs.search'] = slow;
      link.onSearch = (a) => answer('/project/new.txt');
      final m = SearchModel(ws, folders: (_) async => const [folder]);
      final first = m.search(const SearchOptions('old'));
      await Future<void>.delayed(Duration.zero);
      await m.search(const SearchOptions('new'));
      slow.complete(answer('/project/old.txt'));
      await first;
      expect([for (final f in m.results) f.path], ['/project/new.txt']);
      m.dispose();
    });

    test('a bad expression is an error, not an empty result', () async {
      link.onSearch = (a) => throw OpError(codeBadRequest, '表达式无效');
      final m = SearchModel(ws, folders: (_) async => const [folder]);
      await m.search(const SearchOptions('(', regex: true));
      expect(m.error, '表达式无效');
      expect(m.running, isFalse);
      m.dispose();
    });

    test('the scope is the project folders, or the roots except /', () async {
      expect(await searchFolders(ws), [const SearchFolder('home', '/project', 'project')]);
      app.data.servers.single.selectedWorkspace = null;
      final browse = Workspace(app, 'server');
      expect(await searchFolders(browse), [const SearchFolder('home', '/', 'Home')]);
      browse.dispose();
    });
  });

  group('split editor', () {
    EditorTab tab(String id) => EditorTab(id: id, title: id, icon: Icons.terminal, builder: (_) => const SizedBox());

    test('one tab is never on both sides; closing a side unsplits', () async {
      for (final id in ['t1', 't2', 't3']) {
        ws.openTab(tab(id));
      }
      expect(ws.activeId, 't3');
      ws.splitActive();
      expect(ws.split, isTrue);
      expect(ws.sideId, 't3');
      expect(ws.activeId, 't2');
      expect(ws.sideFocused, isTrue);
      expect(ws.active!.id, 't3');
      // opening an already shown tab moves the focus, it is not shown twice
      ws.activate('t2');
      expect(ws.sideFocused, isFalse);
      expect(ws.sideId, 't3');
      // Ctrl+Tab on the left skips the right side's tab
      ws.next(1);
      expect(ws.activeId, 't1');
      expect(ws.sideId, 't3');
      await ws.closeTab('t3');
      expect(ws.split, isFalse);
      expect(ws.activeId, 't1');
    });

    test('closing the last left tab hands the area to the right one', () async {
      ws.openTab(tab('a'));
      ws.openTab(tab('b'));
      ws.splitActive();
      expect((ws.activeId, ws.sideId), ('a', 'b'));
      await ws.closeTab('a');
      expect(ws.split, isFalse);
      expect(ws.activeId, 'b');
    });

    test('splitting needs a second tab; Ctrl+\\ on the right side unsplits', () {
      ws.openTab(tab('only'));
      ws.splitActive();
      expect(ws.split, isFalse);
      ws.openTab(tab('two'));
      ws.splitActive();
      expect(ws.split, isTrue);
      ws.splitActive();
      expect(ws.split, isFalse);
      expect(ws.activeId, 'two');
    });
  });

  group('settings', () {
    test('out-of-range values are clamped; defaults are not written', () {
      final s = EditorSettings.fromJson({'theme': 'neon', 'font_size': 400, 'tab_size': 3, 'word_wrap': true});
      expect(s.theme, 'system');
      expect(s.fontSize, EditorSettings.maxFont);
      expect(s.tabSize, 4);
      expect(s.wordWrap, isTrue);
      expect(Profile().toJson().containsKey('editor'), isFalse);
      final p = Profile(editor: EditorSettings(theme: 'dark', tabSize: 2));
      final back = Profile.fromJson(p.toJson());
      expect((back.editor.theme, back.editor.tabSize), ('dark', 2));
    });
  });

  group('editor', () {
    test('line break of a file', () {
      expect(lineBreakOf('a\r\nb'), TextLineBreak.crlf);
      expect(lineBreakOf('a\nb'), TextLineBreak.lf);
      expect(lineBreakOf('one line'), TextLineBreak.lf);
      expect(lineBreakOf('a\rb\r'), TextLineBreak.cr);
    });

    testWidgets('a CRLF file opens clean and is saved with CRLF', (t) async {
      link.content = 'a\r\nb\r\n';
      final key = GlobalKey<FileEditorState>();
      await show(t, FileEditor(key: key, ws: ws, root: 'home', path: '/project/w.txt'));
      expect(key.currentState!.dirty, isFalse);
      key.currentState!.text = 'a\nchanged\n';
      expect(key.currentState!.dirty, isTrue);
      await key.currentState!.save();
      await t.pump();
      expect(link.writes.single, 'a\r\nchanged\r\n');
      expect(key.currentState!.dirty, isFalse);
      await settle(t);
    });

    testWidgets('a change on the server reloads a clean editor', (t) async {
      await show(t, FileEditor(ws: ws, root: 'home', path: '/project/w.txt'));
      expect(link.fileReads, 1);
      link.content = 'new from server\n';
      link.etag = 'e9';
      ws.watch.debugEvent({'type': 'change', 'root': 'home', 'path': '/project', 'names': ['w.txt']});
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(link.fileReads, 2);
      // a change to another file in the folder is not this editor's business
      ws.watch.debugEvent({'type': 'change', 'root': 'home', 'path': '/project', 'names': ['other.txt']});
      await t.pump(const Duration(milliseconds: 100));
      expect(link.fileReads, 2);
      await settle(t);
    });

    testWidgets('a change on the server never replaces unsaved text: the banner asks', (t) async {
      final key = GlobalKey<FileEditorState>();
      await show(t, FileEditor(key: key, ws: ws, root: 'home', path: '/project/w.txt'));
      key.currentState!.text = 'mine\n';
      link.etag = 'e9';
      ws.watch.debugEvent({'type': 'change', 'root': 'home', 'path': '/project', 'names': ['w.txt']});
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(link.fileReads, 1);
      expect(find.textContaining('被别的程序修改了'), findsOneWidget);
      expect(key.currentState!.text, 'mine\n');
      await t.tap(find.text('保留我的修改'));
      await t.pump();
      expect(find.textContaining('被别的程序修改了'), findsNothing);
      await settle(t);
    });

    testWidgets('reveal moves the cursor of an open file to the line', (t) async {
      link.content = List.generate(50, (i) => 'line ${i + 1}').join('\n');
      final key = GlobalKey<FileEditorState>();
      await show(t, FileEditor(key: key, ws: ws, root: 'home', path: '/project/w.txt', line: 10, col: 3));
      await t.pump();
      expect(key.currentState!.cursor, (9, 2));
      key.currentState!.reveal(40, 1);
      await t.pump();
      expect(key.currentState!.cursor, (39, 0));
      key.currentState!.reveal(999, 1); // past the end: the last line
      expect(key.currentState!.cursor.$1, 49);
      await settle(t);
    });
  });
}
