import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_runtime_test.dart' show RuntimeLink;
import 'support/workspace_fixture.dart';

class _ControlsLink extends RuntimeLink {
  final permissions = <Map<String, dynamic>>[];
  bool failRun = false;
  bool supportsControls = true;
  _ControlsLink() {
    pendingPermission = null;
  }
  @override
  AgentInfo get server => AgentInfo({
    'caps': [
      if (supportsControls) 'ai.run.options',
      'ai.capabilities',
      'ai.inbox',
      'ai.permissions',
    ],
  });
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'ai.run.options')
      return {
        'source': 'project',
        'budgetEnabled': true,
        'budget': {
          'steps': 60,
          'seconds': 900,
          'tokens': 500000,
          'cost': 0,
          'outputBytes': 2097152,
        },
        'subagents': {'maxParallel': 2, 'maxTotal': 32},
        'autoCompact': true,
        'snapshots': true,
      };
    if (op == 'ai.run' && failRun)
      throw OpError(codeConflict, 'synthetic admission failed');
    final result = await super.call(op, args, timeout);
    if (op == 'ai.get') {
      (result as Map)['pending_permissions'] = List.of(permissions);
      result['running'] = permissions.isNotEmpty;
    }
    return result;
  }
}

void main() {
  final shots = Platform.environment['AURORA_AI_SHOTS'];
  final shotKey = GlobalKey();
  late _ControlsLink link;
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  setUpAll(() async {
    if (shots == null) return;
    for (final entry in {
      Ide.ui: r'C:\Windows\Fonts\SegUIVar.ttf',
      'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
      'Microsoft YaHei UI': r'C:\Windows\Fonts\msyh.ttc',
      Ide.mono: r'C:\Windows\Fonts\consola.ttf',
      'Consolas': r'C:\Windows\Fonts\consola.ttf',
      'MaterialIcons': r'C:\dev\VPS\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        Future.value(ByteData.sublistView(File(entry.value).readAsBytesSync())),
      );
      await loader.load();
    }
    Directory(shots).createSync(recursive: true);
  });
  setUp(() {
    link = _ControlsLink();
    app = WorkspaceApp(
      wire: link,
      profile: Profile(
        servers: [ServerEntry(id: 'server', name: 'fixture')],
        selected: 'server',
        ai: AiSettings(
          providers: [
            AiProvider(id: 'p', name: '测试网关', model: 'fixture-model'),
          ],
        ),
      ),
    );
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
  });
  tearDown(() {
    ws.dispose();
    app.dispose();
    input.dispose();
  });
  Future<void> frames(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pump(
    WidgetTester t, {
    double width = 1000,
    double height = 800,
    double scale = 1,
    Brightness brightness = Brightness.dark,
  }) async {
    t.view.physicalSize = Size(width, height);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness),
          builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: w!,
          ),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: AiStudioView(ws: ws, initialSessionId: 'ses_1'),
            ),
          ),
        ),
      ),
    );
    await frames(t);
  }

  Future<void> choose(WidgetTester t, String key, String text) async {
    final field = find.byKey(ValueKey(key));
    await t.ensureVisible(field);
    await t.tap(field);
    await frames(t);
    await t.tap(find.text(text).last);
    await frames(t);
  }

  Future<void> options(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('ai-send-options')));
    await frames(t);
  }

  Future<void> apply(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('ai-send-options-apply')));
    await frames(t);
  }

  Future<void> shot(WidgetTester t, String name) async {
    if (shots == null) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'message controls survive failure, apply once and queue independently',
    (t) async {
      await pump(t);
      await t.enterText(
        find.byKey(const ValueKey('ai-prompt-input')),
        'inspect project',
      );
      await options(t);
      await choose(t, 'ai-send-budget-0', '关闭 · 不限制本次运行');
      await choose(t, 'ai-send-parallel-0', '4 个');
      await apply(t);
      link.supportsControls = false;
      await t.tap(find.byKey(const ValueKey('ai-send-btn')));
      await frames(t);
      expect(link.rpcCalls.where((c) => c.$1 == 'ai.run'), isEmpty);
      expect(find.textContaining('预算关'), findsOneWidget);
      link.supportsControls = true;
      link.failRun = true;
      await t.tap(find.byKey(const ValueKey('ai-send-btn')));
      await frames(t);
      expect(find.textContaining('预算关'), findsOneWidget);
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('ai-prompt-input')))
            .controller!
            .text,
        'inspect project',
      );
      link.failRun = false;
      await t.tap(find.byKey(const ValueKey('ai-send-btn')));
      await frames(t);
      final sent = link.rpcCalls.lastWhere((c) => c.$1 == 'ai.run').$2;
      expect(sent['options'], {'budgetMode': 'off', 'maxParallel': 4});
      expect(find.textContaining('预算关'), findsNothing);
      link.events.emit({'type': 'session.status', 'status': 'running'});
      await frames(t);
      await options(t);
      final budget = t.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('ai-send-budget-0')),
      );
      expect(budget.onChanged, isNull);
      await choose(t, 'ai-send-delivery-0', '排队发送 · 当前任务结束后');
      await choose(t, 'ai-send-budget-0', '关闭 · 不限制本次运行');
      await apply(t);
      await t.enterText(
        find.byKey(const ValueKey('ai-prompt-input')),
        'next task',
      );
      await t.tap(find.byKey(const ValueKey('ai-send-btn')));
      await frames(t);
      final queued = link.rpcCalls.lastWhere((c) => c.$1 == 'ai.run').$2;
      expect(queued['delivery'], 'queue');
      expect(queued['options'], {'budgetMode': 'off'});
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('simultaneous child approvals remain accessible after resync', (
    t,
  ) async {
    for (var i = 1; i <= 2; i++) {
      link.permissions.add({
        'id': 'p$i',
        'session_id': 'child-$i',
        'call_id': 'c$i',
        'tool': 'shell',
        'action': 'shell',
        'resource': 'echo child-$i',
        'reason': 'requires approval',
      });
    }
    await pump(t);
    expect(find.textContaining('echo child-1'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('ai-approve-once')));
    await frames(t);
    expect(find.textContaining('echo child-2'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('ai-deny')));
    await frames(t);
    final approved = link.rpcCalls.where((c) => c.$1 == 'ai.approve').toList();
    expect(approved.map((c) => c.$2['id']), ['p1', 'p2']);
    expect(approved.last.$2['allow'], false);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('send shortcut respects composition and task drafts', (t) async {
    await app.update((p) => p.ai.sendKey = 'ctrl-enter');
    await pump(t);
    final prompt = find.byKey(const ValueKey('ai-prompt-input'));
    await t.enterText(prompt, 'keyboard task');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await frames(t);
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.run'), isEmpty);
    final controller = t.widget<TextField>(prompt).controller!;
    controller.value = controller.value.copyWith(
      composing: const TextRange(start: 0, end: 8),
    );
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(t);
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.run'), isEmpty);
    controller.value = controller.value.copyWith(composing: TextRange.empty);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(t);
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.run'), hasLength(1));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  for (final width in [360.0, 1200.0]) {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      testWidgets('unified pages retain drafts at $width $brightness', (
        t,
      ) async {
        await pump(
          t,
          width: width,
          brightness: brightness,
          scale: width == 360 ? 1.3 : 1,
        );
        await t.enterText(
          find.byKey(const ValueKey('ai-prompt-input')),
          '保留这条尚未发送的草稿',
        );
        await shot(t, 'conversation-${width.toInt()}-${brightness.name}');
        await t.tap(find.byKey(const ValueKey('ai-work-list')));
        await frames(t);
        await shot(t, 'tasks-${width.toInt()}-${brightness.name}');
        await t.tap(find.byKey(const ValueKey('ai-work-main')));
        await frames(t);
        expect(
          t
              .widget<TextField>(find.byKey(const ValueKey('ai-prompt-input')))
              .controller!
              .text,
          '保留这条尚未发送的草稿',
        );
        await options(t);
        await shot(t, 'send-options-${width.toInt()}-${brightness.name}');
        await choose(t, 'ai-send-budget-0', '关闭 · 不限制本次运行');
        await t.tap(find.text('取消').last);
        await frames(t);
        expect(find.textContaining('预算关'), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      });
    }
  }
}
