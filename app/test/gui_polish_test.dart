import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/files/file_kind.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/terminal_panel_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/ui/settings_page.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_feature_test.dart' show FakeAiLink;
import 'support/workspace_fixture.dart';
import 'workbench_visual_test.dart' show VisualWorkbenchLink;

class _TrackingApp extends WorkspaceApp {
  int connectCalls = 0;
  _TrackingApp({super.wire});

  @override
  Future<void> connect(String id) async {
    connectCalls++;
  }
}

class _ToolOnlyAiLink extends FakeAiLink {
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'ai.get') {
      return {
        'session': {
          'id': 'ses_1',
          'title': '工具步骤',
          'root': 'home',
          'workdir': '/project',
          'messages': [
            {
              'id': 'msg_u1',
              'role': 'user',
              'parts': [
                {'type': 'text', 'text': '查看 main.dart'},
              ],
            },
            {
              'id': 'msg_a1',
              'role': 'assistant',
              'model': 'gpt-5',
              'usage': {
                'input_tokens': 120,
                'output_tokens': 30,
                'total_tokens': 1500,
              },
              'parts': [
                {
                  'type': 'tool-call',
                  'tool_call_id': 'call_read',
                  'name': 'read',
                  'input': {'path': 'src/main.dart'},
                },
                {
                  'type': 'tool-result',
                  'tool_call_id': 'call_read',
                  'name': 'read',
                  'output': 'void main() {}',
                },
              ],
            },
          ],
          'todos': const <Object>[],
        },
        'running': false,
      };
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  testWidgets(
    'the terminal rail toggle works and connected status opens overview instead of reconnecting',
    (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final features = Features();
      final app = _TrackingApp(wire: VisualWorkbenchLink(features));
      final input = InputMode(touch: false);
      final shellKey = GlobalKey();

      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Shell(key: shellKey, app: app, features: features),
          ),
        ),
      );
      await t.pumpAndSettle();

      final ws = (shellKey.currentState as dynamic).debugWorkspace as Workspace;
      expect(ws.terminalPanel.visible, isFalse);

      await t.tap(find.byTooltip('切换终端面板（Ctrl+J）'));
      await t.pumpAndSettle();
      expect(ws.terminalPanel.visible, isTrue);

      await t.tap(find.byTooltip('切换终端面板（Ctrl+J）'));
      await t.pumpAndSettle();
      expect(ws.terminalPanel.visible, isFalse);

      await t.tap(find.text('已连接'));
      await t.pumpAndSettle();
      expect(app.connectCalls, 0);
      expect(ws.active?.id, 'overview');

      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      features.dispose();
      input.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'terminal has one session switcher and starts with full-width output',
    (t) async {
      final app = WorkspaceApp(wire: FileTreeLink());
      final ws = Workspace(app, 'server');
      ws.openTab(
        EditorTab(
          id: 'term:main',
          area: TabArea.terminal,
          title: 'main',
          icon: Icons.terminal,
          builder: (_) => const SizedBox.expand(),
        ),
      );
      ws.openTab(
        EditorTab(
          id: 'term:build',
          area: TabArea.terminal,
          title: 'build',
          icon: Icons.terminal,
          builder: (_) => const SizedBox.expand(),
        ),
      );
      expect(ws.terminalActiveId, 'term:build');

      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 300,
              child: ListenableBuilder(
                listenable: ws,
                builder: (_, _) => TerminalPanelView(
                  ws: ws,
                  sessionsBuilder: (_) => const Text('all sessions fixture'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('main'), findsNothing);
      expect(find.text('build'), findsOneWidget);
      final selector = find.byKey(const ValueKey('terminal-selector'));
      expect(selector, findsOneWidget);
      expect(find.text('all sessions fixture'), findsNothing);
      final activeViewport = find.byKey(const ValueKey('terminal-viewport-term:build'));
      expect(t.getSize(activeViewport).width, 800);
      await t.tap(selector);
      await t.pumpAndSettle();
      await t.tap(find.text('main'));
      await t.pumpAndSettle();
      expect(ws.terminalActiveId, 'term:main');
      await t.tap(selector);
      await t.pumpAndSettle();
      await t.tap(find.text('管理全部会话'));
      await t.pumpAndSettle();
      expect(find.text('all sessions fixture'), findsOneWidget);
      final viewport = find.byKey(const ValueKey('terminal-viewport-term:main'));
      expect(t.getSize(viewport).width, lessThan(800));
      await t.tap(selector);
      await t.pumpAndSettle();
      await t.tap(find.text('返回输出'));
      await t.pumpAndSettle();
      expect(t.getSize(viewport).width, 800);

      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'unified editor toolbar exposes save, find panel without overflow, and clean find empty text',
    (t) async {
      final link = FileTreeLink();
      final app = WorkspaceApp(wire: link);
      final ws = Workspace(app, 'server');
      final key = GlobalKey<FileEditorState>();

      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: FileEditor(
              key: key,
              ws: ws,
              root: 'home',
              path: '/project/src/main.dart',
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('editor-command-row')), findsOneWidget);
      expect(find.byTooltip('保存修改（Ctrl+S）'), findsNothing);
      expect(find.text('未配置语言服务'), findsNothing);
      expect(find.byTooltip('查找与替换（Ctrl+F）'), findsOneWidget);

      await t.tap(find.byTooltip('查找与替换（Ctrl+F）'));
      await t.pumpAndSettle();
      expect(find.text('无结果'), findsNothing);

      await t.tap(find.byTooltip('替换'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);

      key.currentState!.text = 'modified text\n';
      await t.pumpAndSettle();
      expect(key.currentState!.dirty, isTrue);
      expect(find.byTooltip('保存修改（Ctrl+S）'), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'AI message hides empty copy button, renders token count, and opens referenced files',
    (t) async {
      t.view.physicalSize = const Size(1280, 860);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final link = _ToolOnlyAiLink();
      final input = InputMode(touch: false);
      final app = WorkspaceApp(
        wire: link,
        profile: Profile(
          selected: 'server',
          servers: [
            ServerEntry(
              id: 'server',
              name: 'fixture',
              workspaces: [
                ProjectWorkspace(
                  id: 'a',
                  name: 'Alpha',
                  folders: [ref('/project')],
                ),
              ],
            ),
          ],
          ai: AiSettings(
            providers: [AiProvider(id: 'p1', name: 'Demo', model: 'gpt-5')],
          ),
        ),
      );
      final ws = Workspace(app, 'server');

      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: AiStudioView(ws: ws, initialSessionId: 'ses_1'),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }

      expect(find.byTooltip('复制回答'), findsNothing);
      expect(find.text('1.5k tok'), findsOneWidget);
      expect(find.byTooltip('在编辑器中打开'), findsOneWidget);

      await t.tap(find.byTooltip('在编辑器中打开'));
      await t.pump();
      expect(ws.editorActiveId, 'file:home:/project/src/main.dart');

      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      input.dispose();
      app.dispose();
    },
  );

  testWidgets('settings page removes duplicate AI chat font row', (t) async {
    final app = WorkspaceApp(wire: FileTreeLink());
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: SettingsPage(app: app)),
      ),
    );
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).first, 'AI 对话字号');
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('AI 对话字号'),
      ),
      findsOneWidget,
    );

    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  test('parseWorkspaceFileHref distinguishes workspace files from web URLs', () {
    expect(parseWorkspaceFileHref('https://example.com/a.pdf'), isNull);
    expect(parseWorkspaceFileHref('http://localhost:3000'), isNull);
    expect(parseWorkspaceFileHref('#section-1'), isNull);

    final abs = parseWorkspaceFileHref('/fancy/cvpr/paper.pdf');
    expect(abs?.path, '/fancy/cvpr/paper.pdf');
    expect(abs?.line, isNull);

    final fileUri = parseWorkspaceFileHref('file:///fancy/cvpr/main.tex#L42-L50');
    expect(fileUri?.path, '/fancy/cvpr/main.tex');
    expect(fileUri?.line, 42);

    final winUri = parseWorkspaceFileHref('file:///C:/dev/proj/a%20b.dart#L10C3');
    expect(winUri?.path, 'C:/dev/proj/a b.dart');
    expect(winUri?.line, 10);
    expect(winUri?.col, 3);

    final relLine = parseWorkspaceFileHref('src/main.dart:18:4');
    expect(relLine?.path, 'src/main.dart');
    expect(relLine?.line, 18);
    expect(relLine?.col, 4);
  });

  testWidgets(
    'clicking a Markdown file link in AI reply opens the file in editor instead of only copying',
    (t) async {
      t.view.physicalSize = const Size(1280, 860);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final link = _MarkdownLinkAiLink();
      final input = InputMode(touch: false);
      final app = WorkspaceApp(
        wire: link,
        profile: Profile(
          selected: 'server',
          servers: [
            ServerEntry(
              id: 'server',
              name: 'fixture',
              workspaces: [
                ProjectWorkspace(
                  id: 'a',
                  name: 'Alpha',
                  folders: [ref('/project')],
                ),
              ],
            ),
          ],
          ai: AiSettings(
            providers: [AiProvider(id: 'p1', name: 'Demo', model: 'gpt-5')],
          ),
        ),
      );
      final ws = Workspace(app, 'server');

      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: AiStudioView(ws: ws, initialSessionId: 'ses_links'),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }

      await t.tap(find.text('英文主稿'));
      await t.pump();
      expect(ws.editorActiveId, 'file:home:/project/src/main.dart');

      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      input.dispose();
      app.dispose();
    },
  );
}

class _MarkdownLinkAiLink extends FakeAiLink {
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'ai.get') {
      return {
        'session': {
          'id': 'ses_links',
          'title': '文件链接测试',
          'root': 'home',
          'workdir': '/project',
          'messages': [
            {
              'id': 'msg_u1',
              'role': 'user',
              'parts': [
                {'type': 'text', 'text': '给出文件链接'},
              ],
            },
            {
              'id': 'msg_a1',
              'role': 'assistant',
              'model': 'gpt-5',
              'parts': [
                {
                  'type': 'text',
                  'text': '最终文件：\n\n- [英文主稿](src/main.dart#L3)\n',
                },
              ],
            },
          ],
          'todos': const <Object>[],
        },
        'running': false,
      };
    }
    return super.call(op, args, timeout);
  }
}
