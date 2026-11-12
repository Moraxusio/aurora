import 'package:aurora/features/ai/ai_feature.dart';
import 'package:aurora/features/ai/ai_settings_dialog.dart';
import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class FakeAiLink extends FileTreeLink {
  final rpcCalls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic>? pendingPermission = {
    'id': 'perm_1',
    'session_id': 'ses_1',
    'message_id': 'msg_a1',
    'call_id': 'call_2',
    'tool': 'edit',
    'action': 'edit',
    'resource': 'src/main.dart',
    'reason': 'File modification requires approval',
  };

  @override
  Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async {
    throw OpError(codeUnsupported, 'stream stubbed in widget test');
  }

  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    final a = args is Map ? args.cast<String, dynamic>() : <String, dynamic>{};
    rpcCalls.add((op, a));
    switch (op) {
      case 'agent.services':
        return {
          'services': [
            {
              'id': 'ai',
              'enabled': true,
              'available': true,
              'ops': const ['ai.sessions', 'ai.get', 'ai.run', 'ai.stream', 'ai.stop', 'ai.approve', 'ai.revert', 'ai.compact', 'ai.models'],
            },
            {'id': 'files', 'enabled': true, 'available': true, 'ops': const <String>[]},
          ],
        };
      case 'ai.sessions':
        return {
          'sessions': [
            {
              'id': 'ses_1',
              'title': '重构登录接口',
              'root': 'home',
              'workdir': '/project',
              'agent': 'build',
              'model': 'claude-sonnet-4-5',
              'running': true,
              'pending_permission': pendingPermission,
              'message_count': 2,
              'updated_at': 1700000000000,
            },
          ],
        };
      case 'ai.get':
        return {
          'running': pendingPermission != null,
          'pending_permission': pendingPermission,
          'session': {
            'id': 'ses_1',
            'title': '重构登录接口',
            'root': 'home',
            'workdir': '/project',
            'agent': 'build',
            'permission_mode': 'ask',
            'model': 'claude-sonnet-4-5',
            'protocol': 'anthropic-messages',
            'todos': [
              {'id': '1', 'content': '阅读现有鉴权模块', 'status': 'completed', 'priority': 'high'},
              {'id': '2', 'content': '修改 main.dart 参数校验', 'status': 'in_progress', 'priority': 'high'},
            ],
            'total_usage': {'input_tokens': 1200, 'output_tokens': 300, 'cache_read_tokens': 900, 'total_tokens': 1500},
            'messages': [
              {
                'id': 'msg_u1',
                'role': 'user',
                'agent': 'build',
                'parts': [
                  {'type': 'text', 'text': '请检查并更新登录逻辑'},
                ],
                'created_at': 1700000000000,
              },
              {
                'id': 'msg_a1',
                'role': 'assistant',
                'agent': 'build',
                'model': 'claude-sonnet-4-5',
                'parts': [
                  {'type': 'reasoning', 'text': '先读取 src/main.dart 分析结构'},
                  {
                    'type': 'tool-call',
                    'tool_call_id': 'call_1',
                    'name': 'read',
                    'input': {'path': 'src/main.dart'},
                  },
                  {
                    'type': 'tool-result',
                    'tool_call_id': 'call_1',
                    'name': 'read',
                    'output': '1: void main() {}',
                  },
                  {'type': 'text', 'text': '准备更新 `src/main.dart` 的校验逻辑。'},
                ],
                'snapshot': {
                  'start': 'sha_1',
                  'end': 'sha_2',
                  'files': [
                    {'file': 'src/main.dart', 'additions': 4, 'deletions': 1, 'status': 'modified', 'patch': '+checkAuth();'},
                  ],
                },
                'created_at': 1700000005000,
              },
            ],
          },
        };
      case 'ai.approve':
        pendingPermission = null;
        return {'resolved': true};
      case 'ai.run':
        return {
          'session': {
            'id': 'ses_1',
            'title': '重构登录接口',
            'root': 'home',
            'workdir': '/project',
            'agent': a['agent'] ?? 'build',
            'model': 'claude-sonnet-4-5',
            'running': true,
            'message_count': 3,
            'updated_at': 1700000010000,
          },
        };
      case 'ai.models':
        return {
          'models': [
            {'id': 'claude-sonnet-4-5', 'name': 'Claude Sonnet 4.5'},
            {'id': 'gpt-5.2-codex', 'name': 'GPT-5.2 Codex'},
          ],
        };
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  late FakeAiLink link;
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;

  setUp(() {
    link = FakeAiLink();
    final p = Profile(
      servers: [
        ServerEntry(
          id: 'server',
          name: 'fixture',
          workspaces: [ProjectWorkspace(id: 'a', name: 'Alpha', folders: [ref('/project')])],
          selectedWorkspace: 'a',
        ),
      ],
      selected: 'server',
      ai: AiSettings(
        providers: [
          AiProvider(
            id: 'prov_1',
            name: 'OpenCode Gateway',
            protocol: 'anthropic-messages',
            baseUrl: 'https://opencode.ai/zen/v1',
            apiKey: 'sk-opencode-test',
            model: 'claude-sonnet-4-5',
            useProxy: true,
          ),
        ],
        selectedProviderId: 'prov_1',
      ),
    );
    app = WorkspaceApp(profile: p, wire: link);
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
  });

  tearDown(() {
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  Future<void> pumpView(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(1280, 860);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: InputMode.scope(mode: input, child: Scaffold(body: child)),
    ));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('AiSessionSidebar lists remote sessions and opens studio tab', (t) async {
    await pumpView(t, AiSessionSidebar(ws: ws));
    expect(find.text('重构登录接口'), findsOneWidget);
    await t.tap(find.text('重构登录接口'));
    await t.pump(const Duration(milliseconds: 100));
    expect(ws.active?.id, 'ai:ses_1');
  });

  testWidgets('AiStudioView renders OpenCode todos, tools, diffs, approves permission, and sends prompt', (t) async {
    await pumpView(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));

    expect(find.text('任务进度 (1/2)'), findsOneWidget);
    expect(find.text('读取 src/main.dart'), findsOneWidget);
    expect(find.text('本步变更 1 个文件'), findsOneWidget);
    expect(find.text('需要授权执行 edit'), findsOneWidget);

    // Approve pending permission inline
    await t.tap(find.byKey(const ValueKey('ai-approve-once')));
    await t.pump(const Duration(milliseconds: 100));
    final approveCall = link.rpcCalls.where((c) => c.$1 == 'ai.approve').single;
    expect(approveCall.$2['id'], 'perm_1');
    expect(approveCall.$2['allow'], isTrue);

    // Switch to Plan mode and send steering message
    await t.tap(find.text('Build 构建'));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('Plan 规划'), findsOneWidget);

    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), '先输出修改方案');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await t.pump(const Duration(milliseconds: 100));

    final runCall = link.rpcCalls.where((c) => c.$1 == 'ai.run').single;
    expect(runCall.$2['agent'], 'plan');
    expect(runCall.$2['text'], '先输出修改方案');
    final sentProv = runCall.$2['provider'] as Map<String, dynamic>;
    expect(sentProv['protocol'], 'anthropic-messages');
    expect(sentProv['api_key'], 'sk-opencode-test');
    expect(sentProv['use_proxy'], isTrue);
  });

  testWidgets('AiSettingsDialog fetches models via agent and saves sealed provider', (t) async {
    await pumpView(
      t,
      Builder(
        builder: (ctx) => Center(
          child: FilledButton(
            onPressed: () => showAiSettingsDialog(ctx, app: app, ws: ws),
            child: const Text('打开配置'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开配置'));
    await t.pumpAndSettle();

    await t.tap(find.text('拉取模型'));
    await t.pumpAndSettle();
    expect(find.text('已获取 2 个可用模型'), findsOneWidget);
    await t.tap(find.text('gpt-5.2-codex'));
    await t.pump();

    await t.tap(find.byKey(const ValueKey('ai-save-settings')));
    await t.pumpAndSettle();
    expect(app.profile.ai.activeProvider!.model, 'gpt-5.2-codex');
  });
}
