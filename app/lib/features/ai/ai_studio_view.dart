// Agent Studio editor tab (D-104): OpenCode-compatible AI coding & server agent UI.
// Supports Build/Plan modes, live streaming thinking + tool cards + todo tracker + diffs,
// inline permission approvals, 1-click shadow-git revert, context attachments, and compaction.
import 'dart:async';
import 'dart:convert';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'ai_model_picker.dart';
import 'ai_auth.dart';
import 'ai_models.dart';
import 'ai_settings_dialog.dart';
import 'ai_attachments.dart';
import 'ai_path_picker.dart';
import 'ai_attachment_tile.dart';
import 'ai_history.dart';
import 'ai_transcript.dart';

class _AiPasteIntent extends Intent { const _AiPasteIntent(); }

EditorTab aiStudioTab(Workspace ws, {String? sessionId, String title = 'AI 助手'}) {
  final tabId = sessionId == null ? 'ai:draft:${newId()}' : 'ai:$sessionId';
  return EditorTab(
    id: tabId,
    taskKey: sessionId,
    title: title,
    icon: Icons.auto_awesome_rounded,
    tooltip: 'AI 智能体 · $title',
    builder: (_) => AiStudioView(key: ValueKey('${ws.serverId}/$tabId'), ws: ws, initialSessionId: sessionId, tabId: tabId),
  );
}

class AiStudioView extends StatefulWidget {
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
  State<AiStudioView> createState() => _AiStudioViewState();
}

class _AiStudioViewState extends State<AiStudioView> {
  String? _sessionId;
  AiSession? _session;
  bool _loading = false;
  bool _running = false;
  bool _runtimeExpanded = false;
  String? _error;

  String _root = '';
  String _workdir = '/';
  List<Map<String, dynamic>> _roots = [];

  String _agentMode = 'build'; // 'build' | 'plan'
  String _permMode = 'ask'; // 'ask' | 'auto'

  // Live streaming buffers for the active step
  String _liveReasoning = '';
  String _liveText = '';
  String _liveCompaction = '';
  final List<LiveToolCall> _liveTools = [];
  AiPermissionQuestion? _pendingPerm;

  final List<AiAttachment> _attachments = [];
  final Map<AiAttachment,(Link,Map<String,dynamic>)> _uploadedAttachments={};
  bool _pasteBusy=false;
  String? _attachmentNote;
  bool _planExpanded = false;
  Timer? _paintTimer;
  double _chatFontSize=15;
  AiProvider? _provider;
  String? _editorId;
  bool _visible = true;
  final Map<AiMessage,(Ide,bool,double,Link?,Widget)> _messageCache={};
  final _inputCtl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scrollCtl = AiTranscriptController();

  OpStream? _stream;
  Link? _streamLink;
  bool _disposed = false;
  int _loadGeneration = 0;
  Timer? _eventRetry;
  String? _eventNote;
  final Map<String, Map<String, dynamic>> _activities = {};
  final List<Map<String, dynamic>> _loadingEvents = [];
  bool _replayingEvents = false;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.initialSessionId;
    if (ws.app.ready) {
      final ai = ws.app.aiSettings;
      _agentMode = ai.defaultAgent;
      _permMode = ai.permissionMode;
      _provider = ai.activeProvider;
    }
    _chatFontSize = ws.app.appearance.value.chatFont;
    _editorId = ws.editorActiveId;
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
    super.dispose();
  }

  void _onAppChanged() {
    if (mounted) setState(() { _provider = ws.app.ready ? ws.app.aiSettings.activeProvider : null; });
  }

  void _onAppearance() {
    final size = ws.app.appearance.value.chatFont;
    if (!mounted || size == _chatFontSize) return;
    if (_visible) { setState(() => _chatFontSize = size); }
    else { _chatFontSize = size; }
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
    } else if (_editorId != ws.editorActiveId) {
      _editorId = ws.editorActiveId;
      setState(() {});
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
    if (_disposed || !mounted || !identical(link, ws.link) || !identical(link, _streamLink)) return;
    if (_sessionId != null) unawaited(_loadSession(link, _sessionId!));
    unawaited(_openEventStream(link));
  }

  void _closeStream() {
    _loadingEvents.clear();
    _eventRetry?.cancel();
    _eventRetry = null;
    _loadGeneration++;
    _stream?.reset();
    _stream = null;
    _streamLink = null;
  }

  Future<void> _loadRoots(Link link) async {
    try {
      final r = await link.call('fs.roots') as Map;
      final list = [for (final x in r['roots'] as List) (x as Map).cast<String, dynamic>()];
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await loadAiHistory(link, id);
      if (!mounted || generation != _loadGeneration || !identical(link, ws.link)) return;
      final sess = AiSession.fromJson((res['session'] as Map).cast<String, dynamic>());
      final running = res['running'] == true;
      final pending = res['pending_permission'] is Map
          ? AiPermissionQuestion.fromJson((res['pending_permission'] as Map).cast<String, dynamic>())
          : null;
      setState(() {
        _session = sess;
        _messageCache.clear();
        _running = running;
        _pendingPerm = pending;
        _activities.clear();
        for (final a in (res['activities'] as List? ?? const [])) {
          if (a is Map) {
            final row = a.cast<String, dynamic>();
            _activities['${row['session_id']}:${row['tool_call_id']}'] = row;
          }
        }
        _root = sess.root;
        _workdir = sess.workdir;
        _agentMode = sess.agent == 'plan' ? 'plan' : 'build';
        if (sess.permissionMode.isNotEmpty) _permMode = sess.permissionMode;
        _loading = false;
      });
      _updateTabTitle(sess.title);
      _replayLoadingEvents();
      _scrollToBottom();
    } on Object catch (e) {
      if (mounted && generation == _loadGeneration && identical(link, ws.link)) {
        setState(() {
          _error = e is OpError ? e.message : e is StateError ? e.message : '会话加载失败，历史和输入均已保留，请重试';
          _loading = false;
        });
        if (_session != null) _replayLoadingEvents();
      }
    }
  }

  void _updateTabTitle(String title) {
    final tabId = widget.tabId ?? (widget.initialSessionId == null ? 'ai:new' : 'ai:${widget.initialSessionId}');
    ws.updateTabTitle(tabId, title);
  }

  Future<void> _openEventStream(Link link) async {
    OpStream? opened;
    try {
      final st = await link.open('ai.stream', {
        if (_sessionId != null) 'session_id': _sessionId,
      });
      opened = st;
      await st.response();
      if (_disposed || !mounted || !identical(link, ws.link) || !identical(link, _streamLink)) return;
      _stream = st;
      if (mounted) setState(() => _eventNote = null);
      if (_sessionId != null) unawaited(_loadSession(link, _sessionId!));
      while (!_disposed) {
        final f = await st.read();
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
      if (!_disposed && mounted && identical(link, ws.link) && identical(link, _streamLink)) {
        setState(() => _eventNote = '实时状态流中断，正在恢复；请以重新同步结果为准');
        _eventRetry?.cancel();
        _eventRetry = Timer(const Duration(seconds: 3), () {
          if (!_disposed && identical(link, ws.link)) unawaited(_openEventStream(link));
        });
      }
    }
  }

  void _handleStreamEvent(Map<String, dynamic> ev) {
    if (!mounted || _disposed) return;
    final type = ev['type'] as String? ?? '';
    if (type == 'ping') return;
    if (_loading && !_replayingEvents) {
      if (_loadingEvents.length >= 512) { _loadingEvents.removeAt(0); }
      _loadingEvents.add(ev);
      return;
    }
    final sid = ev['session_id'] as String? ?? '';
    if (_sessionId == null || (sid != _sessionId && ev['root_session_id'] != _sessionId)) return;
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
        a['output'] = text.length > 32768 ? text.substring(text.length - 32768) : text;
      }
      final live = _liveTools.where((t) => t.callId == ev['tool_call_id']).firstOrNull;
      if (live != null && sid == _sessionId) live.output = _activities[activityKey]?['output'] as String? ?? '';
      _paintTimer ??= Timer(const Duration(milliseconds: 33), () { _paintTimer = null; if (mounted && _visible) setState(() {}); });
      return;
    }
    if (type == 'tool.done') _activities.remove(activityKey);
    if (sid != _sessionId) {
      setState(() {
        if (type == 'permission.ask' && ev['permission'] is Map) _pendingPerm = AiPermissionQuestion.fromJson((ev['permission'] as Map).cast<String,dynamic>());
        if (type == 'tool.done' && _pendingPerm?.callId == ev['tool_call_id']) _pendingPerm = null;
        if (type == 'session.status' && ev['status'] != 'running') _activities.removeWhere((_, a) => a['session_id'] == sid);
      });
      return;
    }

    // Coalesce high-frequency text chunks; do not re-layout Markdown per token.
    if(type=='text.delta'||type=='reasoning.delta'||type=='compaction.delta'){
      final delta=ev['delta'] as String? ?? '';
      if(type=='text.delta')_liveText+=delta;
      if(type=='reasoning.delta')_liveReasoning+=delta;
      if(type=='compaction.delta'){if(_liveCompaction=='正在压缩上下文摘要…')_liveCompaction='';_liveCompaction+=delta;}
      _paintTimer??=Timer(const Duration(milliseconds:33),(){_paintTimer=null;if(mounted && _visible){setState((){});_scrollToBottom();}});
      return;
    }

    setState(() {
      if (ev['runtime'] is Map || ev['context'] is Map) {
        _session ??= AiSession(id:sid, title:'新会话', root:_root, workdir:_workdir);
        if (ev['runtime'] is Map) _session!.runtime = AiRuntimeInfo.fromJson((ev['runtime'] as Map).cast<String,dynamic>());
        if (ev['context'] is Map) _session!.context = AiContextInfo.fromJson((ev['context'] as Map).cast<String,dynamic>());
      }
      switch (type) {
        case 'session.status':
          final status = ev['status'] as String? ?? '';
          _running = status == 'running';
          if (!_running) {
            _activities.clear();
            _liveReasoning = '';
            _liveText = '';
            _liveCompaction = '';
            _liveTools.clear();
            _pendingPerm = null;
          }
          widget.onSessionsChanged?.call();

        case 'session.title':
          final title = ev['title'] as String? ?? '';
          if (title.isNotEmpty && _session != null) {
            _session!.title = title;
            _updateTabTitle(title);
            widget.onSessionsChanged?.call();
          }

        case 'message.added':
          if (ev['message'] is Map) {
            final msg = AiMessage.fromJson((ev['message'] as Map).cast<String, dynamic>());
            _session ??= AiSession(id: sid, title: '新会话', root: _root, workdir: _workdir);
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
          final inp = ev['input'] == null ? '' : (ev['input'] is String ? ev['input'] as String : jsonEncode(ev['input']));
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
          final meta = ev['metadata'] is Map ? (ev['metadata'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
          final existing = _liveTools.where((t) => t.callId == cid).firstOrNull;
          if (existing != null) {
            existing.output = out;
            existing.isError = isErr;
            existing.running = false;
            existing.metadata = meta;
          }
          if (_pendingPerm?.callId == cid) {
            _pendingPerm = null;
          }
          // Notify open editors/file tree if files were modified
          if (meta.containsKey('files')) {
            ws.filesRevision.value++;
          }

        case 'permission.ask':
          if (ev['permission'] is Map) {
            _pendingPerm = AiPermissionQuestion.fromJson((ev['permission'] as Map).cast<String, dynamic>());
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
            final msg = AiMessage.fromJson((ev['message'] as Map).cast<String, dynamic>());
            _session ??= AiSession(id: sid, title: '新会话', root: _root, workdir: _workdir);
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
            final msg = AiMessage.fromJson((ev['message'] as Map).cast<String, dynamic>());
            if (!_session!.messages.any((m) => m.id == msg.id)) _session!.messages.add(msg);
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
            final msg = AiMessage.fromJson((ev['message'] as Map).cast<String, dynamic>());
            _session ??= AiSession(id: sid, title: '新会话', root: _root, workdir: _workdir);
            if (!_session!.messages.any((m) => m.id == msg.id)) _session!.messages.add(msg);
          } else if ((ev['error'] as String? ?? '').isNotEmpty) {
            ws.toast('${ev['error']}', error: true);
          }

        case 'session.reverted':
          if (ws.link != null && _sessionId != null) {
            unawaited(_loadSession(ws.link!, _sessionId!));
          }
      }
      if (ev['total_usage'] is Map && _session != null) _session!.totalUsage = AiUsage.fromJson((ev['total_usage'] as Map).cast<String,dynamic>());
    });
    _scrollToBottom();
  }

  void _replayLoadingEvents() {
    final buffered = List<Map<String,dynamic>>.of(_loadingEvents);
    _loadingEvents.clear();
    _replayingEvents = true;
    try { for (final event in buffered) { _handleStreamEvent(event); } }
    finally { _replayingEvents = false; }
  }

  void _scrollToBottom({bool force=false}) {
    // Ordinary events/reloads never change reading intent. The transcript
    // applies geometry and tail corrections during layout, not animations.
    if (force) _scrollCtl.followLatest();
  }

  AiProvider? get _activeProvider => _provider;
  bool _sending = false;

  Future<void> _send([String? quickPrompt]) async {
    if (_sending) return;
    final link = ws.link;
    if (link == null) {
      ws.toast(ws.entry?.isLocal == true ? '本地 agent 未连接' : '服务器未连接', error: true);
      return;
    }
    final prov = _activeProvider;
    if (prov == null || prov.model.trim().isEmpty) {
      await showAiSettingsDialog(context, app: ws.app, ws: ws);
      return;
    }
    final text = (quickPrompt ?? _inputCtl.text).trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    final sentAttachments = List<AiAttachment>.of(_attachments);
    final sentRoot=_root, sentWorkdir=_workdir, sentAgent=_agentMode, sentPermission=_permMode;
    final inputBefore = _inputCtl.text;
    setState(() { _sending = true; });
    _scrollCtl.followLatest();

    try {
      final prepared = await prepareAiProvider(ws.app, link, prov);
      if (!mounted || !identical(link, ws.link)) return;
      if (_activeProvider?.id != prov.id || _activeProvider?.model != prov.model) throw StateError('模型选择已变更，请确认后重新发送');
      final attachments=<Map<String,dynamic>>[];
      for(final a in sentAttachments){
        if(a.bytes==null){attachments.add(a.toJson());continue;}
        final cached=_uploadedAttachments[a];
        if(cached!=null&&identical(cached.$1,link)){attachments.add(cached.$2);continue;}
        final result=await uploadAiAttachment(link,a,active:()=>mounted&&identical(ws.link,link),progress:(p){if(mounted)setState(()=>_attachmentNote='正在上传 ${a.label} · ${(p*100).round()}%');});
        _uploadedAttachments[a]=(link,result);
        attachments.add(result);
      }
      if(!mounted||!identical(link,ws.link))return;
      final res = await link.call('ai.run', {
        if (_sessionId != null) 'session_id': _sessionId,
        'root': sentRoot,
        'workdir': sentWorkdir,
        'agent': sentAgent,
        'permission_mode': sentPermission,
        'text': text,
        if (attachments.isNotEmpty) 'attachments': attachments,
        'provider': prepared.toWireJson(),
      }) as Map;
      if (!mounted) return;
      if (quickPrompt == null && _inputCtl.text == inputBefore) _inputCtl.clear();
      setState(() => _attachments.removeWhere(sentAttachments.contains));
      for(final a in sentAttachments){_uploadedAttachments.remove(a);}
      final sum = AiSessionSummary.fromJson((res['session'] as Map).cast<String, dynamic>());
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
      _scrollToBottom();
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    } on Object catch (e) {
      ws.toast(e is StateError ? e.message : '发送失败，输入和附件已保留', error:true);
    } finally {
      if (mounted) setState(() { _sending = false; _attachmentNote=null; });
    }
  }

  Future<void> _stop() async {
    final link = ws.link;
    final sid = _sessionId;
    if (link == null || sid == null) return;
    await ws.guard(() => link.call('ai.stop', {'id': sid}));
  }

  Future<void> _approve(AiPermissionQuestion q, {required bool allow, bool always = false}) async {
    final link = ws.link;
    if (link == null) return;
    setState(() => _pendingPerm = null);
    await ws.guard(() => link.call('ai.approve', {
          'id': q.id,
          'allow': allow,
          'always': always,
        }));
  }

  Future<void> _revertTo(AiMessage msg) async {
    final link = ws.link;
    final sid = _sessionId;
    if (link == null || sid == null) return;
    final ok = await confirmDialog(
      context,
      title: '回退到此消息之前？',
      body: '将通过影子 Git 快照恢复此消息及之后智能体修改过的所有文件，并截断后续对话记录。',
      ok: '回退文件与对话',
      danger: true,
    );
    if (!ok || !mounted) return;
    final res = await ws.guard(() => link.call('ai.revert', {
          'session_id': sid,
          'message_id': msg.id,
          'files': true,
        }));
    if (res is Map) {
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
    setState(() => _running = true);
    try {
      final prepared = await prepareAiProvider(ws.app, link, prov);
      await link.call('ai.compact', {
        'session_id': sid,
        'provider': prepared.toWireJson(),
      });
      await _loadSession(link, sid);
      ws.toast('上下文已按 OpenCode 检查点模板压缩');
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    } on Object catch (e) {
      ws.toast(e is StateError ? e.message : '压缩失败，请检查连接', error:true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _attachActiveFile() async {
    final link = ws.link;
    final activeFile = ws.tab(ws.editorActiveId ?? '')?.file;
    if (link == null || activeFile == null) {
      ws.toast('请先在编辑器中打开一个文件，或使用「浏览服务器文件」');
      return;
    }
    try {
      _addAttachments([await readAiRemoteFile(link,activeFile.root,activeFile.path)]);
    } on Object catch (e) {
      _attachmentError(e);
    }
  }

  Future<void> _attachFileByPath() async {
    final link = ws.link;
    if (link == null) return;
    final choice=await showAiPathPicker(context,link:link,roots:_roots,root:_root,path:_workdir,directory:false);
    if (choice == null) return;
    try {
      _addAttachments([await readAiRemoteFile(link,choice.root,choice.path)]);
    } on Object catch (e) {
      _attachmentError(e);
    }
  }

  Future<void> _pickWorkdir() async {
    final link=ws.link;if(link==null)return;
    final next=await showAiPathPicker(context,link:link,roots:_roots,root:_root,path:_workdir);
    if (next == null || !mounted || !identical(link,ws.link)) return;
    setState(() {
      _root=next.root;_workdir=next.path;
    });
  }

  void _attachmentError(Object e){if(mounted)ws.toast(e is StateError?e.message:e is OpError?e.message:e is PlatformException?e.message??'无法读取剪贴板':'附件读取失败，请重试',error:true);}
  void _addAttachments(List<AiAttachment> list){
    if(!mounted)return;
    if(_attachments.length+list.length>8)throw StateError('每条消息最多 8 个附件');
    final total=[..._attachments,...list].fold<int>(0,(n,a)=>n+(a.bytes?.length??utf8.encode(a.content).length));
    if(total>aiAttachmentTotalLimit)throw StateError('每条消息附件总大小不能超过 20 MiB');
    setState(()=>_attachments.addAll(list));
  }
  Future<void> _pickLocalFiles() async {try{_addAttachments(await pickAiLocalFiles());}on Object catch(e){_attachmentError(e);}}
  Future<void> _paste() async {
    if(_pasteBusy)return;_pasteBusy=true;
    try{
      final files=await readAiClipboardFiles();
      if(!mounted)return;
      if(files.isNotEmpty){_addAttachments(files);return;}
      final text=await Clipboard.getData(Clipboard.kTextPlain);
      if(!mounted||text?.text==null)return;
      final value=_inputCtl.value;
      final selection=value.selection.isValid?value.selection:TextSelection.collapsed(offset:value.text.length);
      final inserted=text!.text!;
      _inputCtl.value=TextEditingValue(text:value.text.replaceRange(selection.start,selection.end,inserted),selection:TextSelection.collapsed(offset:selection.start+inserted.length));
    }on Object catch(e){_attachmentError(e);}finally{_pasteBusy=false;}
  }
  Future<void> _insertContent(KeyboardInsertedContent content) async {
    try{
      if(content.data!=null){_addAttachments([aiAttachmentFromBytes('keyboard.${content.mimeType.split('/').last}',content.data!)]);}
      else{_addAttachments(await readAiContentUri(content.uri));}
    }on Object catch(e){_attachmentError(e);}
  }

  void _setChatFontSize(double size) {
    ws.app.appearance.set('chatFont', size);
  }
  Widget _cachedMessageItem(Ide ide,AiMessage message){
    final old=_messageCache[message];
    if(old!=null&&identical(old.$1,ide)&&old.$2==_running&&old.$3==_chatFontSize&&identical(old.$4,ws.link))return old.$5;
    final child=_buildMessageItem(ide,message);
    if(_messageCache.length>=100)_messageCache.clear();
    _messageCache[message]=(ide,_running,_chatFontSize,ws.link,child);
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (ws.link == null) return NotConnected(ws: ws);
    if (_loading && _session == null) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error != null && _session == null) {
      return EmptyHint(
        icon: Icons.error_outline_rounded,
        text: _error!,
        actionLabel: '重试',
        onAction: () => _sessionId != null && ws.link != null ? _loadSession(ws.link!, _sessionId!) : null,
      );
    }

    final prov = _activeProvider;
    final messages = (_session?.messages ?? const <AiMessage>[]).where((m) => !m.isSystemReminder).toList();
    final todos = _session?.todos ?? const <AiTodoItem>[];

    return LayoutBuilder(builder: (_, constraints) {
    final short = constraints.maxHeight < 420;
    return CallbackShortcuts(bindings: {
      const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => _navigateMessage(messages, -1),
      const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => _navigateMessage(messages, 1),
      const SingleActivator(LogicalKeyboardKey.end, control: true): () => _scrollCtl.followLatest(),
    }, child: DefaultTextStyle.merge(style:const TextStyle(fontFamily:Ide.ui,fontFamilyFallback:Ide.uiFallback),child:Column(
      children: [
        _buildMessageNavigation(ide, messages),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_eventNote != null || _error != null) MaterialBanner(
          content: Text(_error ?? _eventNote!, style: const TextStyle(fontSize: 12)),
          actions: [TextButton(onPressed: () { if (_sessionId != null && ws.link != null) unawaited(_loadSession(ws.link!, _sessionId!)); }, child: const Text('重新同步'))],
        ),
        Expanded(
          child: messages.isEmpty && !_running
              ? _buildEmptyWelcome(ide, prov)
              : AiTranscript(
                   controller: _scrollCtl,
                   ids: [for (final message in messages) message.id,
                     if (_running||_activities.isNotEmpty||_liveReasoning.isNotEmpty||_liveText.isNotEmpty||_liveTools.isNotEmpty||_liveCompaction.isNotEmpty) '@live',
                     if (_pendingPerm != null) '@permission'],
                   itemBuilder:(context,index){
                     if(index<messages.length){final msg=messages[index];return Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Center(
                         child: ConstrainedBox(
                           constraints: const BoxConstraints(maxWidth: 760),
                           child: RepaintBoundary(key:ValueKey(msg.id),child:_cachedMessageItem(ide, msg)),
                         ),
                       ));}
                     if(index==messages.length&&(_running||_activities.isNotEmpty||_liveReasoning.isNotEmpty||_liveText.isNotEmpty||_liveTools.isNotEmpty||_liveCompaction.isNotEmpty)){return Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Center(
                         child: ConstrainedBox(
                           constraints: const BoxConstraints(maxWidth: 760),
                           child: Column(children: [if (_activities.isNotEmpty) _buildActivities(ide), _buildLiveStep(ide)]),
                         ),
                       ));}
                     return Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Center(
                         child: ConstrainedBox(
                           constraints: const BoxConstraints(maxWidth: 760),
                          child: Padding(
                            padding: const EdgeInsets.only(top: Space.m),
                            child: _buildPermissionCard(ide, _pendingPerm!),
                          ),
                        ),
                       ));
                  },
                ),
        ),
        if (!short && todos.any((t) => t.status != 'completed' && t.status != 'cancelled')) _buildTodoBanner(ide, todos),
        if (!short) _buildRuntimeBar(ide, prov),
        _buildComposer(ide, prov, compact: short),
      ],
    )));
    });
  }

  void _navigateMessage(List<AiMessage> messages, int step) {
    if (messages.isEmpty) return;
    final index = messages.indexWhere((m) => m.id == _scrollCtl.currentMessage.value);
    final at = index < 0 ? messages.length - 1 : index;
    _scrollCtl.reveal(messages[(at + step).clamp(0, messages.length - 1)].id);
  }

  Widget _buildMessageNavigation(Ide ide, List<AiMessage> messages) => Container(
    key: const ValueKey('ai-message-navigation'), height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: ValueListenableBuilder<String?>(valueListenable: _scrollCtl.currentMessage, builder: (_, current, _) {
      final index = messages.indexWhere((m) => m.id == current);
      final at = index < 0 ? messages.length - 1 : index;
      String label(AiMessage m) {
        final text = m.parts.where((p) => p.type == 'text').map((p) => p.text).join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
        return '${m.role == 'user' ? '你' : m.role == 'assistant' ? 'AI' : '检查点'} · ${text.isEmpty ? '工具与执行记录' : text}';
      }
      return Row(children: [
        IconButton(key: const ValueKey('ai-previous-message'), tooltip: '上一条消息（Alt+↑）', padding: EdgeInsets.zero, constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          onPressed: at > 0 ? () => _scrollCtl.reveal(messages[at - 1].id) : null, icon: const Icon(Icons.arrow_upward, size: 15)),
        Expanded(child: PopupMenuButton<String>(key: const ValueKey('ai-message-anchors'), tooltip: '对话锚点 · 跳转到消息', onSelected: _scrollCtl.reveal,
          itemBuilder: (_) => [for (var i = 0; i < messages.length; i++) PopupMenuItem(value: messages[i].id, child: SizedBox(width: 300, child: Text('${i + 1}. ${label(messages[i])}', maxLines: 2, overflow: TextOverflow.ellipsis)))],
          child: Text(messages.isEmpty ? '对话锚点' : '${at + 1}/${messages.length}  ${label(messages[at])}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ide.textDim)))),
        IconButton(key: const ValueKey('ai-next-message'), tooltip: '下一条消息（Alt+↓）', padding: EdgeInsets.zero, constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          onPressed: at >= 0 && at < messages.length - 1 ? () => _scrollCtl.reveal(messages[at + 1].id) : null, icon: const Icon(Icons.arrow_downward, size: 15)),
        ValueListenableBuilder<bool>(valueListenable: _scrollCtl.followsLatest, builder: (_, follows, _) => IconButton(
          key: const ValueKey('ai-jump-latest'), tooltip: follows ? '已在最新消息' : '回到最新消息', padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28), onPressed: () => _scrollToBottom(force: true),
          icon: Icon(Icons.vertical_align_bottom, size: 16, color: follows ? ide.textFaint : ide.accent))),
        _buildConversationActions(ide),
      ]);
    }),
  );

  Widget _buildConversationActions(Ide ide) {
    final canPickDir = !_sending&&(_session == null || _session!.messages.isEmpty);

    return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Root & Workdir badge
          SizedBox(width:28, child:PopupMenuButton<AiPathChoice>(
            key:const ValueKey('ai-workdir-menu'),enabled:canPickDir,padding:EdgeInsets.zero,
            tooltip:'${ws.entry?.isLocal == true ? ws.app.localAgent.nativePath(_root,_workdir) : '$_root : $_workdir'}\n${canPickDir ? '选择工作目录' : '会话目录固定'}',
            onSelected:(choice){if(choice.root=='*browse*'){_pickWorkdir();}else{setState((){_root=choice.root;_workdir=choice.path;});}},
            itemBuilder:(_)=>[
              for(final folder in ws.project?.folders ?? const <WorkspacePath>[]) PopupMenuItem(value:AiPathChoice(folder.root,folder.path,folder.path),child:Text('项目：${folder.path}')),
              for(final r in _roots) PopupMenuItem(value:AiPathChoice(r['id'] as String,'/','/'),child:Text('${r['label']??r['id']} /')),
              const PopupMenuDivider(),
              PopupMenuItem(value:const AiPathChoice('*browse*','',''),child:Row(children:[const Icon(Icons.folder_open,size:18),const SizedBox(width:8),Text(ws.entry?.isLocal == true ? '浏览本机目录…' : '浏览服务器目录…')])),
            ],
            icon:Icon(Icons.folder_open_outlined,size:16,color:ide.textDim),
          )),
          SizedBox(width:28, child:PopupMenuButton<String>(key:const ValueKey('ai-chat-font'),tooltip:'对话选项',padding:EdgeInsets.zero,onSelected:(value){
            if(value=='smaller')_setChatFontSize(_chatFontSize-1);
            if(value=='larger')_setChatFontSize(_chatFontSize+1);
            if(value=='reset')_setChatFontSize(15);
            if(value=='compact')_compactManual();
            if(value=='details')setState(()=>_runtimeExpanded=!_runtimeExpanded);
            if(value=='models')showAiSettingsDialog(context,app:ws.app,ws:ws);
          },itemBuilder:(_)=>[
            const PopupMenuItem(value:'models',child:Text('模型与 API Key…')),
            const PopupMenuItem(value:'details',child:Text('模型与上下文详情')),
            PopupMenuItem(value:'compact',enabled:!_running && (_session?.messages.isNotEmpty??false),child:const Text('压缩上下文')),
            const PopupMenuDivider(),
            const PopupMenuItem(value:'smaller',child:Text('缩小字号')),
            const PopupMenuItem(value:'larger',child:Text('增大字号')),
            const PopupMenuItem(value:'reset',child:Text('还原字号 · 15 px')),
          ],icon:Icon(Icons.more_horiz,size:17,color:ide.textDim))),
        ],
    );
  }

  Widget _buildRuntimeBar(Ide ide, AiProvider? prov) {
    if (!_runtimeExpanded) return const SizedBox.shrink(key: ValueKey('ai-runtime-bar'));
    final runtime = _session?.runtime;
    final ctx = _session?.context;
    final usage = _session?.totalUsage;
    final ratio = ctx?.ratio;
    final color = ratio != null && ratio >= 1 ? ide.error : ratio != null && ratio >= 0.85 ? ide.warn : ide.accent;
    final actual = runtime?.label ?? (_session?.model.isNotEmpty == true ? '未知提供商 / ${_session!.model}（旧会话）' : '尚未调用模型');
    final contextText = ctx == null ? '上下文：暂无统计（旧 agent / 尚未调用）' : '上下文 ${ctx.estimated ? '≈' : ''}${_fmtTokens(ctx.tokens)} / ${ctx.limit > 0 ? _fmtTokens(ctx.limit) : '未知'} tokens${ratio != null ? ' · ${(ratio * 100).toStringAsFixed(1)}%' : ''}';
    return Container(
      key:const ValueKey('ai-runtime-bar'), width:double.infinity,
      padding:const EdgeInsets.symmetric(horizontal:Space.l),
      decoration:BoxDecoration(border:Border(bottom:BorderSide(color:ide.border))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
        SizedBox(height:32,child:Row(children:[
          Expanded(child:Tooltip(message:'本步实际发送的提供商配置与模型 ID；网关可能自行映射模型，无法认证其内部模型身份。\n$actual',child:Text('${_running ? '本步实际' : '最近实际'}：$actual',key:const ValueKey('ai-actual-model'),maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:11.5,color:ide.textDim)))),
          const SizedBox(width:12),
          Tooltip(message:contextText,child:Text(ratio==null?'暂无统计':'上下文 ≈${(ratio*100).toStringAsFixed(0)}%',key:const ValueKey('ai-context-summary'),style:TextStyle(fontSize:11,color:ratio!=null&&ratio>=.85?color:ide.textDim))),
          const SizedBox(width:4),
          IconBtn(_runtimeExpanded?Icons.expand_less:Icons.expand_more,'模型与上下文详情',()=>setState(()=>_runtimeExpanded=!_runtimeExpanded),size:16),
        ])),
        if(_runtimeExpanded)...[
        Text('下次调用：${prov == null ? '未配置' : '${prov.name} / ${prov.model}'}', key:const ValueKey('ai-next-model'), style:TextStyle(fontSize:11.5, color:ide.textDim)),
        const SizedBox(height:6),
        Wrap(spacing:16, runSpacing:4, crossAxisAlignment:WrapCrossAlignment.center, children:[
          Tooltip(message:ctx == null ? '需新版 agent；累计用量不代表当前上下文。' : '活动上下文估算（包括系统提示、工具定义、回答与工具输出），不含尚未发送的输入。图片/PDF 使用粗略估值，不按 base64 长度计算。\n上次实际输入：${ctx.lastInput > 0 ? '${ctx.lastInput} tokens（已含缓存）' : '暂无 / 已压缩或回退'}\n上限来源：${ctx.limitSource == 'configured' ? '目录 / 手动配置' : '模型默认输入预算（可能与真实窗口不同）'}。\n压缩后重新估算；累计用量另列。', child:Text(contextText, key:const ValueKey('ai-context-usage'), style:TextStyle(fontSize:11.5, color:color))),
          if (usage != null && usage.totalTokens > 0)
            Tooltip(message:'累计输入 ${usage.inputTokens}（含缓存 ${usage.cacheReadTokens}）· 输出 ${usage.outputTokens}', child:Text('累计用量 ${_fmtTokens(usage.totalTokens)} tokens', key:const ValueKey('ai-total-usage'), style:TextStyle(fontSize:11, color:ide.textFaint))),
        ]),
        if (ratio != null) ...[const SizedBox(height:5), LinearProgressIndicator(value:ratio.clamp(0.0,1.0), minHeight:3, color:color, backgroundColor:ide.border)],
        const SizedBox(height:8),
        ],
      ]),
    );
  }

  Widget _buildTodoBanner(Ide ide, List<AiTodoItem> todos) {
    final done = todos.where((t) => t.status == 'completed').length;
    return Container(
      width: double.infinity,
      key: const ValueKey('ai-active-plan'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: ide.sideBar.withValues(alpha: 0.7),
        border: Border(bottom: BorderSide(color: ide.border)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(onTap: () => setState(() => _planExpanded = !_planExpanded), child: SizedBox(height: 28, child: Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 15, color: ide.accent),
                  const SizedBox(width: 6),
                  Text('任务进度 ($done/${todos.length})', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.text)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(todos.where((t) => t.status == 'in_progress').firstOrNull?.content ?? '计划进行中', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ide.textDim))),
                  Icon(_planExpanded ? Icons.expand_less : Icons.expand_more, size: 16, color: ide.textDim),
                ],
              ))),
              if (_planExpanded) ConstrainedBox(constraints: const BoxConstraints(maxHeight: 140), child: SingleChildScrollView(child: Column(
                children: [
                  for (final t in todos)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(
                      children: [
                        Icon(
                          t.status == 'completed'
                              ? Icons.check_circle_rounded
                              : t.status == 'in_progress'
                                  ? Icons.timelapse_rounded
                                  : Icons.radio_button_unchecked_rounded,
                          size: 13,
                          color: t.status == 'completed'
                              ? ide.ok
                              : t.status == 'in_progress'
                                  ? ide.accent
                                  : ide.textFaint,
                        ),
                        const SizedBox(width: 4),
                        Expanded(child: Text(
                          t.content,
                          style: TextStyle(
                            fontSize: 12,
                            color: t.status == 'completed' ? ide.textDim : ide.text,
                            decoration: t.status == 'completed' ? TextDecoration.lineThrough : null,
                          ),
                        )),
                      ],
                    )),
                ],
              ))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyWelcome(Ide ide, AiProvider? prov) {
    final hasKey = prov != null && prov.model.isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: ide.accentSoft,
                  borderRadius: BorderRadius.circular(Radii.island + 2),
                ),
                child: Icon(Icons.auto_awesome_rounded, size: 24, color: ide.accent),
              ),
              const SizedBox(height: Space.l),
              Text('Aurora AI 工作台', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ide.text)),
              const SizedBox(height: Space.xs + 2),
              Text(
                ws.entry?.isLocal == true ? '直接阅读和修改本机项目、搜索代码、调用 PowerShell。无需服务器，工具执行仍遵循批准设置。' : '阅读和修改远程代码、搜索仓库、执行 shell；工作状态面板可查看子代理和命令输出。支持 OpenCode 兼容协议及影子 Git 回退。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: ide.textDim, height: 1.5),
              ),
              const SizedBox(height: Space.xl),
              if (!hasKey)
                FilledButton.icon(
                  key: const ValueKey('ai-configure-btn'),
                  onPressed: () => showAiSettingsDialog(context, app: ws.app, ws: ws),
                  icon: const Icon(Icons.key_rounded, size: 16),
                  label: const Text('配置 OpenCode 模型与 API Key'),
                )
              else
                Wrap(
                  spacing: Space.s + 2,
                  runSpacing: Space.s + 2,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final (icon, label, prompt) in const [
                      (Icons.explore_outlined, '梳理项目结构', '请快速浏览当前目录结构与核心代码，总结架构与技术栈。'),
                      (Icons.monitor_heart_outlined, '排查服务器负载与日志', '请检查当前服务器的 CPU、内存、磁盘状态及近期异常服务日志，给出诊断建议。'),
                      (Icons.bug_report_outlined, '查找潜在问题', '请检查最近修改的代码与 git 状态，看看是否有明显的 bug、构建错误或遗漏。'),
                    ])
                      ActionChip(
                        avatar: Icon(icon, size: 15, color: ide.accent),
                        label: Text(label, style: const TextStyle(fontSize: 12.5)),
                        onPressed: () => _send(prompt),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageItem(Ide ide, AiMessage msg) {
    if (msg.role == 'compaction') {
      final summary = msg.parts.firstOrNull?.text ?? '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.m),
        child: _CollapsibleBlock(
          icon: Icons.inventory_2_outlined,
          title: '上下文检查点摘要 (OpenCode Compaction)',
          accent: ide.accent,
          initiallyExpanded: false,
          child: SelectableText(summary, style: TextStyle(fontSize: 12.5, color: ide.textDim, height: 1.5)),
        ),
      );
    }

    if (msg.role == 'user') {
      final text = msg.parts.map((p) => p.text).where((s) => s.isNotEmpty).join('\n\n');
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.l),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.m + 2),
                decoration: BoxDecoration(
                  color: ide.sideBar,
                  borderRadius: BorderRadius.circular(Radii.l + 2),
                  border: Border.all(color: ide.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(Radii.s),
                          ),
                          child: Text(
                            '你',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: msg.agent == 'plan' ? ide.warn : ide.accent,
                            ),
                          ),
                        ),
                        const Spacer(),
                        if (!_running)
                          Tooltip(
                            message: '回退到此消息之前（恢复后续修改的文件）',
                            child: InkWell(
                              onTap: () => _revertTo(msg),
                              borderRadius: BorderRadius.circular(Radii.s),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.undo_rounded, size: 13, color: ide.textFaint),
                                    const SizedBox(width: 3),
                                    Text('回退', style: TextStyle(fontSize: 11, color: ide.textFaint)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: Space.xs + 2),
                    if(text.isNotEmpty) SelectableText(text, style: TextStyle(fontFamily:Ide.ui,fontFamilyFallback:Ide.uiFallback,fontSize:_chatFontSize,color:ide.text,height:1.65)),
                    for(final part in msg.parts) if(part.attachmentId.isNotEmpty&&ws.link!=null) Padding(padding:const EdgeInsets.only(top:8),child:AiAttachmentTile(key:ValueKey(part.attachmentId),part:part,link:ws.link!)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Assistant message: pair tool-call parts with their corresponding tool-result parts
    final resultMap = <String, AiPart>{
      for (final p in msg.parts)
        if (p.type == 'tool-result' && p.toolCallId.isNotEmpty) p.toolCallId: p,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.l + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (msg.role == 'assistant') Padding(
            padding:const EdgeInsets.only(bottom:Space.s),
            child:Row(children:[Expanded(child:Text(msg.runtime?.label ?? '未知提供商 / ${msg.model.isEmpty ? '未知模型' : msg.model}（旧记录）',style:TextStyle(fontSize:12,color:ide.textDim))),IconBtn(Icons.copy_outlined,'复制回答',()=>copyText(msg.parts.where((p)=>p.type=='text').map((p)=>p.text).join('\n\n'),what:'回答已复制'),size:15)]),
          ),
          for (final p in msg.parts)
            if (p.type == 'reasoning' && p.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: _CollapsibleBlock(
                  icon: Icons.psychology_outlined,
                  title: '思考过程',
                  accent: ide.textDim,
                  initiallyExpanded: false,
                  child: SelectableText(p.text.trim(), style: TextStyle(fontSize: 12.5, color: ide.textDim, height: 1.5)),
                ),
              )
            else if (p.type == 'text' && p.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s + 2),
                child: _MarkdownText(text: p.text.trim(),fontSize:_chatFontSize),
              )
            else if (p.type == 'tool-call')
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: _ToolCallCard(
                  name: p.toolName,
                  inputJson: p.inputJson,
                  output: resultMap[p.toolCallId]?.output ?? '',
                  isError: resultMap[p.toolCallId]?.isError ?? false,
                  running: false,
                  metadata: resultMap[p.toolCallId]?.metadata ?? const {},
                ),
              ),
          if (msg.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Notice(tone: Tone.error, title: '模型请求中断或报错', body: msg.error),
            ),
          if (msg.snapshot != null && msg.snapshot!.files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: _StepDiffCard(files: msg.snapshot!.files),
            ),
        ],
      ),
    );
  }

  Widget _buildActivities(Ide ide) {
    return Material(color: ide.sideBar, child: Container(
      key: const ValueKey('ai-active-work'),
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ide.border))),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Text('正在工作 · ${_activities.length} 项', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: ide.accent))),
        for (final a in _activities.values) Builder(builder: (context) {
          final name = a['tool_name'] as String? ?? '工具';
          final child = a['session_id'] != _sessionId;
          Map args = const {};
          try { args = a['input'] is Map ? a['input'] as Map : jsonDecode(a['input'] as String? ?? '{}') as Map; } on Object { /* partial tool arguments */ }
          final label = name == 'shell' ? '${args['command'] ?? '启动 shell…'}' : name == 'subagent' ? '${args['description'] ?? '子代理'}' : '$name · ${args['path'] ?? args['pattern'] ?? ''}';
          final output = a['output'] as String? ?? '';
          final childId = child ? a['session_id'] as String? : (a['metadata'] as Map?)?['child_session_id'] as String?;
          final proxy = switch ((a['metadata'] as Map?)?['proxy_mode']) { 'agent' => '执行端代理', 'environment' => '继承环境 / 系统代理', 'direct' => '未发现代理变量', _ => '跟随执行环境' };
          return ExpansionTile(
            key: ValueKey('activity-${a['session_id']}-${a['tool_call_id']}'),
            dense: true,
            leading: Icon(name == 'shell' ? Icons.terminal : name == 'subagent' ? Icons.account_tree_outlined : Icons.build_outlined, size: 17, color: ide.accent),
            title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            subtitle: Text(child ? '子代理 · ${a['session_title'] ?? ''}${name == 'shell' ? ' · $proxy' : ''}' : name == 'shell' ? 'Shell 正在执行 · $proxy' : name == 'subagent' ? '子代理运行中 · ${args['agent'] ?? 'explore'}' : '主代理正在执行', style: TextStyle(fontSize: 11, color: ide.textDim)),
            children: [
              if (childId != null) TextButton.icon(onPressed: () => ws.openTab(aiStudioTab(ws, sessionId: childId, title: child ? a['session_title'] as String? ?? '子代理' : args['description'] as String? ?? '子代理')), icon: const Icon(Icons.open_in_new, size: 14), label: const Text('查看子代理会话')),
              Padding(padding: const EdgeInsets.all(12), child: Align(alignment: Alignment.centerLeft, child: SelectableText(output.isEmpty ? '等待输出…' : output, style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 11.5, color: ide.text)))),
            ],
          );
        }),
      ])),
    ));
  }

  Widget _buildLiveStep(Ide ide) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_liveCompaction.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: _CollapsibleBlock(
                icon: Icons.compress_rounded,
                title: '正在生成检查点摘要…',
                accent: ide.accent,
                initiallyExpanded: true,
                child: SelectableText(_liveCompaction, style: TextStyle(fontSize: 12.5, color: ide.textDim)),
              ),
            ),
          if (_liveReasoning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: _CollapsibleBlock(
                icon: Icons.psychology_outlined,
                title: '正在思考…',
                accent: ide.accent,
                initiallyExpanded: true,
                child: SelectableText(_liveReasoning, style: TextStyle(fontSize: 12.5, color: ide.textDim, height: 1.5)),
              ),
            ),
          if (_liveText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s + 2),
              child: _MarkdownText(text: _liveText,fontSize:_chatFontSize),
            ),
          for (final t in _liveTools)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: _ToolCallCard(
                name: t.name,
                inputJson: t.inputJson,
                output: t.output,
                isError: t.isError,
                running: t.running,
                metadata: t.metadata,
              ),
            ),
          if (_liveReasoning.isEmpty && _liveText.isEmpty && _liveTools.isEmpty && _liveCompaction.isEmpty && _running)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s),
              child: Row(
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Space.m),
                  Text('正在等待模型响应…', style: TextStyle(fontSize: 12.5, color: ide.textDim)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPermissionCard(Ide ide, AiPermissionQuestion q) {
    return Container(
      padding: const EdgeInsets.all(Space.l),
      decoration: BoxDecoration(
        color: ide.warn.withValues(alpha: ide.isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(Radii.l + 2),
        border: Border.all(color: ide.warn.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: ide.warn),
              const SizedBox(width: Space.s + 2),
              Expanded(
                child: Text(
                  '需要授权执行 ${q.tool}',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.text),
                ),
              ),
            ],
          ),
          if (q.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(q.reason, style: TextStyle(fontSize: 12, color: ide.textDim)),
          ],
          const SizedBox(height: Space.s),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Space.s + 2),
            decoration: BoxDecoration(
              color: ide.editor,
              borderRadius: BorderRadius.circular(Radii.m),
              border: Border.all(color: ide.border),
            ),
            child: SelectableText(
              q.resource,
              style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 12, color: ide.text),
            ),
          ),
          const SizedBox(height: Space.m),
          Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: () => _approve(q, allow: false),
                child: Text('拒绝', style: TextStyle(color: ide.error)),
              ),
              OutlinedButton(
                onPressed: () => _approve(q, allow: true, always: true),
                child: const Text('本会话始终允许'),
              ),
              FilledButton(
                key: const ValueKey('ai-approve-once'),
                onPressed: () => _approve(q, allow: true),
                child: const Text('允许本次'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(Ide ide, AiProvider? prov, {bool compact = false}) {
    final activeFile = ws.tab(ws.editorActiveId ?? '')?.file;
    return LayoutBuilder(builder: (_, box) {
    final narrow = box.maxWidth < 460;
    return Container(
      key: const ValueKey('ai-composer'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: ide.editor,
        border: Border(top: BorderSide(color: ide.border)),
      ),
      child: Center(
        child: ConstrainedBox(
           constraints: const BoxConstraints(maxWidth: 760),
           child: Padding(
             padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.s),
                    child:ConstrainedBox(constraints:const BoxConstraints(maxHeight:110),child:SingleChildScrollView(child:Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var i = 0; i < _attachments.length; i++)
                          InputChip(
                            visualDensity: VisualDensity.compact,
                            avatar: _attachments[i].mime.startsWith('image/')&&_attachments[i].bytes!=null?ClipRRect(borderRadius:BorderRadius.circular(4),child:Image.memory(_attachments[i].bytes!,width:28,height:28,cacheWidth:64,fit:BoxFit.cover,errorBuilder:(_,_,_)=>const Icon(Icons.broken_image_outlined,size:16))):Icon(_attachments[i].mime=='application/pdf'?Icons.picture_as_pdf_outlined:Icons.description_outlined,size:16),
                            label: ConstrainedBox(constraints:const BoxConstraints(maxWidth:200),child:Text('${_attachments[i].label}${_attachments[i].bytes!=null?' · ${(_attachments[i].bytes!.length/1024).toStringAsFixed(0)} KiB':''}',overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:12))),
                            onDeleted: () => setState(() {_uploadedAttachments.remove(_attachments[i]);_attachments.removeAt(i);}),
                          ),
                      ],
                    ))),
                  ),
                if(_attachments.isNotEmpty) Padding(padding:const EdgeInsets.only(bottom:8),child:Text(ws.entry?.isLocal == true ? '发送时复制到本地 agent 私有目录用于历史重放；模型调用会把附件发给提供商。' : '发送时上传并保存到服务器 AI 私有目录，供历史重放；图片/PDF 需模型支持。',maxLines:2,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:11.5,color:ide.textDim,height:1.5))),
                if(_attachmentNote!=null) Padding(padding:const EdgeInsets.only(bottom:8),child:Text(_attachmentNote!,style:TextStyle(fontSize:12,color:ide.accent))),
                Shortcuts(shortcuts:const{
                  SingleActivator(LogicalKeyboardKey.keyV,control:true):_AiPasteIntent(),
                  SingleActivator(LogicalKeyboardKey.keyV,meta:true):_AiPasteIntent(),
                },child:Actions(actions:{_AiPasteIntent:CallbackAction<_AiPasteIntent>(onInvoke:(_){unawaited(_paste());return null;})},child:Focus(
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.enter &&
                        !HardwareKeyboard.instance.isShiftPressed &&
                        !(_inputCtl.value.composing.isValid&&!_inputCtl.value.composing.isCollapsed)) {
                      _send();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    key: const ValueKey('ai-prompt-input'),
                    controller: _inputCtl,
                    focusNode: _inputFocus,
                    minLines: compact ? 1 : 2,
                    maxLines: compact ? 2 : box.maxWidth<600?3:6,
                    style: TextStyle(fontFamily:Ide.ui,fontFamilyFallback:Ide.uiFallback,fontSize:_chatFontSize,color:ide.text,height:1.5),
                    contentInsertionConfiguration:ContentInsertionConfiguration(allowedMimeTypes:const ['image/png','image/jpeg','image/gif','image/webp','application/pdf','text/plain'],onContentInserted:(c)=>unawaited(_insertContent(c))),
                    contextMenuBuilder:(context,state)=>AdaptiveTextSelectionToolbar.buttonItems(anchors:state.contextMenuAnchors,buttonItems:[
                      for(final item in state.contextMenuButtonItems) if(item.type!=ContextMenuButtonType.paste)item,
                      ContextMenuButtonItem(label:'粘贴 / 图片 / 文件',onPressed:(){state.hideToolbar();unawaited(_paste());}),
                    ]),
                    decoration: InputDecoration(
                      hintText: _running
                          ? '补充指令…'
                          : (_agentMode == 'plan' ? '规划任务，不修改文件…' : '向 AI 提问，或描述要完成的任务…'),
                      filled: false,
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ))),
                const SizedBox(height: Space.s + 2),
                 SizedBox(height: 32, child: Row(
                   children: [
                     Expanded(child: _buildModelChoice(ide, prov)),
                    // Build / Plan switcher
                    _ModePill(
                      label: _agentMode == 'plan' ? (narrow ? 'Plan' : 'Plan 规划') : (narrow ? 'Build' : 'Build 构建'),
                      icon: _agentMode == 'plan' ? Icons.architecture_rounded : Icons.build_circle_outlined,
                      color: _agentMode == 'plan' ? ide.warn : ide.accent,
                      onTap: () => setState(() => _agentMode = _agentMode == 'plan' ? 'build' : 'plan'),
                    ),
                    const SizedBox(width: 4),
                    // Ask / Auto permission switcher
                    _ModePill(
                      label: _permMode == 'auto' ? (narrow ? 'Auto' : 'Auto 自动执行') : (narrow ? 'Ask' : 'Ask 询问确认'),
                      icon: _permMode == 'auto' ? Icons.bolt_rounded : Icons.verified_user_outlined,
                      color: _permMode == 'auto' ? ide.ok : ide.textDim,
                      onTap: () => setState(() => _permMode = _permMode == 'auto' ? 'ask' : 'auto'),
                    ),
                    SizedBox(width: 30, child: PopupMenuButton<String>(padding: EdgeInsets.zero, key:const ValueKey('ai-attach-menu'),tooltip:'添加图片或文件',onSelected:(v){if(v=='active')_attachActiveFile();if(v=='local')_pickLocalFiles();if(v=='paste')_paste();if(v=='remote')_attachFileByPath();},itemBuilder:(_)=>[
                      if (activeFile != null) PopupMenuItem(value:'active',child:Text('附加当前文件：${activeFile.name}')),
                      const PopupMenuItem(value:'local',child:Text('选择本机图片 / 文件…')),
                      const PopupMenuItem(value:'paste',child:Text('粘贴图片 / 文件 / 文本')),
                      PopupMenuItem(value:'remote',child:Text(ws.entry?.isLocal == true ? '浏览本机项目文件…' : '浏览服务器文件…')),
                    ],icon:Icon(Icons.add,size:18,color:ide.textDim))),
                    if (_running) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: '停止当前运行',
                        child: InkWell(
                          key: const ValueKey('ai-stop-btn'),
                          onTap: _stop,
                          borderRadius: BorderRadius.circular(Radii.m),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                            decoration: BoxDecoration(
                              color: ide.error.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(Radii.m),
                              border: Border.all(color: ide.error.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.stop_rounded, size: 15, color: ide.error),
                                const SizedBox(width: 3),
                                if (!narrow) Text('停止', style: TextStyle(fontSize: 12, color: ide.error, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    FilledButton(
                      key: const ValueKey('ai-send-btn'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        minimumSize: const Size(0, 30),
                      ),
                      onPressed: _sending ? null : _send,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_running ? Icons.subdirectory_arrow_left_rounded : Icons.arrow_upward_rounded, size: 15),
                          const SizedBox(width: 4),
                          if (!narrow) Text(_sending ? '准备中' : _running ? '引导' : '发送', style: const TextStyle(fontSize: 12.5)),
                        ],
                      ),
                    ),
                  ],
                )),
              ],
            ),
          ),
        ),
      ),
    );
    });
  }

  Widget _buildModelChoice(Ide ide, AiProvider? prov) => Row(children:[Expanded(child:Tooltip(
    message:prov==null?'选择模型':'${prov.name} / ${prov.model}${prov.reasoningEffort.isEmpty?'':' · ${aiEffortLabel(prov.reasoningEffort)}'}',child:InkWell(
    key: const ValueKey('ai-model-btn'), onTap: () => showAiModelPicker(context, ws),
    borderRadius: BorderRadius.circular(4),
    child: Row(children: [
      Icon(Icons.expand_more, size: 14, color: ide.textDim), const SizedBox(width: 4),
      Expanded(child: Text(prov == null || prov.model.isEmpty ? '选择模型…' : '${prov.name} / ${prov.model}',
        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: prov == null ? ide.warn : ide.textDim))),
     ]),
  ))), Tooltip(message:'模型与上下文详情',child:InkWell(onTap:()=>setState(()=>_runtimeExpanded=!_runtimeExpanded),
    child:Padding(padding:const EdgeInsets.symmetric(horizontal:4,vertical:6),child:Text(
      _session?.context?.ratio==null?'ⓘ':'${(_session!.context!.ratio!*100).round()}%',
      key:const ValueKey('ai-context-indicator'),style:TextStyle(fontSize:11,color:(_session?.context?.ratio??0)>=.85?ide.warn:ide.textDim))))) ]);

  String _fmtTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _ModePill extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ModePill({required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.m),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.m),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}

class _CollapsibleBlock extends StatefulWidget {
  final IconData icon;
  final String title;
  final Color accent;
  final bool initiallyExpanded;
  final Widget child;

  const _CollapsibleBlock({
    required this.icon,
    required this.title,
    required this.accent,
    required this.initiallyExpanded,
    required this.child,
  });

  @override
  State<_CollapsibleBlock> createState() => _CollapsibleBlockState();
}

class _CollapsibleBlockState extends State<_CollapsibleBlock> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      decoration: BoxDecoration(
        color: ide.sideBar.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(Radii.l),
        border: Border.all(color: ide.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.l),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
              child: Row(
                children: [
                  Icon(widget.icon, size: 14, color: widget.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(widget.title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ide.textDim)),
                  ),
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: ide.textFaint),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: ide.border),
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: widget.child,
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolCallCard extends StatefulWidget {
  final String name;
  final String inputJson;
  final String output;
  final bool isError;
  final bool running;
  final Map<String, dynamic> metadata;

  const _ToolCallCard({
    required this.name,
    required this.inputJson,
    required this.output,
    required this.isError,
    required this.running,
    this.metadata = const {},
  });

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _open = false;

  /// The pages a websearch found, from the tool result's metadata.
  List<({String title, String url})> get _sources => [
        for (final s in (widget.metadata['sources'] as List? ?? const []))
          if (s is Map && (s['url'] as String? ?? '').isNotEmpty) (title: (s['title'] as String?) ?? (s['url'] as String), url: s['url'] as String),
      ];

  String _host(String url) => Uri.tryParse(url)?.host ?? url;

  (IconData, String) _summary() {
    Map<String, dynamic> args = const {};
    if (widget.inputJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(widget.inputJson);
        if (decoded is Map) args = decoded.cast<String, dynamic>();
      } on Object {
        // ignore partial JSON
      }
    }
    final found = _sources.length;
    return switch (widget.name) {
      'read' => (Icons.visibility_outlined, '读取 ${args['path'] ?? args['filePath'] ?? ''}'),
      'edit' => (Icons.edit_note_rounded, '编辑 ${args['path'] ?? args['filePath'] ?? ''}'),
      'write' => (Icons.save_outlined, '写入 ${args['path'] ?? args['filePath'] ?? ''}'),
      'glob' => (Icons.manage_search_rounded, '匹配文件 ${args['pattern'] ?? ''}'),
      'grep' => (Icons.search_rounded, '搜索内容 ${args['pattern'] ?? ''}'),
      'shell' => (Icons.terminal_rounded, '\$ ${args['command'] ?? ''}'),
      'todowrite' => (Icons.checklist_rounded, '更新任务清单'),
      'websearch' => (Icons.travel_explore_rounded, '联网搜索「${args['query'] ?? ''}」${!widget.running && found > 0 ? ' · $found 个结果' : ''}'),
      'webfetch' => (Icons.language_rounded, '抓取网页 ${args['url'] == null ? '' : _host('${args['url']}')}'),
      'subagent' => (Icons.account_tree_outlined, '子智能体 (${args['agent'] ?? 'explore'}): ${args['description'] ?? ''}'),
      _ => (Icons.extension_outlined, widget.name),
    };
  }

  Widget _sourceList(Ide ide) {
    final list = _sources;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < list.length; i++)
        InkWell(
          key: ValueKey('ai-source-$i'),
          onTap: () => copyText(list[i].url, what: '链接已复制（不会自动打开）'),
          borderRadius: BorderRadius.circular(Radii.s),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: ide.accentSoft, borderRadius: BorderRadius.circular(Radii.s)),
                child: Text('${i + 1}', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: ide.accent)),
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(list[i].title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: ide.text, fontWeight: FontWeight.w500)),
                  Text(_host(list[i].url), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ide.textFaint)),
                ]),
              ),
              Icon(Icons.copy_rounded, size: 12, color: ide.textFaint),
            ]),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final (icon, label) = _summary();
    final statusColor = widget.running
        ? ide.accent
        : widget.isError
            ? ide.error
            : ide.ok;

    return Container(
      decoration: BoxDecoration(
        color: ide.sideBar.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(Radii.m + 2),
        border: Border.all(color: widget.isError ? ide.error.withValues(alpha: 0.45) : ide.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.m + 2),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: 7),
              child: Row(
                children: [
                  if (widget.running)
                    const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.8))
                  else
                    Icon(icon, size: 15, color: statusColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontFamily: widget.name == 'shell' ? Ide.mono : null,
                        fontFamilyFallback: widget.name == 'shell' ? Ide.monoFallback : null,
                        color: ide.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: ide.textFaint),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: ide.border),
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.name == 'websearch' && _sources.isNotEmpty) ...[
                    Text('来源', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ide.textFaint)),
                    const SizedBox(height: 3),
                    _sourceList(ide),
                    const SizedBox(height: Space.s),
                  ] else if (widget.inputJson.isNotEmpty) ...[
                    Text('参数', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ide.textFaint)),
                    const SizedBox(height: 3),
                    SelectableText(widget.inputJson, style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 11.5, color: ide.textDim)),
                    const SizedBox(height: Space.s),
                  ],
                  if (widget.output.isNotEmpty) ...[
                    Text('输出', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ide.textFaint)),
                    const SizedBox(height: 3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          widget.output,
                          style: TextStyle(
                            fontFamily: Ide.mono,
                            fontFamilyFallback: Ide.monoFallback,
                            fontSize: 11.5,
                            color: widget.isError ? ide.error : ide.text,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepDiffCard extends StatefulWidget {
  final List<AiFileDiff> files;
  const _StepDiffCard({required this.files});

  @override
  State<_StepDiffCard> createState() => _StepDiffCardState();
}

class _StepDiffCardState extends State<_StepDiffCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    var add = 0, del = 0;
    for (final f in widget.files) {
      add += f.additions;
      del += f.deletions;
    }
    return Container(
      decoration: BoxDecoration(
        color: ide.sideBar.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.m + 2),
        border: Border.all(color: ide.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.m + 2),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.difference_outlined, size: 14, color: ide.accent),
                  const SizedBox(width: 6),
                  Text('本步变更 ${widget.files.length} 个文件', style: TextStyle(fontSize: 12, color: ide.text)),
                  const SizedBox(width: 8),
                  Text('+$add', style: TextStyle(fontSize: 11.5, color: ide.ok, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 5),
                  Text('-$del', style: TextStyle(fontSize: 11.5, color: ide.error, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: ide.textFaint),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: ide.border),
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in widget.files) ...[
                    Row(
                      children: [
                        Expanded(child: Text(f.file, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.text))),
                        Text('+${f.additions} -${f.deletions}', style: TextStyle(fontSize: 11.5, color: ide.textDim)),
                      ],
                    ),
                    if (f.patch.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(Space.s),
                        decoration: BoxDecoration(
                          color: ide.editor,
                          borderRadius: BorderRadius.circular(Radii.s),
                        ),
                        child: SelectableText(
                          f.patch.trim(),
                          style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 11, color: ide.textDim, height: 1.35),
                        ),
                      ),
                    ],
                    const SizedBox(height: Space.s),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lightweight structured Markdown & fenced-code-block renderer with 1-click copy.
class _MarkdownText extends StatelessWidget {
  final String text;
  final double fontSize;
  const _MarkdownText({required this.text,this.fontSize=15});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final blocks = _splitFencedBlocks(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocks)
          if (b.isCode)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: ide.sideBar,
                borderRadius: BorderRadius.circular(Radii.m + 2),
                border: Border.all(color: ide.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: ide.border)),
                    ),
                    child: Row(
                      children: [
                        Text(b.lang.isEmpty ? 'code' : b.lang, style: TextStyle(fontSize: 11, color: ide.textFaint)),
                        const Spacer(),
                        InkWell(
                          onTap: () => copyText(b.content, what: '已复制代码'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.copy_rounded, size: 12, color: ide.textDim),
                                const SizedBox(width: 4),
                                Text('复制', style: TextStyle(fontSize: 11, color: ide.textDim)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(Space.m),
                    child: SelectableText(
                      b.content,
                      style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: fontSize-1, color: ide.text, height: 1.6),
                    ),
                  ),
                ],
              ),
            )
          else if (b.content.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: MarkdownBody(
                data: b.content.trim(),
                selectable: true,
                styleSheet: _chatMarkdownStyle(context, ide),
                // Like the file preview: a chat reply never makes a request by itself.
                imageBuilder: (uri, title, alt) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('[图片未加载${alt == null || alt.isEmpty ? '' : '：$alt'}]', style: TextStyle(color: ide.textDim, fontStyle: FontStyle.italic)),
                ),
                onTapLink: (text, href, title) {
                  if (href == null) return;
                  copyText(href, what: '链接已复制（不会自动打开）');
                },
              ),
            ),
      ],
    );
  }

  MarkdownStyleSheet _chatMarkdownStyle(BuildContext context, Ide ide) {
    final body=TextStyle(fontFamily:Ide.ui,fontFamilyFallback:Ide.uiFallback,color:ide.text,fontSize:fontSize,height:1.7);
    final mono = TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: fontSize-1, color: ide.text,height:1.5);
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: body,
      h1: body.copyWith(fontSize: fontSize * 1.35, fontWeight: FontWeight.w600, height: 1.5),
      h2: body.copyWith(fontSize: fontSize * 1.2, fontWeight: FontWeight.w600, height: 1.5),
      h3: body.copyWith(fontSize: fontSize * 1.1, fontWeight: FontWeight.w600, height: 1.5),
      h4: body.copyWith(fontWeight: FontWeight.w600, height: 1.5),
      strong: TextStyle(color: ide.text, fontWeight: FontWeight.w700),
      em: TextStyle(color: ide.text, fontStyle: FontStyle.italic),
      listBullet: body.copyWith(color:ide.textDim),
      code: mono.copyWith(backgroundColor: ide.hover),
      codeblockDecoration: BoxDecoration(color: ide.sideBar, borderRadius: BorderRadius.circular(Radii.m)),
      blockquoteDecoration: BoxDecoration(color: ide.hover.withValues(alpha: 0.4), border: Border(left: BorderSide(color: ide.accent, width: 3))),
      a: TextStyle(color: ide.accent),
      tableBorder: TableBorder.all(color: ide.border),
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body.copyWith(fontSize:fontSize-1),
      horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: ide.border))),
    );
  }

  List<({bool isCode, String lang, String content})> _splitFencedBlocks(String src) {
    final out = <({bool isCode, String lang, String content})>[];
    final re = RegExp(r'```([^\n`]*)\n([\s\S]*?)```');
    var cursor = 0;
    for (final m in re.allMatches(src)) {
      if (m.start > cursor) {
        out.add((isCode: false, lang: '', content: src.substring(cursor, m.start)));
      }
      out.add((isCode: true, lang: (m.group(1) ?? '').trim(), content: (m.group(2) ?? '').trimRight()));
      cursor = m.end;
    }
    if (cursor < src.length) {
      out.add((isCode: false, lang: '', content: src.substring(cursor)));
    }
    return out;
  }
}
