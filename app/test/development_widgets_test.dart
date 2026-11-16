import 'dart:async';

import 'package:aurora/features/development/development_feature.dart';
import 'package:aurora/features/development/debug_panel.dart';
import 'package:aurora/features/development/language_actions.dart';
import 'package:aurora/features/development/task_panel.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/kernel/development/task_model.dart';
import 'package:aurora/kernel/development/text_edits.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/workspace_fixture.dart';

class _Link extends FileTreeLink {
  Object? savedConfig;
  @override
  AgentInfo get server => AgentInfo({
    'caps': [
      'fs.read',
      'lsp.start',
      'devtools.config',
      'dap.start',
      'task.run',
    ],
  });
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'devtools.config')
      return {
        'rootUri': 'file:///C:/project',
        'workspaceUri': 'file:///C:/project',
        'platform': 'windows',
        'etag': 'config1',
        'config': {
          'version': 1,
          'languageServers': [],
          'tasks': [],
          'debug': [],
        },
      };
    if (op == 'devtools.configure') {
      savedConfig = (args as Map)['config'];
      return {'etag': 'config2'};
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  testWidgets(
    'short Problems panel scrolls to logs and cancelled edit review closes',
    (t) async {
      final input = InputMode(touch: true), link = _Link();
      final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
      ws.development.log('语言服务日志内容');
      Widget host(Widget child) => InputMode.scope(
        mode: input,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(body: child),
        ),
      );
      await t.pumpWidget(
        host(
          Center(
            child: SizedBox(
              width: 240,
              height: 110,
              child: DevelopmentPanel(ws: ws),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byTooltip('开发工具日志'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('开发工具日志'));
      await t.pumpAndSettle();
      expect(find.text('语言服务日志内容'), findsWidgets);
      expect(t.takeException(), isNull);
      await t.tap(find.text('关闭'));
      await t.pumpAndSettle();

      final doc = ws.documents.open('home', '/project/main.dart');
      await doc.load();
      final cancelled = Completer<void>();
      final plan = DocumentEditPlan(
        [PlannedDocumentEdit(doc, doc.version, doc.text, 'preview\n')],
        active: () => !cancelled.isCompleted,
        cancelled: cancelled.future,
      );
      var accepted = true;
      await t.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                accepted = await reviewDocumentEdits(context, plan);
              },
              child: const Text('review'),
            ),
          ),
        ),
      );
      await t.tap(find.text('review'));
      await t.pump();
      cancelled.complete();
      await t.pumpAndSettle();
      expect(accepted, isFalse);
      expect(find.text('接受全部修改'), findsNothing);
      expect(doc.text, 'synthetic original\n');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
      input.dispose();
    },
  );
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'development tabs, config and result view fit $width at enlarged text scale',
      (t) async {
        t.view.physicalSize = Size(width, 740);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final input = InputMode(touch: width < 500), link = _Link();
        final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
        await ws.selectProject('a');
        Widget wrap(Widget child) => MaterialApp(
          theme: buildTheme(Brightness.dark),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(body: child),
          ),
        );
        await t.pumpWidget(
          wrap(
            Column(
              children: [
                Builder(
                  builder: (c) => TextButton(
                    onPressed: () => editDevelopmentConfiguration(c, ws),
                    child: const Text('configure'),
                  ),
                ),
                Expanded(child: DevelopmentPanel(ws: ws)),
              ],
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('任务与测试'));
        await t.pumpAndSettle();
        expect(find.text('运行测试'), findsOneWidget);
        await t.tap(find.text('调试'));
        await t.pumpAndSettle();
        expect(find.text('断点 · 0'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.tap(find.text('configure'));
        await t.pumpAndSettle();
        await t.enterText(
          find.byType(TextField),
          '{"version":1,"languageServers":[],"tasks":[],"debug":[]}',
        );
        await t.tap(find.text('保存配置'));
        await t.pumpAndSettle();
        expect((link.savedConfig as Map)['version'], 1);
        expect(t.takeException(), isNull);
        final run =
            TaskRun(
                'test',
                'test',
                '长名称测试任务',
                'home',
                '/project',
                'test',
                DateTime.now(),
              )
              ..status = 'failed'
              ..exitCode = 1
              ..output = 'error output';
        run.problems.add(
          const TaskProblem(
            'home',
            '/project/file.dart',
            3,
            2,
            'failure',
            'error',
          ),
        );
        run.tests['one'] = TestResult(
          'one',
          'example',
          'fail',
          output: 'expected one',
        );
        await t.pumpWidget(wrap(TaskResultView(ws: ws, run: run)));
        await t.pumpAndSettle();
        await t.tap(find.text('问题 1'));
        await t.pumpAndSettle();
        await t.tap(find.text('failure'));
        await t.pumpAndSettle();
        expect(ws.active?.file?.path, '/project/file.dart');
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        ws.dispose();
        app.dispose();
        input.dispose();
      },
    );
  }

  testWidgets('editor F9 and visible gutter share persisted breakpoint state', (
    t,
  ) async {
    final input = InputMode(),
        app = WorkspaceApp(wire: _Link()),
        ws = Workspace(app, 'server');
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: FileEditor(ws: ws, root: 'home', path: '/project/main.dart'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(CodeEditor), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.f9);
    await t.pumpAndSettle();
    expect(ws.debugger.breakpoints.single.line, 1);
    expect(t.takeException(), isNull);
    await t.tapAt(
      t.getTopLeft(find.byType(BreakpointGutter)) + const Offset(10, 8),
    );
    await t.pumpAndSettle();
    expect(ws.debugger.breakpoints, isEmpty);
    await t.pumpWidget(const SizedBox());
    ws.dispose();
    app.dispose();
    input.dispose();
  });

  testWidgets('language edit review accepts buffers with undo', (t) async {
    final input = InputMode(),
        app = WorkspaceApp(wire: _Link()),
        ws = Workspace(app, 'server');
    final doc = ws.documents.open('home', '/project/main.dart');
    await doc.load();
    final plan = DocumentEditPlan([
      PlannedDocumentEdit(doc, doc.version, doc.text, 'formatted\n'),
    ], active: () => true);
    var accepted = false;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: InputMode.scope(
          mode: input,
          child: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  accepted = await reviewDocumentEdits(c, plan);
                  if (accepted) plan.apply();
                },
                child: const Text('review'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('review'));
    // Diff computation runs in a real isolate, independently of widget fake time.
    await t.pump();
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pump();
    expect(t.takeException(), isNull);
    await t.tap(find.text('接受全部修改'));
    await t.pumpAndSettle();
    expect(accepted, isTrue);
    expect(doc.text, 'formatted\n');
    doc.controller.undo();
    expect(doc.text, 'synthetic original\n');
    await t.pumpWidget(const SizedBox());
    ws.dispose();
    app.dispose();
    input.dispose();
  });
}
