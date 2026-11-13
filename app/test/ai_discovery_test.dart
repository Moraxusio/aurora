import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/ai/ai_model_discovery.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  test('discovery accepts gateway arrays and provider schemas', () {
    for (final json in [
      {
        'data': [
          {'id': 'custom', 'context_window': 32000},
        ],
      },
      {
        'models': [
          {'name': 'models/custom'},
        ],
      },
      [
        {'id': 'custom'},
      ],
      ['custom', 'custom'],
    ]) {
      expect(parseAiModels(json).map((x) => x['id']), ['custom']);
    }
    expect(() => parseAiModels({'error': 'wrong endpoint'}), throwsStateError);
  });
  test(
    'client discovery normalizes endpoint, sends key and falls back to v1',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final paths = <String>[];
        server.listen((req) async {
          paths.add(req.uri.path);
          expect(req.headers.value('authorization'), 'Bearer synthetic-key');
          if (req.uri.path == '/models') {
            req.response.write('<html>web page</html>');
          } else {
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'data': [
                  {'id': 'manual-compatible', 'context_window': 128000},
                ],
              }),
            );
          }
          await req.response.close();
        });
        try {
          final p = AiProvider(
            id: 'p',
            name: 'fixture',
            apiKey: 'synthetic-key',
            baseUrl: 'http://127.0.0.1:${server.port}/chat/completions',
          );
          final list = await discoverAiModels(p);
          expect(paths, ['/models', '/v1/models']);
          expect(list.single['context_window'], 128000);
          expect(p.apiKey, 'synthetic-key');
        } finally {
          await server.close(force: true);
        }
      }, _RealHttp());
    },
  );
  test('client discovery never forwards keys through redirects', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var redirected = false;
      server.listen((req) async {
        if (req.uri.path == '/stolen') redirected = true;
        req.response.statusCode = 302;
        req.response.headers.set('location', '/stolen');
        await req.response.close();
      });
      try {
        await expectLater(
          discoverAiModels(
            AiProvider(
              id: 'p',
              name: 'fixture',
              apiKey: 'synthetic-key',
              baseUrl: 'http://127.0.0.1:${server.port}/v1',
            ),
          ),
          throwsStateError,
        );
        expect(redirected, false);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttp());
  });
  test(
    'legacy entries and encrypted profile fields round-trip without migration',
    () {
      final p = Profile(
        servers: [ServerEntry(id: 'old', name: 'remote')],
        ai: AiSettings(
          providers: [
            AiProvider(
              id: 'p',
              name: 'fixture',
              apiKey: 'synthetic-key',
              oauth: const AiOAuthCredential(
                access: 'access-fixture',
                refresh: 'refresh-fixture',
                expires: 999,
              ),
              headers: {'fixture': 'preserved'},
              models: ['custom'],
            ),
          ],
        ),
      );
      final json = p.toJson();
      p.servers.add(ServerEntry(id: 'local', name: '本机', kind: 'local'));
      final restored = Profile.fromJson(p.toJson());
      expect(restored.servers.first.kind, 'remote');
      expect(restored.servers.last.isLocal, true);
      expect(restored.ai.toJson(), Profile.fromJson(json).ai.toJson());
    },
  );
}
