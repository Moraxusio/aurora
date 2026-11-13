import 'package:aurora/features/ai/ai_feature.dart';
import 'package:aurora/features/ai/ai_models.dart';
import 'package:aurora/features/ai/ai_settings_dialog.dart';
import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class FakeAiLink extends FileTreeLink {
  final rpcCalls = <(String, Map<String, dynamic>)>[];
  bool pinned = false;
  String? renamedTo;
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
              'preview': '准备更新 src/main.dart 的校验逻辑。',
              'running': true,
              'pending_permission': pendingPermission,
              'message_count': 2,
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            },
            {
              'id': 'ses_2',
              'title': 'Nginx 调优笔记',
              'pinned': pinned,
              'root': 'home',
              'workdir': '/etc/nginx',
              'agent': 'plan',
              'preview': 'upstream 超时调成 30 秒。',
              'message_count': 4,
              'updated_at': DateTime.now().millisecondsSinceEpoch - 3 * 86400000,
            },
          ],
        };
      case 'ai.update':
        if (a.containsKey('pinned')) pinned = a['pinned'] == true;
        if (a['title'] is String) renamedTo = a['title'] as String;
        return {'session': {'id': a['id'], 'title': renamedTo ?? 'x'}};
      case 'ai.search':
        return {
          'hits': [
            {'session_id': 'ses_2', 'title': 'Nginx 调优笔记', 'workdir': '/etc/nginx', 'updated_at': 1700000000000, 'snippet': '…proxy_read_timeout 30s 解决了 502…'},
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
                  {
                    'type': 'tool-call',
                    'tool_call_id': 'call_ws',
                    'name': 'websearch',
                    'input': {'query': 'dart null safety'},
                  },
                  {
                    'type': 'tool-result',
                    'tool_call_id': 'call_ws',
                    'name': 'websearch',
                    'output': '## [Dart null safety](https://dart.dev/null-safety)',
                    'metadata': {
                      'provider': 'exa',
                      'sources': [
                        {'title': 'Dart null safety', 'url': 'https://dart.dev/null-safety'},
                        {'title': 'Migrating', 'url': 'https://dart.dev/null-safety/migration-guide'},
                      ],
                    },
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

  // A running session shows a spinner that never stops, so pumpAndSettle would
  // time out: pump a fixed number of frames instead.
  Future<void> settle(WidgetTester t, [int frames = 10]) async {
    for (var i = 0; i < frames; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('AiSessionSidebar lists remote sessions and opens studio tab', (t) async {
    await pumpView(t, AiSessionSidebar(ws: ws));
    expect(find.text('重构登录接口'), findsOneWidget);
    await t.tap(find.text('重构登录接口'));
    await t.pump(const Duration(milliseconds: 100));
    expect(ws.active?.id, 'ai:ses_1');
  });

  testWidgets('history groups by day, shows a preview, pins, renames and searches the conversation text', (t) async {
    await pumpView(t, AiSessionSidebar(ws: ws));
    // Day groups and the last line said in each session.
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('最近 7 天'), findsOneWidget);
    expect(find.text('等待你批准：edit'), findsOneWidget, reason: 'a session waiting for approval says so instead of its last line');
    expect(find.text('upstream 超时调成 30 秒。'), findsOneWidget);

    // Pin through the context menu: ai.update carries pinned, nothing else.
    await t.tap(find.byKey(const ValueKey('ai-session-ses_2')), buttons: kSecondaryButton);
    await settle(t);
    await t.tap(find.text('置顶'));
    await settle(t);
    final pin = link.rpcCalls.where((c) => c.$1 == 'ai.update').single.$2;
    expect(pin['id'], 'ses_2');
    expect(pin['pinned'], isTrue);
    expect(pin.containsKey('title'), isFalse);
    expect(find.text('置顶'), findsOneWidget, reason: 'the pinned group header appears');

    // Full-text search: debounced, asks the agent, shows the matching snippet.
    await t.enterText(find.byKey(const ValueKey('ai-history-search')), '502');
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 100));
    final q = link.rpcCalls.where((c) => c.$1 == 'ai.search').single.$2;
    expect(q['query'], '502');
    expect(find.textContaining('proxy_read_timeout'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ai-hit-ses_2')));
    await t.pump(const Duration(milliseconds: 100));
    expect(ws.active?.id, 'ai:ses_2');
  });

  testWidgets('the composer shows the model and thinking strength, and the picker changes both', (t) async {
    await pumpView(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
    expect(find.text('OpenCode Gateway / claude-sonnet-4-5'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ai-model-btn')));
    await settle(t);

    // Fetch the model list through the agent, then choose a model typed or listed.
    await t.tap(find.text('拉取模型'));
    await settle(t);
    expect(find.text('gpt-5.2-codex'), findsOneWidget);
    await t.tap(find.text('深度'));
    await settle(t);
    expect(app.profile.ai.activeProvider!.reasoningEffort, 'high');
    await t.tap(find.text('gpt-5.2-codex'));
    await settle(t);
    expect(app.profile.ai.activeProvider!.model, 'gpt-5.2-codex');
    expect(app.profile.ai.activeProvider!.models, contains('claude-sonnet-4-5'));

    // The composer now names the new model and the strength.
    expect(find.text('OpenCode Gateway / gpt-5.2-codex'), findsOneWidget);
    expect(find.text('深度'), findsOneWidget);

    // And what is sent to the agent carries both.
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'hi');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await t.pump(const Duration(milliseconds: 100));
    final sent = link.rpcCalls.where((c) => c.$1 == 'ai.run').single.$2['provider'] as Map<String, dynamic>;
    expect(sent['model'], 'gpt-5.2-codex');
    expect(sent['reasoning_effort'], 'high');
  });

  testWidgets('a websearch call shows its query, the result count and the sources, and a click copies the link', (t) async {
    await pumpView(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
    expect(find.text('联网搜索「dart null safety」 · 2 个结果'), findsOneWidget);
    await t.tap(find.text('联网搜索「dart null safety」 · 2 个结果'));
    await settle(t);
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('dart.dev'), findsNWidgets(2));
    expect(find.text('Migrating'), findsOneWidget);
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await t.tap(find.byKey(const ValueKey('ai-source-1')));
    await t.pump();
    expect(copied, ['https://dart.dev/null-safety/migration-guide']);
  });

  test('aiDayGroup buckets by calendar day', () {
    final now = DateTime(2026, 11, 12, 15);
    int ms(DateTime d) => d.millisecondsSinceEpoch;
    expect(aiDayGroup(ms(DateTime(2026, 11, 12, 0, 5)), now: now), '今天');
    expect(aiDayGroup(ms(DateTime(2026, 11, 11, 23, 59)), now: now), '昨天');
    expect(aiDayGroup(ms(DateTime(2026, 11, 8)), now: now), '最近 7 天');
    expect(aiDayGroup(ms(DateTime(2026, 10, 20)), now: now), '最近 30 天');
    expect(aiDayGroup(ms(DateTime(2026, 5, 1)), now: now), '更早');
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
    expect(find.text('已获取 2 个模型'), findsOneWidget);
    await t.tap(find.text('gpt-5.2-codex'));
    await t.pump();

    await t.tap(find.byKey(const ValueKey('ai-save-settings')));
    await t.pumpAndSettle();
    expect(app.profile.ai.activeProvider!.model, 'gpt-5.2-codex');
  });
}
