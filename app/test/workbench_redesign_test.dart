import 'dart:async';

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/git/git_feature.dart';
import 'package:aurora/features/search/search_feature.dart';
import 'package:aurora/features/systemd/systemd_feature.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/ui/aurora_ui.dart' show Toast, UiNavigationItem;
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/workspace_fixture.dart';

class _Link extends FileTreeLink {
  final Features features;
  final requests = <(String, Object?)>[];
  final held = <String, Completer<Object?>>{};
  bool staged = true;
  bool operation = false;
  _Link(this.features);

  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    requests.add((op, args));
    final gate = held.remove(op);
    if (gate != null) return gate.future;
    if (op == 'agent.services') {
      return {'services': [
        for (final id in features.all.map((f) => f.service).toSet())
          {'id': id, 'enabled': true, 'available': true, 'ops': [
            for (final f in features.all.where((f) => f.service == id)) ...f.ops,
          ]},
      ]};
    }
    if (op == 'git.repos') return {'repos': [
      {'repo': '/alpha', 'name': 'Alpha repo'}, {'repo': '/beta', 'name': 'Beta repo'},
    ]};
    if (op == 'git.status') return {'branch': 'main', if (operation) ...{
      'operation': 'rebase', 'stashes': 100, 'upstream': 'origin/main', 'ahead': 200, 'behind': 100,
    }, 'files': [
      {'path': 'main.dart', 'x': staged ? 'M' : '.', 'y': staged ? '.' : 'M'},
    ]};
    if (op == 'git.commit' || op == 'git.stage') return {};
    if (op == 'fs.search') return {'files': [], 'total': 0};
    if (op == 'fs.read' && (args as Map)['path'] == '/project/wrap.md') {
      return {'content': List.filled(200, List.filled(30, 'longword').join(' ')).join('\n'), 'etag': 'wrap-fixture'};
    }
    if (op == 'svc.list') return {'units': [
      {'name': 'web.service', 'description': 'Website', 'active': 'active', 'sub': 'running', 'load': 'loaded'},
    ]};
    if (op == 'agent.actions') return {'actions': {'web.service': ['start', 'stop', 'restart']}};
    if (op == 'svc.action') return {'active': 'active'};
    return super.call(op, args, timeout);
  }
}

class _App extends WorkspaceApp {
  final Map<String, Link?> links;
  _App(this.links) : super(profile: Profile(selected: 'server', servers: [
    ServerEntry(id: 'server', name: '本机工作区', kind: 'local'),
    ServerEntry(id: 'second', name: '开发服务器'),
  ]));
  @override Link? link(String id) => links[id];
  @override ConnStatus status(String id) => ConnStatus(links[id] == null ? ConnState.idle : ConnState.connected);
  void relink(String id, Link? next) { links[id] = next; notifyListeners(); }
}

void main() {
  Future<void> frames(WidgetTester t, [int count = 5]) async {
    for (var i = 0; i < count; i++) { await t.pump(const Duration(milliseconds: 100)); }
    expect(t.takeException(), isNull);
  }
  Future<void> host(WidgetTester t, Widget child, InputMode input, {Brightness theme = Brightness.dark, double textScale = 1}) async {
    await t.pumpWidget(MaterialApp(theme: buildTheme(theme), scaffoldMessengerKey: Toast.key,
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
      home: InputMode.scope(mode: input, child: Scaffold(body: child))));
    await frames(t);
  }
  Finder message() => find.descendant(of: find.byType(GitPanel), matching: find.byType(TextField));
  final searchEntry = find.byKey(const ValueKey('workbench-quick-open'));
  final query = find.byKey(const ValueKey('workbench-search-query'));
  Future<void> contents(WidgetTester t, [String? text]) async {
    await t.tap(searchEntry); await frames(t);
    await t.tap(find.text('文件内容')); await frames(t);
    if (text != null) await t.enterText(query, text);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await frames(t);
  }

  testWidgets('real sidebars retain per-server inputs, navigation and identity across reconnect and theme', (t) async {
    t.view.physicalSize = const Size(1440, 900); t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
    final features = Features(), input = InputMode(touch: false);
    final first = _Link(features), second = _Link(features);
    final app = _App({'server': first, 'second': second});
    final shell = Shell(app: app, features: features);
    await host(t, shell, input);
    expect(find.byTooltip('开发与问题'), findsOneWidget, reason: 'local development must be discoverable');
    await contents(t, 'retained query');
    final search = t.state(find.byType(SearchPanel));
    expect(find.descendant(of: find.byType(SearchPanel), matching: find.byType(TextField)), findsNothing);
    await t.tap(find.byTooltip('源代码管理')); await frames(t);
    final git = t.state(find.byType(GitPanel));
    await t.enterText(message(), 'server one draft');
    await app.select('second'); await frames(t);
    await t.tap(find.byTooltip('源代码管理')); await frames(t);
    await t.enterText(message(), 'server two draft');
    await app.select('server'); await frames(t);
    expect(t.state(find.byType(GitPanel)), same(git));
    expect(t.widget<TextField>(message()).controller!.text, 'server one draft');
    app.relink('server', null); await frames(t);
    app.relink('server', _Link(features)); await frames(t);
    expect(t.state(find.byType(GitPanel)), same(git));
    expect(t.widget<TextField>(message()).controller!.text, 'server one draft');
    await host(t, shell, input, theme: Brightness.light);
    expect(t.state(find.byType(GitPanel)), same(git));
    await contents(t);
    expect(t.state(find.byType(SearchPanel)), same(search));
    expect(find.text('内容搜索：retained query'), findsOneWidget);
    await app.select('second'); await frames(t);
    expect(t.widget<TextField>(message()).controller!.text, 'server two draft');
    await t.pumpWidget(const SizedBox()); await t.pump();
    app.dispose(); features.dispose(); input.dispose();
  });

  testWidgets('desktop search has one query and retains it across header modes', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final features = Features(), input = InputMode(touch: false);
    final link = _Link(features);
    final app = _App({'server': link});
    await host(t, Shell(app: app, features: features), input);
    expect(find.byTooltip('搜索'), findsNothing, reason: 'desktop has one search entry');
    await t.tap(searchEntry);
    await frames(t);
    final state = t.state(query);
    await t.enterText(query, 'file-name');
    await t.tap(find.text('命令'));
    await frames(t);
    expect(t.state(query), same(state), reason: 'switching scopes must reuse the physical input');
    await t.enterText(query, '关闭');
    await t.tap(find.text('文件名')); await frames(t);
    expect(t.widget<TextField>(query).controller!.text, 'file-name');
    await t.tap(find.text('文件内容')); await frames(t);
    await t.enterText(query, 'needle');
    await t.pump();
    expect(t.widget<TextField>(query).controller!.text, 'needle');
    expect(find.text('在项目中搜索「needle」'), findsOneWidget);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await frames(t);
    expect(query, findsNothing);
    expect(find.text('内容搜索：needle'), findsOneWidget);
    expect(find.byType(SearchPanel), findsOneWidget);
    expect(link.requests.where((r) => r.$1 == 'fs.search' && (r.$2 as Map)['query'] == 'needle'), isNotEmpty,
      reason: 'The entire query must reach the agent: ${link.requests}');
    expect(find.descendant(of: find.byType(SearchPanel), matching: find.byType(TextField)), findsNothing);
    await t.tap(find.byTooltip('文件')); await frames(t);
    expect(query, findsNothing);
    expect(find.byKey(const ValueKey('workbench-quick-open')), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF, physicalKey: PhysicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
    await frames(t);
    expect(t.widget<TextField>(query).controller!.text, 'needle');
    await t.sendKeyEvent(LogicalKeyboardKey.escape, physicalKey: PhysicalKeyboardKey.escape);
    await frames(t);
    await t.pumpWidget(const SizedBox());
    app.dispose(); features.dispose(); input.dispose();
  });

  testWidgets('sidebars touch without a document and keep the assistant draft when editor returns', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final features = Features(), input = InputMode(touch: false);
    final app = _App({'server': _Link(features)});
    final shellKey = GlobalKey();
    await host(t, Shell(key: shellKey, app: app, features: features), input);
    final ws = (shellKey.currentState as dynamic).debugWorkspace as Workspace;
    const draftKey = ValueKey('assistant-fixture-draft');
    ws.openTab(EditorTab(id: 'ai:fixture', title: '助手草稿', icon: Icons.chat_outlined,
      builder: (_) => const TextField(key: draftKey)));
    await frames(t);
    final assistant = find.byKey(const ValueKey('workbench-assistant'));
    final editor = find.byKey(const ValueKey('workbench-editor'));
    final side = find.byKey(const ValueKey('main-sidebar'));
    expect(editor, findsNothing);
    expect(t.getTopLeft(assistant).dx - t.getTopRight(side).dx, 5);
    await t.enterText(find.byKey(draftKey), 'unsent draft');
    ws.openTab(EditorTab(id: 'test-document', title: '文档', icon: Icons.description_outlined,
      builder: (_) => const Text('文档正文')));
    await frames(t);
    expect(editor, findsOneWidget);
    expect(t.getTopLeft(assistant).dx, greaterThan(t.getTopLeft(editor).dx + 240));
    expect(find.text('unsent draft'), findsOneWidget);
    await ws.closeTab('test-document');
    await frames(t);
    expect(editor, findsNothing);
    expect(t.getTopLeft(assistant).dx - t.getTopRight(side).dx, 5);
    expect(find.text('unsent draft'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    app.dispose(); features.dispose(); input.dispose();
  });

  testWidgets('dragging the right dock reflows the central file without replacing its buffer', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final features = Features(), input = InputMode(touch: false);
    final app = _App({'server': _Link(features)});
    final shellKey = GlobalKey();
    await host(t, Shell(key: shellKey, app: app, features: features), input);
    final ws = (shellKey.currentState as dynamic).debugWorkspace as Workspace;
    ws.openTab(EditorTab(id: 'ai:fixture', title: '助手', icon: Icons.chat_outlined, builder: (_) => const SizedBox()));
    ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/wrap.md'));
    await frames(t);
    final editor = find.byType(CodeEditor);
    final controller = t.widget<CodeEditor>(editor).controller;
    final scroll = find.descendant(of: editor, matching: find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down));
    final width = t.getSize(editor).width;
    final height = t.state<ScrollableState>(scroll).position.maxScrollExtent;
    await t.drag(find.byKey(const ValueKey('assistant-panel-resize')), const Offset(-170, 0));
    await frames(t);
    expect(t.getSize(editor).width, lessThan(width - 100));
    expect(t.state<ScrollableState>(scroll).position.maxScrollExtent, greaterThan(height));
    expect(t.widget<CodeEditor>(editor).controller, same(controller));
    expect(t.widget<CodeEditor>(editor).wordWrap, isTrue);
    await t.pumpWidget(const SizedBox());
    app.dispose(); features.dispose(); input.dispose();
  });

  testWidgets('Git drafts follow repositories and a completed commit keeps newer typing', (t) async {
    final features = Features(), input = InputMode(touch: false);
    final link = _Link(features), app = _App({});
    app.links['server'] = link;
    final ws = Workspace(app, 'server');
    await host(t, GitPanel(ws: ws), input);
    await t.enterText(message(), 'alpha draft');
    await t.tap(find.byTooltip('切换仓库')); await frames(t);
    await t.tap(find.text('Beta repo  /beta')); await frames(t);
    expect(t.widget<TextField>(message()).controller!.text, '');
    await t.enterText(message(), 'beta draft');
    await t.tap(find.byTooltip('切换仓库')); await frames(t);
    await t.tap(find.text('Alpha repo  /alpha')); await frames(t);
    expect(t.widget<TextField>(message()).controller!.text, 'alpha draft');
    final commit = Completer<Object?>();
    link.held['git.commit'] = commit;
    await t.tap(find.text('提交 1 个文件')); await t.pump();
    await t.enterText(message(), 'next commit draft');
    commit.complete({}); await frames(t);
    expect(t.widget<TextField>(message()).controller!.text, 'next commit draft');
    expect(link.requests.where((r) => r.$1 == 'git.commit'), hasLength(1));
    await t.pumpWidget(const SizedBox()); await t.pump();
    ws.dispose(); app.dispose(); features.dispose(); input.dispose();
  });

  testWidgets('Git confirmation and service confirmation cannot execute on a replacement link', (t) async {
    final features = Features(), input = InputMode(touch: false);
    final link = _Link(features)..staged = false, next = _Link(features);
    final app = _App({'server': link});
    final ws = Workspace(app, 'server');
    await host(t, GitPanel(ws: ws), input);
    await t.enterText(message(), 'unsubmitted');
    await t.tap(find.text('提交全部更改')); await frames(t);
    app.relink('server', next); await frames(t);
    await t.tap(find.text('全部提交')); await frames(t);
    expect([...link.requests, ...next.requests].where((r) => r.$1 == 'git.commit'), isEmpty);
    expect(t.widget<TextField>(message()).controller!.text, 'unsubmitted');
    await host(t, UnitList(ws: ws), input);
    await t.tap(find.byTooltip('重启')); await frames(t);
    app.relink('server', link); await frames(t);
    await t.tap(find.text('重启')); await frames(t);
    expect([...link.requests, ...next.requests].where((r) => r.$1 == 'svc.action'), isEmpty);
    await t.pumpWidget(const SizedBox()); await t.pump();
    ws.dispose(); app.dispose(); features.dispose(); input.dispose();
  });

  for (final theme in Brightness.values) {
    testWidgets('search and services stay operable in short narrow ${theme.name} panels at 150% text', (t) async {
      t.view.physicalSize = const Size(260, 320); t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
      final features = Features(), input = InputMode(touch: true);
      final app = _App({'server': _Link(features)..operation = true});
      final ws = Workspace(app, 'server');
      for (final child in [SearchPanel(ws: ws), UnitList(ws: ws), GitPanel(ws: ws)]) {
        await host(t, child, input, theme: theme, textScale: 1.5);
        expect(find.byType(ErrorWidget), findsNothing);
        await t.drag(find.byType(Scrollable).first, const Offset(0, -200));
        await frames(t);
      }
      await t.pumpWidget(const SizedBox()); await t.pump();
      ws.dispose(); app.dispose(); features.dispose(); input.dispose();
    });
  }

  testWidgets('labelled navigation is keyboard accessible and exposes selection', (t) async {
    final input = InputMode(touch: false);
    var picked = 0;
    await host(t, Align(alignment: Alignment.topLeft, child: SizedBox(width: 68,
      child: UiNavigationItem(icon: Icons.code, label: '开发', tooltip: '开发与问题',
        selected: true, onTap: () => picked++))), input);
    await t.sendKeyEvent(LogicalKeyboardKey.tab); await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter); await t.pump();
    expect(picked, 1);
    expect(find.text('开发'), findsOneWidget);
    await t.pumpWidget(const SizedBox()); input.dispose();
  });
}
