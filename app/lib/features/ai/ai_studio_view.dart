// Agent Studio editor tab (D-104): OpenCode-compatible AI coding & server agent UI.
// Supports Build/Plan modes, live streaming thinking + tool cards + todo tracker + diffs,
// inline permission approvals, 1-click shadow-git revert, context attachments, and compaction.
import 'dart:async';
import 'dart:convert';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'ai_models.dart';
import 'ai_settings_dialog.dart';

EditorTab aiStudioTab(Workspace ws, {String? sessionId, String title = 'AI 助手'}) {
  final tabId = sessionId == null ? 'ai:new' : 'ai:$sessionId';
  return EditorTab(
    id: tabId,
    title: title,
    icon: Icons.auto_awesome_rounded,
    tooltip: 'AI 智能体 · $title',
    builder: (_) => AiStudioView(key: ValueKey('${ws.serverId}/$tabId'), ws: ws, initialSessionId: sessionId),
  );
}

class AiStudioView extends StatefulWidget {
  final Workspace ws;
  final String? initialSessionId;
  final VoidCallback? onSessionsChanged;

  const AiStudioView({
    super.key,
    required this.ws,
    this.initialSessionId,
    this.onSessionsChanged,
  });

  @override
  State<AiStudioView> createState() => _AiStudioViewState();
}

class _AiStudioViewState extends State<AiStudioView> {
  String? _sessionId;
  AiSession? _session;
  bool _loading = false;
  bool _running = false;
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
  final _inputCtl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scrollCtl = ScrollController();

  OpStream? _stream;
  Link? _streamLink;
  bool _disposed = false;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.initialSessionId;
    if (ws.app.ready) {
      _agentMode = ws.app.profile.ai.defaultAgent;
      _permMode = ws.app.profile.ai.permissionMode;
    }
    ws.addListener(_onWorkspaceChanged);
    ws.app.addListener(_onAppChanged);
    _initConnection();
  }

  @override
  void dispose() {
    _disposed = true;
    ws.removeListener(_onWorkspaceChanged);
    ws.app.removeListener(_onAppChanged);
    _closeStream();
    _inputCtl.dispose();
    _inputFocus.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  void _onAppChanged() {
    if (mounted) setState(() {});
  }

  void _onWorkspaceChanged() {
    if (_disposed || !mounted) return;
    if (!identical(ws.link, _streamLink)) {
      _initConnection();
    } else {
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
    if (_sessionId != null) {
      await _loadSession(link, _sessionId!);
    }
    unawaited(_openEventStream(link));
  }

  void _closeStream() {
    _stream?.reset();
    _stream = null;
    _streamLink = null;
  }

  Future<void> _loadRoots(Link link) async {
    try {
      final r = await link.call('fs.roots') as Map;
      final list = [for (final x in r['roots'] as List) (x as Map).cast<String, dynamic>()];
      if (!mounted) return;
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await link.call('ai.get', {'id': id}) as Map;
      if (!mounted) return;
      final sess = AiSession.fromJson((res['session'] as Map).cast<String, dynamic>());
      final running = res['running'] == true;
      final pending = res['pending_permission'] is Map
          ? AiPermissionQuestion.fromJson((res['pending_permission'] as Map).cast<String, dynamic>())
          : null;
      setState(() {
        _session = sess;
        _running = running;
        _pendingPerm = pending;
        _root = sess.root;
        _workdir = sess.workdir;
        _agentMode = sess.agent == 'plan' ? 'plan' : 'build';
        if (sess.permissionMode.isNotEmpty) _permMode = sess.permissionMode;
        _loading = false;
      });
      _updateTabTitle(sess.title);
      _scrollToBottom();
    } on OpError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  void _updateTabTitle(String title) {
    final tabId = widget.initialSessionId == null ? 'ai:new' : 'ai:${widget.initialSessionId}';
    final t = ws.tab(tabId);
    if (t != null && title.isNotEmpty && t.title != title) {
      t.title = title;
      // Trigger tab bar repaint
      ws.filesRevision.value = ws.filesRevision.value;
    }
  }

  Future<void> _openEventStream(Link link) async {
    try {
      final st = await link.open('ai.stream', {
        if (_sessionId != null) 'session_id': _sessionId,
      });
      await st.response();
      if (_disposed || !identical(link, ws.link)) {
        st.reset();
        return;
      }
      _stream = st;
      while (!_disposed) {
        final f = await st.read();
        if (f == null) break;
        if (!f.isJson) continue;
        final ev = (f.json() as Map).cast<String, dynamic>();
        _handleStreamEvent(ev);
      }
    } on Object {
      // Reconnect handled by _onWorkspaceChanged
    }
  }

  void _handleStreamEvent(Map<String, dynamic> ev) {
    if (!mounted || _disposed) return;
    final type = ev['type'] as String? ?? '';
    if (type == 'ping') return;
    final sid = ev['session_id'] as String? ?? '';
    if (_sessionId == null || sid != _sessionId) return;

    setState(() {
      switch (type) {
        case 'session.status':
          final status = ev['status'] as String? ?? '';
          _running = status == 'running';
          if (!_running) {
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
            if (msg.usage != null) {
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
            final msg = AiMessage.fromJson((ev['message'] as Map).cast<String, dynamic>());
            _session ??= AiSession(id: sid, title: '新会话', root: _root, workdir: _workdir);
            _session!.messages.add(msg);
          } else if ((ev['error'] as String? ?? '').isNotEmpty) {
            ws.toast('${ev['error']}', error: true);
          }

        case 'session.reverted':
          if (ws.link != null && _sessionId != null) {
            unawaited(_loadSession(ws.link!, _sessionId!));
          }
      }
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      final pos = _scrollCtl.position;
      if (pos.maxScrollExtent - pos.pixels < 260 || !_running) {
        _scrollCtl.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      }
    });
  }

  AiProvider? get _activeProvider => ws.app.ready ? ws.app.profile.ai.activeProvider : null;

  Future<void> _send([String? quickPrompt]) async {
    final link = ws.link;
    if (link == null) {
      ws.toast('服务器未连接', error: true);
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
    if (quickPrompt == null) _inputCtl.clear();
    setState(() => _attachments.clear());

    try {
      final res = await link.call('ai.run', {
        if (_sessionId != null) 'session_id': _sessionId,
        'root': _root,
        'workdir': _workdir,
        'agent': _agentMode,
        'permission_mode': _permMode,
        'text': text,
        if (sentAttachments.isNotEmpty) 'attachments': [for (final a in sentAttachments) a.toJson()],
        'provider': prov.toWireJson(),
      }) as Map;
      final sum = AiSessionSummary.fromJson((res['session'] as Map).cast<String, dynamic>());
      final isNew = _sessionId == null;
      _sessionId = sum.id;
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
      await link.call('ai.compact', {
        'session_id': sid,
        'provider': prov.toWireJson(),
      });
      await _loadSession(link, sid);
      ws.toast('上下文已按 OpenCode 检查点模板压缩');
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _attachActiveFile() async {
    final link = ws.link;
    final activeFile = ws.active?.file;
    if (link == null || activeFile == null) {
      ws.toast('请先在编辑器中打开一个文件，或使用「附加路径…」');
      return;
    }
    try {
      final res = await link.call('fs.read', {'root': activeFile.root, 'path': activeFile.path}) as Map;
      final content = res['content'] as String? ?? '';
      if (!mounted) return;
      setState(() {
        _attachments.add(AiAttachment(
          kind: 'file',
          label: activeFile.name,
          path: activeFile.path,
          content: content.length > 32000 ? '${content.substring(0, 32000)}\n...[truncated]' : content,
        ));
      });
    } on OpError catch (e) {
      ws.toast('读取文件失败：${e.message}', error: true);
    }
  }

  Future<void> _attachFileByPath() async {
    final link = ws.link;
    if (link == null) return;
    final path = await askText(context, title: '附加服务器文件到上下文', initial: _workdir == '/' ? '/' : '$_workdir/', hint: '/path/to/file');
    if (path == null || path.isEmpty) return;
    try {
      final res = await link.call('fs.read', {'root': _root, 'path': path}) as Map;
      final content = res['content'] as String? ?? '';
      if (!mounted) return;
      final name = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
      setState(() {
        _attachments.add(AiAttachment(
          kind: 'file',
          label: name,
          path: path,
          content: content.length > 32000 ? '${content.substring(0, 32000)}\n...[truncated]' : content,
        ));
      });
    } on OpError catch (e) {
      ws.toast('读取失败：${e.message}', error: true);
    }
  }

  Future<void> _pickWorkdir() async {
    final next = await askText(
      context,
      title: '设置会话工作目录（相对于根目录 $_root）',
      initial: _workdir,
      hint: '例如 /projects/myapp 或 /',
    );
    if (next == null || next.isEmpty) return;
    setState(() {
      _workdir = next.startsWith('/') ? next : '/$next';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (ws.link == null) return NotConnected(ws: ws);
    if (_loading) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error != null) {
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

    return Column(
      children: [
        _buildTopBar(ide, prov),
        const Divider(height: 1),
        if (todos.isNotEmpty) _buildTodoBanner(ide, todos),
        Expanded(
          child: messages.isEmpty && !_running
              ? _buildEmptyWelcome(ide, prov)
              : ListView(
                  controller: _scrollCtl,
                  padding: const EdgeInsets.fromLTRB(Space.xl, Space.l, Space.xl, Space.xl),
                  children: [
                    for (final msg in messages)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 820),
                          child: _buildMessageItem(ide, msg),
                        ),
                      ),
                    if (_running || _liveReasoning.isNotEmpty || _liveText.isNotEmpty || _liveTools.isNotEmpty || _liveCompaction.isNotEmpty)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 820),
                          child: _buildLiveStep(ide),
                        ),
                      ),
                    if (_pendingPerm != null)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 820),
                          child: Padding(
                            padding: const EdgeInsets.only(top: Space.m),
                            child: _buildPermissionCard(ide, _pendingPerm!),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        _buildComposer(ide, prov),
      ],
    );
  }

  Widget _buildTopBar(Ide ide, AiProvider? prov) {
    final usage = _session?.totalUsage;
    final canPickDir = _session == null || _session!.messages.isEmpty;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: Space.m),
      color: ide.editor,
      child: Row(
        children: [
          // Root & Workdir badge
          InkWell(
            onTap: canPickDir ? _pickWorkdir : null,
            borderRadius: BorderRadius.circular(Radii.s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open_rounded, size: 14, color: ide.textDim),
                  const SizedBox(width: 5),
                  if (_roots.length > 1 && canPickDir)
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isDense: true,
                        value: _roots.any((r) => r['id'] == _root) ? _root : _roots.first['id'] as String,
                        items: [
                          for (final r in _roots)
                            DropdownMenuItem(
                              value: r['id'] as String,
                              child: Text('${r['label'] ?? r['id']}', style: TextStyle(fontSize: 12, color: ide.text)),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _root = v);
                        },
                      ),
                    )
                  else
                    Text(_root.isEmpty ? '默认根目录' : _root, style: TextStyle(fontSize: 12, color: ide.textDim)),
                  Text(' : $_workdir', style: TextStyle(fontSize: 12, color: ide.text, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (usage != null && usage.totalTokens > 0)
            Padding(
              padding: const EdgeInsets.only(right: Space.m),
              child: Tooltip(
                message: '输入 ${usage.inputTokens} (缓存命中 ${usage.cacheReadTokens}) · 输出 ${usage.outputTokens}',
                child: Text(
                  '${_fmtTokens(usage.totalTokens)} tok${usage.cacheReadTokens > 0 ? ' · 缓存 ${_fmtTokens(usage.cacheReadTokens)}' : ''}',
                  style: TextStyle(fontSize: 11.5, color: ide.textFaint),
                ),
              ),
            ),
          if (_sessionId != null && (_session?.messages.isNotEmpty ?? false))
            IconBtn(Icons.compress_rounded, '压缩上下文 (/compact)', _running ? null : _compactManual, size: 15),
          IconBtn(
            Icons.tune_rounded,
            '配置 OpenCode 模型与 API Key',
            () => showAiSettingsDialog(context, app: ws.app, ws: ws),
            size: 15,
          ),
        ],
      ),
    );
  }

  Widget _buildTodoBanner(Ide ide, List<AiTodoItem> todos) {
    final done = todos.where((t) => t.status == 'completed').length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.s + 2),
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
              Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 15, color: ide.accent),
                  const SizedBox(width: 6),
                  Text('任务进度 ($done/${todos.length})', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.text)),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: Space.m,
                runSpacing: 4,
                children: [
                  for (final t in todos)
                    Row(
                      mainAxisSize: MainAxisSize.min,
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
                        Text(
                          t.content,
                          style: TextStyle(
                            fontSize: 12,
                            color: t.status == 'completed' ? ide.textDim : ide.text,
                            decoration: t.status == 'completed' ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
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
              Text('Aurora AI 智能体 (OpenCode 引擎)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ide.text)),
              const SizedBox(height: Space.xs + 2),
              Text(
                '完整兼容 OpenCode 协议头、系统提示词与工具链。可直接在远程服务器上阅读和修改代码、搜索仓库、诊断日志并支持影子 Git 一键回退。',
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
                            color: msg.agent == 'plan' ? ide.warn.withValues(alpha: 0.14) : ide.accentSoft,
                            borderRadius: BorderRadius.circular(Radii.s),
                          ),
                          child: Text(
                            msg.agent == 'plan' ? 'PLAN' : 'BUILD',
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
                    SelectableText(text, style: TextStyle(fontSize: 13.5, color: ide.text, height: 1.5)),
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
                child: _MarkdownText(text: p.text.trim()),
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
              child: _MarkdownText(text: _liveText),
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

  Widget _buildComposer(Ide ide, AiProvider? prov) {
    final activeFile = ws.active?.file;
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.s + 2, Space.l, Space.m + 2),
      decoration: BoxDecoration(
        color: ide.editor,
        border: Border(top: BorderSide(color: ide.border)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Container(
            decoration: BoxDecoration(
              color: ide.sideBar,
              borderRadius: BorderRadius.circular(Radii.island),
              border: Border.all(color: ide.borderStrong.withValues(alpha: 0.7)),
            ),
            padding: const EdgeInsets.fromLTRB(Space.m + 2, Space.s + 2, Space.m, Space.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.s),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var i = 0; i < _attachments.length; i++)
                          InputChip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.description_outlined, size: 14),
                            label: Text(_attachments[i].label, style: const TextStyle(fontSize: 11.5)),
                            onDeleted: () => setState(() => _attachments.removeAt(i)),
                          ),
                      ],
                    ),
                  ),
                Focus(
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.enter &&
                        !HardwareKeyboard.instance.isShiftPressed) {
                      _send();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    key: const ValueKey('ai-prompt-input'),
                    controller: _inputCtl,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 6,
                    style: TextStyle(fontSize: 13.5, color: ide.text, height: 1.45),
                    decoration: InputDecoration(
                      hintText: _running
                          ? '正在运行… 输入补充指令并回车可实时引导 (Steer)'
                          : (_agentMode == 'plan' ? 'Plan 只读规划模式：探索代码库并制定方案（Shift+Enter 换行）' : '描述需要编写、修复或排查的任务…（Shift+Enter 换行）'),
                      filled: false,
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: Space.s + 2),
                Row(
                  children: [
                    // Build / Plan switcher
                    _ModePill(
                      label: _agentMode == 'plan' ? 'Plan 规划' : 'Build 构建',
                      icon: _agentMode == 'plan' ? Icons.architecture_rounded : Icons.build_circle_outlined,
                      color: _agentMode == 'plan' ? ide.warn : ide.accent,
                      onTap: () => setState(() => _agentMode = _agentMode == 'plan' ? 'build' : 'plan'),
                    ),
                    const SizedBox(width: Space.s),
                    // Ask / Auto permission switcher
                    _ModePill(
                      label: _permMode == 'auto' ? 'Auto 自动执行' : 'Ask 询问确认',
                      icon: _permMode == 'auto' ? Icons.bolt_rounded : Icons.verified_user_outlined,
                      color: _permMode == 'auto' ? ide.ok : ide.textDim,
                      onTap: () => setState(() => _permMode = _permMode == 'auto' ? 'ask' : 'auto'),
                    ),
                    const SizedBox(width: Space.s),
                    // Model selector button
                    InkWell(
                      onTap: () => showAiSettingsDialog(context, app: ws.app, ws: ws),
                      borderRadius: BorderRadius.circular(Radii.s + 2),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.memory_rounded, size: 13, color: ide.textDim),
                            const SizedBox(width: 4),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: Text(
                                prov == null || prov.model.isEmpty ? '选择模型…' : prov.model,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: prov == null || prov.model.isEmpty ? ide.warn : ide.textDim),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (activeFile != null)
                      IconBtn(Icons.attach_file_rounded, '附加当前打开文件 (${activeFile.name})', _attachActiveFile, size: 15),
                    IconBtn(Icons.post_add_rounded, '按路径附加服务器文件…', _attachFileByPath, size: 15),
                    if (_running) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: '停止当前运行',
                        child: InkWell(
                          key: const ValueKey('ai-stop-btn'),
                          onTap: _stop,
                          borderRadius: BorderRadius.circular(Radii.m),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                                Text('停止', style: TextStyle(fontSize: 12, color: ide.error, fontWeight: FontWeight.w600)),
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
                      onPressed: _send,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_running ? Icons.subdirectory_arrow_left_rounded : Icons.arrow_upward_rounded, size: 15),
                          const SizedBox(width: 4),
                          Text(_running ? '引导' : '发送', style: const TextStyle(fontSize: 12.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.m),
          border: Border.all(color: color.withValues(alpha: 0.3)),
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

  const _ToolCallCard({
    required this.name,
    required this.inputJson,
    required this.output,
    required this.isError,
    required this.running,
  });

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _open = false;

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
    return switch (widget.name) {
      'read' => (Icons.visibility_outlined, '读取 ${args['path'] ?? args['filePath'] ?? ''}'),
      'edit' => (Icons.edit_note_rounded, '编辑 ${args['path'] ?? args['filePath'] ?? ''}'),
      'write' => (Icons.save_outlined, '写入 ${args['path'] ?? args['filePath'] ?? ''}'),
      'glob' => (Icons.manage_search_rounded, '匹配文件 ${args['pattern'] ?? ''}'),
      'grep' => (Icons.search_rounded, '搜索内容 ${args['pattern'] ?? ''}'),
      'shell' => (Icons.terminal_rounded, '\$ ${args['command'] ?? ''}'),
      'todowrite' => (Icons.checklist_rounded, '更新任务清单'),
      'subagent' => (Icons.account_tree_outlined, '子智能体 (${args['agent'] ?? 'explore'}): ${args['description'] ?? ''}'),
      _ => (Icons.extension_outlined, widget.name),
    };
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
                  if (widget.inputJson.isNotEmpty) ...[
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
  const _MarkdownText({required this.text});

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
                      style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 12.5, color: ide.text, height: 1.45),
                    ),
                  ),
                ],
              ),
            )
          else if (b.content.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(
                b.content.trim(),
                style: TextStyle(fontSize: 13.5, color: ide.text, height: 1.55),
              ),
            ),
      ],
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
