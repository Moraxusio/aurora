import 'dart:async';

import 'package:aurora/features/ai/ai_auth.dart';
import 'package:aurora/features/ai/ai_oauth_client.dart';
import 'package:aurora/features/ai/ai_settings_dialog.dart';
import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_feature_test.dart' show FakeAiLink;
import 'support/workspace_fixture.dart';

AiProvider provider({String model = 'gpt-6.1-sol'}) => AiProvider(
  id: 'prov_1',
  name: 'ChatGPT',
  authMode: 'chatgpt-device',
  model: model,
  oauth: const AiOAuthCredential(access: 'old-access-fixture', refresh: 'old-refresh-fixture', expires: 1,transport:'server'),
);

class AuthLink extends FakeAiLink {
  bool networkChoice = false;
  @override AgentInfo get server => AgentInfo({'version': '3.99.0', 'caps': [if (networkChoice) 'ai.network']});
  int refreshCalls = 0, polls = 0;
  bool pending = false, expired = false, failRun = false;
  int deviceLifetimeMs = 900000;
  Completer<Object?>? pollBarrier;
  Completer<Object?>? refreshBarrier;
  Map<String, dynamic> get credential => {
    'access': 'new-access-fixture',
    'refresh': 'new-refresh-fixture',
    'expires': DateTime.now().millisecondsSinceEpoch + 3600000,
  };
  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    if (op.startsWith('ai.auth.')) {
      rpcCalls.add((op, (args as Map).cast<String, dynamic>()));
      if (op == 'ai.auth.refresh') {
        refreshCalls++;
        return refreshBarrier == null ? {'credential': credential} : refreshBarrier!.future;
      }
      if (op == 'ai.auth.begin') {
        return {
          'device_auth_id': 'device-fixture',
          'user_code': 'ABCD-EFGH',
          'url': 'https://auth.openai.com/codex/device',
          'interval_ms': 8000,
          'expires_at': DateTime.now().millisecondsSinceEpoch + (expired ? -1 : deviceLifetimeMs),
        };
      }
      polls++;
      if (pollBarrier != null) return pollBarrier!.future;
      return pending ? {'status': 'pending'} : {'status': 'authorized', 'credential': credential};
    }
    if (op == 'ai.run' && failRun) throw OpError(codeInternal, 'synthetic run failure');
    return super.call(op, args, timeout);
  }
}

class FixtureLocalAuth extends AiOAuthClient {
  final AuthLink link;
  FixtureLocalAuth(this.link);
  @override Future<void> configureProxy() async {}
  @override Future<Map<String,dynamic>> begin() async => (await link.call('ai.auth.begin',{'use_proxy':false}) as Map).cast<String,dynamic>();
  @override Future<Map<String,dynamic>> poll(String device,String code) async => (await link.call('ai.auth.poll',{'device_auth_id':device,'user_code':code}) as Map).cast<String,dynamic>();
}

WorkspaceApp makeApp(AuthLink link, AiProvider p) => WorkspaceApp(
  wire: link,
  profile: Profile(
    servers: [ServerEntry(id: 'server', name: 'fixture')],
    selected: 'server',
    ai: AiSettings(providers: [p], selectedProviderId: p.id),
  ),
);

void main() {
  test('explicit route requires capability and preserves legacy provider settings', () async {
    final link = AuthLink();
    final p = AiProvider(id: 'fixture', name: 'fixture', apiKey: 'synthetic-key', useProxy: true);
    final app = makeApp(link, p);
    addTearDown(app.dispose);
    expect((await prepareAiProvider(app, link, p)).useProxy, isTrue);
    p.proxyMode = 'agent';
    await expectLater(prepareAiProvider(app, link, p), throwsStateError);
    link.networkChoice = true;
    final prepared = await prepareAiProvider(app, link, p);
    expect(prepared.toWireJson()['proxy_mode'], 'agent');
    expect(prepared.apiKey, 'synthetic-key');
  });

  test('server OAuth refresh carries the selected route without replacing API keys', () async {
    final link = AuthLink()..networkChoice = true;
    final p = provider()..proxyMode = 'direct'..apiKey = 'synthetic-retained-key';
    final app = makeApp(link, p);
    addTearDown(app.dispose);
    await prepareAiProvider(app, link, p);
    final sent = link.rpcCalls.singleWhere((r) => r.$1 == 'ai.auth.refresh').$2;
    expect(sent['proxy_mode'], 'direct');
    expect(sent['use_proxy'], isFalse);
    expect(app.profile.ai.activeProvider!.apiKey, 'synthetic-retained-key');
    expect(app.profile.ai.activeProvider!.proxyMode, 'direct');
  });
  test('concurrent refresh saves once and preserves each caller model', () async {
    final link = AuthLink()..refreshBarrier = Completer<Object?>();
    final app = makeApp(link, provider());
    addTearDown(app.dispose);
    final a = prepareAiProvider(app, link, provider());
    final b = prepareAiProvider(app, link, provider(model: 'gpt-5.2-codex'));
    expect(link.refreshCalls, 1);
    link.refreshBarrier!.complete({'credential': link.credential});
    expect((await a).oauth!.refresh, 'new-refresh-fixture');
    expect((await b).model, 'gpt-5.2-codex');
    expect(app.profile.ai.activeProvider!.oauth!.access, 'new-access-fixture');
    expect(app.notifications, 1);
  });
  test('deleted provider cannot be resurrected by a late refresh', () async {
    final link = AuthLink()..refreshBarrier = Completer<Object?>();
    final app = makeApp(link, provider());
    addTearDown(app.dispose);
    final future = prepareAiProvider(app, link, provider());
    final check = expectLater(future, throwsStateError);
    await app.update((p) => p.ai.providers.clear());
    link.refreshBarrier!.complete({'credential': link.credential});
    await check;
    expect(app.profile.ai.providers, isEmpty);
  });
  test('failed credential save refuses to use rotated access', () async {
    final link = AuthLink();
    final app = makeApp(link, provider())..failChanges = true;
    addTearDown(app.dispose);
    await expectLater(prepareAiProvider(app, link, provider()), throwsStateError);
    expect(app.profile.ai.activeProvider!.oauth!.access, 'old-access-fixture');
  });

  Future<void> pumpDialog(WidgetTester t, AuthLink link, void Function(AiOAuthCredential?) onResult) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(await showAiDeviceLogin(ctx, link, useProxy: false,initialTransport:'server'));
              },
              child: const Text('login'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('login'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('device login polls once then returns credential', (t) async {
    final link = AuthLink();
    AiOAuthCredential? result;
    await pumpDialog(t, link, (c) => result = c);
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    expect(link.polls, 0);
    await t.pump(const Duration(seconds: 8));
    await t.pump(const Duration(milliseconds: 300));
    expect(result!.access, 'new-access-fixture');
    expect(link.polls, 1);
  });
  testWidgets('pending polling respects interval and cancellation stops polling', (t) async {
    final link = AuthLink()..pending = true;
    await pumpDialog(t, link, (_) {});
    await t.pump(const Duration(seconds: 7));
    expect(link.polls, 0);
    await t.pump(const Duration(seconds: 1));
    expect(link.polls, 1);
    await t.tap(find.text('取消登录'));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(seconds: 60));
    expect(link.polls, 1);
  });
  testWidgets('expired device response fails without polling', (t) async {
    final link = AuthLink()..expired = true;
    await pumpDialog(t, link, (_) {});
    expect(find.textContaining('设备授权响应无效'), findsOneWidget);
    expect(link.polls, 0);
    await t.tap(find.text('关闭'));
    await t.pump(const Duration(milliseconds: 300));
  });
  testWidgets('device timeout stops pending polls', (t) async {
    final link = AuthLink()
      ..pending = true
      ..deviceLifetimeMs = 15000;
    await pumpDialog(t, link, (_) {});
    await t.pump(const Duration(seconds: 16));
    expect(find.textContaining('设备码已过期'), findsOneWidget);
    final count = link.polls;
    await t.pump(const Duration(seconds: 60));
    expect(link.polls, count);
    await t.tap(find.text('关闭'));
    await t.pump(const Duration(milliseconds: 300));
  });
  testWidgets('cancel ignores an in-flight authorized response', (t) async {
    final link = AuthLink()..pollBarrier = Completer<Object?>();
    AiOAuthCredential? result;
    await pumpDialog(t, link, (c) => result = c);
    await t.pump(const Duration(seconds: 8));
    await t.tap(find.text('取消登录'));
    link.pollBarrier!.complete({'status': 'authorized', 'credential': link.credential});
    await t.pump(const Duration(milliseconds: 300));
    expect(result, isNull);
    expect(t.takeException(), isNull);
  });
  testWidgets('subscription preset logs in and saves before dialog closes', (t) async {
    final link = AuthLink();
    final app = makeApp(link, provider()..oauth = null);
    final ws = Workspace(app, 'server');
    addTearDown(ws.dispose);
    addTearDown(app.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showAiSettingsDialog(ctx, app: app, ws: ws,localAuthFactory:()=>FixtureLocalAuth(link)),
              child: const Text('settings'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('settings'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('ai-device-login')));
    await t.tap(find.byKey(const ValueKey('ai-device-login')));
    await t.pump();
    await t.pump(const Duration(seconds: 8));
    await t.pumpAndSettle();
    expect(app.profile.ai.activeProvider!.oauth!.refresh, 'new-refresh-fixture');
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(app.profile.ai.activeProvider!.oauth!.refresh, 'new-refresh-fixture');
  });
  testWidgets('refresh failure retains prompt and prevents run', (t) async {
    final link = AuthLink();
    final app = makeApp(link, provider())..failChanges = true;
    final ws = Workspace(app, 'server');
    final input = InputMode(touch: false);
    addTearDown(ws.dispose);
    addTearDown(app.dispose);
    addTearDown(input.dispose);
    t.view.physicalSize = const Size(1280, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(body: AiStudioView(ws: ws)),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'keep this prompt');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('keep this prompt'), findsOneWidget);
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.run'), isEmpty);
  });
}
