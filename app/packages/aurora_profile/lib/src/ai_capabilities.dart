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

/// One ordered permission rule. Rules are evaluated in order and the last
/// matching rule wins, following OpenCode's permission model. Project rules
/// are bound to both the server and project; unbound legacy rules do not leak.
class AiPermissionRule {
  String action;
  String resource;
  String effect; // allow | ask | deny
  String scope; // global | project
  String serverId;
  String projectId;
  String agent; // '' | '*' | 'primary' | 'subagent' | 'build' | 'plan' | 'orchestrator' | 'explore' | 'general'
  int expiresAt; // unix millis; 0 = permanent
  bool disabled;

  AiPermissionRule({
    required this.action,
    required this.resource,
    required this.effect,
    this.scope = 'global',
    this.serverId = '',
    this.projectId = '',
    this.agent = '',
    this.expiresAt = 0,
    this.disabled = false,
  });

  bool get isExpired =>
      expiresAt > 0 && DateTime.now().millisecondsSinceEpoch >= expiresAt;

  factory AiPermissionRule.fromJson(Map<String, dynamic> j) => AiPermissionRule(
    action: j['action'] as String? ?? 'shell',
    resource: j['resource'] as String? ?? '*',
    effect: const ['allow', 'ask', 'deny'].contains(j['effect'])
        ? j['effect'] as String
        : 'ask',
    scope: j['scope'] == 'project' ? 'project' : 'global',
    serverId: j['server_id'] as String? ?? '',
    projectId: j['project_id'] as String? ?? '',
    agent: j['agent'] as String? ?? '',
    expiresAt: (j['expires_at'] as num?)?.toInt() ?? 0,
    disabled: j['disabled'] == true,
  );

  Map<String, dynamic> toJson() => {
    'action': action,
    'resource': resource,
    'effect': effect,
    if (scope != 'global') 'scope': scope,
    if (serverId.isNotEmpty) 'server_id': serverId,
    if (projectId.isNotEmpty) 'project_id': projectId,
    if (agent.isNotEmpty) 'agent': agent,
    if (expiresAt > 0) 'expires_at': expiresAt,
    if (disabled) 'disabled': true,
  };

  bool appliesTo(String server, String? project) =>
      scope == 'global' ||
      (projectId.isNotEmpty && serverId == server && projectId == project);
}

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
  int contextWindow;
  int maxTokens;

  /// '' (inherit) | 'ask' | 'auto' | 'full_access'
  String permissionMode;

  /// Model-scoped permission rules applied whenever this model runs.
  List<AiPermissionRule> permissionRules;

  AiModelOptions({
    Map<String, bool>? capabilities,
    this.reasoningEffort,
    Map<String, String>? reasoningEfforts,
    this.reasoningMode = 'protocol',
    this.thinkingBudget = 0,
    this.contextWindow = 0,
    this.maxTokens = 0,
    this.permissionMode = '',
    List<AiPermissionRule>? permissionRules,
  }) : capabilities = capabilities ?? {},
       reasoningEfforts = reasoningEfforts ?? {},
       permissionRules = permissionRules ?? [];

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
    contextWindow: (j['context_window'] as num?)?.toInt() ?? 0,
    maxTokens: (j['max_tokens'] as num?)?.toInt() ?? 0,
    permissionMode: const ['ask', 'auto', 'full_access'].contains(j['permission_mode'])
        ? j['permission_mode'] as String
        : '',
    permissionRules: [
      for (final r in (j['permission_rules'] as List? ?? const []))
        if (r is Map) AiPermissionRule.fromJson(r.cast<String, dynamic>()),
    ],
  );

  Map<String, dynamic> toJson() => {
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
    if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
    if (reasoningEfforts.isNotEmpty) 'reasoning_efforts': reasoningEfforts,
    if (reasoningMode != 'protocol') 'reasoning_mode': reasoningMode,
    if (thinkingBudget > 0) 'thinking_budget': thinkingBudget,
    if (contextWindow != 0) 'context_window': contextWindow,
    if (maxTokens != 0) 'max_tokens': maxTokens,
    if (permissionMode.isNotEmpty) 'permission_mode': permissionMode,
    if (permissionRules.isNotEmpty)
      'permission_rules': [for (final r in permissionRules) r.toJson()],
  };
}
