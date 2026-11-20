import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/files/file_tree_row.dart';
import 'package:aurora/features/files/files_feature.dart';
import 'package:aurora/features/files/transfers.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/tab_workspace_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/workspace_fixture.dart';

class _EditorFixtureLink extends FileTreeLink {
  final Map<String, String> contents = {
    '/project/src/main.dart': 'void main() {\n  final count = 1;\n  print(count);\n}\n',
    '/project/src/app.py': 'def run():\n    x = 1\n    return x\n',
    '/project/README.md': '# Hello\n',
  };
  final List<(String, Object?)> terminalCalls = [];

  @override
  AgentInfo get server => AgentInfo({
    'version': '3.25.0',
    'arch': 'amd64',
    'caps': <String>['session.list', 'session.create', 'fs.find'],
  });

  _EditorFixtureLink() {
    directories['/project'] = [
      FileTreeLink.dir('src'),
      FileTreeLink.dir('test'),
      FileTreeLink.file('README.md'),
      FileTreeLink.file('Dockerfile'),
    ];
    directories['/project/src'] = [
      FileTreeLink.file('main.dart'),
      FileTreeLink.file('app.py'),
      FileTreeLink.dir('nested'),
    ];
    directories['/project/test'] = [FileTreeLink.file('main.dart')];
  }

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'agent.services') {
      return {
        'services': [
          {
            'id': 'terminal',
            'enabled': true,
            'available': true,
            'ops': ['session.list', 'session.create', 'terminal'],
          },
          {
            'id': 'files',
            'enabled': true,
            'available': true,
            'ops': ['fs.roots', 'fs.list', 'fs.read', 'fs.write'],
          },
        ],
      };
    }
    if (op == 'session.list') {
      return {'sessions': <Object>[]};
    }
    if (op == 'session.create') {
      terminalCalls.add((op, args));
      return {'name': (args as Map)['name'], 'existed': false};
    }
    if (op == 'fs.read') {
      final path = (args as Map)['path'] as String;
      reads++;
      return {
        'content': contents[path] ?? 'line 1\nline 2\n',
        'etag': 'etag-1',
      };
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  testWidgets('desktop file clicks reuse previews; double-click and editing keep tabs', (t) async {
    t.view.physicalSize = const Size(1100, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final app = WorkspaceApp(wire: _EditorFixtureLink());
    app.data.servers.single.selectedWorkspace = 'a';
    final ws = Workspace(app, 'server');
    final transfers = Transfers(), input = InputMode(touch: false);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: InputMode.scope(mode: input, child: Scaffold(body: Row(children: [
        SizedBox(width: 275, child: FileTree(ws: ws, transfers: transfers)),
        Expanded(child: ListenableBuilder(listenable: ws,
          builder: (_, _) => TabWorkspaceView(ws: ws, empty: const SizedBox()))),
      ]))),
    ));
    Future<void> frames() async {
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }
    await frames();
    Finder row(String name) =>
        find.byWidgetPredicate((w) => w is FileTreeRow && w.name == name);
    Future<void> click(String name) async {
      await t.tap(row(name), kind: PointerDeviceKind.mouse);
      await frames();
    }
    const readme = 'file:home:/project/README.md';
    const docker = 'file:home:/project/Dockerfile';
    await click('README.md');
    expect(ws.tabLayout.previews, {readme});
    expect(ws.viewForCurrent().files, isEmpty);
    await click('Dockerfile');
    expect(ws.visibleTabs.map((t) => t.id), [docker]);
    expect(ws.documents.find('home', '/project/README.md'), isNull);
    final dockerTab = ws.tab(docker);
    await t.tap(row('Dockerfile'), kind: PointerDeviceKind.mouse);
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(row('Dockerfile'), kind: PointerDeviceKind.mouse);
    await frames();
    expect(ws.tab(docker), same(dockerTab));
    expect(ws.tabLayout.previews, isEmpty);
    await click('README.md');
    final editor = t.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'local unsaved changes';
    await t.pump();
    expect(ws.tabLayout.previews, isEmpty);
    await click('Dockerfile');
    expect(ws.visibleTabs.map((t) => t.id), [docker, readme]);
    expect(ws.documents.find('home', '/project/README.md')!.dirty, isTrue);
    expect(ws.viewForCurrent().files, containsAll([ref('/project/Dockerfile'), ref('/project/README.md')]));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await frames();
    ws.dispose();
    app.dispose();
    input.dispose();
    transfers.dispose();
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  test('fileIconSpec and folderGlyph classify diverse languages, configs, docs, and folders', () {
    expect(fileIconSpec('main.dart').badge, 'DT');
    expect(fileIconSpec('index.ts').badge, 'TS');
    expect(fileIconSpec('script.py').badge, 'PY');
    expect(fileIconSpec('server.go').badge, 'GO');
    expect(fileIconSpec('lib.rs').badge, 'RS');
    expect(fileIconSpec('paper.tex').badge, 'TEX');
    expect(fileIconSpec('report.pdf').badge, 'PDF');
    expect(fileIconSpec('Dockerfile').badge, 'DKR');
    expect(fileIconSpec('package.json').badge, 'NPM');
    expect(fileIconSpec('pubspec.lock').icon, Icons.lock_outline);
    expect(fileIconSpec('.env.local').icon, Icons.key_outlined);
    expect(fileIconSpec('.gitignore').icon, Icons.fork_right);
    expect(fileIconSpec('photo.png').icon, Icons.image_outlined);
    expect(fileIconSpec('clip.mp4').icon, Icons.movie_outlined);

    final srcColor = folderGlyph('src', expanded: false, root: false, ide: Ide.dark).$2;
    final testColor = folderGlyph('test', expanded: false, root: false, ide: Ide.dark).$2;
    final defaultColor = folderGlyph('other', expanded: false, root: false, ide: Ide.dark).$2;
    expect(srcColor, isNot(defaultColor));
    expect(testColor, isNot(defaultColor));
    expect(srcColor, isNot(testColor));
  });

  testWidgets('file explorer filter bar, keyboard navigation, and folder open-in-terminal work', (t) async {
    final link = _EditorFixtureLink();
    final app = WorkspaceApp(wire: link);
    app.data.servers.single.selectedWorkspace = 'a';
    final ws = Workspace(app, 'server');
    final transfers = Transfers();
    final input = InputMode(touch: false);

    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: SizedBox(
              width: 320,
              height: 680,
              child: FileTree(ws: ws, transfers: transfers),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 16; i++) {
      await t.pump(const Duration(milliseconds: 40));
    }

    Finder row(String path) =>
        find.byWidgetPredicate((w) => w is FileTreeRow && w.path == path);

    expect(row('/project/README.md'), findsOneWidget);
    await t.tap(find.byTooltip('新建'));
    await t.pumpAndSettle();
    expect(find.text('文件夹…'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();

    // Filter files inline and reveal matched loaded node.
    await t.tap(find.byTooltip('过滤文件（Ctrl+F）'));
    await t.pump();
    expect(find.byKey(const ValueKey('file-filter-bar')), findsOneWidget);
    await t.enterText(find.byType(TextField), 'Dockerfile');
    await t.pump();
    expect(row('/project/Dockerfile'), findsOneWidget);
    expect(row('/project/README.md'), findsNothing);

    await t.tap(find.byTooltip('关闭过滤（Esc）'));
    await t.pump();
    expect(row('/project/README.md'), findsOneWidget);

    // Right-click a folder -> "在终端中打开" creates session at that folder.
    final srcRow = row('/project/src');
    await t.tapAt(t.getCenter(srcRow), buttons: kSecondaryMouseButton);
    await t.pumpAndSettle();
    expect(find.text('在终端中打开'), findsOneWidget);
    expect(find.text('更多选项'), findsOneWidget);
    await t.tap(find.text('在终端中打开'));
    await t.pumpAndSettle();
    expect(link.terminalCalls, hasLength(1));
    final args = link.terminalCalls.single.$2 as Map;
    expect(args['root'], 'home');
    expect(args['path'], '/project/src');
    expect(ws.terminalActiveId, isNotNull);

    // Keyboard navigation: tap README.md to focus tree, ArrowUp x2 (Dockerfile -> test/), ArrowRight expands, ArrowDown + Enter opens test/main.dart.
    await t.tap(row('/project/README.md'));
    await t.pump(const Duration(milliseconds: 350));
    expect(ws.editorActiveId, 'file:home:/project/README.md');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 30));
    }
    expect(row('/project/test/main.dart'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(ws.editorActiveId, 'file:home:/project/test/main.dart');

    await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    ws.dispose();
    transfers.dispose();
    input.dispose();
    app.dispose();
  });

  testWidgets(
    'editor supports breadcrumbs, Ctrl+/, Shift+Alt+Down, Ctrl+Shift+K, Ctrl+Enter, Ctrl+D, Ctrl+H, and right-click menu',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (t) async {
      t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final link = _EditorFixtureLink();
    final app = WorkspaceApp(wire: link);
    app.data.servers.single.selectedWorkspace = 'a';
    final ws = Workspace(app, 'server');
    final input = InputMode(touch: false);
    final key = GlobalKey<FileEditorState>();

    final tab = EditorTab(
      id: 'file:home:/project/src/main.dart',
      title: 'main.dart',
      icon: fileIconSpec('main.dart').icon,
      file: ref('/project/src/main.dart'),
      builder: (_) => FileEditor(
        key: key,
        ws: ws,
        root: 'home',
        path: '/project/src/main.dart',
      ),
    );
    ws.openTab(tab);

    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: Builder(builder: tab.builder),
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 40));
    }

    // Breadcrumbs visible and clickable.
    expect(find.byKey(const ValueKey('editor-breadcrumbs')), findsOneWidget);
    expect(find.text('src'), findsOneWidget);

    // Focus editor at line 1 ("  final count = 1;")
    await t.tap(find.byType(CodeEditor));
    await t.pump();
    key.currentState!.reveal(2, 5);
    await t.pump();

    // Ctrl+D selects word "final"
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyD);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(tab.status.value, contains('已选 5 字符'));

    // Ctrl+/ toggles single-line comment ("  // final count = 1;")
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.slash);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(key.currentState!.text.split('\n')[1], startsWith('  // final count = 1;'));

    // Shift+Alt+Down duplicates current line down.
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    final afterDup = key.currentState!.text.split('\n');
    expect(afterDup[1], '  // final count = 1;');
    expect(afterDup[2], '  // final count = 1;');

    // Ctrl+Shift+K deletes current line.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyK);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    final afterDel = key.currentState!.text.split('\n');
    expect(afterDel[1], '  // final count = 1;');
    expect(afterDel[2], '  print(count);');

    // Ctrl+Enter inserts blank line below matching indent (cursor is now on line 2: '  print(count);').
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    final afterIns = key.currentState!.text.split('\n');
    expect(afterIns[3], '  ');
    expect(key.currentState!.cursor, (3, 2));

    // Ctrl+H opens Find & Replace bar; Esc closes it.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyH);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(find.text('全部替换'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.text('全部替换'), findsNothing);

    // Right-click inside editor opens VS Code context menu.
    await t.tapAt(t.getCenter(find.byType(CodeEditor)), buttons: kSecondaryMouseButton);
    await t.pumpAndSettle();
    expect(find.text('切换行注释'), findsOneWidget);
    expect(find.text('向下复制行'), findsOneWidget);
    expect(find.text('转到行…'), findsOneWidget);
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();

    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  testWidgets('duplicate editor tab titles show parent folder disambiguation and FileIcon', (t) async {
    final link = _EditorFixtureLink();
    final app = WorkspaceApp(wire: link);
    final ws = Workspace(app, 'server');
    final input = InputMode(touch: false);

    ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/src/main.dart'));
    ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/test/main.dart'));

    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: SizedBox(
              width: 900,
              height: 500,
              child: TabWorkspaceView(ws: ws, empty: const SizedBox()),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 40));
    }

    expect(find.text('main.dart'), findsAtLeastNWidgets(2));
    expect(find.text('src'), findsAtLeastNWidgets(1));
    expect(find.text('test'), findsAtLeastNWidgets(1));
    expect(find.byType(FileIcon), findsAtLeastNWidgets(2));

    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
    ws.dispose();
    input.dispose();
    app.dispose();
  });
}
