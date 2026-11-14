import 'package:aurora/features/ai/ai_feature.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workbench_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

void main() {
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  final controllers = <String, TextEditingController>{};
  setUp(() {
    app = WorkspaceApp();
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
  });
  tearDown(() async {
    await ws.flushViews();
    ws.dispose();
    app.dispose();
    input.dispose();
    for (final controller in controllers.values) {
      controller.dispose();
    }
    controllers.clear();
  });
  void open(String id) {
    final controller = controllers[id] = TextEditingController();
    ws.openTab(
      EditorTab(
        id: id,
        title: id,
        icon: Icons.description,
        builder: (_) => Material(
          child: TextField(key: ValueKey('input-$id'), controller: controller),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: ListenableBuilder(
              listenable: ws,
              builder: (_, _) =>
                  WorkbenchView(ws: ws, empty: const Text('Empty editor')),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets(
    'editor, assistant and terminal are distinct regions with retained drafts and focus',
    (t) async {
      open('doc');
      open('term:main');
      open('ai:one');
      await pump(t);
      await t.enterText(
        find.byKey(const ValueKey('input-ai:one')),
        'unsent prompt',
      );
      final editor = t.getRect(find.byKey(const ValueKey('workbench-editor')));
      final assistant = t.getRect(
        find.byKey(const ValueKey('workbench-assistant')),
      );
      final terminal = t.getRect(
        find.byKey(const ValueKey('workbench-terminal')),
      );
      expect(assistant.left, greaterThan(editor.right));
      expect(editor.overlaps(terminal), isFalse);
      expect(assistant.overlaps(terminal), isFalse);
      expect(ws.visibleTabs.map((tab) => tab.id), ['doc']);
      expect(ws.tabLayout.owner('ai:one'), isNull);
      for (var i = 0; i < 4; i++) {
        ws.hideAssistantPanel();
        await t.pumpAndSettle();
        ws.showAssistantPanel();
        await t.pumpAndSettle();
        ws.toggleAssistantMaximized();
        await t.pumpAndSettle();
        ws.toggleAssistantMaximized();
        await t.pumpAndSettle();
      }
      expect(controllers['ai:one']!.text, 'unsent prompt');
      final chatState = t.state(find.byKey(const ValueKey('input-ai:one')));
      await t.tap(find.byTooltip('AI 对话历史'));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('input-ai:one')), findsNothing);
      expect(find.byKey(const ValueKey('input-doc')), findsOneWidget);
      await t.tap(find.byTooltip('返回对话'));
      await t.pumpAndSettle();
      expect(t.state(find.byKey(const ValueKey('input-ai:one'))), same(chatState));
      expect(controllers['ai:one']!.text, 'unsent prompt');
      ws.focusGroupAt(0);
      await t.pumpAndSettle();
      expect(ws.focusedId, 'doc');
      ws.showTerminalPanel();
      await t.pumpAndSettle();
      expect(ws.focusedId, 'term:main');
      ws.showAssistantPanel();
      await t.pumpAndSettle();
      expect(ws.focusedId, 'ai:one');
      await ws.closeTabs(ws.visibleTabs.map((tab) => tab.id));
      await t.pumpAndSettle();
      expect(ws.assistantTabs.single.id, 'ai:one');
      expect(ws.terminalTabs.single.id, 'term:main');
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'compact region changes do not change the editor group tree or destroy AI draft',
    (t) async {
      open('doc');
      open('ai:one');
      await pump(t);
      await t.enterText(
        find.byKey(const ValueKey('input-ai:one')),
        'keep this draft',
      );
      final root = ws.tabLayout.root;
      t.view.physicalSize = const Size(700, 800);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('input-doc')), findsNothing);
      ws.focusGroupAt(0);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('input-doc')), findsOneWidget);
      expect(find.byKey(const ValueKey('input-ai:one')), findsNothing);
      t.view.physicalSize = const Size(1440, 900);
      await t.pumpAndSettle();
      expect(controllers['ai:one']!.text, 'keep this draft');
      expect(ws.tabLayout.root, same(root));
      await t.pumpWidget(const SizedBox());
    },
  );
  test('new AI drafts have independent identities and never discard existing tasks', () async {
    openNewAiSession(ws);
    final first = ws.assistantTabs.single;
    openNewAiSession(ws);
    expect(ws.assistantTabs, hasLength(2));
    expect(ws.assistantTabs.first, same(first));
    expect(ws.assistantTabs.last.id, isNot(first.id));
    expect(ws.visibleTabs, isEmpty);
    first.taskKey = 'saved-session';
    ws.openTab(
      EditorTab(
        id: 'ai:saved-session',
        taskKey: 'saved-session',
        title: 'same saved chat',
        icon: Icons.auto_awesome,
        builder: (_) => const SizedBox(),
      ),
    );
    expect(ws.assistantTabs, hasLength(2));
    expect(
      ws.assistantPanel.active,
      first.id,
      reason: 'history reopens the existing draft host instead of cloning a running chat',
    );
    ws.setAssistantWidth(500);
    await ws.flushViews();
    final restored = Workspace(app, 'server');
    expect(restored.assistantPanel.width, 500);
    expect(restored.assistantPanel.visible, isFalse);
    expect(restored.assistantTabs, isEmpty);
    await restored.flushViews();
    restored.dispose();
  });

  testWidgets('an externally opened AI tab leaves history and keeps the old draft', (t) async {
    open('doc'); open('ai:one');
    await pump(t);
    await t.enterText(find.byKey(const ValueKey('input-ai:one')), 'keep first draft');
    await t.tap(find.byTooltip('AI 对话历史')); await t.pumpAndSettle();
    open('ai:two'); await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('input-ai:two')), findsOneWidget);
    ws.activate('ai:one'); await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('input-ai:one')), findsOneWidget);
    expect(controllers['ai:one']!.text, 'keep first draft');
    await t.pumpWidget(const SizedBox());
  });

  test('explicit terminal navigation exits a maximized assistant instead of focusing a hidden host', () {
    open('doc');
    open('term:one');
    open('ai:one');
    void maximizeAssistant() {
      ws.showAssistantPanel();
      ws.toggleAssistantMaximized();
      expect(ws.assistantPanel.maximized, isTrue);
    }

    maximizeAssistant();
    open('term:two');
    expect(ws.focusedId, 'term:two');
    expect(ws.assistantPanel.maximized, isFalse);
    maximizeAssistant();
    ws.activate('term:one');
    expect(ws.focusedId, 'term:one');
    expect(ws.assistantPanel.maximized, isFalse);
    maximizeAssistant();
    ws.focusTerminalPanel();
    expect(ws.assistantPanel.maximized, isFalse);
    maximizeAssistant();
    ws.toggleTerminalMaximized();
    expect(ws.assistantPanel.maximized, isFalse);
    expect(ws.terminalPanel.maximized, isTrue);
  });
}
