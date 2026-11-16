import 'package:aurora_profile/aurora_profile.dart';
import 'package:test/test.dart';

void main() {
  test(
    'extension controls persist but only send new keys to capable agents',
    () {
      final provider = AiProvider(id: 'p', name: 'p', model: 'm');
      provider.modelOptions['m'] = AiModelOptions(
        capabilities: {'mcp': false, 'skill': false},
      );
      final restored = AiProvider.fromJson(provider.toJson());
      expect(restored.effectiveCapabilities()['mcp'], isFalse);
      final old = restored.toWireJson()['capabilities'] as Map;
      expect(old.containsKey('mcp'), isFalse);
      expect(old.containsKey('skill'), isFalse);
      final current =
          restored.toWireJson(extensionCapabilities: true)['capabilities']
              as Map;
      expect(current['mcp'], isFalse);
      expect(current['skill'], isFalse);
      expect(current['read'], isTrue);
    },
  );
}
