/// Keys shared with the agent's capability resolver. Missing values inherit.
const aiCapabilityDefaults = <String, bool>{
  'tool_calling': true,
  'image_input': true,
  'pdf_input': true,
  'read': true,
  'glob': true,
  'grep': true,
  'write': true,
  'edit': true,
  'apply_patch': true,
  'shell': true,
  'webfetch': true,
  'websearch': true,
  'todowrite': true,
  'subagent': true,
  'question': true,
  'skill': true,
  'mcp': true,
};

Map<String, bool> aiCapabilityMap(Object? value) => {
  if (value is Map)
    for (final e in value.entries)
      if (aiCapabilityDefaults.containsKey(e.key) && e.value is bool)
        '${e.key}': e.value as bool,
};

/// Explicit per-model overrides, independent of discovered catalog metadata.
class AiModelOptions {
  Map<String, bool> capabilities;

  /// null inherits the connection; empty omits the upstream effort parameter.
  String? reasoningEffort;

  /// Display/selection value -> exact upstream value. Empty means omit.
  Map<String, String> reasoningEfforts;

  /// protocol | disabled | anthropic-adaptive | anthropic-budget
  String reasoningMode;
  int thinkingBudget;

  AiModelOptions({
    Map<String, bool>? capabilities,
    this.reasoningEffort,
    Map<String, String>? reasoningEfforts,
    this.reasoningMode = 'protocol',
    this.thinkingBudget = 0,
  }) : capabilities = capabilities ?? {},
       reasoningEfforts = reasoningEfforts ?? {};

  factory AiModelOptions.fromJson(Map<String, dynamic> j) => AiModelOptions(
    capabilities: aiCapabilityMap(j['capabilities']),
    reasoningEffort: j['reasoning_effort'] as String?,
    reasoningEfforts: {
      if (j['reasoning_efforts'] is Map)
        for (final e in (j['reasoning_efforts'] as Map).entries)
          if (e.value is String) '${e.key}': e.value as String,
    },
    reasoningMode:
        const [
          'disabled',
          'anthropic-adaptive',
          'anthropic-budget',
        ].contains(j['reasoning_mode'])
        ? j['reasoning_mode'] as String
        : 'protocol',
    thinkingBudget: (j['thinking_budget'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
    if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
    if (reasoningEfforts.isNotEmpty) 'reasoning_efforts': reasoningEfforts,
    if (reasoningMode != 'protocol') 'reasoning_mode': reasoningMode,
    if (thinkingBudget > 0) 'thinking_budget': thinkingBudget,
  };
}
