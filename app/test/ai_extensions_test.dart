import 'dart:async';
import 'dart:convert';

import 'package:aurora/features/ai/ai_extensions.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
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
  Future<void> reveal(WidgetTester t, String label) async {
    // Drag the page gutter; its centre is a separately scrollable JSON editor.
    for (
      var i = 0;
      i < 24 && find.text(label).hitTestable().evaluate().isEmpty;
      i++
    ) {
      await t.dragFrom(
        Offset(2, t.view.physicalSize.height / t.view.devicePixelRatio * .8),
        const Offset(0, -160),
      );
      await t.pumpAndSettle();
    }
    expect(find.text(label).hitTestable(), findsOneWidget);
  }

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'extension configuration saves versioned JSON and shows MCP catalog ($width)',
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
        expect(find.text('AI 扩展与预算 · home:/project'), findsOneWidget);
        final source = t.widget<TextField>(find.byType(TextField)).controller!;
        final draft = jsonDecode(source.text) as Map;
        draft['budget']['steps'] = 5;
        source.text = jsonEncode(draft);
        link.saveGate = Completer<void>();
        await t.ensureVisible(find.text('保存 AI 配置'));
        await t.tap(find.text('保存 AI 配置'));
        await t.pump();
        expect(link.saveStarted.isCompleted, isTrue);
        draft['budget']['steps'] = 6;
        source.text = jsonEncode(draft);
        link.saveGate!.complete();
        await t.pumpAndSettle();
        expect((link.config['budget'] as Map)['steps'], 5);
        expect((jsonDecode(source.text) as Map)['budget']['steps'], 6);
        await reveal(t, '检测连接与目录');
        await t.tap(find.text('检测连接与目录'));
        await t.pumpAndSettle();
        expect(find.text('1 工具 · 0 资源 · 0 提示词'), findsOneWidget);
        await t.ensureVisible(find.text('清理未引用快照'));
        await t.pumpAndSettle();
        await t.tap(find.text('清理未引用快照'));
        await t.pumpAndSettle();
        expect(link.pruneCalls, 1);
        expect(find.text('快照占用：4096 → 2048 字节'), findsOneWidget);
        // An external writer wins; the rejected save preserves the editor draft.
        link.version++;
        await t.ensureVisible(find.text('保存 AI 配置'));
        await t.pumpAndSettle();
        await t.tap(find.text('保存 AI 配置'));
        await t.pumpAndSettle();
        expect(find.textContaining('stale'), findsOneWidget);
        expect((jsonDecode(source.text) as Map)['budget']['steps'], 6);
        expect((link.config['budget'] as Map)['steps'], 5);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        ws.dispose();
        app.dispose();
        input.dispose();
      },
    );
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
      final source = t.widget<TextField>(find.byType(TextField)).controller!;
      source.text = '{"draft":true}';
      await reveal(t, '检测连接与目录');
      await t.tap(find.text('检测连接与目录'));
      await t.pump();
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
