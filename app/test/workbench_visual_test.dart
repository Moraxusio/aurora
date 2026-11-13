// The real shell, file tree, editor and AI widgets, with memory-only fixtures.
// Screenshots never open a native window or the user's profile/credentials.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/terminal/terminal_feature.dart'
    show openSession;
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/desktop_lifecycle.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/kernel/window_frame.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'ai_feature_test.dart' show FakeAiLink;
import 'support/workspace_fixture.dart';
import 'support/terminal_fixture.dart';

const _code = '''import 'package:flutter/material.dart';

void main() => runApp(const Aurora());

/// Keep the work. Simplify everything around it.
class Aurora extends StatelessWidget {
  const Aurora({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aurora',
      theme: ThemeData.dark(),
      home: const Workbench(),
    );
  }
}

class Workbench extends StatelessWidget {
  const Workbench({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: const [
          ProjectFiles(),
          Expanded(child: Editor()),
        ],
      ),
    );
  }
}
''';

class _IdleStream implements OpStream {
  final done = Completer<Frame?>();
  @override
  Future<Object?> response() async => null;
  @override
  Future<Frame?> read() => done.future;
  @override
  void reset() {
    if (!done.isCompleted) done.complete(null);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _VisualTerminalStream extends MemoryTerminalStream {
  bool painted = false;
  @override
  Future<void> sendJson(Object? data) async {
    await super.sendJson(data);
    if (!painted && (data as Map)['type'] == 'resize') {
      painted = true;
      output(
        '\x1b[38;5;110maurora\x1b[0m  \x1b[38;5;108m~/project\x1b[0m\r\n'
        '\$ flutter test\r\n'
        '\x1b[38;5;108m00:01 +24: All tests passed!\x1b[0m\r\n\r\n'
        '\x1b[38;5;110maurora\x1b[0m  \x1b[38;5;108m~/project\x1b[0m\r\n\$ ',
      );
    }
  }
}

class _VisualLink extends FakeAiLink {
  final Features features;
  final List<MemoryTerminalStream> terminalStreams = [];
  _VisualLink(this.features) {
    pendingPermission = null;
    directories['/project'] = [
      FileTreeLink.dir('src'),
      FileTreeLink.dir('test'),
      FileTreeLink.file('pubspec.yaml'),
      FileTreeLink.file('README.md'),
    ];
    directories['/project/src'] = [
      FileTreeLink.file('main.dart'),
      FileTreeLink.file('workbench.dart'),
      FileTreeLink.file('theme.dart'),
    ];
  }
  @override
  AgentInfo get server => AgentInfo({
    'version': '3.15.0',
    'os': 'linux',
    'arch': 'amd64',
    'caps': <String>[],
  });
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    if (op == 'terminal') {
      final stream = _VisualTerminalStream();
      terminalStreams.add(stream);
      return stream;
    }
    return _IdleStream();
  }

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'session.list') {
      return {
        'sessions': [
          {'name': 'main', 'attached': 1, 'windows': 1},
          {'name': 'server', 'attached': 0, 'windows': 1},
        ],
      };
    }
    if (op == 'agent.services') {
      return {
        'services': [
          for (final id in features.all.map((f) => f.service).toSet())
            {
              'id': id,
              'enabled': true,
              'available': true,
              'ops': [
                for (final f in features.all.where((f) => f.service == id))
                  ...f.ops,
              ],
            },
        ],
      };
    }
    if (op == 'fs.read') {
      return {
        'content': (args as Map)['path'].toString().endsWith('.md')
            ? '# Aurora\n\nA quieter place to build.\n'
            : _code,
        'etag': 'visual-fixture',
      };
    }
    final result = await super.call(op, args, timeout);
    if (op == 'ai.get') {
      final session = (result as Map)['session'] as Map;
      session['title'] = '整理工作台';
      session['todos'] = <Object>[];
      session['runtime'] = {
        'provider_name': 'Demo',
        'model': 'example-model',
        'protocol': 'openai-chat',
      };
      session['context'] = {
        'tokens': 12000,
        'limit': 128000,
        'estimated': true,
      };
      session['messages'] = [
        {
          'id': 'u',
          'role': 'user',
          'parts': [
            {'type': 'text', 'text': '让界面回到内容本身：更直接，也更轻快。'},
          ],
        },
        {
          'id': 'a',
          'role': 'assistant',
          'parts': [
            {
              'type': 'text',
              'text': '## 少一点界面，多一点工作\n\n标签就是入口，不必先理解“编辑组”。\n\n- 拖动标签到边缘，自然分屏。\n- 调整宽度只更新当前视口。\n- 文件、终端与对话留在原处，不重复创建。\n\n更复杂的排布和统计仍然保留，需要时再展开。',
            },
          ],
        },
      ];
    }
    return result;
  }
}

void main() {
  final shots = Platform.environment['AURORA_UI_SHOTS'];
  final frame = GlobalKey(), shell = GlobalKey();
  setUpAll(() async {
    if (shots == null) return;
    final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final flutter = Platform.environment['FLUTTER_ROOT'];
    for (final font in <String, String>{
      Ide.ui: '$windows/Fonts/SegUIVar.ttf',
      'Segoe UI': '$windows/Fonts/segoeui.ttf',
      'Microsoft YaHei UI': '$windows/Fonts/msyh.ttc',
      Ide.mono: '$windows/Fonts/consola.ttf',
      if (flutter != null)
        'MaterialIcons':
            '$flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    }.entries) {
      final file = File(font.value);
      if (file.existsSync()) {
        await (FontLoader(font.key)..addFont(
              Future.value(ByteData.sublistView(file.readAsBytesSync())),
            ))
            .load();
      }
    }
  });
  Future<void> snapshot(WidgetTester t, String name) async {
    if (shots == null) return;
    final boundary =
        frame.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(shots).create(recursive: true);
      await File('$shots/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'real workbench stays quiet, responsive and stateful in both themes',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final features = Features(), input = InputMode(touch: false);
      DesktopLifecycle.frameless.value = true;
      addTearDown(() => DesktopLifecycle.frameless.value = false);
      final link = _VisualLink(features);
      final app = WorkspaceApp(
        wire: link,
        profile: Profile(
          selected: 'server',
          servers: [
            ServerEntry(
              id: 'server',
              name: '开发环境',
              selectedWorkspace: 'a',
              workspaces: [
                ProjectWorkspace(
                  id: 'a',
                  name: 'Aurora',
                  folders: [ref('/project')],
                  view: WorkspaceView(
                    treeSet: true,
                    expanded: [ref('/project'), ref('/project/src')],
                  ),
                ),
              ],
            ),
          ],
          ai: AiSettings(
            providers: [
              AiProvider(id: 'demo', name: 'Demo', model: 'example-model'),
            ],
          ),
        ),
      );
      Future<void> show(Brightness brightness) async {
        await t.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(brightness),
              home: WindowChrome(
                child: InputMode.scope(
                  mode: input,
                  child: Shell(key: shell, app: app, features: features),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      await show(Brightness.dark);
      final ws = (shell.currentState as dynamic).debugWorkspace as Workspace;
      for (final path in [
        '/project/src/main.dart',
        '/project/src/workbench.dart',
        '/project/README.md',
      ]) {
        ws.openTab(fileEditorTab(ws, root: 'home', path: path));
      }
      ws.activate('file:home:/project/src/main.dart');
      await t.pumpAndSettle();
      expect(find.textContaining('编辑组'), findsNothing);
      expect(t.takeException(), isNull);
      await snapshot(t, 'workbench-dark');
      await show(Brightness.light);
      expect(t.takeException(), isNull);
      await snapshot(t, 'workbench-light');
      await show(Brightness.dark);
      openSession(ws, 'main');
      await t.pumpAndSettle();
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byKey(const ValueKey('tab-term:main')), findsNothing);
      await snapshot(t, 'workbench-bottom-terminal');
      await show(Brightness.light);
      await snapshot(t, 'workbench-bottom-terminal-light');
      await show(Brightness.dark);
      ws.openTab(
        EditorTab(
          id: 'ai:ses_1',
          title: '整理工作台',
          icon: Icons.auto_awesome_outlined,
          builder: (_) => AiStudioView(ws: ws, initialSessionId: 'ses_1'),
        ),
      );
      ws.activate('file:home:/project/src/main.dart');
      ws.splitGroup(SplitAxis.horizontal, tabId: 'ai:ses_1');
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await snapshot(t, 'workbench-split-ai');
      ws.setTabPlacement(TabPlacement.right);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await snapshot(t, 'workbench-right-tabs-terminal');
      ws.toggleTerminalMaximized();
      await t.pumpAndSettle();
      await snapshot(t, 'workbench-terminal-maximized');
      ws.hideTerminalPanel();
      ws.arrangeEditors(EditorArrangement.single);
      ws.setTabPlacement(TabPlacement.left);
      await t.pumpAndSettle();
      await snapshot(t, 'workbench-vertical');
      ws.setTabPlacement(TabPlacement.top);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('布局'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await snapshot(t, 'workbench-layout-menu');
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      DesktopLifecycle.frameless.value = false;
      t.view.physicalSize = const Size(390, 760);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await snapshot(t, 'workbench-phone');
      ws.showTerminalPanel();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await snapshot(t, 'workbench-phone-terminal');
      expect(
        link.terminalStreams,
        hasLength(1),
        reason: 'one real terminal widget and attachment across all layouts',
      );
      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      input.dispose();
      features.dispose();
      app.dispose();
    },
  );
}
