// Wire data models for the built-in OpenCode-compatible AI service (D-104).
import 'dart:convert';

class AiSessionSummary {
  final String id;
  final String parentId;
  String title;
  final String root;
  final String workdir;
  String agent;
  String model;
  bool running;
  AiPermissionQuestion? pendingPermission;
  int messageCount;
  int updatedAt;

  AiSessionSummary({
    required this.id,
    this.parentId = '',
    required this.title,
    required this.root,
    required this.workdir,
    required this.agent,
    this.model = '',
    this.running = false,
    this.pendingPermission,
    this.messageCount = 0,
    this.updatedAt = 0,
  });

  factory AiSessionSummary.fromJson(Map<String, dynamic> j) => AiSessionSummary(
        id: j['id'] as String? ?? '',
        parentId: j['parent_id'] as String? ?? '',
        title: j['title'] as String? ?? '新会话',
        root: j['root'] as String? ?? '',
        workdir: j['workdir'] as String? ?? '/',
        agent: j['agent'] as String? ?? 'build',
        model: j['model'] as String? ?? '',
        running: j['running'] == true,
        pendingPermission: j['pending_permission'] is Map
            ? AiPermissionQuestion.fromJson((j['pending_permission'] as Map).cast<String, dynamic>())
            : null,
        messageCount: (j['message_count'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      );
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
      metadata: j['metadata'] is Map ? (j['metadata'] as Map).cast<String, dynamic>() : const {},
    );
  }
}

class AiMessage {
  final String id;
  final String sessionId;
  final String role; // user | assistant | tool | compaction
  final String agent;
  final String model;
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
    required this.parts,
    this.finish = '',
    this.error = '',
    this.usage,
    this.snapshot,
    this.createdAt = 0,
  });

  bool get isSystemReminder =>
      role == 'user' && parts.length == 1 && parts.first.text.trimLeft().startsWith('<system-reminder>');

  factory AiMessage.fromJson(Map<String, dynamic> j) => AiMessage(
        id: j['id'] as String? ?? '',
        sessionId: j['session_id'] as String? ?? '',
        role: j['role'] as String? ?? 'user',
        agent: j['agent'] as String? ?? '',
        model: j['model'] as String? ?? '',
        parts: [
          for (final p in (j['parts'] as List? ?? const []))
            if (p is Map) AiPart.fromJson(p.cast<String, dynamic>()),
        ],
        finish: j['finish'] as String? ?? '',
        error: j['error'] as String? ?? '',
        usage: j['usage'] is Map ? AiUsage.fromJson((j['usage'] as Map).cast<String, dynamic>()) : null,
        snapshot: j['snapshot'] is Map ? AiStepSnapshot.fromJson((j['snapshot'] as Map).cast<String, dynamic>()) : null,
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      );
}

class AiSession {
  final String id;
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
  List<AiMessage> messages;
  int createdAt;
  int updatedAt;

  AiSession({
    required this.id,
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
    List<AiMessage>? messages,
    this.createdAt = 0,
    this.updatedAt = 0,
  })  : todos = todos ?? [],
        messages = messages ?? [];

  factory AiSession.fromJson(Map<String, dynamic> j) => AiSession(
        id: j['id'] as String? ?? '',
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
    this.metadata = const {},
  });

  factory AiPermissionQuestion.fromJson(Map<String, dynamic> j) => AiPermissionQuestion(
        id: j['id'] as String? ?? '',
        sessionId: j['session_id'] as String? ?? '',
        messageId: j['message_id'] as String? ?? '',
        callId: j['call_id'] as String? ?? '',
        tool: j['tool'] as String? ?? '',
        action: j['action'] as String? ?? '',
        resource: j['resource'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        metadata: j['metadata'] is Map ? (j['metadata'] as Map).cast<String, dynamic>() : const {},
      );
}

class AiAttachment {
  final String kind; // file | git_diff | note
  final String label;
  final String path;
  final String content;

  const AiAttachment({
    required this.kind,
    required this.label,
    this.path = '',
    required this.content,
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
