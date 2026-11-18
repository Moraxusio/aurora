import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_extensions.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _Link extends FileTreeLink {
  var config = <String, Object?>{
    'version': 1,
    'instructions': [],
    'disabledSkills': [],
    'mcp': [
      {'id': 'fixture', 'url': 'https://fixture.test/mcp'},
    ],
    'budget': {
      'steps': 60,
      'seconds': 900,
      'tokens': 500000,
      'outputBytes': 2097152,
      'cost': 0,
    },
    'prices': {},
  };
  var version = 1;
  Completer<void>? saveGate;
  Completer<Object?>? probeGate;
  final saveStarted = Completer<void>();
  var pruneCalls = 0;
  @override
  AgentInfo get server => AgentInfo({
    'caps': ['ai.extensions', 'ai.mcp.probe', 'ai.snapshots.prune'],
  });
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'ai.extensions') {
      final input = args as Map;
      if (input['config'] != null) {
        if (input['if_match'] != '$version')
          throw OpError(codeConflict, 'stale');
        if (!saveStarted.isCompleted) saveStarted.complete();
        await saveGate?.future;
        config = (input['config'] as Map).cast<String, Object?>();
        version++;
      }
      return {
        'budget_version': 2,
        'controls_version': 1,
        'etag': '$version',
        'config': config,
        'instructions': [
          {'path': '/AGENTS.md', 'text': 'root instructions'},
        ],
        'skills': [
          {
            'name': 'fixture',
            'description': 'Test skill',
            'path': '/skills/fixture/SKILL.md',
          },
        ],
      };
    }
    if (op == 'ai.mcp.probe')
      return probeGate?.future ??
          {
            'tools': [
              {'name': 'echo'},
            ],
            'resources': [],
            'prompts': [],
          };
    if (op == 'ai.snapshots.prune') {
      pruneCalls++;
      return {'beforeBytes': 4096, 'afterBytes': 2048};
    }
    return super.call(op, args, timeout);
  }
}

class _App extends WorkspaceApp {
  Link current;
  _App(this.current);
  @override
  Link? link(String id) => current;
  void reconnect(Link next) {
    current = next;
    notifyListeners();
  }
}

void main() {
  final shots = Platform.environment['AURORA_AI_SHOTS'];
  final shotKey = GlobalKey();
  setUpAll(() async {
    if (shots == null) return;
    for (final entry in {
      Ide.ui: r'C:\Windows\Fonts\SegUIVar.ttf',
      'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
      'Microsoft YaHei UI': r'C:\Windows\Fonts\msyh.ttc',
      Ide.mono: r'C:\Windows\Fonts\consola.ttf',
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
  Future<void> shot(WidgetTester t, String name) async {
    if (shots == null) return;
    await t.ensureVisible(find.text('AI 项目配置'));
    await t.pumpAndSettle();
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> reveal(WidgetTester t, String label) async {
    // Drag the page gutter; its centre is a separately scrollable JSON editor.
    for (
      var i = 0;
      i < 24 && find.text(label).hitTestable().evaluate().isEmpty;
      i++
    ) {
      final bounds = t.getRect(
        find.byKey(const ValueKey('ai-extensions-scroll')),
      );
      await t.dragFrom(
        Offset(bounds.right - 2, bounds.top + bounds.height * .8),
        const Offset(0, -160),
      );
      await t.pumpAndSettle();
    }
    expect(find.text(label).hitTestable(), findsOneWidget);
  }

  Future<void> page(WidgetTester t, String id) async {
    final selector = find.byKey(const ValueKey('ai-project-nav-selector'));
    var direction = 120.0;
    if (selector.evaluate().isNotEmpty) {
      final button = t.widget<DropdownButton<String>>(selector);
      final pages = button.items!.map((item) => item.value).toList();
      if (pages.indexOf(id) < pages.indexOf(button.value)) direction = -120;
      await t.ensureVisible(selector);
      await t.pumpAndSettle();
      await t.tap(selector);
      await t.pumpAndSettle();
    }
    final nav = find.byKey(ValueKey('ai-project-nav-$id'));
    if (nav.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        nav,
        direction,
        scrollable: find.byType(Scrollable).last,
      );
    }
    await t.ensureVisible(nav);
    await t.pumpAndSettle();
    await t.tap(nav.hitTestable());
    await t.pumpAndSettle();
    if (selector.evaluate().isNotEmpty) {
      expect(t.widget<DropdownButton<String>>(selector).value, id);
    }
  }

  testWidgets('project shortcuts reuse the draft and protect it on close', (
    t,
  ) async {
    final link = _Link(), input = InputMode();
    final app = _App(link), ws = Workspace(app, 'server');
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: AnimatedBuilder(
              animation: ws,
              builder: (context, _) => ws.tabs.isEmpty
                  ? const SizedBox()
                  : ws.tabs.single.builder(context),
            ),
          ),
        ),
      ),
    );
    final context = t.element(find.byType(Scaffold));
    await openAiExtensions(context, ws, root: 'home', workdir: '/project');
    await t.pumpAndSettle();
    final steps = find.byKey(const ValueKey('ai-budget-steps'));
    await t.ensureVisible(steps);
    await t.enterText(steps, '123');
    expect(ws.tabs.single.dirty.value, isTrue);
    await openAiExtensions(
      context,
      ws,
      root: 'home',
      workdir: '/project',
      page: 'snapshots',
    );
    await t.pumpAndSettle();
    expect(ws.tabs, hasLength(1));
    expect(find.byKey(const ValueKey('ai-snapshots-enabled')), findsOneWidget);
    final close = ws.tabs.single.confirmClose!();
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(await close, isFalse);
    await openAiExtensions(context, ws, root: 'home', workdir: '/project');
    await t.pumpAndSettle();
    await page(t, 'advanced');
    final source = t
        .widget<TextField>(find.byKey(const ValueKey('ai-project-json')))
        .controller!;
    expect((jsonDecode(source.text) as Map)['budget']['steps'], 123);
    await t.ensureVisible(find.text('保存 AI 配置'));
    await t.tap(find.text('保存 AI 配置'));
    await t.pumpAndSettle();
    expect(ws.tabs.single.dirty.value, isFalse);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    ws.dispose();
    app.dispose();
    input.dispose();
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'project forms preserve in-flight edits, conflicts and MCP catalog ($width)',
      (t) async {
        t.view.physicalSize = Size(width, 480);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final link = _Link(), input = InputMode();
        final app = _App(link), ws = Workspace(app, 'server');
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.dark),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: InputMode.scope(
              mode: input,
              child: Scaffold(
                body: AiExtensionsView(
                  ws: ws,
                  root: 'home',
                  workdir: '/project',
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('AI 项目配置'), findsOneWidget);
        final steps = find.byKey(const ValueKey('ai-budget-steps'));
        await t.ensureVisible(steps);
        await t.enterText(steps, '5');
        link.saveGate = Completer<void>();
        await t.ensureVisible(find.text('保存 AI 配置'));
        await t.tap(find.text('保存 AI 配置'));
        await t.pump();
        expect(link.saveStarted.isCompleted, isTrue);
        await t.ensureVisible(steps);
        await t.enterText(steps, '6');
        link.saveGate!.complete();
        await t.pumpAndSettle();
        expect((link.config['budget'] as Map)['steps'], 5);
        await page(t, 'advanced');
        final source = t
            .widget<TextField>(find.byKey(const ValueKey('ai-project-json')))
            .controller!;
        expect((jsonDecode(source.text) as Map)['budget']['steps'], 6);
        // An external writer wins; the rejected save preserves the editor draft.
        link.version++;
        await t.ensureVisible(find.text('保存 AI 配置'));
        await t.pumpAndSettle();
        await t.tap(find.text('保存 AI 配置'));
        await t.pumpAndSettle();
        expect(find.textContaining('stale'), findsOneWidget);
        expect((jsonDecode(source.text) as Map)['budget']['steps'], 6);
        expect((link.config['budget'] as Map)['steps'], 5);
        link.version--;
        await t.tap(find.text('保存 AI 配置'));
        await t.pumpAndSettle();
        expect((link.config['budget'] as Map)['steps'], 6);
        await page(t, 'mcp');
        await reveal(t, '检测连接与目录');
        await t.tap(find.text('检测连接与目录'));
        await t.pumpAndSettle();
        expect(find.text('1 工具 · 0 资源 · 0 提示词'), findsOneWidget);
        await page(t, 'snapshots');
        await reveal(t, '清理未引用快照');
        await t.tap(find.text('清理未引用快照'));
        await t.pumpAndSettle();
        expect(link.pruneCalls, 1);
        expect(find.text('快照占用：4096 → 2048 字节'), findsOneWidget);
        await page(t, 'budget');
        final tokens = find.byKey(const ValueKey('ai-budget-tokens'));
        await t.ensureVisible(tokens);
        await t.enterText(tokens, '-1');
        await t.ensureVisible(find.text('保存 AI 配置'));
        await t.tap(find.text('保存 AI 配置'));
        await t.pumpAndSettle();
        expect(find.textContaining('请输入 0–1000000000'), findsOneWidget);
        expect((link.config['budget'] as Map)['tokens'], 500000);
        await t.ensureVisible(tokens);
        await t.enterText(tokens, '0');
        await t.ensureVisible(find.text('保存 AI 配置'));
        await t.tap(find.text('保存 AI 配置'));
        await t.pumpAndSettle();
        expect((link.config['budget'] as Map)['tokens'], 0);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        ws.dispose();
        app.dispose();
        input.dispose();
      },
    );
  }
  for (final width in [360.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'project agent and tool controls save at $width ${brightness.name}',
        (t) async {
          t.view.physicalSize = Size(width, 960);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final link = _Link(), input = InputMode();
          final app = _App(link), ws = Workspace(app, 'server');
          addTearDown(() {
            ws.dispose();
            app.dispose();
            input.dispose();
          });
          await t.pumpWidget(
            RepaintBoundary(
              key: shotKey,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(brightness),
                home: InputMode.scope(
                  mode: input,
                  child: Scaffold(
                    body: AiExtensionsView(
                      ws: ws,
                      root: 'home',
                      workdir: '/project',
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          Future<void> number(String key, String value) async {
            final field = find.byKey(ValueKey(key));
            await t.ensureVisible(field);
            await t.enterText(field, value);
            await t.pumpAndSettle();
          }

          Future<void> save() async {
            final button = find.byKey(const ValueKey('ai-project-save'));
            await t.ensureVisible(button);
            await t.pumpAndSettle();
            await t.tap(button);
            await t.pumpAndSettle();
          }

          await page(t, 'agents');
          await number('ai-subagents-maxParallel', '17');
          await save();
          expect(link.version, 1);
          expect(find.textContaining('请输入 1–16'), findsOneWidget);
          await number('ai-subagents-maxParallel', '4');
          await number('ai-subagents-maxTotal', '12');
          final readOnly = find.widgetWithText(SwitchListTile, '子代理仅允许只读探索');
          await t.ensureVisible(readOnly);
          await t.tap(readOnly);
          await save();
          expect(link.config['subagents'], {
            'maxParallel': 4,
            'maxTotal': 12,
            'readOnly': true,
          });
          await page(t, 'tools');
          await number('ai-tools-maxCallsPerStep', '8');
          await number('ai-tools-repeatLimit', '4');
          await number('ai-tools-shellDefaultSeconds', '30');
          await number('ai-tools-shellMaxSeconds', '60');
          await save();
          expect(link.config['tools'], {
            'maxCallsPerStep': 8,
            'repeatLimit': 4,
            'shellDefaultSeconds': 30,
            'shellMaxSeconds': 60,
          });
          await shot(t, 'project-tools-${width.toInt()}-${brightness.name}');
          await page(t, 'agents');
          expect(
            t
                .widget<TextFormField>(
                  find.byKey(const ValueKey('ai-subagents-maxParallel')),
                )
                .initialValue,
            '4',
          );
          expect(t.widget<SwitchListTile>(readOnly).value, isTrue);
          await shot(t, 'project-agents-${width.toInt()}-${brightness.name}');
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'old connection probe cannot populate new connection; draft stays editable',
    (t) async {
      final link = _Link()..probeGate = Completer<Object?>(),
          input = InputMode();
      final app = _App(link), ws = Workspace(app, 'server');
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: AiExtensionsView(ws: ws, root: 'home', workdir: '/project'),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await page(t, 'mcp');
      await reveal(t, '检测连接与目录');
      await t.tap(find.text('检测连接与目录'));
      await t.pump();
      await page(t, 'advanced');
      final source = t
          .widget<TextField>(find.byKey(const ValueKey('ai-project-json')))
          .controller!;
      source.text = '{"draft":true}';
      app.reconnect(_Link());
      link.probeGate!.complete({
        'tools': [
          {'name': 'old'},
        ],
      });
      await t.pumpAndSettle();
      expect(source.text, '{"draft":true}');
      expect(find.textContaining('1 工具'), findsNothing);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存 AI 配置'))
            .onPressed,
        isNull,
      );
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
      input.dispose();
    },
  );
}
