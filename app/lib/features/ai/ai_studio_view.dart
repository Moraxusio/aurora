// Agent Studio editor tab (D-104): OpenCode-compatible AI coding & server agent UI.
// Supports Build/Plan modes, live streaming thinking + tool cards + todo tracker + diffs,
// inline permission approvals, 1-click shadow-git revert, context attachments, and compaction.
import 'dart:async';
import 'dart:convert';

import 'package:aurora_install/aurora_install.dart' show compareVersions;
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../files/file_editor.dart' show openFileAt;
import '../files/file_icons.dart' show FileIcon;
import '../files/file_kind.dart' show parseWorkspaceFileHref;
import '../git/diff_view.dart'
    show DiffLineKind, parseDiff, withoutFileHeader;
import 'ai_model_picker.dart';
import 'ai_auth.dart';
import 'ai_models.dart';
import 'ai_permission_card.dart';
import 'ai_session_grants.dart';
import 'ai_question_dialog.dart';
import 'ai_settings_dialog.dart';
import 'ai_budget_view.dart';
import 'ai_run_options.dart';
import 'ai_attachments.dart';
import 'ai_path_picker.dart';
import 'ai_attachment_tile.dart';
import 'ai_history.dart';
import 'ai_transcript.dart';
import 'ai_work.dart';
import 'ai_workbench.dart';
import 'ai_visuals.dart';

part 'ai_studio_chrome.dart';
part 'ai_studio_composer.dart';
part 'ai_studio_dialogs.dart';
part 'ai_studio_messages.dart';

class _AiPasteIntent extends Intent {
  const _AiPasteIntent();
}

/// The words of the two switches under the input, and of the send button.
/// Chinese first: the English names are the agent's own and stay as a hint.
abstract final class AiComposerText {
  static String agent(String mode, {required bool narrow}) => switch (mode) {
    'plan' => narrow ? '规划' : '规划 · 只读',
    'orchestrator' => narrow ? '编排' : '编排 · 指挥乐手',
    _ => narrow ? '构建' : '构建 · 可改文件',
  };

  static String agentTip(String mode) => switch (mode) {
    'plan' => '规划模式（Plan）：只读文件、讨论方案，不修改任何文件。点击切换为编排',
    'orchestrator' => '编排模式（Orchestrator）：指挥官拆解任务并调度乐手子代理协同执行。点击切换为构建',
    _ => '构建模式（Build）：可以修改文件、运行命令。点击切换为规划',
  };

  static String permission(String mode, {required bool narrow}) =>
      switch (mode) {
        'auto' => narrow ? '自动' : '自动执行',
        'full_access' => narrow ? '完全' : '完全权限',
        _ => narrow ? '询问' : '先询问',
      };

  static String permissionTip(String mode) => switch (mode) {
    'auto' => '自动执行（Auto）：改文件和运行命令不再逐次询问，只有高风险命令仍会确认。点击切换为完全权限',
    'full_access' => '完全权限（Full Access）：免确认自动放行，仅显式拒绝规则与只读护栏仍生效。点击切换为先询问',
    _ => '先询问（Ask）：改文件和运行命令前会让你确认。点击切换为自动执行',
  };

  /// What sending does right now: a new turn, or a nudge into a turn that is running.
  static String send({required bool running, required bool sending}) =>
      sending ? '准备中' : (running ? '补充指令' : '发送');

  static String sendTip({required bool running}) =>
      running ? '把这条消息插入正在进行的任务（Enter）' : '发送（Enter）；Shift+Enter 换行';

  static String hint({required bool running, required String agentMode}) =>
      running
      ? '任务进行中：输入补充指令，回车后会插入当前任务'
      : switch (agentMode) {
          'plan' => '规划任务，不修改文件…',
          'orchestrator' => '描述复杂目标，指挥官将拆解并调度乐手协同完成…',
          _ => '向 AI 提问，或描述要完成的任务…',
        };
}

const _aiSlashCommands = <(String, String)>[
  ('/help', '查看可用的会话快捷命令'),
  ('/compact', '压缩当前会话上下文'),
  ('/plan', '切换到规划模式（只读）'),
  ('/build', '切换到构建模式（可修改文件）'),
  ('/orchestrator', '切换到编排模式（指挥调度乐手）'),
  ('/ask', '切换为每次操作前询问'),
  ('/auto', '切换为自动执行（高风险仍会询问）'),
  ('/full', '切换为完全权限（Full Access，免确认放行）'),
  ('/steer', '运行中切为补充指令（下一步优先）'),
  ('/queue', '运行中切为排队发送（当前任务结束后）'),
  ('/stop', '停止当前运行'),
  ('/model', '打开本次对话的模型选择器'),
];

EditorTab aiStudioTab(
  Workspace ws, {
  String? sessionId,
  String title = 'AI 助手',
}) {
  final tabId = sessionId == null ? 'ai:draft:${newId()}' : 'ai:$sessionId';
  return EditorTab(
    id: tabId,
    taskKey: sessionId,
    title: title,
    icon: Icons.auto_awesome_rounded,
    tooltip: 'AI 智能体 · $title',
    builder: (_) => AiStudioView(
      key: ValueKey('${ws.serverId}/$tabId'),
      ws: ws,
      initialSessionId: sessionId,
      tabId: tabId,
    ),
  );
}

class AiStudioView extends StatelessWidget {
  final Workspace ws;
  final String? initialSessionId;
  final VoidCallback? onSessionsChanged;
  final String? tabId;
  const AiStudioView({
    super.key,
    required this.ws,
    this.initialSessionId,
    this.onSessionsChanged,
    this.tabId,
  });
  @override
  Widget build(BuildContext context) => AiWorkbench(
    sessionId: initialSessionId,
    onStopSession: (id) {
      final link = ws.link;
      if (link != null)
        unawaited(ws.guard(() => link.call('ai.stop', {'id': id})));
    },
    conversationBuilder: (work, sessionId, primary) => _AiConversation(
      ws: ws,
      initialSessionId: sessionId,
      onSessionsChanged: onSessionsChanged,
      tabId: primary ? tabId : null,
      work: work,
      primary: primary,
    ),
  );
}

class _AiConversation extends StatefulWidget {
  final Workspace ws;
  final String? initialSessionId;
  final VoidCallback? onSessionsChanged;
  final String? tabId;
  final AiWorkController work;
  final bool primary;

  const _AiConversation({
    required this.ws,
    this.initialSessionId,
    this.onSessionsChanged,
    this.tabId,
    required this.work,
    required this.primary,
  });

  @override
  State<_AiConversation> createState() => _AiStudioViewState();
}

class _AiStudioViewState extends State<_AiConversation> {
  String? _sessionId;
  AiSession? _session;
  bool _loading = false;
  bool _running = false;
  String? _error;

  String _root = '';
  String _workdir = '/';
  List<Map<String, dynamic>> _roots = [];

  String _agentMode = 'build'; // 'build' | 'plan' | 'orchestrator'
  String _permMode = 'ask'; // 'ask' | 'auto' | 'full_access'
  String _lastSettingsPermMode = 'ask';
  String _lastSettingsPermRules = '[]';
  Future<void> _permissionUpdate = Future<void>.value();
  String _deliveryMode = 'steer'; // 'steer' | 'queue'
  AiSessionPolicy _sessionPolicy = AiSessionPolicy();

  // Live streaming buffers for the active step
  String _liveReasoning = '';
  String _liveText = '';
  String _liveCompaction = '';
  final List<LiveToolCall> _liveTools = [];
  final _permissions = <String, AiPermissionQuestion>{};
  AiPermissionQuestion? get _pendingPerm => _permissions.values.firstOrNull;
  set _pendingPerm(AiPermissionQuestion? value) {
    if (value != null) {
      _permissions[value.id] = value;
    } else if (_permissions.isNotEmpty) {
      _permissions.remove(_permissions.keys.first);
    }
  }

  Map<String, dynamic>? _pendingQuestion;
  final Set<String> _childQuestions = {};
  int _questionGeneration = 0;
  final _openActions = <String>{};
  void _set(VoidCallback fn) => setState(fn);

  final List<AiAttachment> _attachments = [];
  final Map<AiAttachment, (Link, Map<String, dynamic>)> _uploadedAttachments =
      {};
  bool _pasteBusy = false;
  String? _attachmentNote;
  bool _planExpanded = false;
  Timer? _paintTimer;
  double _chatFontSize = 15;
  AiProvider? _provider;
  String? _activePersonaId;
  String? _conductorPersonaId;
  String? _musicianPersonaId;
  bool _selectionExplicit = false;
  String? _reasoningOverride;
  bool _reasoningOverrideSet = false;
  bool _visible = true;
  final Map<AiMessage, (Ide, bool, double, Link?, Widget)> _messageCache = {};
  final _inputCtl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scrollCtl = AiTranscriptController();

  OpStream? _stream;
  Link? _streamLink;
  bool _disposed = false;
  int _loadGeneration = 0;
  int _streamGeneration = 0;
  Timer? _eventRetry;
  String? _eventNote;
  final Map<String, Map<String, dynamic>> _activities = {};
  final List<Map<String, dynamic>> _loadingEvents = [];
  bool _replayingEvents = false;
  bool _approvalBusy = false;
  String? _approvalError;
  List<Map<String, dynamic>> _inbox = [];
  int _inboxGeneration = 0;
  final _inboxChanges = ValueNotifier<int>(0);
  final _runtimeChanges = ValueNotifier<int>(0);
  bool _inboxBusy = false;
  String? _inboxError;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.initialSessionId;
    if (ws.app.ready) {
      final ai = ws.app.aiSettings;
      _agentMode = ai.defaultAgent;
      _activePersonaId =
          ai.activePersonaId ?? ai.personas.firstOrNull?.id;
      _deliveryMode = ai.followUp;
      _conductorPersonaId = ai.orchestratorConductorPersonaId;
      _musicianPersonaId = ai.orchestratorMusicianPersonaId;
      _permMode = _lastSettingsPermMode = _settingsPermissionMode;
      _lastSettingsPermRules = jsonEncode(_effectivePermissionRules());
      _sessionPolicy = ai.defaultPolicy.copy();
      final initial = ai.activeProvider;
      _provider = initial == null
          ? null
          : AiProvider.fromJson(initial.toJson());
    }
    _chatFontSize = ws.app.appearance.value.chatFont;
    ws.addListener(_onWorkspaceChanged);
    ws.app.addListener(_onAppChanged);
    ws.app.appearance.addListener(_onAppearance);
    _initConnection();
  }

  @override
  void dispose() {
    _disposed = true;
    ws.removeListener(_onWorkspaceChanged);
    ws.app.removeListener(_onAppChanged);
    ws.app.appearance.removeListener(_onAppearance);
    _closeStream();
    _paintTimer?.cancel();
    _inputCtl.dispose();
    _inputFocus.dispose();
    _scrollCtl.dispose();
    _inboxChanges.dispose();
    _runtimeChanges.dispose();
    super.dispose();
  }

  void _onAppChanged() {
    if (!mounted) return;
    final ai = ws.app.ready ? ws.app.aiSettings : AiSettings();
    setState(() {
      _messageCache.clear();
      final previous = _provider;
      final live = ai.providers.where((p) => p.id == previous?.id).firstOrNull;
      final source = live ?? (!_selectionExplicit ? ai.activeProvider : null);
      _provider = source == null ? null : AiProvider.fromJson(source.toJson());
      if (live != null && previous != null) _provider!.model = previous.model;
      if (_sessionPolicy.isDefault) {
        _sessionPolicy = ai.defaultPolicy.copy();
      }
    });
    _refreshEffectivePermissions();
  }

  String get _settingsPermissionMode {
    final mode = _primaryPersona?.permissionMode ?? '';
    return mode.isNotEmpty
        ? mode
        : ws.app.ready
        ? ws.app.aiSettings.permissionMode
        : 'ask';
  }

  List<Map<String, dynamic>> _effectivePermissionRules() {
    final project = ws.project;
    final path = _root.isEmpty ? null : WorkspacePath(root: _root, path: _workdir);
    final projectId = path != null && project?.folders.any((f) => f.contains(path)) == true
        ? project!.id
        : null;
    return [
      if (ws.app.ready)
        for (final rule in ws.app.aiSettings.permissionRules)
          if (!rule.disabled &&
              !rule.isExpired &&
              rule.appliesTo(ws.serverId, projectId))
            rule.toJson(),
      for (final rule in _primaryPersona?.permissionRules ??
          const <AiPermissionRule>[])
        if (!rule.disabled && !rule.isExpired) rule.toJson(),
    ];
  }

  void _refreshEffectivePermissions({bool sendMode = false}) {
    final mode = _settingsPermissionMode;
    final modeChanged = mode != _lastSettingsPermMode;
    final rules = _effectivePermissionRules();
    final encodedRules = jsonEncode(rules);
    final rulesChanged = encodedRules != _lastSettingsPermRules;
    _lastSettingsPermRules = encodedRules;
    if (modeChanged) {
      _lastSettingsPermMode = mode;
      setState(() => _permMode = mode);
    }
    if (sendMode || modeChanged || rulesChanged) {
      _syncLivePermissions(
        mode: sendMode || modeChanged ? _permMode : null,
        rules: rulesChanged ? rules : null,
      );
    }
  }

  void _syncLivePermissions({
    String? mode,
    List<Map<String, dynamic>>? rules,
  }) {
    final link = ws.link, sid = _sessionId;
    if (link == null || sid == null) return;
    final requestedMode = mode == 'full_access' && !_supportsFullAccess(link) ? null : mode;
    if (requestedMode == null && rules == null) return;
    // Preserve update order during rapid toggles and remove only the prompts
    // the agent actually resolved (older agents remove them via tool.done).
    _permissionUpdate = _permissionUpdate.then((_) async {
      if (!identical(link, ws.link) || sid != _sessionId) return;
      try {
        final result = await link.call('ai.update', {
          'id': sid,
          if (requestedMode != null) 'permission_mode': requestedMode,
          if (rules != null) 'permission_rules': rules,
        });
        if (!mounted || !identical(link, ws.link) || sid != _sessionId) return;
        final resolved = result is Map ? result['resolved_ids'] : null;
        if (resolved is List && resolved.isNotEmpty) {
          setState(() {
            for (final id in resolved) {
              _permissions.remove(id);
            }
          });
        }
      } on Object {
        if (mounted && identical(link, ws.link) && sid == _sessionId && _running) {
          ws.toast('即时权限更新未确认，当前任务可能仍按原权限运行。请停止任务并重新连接后检查。', error: true);
        }
      }
    });
  }

  void _onAppearance() {
    final size = ws.app.appearance.value.chatFont;
    if (!mounted || size == _chatFontSize) return;
    if (_visible) {
      setState(() => _chatFontSize = size);
    } else {
      _chatFontSize = size;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
  }

  void _onWorkspaceChanged() {
    if (_disposed || !mounted) return;
    if (!identical(ws.link, _streamLink)) {
      _initConnection();
    }
  }

  Future<void> _initConnection() async {
    _closeStream();
    final link = ws.link;
    if (link == null) {
      if (mounted) setState(() {});
      return;
    }
    _streamLink = link;
    await _loadRoots(link);
    if (_disposed ||
        !mounted ||
        !identical(link, ws.link) ||
        !identical(link, _streamLink))
      return;
    if (_sessionId != null) unawaited(_loadSession(link, _sessionId!));
    unawaited(_refreshQuestion());
    unawaited(_openEventStream(link));
  }

  void _closeStream() {
    _loadingEvents.clear();
    _eventRetry?.cancel();
    _eventRetry = null;
    _loadGeneration++;
    _streamGeneration++;
    _stream?.reset();
    _stream = null;
    _streamLink = null;
  }

  Future<void> _loadRoots(Link link) async {
    try {
      final r = await link.call('fs.roots') as Map;
      final list = [
        for (final x in r['roots'] as List) (x as Map).cast<String, dynamic>(),
      ];
      if (_disposed || !mounted || !identical(link, ws.link)) return;
      setState(() {
        _roots = list;
        if (_root.isEmpty) {
          final projFolder = ws.project?.folders.firstOrNull;
          if (projFolder != null) {
            _root = projFolder.root;
            _workdir = projFolder.path;
          } else if (list.isNotEmpty) {
            _root = list.first['id'] as String? ?? '';
            _workdir = '/';
          }
        }
      });
    } on Object {
      // fs service may be off; fallback to empty root (agent picks first root)
    }
  }

  Future<void> _loadSession(Link link, String id) async {
    if (_disposed || !mounted || !identical(link, ws.link)) return;
    final generation = ++_loadGeneration;
    final workRevision = widget.work.revisionFor(id);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await loadAiHistory(link, id);
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(link, ws.link))
        return;
      final sess = AiSession.fromJson(
        (res['session'] as Map).cast<String, dynamic>(),
      );
      final running = res['running'] == true;
      final initialLoad = _session == null;
      final pending = res['pending_permission'] is Map
          ? AiPermissionQuestion.fromJson(
              (res['pending_permission'] as Map).cast<String, dynamic>(),
            )
          : null;
      setState(() {
        _session = sess;
        _inbox = [
          for (final item in ((res['session'] as Map)['inbox'] as List? ?? []))
            if (item is Map) item.cast<String, dynamic>(),
        ];
        _messageCache.clear();
        _running = running;
        _permissions.clear();
        _childQuestions.clear();
        if (res['pending_permissions'] is List) {
          for (final q in res['pending_permissions'] as List) {
            if (q is Map)
              _pendingPerm = AiPermissionQuestion.fromJson(
                q.cast<String, dynamic>(),
              );
          }
        } else if (pending != null) {
          _pendingPerm = pending;
        }
        _activities.clear();
        for (final a in (res['activities'] as List? ?? const [])) {
          if (a is Map) {
            final row = a.cast<String, dynamic>();
            _activities['${row['session_id']}:${row['tool_call_id']}'] = row;
          }
        }
        _root = sess.root;
        _workdir = sess.workdir;
        if (initialLoad) {
          _agentMode = ['plan', 'explore', 'orchestrator'].contains(sess.agent)
              ? sess.agent
              : 'build';
          if (sess.permissionMode.isNotEmpty) _permMode = sess.permissionMode;
          _lastSettingsPermMode = _settingsPermissionMode;
        }
        _lastSettingsPermRules = jsonEncode(_effectivePermissionRules());
        if (!_selectionExplicit &&
            sess.runtime?.providerId.isNotEmpty == true) {
          final source = ws.app.aiSettings.providers
              .where((p) => p.id == sess.runtime!.providerId)
              .firstOrNull;
          if (source != null) {
            _provider = AiProvider.fromJson(source.toJson())
              ..model = sess.runtime!.model;
            _selectionExplicit = true;
          }
        }
        _loading = false;
      });
      _updateTabTitle(sess.title);
      _inboxChanges.value++;
      _runtimeChanges.value++;
      if (widget.primary || widget.work.revisionFor(id) == workRevision) {
        widget.work.hydrate(
          sess,
          res['activities'] as List? ?? const [],
          primary: widget.primary,
          running: running,
          waiting: pending != null,
        );
      }
      if (widget.primary) unawaited(_recoverChildWork(link, generation));
      _replayLoadingEvents();
      unawaited(_refreshQuestion());
      _scrollToBottom();
    } on Object catch (e) {
      if (mounted &&
          generation == _loadGeneration &&
          identical(link, ws.link)) {
        setState(() {
          _error = e is OpError
              ? e.message
              : e is StateError
              ? e.message
              : '会话加载失败，历史和输入均已保留，请重试';
          _loading = false;
        });
        if (_session != null) _replayLoadingEvents();
      }
    }
  }

  void _updateTabTitle(String title) {
    if (!widget.primary) return;
    final tabId =
        widget.tabId ??
        (widget.initialSessionId == null
            ? 'ai:new'
            : 'ai:${widget.initialSessionId}');
    ws.updateTabTitle(tabId, title);
  }

  Future<void> _recoverChildWork(Link link, int generation) async {
    final ids = widget.work.items.values
        .where(
          (item) =>
              item.sessionId != _sessionId &&
              item.status == AiWorkStatus.interrupted,
        )
        .map((item) => item.sessionId)
        .toSet();
    for (final id in ids) {
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(link, ws.link))
        return;
      final revision = widget.work.revisionFor(id);
      try {
        final result = await loadAiHistory(link, id);
        if (!mounted ||
            generation != _loadGeneration ||
            !identical(link, ws.link))
          return;
        if (revision != widget.work.revisionFor(id)) continue;
        widget.work.hydrate(
          AiSession.fromJson(
            (result['session'] as Map).cast<String, dynamic>(),
          ),
          result['activities'] as List? ?? const [],
          primary: false,
          running: result['running'] == true,
          waiting: result['pending_permission'] is Map,
        );
      } on Object {
        /* Keep the last output and its unconfirmed/interrupted status. */
      }
    }
  }

  Future<void> _openEventStream(Link link) async {
    final generation = _streamGeneration;
    OpStream? opened;
    try {
      final st = await link.open('ai.stream', {
        if (_sessionId != null) 'session_id': _sessionId,
      });
      opened = st;
      await st.response();
      if (_disposed ||
          !mounted ||
          generation != _streamGeneration ||
          !identical(link, ws.link) ||
          !identical(link, _streamLink))
        return;
      _stream = st;
      if (mounted) setState(() => _eventNote = null);
      if (_sessionId != null) unawaited(_loadSession(link, _sessionId!));
      while (!_disposed) {
        final f = await st.read();
        if (generation != _streamGeneration ||
            !identical(st, _stream) ||
            !identical(link, ws.link))
          break;
        if (f == null) break;
        if (!f.isJson) continue;
        final ev = (f.json() as Map).cast<String, dynamic>();
        _handleStreamEvent(ev);
      }
    } on Object {
      // A single operation stream can fail while the TLS link remains healthy.
    } finally {
      opened?.reset();
      if (opened != null && identical(_stream, opened)) _stream = null;
      if (!_disposed &&
          mounted &&
          generation == _streamGeneration &&
          identical(link, ws.link) &&
          identical(link, _streamLink)) {
        setState(() => _eventNote = '实时状态流中断，正在恢复；请以重新同步结果为准');
        _eventRetry?.cancel();
        _eventRetry = Timer(const Duration(seconds: 3), () {
          if (!_disposed && identical(link, ws.link))
            unawaited(_openEventStream(link));
        });
      }
    }
  }

  void _handleStreamEvent(Map<String, dynamic> ev) {
    if (!mounted || _disposed) return;
    final type = ev['type'] as String? ?? '';
    if (type == 'ping') return;
    if (_loading && !_replayingEvents) {
      if (_loadingEvents.length >= 512) {
        _loadingEvents.removeAt(0);
      }
      _loadingEvents.add(ev);
      return;
    }
    final sid = ev['session_id'] as String? ?? '';
    // Queue overflow invalidates every session on this subscription.
    if (type == 'sync.required' && sid.isEmpty) {
      if (ws.link != null && _sessionId != null) {
        unawaited(_loadSession(ws.link!, _sessionId!));
      }
      return;
    }
    if (_sessionId == null ||
        (sid != _sessionId && ev['root_session_id'] != _sessionId))
      return;
    if (widget.primary) widget.work.event(ev);
    if (type == 'sync.required') {
      if (ws.link != null) unawaited(_loadSession(ws.link!, _sessionId!));
      return;
    }
    final activityKey = '$sid:${ev['tool_call_id']}';
    if (type == 'tool.running') _activities[activityKey] = Map.of(ev);
    if (type == 'tool.progress') {
      final a = _activities[activityKey];
      if (a != null) {
        final text = '${a['output'] ?? ''}${ev['delta'] ?? ''}';
        a['output'] = text.length > 32768
            ? text.substring(text.length - 32768)
            : text;
      }
      final live = _liveTools
          .where((t) => t.callId == ev['tool_call_id'])
          .firstOrNull;
      if (live != null && sid == _sessionId)
        live.output = _activities[activityKey]?['output'] as String? ?? '';
      _paintTimer ??= Timer(const Duration(milliseconds: 33), () {
        _paintTimer = null;
        if (mounted && _visible) setState(() {});
      });
      return;
    }
    if (type == 'tool.done') _activities.remove(activityKey);
    if (sid != _sessionId) {
      setState(() {
        if (type == 'permission.ask' && ev['permission'] is Map)
          _pendingPerm = AiPermissionQuestion.fromJson(
            (ev['permission'] as Map).cast<String, dynamic>(),
          );
        if (type == 'question.ask') _childQuestions.add(sid);
        if (type == 'question.done') _childQuestions.remove(sid);
        if (type == 'tool.done')
          _permissions.removeWhere(
            (_, q) => q.sessionId == sid && q.callId == ev['tool_call_id'],
          );
        if (type == 'session.status' && ev['status'] != 'running') {
          _permissions.removeWhere((_, q) => q.sessionId == sid);
          _childQuestions.remove(sid);
          _activities.removeWhere((_, a) => a['session_id'] == sid);
        }
      });
      return;
    }

    // Coalesce high-frequency text chunks; do not re-layout Markdown per token.
    if (type == 'text.delta' ||
        type == 'reasoning.delta' ||
        type == 'compaction.delta') {
      final delta = ev['delta'] as String? ?? '';
      if (type == 'text.delta') _liveText += delta;
      if (type == 'reasoning.delta') _liveReasoning += delta;
      if (type == 'compaction.delta') {
        if (_liveCompaction == '正在压缩上下文摘要…') _liveCompaction = '';
        _liveCompaction += delta;
      }
      _paintTimer ??= Timer(const Duration(milliseconds: 33), () {
        _paintTimer = null;
        if (mounted && _visible) {
          setState(() {});
          _scrollToBottom();
        }
      });
      return;
    }

    setState(() {
      if (ev['runtime'] is Map || ev['context'] is Map || ev['budget'] is Map) {
        _session ??= AiSession(
          id: sid,
          title: '新会话',
          root: _root,
          workdir: _workdir,
        );
        if (ev['runtime'] is Map)
          _session!.runtime = AiRuntimeInfo.fromJson(
            (ev['runtime'] as Map).cast<String, dynamic>(),
          );
        if (ev['context'] is Map)
          _session!.context = AiContextInfo.fromJson(
            (ev['context'] as Map).cast<String, dynamic>(),
          );
        if (ev['budget'] is Map)
          _session!.budget = AiRunBudget.fromJson(ev['budget'] as Map);
      }
      switch (type) {
        case 'question.ask':
          _questionGeneration++;
          _pendingQuestion = (ev['question'] as Map?)?.cast<String, dynamic>();
        case 'question.done':
          _questionGeneration++;
          _pendingQuestion = null;
        case 'inbox.updated':
          unawaited(_refreshInbox());
        case 'session.status':
          final status = ev['status'] as String? ?? '';
          _running = status == 'running';
          if (!_running) {
            _activities.clear();
            _liveReasoning = '';
            _liveText = '';
            _liveCompaction = '';
            _liveTools.clear();
            _permissions.clear();
            _childQuestions.clear();
            _pendingQuestion = null;
          }
          widget.onSessionsChanged?.call();
          unawaited(_refreshInbox());
          unawaited(_refreshQuestion());

        case 'session.title':
          final title = ev['title'] as String? ?? '';
          if (title.isNotEmpty && _session != null) {
            _session!.title = title;
            _updateTabTitle(title);
            widget.onSessionsChanged?.call();
          }

        case 'message.added':
          if (ev['message'] is Map) {
            final msg = AiMessage.fromJson(
              (ev['message'] as Map).cast<String, dynamic>(),
            );
            _session ??= AiSession(
              id: sid,
              title: '新会话',
              root: _root,
              workdir: _workdir,
            );
            if (!_session!.messages.any((m) => m.id == msg.id)) {
              _session!.messages.add(msg);
            }
          }

        case 'step.start':
          _liveReasoning = '';
          _liveText = '';
          _liveTools.clear();

        case 'reasoning.delta':
          _liveReasoning += ev['delta'] as String? ?? '';

        case 'text.delta':
          _liveText += ev['delta'] as String? ?? '';

        case 'tool.start':
          final cid = ev['tool_call_id'] as String? ?? '';
          final nm = ev['tool_name'] as String? ?? '';
          if (!_liveTools.any((t) => t.callId == cid)) {
            _liveTools.add(LiveToolCall(callId: cid, name: nm));
          }

        case 'tool.running':
          final cid = ev['tool_call_id'] as String? ?? '';
          final nm = ev['tool_name'] as String? ?? '';
          final inp = ev['input'] == null
              ? ''
              : (ev['input'] is String
                    ? ev['input'] as String
                    : jsonEncode(ev['input']));
          final existing = _liveTools.where((t) => t.callId == cid).firstOrNull;
          if (existing != null) {
            existing.inputJson = inp;
          } else {
            _liveTools.add(LiveToolCall(callId: cid, name: nm, inputJson: inp));
          }

        case 'tool.done':
          final cid = ev['tool_call_id'] as String? ?? '';
          final out = ev['output'] as String? ?? '';
          final isErr = ev['is_error'] == true;
          final meta = ev['metadata'] is Map
              ? (ev['metadata'] as Map).cast<String, dynamic>()
              : const <String, dynamic>{};
          final existing = _liveTools.where((t) => t.callId == cid).firstOrNull;
          if (existing != null) {
            existing.output = out;
            existing.isError = isErr;
            existing.running = false;
            existing.metadata = meta;
          }
          _permissions.removeWhere(
            (_, q) => q.sessionId == sid && q.callId == cid,
          );
          // Notify open editors/file tree if files were modified
          if (meta.containsKey('files')) {
            ws.filesRevision.value++;
          }

        case 'permission.ask':
          if (ev['permission'] is Map) {
            _pendingPerm = AiPermissionQuestion.fromJson(
              (ev['permission'] as Map).cast<String, dynamic>(),
            );
          }

        case 'todos.updated':
          if (_session != null && ev['todos'] is List) {
            _session!.todos = [
              for (final t in ev['todos'] as List)
                if (t is Map) AiTodoItem.fromJson(t.cast<String, dynamic>()),
            ];
          }

        case 'step.finish':
          _liveReasoning = '';
          _liveText = '';
          _liveTools.clear();
          if (ev['message'] is Map) {
            final msg = AiMessage.fromJson(
              (ev['message'] as Map).cast<String, dynamic>(),
            );
            _session ??= AiSession(
              id: sid,
              title: '新会话',
              root: _root,
              workdir: _workdir,
            );
            final idx = _session!.messages.indexWhere((m) => m.id == msg.id);
            if (idx >= 0) {
              _session!.messages[idx] = msg;
            } else {
              _session!.messages.add(msg);
            }
            if (msg.usage != null && idx < 0) {
              final u = msg.usage!;
              final cur = _session!.totalUsage;
              _session!.totalUsage = AiUsage(
                inputTokens: cur.inputTokens + u.inputTokens,
                outputTokens: cur.outputTokens + u.outputTokens,
                cacheReadTokens: cur.cacheReadTokens + u.cacheReadTokens,
                cacheWriteTokens: cur.cacheWriteTokens + u.cacheWriteTokens,
                reasoningTokens: cur.reasoningTokens + u.reasoningTokens,
                totalTokens: cur.totalTokens + u.totalTokens,
                cost: cur.cost + u.cost,
              );
              if (u.inputTokens > 0) _session!.lastInputTokens = u.inputTokens;
            }
          }

        case 'compaction.start':
          _liveCompaction = '正在压缩上下文摘要…';

        case 'compaction.delta':
          if (_liveCompaction == '正在压缩上下文摘要…') _liveCompaction = '';
          _liveCompaction += ev['delta'] as String? ?? '';

        case 'compaction.done':
          _liveCompaction = '';
          if (ev['message'] is Map && _session != null) {
            final msg = AiMessage.fromJson(
              (ev['message'] as Map).cast<String, dynamic>(),
            );
            if (!_session!.messages.any((m) => m.id == msg.id))
              _session!.messages.add(msg);
          }

        case 'compaction.error':
          _liveCompaction = '';
          ws.toast('压缩上下文失败：${ev['error'] ?? ''}', error: true);

        case 'session.error':
          _running = false;
          _liveReasoning = '';
          _liveText = '';
          _liveTools.clear();
          if (ev['message'] is Map) {
            final msg = AiMessage.fromJson(
              (ev['message'] as Map).cast<String, dynamic>(),
            );
            _session ??= AiSession(
              id: sid,
              title: '新会话',
              root: _root,
              workdir: _workdir,
            );
            if (!_session!.messages.any((m) => m.id == msg.id))
              _session!.messages.add(msg);
          } else if ((ev['error'] as String? ?? '').isNotEmpty) {
            ws.toast('${ev['error']}', error: true);
          }

        case 'session.reverted':
          if (ws.link != null && _sessionId != null) {
            unawaited(_loadSession(ws.link!, _sessionId!));
          }
      }
      if (ev['total_usage'] is Map && _session != null)
        _session!.totalUsage = AiUsage.fromJson(
          (ev['total_usage'] as Map).cast<String, dynamic>(),
        );
    });
    _runtimeChanges.value++;
    _scrollToBottom();
  }

  void _replayLoadingEvents() {
    final buffered = List<Map<String, dynamic>>.of(_loadingEvents);
    _loadingEvents.clear();
    _replayingEvents = true;
    try {
      for (final event in buffered) {
        _handleStreamEvent(event);
      }
    } finally {
      _replayingEvents = false;
    }
  }

  void _scrollToBottom({bool force = false}) {
    // Ordinary events/reloads never change reading intent. The transcript
    // applies geometry and tail corrections during layout, not animations.
    if (force) _scrollCtl.followLatest();
  }

  AiProvider? get _activeProvider => _provider;
  bool _sending = false;

  // Menus, keyboard commands and compact/wide controls use the same actions.
  Future<void> _action(String value) async {
    value = switch (value) {
      'pick-model' => 'model',
      'models' => 'settings',
      'local' => 'attach',
      'full' => 'full_access',
      _ => value,
    };
    if (!mounted || !_openActions.add(value)) return;
    try {
      switch (value) {
        case 'send-options':
          final defaultPolicy = ws.app.ready
              ? ws.app.aiSettings.defaultPolicy
              : AiSessionPolicy();
          final result = await showAiSessionPolicyDialog(
            context,
            initial: AiSendSettings(
              agent: _agentMode,
              permission: _permMode,
              delivery: _deliveryMode,
              policy: _sessionPolicy,
            ),
            defaultPolicy: defaultPolicy,
            running: _running,
            child: _session?.parentId.isNotEmpty == true,
          );
          if (result != null && mounted) {
            final permChanged = result.permission != _permMode;
            setState(() {
              _agentMode = result.agent;
              _permMode = result.permission;
              _deliveryMode = result.delivery;
              _sessionPolicy = result.policy;
            });
            // Role changes may also replace Persona rules. Keep the mode
            // explicitly selected in this dialog.
            _lastSettingsPermMode = _settingsPermissionMode;
            _refreshEffectivePermissions(sendMode: permChanged);
          }
        case 'navigate':
          await _showNavigateDialog();
        case 'latest':
          _scrollToBottom(force: true);
        case 'model':
          await _chooseModel();
        case 'settings':
          await showAiSettingsDialog(
            context,
            app: ws.app,
            ws: ws,
            initialSection: 'overview',
            providerId: _provider?.id,
            model: _provider?.model,
          );
        case 'personas':
          await showAiSettingsDialog(
            context,
            app: ws.app,
            ws: ws,
            initialSection: 'personas',
            providerId: _provider?.id,
            model: _provider?.model,
          );
        case 'compact':
          await _compactManual();
        case 'stop':
          await _stop();
        case 'grants':
          await _showGrants();
        case 'inbox':
          await _showInbox();
        case 'attach':
          await _pickLocalFiles();
        case 'attachments':
          await _showComposerAttachments();
        case 'paste':
          await _paste();
        case 'active':
          await _attachActiveFile();
        case 'selection':
          await _attachActiveFile(selection: true);
        case 'remote':
          await _attachFileByPath();
        case 'send':
          await _submitComposer();
        case 'plan':
        case 'build':
        case 'orchestrator':
          setState(() => _agentMode = value);
          _refreshEffectivePermissions();
        case 'ask':
        case 'auto':
        case 'full_access':
          setState(() => _permMode = value);
          _syncLivePermissions(mode: value);
        case 'queue':
        case 'steer':
          setState(() => _deliveryMode = value);
        case 'smaller':
          _setChatFontSize(_chatFontSize - 1);
        case 'larger':
          _setChatFontSize(_chatFontSize + 1);
        case 'reset':
          _setChatFontSize(15);
        case 'details':
          await _showDetailsDialog();
        case 'question':
          final question = _pendingQuestion, link = ws.link, sid = _sessionId;
          if (question == null || link == null || sid == null) return;
          await showWorkbenchDialog<void>(
            context: context,
            builder: (_) => AiQuestionDialog(
              question: question,
              submit: (answers, skip) async {
                if (!mounted ||
                    !identical(link, ws.link) ||
                    _pendingQuestion?['id'] != question['id']) {
                  throw StateError('问题已结束或连接已变更，请返回当前会话。');
                }
                await link.call('ai.question', {
                  'session_id': sid,
                  'id': question['id'],
                  if (skip) 'cancel': true else 'answers': answers,
                });
                if (mounted && _pendingQuestion?['id'] == question['id']) {
                  setState(() => _pendingQuestion = null);
                }
              },
            ),
          );
      }
    } on Object catch (e) {
      if (mounted)
        ws.toast(
          e is OpError
              ? e.message
              : e is StateError
              ? e.message
              : '操作失败，请重试。',
          error: true,
        );
    } finally {
      _openActions.remove(value);
    }
  }

  Future<void> _refreshQuestion() async {
    final link = ws.link, sid = _sessionId;
    if (link == null ||
        sid == null ||
        !link.server.caps.contains('ai.question'))
      return;
    final generation = ++_questionGeneration;
    try {
      final res = await link.call('ai.question', {'session_id': sid}) as Map;
      if (!mounted ||
          generation != _questionGeneration ||
          !identical(link, ws.link) ||
          _sessionId != sid)
        return;
      setState(
        () => _pendingQuestion = (res['question'] as Map?)
            ?.cast<String, dynamic>(),
      );
    } on Object {
      // A transient fetch keeps the last pending question and the retry action.
    }
  }

  List<(String, String)> _slashSuggestions(String value) {
    final query = value.trim().toLowerCase();
    if (!query.startsWith('/')) return const [];
    return _aiSlashCommands
        .where((entry) => entry.$1.startsWith(query))
        .take(5)
        .toList();
  }

  Future<void> _submitComposer() async {
    if (_sending ||
        (_inputCtl.value.composing.isValid &&
            !_inputCtl.value.composing.isCollapsed))
      return;
    final value = _inputCtl.text.trim();
    if (value.startsWith('/')) {
      final command = value.split(RegExp(r'\s+')).first.toLowerCase();
      final known = _aiSlashCommands.any((entry) => entry.$1 == command);
      if (!known) {
        ws.toast('未知命令：$command。输入 /help 查看可用命令', error: true);
        return;
      }
      _inputCtl.clear();
      if (command == '/help') {
        ws.toast('可用命令：${_aiSlashCommands.map((e) => e.$1).join('  ')}');
      } else {
        await _action(command.substring(1));
      }
      return;
    }
    await _send();
  }

  Future<void> _chooseModel() async {
    final personas = ws.app.ready ? ws.app.aiSettings.personas : const <AiPersona>[];
    if (personas.isEmpty) {
      await showAiSettingsDialog(
        context,
        app: ws.app,
        ws: ws,
        initialSection: 'personas',
      );
      return;
    }
    final pickedId = await showAiPersonaPicker(
      context,
      ws,
      initialPersonaId: _activePersonaId,
    );
    if (pickedId == null || !mounted) return;
    _applyPersonaSelection(_personaById(pickedId));
  }

  AiPersona? _personaById(String? id) =>
      ws.app.ready ? ws.app.aiSettings.personaById(id) : null;

  AiPersona? get _primaryPersona => _agentMode == 'orchestrator'
      ? (_personaById(_conductorPersonaId) ?? _personaById(_activePersonaId))
      : _personaById(_activePersonaId);

  AiProvider? _providerForPersona(AiPersona? persona, AiProvider? fallback) {
    if (persona == null) return fallback;
    final source = persona.providerId.isNotEmpty && ws.app.ready
        ? ws.app.aiSettings.providers
              .where((p) => p.id == persona.providerId)
              .firstOrNull
        : fallback;
    if (source == null) return fallback;
    final copy = AiProvider.fromJson(source.toJson());
    if (persona.model.isNotEmpty) copy.model = persona.model;
    return copy;
  }

  void _applyPersonaSelection(AiPersona? persona) {
    setState(() {
      _activePersonaId = persona?.id;
      if (persona != null) {
        final nextProv = _providerForPersona(persona, _provider);
        if (nextProv != null) _provider = nextProv;
        _reasoningOverride = persona.reasoningEffort;
        _reasoningOverrideSet = persona.reasoningEffort != null;
        _selectionExplicit = true;
      }
    });
    _refreshEffectivePermissions();
  }

  Future<void> _send([String? quickPrompt, String? inboxId]) async {
    if (_sending) return;
    final link = ws.link;
    if (link == null) {
      ws.toast(
        ws.entry?.isLocal == true ? '本地 agent 未连接' : '服务器未连接',
        error: true,
      );
      return;
    }
    final primaryPersona = _primaryPersona;
    final musicianPersona = _agentMode == 'orchestrator'
        ? _personaById(_musicianPersonaId)
        : null;
    final prov = _providerForPersona(primaryPersona, _activeProvider);
    if (prov == null || prov.model.trim().isEmpty) {
      await _action('settings');
      return;
    }
    final text = (quickPrompt ?? _inputCtl.text).trim();
    if (text.isEmpty && _attachments.isEmpty && inboxId == null) return;
    if (_running &&
        _deliveryMode == 'queue' &&
        !link.server.caps.contains('ai.inbox')) {
      ws.toast('当前 agent 尚不支持任务结束后的排队，请升级 agent 后使用。', error: true);
      return;
    }

    final sentAttachments = inboxId == null
        ? List<AiAttachment>.of(_attachments)
        : <AiAttachment>[];
    final sentOptions = _sessionPolicy.isDefault
        ? const <String, dynamic>{}
        : _sessionPolicy.toRunOptionsJson();
    bool wantsFullAccess() =>
        _permMode == 'full_access' ||
        musicianPersona?.permissionMode == 'full_access' ||
        (inboxId == null && sentOptions['subagents_permission_mode'] == 'full_access');
    if (wantsFullAccess() && !_supportsFullAccess(link)) {
      ws.toast('当前 agent 无法确认支持完全权限。请升级 agent，或改用先询问／自动执行后再发。', error: true);
      return;
    }
    if (sentOptions.isNotEmpty &&
        inboxId == null &&
        !link.server.caps.contains('ai.run.options')) {
      ws.toast('当前 agent 不支持自定义对话策略，请升级 agent 或恢复默认策略后发送。', error: true);
      return;
    }
    final sentRoot = _root,
        sentWorkdir = _workdir,
        sentAgent = _agentMode,
        sentReasoning = _reasoningOverride,
        sentReasoningSet = _reasoningOverrideSet,
        sentDelivery = _deliveryMode;
    final sentDefaults = Map<String, bool>.of(ws.app.aiSettings.toolDefaults);
    final capabilities = {
      ...prov.effectiveCapabilities(prov.model, sentDefaults),
      if (primaryPersona != null) ...primaryPersona.capabilities,
    };
    if (!link.server.caps.contains('ai.capabilities') &&
        (sentDefaults.isNotEmpty ||
            prov.modelOptions.containsKey(prov.model))) {
      ws.toast('当前 agent 不支持模型工具能力配置，请先升级 agent 后发送。', error: true);
      return;
    }
    if (sentAttachments.any((a) => a.mime.startsWith('image/')) &&
        capabilities['image_input'] == false) {
      ws.toast('当前模型已配置为不支持图片输入，请在模型配置中更换模型或更新能力标记', error: true);
      return;
    }
    if (sentAttachments.any((a) => a.mime == 'application/pdf') &&
        capabilities['pdf_input'] == false) {
      ws.toast('当前模型已禁用 PDF 输入，请更换模型或调整模型能力。', error: true);
      return;
    }
    final inputBefore = _inputCtl.text;
    setState(() {
      _sending = true;
    });
    _scrollCtl.followLatest();

    try {
      final prepared = await prepareAiProvider(ws.app, link, prov);
      AiProvider? preparedMusician;
      if (musicianPersona != null) {
        final mProv = _providerForPersona(musicianPersona, prov);
        if (mProv != null && mProv.model.trim().isNotEmpty) {
          preparedMusician = await prepareAiProvider(ws.app, link, mProv);
        }
      }
      if (!mounted || !identical(link, ws.link)) return;
      if (_providerForPersona(primaryPersona, _activeProvider)?.id != prov.id ||
          _providerForPersona(primaryPersona, _activeProvider)?.model !=
              prov.model)
        throw StateError('模型选择已变更，请确认后重新发送');
      final attachments = <Map<String, dynamic>>[];
      for (final a in sentAttachments) {
        if (a.bytes == null) {
          attachments.add(a.toJson());
          continue;
        }
        final cached = _uploadedAttachments[a];
        if (cached != null && identical(cached.$1, link)) {
          attachments.add(cached.$2);
          continue;
        }
        final result = await uploadAiAttachment(
          link,
          a,
          active: () => mounted && identical(ws.link, link),
          progress: (p) {
            if (mounted)
              setState(
                () =>
                    _attachmentNote = '正在上传 ${a.label} · ${(p * 100).round()}%',
              );
          },
        );
        _uploadedAttachments[a] = (link, result);
        attachments.add(result);
      }
      if (!mounted || !identical(link, ws.link)) return;
      // Upload can take time; do not overwrite a permission update made while
      // it was running with the obsolete mode and rules from the draft start.
      await _permissionUpdate;
      if (!mounted || !identical(link, ws.link)) return;
      if (wantsFullAccess() && !_supportsFullAccess(link)) {
        throw StateError('当前 agent 不支持完全权限，请升级或重新选择权限后再发');
      }
      if (_agentMode != sentAgent ||
          _primaryPersona?.id != primaryPersona?.id ||
          _root != sentRoot ||
          _workdir != sentWorkdir) {
        throw StateError('工作模式、人设或目录已变更，请确认后重新发送');
      }
      final useRunOptions = !_running || sentDelivery == 'queue';
      final res = await link.call('ai.run', {
        if (_sessionId != null) 'session_id': _sessionId,
        if (inboxId != null) 'inbox_id': inboxId,
        if (link.server.caps.contains('ai.run.options') &&
            useRunOptions &&
            sentOptions.isNotEmpty &&
            inboxId == null)
          'options': sentOptions,
        'root': sentRoot,
        'workdir': sentWorkdir,
        'agent': sentAgent,
        'permission_mode': _permMode,
        'permission_rules': _effectivePermissionRules(),
        if (_running) 'delivery': sentDelivery,
        'text': text,
        if (attachments.isNotEmpty) 'attachments': attachments,
        'provider': prepared.toWireJson(
          extensionCapabilities: link.server.caps.contains('ai.extensions'),
          reasoningOverride: sentReasoningSet ? sentReasoning : null,
          capabilityDefaults: sentDefaults,
          persona: primaryPersona,
        ),
        if (preparedMusician != null && musicianPersona != null) ...{
          'subagent_provider': preparedMusician.toWireJson(
            extensionCapabilities: link.server.caps.contains('ai.extensions'),
            capabilityDefaults: sentDefaults,
            persona: musicianPersona,
          ),
          if (musicianPersona.permissionMode.isNotEmpty)
            'subagent_permission_mode': musicianPersona.permissionMode,
          if (musicianPersona.permissionRules.isNotEmpty)
            'subagent_permission_rules': [
              for (final r in musicianPersona.permissionRules)
                if (!r.disabled && !r.isExpired) r.toJson(),
            ],
        },
      }) as Map;
      if (!mounted || !identical(link, ws.link)) return;
      if (quickPrompt == null && _inputCtl.text == inputBefore)
        _inputCtl.clear();
      setState(() => _attachments.removeWhere(sentAttachments.contains));
      for (final a in sentAttachments) {
        _uploadedAttachments.remove(a);
      }
      final sum = AiSessionSummary.fromJson(
        (res['session'] as Map).cast<String, dynamic>(),
      );
      final isNew = _sessionId == null;
      _sessionId = sum.id;
      final currentTab = ws.tab(widget.tabId ?? '');
      if (currentTab != null) currentTab.taskKey = sum.id;
      if (isNew) {
        _stream?.sendJson({'type': 'filter', 'session_id': sum.id}).ignore();
        await _loadSession(link, sum.id);
      } else {
        setState(() => _running = true);
      }
      widget.onSessionsChanged?.call();
      unawaited(_refreshInbox());
      unawaited(_refreshQuestion());
      _scrollToBottom();
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    } on Object catch (e) {
      ws.toast(e is StateError ? e.message : '发送失败，输入和附件已保留', error: true);
    } finally {
      if (mounted)
        setState(() {
          _sending = false;
          _attachmentNote = null;
        });
    }
  }

  // 3.25.0 was shipped with different behaviors under one number. Only
  // unambiguous releases are accepted when there is no explicit capability.
  bool _supportsFullAccess(Link link) =>
      link.server.caps.contains('ai.permissions.full_access') ||
      (compareVersions(link.server.version, '3.25.1') ?? -1) >= 0;

  Future<void> _refreshInbox() async {
    final link = ws.link, sid = _sessionId;
    if (link == null || sid == null || !link.server.caps.contains('ai.inbox'))
      return;
    final generation = ++_inboxGeneration;
    try {
      final result = await link.call('ai.inbox', {'session_id': sid}) as Map;
      if (!mounted ||
          generation != _inboxGeneration ||
          !identical(link, ws.link))
        return;
      setState(
        () => _inbox = [
          for (final row in result['items'] as List? ?? [])
            if (row is Map) row.cast<String, dynamic>(),
        ],
      );
      _inboxChanges.value++;
    } on Object {
      // Keep the last admitted inputs visible across a transient disconnect.
    }
  }

  Future<void> _changeInbox(String id, String action) async {
    if (_inboxBusy) return;
    final link = ws.link;
    if (link == null) return;
    _inboxBusy = true;
    _inboxError = null;
    _inboxChanges.value++;
    try {
      await link.call('ai.inbox', {
        'session_id': _sessionId,
        'id': id,
        'action': action,
      });
      await _refreshInbox();
    } on Object catch (e) {
      if (mounted) _inboxError = e is OpError ? e.message : '更新失败，输入已保留，请重试。';
    } finally {
      if (mounted) {
        _inboxBusy = false;
        _inboxChanges.value++;
      }
    }
  }

  Future<void> _stop() async {
    final link = ws.link;
    final sid = _sessionId;
    if (link == null || sid == null) return;
    await ws.guard(() => link.call('ai.stop', {'id': sid}));
  }

  Future<void> _approve(
    AiPermissionQuestion q, {
    required bool allow,
    bool always = false,
  }) async {
    final link = ws.link;
    if (link == null) return;
    if (_approvalBusy) return;
    setState(() {
      _approvalBusy = true;
      _approvalError = null;
    });
    try {
      await link
          .call('ai.approve', {'id': q.id, 'allow': allow, 'always': always})
          .timeout(const Duration(seconds: 20));
      if (mounted && identical(link, ws.link)) {
        setState(() => _permissions.remove(q.id));
      }
    } on Object catch (e) {
      if (mounted && _pendingPerm?.id == q.id) {
        setState(
          () => _approvalError = e is OpError ? e.message : '审批提交失败，问题已保留，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _approvalBusy = false);
    }
  }

  Future<void> _showGrants() async {
    final link = ws.link, sid = _sessionId;
    if (link != null && sid != null)
      await showAiSessionGrants(context, link, sid);
  }

  bool _revertBusy = false;

  Future<void> _revertTo(AiMessage msg) async {
    if (_revertBusy) return;
    _revertBusy = true;
    try {
      await _reviewRevert(msg);
    } finally {
      _revertBusy = false;
    }
  }

  Future<void> _reviewRevert(AiMessage msg) async {
    final link = ws.link;
    final sid = _sessionId;
    final project = ws.projectKey;
    final lastMessage = _session?.messages.lastOrNull?.id;
    if (link == null || sid == null || _running) return;
    bool stillHere() => mounted && identical(link, ws.link) &&
        sid == _sessionId && project == ws.projectKey && ws.app.selected == ws.serverId;
    bool hasDirtyFiles() => ws.tabs.any((t) {
      final file = t.file;
      return t.dirty.value && file != null && file.root == _root &&
          (_workdir == '/' || file.path == _workdir || file.path.startsWith('$_workdir/'));
    });
    if (hasDirtyFiles()) {
      ws.toast('回退前请先保存目录内未保存的文件', error: true);
      return;
    }
    final scope = {'session_id': sid, 'message_id': msg.id};
    Map? preview;
    if (link.server.caps.contains('ai.revert.preview')) {
      preview = await ws.guard(() async => await link.call('ai.revert.preview', scope) as Map);
      if (preview == null || !stillHere()) return;
    }
    if (!stillHere()) return;
    final paths = (preview?['paths'] as List? ?? const []).whereType<String>().toList();
    final checked = <String>{};
    final chosen = await showWorkbenchDialog<List<String>>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, update) => AlertDialog(
        title: const Text('回退到此消息之前？'),
        content: SizedBox(width: 500, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview == null
                ? '当前 agent 不支持审阅，只有对话记录可回退，文件保持不变。'
                : '默认不改动文件。快照无法区分 AI 写入与手动保存，请先核对差异，只勾选要恢复的文件。'),
            if (preview?['overflow'] == true) const Text('只列出事务允许的文件范围；未列出的文件不会恢复。'),
            if (paths.isNotEmpty) SizedBox(
              height: (MediaQuery.sizeOf(c).height * 0.35).clamp(90.0, 250.0).toDouble(),
              child: ListView.builder(
              itemCount: paths.length,
              itemBuilder: (_, i) => CheckboxListTile(
                title: Text(paths[i], maxLines: 2, overflow: TextOverflow.ellipsis),
                value: checked.contains(paths[i]),
                onChanged: (on) => update(() {
                  if (on == true) {
                    checked.add(paths[i]);
                  } else {
                    checked.remove(paths[i]);
                  }
                }),
              ),
            )),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, checked.toList()),
            child: Text(checked.isEmpty ? '仅回退对话' : '恢复所选文件和对话'),
          ),
        ],
      )),
    );
    if (chosen == null || !mounted) return;
    if (!stillHere() || _running || _session?.messages.lastOrNull?.id != lastMessage) {
      ws.toast('连接、工作区或对话已变化，请重新核对回退目标', error: true);
      return;
    }
    if (hasDirtyFiles()) {
      ws.toast('回退前请先保存目录内未保存的文件', error: true);
      return;
    }
    final res = await ws.guard(
      () => link.call('ai.revert', {
        ...scope,
        'files': chosen.isNotEmpty,
        if (preview != null) 'review': {'revision': preview['revision'], 'paths': chosen},
      }),
    );
    if (res is Map && stillHere()) {
      final count = (res['restored_files'] as num?)?.toInt() ?? 0;
      ws.filesRevision.value++;
      ws.toast(count > 0 ? '已回退对话并恢复 $count 个文件' : '已回退对话记录');
      await _loadSession(link, sid);
    }
  }

  Future<void> _compactManual() async {
    final link = ws.link;
    final sid = _sessionId;
    final prov = _activeProvider;
    if (link == null || sid == null || prov == null) return;
    if (_running) {
      ws.toast('请等待当前步骤完成后再压缩', error: true);
      return;
    }
    final defaults = Map<String, bool>.of(ws.app.aiSettings.toolDefaults);
    if (!link.server.caps.contains('ai.capabilities') &&
        (defaults.isNotEmpty || prov.modelOptions.containsKey(prov.model))) {
      ws.toast('当前 agent 不支持模型工具能力配置，请先升级 agent。', error: true);
      return;
    }
    final reasoning = _reasoningOverrideSet ? _reasoningOverride : null;
    setState(() => _running = true);
    try {
      final prepared = await prepareAiProvider(ws.app, link, prov);
      await link.call('ai.compact', {
        'session_id': sid,
        'provider': prepared.toWireJson(
          extensionCapabilities: link.server.caps.contains('ai.extensions'),
          reasoningOverride: reasoning,
          capabilityDefaults: defaults,
        ),
      });
      await _loadSession(link, sid);
      ws.toast('上下文已按 OpenCode 检查点模板压缩');
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    } on Object catch (e) {
      ws.toast(e is StateError ? e.message : '压缩失败，请检查连接', error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _attachActiveFile({bool selection = false}) async {
    final link = ws.link;
    final activeFile = ws.tab(ws.editorActiveId ?? '')?.file;
    if (activeFile == null) {
      ws.toast('请先在编辑器中打开一个文件，或使用「浏览服务器文件」');
      return;
    }
    try {
      final document = ws.documents.find(activeFile.root, activeFile.path);
      if (document != null && document.phase.name == 'ready') {
        final content = selection ? document.selectedText : document.text;
        if (selection && content.isEmpty) throw StateError('请先在编辑器中选择文本');
        if (utf8.encode(content).length > aiAttachmentLimit)
          throw StateError('编辑缓冲超过附件大小上限');
        _addAttachments([
          AiAttachment(
            kind: 'file',
            label:
                '${activeFile.name} · ${selection ? '选区' : '编辑缓冲'} v${document.version}${document.dirty ? '（未保存）' : ''}',
            path: activeFile.path,
            content: content,
          ),
        ]);
        return;
      }
      if (selection) throw StateError('当前文件没有可用的编辑选区');
      if (link == null) throw StateError('未连接，且当前文件没有已加载的编辑缓冲');
      _addAttachments([
        await readAiRemoteFile(link, activeFile.root, activeFile.path),
      ]);
    } on Object catch (e) {
      _attachmentError(e);
    }
  }

  Future<void> _attachFileByPath() async {
    final link = ws.link;
    if (link == null) return;
    final choice = await showAiPathPicker(
      context,
      link: link,
      roots: _roots,
      root: _root,
      path: _workdir,
      directory: false,
    );
    if (choice == null) return;
    try {
      _addAttachments([await readAiRemoteFile(link, choice.root, choice.path)]);
    } on Object catch (e) {
      _attachmentError(e);
    }
  }

  Future<void> _pickWorkdir() async {
    final link = ws.link;
    if (link == null) return;
    final next = await showAiPathPicker(
      context,
      link: link,
      roots: _roots,
      root: _root,
      path: _workdir,
    );
    if (next == null || !mounted || !identical(link, ws.link)) return;
    setState(() {
      _root = next.root;
      _workdir = next.path;
    });
  }

  void _attachmentError(Object e) {
    if (mounted)
      ws.toast(
        e is StateError
            ? e.message
            : e is OpError
            ? e.message
            : e is PlatformException
            ? e.message ?? '无法读取剪贴板'
            : '附件读取失败，请重试',
        error: true,
      );
  }

  void _addAttachments(List<AiAttachment> list) {
    if (!mounted) return;
    if (_attachments.length + list.length > 8) throw StateError('每条消息最多 8 个附件');
    final total = [..._attachments, ...list].fold<int>(
      0,
      (n, a) => n + (a.bytes?.length ?? utf8.encode(a.content).length),
    );
    if (total > aiAttachmentTotalLimit)
      throw StateError('每条消息附件总大小不能超过 20 MiB');
    setState(() => _attachments.addAll(list));
  }

  Future<void> _pickLocalFiles() async {
    try {
      _addAttachments(await pickAiLocalFiles());
    } on Object catch (e) {
      _attachmentError(e);
    }
  }

  Future<void> _paste() async {
    if (_pasteBusy) return;
    _pasteBusy = true;
    try {
      final files = await readAiClipboardFiles();
      if (!mounted) return;
      if (files.isNotEmpty) {
        _addAttachments(files);
        return;
      }
      final text = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || text?.text == null) return;
      final value = _inputCtl.value;
      final selection = value.selection.isValid
          ? value.selection
          : TextSelection.collapsed(offset: value.text.length);
      final inserted = text!.text!;
      _inputCtl.value = TextEditingValue(
        text: value.text.replaceRange(selection.start, selection.end, inserted),
        selection: TextSelection.collapsed(
          offset: selection.start + inserted.length,
        ),
      );
    } on Object catch (e) {
      _attachmentError(e);
    } finally {
      _pasteBusy = false;
    }
  }

  Future<void> _insertContent(KeyboardInsertedContent content) async {
    try {
      if (content.data != null) {
        _addAttachments([
          aiAttachmentFromBytes(
            'keyboard.${content.mimeType.split('/').last}',
            content.data!,
          ),
        ]);
      } else {
        _addAttachments(await readAiContentUri(content.uri));
      }
    } on Object catch (e) {
      _attachmentError(e);
    }
  }

  void _setChatFontSize(double size) {
    ws.app.appearance.set('chatFont', size);
  }

  Widget _cachedMessageItem(Ide ide, AiMessage message) {
    final old = _messageCache[message];
    if (old != null &&
        identical(old.$1, ide) &&
        old.$2 == _running &&
        old.$3 == _chatFontSize &&
        identical(old.$4, ws.link))
      return old.$5;
    final child = _buildMessageItem(ide, message);
    if (_messageCache.length >= 100) _messageCache.clear();
    _messageCache[message] = (ide, _running, _chatFontSize, ws.link, child);
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (ws.link == null) return NotConnected(ws: ws);
    if (_loading && _session == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null && _session == null) {
      return EmptyHint(
        icon: Icons.error_outline_rounded,
        text: _error!,
        actionLabel: '重试',
        onAction: () => _sessionId != null && ws.link != null
            ? _loadSession(ws.link!, _sessionId!)
            : null,
      );
    }

    final prov = _activeProvider;
    final messages = (_session?.messages ?? const <AiMessage>[])
        .where((m) => !m.isSystemReminder)
        .toList();
    final todos = _session?.todos ?? const <AiTodoItem>[];

    return LayoutBuilder(
      builder: (_, constraints) {
        final short = constraints.maxHeight < 420;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
                _navigateMessage(messages, -1),
            const SingleActivator(
              LogicalKeyboardKey.arrowDown,
              alt: true,
            ): () =>
                _navigateMessage(messages, 1),
            const SingleActivator(LogicalKeyboardKey.end, control: true): () =>
                _scrollCtl.followLatest(),
          },
          child: DefaultTextStyle.merge(
            style: const TextStyle(
              fontFamily: Ide.ui,
              fontFamilyFallback: Ide.uiFallback,
            ),
            child: Column(
              children: [
                _buildWorkspaceBar(ide, compact: short),
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                if (_eventNote != null || _error != null)
                  MaterialBanner(
                    content: Text(
                      _error ?? _eventNote!,
                      style: const TextStyle(fontSize: 12),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          if (_sessionId != null && ws.link != null)
                            unawaited(_loadSession(ws.link!, _sessionId!));
                        },
                        child: const Text('重新同步'),
                      ),
                    ],
                  ),
                Expanded(
                  child: messages.isEmpty && !_running
                      ? _buildEmptyWelcome(ide, prov)
                      : Stack(
                          children: [
                            AiTranscript(
                              controller: _scrollCtl,
                              ids: [
                                for (final message in messages) message.id,
                                if (_running ||
                                    _activities.isNotEmpty ||
                                    _liveReasoning.isNotEmpty ||
                                    _liveText.isNotEmpty ||
                                    _liveTools.isNotEmpty ||
                                    _liveCompaction.isNotEmpty)
                                  '@live',
                              ],
                              itemBuilder: (context, index) {
                                if (index < messages.length) {
                                  final msg = messages[index];
                                  return Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      16,
                                      index == 0 &&
                                              ws.app.aiSettings
                                                  .showMessageNavigation &&
                                              !short
                                          ? 38
                                          : 0,
                                      16,
                                      0,
                                    ),
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 760,
                                        ),
                                        child: RepaintBoundary(
                                          key: ValueKey(msg.id),
                                          child: _cachedMessageItem(ide, msg),
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                if (index == messages.length &&
                                    (_running ||
                                        _activities.isNotEmpty ||
                                        _liveReasoning.isNotEmpty ||
                                        _liveText.isNotEmpty ||
                                        _liveTools.isNotEmpty ||
                                        _liveCompaction.isNotEmpty)) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 760,
                                        ),
                                        child: _buildLiveStep(ide),
                                      ),
                                    ),
                                  );
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                            if (ws.app.aiSettings.showMessageNavigation &&
                                !short &&
                                messages.isNotEmpty)
                              Positioned(
                                top: 6,
                                right: 12,
                                child: _buildMessageNavigation(
                                  ide,
                                  messages,
                                  floating: true,
                                ),
                              ),
                          ],
                        ),
                ),
                if (!short &&
                    todos.any(
                      (t) => t.status != 'completed' && t.status != 'cancelled',
                    ))
                  _buildTodoBanner(ide, todos),
                _buildActionDocks(ide, compact: constraints.maxHeight < 650),
                _buildComposer(ide, prov, compact: short),
              ],
            ),
          ),
        );
      },
    );
  }

  void _navigateMessage(List<AiMessage> messages, int step) {
    if (messages.isEmpty) return;
    final index = messages.indexWhere(
      (m) => m.id == _scrollCtl.currentMessage.value,
    );
    final at = index < 0 ? messages.length - 1 : index;
    _scrollCtl.reveal(messages[(at + step).clamp(0, messages.length - 1)].id);
  }

}
