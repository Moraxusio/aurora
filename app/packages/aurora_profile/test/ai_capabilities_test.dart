import 'dart:convert';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:test/test.dart';

void main() {
  test(
    'model context/output overrides survive profile and wire resolution',
    () {
      final original = AiProvider(
        id: 'p',
        name: 'fixture',
        model: 'm',
        contextWindow: 32000,
        maxTokens: 4096,
        modelContextWindows: {'m': 64000},
        modelOptions: {
          'm': AiModelOptions(contextWindow: 128000, maxTokens: 16384),
        },
      );
      final p = AiProvider.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(p.toWireJson()['context_window'], 128000);
      expect(p.toWireJson()['max_tokens'], 16384);
      expect(p.toWireJson(modelOverride: 'other')['context_window'], 32000);
      p.modelOptions['m'] = AiModelOptions();
      expect(p.toWireJson()['max_tokens'], 4096);
      p.contextWindow = 0;
      expect(p.toWireJson()['context_window'], 64000);
      p.authMode = 'chatgpt-device';
      expect(p.toWireJson(), isNot(contains('max_tokens')));
    },
  );
  test('legacy, global and model capabilities resolve in explicit order', () {
    final p = AiProvider(
      id: 'p',
      name: 'fixture',
      model: 'm',
      modelImageSupport: {'m': false},
      modelOptions: {
        'm': AiModelOptions(capabilities: {'shell': true}),
      },
    );
    expect(p.effectiveCapabilities()['image_input'], isFalse);
    final resolved = p.effectiveCapabilities('m', {
      'image_input': true,
      'shell': false,
      'grep': false,
    });
    expect(resolved['image_input'], isTrue);
    expect(resolved['shell'], isTrue);
    expect(resolved['grep'], isFalse);
    expect(p.effectiveCapabilities('other')['shell'], isTrue);
    expect(
      p.toWireJson(capabilityDefaults: {'grep': false})['capabilities'],
      containsPair('grep', false),
    );
  });

  test('custom effort inheritance, mapping, omission and session override', () {
    final p = AiProvider(
      id: 'p',
      name: 'fixture',
      model: 'm',
      reasoningEffort: 'high',
      modelOptions: {
        'm': AiModelOptions(reasoningEfforts: {'max': 'ultra', 'off': ''}),
      },
    );
    expect(p.toWireJson()['reasoning_effort'], 'high');
    p.modelOptions['m']!.reasoningEffort = 'max';
    expect(p.toWireJson()['reasoning_effort'], 'ultra');
    expect(
      p.toWireJson(reasoningOverride: 'experimental')['reasoning_effort'],
      'experimental',
    );
    expect(
      p.toWireJson(reasoningOverride: 'off'),
      isNot(contains('reasoning_effort')),
    );
    expect(
      p.toWireJson(reasoningOverride: ''),
      isNot(contains('reasoning_effort')),
    );
    expect(p.toWireJson(modelOverride: 'other')['reasoning_effort'], 'high');
    p.modelOptions['m']!.reasoningMode = 'disabled';
    expect(
      p.toWireJson(reasoningOverride: 'max'),
      isNot(contains('reasoning_effort')),
    );
  });

  test('profile roundtrip retains per-model options and independent maps', () {
    final ai = AiSettings(
      toolDefaults: {'question': false},
      providers: [
        AiProvider(
          id: 'p',
          name: 'fixture',
          protocol: 'anthropic-messages',
          model: 'm',
          modelOptions: {
            'm': AiModelOptions(
              capabilities: {'image_input': true},
              reasoningEffort: '',
              reasoningEfforts: {'max': 'ultra'},
              reasoningMode: 'anthropic-budget',
              thinkingBudget: 8192,
            ),
          },
        ),
      ],
    );
    final restored = AiSettings.fromJson(
      jsonDecode(jsonEncode(ai.toJson())) as Map<String, dynamic>,
    );
    final p = restored.providers.single;
    expect(restored.toolDefaults, {'question': false});
    expect(p.modelOptions['m']!.reasoningEffort, '');
    expect(p.modelOptions['m']!.thinkingBudget, 8192);
    expect(p.toWireJson()['thinking_budget'], 8192);
    p.modelOptions['m']!.capabilities['image_input'] = false;
    expect(
      ai.providers.single.modelOptions['m']!.capabilities['image_input'],
      isTrue,
    );
    p.authMode = 'chatgpt-device';
    final subWire = p.toWireJson();
    expect(subWire['protocol'], 'openai-responses');
    expect(subWire, isNot(contains('reasoning_mode')));
    expect(subWire, isNot(contains('thinking_budget')));
  });
}
