import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/ai/ai_auth.dart';
import 'package:aurora/features/ai/ai_oauth_client.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_auth_test.dart' show AuthLink, makeApp, provider;

class _RealHttp extends HttpOverrides {}

class _LocalAuth extends AiOAuthClient {
  Completer<Map<String, dynamic>>? beginBarrier;
  bool closed = false;
  @override
  Future<void> configureProxy() async {}
  @override
  Future<Map<String, dynamic>> begin() =>
      beginBarrier?.future ??
      Future.value({
        'device_auth_id': 'local-device-fixture',
        'user_code': 'LOCAL-CODE',
        'expires_at': DateTime.now().millisecondsSinceEpoch + 900000,
        'interval_ms': 8000,
      });
  @override
  Future<AiOAuthCredential> refresh(AiOAuthCredential previous) async => AiOAuthCredential(
    access: 'local-new-access',
    refresh: 'local-new-refresh',
    expires: DateTime.now().millisecondsSinceEpoch + 3600000,
    transport: 'client',
  );
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _RejectedLocalAuth extends _LocalAuth {
  @override
  Future<Map<String, dynamic>> begin() async => throw StateError('获取设备码被拒绝（HTTP 403，网页安全验证），请切换授权出口后重试');
}

void main() {
  test('client device flow uses local HTTP, exchanges verifier, extracts account and refreshes', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        final text = await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/usercode')) {
          expect((jsonDecode(text) as Map)['client_id'], AiOAuthClient.clientId);
          request.response.write(jsonEncode({'device_auth_id': 'device', 'user_code': 'CODE', 'interval': 5}));
        } else if (request.uri.path.endsWith('/deviceauth/token')) {
          expect((jsonDecode(text) as Map)['device_auth_id'], 'device');
          request.response.write(jsonEncode({'authorization_code': 'code', 'code_verifier': 'verifier'}));
        } else {
          final form = Uri.splitQueryString(text);
          expect(form['client_id'], AiOAuthClient.clientId);
          if (form['grant_type'] == 'authorization_code') {
            expect(form['code_verifier'], 'verifier');
            expect(form['redirect_uri'], endsWith('/deviceauth/callback'));
          } else {
            expect(form['refresh_token'], 'refresh-fixture');
          }
          final jwt =
              'e30.${base64Url.encode(utf8.encode(jsonEncode({
                'https://api.openai.com/auth': {'chatgpt_account_id': 'account-fixture'},
              }))).replaceAll('=', '')}.fixture';
          request.response.write(
            jsonEncode({
              'access_token': 'access-fixture',
              'refresh_token': 'refresh-fixture',
              'expires_in': 3600,
              'id_token': jwt,
            }),
          );
        }
        await request.response.close();
      });
      final client = AiOAuthClient(testIssuer: Uri.parse('http://127.0.0.1:${server.port}'));
      try {
        final begin = await client.begin();
        expect(begin['interval_ms'], 8000);
        final result = await client.poll('device', 'CODE');
        final credential = AiOAuthCredential.fromJson((result['credential'] as Map).cast<String, dynamic>());
        expect(credential.accountId, 'account-fixture');
        expect(credential.transport, 'client');
        expect((await client.refresh(credential)).access, 'access-fixture');
      } finally {
        client.close();
        await server.close(force: true);
        await subscription.cancel();
      }
    }, _RealHttp());
  });
  test('403 at device begin is a network-stage rejection and does not expose upstream bodies', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.html;
        request.response.write('private-upstream-secret');
        await request.response.close();
      });
      final client = AiOAuthClient(testIssuer: Uri.parse('http://127.0.0.1:${server.port}'));
      try {
        await expectLater(
          client.begin(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'safe description',
              allOf(contains('获取设备码'), contains('网页安全验证'), isNot(contains('private-upstream-secret'))),
            ),
          ),
        );
      } finally {
        client.close();
        await server.close(force: true);
      }
    }, _RealHttp());
  });
  test('pending poll does not exchange a token and redirects are never followed', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var redirected = false;
      server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path.endsWith('/deviceauth/token')) {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{}');
        } else if (request.uri.path == '/redirect-target') {
          redirected = true;
        } else {
          request.response.statusCode = 307;
          request.response.headers.set('Location', '/redirect-target');
        }
        await request.response.close();
      });
      final client = AiOAuthClient(testIssuer: Uri.parse('http://127.0.0.1:${server.port}'));
      try {
        expect((await client.poll('device', 'code'))['status'], 'pending');
        await expectLater(client.begin(), throwsStateError);
        expect(redirected, isFalse);
      } finally {
        client.close();
        await server.close(force: true);
      }
    }, _RealHttp());
  });
  test('client refresh never sends refresh through agent RPC', () async {
    final link = AuthLink();
    final p = provider()
      ..oauth = const AiOAuthCredential(access: 'old', refresh: 'refresh', expires: 1, transport: 'client');
    final app = makeApp(link, p);
    addTearDown(app.dispose);
    final local = _LocalAuth();
    final prepared = await prepareAiProvider(app, link, p, localFactory: () => local);
    expect(prepared.oauth!.access, 'local-new-access');
    expect(app.profile.ai.activeProvider!.oauth!.transport, 'client');
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.auth.refresh'), isEmpty);
    expect(local.closed, isTrue);
  });
  testWidgets('default auth is local and switching to server ignores the late local result', (t) async {
    final local = _LocalAuth()..beginBarrier = Completer<Map<String, dynamic>>();
    final link = AuthLink();
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAiDeviceLogin(context, link, useProxy: false, localFactory: () => local),
              child: const Text('login'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('login'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.auth.begin'), isEmpty);
    await t.tap(find.byKey(const ValueKey('ai-auth-transport-client')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('服务器网络 / 服务器代理出口').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(local.closed, isTrue);
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    local.beginBarrier!.complete({
      'device_auth_id': 'stale',
      'user_code': 'STALE',
      'expires_at': DateTime.now().millisecondsSinceEpoch + 900000,
      'interval_ms': 8000,
    });
    await t.pump();
    expect(find.text('STALE'), findsNothing);
    await t.tap(find.text('取消登录'));
    await t.pump(const Duration(milliseconds: 300));
  });
  testWidgets('auth rejection can be retried and its dialog fits scaled mobile text', (t) async {
    t.view.physicalSize = const Size(390, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    var attempts = 0;
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.4)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAiDeviceLogin(
                context,
                null,
                useProxy: false,
                localFactory: () {
                  attempts++;
                  return attempts == 1 ? _RejectedLocalAuth() : _LocalAuth();
                },
              ),
              child: const Text('login'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('login'));
    await t.pumpAndSettle();
    expect(find.textContaining('HTTP 403'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.ensureVisible(find.text('重新获取设备码'));
    await t.tap(find.text('重新获取设备码'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('LOCAL-CODE'), findsOneWidget);
    expect(attempts, 2);
    await t.tap(find.text('取消登录'));
    await t.pump(const Duration(milliseconds: 300));
  });
}
