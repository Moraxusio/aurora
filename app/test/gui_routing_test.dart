import 'dart:convert';

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/search/quick_open.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/desktop_lifecycle.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'support/workspace_fixture.dart';
import 'workbench_visual_test.dart' show VisualWorkbenchLink;

Future<void> guiKeys(WidgetTester t, LogicalKeyboardKey key, {bool shift = false, bool alt = false}) async {
  // Profile strips debug key names, which Flutter's inference relies on.
  final physical = {
    LogicalKeyboardKey.keyC: PhysicalKeyboardKey.keyC,
    LogicalKeyboardKey.keyV: PhysicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyJ: PhysicalKeyboardKey.keyJ,
    LogicalKeyboardKey.keyP: PhysicalKeyboardKey.keyP,
    LogicalKeyboardKey.keyW: PhysicalKeyboardKey.keyW,
    LogicalKeyboardKey.digit0: PhysicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1: PhysicalKeyboardKey.digit1,
    LogicalKeyboardKey.backquote: PhysicalKeyboardKey.backquote,
  }[key]!;
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
  if (alt) await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft, physicalKey: PhysicalKeyboardKey.altLeft);
  await t.sendKeyEvent(key, physicalKey: physical);
  if (alt) await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft, physicalKey: PhysicalKeyboardKey.altLeft);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await t.pumpAndSettle();
}

Future<void> guiCommand(WidgetTester t, String title) async {
  await guiKeys(t, LogicalKeyboardKey.keyP, shift: true);
  final input = find.widgetWithText(TextField, '输入命令…');
  expect(input, findsOneWidget);
  await t.enterText(input, title);
  await t.pump();
  await t.tapAt(t.getCenter(find.text(title).last), kind: PointerDeviceKind.mouse);
  await t.pumpAndSettle();
}

void main() {
  late WorkspaceApp app;
  late Features features;
  late VisualWorkbenchLink link;
  late Workspace ws;
  final windowCalls = <String>[];
  setUp(() {
    features = Features();
    link = VisualWorkbenchLink(features);
    app = WorkspaceApp(wire: link);
    windowCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      DesktopLifecycle.channel, (call) async {
        windowCalls.add(call.method);
        return call.method == 'ready' ? {'frameless': true, 'maximized': false} : null;
      });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopLifecycle.channel, null);
    DesktopLifecycle.frameless.value = false;
    app.dispose(); features.dispose();
  });
  Future<void> pump(WidgetTester t, double scale) async {
    t.view.physicalSize = const Size(1560, 1000); t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
    app.appearance.set('uiScale', scale);
    await t.pumpWidget(AuroraApp(app: app));
    await t.pumpAndSettle();
    ws = (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;
  }
  Future<void> close(WidgetTester t) async {
    await app.appearance.flush(); await ws.flushViews();
    await t.pumpWidget(const SizedBox());
  }

  testWidgets('production command palette can open feature dialogs using the active navigator', (t) async {
    await pump(t, .85);
    await guiCommand(t, '新建终端会话…');
    expect(find.byType(NewSessionDialog), findsOneWidget);
    await t.tap(find.text('取消')); await t.pumpAndSettle();
    await guiCommand(t, '配置 AI 模型与密钥…');
    expect(find.text('AI 模型与 OpenCode 协议配置'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape, physicalKey: PhysicalKeyboardKey.escape); await t.pumpAndSettle();
    await guiCommand(t, '按文件名打开…');
    expect(find.byType(QuickOpen), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape, physicalKey: PhysicalKeyboardKey.escape); await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('notifications fit the scaled production viewport', (t) async {
    await pump(t, 1.5);
    Toast.show('操作完成，仍可继续编辑');
    await t.pumpAndSettle();
    final text = find.text('操作完成，仍可继续编辑');
    expect(text, findsOneWidget);
    expect(t.getSize(text).width, greaterThan(200));
    app.appearance.set('uiScale', .85);
    await t.pump();
    expect(t.getSize(text).width, greaterThan(200));
    expect(t.takeException(), isNull);
    Toast.key.currentState!.removeCurrentSnackBar();
    await close(t);
  });

  testWidgets('real terminal routes workbench shortcuts before encoding shell input', (t) async {
    await pump(t, .85);
    ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/src/main.dart'));
    openSession(ws, 'main');
    await t.pumpAndSettle();
    await t.tapAt(t.getCenter(find.byType(TerminalView))); await t.pump();
    expect(t.widget<TerminalView>(find.byType(TerminalView)).focusNode!.hasFocus, isTrue);
    final stream = link.terminalStreams.single;
    await guiKeys(t, LogicalKeyboardKey.keyC);
    expect(stream.input.expand((bytes) => bytes), [3], reason: 'shell control keys still reach the terminal');
    stream.input.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': 'clipboard-fixture'} : null);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await guiKeys(t, LogicalKeyboardKey.keyV, shift: true);
    expect(utf8.decode(stream.input.expand((bytes) => bytes).toList()), contains('clipboard-fixture'));
    stream.input.clear();
    await guiKeys(t, LogicalKeyboardKey.keyJ);
    expect(ws.terminalPanel.visible, isFalse);
    expect(stream.input, isEmpty, reason: 'reserved shortcuts must not also be sent to the shell');
    await guiKeys(t, LogicalKeyboardKey.backquote);
    expect(ws.terminalPanel.visible, isTrue);
    await guiKeys(t, LogicalKeyboardKey.digit0);
    expect(app.appearance.value.uiScale, 1);
    await guiKeys(t, LogicalKeyboardKey.digit1);
    expect(ws.terminalFocused, isFalse);
    expect(link.terminalStreams, hasLength(1));
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('native caption buttons remain clickable across UI zoom and display DPI', (t) async {
    await pump(t, 1);
    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      t.view.devicePixelRatio = dpr;
      t.view.physicalSize = const Size(1560, 1000) * dpr;
      for (final scale in [.8, .85, 1.0, 1.25, 1.5]) {
        app.appearance.set('uiScale', scale); await t.pumpAndSettle();
        windowCalls.clear();
        for (final label in ['最小化', '最大化', '关闭到托盘']) {
          final button = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);
          expect(button.hitTestable(), findsOneWidget);
          await t.tapAt(t.getCenter(button)); await t.pump();
        }
        expect(windowCalls, ['minimize', 'toggleMaximize', 'close'], reason: '$scale zoom, DPR $dpr');
      }
    }
    await close(t);
  });
}
