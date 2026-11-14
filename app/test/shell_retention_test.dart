import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/feature.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'side bar and editor switches do not rebuild unrelated retained bodies',
    (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final app = _App();
      final builds = <String, int>{};
      final terminal = _Feature('terminal', 'Terminal fixture', builds);
      final files = _Feature('files', 'Files fixture', builds);
      final features = Features();
      features.all
        ..clear()
        ..addAll([
          terminal,
          files,
          _Feature('monitor', 'Monitor fixture', builds),
        ]);
      final input = InputMode(touch: false);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: InputMode.scope(
            mode: input,
            child: Shell(app: app, features: features),
          ),
        ),
      );
      await t.pumpAndSettle();
      final ws = files.workspace!;
      ws.openTab(
        EditorTab(
          id: 'one',
          title: 'One',
          icon: Icons.description,
          builder: (_) => _Probe('one', builds),
        ),
      );
      ws.openTab(
        EditorTab(
          id: 'two',
          title: 'Two',
          icon: Icons.description,
          builder: (_) => _Probe('two', builds),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Terminal fixture'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Files fixture'));
      await t.pumpAndSettle();
      final before = Map<String, int>.from(builds);
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byTooltip('显示或隐藏侧栏（Ctrl+B）'));
        await t.pumpAndSettle();
      }
      for (var i = 0; i < 4; i++) {
        ws.activate(i.isEven ? 'one' : 'two');
        await t.pumpAndSettle();
        await t.tap(
          find.byTooltip(i.isEven ? 'Terminal fixture' : 'Files fixture'),
        );
        await t.pumpAndSettle();
      }
      expect(
        builds,
        before,
        reason: 'state is preserved without rebuilding hidden pages on every switch',
      );
      expect(
        app.wholeProfileReads,
        0,
        reason: 'switching must not copy all subscription nodes',
      );
      app.changed();
      await t.pumpAndSettle();
      expect(
        builds['one'],
        greaterThan(before['one']!),
        reason:
            'real profile/connection changes still invalidate configurations',
      );
      await t.pumpWidget(const SizedBox.shrink());
      features.dispose();
      input.dispose();
      app.dispose();
    },
  );
  testWidgets('sidebar resizes, restores preferred width and long titles fit narrow windows', (t) async {
    t.view.physicalSize = const Size(1400, 900); t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
    final app = _App();
    app._entry.name = '非常长的服务器名称 ' * 8;
    final builds = <String, int>{}, feature = _Feature('terminal', 'Terminal fixture', {});
    final features = Features(); features.all..clear()..add(feature);
    final input = InputMode(touch: false);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: InputMode.scope(mode: input, child: Shell(app: app, features: features))));
    await t.pumpAndSettle();
    final ws = feature.workspace!;
    ws.openTab(EditorTab(id: 'one', title: 'One', icon: Icons.description, builder: (_) => _Probe('one', builds)));
    await t.pumpAndSettle();
    final original = t.getSize(find.byKey(const ValueKey('main-sidebar'))).width;
    await t.drag(find.byKey(const ValueKey('sidebar-resize')), const Offset(90, 0)); await t.pumpAndSettle();
    expect(t.getSize(find.byKey(const ValueKey('main-sidebar'))).width, greaterThan(original));
    final preferred = ws.tabLayout.sideWidth;
    t.view.physicalSize = const Size(620, 800); await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.tap(find.byTooltip('显示或隐藏侧栏（Ctrl+B）')); await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar-resize')), findsOneWidget);
    expect(t.getRect(find.byKey(const ValueKey('main-sidebar'))).overlaps(t.getRect(find.byKey(const ValueKey('editor-slot')))), isFalse);
    await t.drag(find.byKey(const ValueKey('sidebar-resize')), const Offset(-30, 0)); await t.pumpAndSettle();
    expect(ws.tabLayout.sideWidth, lessThan(preferred));
    t.view.physicalSize = const Size(390, 800); await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    t.view.physicalSize = const Size(1400, 900); await t.pumpAndSettle();
    expect(t.getSize(find.byKey(const ValueKey('main-sidebar'))).width, ws.tabLayout.sideWidth);
    expect(builds['one'], 1, reason: 'resizing and responsive navigation must not reopen a document');
    await ws.flushViews(); await t.pumpWidget(const SizedBox());
    features.dispose(); input.dispose(); app.dispose();
  });

  testWidgets('group shortcuts and Ctrl+W target the focused group', (t) async {
    t.view.physicalSize = const Size(1400, 900); t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
    final app = _App(), feature = _Feature('terminal', 'Terminal fixture', {});
    final features = Features(); features.all..clear()..add(feature);
    final input = InputMode(touch: false);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: InputMode.scope(mode: input, child: Shell(app: app, features: features))));
    await t.pumpAndSettle();
    final ws = feature.workspace!;
    for (final id in ['a', 'b']) { ws.openTab(EditorTab(id: id, title: id, icon: Icons.terminal, builder: (_) => Text(id))); }
    ws.splitGroup(SplitAxis.horizontal, tabId: 'b'); await t.pumpAndSettle();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await t.sendKeyEvent(LogicalKeyboardKey.digit1); await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(ws.focusedId, 'a');
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft); await t.sendKeyEvent(LogicalKeyboardKey.keyW); await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(ws.tabs.single.id, 'b');
    expect(ws.focusedId, 'b');
    await ws.flushViews(); await t.pumpWidget(const SizedBox());
    features.dispose(); input.dispose(); app.dispose();
  });
}

class _App extends AppState {
  final _entry = ServerEntry(id: 'fixture', name: 'fixture');
  final _link = _Link();
  int wholeProfileReads = 0;
  @override EditorSettings get editorSettings => EditorSettings();
  @override AiSettings get aiSettings => AiSettings();
  @override
  bool get ready => true;
  @override
  Profile get profile {
    wholeProfileReads++;
    return Profile(servers: [_entry], selected: _entry.id);
  }

  @override
  ServerEntry? server(String id) => id == _entry.id ? _entry : null;
  @override
  String? get selected => _entry.id;
  @override
  List<ServerEntry> get servers => [_entry];
  @override
  Link? link(String id) => _link;
  @override
  ConnStatus status(String id) =>
      ConnStatus(ConnState.connected, addr: 'fixture:17710');
  @override Future<void> saveWorkspaceViews(String id, Map<String, WorkspaceView> views) async {
    if (views[''] != null) _entry.browserView = WorkspaceView.fromJson(views['']!.toJson());
  }
  void changed() => notifyListeners();
}

class _Link implements Link {
  @override
  AgentInfo get server =>
      AgentInfo({'version': '3.3.0', 'arch': 'amd64', 'caps': <String>[]});
  @override
  bool get isClosed => false;
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async => {
    'services': [
      for (final id in ['terminal', 'files', 'monitor'])
        {'id': id, 'enabled': true, 'available': true, 'ops': <String>[]},
    ],
  };
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Feature extends Feature {
  @override
  final String id;
  @override
  final String title;
  final Map<String, int> builds;
  Workspace? workspace;
  _Feature(this.id, this.title, this.builds);
  @override
  IconData get icon => Icons.folder;
  @override
  String get service => id;
  @override
  List<String> get ops => const [];
  @override
  SideBarView sideBar(BuildContext context, Workspace ws) {
    workspace = ws;
    return SideBarView(title: title, body: _Probe(id, builds));
  }
}

class _Probe extends StatelessWidget {
  final String id;
  final Map<String, int> builds;
  const _Probe(this.id, this.builds);
  @override
  Widget build(BuildContext context) {
    builds.update(id, (n) => n + 1, ifAbsent: () => 1);
    return Text('body $id');
  }
}
