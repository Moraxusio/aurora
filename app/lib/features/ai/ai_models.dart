// Wire data models for the built-in OpenCode-compatible AI service (D-104).
import 'dart:convert';
import 'dart:typed_data';

class AiSessionSummary {
  final String id;
  final String parentId;
  String title;
  bool pinned;
  final String root;
  final String workdir;
  String agent;
  String model;
  String preview;
  bool running;
  AiPermissionQuestion? pendingPermission;
  int messageCount;
  int createdAt;
  int updatedAt;

  AiSessionSummary({
    required this.id,
    this.parentId = '',
    required this.title,
    this.pinned = false,
    required this.root,
    required this.workdir,
    required this.agent,
    this.model = '',
    this.preview = '',
    this.running = false,
    this.pendingPermission,
    this.messageCount = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  factory AiSessionSummary.fromJson(Map<String, dynamic> j) => AiSessionSummary(
    id: j['id'] as String? ?? '',
    parentId: j['parent_id'] as String? ?? '',
    title: j['title'] as String? ?? '新会话',
    pinned: j['pinned'] == true,
    root: j['root'] as String? ?? '',
    workdir: j['workdir'] as String? ?? '/',
    agent: j['agent'] as String? ?? 'build',
    model: j['model'] as String? ?? '',
    preview: j['preview'] as String? ?? '',
    running: j['running'] == true,
    pendingPermission: j['pending_permission'] is Map
        ? AiPermissionQuestion.fromJson(
            (j['pending_permission'] as Map).cast<String, dynamic>(),
          )
        : null,
    messageCount: (j['message_count'] as num?)?.toInt() ?? 0,
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
  );
}

/// One hit of `ai.search`: a session whose title or text holds every word.
class AiSearchHit {
  final String sessionId;
  final String title;
  final String workdir;
  final int updatedAt;
  final String snippet;

  const AiSearchHit({
    required this.sessionId,
    required this.title,
    required this.workdir,
    required this.updatedAt,
    required this.snippet,
  });

  factory AiSearchHit.fromJson(Map<String, dynamic> j) => AiSearchHit(
    sessionId: j['session_id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    workdir: j['workdir'] as String? ?? '/',
    updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
    snippet: j['snippet'] as String? ?? '',
  );
}

/// Which day-group a session belongs to in the history list.
String aiDayGroup(int updatedMs, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = DateTime.fromMillisecondsSinceEpoch(updatedMs);
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff < 7) return '最近 7 天';
  if (diff < 30) return '最近 30 天';
  return '更早';
}

class AiTodoItem {
  final String id;
  final String content;
  final String status; // pending | in_progress | completed | cancelled
  final String priority;

  const AiTodoItem({
    required this.id,
    required this.content,
    required this.status,
    this.priority = 'medium',
  });

  factory AiTodoItem.fromJson(Map<String, dynamic> j) => AiTodoItem(
    id: '${j['id'] ?? ''}',
    content: j['content'] as String? ?? '',
    status: j['status'] as String? ?? 'pending',
    priority: j['priority'] as String? ?? 'medium',
  );
}

class AiFileDiff {
  final String file;
  final int additions;
  final int deletions;
  final String status;
  final String patch;

  const AiFileDiff({
    required this.file,
    required this.additions,
    required this.deletions,
    this.status = 'modified',
    this.patch = '',
  });

  factory AiFileDiff.fromJson(Map<String, dynamic> j) => AiFileDiff(
    file: j['file'] as String? ?? '',
    additions: (j['additions'] as num?)?.toInt() ?? 0,
    deletions: (j['deletions'] as num?)?.toInt() ?? 0,
    status: j['status'] as String? ?? 'modified',
    patch: j['patch'] as String? ?? '',
  );
}

class AiStepSnapshot {
  final String start;
  final String end;
  final List<AiFileDiff> files;

  const AiStepSnapshot({this.start = '', this.end = '', this.files = const []});

  factory AiStepSnapshot.fromJson(Map<String, dynamic> j) => AiStepSnapshot(
    start: j['start'] as String? ?? '',
    end: j['end'] as String? ?? '',
    files: [
      for (final f in (j['files'] as List? ?? const []))
        if (f is Map) AiFileDiff.fromJson(f.cast<String, dynamic>()),
    ],
  );
}

class AiUsage {
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;
  final int totalTokens;
  final double cost;

  const AiUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    this.totalTokens = 0,
    this.cost = 0,
  });

  factory AiUsage.fromJson(Map<String, dynamic> j) => AiUsage(
    inputTokens: (j['input_tokens'] as num?)?.toInt() ?? 0,
    outputTokens: (j['output_tokens'] as num?)?.toInt() ?? 0,
    cacheReadTokens: (j['cache_read_tokens'] as num?)?.toInt() ?? 0,
    cacheWriteTokens: (j['cache_write_tokens'] as num?)?.toInt() ?? 0,
    reasoningTokens: (j['reasoning_tokens'] as num?)?.toInt() ?? 0,
    totalTokens: (j['total_tokens'] as num?)?.toInt() ?? 0,
    cost: (j['cost'] as num?)?.toDouble() ?? 0,
  );
}

class AiPart {
  final String type; // text | reasoning | tool-call | tool-result | compaction
  final String id;
  final String text;
  final String toolName;
  final String toolCallId;
  final String inputJson;
  final String output;
  final bool isError;
  final Map<String, dynamic> metadata;
  final String attachmentId, mime, filename;
  final int size;
  final List<AiPart> attachments;

  const AiPart({
    required this.type,
    this.id = '',
    this.text = '',
    this.toolName = '',
    this.toolCallId = '',
    this.inputJson = '',
    this.output = '',
    this.isError = false,
    this.metadata = const {},
    this.attachmentId = '',
    this.mime = '',
    this.filename = '',
    this.size = 0,
    this.attachments = const [],
  });

  factory AiPart.fromJson(Map<String, dynamic> j) {
    var rawInput = '';
    final inp = j['input'];
    if (inp is String) {
      rawInput = inp;
    } else if (inp != null) {
      rawInput = jsonEncode(inp);
    }
    return AiPart(
      type: j['type'] as String? ?? 'text',
      id: j['id'] as String? ?? '',
      text: j['text'] as String? ?? '',
      toolName: j['name'] as String? ?? '',
      toolCallId: j['tool_call_id'] as String? ?? '',
      inputJson: rawInput,
      output: j['output'] as String? ?? '',
      isError: j['is_error'] == true,
      metadata: j['metadata'] is Map
          ? (j['metadata'] as Map).cast<String, dynamic>()
          : const {},
      attachments: [
        for (final a in j['attachments'] as List? ?? const [])
          if (a is Map) AiPart.fromJson(a.cast<String, dynamic>()),
      ],
      attachmentId: j['attachment_id'] as String? ?? '',
      mime: j['mime'] as String? ?? '',
      filename: j['filename'] as String? ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
    );
  }
}

class AiRuntimeInfo {
  final String providerName;
  final String providerId;
  final String model;
  final String protocol;
  final String authMode;
  final String reasoningEffort;
  const AiRuntimeInfo({
    this.providerName = '',
    this.providerId = '',
    this.model = '',
    this.protocol = '',
    this.authMode = '',
    this.reasoningEffort = '',
  });
  factory AiRuntimeInfo.fromJson(Map<String, dynamic> j) => AiRuntimeInfo(
    providerName: j['provider_name'] as String? ?? '',
    providerId: j['provider_id'] as String? ?? '',
    model: j['model'] as String? ?? '',
    protocol: j['protocol'] as String? ?? '',
    authMode: j['auth_mode'] as String? ?? '',
    reasoningEffort: j['reasoning_effort'] as String? ?? '',
  );
  String get label =>
      '${providerName.isEmpty ? '未知提供商' : providerName} / $model${reasoningEffort.isEmpty ? '' : ' · $reasoningEffort'}';
}

class AiContextInfo {
  final int tokens;
  final int limit;
  final int lastInput;
  final bool estimated;
  final String limitSource;
  const AiContextInfo({
    this.tokens = 0,
    this.limit = 0,
    this.lastInput = 0,
    this.estimated = true,
    this.limitSource = 'unknown',
  });
  factory AiContextInfo.fromJson(Map<String, dynamic> j) => AiContextInfo(
    tokens: (j['tokens'] as num?)?.toInt() ?? 0,
    limit: (j['limit'] as num?)?.toInt() ?? 0,
    lastInput: (j['last_input'] as num?)?.toInt() ?? 0,
    estimated: j['estimated'] != false,
    limitSource: j['limit_source'] as String? ?? 'unknown',
  );
  double? get ratio => limit > 0 ? tokens / limit : null;
}

class AiMessage {
  final String id;
  final String sessionId;
  final String role; // user | assistant | tool | compaction
  final String agent;
  final String model;
  final AiRuntimeInfo? runtime;
  final List<AiPart> parts;
  final String finish;
  final String error;
  final AiUsage? usage;
  final AiStepSnapshot? snapshot;
  final int createdAt;

  AiMessage({
    required this.id,
    this.sessionId = '',
    required this.role,
    this.agent = '',
    this.model = '',
    this.runtime,
    required this.parts,
    this.finish = '',
    this.error = '',
    this.usage,
    this.snapshot,
    this.createdAt = 0,
  });

  bool get isSystemReminder =>
      role == 'user' &&
      parts.length == 1 &&
      parts.first.text.trimLeft().startsWith('<system-reminder>');

  factory AiMessage.fromJson(Map<String, dynamic> j) => AiMessage(
    id: j['id'] as String? ?? '',
    sessionId: j['session_id'] as String? ?? '',
    role: j['role'] as String? ?? 'user',
    agent: j['agent'] as String? ?? '',
    model: j['model'] as String? ?? '',
    runtime: j['runtime'] is Map
        ? AiRuntimeInfo.fromJson((j['runtime'] as Map).cast<String, dynamic>())
        : null,
    parts: [
      for (final p in (j['parts'] as List? ?? const []))
        if (p is Map) AiPart.fromJson(p.cast<String, dynamic>()),
    ],
    finish: j['finish'] as String? ?? '',
    error: j['error'] as String? ?? '',
    usage: j['usage'] is Map
        ? AiUsage.fromJson((j['usage'] as Map).cast<String, dynamic>())
        : null,
    snapshot: j['snapshot'] is Map
        ? AiStepSnapshot.fromJson(
            (j['snapshot'] as Map).cast<String, dynamic>(),
          )
        : null,
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
  );
}

class AiSession {
  final String id;
  final String parentId;
  String title;
  String root;
  String workdir;
  String agent;
  String permissionMode;
  String model;
  String protocol;
  List<AiTodoItem> todos;
  AiUsage totalUsage;
  int lastInputTokens;
  AiRuntimeInfo? runtime;
  AiContextInfo? context;
  List<AiMessage> messages;
  int createdAt;
  int updatedAt;

  AiSession({
    required this.id,
    this.parentId = '',
    required this.title,
    required this.root,
    required this.workdir,
    this.agent = 'build',
    this.permissionMode = 'ask',
    this.model = '',
    this.protocol = '',
    List<AiTodoItem>? todos,
    this.totalUsage = const AiUsage(),
    this.lastInputTokens = 0,
    this.runtime,
    this.context,
    List<AiMessage>? messages,
    this.createdAt = 0,
    this.updatedAt = 0,
  }) : todos = todos ?? [],
       messages = messages ?? [];

  factory AiSession.fromJson(Map<String, dynamic> j) => AiSession(
    id: j['id'] as String? ?? '',
    parentId: j['parent_id'] as String? ?? '',
    title: j['title'] as String? ?? '新会话',
    root: j['root'] as String? ?? '',
    workdir: j['workdir'] as String? ?? '/',
    agent: j['agent'] as String? ?? 'build',
    permissionMode: j['permission_mode'] as String? ?? 'ask',
    model: j['model'] as String? ?? '',
    protocol: j['protocol'] as String? ?? '',
    todos: [
      for (final t in (j['todos'] as List? ?? const []))
        if (t is Map) AiTodoItem.fromJson(t.cast<String, dynamic>()),
    ],
    totalUsage: j['total_usage'] is Map
        ? AiUsage.fromJson((j['total_usage'] as Map).cast<String, dynamic>())
        : const AiUsage(),
    lastInputTokens: (j['last_input_tokens'] as num?)?.toInt() ?? 0,
    runtime: j['runtime'] is Map
        ? AiRuntimeInfo.fromJson((j['runtime'] as Map).cast<String, dynamic>())
        : null,
    context: j['context'] is Map
        ? AiContextInfo.fromJson((j['context'] as Map).cast<String, dynamic>())
        : null,
    messages: [
      for (final m in (j['messages'] as List? ?? const []))
        if (m is Map) AiMessage.fromJson(m.cast<String, dynamic>()),
    ],
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
  );
}

class AiPermissionQuestion {
  final String id;
  final String sessionId;
  final String messageId;
  final String callId;
  final String tool;
  final String action;
  final String resource;
  final String reason;

  /// Stable name of [reason] (agent 3.21.1+); empty from older agents.
  final String reasonCode;

  /// What "allow for this session" would remember ("git *" or "*"); empty from
  /// older agents, which is then derived with [alwaysScope].
  final String scope;
  final Map<String, dynamic> metadata;

  const AiPermissionQuestion({
    required this.id,
    required this.sessionId,
    this.messageId = '',
    this.callId = '',
    required this.tool,
    required this.action,
    required this.resource,
    this.reason = '',
    this.reasonCode = '',
    this.scope = '',
    this.metadata = const {},
  });

  factory AiPermissionQuestion.fromJson(Map<String, dynamic> j) =>
      AiPermissionQuestion(
        id: j['id'] as String? ?? '',
        sessionId: j['session_id'] as String? ?? '',
        messageId: j['message_id'] as String? ?? '',
        callId: j['call_id'] as String? ?? '',
        tool: j['tool'] as String? ?? '',
        action: j['action'] as String? ?? '',
        resource: j['resource'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        reasonCode: j['reason_code'] as String? ?? '',
        scope: j['always_scope'] as String? ?? '',
        metadata: j['metadata'] is Map
            ? (j['metadata'] as Map).cast<String, dynamic>()
            : const {},
      );

  /// The reason in Chinese. A code from the agent wins; otherwise the English
  /// text of agents before the code existed is matched, so an old agent reads
  /// the same.
  String get reasonText {
    final code = reasonCode.isNotEmpty ? reasonCode : _codeOfText(reason);
    return switch (code) {
      'file_modification' => '这一步会修改服务器上的文件',
      'shell_command' => '这一步会执行一条命令',
      'high_risk_shell' => '这条命令影响很大，即使在自动模式下也需要你确认',
      'sensitive_file' => '这个文件可能含有密钥或环境凭据',
      'plan_shell' => '规划模式下，会改动系统的命令需要确认',
      'repeated_call' => 'AI 连续三次发出了完全相同的调用，可能陷入循环',
      'plan_read_only' => '规划模式只读，不能修改文件',
      'explore_read_only' || 'explore_shell' => '探索子代理只读',
      _ => reason,
    };
  }

  static String _codeOfText(String text) {
    if (text.startsWith('File modification requires'))
      return 'file_modification';
    if (text.startsWith('Shell command execution requires'))
      return 'shell_command';
    if (text.startsWith('High-impact shell command')) return 'high_risk_shell';
    if (text.startsWith('Accessing potential secret')) return 'sensitive_file';
    if (text.startsWith('Plan mode requires confirmation')) return 'plan_shell';
    if (text.startsWith('Repeated identical tool call') ||
        text.startsWith('Agent invoked the exact same tool'))
      return 'repeated_call';
    return '';
  }

  /// What "allow for this session" covers, in words, for the button.
  String get alwaysLabel {
    final s = scope.isNotEmpty ? scope : alwaysScope(action, resource);
    if (action == 'shell' && s.endsWith(' *') && s != '*') {
      return '本会话始终允许 ${s.substring(0, s.length - 2)} 开头的命令';
    }
    if ((action == 'edit' || action == 'write') && s.endsWith('/*')) {
      final dir = s.substring(0, s.length - 2);
      return '本会话始终允许修改 ${dir.isEmpty ? '当前目录' : '$dir/'} 下的文件';
    }
    if ((action == 'edit' || action == 'write') && s != '*') {
      return '本会话始终允许修改此文件';
    }
    return switch (action) {
      'edit' || 'write' => '本会话始终允许修改文件',
      'shell' => '本会话始终允许执行命令',
      _ => '本会话始终允许',
    };
  }

  /// Mirrors the agent's savePattern for agents that do not send the scope.
  static String alwaysScope(String action, String resource) {
    if (action == 'shell') {
      final words = resource.trim().split(RegExp(r'\s+'));
      if (words.isNotEmpty && words.first.isNotEmpty) return '${words.first} *';
    }
    // Older agents do not send always_scope. Keep their generic wording; new
    // agents send the precise directory or file scope explicitly.
    return '*';
  }
}

class AiAttachment {
  final String kind; // file | git_diff | note
  final String label;
  final String path;
  final String content;
  final Uint8List? bytes;
  final String mime;

  const AiAttachment({
    required this.kind,
    required this.label,
    this.path = '',
    required this.content,
    this.bytes,
    this.mime = 'text/plain',
  });

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'label': label,
    if (path.isNotEmpty) 'path': path,
    'content': content,
  };
}

class LiveToolCall {
  final String callId;
  final String name;
  String inputJson;
  String output;
  bool running;
  bool isError;
  Map<String, dynamic> metadata;

  LiveToolCall({
    required this.callId,
    required this.name,
    this.inputJson = '',
    this.output = '',
    this.running = true,
    this.isError = false,
    this.metadata = const {},
  });
}
