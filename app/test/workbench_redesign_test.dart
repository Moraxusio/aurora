import 'dart:async';

import 'package:aurora/features/git/git_feature.dart';
import 'package:aurora/features/search/search_feature.dart';
import 'package:aurora/features/systemd/systemd_feature.dart';
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

  testWidgets('real sidebars retain per-server inputs, navigation and identity across reconnect and theme', (t) async {
    t.view.physicalSize = const Size(1440, 900); t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
    final features = Features(), input = InputMode(touch: false);
    final first = _Link(features), second = _Link(features);
    final app = _App({'server': first, 'second': second});
    final shell = Shell(app: app, features: features);
    await host(t, shell, input);
    expect(find.byTooltip('开发与问题'), findsOneWidget, reason: 'local development must be discoverable');
    await t.tap(find.byTooltip('搜索')); await frames(t);
    final search = t.state(find.byType(SearchPanel));
    await t.enterText(find.descendant(of: find.byType(SearchPanel), matching: find.byType(TextField)).first, 'retained query');
    await frames(t);
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
    await t.tap(find.byTooltip('搜索')); await frames(t);
    expect(t.state(find.byType(SearchPanel)), same(search));
    expect(find.text('retained query'), findsOneWidget);
    await app.select('second'); await frames(t);
    expect(t.widget<TextField>(message()).controller!.text, 'server two draft');
    await t.pumpWidget(const SizedBox()); await t.pump();
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
