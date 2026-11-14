import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/files/file_tree_row.dart';
import 'package:aurora/features/files/files_feature.dart';
import 'package:aurora/features/files/transfers.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

void main() {
  late WorkspaceApp app;
  late Workspace ws;
  late FileTreeLink link;
  late Transfers transfers;
  late InputMode input;
  setUp(() {
    link = FileTreeLink();
    app = WorkspaceApp(wire: link);
    app.data.servers.single.selectedWorkspace = 'a';
    ws = Workspace(app, 'server');
    transfers = Transfers();
    input = InputMode(touch: false);
  });
  tearDown(() async { ws.dispose(); transfers.dispose(); input.dispose(); app.dispose(); });
  Future<void> treePumps(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }
  Future<void> mount(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: InputMode.scope(mode: input,
      child: Scaffold(body: SizedBox(width: 310, height: 650, child: FileTree(ws: ws, transfers: transfers))))));
    await treePumps(t);
  }
  Finder row(String path) => find.byWidgetPredicate((w) => w is FileTreeRow && w.path == path);

  testWidgets('reveal expands deep ancestors and collapse preserves the open document', (t) async {
    final tab = EditorTab(id: 'fixture-document', title: 'deep.txt', icon: Icons.description, file: ref('/project/src/nested/deep.txt'), builder: (_) => const Text('retained buffer'));
    ws.openTab(tab);
    await mount(t);
    expect(row('/project/src/nested/deep.txt'), findsNothing);
    await t.tap(find.byTooltip('定位当前文件'));
    await treePumps(t);
    final active = t.widget<FileTreeRow>(row('/project/src/nested/deep.txt'));
    expect(active.active, isTrue);
    expect(active.selected, isTrue);
    await t.tap(find.byTooltip('文件选项'));
    await t.pumpAndSettle();
    await t.tap(find.text('折叠所有文件夹'));
    await treePumps(t);
    expect(row('/project/src/nested/deep.txt'), findsNothing);
    expect(ws.active, same(tab));
    expect(await t.runAsync(() => ws.flushViews()), isTrue);
    await t.pumpWidget(const SizedBox());
  });

  for (final width in [220.0, 310.0, 520.0]) {
    testWidgets('deep long names fit $width px and preserve their extension', (t) async {
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: InputMode.scope(mode: input,
        child: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: FileTreeRow(
          name: 'very-long-component-file-name-with-many-words.dart', path: '/fixture/long.dart', depth: 24,
          folder: false, expanded: false, loading: false, selected: false, root: false, link: false,
          detail: '12.5 MB', modified: '11-14 12:30', onTap: () {}, menu: () => const [])))))));
      expect(t.takeException(), isNull);
      expect(find.text('.dart'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('file tree ${brightness.name} visual', (t) async {
      final out = Platform.environment['AURORA_FILES_SHOTS'];
      if (out != null) {
        for (final (family, file) in [
          ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
          (Ide.ui, r'C:\Windows\Fonts\SegUIVar.ttf'),
          ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
          ('MaterialIcons', r'C:\dev\VPS\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf'),
        ]) {
          await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(file).readAsBytesSync())))).load();
        }
      }
      final key = GlobalKey();
      await t.pumpWidget(MaterialApp(theme: buildTheme(brightness), home: InputMode.scope(mode: input,
        child: Scaffold(body: RepaintBoundary(key: key, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final width in [260.0, 520.0]) SizedBox(width: width, child: Builder(builder: (context) => ColoredBox(color: Ide.of(context).sideBar, child: Column(children: [
            const SizedBox(height: 12),
            Text(width < 300 ? '紧凑侧栏' : '宽侧栏 · 文件大小与修改时间'),
            const SizedBox(height: 12),
            for (final (name, depth, folder, active) in [
              ('Aurora 工作区', 0, true, false), ('app', 1, true, false), ('lib', 2, true, false),
              ('features', 3, true, false), ('files', 4, true, false),
              ('file_tree_row.dart', 5, false, true), ('very-long-file-management-component-name.dart', 5, false, false),
              ('深层目录里的配置文件.json', 24, false, false), ('README.md', 1, false, false),
            ]) FileTreeRow(name: name, path: '/fixture/$name', depth: depth, folder: folder, expanded: folder, loading: false,
              selected: active, active: active, root: depth == 0, link: false, detail: folder ? null : '12.5 KB',
              modified: folder ? null : '11-14 12:30', onTap: () {}, menu: () => const []),
          ])))),
        ]))))));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      if (out != null) {
        final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key));
        await t.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(out).createSync(recursive: true);
          await File('$out/files-${brightness.name}.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('restores descendants and refresh walks each visible folder once', (t) async {
    ws.rememberExpanded([ref('/project'), ref('/project/src'), ref('/project/src/nested')]);
    await mount(t);
    expect(row('/project/src/nested/deep.txt'), findsOneWidget);
    link.calls.clear();
    ws.filesRevision.value++;
    await treePumps(t);
    expect(link.calls, ['fs.list:/project', 'fs.list:/project/src', 'fs.list:/project/src/nested']);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('all collapsed remains collapsed after remount without disk debounce', (t) async {
    await mount(t);
    expect(row('/project/README.md'), findsOneWidget);
    await t.tap(row('/project'));
    await t.pump();
    expect(ws.viewForCurrent().treeSet, isTrue);
    await t.pumpWidget(const SizedBox());
    link.calls.clear();
    await mount(t);
    expect(row('/project/README.md'), findsNothing);
    expect(link.calls.where((c) => c.startsWith('fs.list:')), isEmpty);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('overlapping folders have unique row keys and share file buffers', (t) async {
    // Profile writes are real asynchronous work: run them outside fake time.
    await t.runAsync(() => ws.addFolder(ref('/project/src')));
    ws.rememberExpanded([ref('/project'), ref('/project/src')]);
    await mount(t);
    expect(row('/project/src'), findsNWidgets(2));
    expect(row('/project/src/main.dart'), findsNWidgets(2));
    await t.tap(row('/project/src/main.dart').first);
    await t.pump();
    await t.tap(row('/project/src/main.dart').last);
    await t.pump();
    expect(ws.tabs, hasLength(1));
    expect(t.takeException(), isNull);
    // Opening a file queues a debounced view save; flush it so no timer outlives the test.
    expect(await t.runAsync(() => ws.flushViews()), isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('project pages cache trees and retain separate expansion state', (t) async {
    await mount(t);
    await t.tap(row('/project/src'));
    await treePumps(t);
    await t.runAsync(() => ws.selectProject('b'));
    await treePumps(t);
    expect(row('/other/notes.txt'), findsOneWidget);
    link.calls.clear();
    await t.runAsync(() => ws.selectProject('a'));
    await treePumps(t);
    expect(row('/project/src/main.dart'), findsOneWidget);
    expect(link.calls, isEmpty, reason: 'switching back must not refetch a cached tree');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('removed folder response cannot overwrite the current roots', (t) async {
    final delayed = Completer<Object?>();
    link.delayed['fs.list:/project'] = delayed;
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: InputMode.scope(mode: input,
      child: Scaffold(body: SizedBox(width: 310, child: FileTree(ws: ws, transfers: transfers))))));
    await t.pump();
    await t.pump();
    await t.runAsync(() => ws.removeFolder(ref('/project')));
    await treePumps(t);
    delayed.complete({'entries': [FileTreeLink.file('obsolete.txt')]});
    await treePumps(t);
    expect(find.text('obsolete.txt'), findsNothing);
    expect(find.text('工作区里还没有文件夹'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('missing or denied folders show recoverable inline errors', (t) async {
    link.denied.add('/project');
    await mount(t);
    expect(find.text('fixture folder not found'), findsOneWidget);
    expect(row('/project'), findsOneWidget);
    link.denied.clear();
    ws.filesRevision.value++;
    await treePumps(t);
    expect(row('/project/README.md'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('large directories build only viewport rows', (t) async {
    link.directories['/project'] = [for (var i = 0; i < 5000; i++) FileTreeLink.file('file-${i.toString().padLeft(5, '0')}.txt')];
    await mount(t);
    expect(find.byType(FileTreeRow).evaluate().length, lessThan(60));
    expect(find.text('file-04999.txt'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
