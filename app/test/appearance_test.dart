import 'dart:async';

import 'package:aurora/state/appearance.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/theme/workbench_scale.dart';
import 'package:aurora/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart';

import 'support/workspace_fixture.dart';
import 'workbench_visual_test.dart' show VisualWorkbenchLink;

void main() {
  testWidgets('240 live values coalesce into one write; a slow write never rolls back the preview', (t) async {
    var disk = const AppearanceValues();
    final writes = <Map<String, Object>>[];
    Completer<void>? barrier;
    final prefs = AppearanceController(read: () => disk, save: (patch) async {
      writes.add(patch);
      if (barrier != null) await barrier.future;
      disk = disk.patch(patch);
    });
    for (var i = 0; i < 240; i++) { prefs.set('editorFont', 9 + i / 20); }
    expect(prefs.value.editorFont, 20.95);
    expect(writes, isEmpty);
    await t.pump(const Duration(milliseconds: 240));
    expect(writes, hasLength(1));
    expect(disk.editorFont, 20.95);
    barrier = Completer<void>();
    prefs.set('editorFont', 18.0);
    final save = prefs.flush();
    await t.pump();
    prefs.set('editorFont', 22.0);
    prefs.set('terminalFont', 19.0);
    prefs.reload();
    expect((prefs.value.editorFont, prefs.value.terminalFont), (22, 19));
    barrier.complete();
    await t.pump();
    expect(await save, isTrue);
    expect((disk.editorFont, disk.terminalFont), (22, 19));
    prefs.dispose();
  });

  testWidgets('failed save preserves live settings and can retry without overwriting unrelated fields', (t) async {
    var disk = const AppearanceValues(), failing = true;
    final prefs = AppearanceController(read: () => disk, save: (patch) async {
      if (failing) throw StateError('synthetic failure');
      disk = disk.patch(patch);
    });
    prefs.set('editorFont', 20.0);
    final result = prefs.flush();
    await t.pump();
    expect(await result, isFalse);
    expect(prefs.value.editorFont, 20);
    expect(prefs.error, isNotNull);
    disk = disk.patch({'theme': 'light'});
    prefs.reload();
    failing = false;
    final retry = prefs.flush();
    await t.pump();
    expect(await retry, isTrue);
    expect((disk.theme, disk.editorFont), ('light', 20));
    prefs.dispose();
  });

  testWidgets('real open file and terminal update before saving, UI zoom keeps their controllers and stream', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final features = Features(), input = InputMode(touch: false), shell = GlobalKey();
    final link = VisualWorkbenchLink(features), app = WorkspaceApp();
    final live = WorkspaceApp(profile: app.data, wire: link);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: ListenableBuilder(
      listenable: live.appearance, child: Shell(key: shell, app: live, features: features),
      builder: (_, child) => WorkbenchScale(scale: live.appearance.value.uiScale,
        child: InputMode.scope(mode: input, child: child!)))));
    await t.pumpAndSettle();
    final ws = (shell.currentState as dynamic).debugWorkspace as Workspace;
    ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/src/main.dart'));
    ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/src/other.dart'));
    ws.activate('file:home:/project/src/main.dart');
    openSession(ws, 'main');
    await t.pumpAndSettle();
    final editor = t.widget<CodeEditor>(find.byType(CodeEditor));
    final term = t.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final columns = term.viewWidth;
    final state = t.state<FileEditorState>(find.byType(FileEditor));
    state.text = 'unsaved text';
    live.appearance.set('editorFont', 22.0);
    live.appearance.set('terminalFont', 20.0);
    await t.pump();
    expect(t.widget<CodeEditor>(find.byType(CodeEditor)).style!.fontSize, 22);
    expect(t.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize, 20);
    expect(term.viewWidth, lessThan(columns), reason: 'the real terminal grid must remeasure, not just its widget property');
    expect(live.data.editor.fontSize, 13.5, reason: 'no disk write needed for the first frame');
    final sizes = t.widgetList<CodeEditor>(find.byType(CodeEditor, skipOffstage: false)).map((e) => e.style!.fontSize);
    expect(sizes, containsAll([13.5, 22]), reason: 'a hidden code buffer must not reflow during the slider drag');
    ws.activate('file:home:/project/src/other.dart');
    await t.pump();
    expect(t.widget<CodeEditor>(find.byType(CodeEditor)).style!.fontSize, 22);
    ws.activate('file:home:/project/src/main.dart');
    await t.pump();
    for (final scale in [1.25, .8, 1.5, 1.0]) {
      live.appearance.set('uiScale', scale);
      await t.pump();
      expect(t.widget<CodeEditor>(find.byType(CodeEditor)).controller, same(editor.controller));
      expect(t.widget<TerminalView>(find.byType(TerminalView)).terminal, same(term));
      expect(state.text, 'unsaved text');
      expect(state.dirty, isTrue);
      expect(t.takeException(), isNull);
    }
    expect(link.terminalStreams, hasLength(1));
    ws.openTab(settingsTab(live));
    await t.pumpAndSettle();
    await t.tap(find.text('文字与编辑器').first);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('setting-input-editorFont')), '19.5');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(live.appearance.value.editorFont, 19.5);
    final flush = live.appearance.flush(); await t.pump(); await flush;
    await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    features.dispose(); input.dispose(); live.dispose(); app.dispose();
  });
}
