import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/feature.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _Files extends Feature {
  @override
  String get id => 'files';
  @override
  String get title => 'Files fixture';
  @override
  IconData get icon => Icons.folder;
  @override
  String get service => 'files';
  @override
  List<String> get ops => const [];
  @override
  SideBarView sideBar(BuildContext context, Workspace ws) => const SideBarView(
    title: 'Project files',
    body: Text('File tree stays here', key: ValueKey('files-sidebar-fixture')),
  );
}

class _Link extends FileTreeLink {
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
            'id': 'files',
            'enabled': true,
            'available': true,
            'ops': <String>[],
          },
          {
            'id': 'terminal',
            'enabled': true,
            'available': true,
            'ops': const ['session.list', 'session.create', 'terminal'],
          },
        ],
      };
    }
    if (op == 'session.list') {
      return {
        'sessions': [
          {'name': 'main'},
        ],
      };
    }
    throw OpError(codeNotFound, 'Synthetic operation refused');
  }
}

void main() {
  late WorkspaceApp app;
  late InputMode input;
  late Features features;
  final shell = GlobalKey();
  setUp(() {
    app = WorkspaceApp(wire: _Link());
    input = InputMode(touch: false);
    features = Features();
    features.all
      ..clear()
      ..addAll([_Files(), const TerminalFeature()]);
  });
  tearDown(() {
    features.dispose();
    input.dispose();
    app.dispose();
  });
  Future<Workspace> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Shell(key: shell, app: app, features: features),
        ),
      ),
    );
    await t.pumpAndSettle();
    return (shell.currentState as dynamic).debugWorkspace as Workspace;
  }

  Future<void> keys(
    WidgetTester t,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(key);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
  }

  testWidgets(
    'the terminal activity opens the bottom panel and never replaces the file tree',
    (t) async {
      final ws = await pump(t);
      final before = t.getRect(find.byKey(const ValueKey('main-sidebar')));
      await t.tap(find.byTooltip('终端'));
      await t.pumpAndSettle();
      expect(ws.terminalPanel.visible, isTrue);
      expect(
        find.byKey(const ValueKey('files-sidebar-fixture')),
        findsOneWidget,
      );
      expect(t.getRect(find.byKey(const ValueKey('main-sidebar'))), before);
      final panel = t.getRect(find.byKey(const ValueKey('workbench-terminal')));
      final list = t.getRect(find.byType(SessionList));
      expect(panel.contains(list.center), isTrue);
      expect(
        list.top,
        greaterThanOrEqualTo(
          t.getRect(find.byKey(const ValueKey('terminal-panel-header'))).bottom,
        ),
      );
      expect(
        find.text('终端会话'),
        findsNothing,
        reason: 'there is no second terminal sidebar',
      );
      await keys(t, LogicalKeyboardKey.backquote, shift: true);
      expect(find.byType(NewSessionDialog), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'panel shortcuts preserve the file selection and Ctrl+1 returns keyboard focus to it',
    (t) async {
      final ws = await pump(t);
      final document = TextEditingController(),
          terminal = TextEditingController();
      final documentFocus = FocusNode(), terminalFocus = FocusNode();
      ws.openTab(
        EditorTab(
          id: 'doc',
          title: 'document',
          icon: Icons.description,
          builder: (_) => Material(
            child: TextField(
              key: const ValueKey('shell-doc'),
              controller: document,
              focusNode: documentFocus,
            ),
          ),
        ),
      );
      ws.openTab(
        EditorTab(
          id: 'term:main',
          title: 'main',
          icon: Icons.terminal,
          builder: (_) => Material(
            child: TextField(
              key: const ValueKey('shell-term'),
              controller: terminal,
              focusNode: terminalFocus,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('shell-term')));
      await t.pump();
      await keys(t, LogicalKeyboardKey.keyJ);
      expect(ws.terminalPanel.visible, isFalse);
      expect(ws.editorActiveId, 'doc');
      expect(ws.tabs, hasLength(2));
      await keys(t, LogicalKeyboardKey.backquote);
      expect(ws.terminalPanel.visible, isTrue);
      expect(ws.focusedId, 'term:main');
      await keys(t, LogicalKeyboardKey.digit1);
      expect(ws.focusedId, 'doc');
      await t.tap(find.byKey(const ValueKey('shell-doc')));
      await t.pump();
      await t.enterText(
        find.byKey(const ValueKey('shell-doc')),
        'retained file input',
      );
      await keys(t, LogicalKeyboardKey.keyJ);
      await keys(t, LogicalKeyboardKey.keyJ);
      expect(document.text, 'retained file input');
      expect(ws.editorActiveId, 'doc');
      await keys(t, LogicalKeyboardKey.digit1);
      await keys(t, LogicalKeyboardKey.keyW);
      expect(ws.tabs.single.id, 'term:main');
      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      document.dispose();
      terminal.dispose();
      documentFocus.dispose();
      terminalFocus.dispose();
    },
  );
}
