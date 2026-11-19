import 'package:aurora/features/ai/ai_run_options.dart';
import 'package:aurora/features/ai/ai_models.dart';
import 'package:aurora/features/ai/ai_permission_card.dart';
import 'package:aurora/features/ai/ai_session_grants.dart';
import 'package:aurora/features/ai/ai_settings_dialog.dart';
import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_runtime_test.dart' show RuntimeLink;
import 'support/workspace_fixture.dart';

class _PermLink extends RuntimeLink {
  final List<Map<String, dynamic>> grants = [
    {
      'action': 'shell',
      'resource': 'git *',
      'effect': 'allow',
      'expires_at': DateTime.now().add(const Duration(minutes: 45)).millisecondsSinceEpoch,
    },
  ];
  Map<String, dynamic> projectConfig = {
    'version': 1,
    'instructions': <String>[],
    'disabledSkills': <String>[],
    'mcp': <Object>[],
    'budget': {'steps': 60, 'seconds': 900, 'tokens': 500000, 'outputBytes': 2097152},
    'subagents': {
      'enabled': true,
      'maxParallel': 2,
      'maxTotal': 32,
      'readOnly': false,
      'permissionMode': '',
      'allowNetwork': true,
      'allowShell': true,
    },
    'tools': {
      'maxCallsPerStep': 64,
      'repeatLimit': 3,
      'shellDefaultSeconds': 120,
      'shellMaxSeconds': 600,
    },
    'prices': <String, Object?>{},
  };

  @override
  AgentInfo get server => AgentInfo({
    'version': '3.25.0',
    'arch': 'amd64',
    'caps': <String>[
      'ai',
      'ai.extensions',
      'ai.permissions',
      'ai.capabilities',
      'ai.run.options',
    ],
  });

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'ai.permissions') {
      final m = (args as Map?) ?? const {};
      if (m['revoke'] == true) {
        if (m['action'] == '*' && m['resource'] == '*') {
          grants.clear();
        } else {
          grants.removeWhere(
            (g) => g['action'] == m['action'] && g['resource'] == m['resource'],
          );
        }
      }
      return {'grants': List<Map<String, dynamic>>.from(grants)};
    }
    if (op == 'ai.extensions') {
      final m = (args as Map?) ?? const {};
      if (m['config'] is Map) {
        projectConfig = (m['config'] as Map).cast<String, dynamic>();
      }
      return {
        'config': projectConfig,
        'etag': 'etag-1',
        'source': 'project',
        'budget_version': 2,
        'controls_version': 1,
        'instructions': const <Object>[],
        'skills': const <Object>[],
        'available_skills': const <Object>[],
      };
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  test('AiPermissionRule preserves backward-compatible JSON and models role + lifecycle', () {
    final legacy = AiPermissionRule(
      action: 'shell',
      resource: 'git status *',
      effect: 'allow',
    );
    expect(legacy.toJson(), {
      'action': 'shell',
      'resource': 'git status *',
      'effect': 'allow',
    });
    expect(legacy.isExpired, isFalse);

    final future = DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch;
    final past = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    final scoped = AiPermissionRule(
      action: 'network',
      resource: '*',
      effect: 'deny',
      agent: 'subagent',
      expiresAt: future,
      disabled: true,
    );
    final restored = AiPermissionRule.fromJson(scoped.toJson());
    expect(restored.agent, 'subagent');
    expect(restored.expiresAt, future);
    expect(restored.disabled, isTrue);
    expect(restored.isExpired, isFalse);

    final expired = AiPermissionRule(
      action: 'shell',
      resource: '*',
      effect: 'allow',
      expiresAt: past,
    );
    expect(expired.isExpired, isTrue);
  });

  test('AiPermissionQuestion parses subagent context and network_access scope', () {
    final q = AiPermissionQuestion.fromJson({
      'id': 'perm_1',
      'session_id': 'ses_1',
      'tool': 'webfetch',
      'action': 'webfetch',
      'resource': 'https://docs.example.com/api',
      'agent': 'general',
      'is_subagent': true,
      'reason_code': 'network_access',
    });
    expect(q.isSubagent, isTrue);
    expect(q.agent, 'general');
    expect(q.reasonText, contains('外部网络'));
    expect(q.alwaysLabel, '本会话始终允许访问 https://docs.example.com/*');
  });

  testWidgets('AiPermissionCard displays subagent badge when triggered by subagent', (t) async {
    final q = AiPermissionQuestion.fromJson({
      'id': 'perm_2',
      'session_id': 'ses_1',
      'tool': 'shell',
      'action': 'shell',
      'resource': 'npm test',
      'agent': 'general',
      'is_subagent': true,
      'reason_code': 'shell_command',
    });
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: AiPermissionCard(
            question: q,
            workdir: '/project',
            onDecide: ({required bool allow, bool always = false}) {},
          ),
        ),
      ),
    );
    expect(find.text('子代理 · general'), findsOneWidget);
  });

  testWidgets('AiSettingsDialog supports one-click presets, role/lifecycle rule editing, toggle, and expired cleanup', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final link = _PermLink();
    final app = WorkspaceApp(wire: link);
    app.data.ai.permissionRules.add(
      AiPermissionRule(
        action: 'shell',
        resource: 'expired-cmd *',
        effect: 'allow',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 10)).millisecondsSinceEpoch,
      ),
    );
    final ws = Workspace(app, 'server');
    final input = InputMode(touch: false);

    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: AiSettingsDialog(
              app: app,
              ws: ws,
              initialSection: 'execution',
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // Expired rule cleanup button is visible and works.
    expect(find.text('清理 1 条已过期'), findsOneWidget);
    await t.ensureVisible(find.text('清理 1 条已过期'));
    await t.tap(find.text('清理 1 条已过期'));
    await t.pumpAndSettle();
    expect(find.text('expired-cmd *'), findsNothing);

    // Apply "子代理严格隔离" preset and verify rules populated.
    await t.ensureVisible(find.byKey(const ValueKey('ai-preset-isolated-subagent')));
    await t.tap(find.byKey(const ValueKey('ai-preset-isolated-subagent')));
    await t.pumpAndSettle();
    expect(find.text('仅子代理（Explore / General）'), findsAtLeastNWidgets(1));

    // Fill quick template "+ 允许测试命令" and set lifecycle to 24h, then add & save.
    final template = find.text('+ 允许测试命令');
    await t.ensureVisible(template);
    await t.tap(template);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ai-save-rule')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ai-save-settings')));
    await t.pumpAndSettle();

    expect(
      app.profile.ai.permissionRules.any(
        (r) => r.agent == 'subagent' && r.action == 'network' && r.effect == 'deny',
      ),
      isTrue,
    );
    expect(
      app.profile.ai.permissionRules.any(
        (r) => r.action == 'shell' && r.resource == 'npm test *' && r.effect == 'allow',
      ),
      isTrue,
    );

    ws.dispose();
    input.dispose();
    app.dispose();
  });

  testWidgets('AiStudioView filters out disabled and expired permission rules before sending ai.run', (t) async {
    final link = _PermLink();
    final app = WorkspaceApp(wire: link);
    app.data.ai.providers.add(
      AiProvider(
        id: 'p1',
        name: 'Test',
        protocol: 'openai-chat',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'gpt-test',
      ),
    );
    app.data.ai.selectedProviderId = 'p1';
    app.data.ai.permissionRules = [
      AiPermissionRule(action: 'shell', resource: 'git status *', effect: 'allow'),
      AiPermissionRule(action: 'shell', resource: 'npm test *', effect: 'allow', disabled: true),
      AiPermissionRule(
        action: 'webfetch',
        resource: '*',
        effect: 'allow',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 5)).millisecondsSinceEpoch,
      ),
    ];
    final ws = Workspace(app, 'server');
    final input = InputMode(touch: false);

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
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'hello');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await t.pumpAndSettle();

    final runCall = link.rpcCalls.where((c) => c.$1 == 'ai.run').single.$2;
    final sentRules = (runCall['permission_rules'] as List).cast<Map>();
    expect(sentRules, hasLength(1));
    expect(sentRules.single['resource'], 'git status *');

    await t.pumpWidget(const SizedBox());
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  testWidgets('showAiSessionGrants displays expiry and supports revoking all grants', (t) async {
    final link = _PermLink();
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showAiSessionGrants(ctx, link, 'ses_1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    expect(find.textContaining('分钟后过期'), findsOneWidget);
    expect(find.text('全部撤销'), findsOneWidget);

    await t.tap(find.text('全部撤销'));
    await t.pumpAndSettle();
    expect(link.grants, isEmpty);
    expect(find.text('本会话暂无记住的授权。'), findsOneWidget);
  });

  testWidgets('AiSessionPolicyEditor exposes subagent permissionMode, allowNetwork, and allowShell controls', (t) async {
    final policy = AiSessionPolicy();
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (_, setState) => AiSessionPolicyEditor(
                policy: policy,
                onChanged: () => setState(() {}),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('子代理默认权限策略'), findsOneWidget);
    expect(find.text('允许子代理访问外部网络'), findsOneWidget);
    expect(find.text('允许子代理执行 Shell 命令'), findsOneWidget);

    await t.ensureVisible(find.text('允许子代理访问外部网络'));
    await t.tap(find.text('允许子代理访问外部网络'));
    await t.pumpAndSettle();

    expect(policy.subagentsAllowNetwork, isFalse);
  });

  testWidgets('AiStudioView sends orchestrator conductor and musician personas and model permission rules', (t) async {
    final link = _PermLink();
    final app = WorkspaceApp(wire: link);
    final p1 = AiProvider(
      id: 'p1',
      name: 'Primary',
      protocol: 'openai-chat',
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-1',
      model: 'gpt-conductor',
      modelOptions: {
        'gpt-conductor': AiModelOptions(
          permissionMode: 'full_access',
          permissionRules: [
            AiPermissionRule(action: 'shell', resource: 'git status *', effect: 'allow'),
          ],
        ),
      },
    );
    final p2 = AiProvider(
      id: 'p2',
      name: 'Fast',
      protocol: 'anthropic-messages',
      baseUrl: 'https://api.anthropic.com/v1',
      apiKey: 'sk-2',
      model: 'claude-musician',
    );
    final conductor = AiPersona(
      id: 'per_cond',
      name: '架构指挥',
      providerId: 'p1',
      model: 'gpt-conductor',
      reasoningEffort: 'high',
      permissionMode: 'full_access',
    );
    final musician = AiPersona(
      id: 'per_mus',
      name: '执行乐手',
      providerId: 'p2',
      model: 'claude-musician',
      reasoningMode: 'anthropic-budget',
      thinkingBudget: 2048,
      permissionMode: 'auto',
      permissionRules: [
        AiPermissionRule(action: 'network', resource: '*', effect: 'deny'),
      ],
    );
    app.data.ai = AiSettings(
      providers: [p1, p2],
      selectedProviderId: 'p1',
      defaultAgent: 'orchestrator',
      personas: [conductor, musician],
      orchestratorConductorPersonaId: 'per_cond',
      orchestratorMusicianPersonaId: 'per_mus',
    );
    final ws = Workspace(app, 'server');
    final input = InputMode(touch: false);

    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: AiStudioView(ws: ws),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('ai-conductor-pill')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-musician-pill')), findsOneWidget);

    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'orchestrate');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await t.pumpAndSettle();

    final runCall = link.rpcCalls.where((c) => c.$1 == 'ai.run').single.$2;
    expect(runCall['agent'], 'orchestrator');
    expect(runCall['permission_mode'], 'full_access');
    expect((runCall['provider'] as Map)['model'], 'gpt-conductor');
    expect((runCall['provider'] as Map)['reasoning_effort'], 'high');
    expect((runCall['subagent_provider'] as Map)['model'], 'claude-musician');
    expect((runCall['subagent_provider'] as Map)['thinking_budget'], 2048);
    expect(runCall['subagent_permission_mode'], 'auto');
    expect((runCall['subagent_permission_rules'] as List), hasLength(1));

    await t.pumpWidget(const SizedBox());
    ws.dispose();
    input.dispose();
    app.dispose();
  });
}
