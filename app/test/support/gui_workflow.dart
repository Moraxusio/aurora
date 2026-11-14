import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/files/file_tree_row.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/tab_drag.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/main.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart';

import '../gui_routing_test.dart' show guiKeys, guiCommand;
import '../workbench_visual_test.dart' show VisualWorkbenchLink;
import 'workspace_fixture.dart';

/// Production application/Navigator/window chrome, with in-memory services.
/// Used unchanged by widget regression and the real Windows engine run.
Future<Map<String, Object>> exerciseGui(WidgetTester t, {GlobalKey? frame, Future<void> Function()? capture}) async {
  final features = Features();
  final link = VisualWorkbenchLink(features);
  final app = WorkspaceApp(wire: link);
  app.data.ai = AiSettings(providers: [AiProvider(id: 'fixture', name: 'Fixture', protocol: 'openai-chat',
    baseUrl: 'https://example.invalid/v1', apiKey: 'fixture-only', model: 'fixture-model')], selectedProviderId: 'fixture');
  final steps = <String>[];
  Future<void> frames([int count = 8]) async { for (var i = 0; i < count; i++) { await t.pump(const Duration(milliseconds: 60)); } }
  Future<void> click(Finder target) async {
    expect(target, findsOneWidget);
    expect(target.hitTestable(), findsOneWidget, reason: 'painted controls must be reachable by real pointer hits');
    await t.tapAt(t.getCenter(target), kind: PointerDeviceKind.mouse); await frames();
  }
  Finder row(String name) => find.byWidgetPredicate((w) => w is FileTreeRow && w.name == name);
  await t.pumpWidget(RepaintBoundary(key: frame, child: AuroraApp(app: app)));
  await frames(8);
  final ws = (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;
  try {
    await click(find.byKey(const ValueKey('project-switcher')));
    await click(find.text('Alpha').last);
    await click(row('src'));
    await click(row('main.dart'));
    await click(row('workbench.dart'));
    await click(find.byKey(const ValueKey('tab-file:home:/project/src/main.dart')));
    final doc = t.state<FileEditorState>(find.byType(FileEditor));
    final editor = t.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    final savedText = doc.text;
    doc.text = 'const draft = "GUI state survives zoom";\n';
    await frames();
    steps.add('project switch, tree expansion, pointer-open files and retained dirty buffer');

    for (final percent in [85, 80, 100, 125, 150, 85]) {
      debugPrint('GUI_STAGE zoom=$percent');
      await click(find.byTooltip('设置（Ctrl+,）'));
      final value = find.byKey(const ValueKey('setting-input-uiScale'));
      await t.ensureVisible(value); await frames();
      await t.enterText(value, '$percent');
      await t.testTextInput.receiveAction(TextInputAction.done); await frames();
      expect(app.appearance.value.uiScale, percent / 100);

      await click(find.byTooltip('AI 助手'));
      final prompt = find.byKey(const ValueKey('ai-prompt-input'));
      await click(prompt);
      await t.enterText(prompt, 'draft at $percent%'); await frames();
      final chat = t.state(prompt);
      await click(find.byKey(const ValueKey('ai-attach-menu')));
      expect(find.text('选择本机图片 / 文件…'), findsOneWidget);
      // Dismiss via the bottom strip that used to be outside hit-test bounds.
      final view = t.view.physicalSize / t.view.devicePixelRatio;
      await t.tapAt(Offset(view.width / 2, view.height - 4), kind: PointerDeviceKind.mouse); await frames();
      expect(find.text('选择本机图片 / 文件…'), findsNothing, reason: 'dismiss menu at bottom edge at $percent% / $view');

      await click(find.byTooltip('AI 对话历史'));
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('ai-session-ses_1')), findsOneWidget);
      await click(find.byTooltip('返回对话'));
      expect(t.state(prompt), same(chat));
      expect(t.widget<TextField>(prompt).controller!.text, 'draft at $percent%');
      await click(find.byTooltip('展开 AI 对话'));
      await click(find.byTooltip('还原 AI 侧栏'));
      await click(find.byKey(const ValueKey('ai-context-indicator')));
      expect(t.getSize(find.byKey(const ValueKey('ai-runtime-bar'))).height, greaterThan(0));
      await click(find.byKey(const ValueKey('ai-context-indicator')));
      await click(find.byTooltip('隐藏 AI 侧栏（保留对话）'));

      if (ws.terminalTabs.isEmpty) {
        await click(find.byTooltip('终端'));
        await click(find.descendant(of: find.byType(SessionList), matching: find.byWidgetPredicate((w) => w is TreeRow && w.label == 'main')));
      } else {
        await guiKeys(t, LogicalKeyboardKey.backquote);
      }
      await click(find.byType(TerminalView));
      await guiKeys(t, LogicalKeyboardKey.keyJ);
      expect(ws.terminalPanel.visible, isFalse);
      await guiKeys(t, LogicalKeyboardKey.backquote);
      expect(ws.terminalPanel.visible, isTrue);
      await guiKeys(t, LogicalKeyboardKey.digit1);
      expect(ws.terminalFocused, isFalse);
      await guiKeys(t, LogicalKeyboardKey.keyJ);
      expect(ws.terminalPanel.visible, isFalse);

      await click(find.byKey(const ValueKey('tab-file:home:/project/src/main.dart')));
      expect(t.widget<CodeEditor>(find.byType(CodeEditor)).controller, same(editor));
      expect(doc.text, contains('GUI state survives zoom'));
      expect(doc.dirty, isTrue);
      for (final key in ['sidebar-resize']) {
        final handle = find.byKey(ValueKey(key));
        if (handle.evaluate().isEmpty) continue; // medium windows start with the sidebar closed
        final start = t.getCenter(handle);
        final pointer = await t.startGesture(start, kind: PointerDeviceKind.mouse);
        await pointer.moveTo(start + const Offset(17, 0)); await t.pump();
        expect(t.getCenter(handle).dx, closeTo(start.dx + 17, .1));
        await pointer.moveTo(start); await pointer.up(); await frames();
      }
      expect(t.takeException(), isNull);
      steps.add('$percent%: settings input, AI composer/menu/barrier/history/maximize/details, terminal shortcuts, state and divider');
    }

    // Actual scaled drag/drop, followed by close protection on the dirty tab.
    final group = ws.tabLayout.focused;
    final drag = await t.startGesture(t.getCenter(find.byKey(const ValueKey('tab-file:home:/project/src/workbench.dart'))), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(24, 0)); await frames(2);
    final box = t.renderObject<RenderBox>(find.byKey(ValueKey('pane-drop-$group')));
    await drag.moveTo(box.localToGlobal(TabDropPolicy.compass(box.size)[TabDropEdge.right]!.center)); await t.pump();
    expect(find.byKey(ValueKey('drop-preview-$group')), findsOneWidget);
    await drag.up(); await frames();
    expect(ws.tabLayout.groups, hasLength(2));
    await click(find.byKey(const ValueKey('tab-file:home:/project/src/main.dart')));
    await guiKeys(t, LogicalKeyboardKey.keyW);
    expect(find.byType(AlertDialog), findsOneWidget);
    await click(find.text('取消'));
    expect(ws.tab('file:home:/project/src/main.dart'), isNotNull);
    expect(doc.dirty, isTrue);
    steps.add('scaled docking and cancelled unsaved close');

    await click(find.byTooltip('视图操作').first);
    await click(find.text('标签栏与布局…'));
    await click(find.text('标签宽度'));
    final slider = find.descendant(of: find.byType(AlertDialog), matching: find.byType(Slider));
    final before = ws.tabLayout.tabWidth;
    await t.drag(slider, const Offset(45, 0), kind: PointerDeviceKind.mouse); await frames();
    expect(ws.tabLayout.tabWidth, greaterThan(before));
    await click(find.text('完成'));
    steps.add('layout dialog, width slider and accessible local overlay');

    await guiCommand(t, '新建终端会话…');
    expect(find.byType(NewSessionDialog), findsOneWidget);
    await click(find.text('取消'));
    await guiCommand(t, '配置 AI 模型与密钥…');
    expect(find.text('AI 模型与 OpenCode 协议配置'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape, physicalKey: PhysicalKeyboardKey.escape); await frames();
    Toast.show('GUI interaction audit complete'); await frames();
    expect(find.text('GUI interaction audit complete'), findsOneWidget);
    expect(link.terminalStreams, hasLength(1));
    expect(editor.canUndo, isTrue);
    editor.undo(); await frames();
    expect(doc.text, savedText);
    editor.redo(); await frames();
    expect(doc.text, 'const draft = "GUI state survives zoom";\n');
    expect(doc.dirty, isTrue);
    expect(t.takeException(), isNull);
    steps.add('command dialogs, Escape and scaled notification');
    if (capture != null) await capture();
    return {'steps': steps, 'terminal_attaches': link.terminalStreams.length, 'dirty_buffer_retained': doc.dirty, 'undo_redo_retained': true,
      'scales_percent': [85, 80, 100, 125, 150, 85], 'production_root': true, 'synthetic_services': true};
  } finally {
    await app.appearance.flush(); await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    app.dispose(); features.dispose();
  }
}
