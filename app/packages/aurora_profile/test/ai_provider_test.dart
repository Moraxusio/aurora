import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:test/test.dart';

AiProvider subscription() => AiProvider(
  id: 'subscription-fixture',
  name: 'ChatGPT',
  authMode: 'chatgpt-device',
  model: 'gpt-6.1-sol',
  baseUrl: 'https://untrusted.invalid',
  headers: {'Authorization': 'untrusted-fixture'},
  apiKey: 'unused-fixture',
  oauth: const AiOAuthCredential(
    access: 'access-fixture',
    refresh: 'refresh-fixture',
    expires: 9999999999999,
    accountId: 'account-fixture',
  ),
  modelContextWindows: {'gpt-6.1-sol': 500000, 'gpt-5.2-codex': 272000},
);

void main() {
  test('subscription wire uses access only and refuses custom routing', () {
    final p = subscription();
    final wire = p.toWireJson();
    expect(wire['api_key'], 'access-fixture');
    expect(wire['base_url'], 'https://chatgpt.com/backend-api/codex');
    expect(wire['protocol'], 'openai-responses');
    expect(wire['context_window'], 500000);
    final text = jsonEncode(wire);
    for (final secret in ['refresh-fixture', 'untrusted-fixture', 'unused-fixture', 'untrusted.invalid']) {
      expect(text, isNot(contains(secret)));
    }
    expect(wire.containsKey('oauth'), isFalse);
    expect(wire.containsKey('headers'), isFalse);
  });
  test('model-specific windows survive round trip and switching', () {
    final p = AiProvider.fromJson(subscription().toJson());
    expect(p.oauth!.refresh, 'refresh-fixture');
    expect(p.toWireJson(modelOverride: 'gpt-5.2-codex')['context_window'], 272000);
    expect(p.toWireJson(modelOverride: 'custom').containsKey('context_window'), isFalse);
    p.contextWindow = 64000;
    expect(p.toWireJson(modelOverride: 'custom')['context_window'], 64000);
  });
  test('API key configuration remains compatible and ignores dormant OAuth', () {
    final p = subscription()
      ..authMode = 'bearer'
      ..baseUrl = 'https://gateway.invalid';
    final wire = p.toWireJson();
    expect(wire['api_key'], 'unused-fixture');
    expect(wire['base_url'], 'https://gateway.invalid');
    expect(jsonEncode(wire), isNot(contains('refresh-fixture')));
    expect(AiProvider.fromJson({'id': 'old', 'name': 'Old', 'model': 'gpt-4o'}).oauth, isNull);
  });
  test('OAuth is encrypted at rest, reloads and rejects tampering', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-ai-oauth-test-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/profile.bin';
    final sealer = AndroidSealer(Uint8List.fromList(List.generate(32, (i) => i)));
    final store = await ProfileStore.open(path, sealer);
    await store.update((p) {
      p.ai.providers.add(subscription());
      p.ai.selectedProviderId = 'subscription-fixture';
    });
    await store.close();
    final bytes = await File(path).readAsBytes();
    final raw = latin1.decode(bytes);
    expect(raw, isNot(contains('refresh-fixture')));
    expect(raw, isNot(contains('access-fixture')));
    final reopened = await ProfileStore.open(path, sealer);
    expect(reopened.get().ai.activeProvider!.oauth!.refresh, 'refresh-fixture');
    await reopened.close();
    bytes[bytes.length - 1] ^= 1;
    await File(path).writeAsBytes(bytes);
    await expectLater(ProfileStore.open(path, sealer), throwsA(isA<ProfileUnreadable>()));
  });
}
