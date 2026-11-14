// AI Agent feature (service "ai", D-104): the history side bar and the studio tabs.
//
// One history for everything: the agent keeps every session in one folder
// (<state>/ai/sessions), and this list is that folder. Pinned sessions lead,
// the rest are grouped by day, a search box looks through titles and the whole
// conversation text, and each row can be renamed, pinned, exported or deleted.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/feature.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'ai_models.dart';
import 'ai_settings_dialog.dart';
import 'ai_studio_view.dart';

class AiFeature extends Feature {
  const AiFeature();

  @override
  String get id => 'ai';
  @override
  String get title => 'AI 助手';
  @override
  IconData get icon => Icons.auto_awesome_outlined;
  @override
  String get service => 'ai';
  @override
  List<String> get ops => const ['ai.sessions', 'ai.get', 'ai.run', 'ai.stream', 'ai.stop', 'ai.approve'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => null;

  @override
  void open(Workspace ws) {
    if (ws.assistantTabs.isEmpty) { openNewAiSession(ws); } else { ws.showAssistantPanel(); }
  }

  @override
  List<Command> commands(Workspace ws) => [
        Command(id: 'ai.new', title: '新建 AI 智能体会话', group: 'AI 助手', icon: Icons.auto_awesome_rounded, run: () => openNewAiSession(ws)),
        Command(
          id: 'ai.settings',
          title: '配置 AI 模型与密钥…',
          group: 'AI 助手',
          icon: Icons.key_rounded,
          run: () {
            final ctx = Toast.key.currentContext;
            if (ctx != null) showAiSettingsDialog(ctx, app: ws.app, ws: ws);
          },
        ),
      ];
}

void openNewAiSession(Workspace ws) {
  ws.openTab(aiStudioTab(ws));
}

class AiSessionSidebar extends StatefulWidget {
  final Workspace ws;
  final VoidCallback? onOpened;
  const AiSessionSidebar({super.key, required this.ws, this.onOpened});

  @override
  State<AiSessionSidebar> createState() => _AiSessionSidebarState();
}

class _AiSessionSidebarState extends State<AiSessionSidebar> {
  List<AiSessionSummary> _sessions = [];
  bool _loading = true;
  String? _error;
  OpStream? _stream;
  Link? _streamLink;
  bool _disposed = false;
  Timer? _reloadDebounce;

  final _searchCtl = TextEditingController();
  Timer? _searchDebounce;
  List<AiSearchHit>? _hits; // null = not searching
  bool _searching = false;
  int _searchSeq = 0;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    ws.addListener(_onWs);
    _syncLink();
  }

  @override
  void dispose() {
    _disposed = true;
    _reloadDebounce?.cancel();
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    ws.removeListener(_onWs);
    _stream?.reset();
    super.dispose();
  }

  void _onWs() {
    if (_disposed || !mounted) return;
    if (!identical(ws.link, _streamLink)) {
      _syncLink();
    } else {
      setState(() {});
    }
  }

  Future<void> _syncLink() async {
    _stream?.reset();
    _stream = null;
    final link = ws.link;
    _streamLink = link;
    if (link == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    await _reload();
    unawaited(_listenEvents(link));
  }

  Future<void> _reload() async {
    final link = ws.link;
    if (link == null) return;
    try {
      final res = await link.call('ai.sessions') as Map;
      if (!mounted) return;
      final list = [
        for (final x in (res['sessions'] as List? ?? const []))
          if (x is Map) AiSessionSummary.fromJson(x.cast<String, dynamic>()),
      ];
      setState(() {
        _sessions = list;
        _loading = false;
        _error = null;
      });
    } on OpError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  // A streaming answer fires many events; reloading the list at most every
  // 400 ms keeps the side bar calm.
  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!_disposed) unawaited(_reload());
    });
  }

  Future<void> _listenEvents(Link link) async {
    try {
      final st = await link.open('ai.stream');
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
        final type = ev['type'] as String? ?? '';
        if (type == 'session.status' || type == 'session.title' || type == 'message.added' || type == 'permission.ask' || type == 'session.reverted') {
          _scheduleReload();
        }
      }
    } on Object {
      // reconnect is handled by _onWs
    }
  }

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    if (q.trim().isEmpty) {
      _searchSeq++;
      setState(() {
        _hits = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 300), () => _runSearch(q.trim()));
  }

  Future<void> _runSearch(String q) async {
    final link = ws.link;
    if (link == null) return;
    final seq = ++_searchSeq;
    try {
      final res = await link.call('ai.search', {'query': q, 'limit': 50}) as Map;
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _hits = [
          for (final x in (res['hits'] as List? ?? const []))
            if (x is Map) AiSearchHit.fromJson(x.cast<String, dynamic>()),
        ];
        _searching = false;
      });
    } on OpError catch (e) {
      if (mounted && seq == _searchSeq) {
        setState(() => _searching = false);
        ws.toast(e.message, error: true);
      }
    }
  }

  Future<void> _delete(AiSessionSummary s) async {
    final link = ws.link;
    if (link == null) return;
    final ok = await confirmDialog(
      context,
      title: '删除会话「${s.title}」？',
      body: '只删除这段 AI 对话记录，工作区里已经改过的文件不会变。',
      ok: '删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    final deleted = await ws.guard(() async {
      await link.call('ai.delete', {'id': s.id});
      return true;
    });
    if (deleted != true) return;
    ws.dropTabs((t) => t.isAssistant && (t.taskKey == s.id || t.id == 'ai:${s.id}'));
    if (mounted) await _reload();
  }

  Future<void> _rename(AiSessionSummary s) async {
    final link = ws.link;
    if (link == null) return;
    final t = await askText(context, title: '重命名会话', initial: s.title, hint: '会话标题');
    if (t == null || t.isEmpty || t == s.title || !mounted) return;
    final renamed = await ws.guard(() async {
      await link.call('ai.update', {'id': s.id, 'title': t});
      return true;
    });
    if (renamed != true) return;
    for (final tab in ws.assistantTabs) {
      if (tab.taskKey == s.id || tab.id == 'ai:${s.id}') ws.updateTabTitle(tab.id, t);
    }
    if (mounted) await _reload();
  }

  Future<void> _togglePin(AiSessionSummary s) async {
    final link = ws.link;
    if (link == null) return;
    await ws.guard(() => link.call('ai.update', {'id': s.id, 'pinned': !s.pinned}));
    await _reload();
  }

  Future<void> _export(AiSessionSummary s) async {
    final link = ws.link;
    if (link == null) return;
    final res = await ws.guard(() => link.call('ai.export', {'id': s.id}));
    if (res is Map) copyText(res['markdown'] as String? ?? '', what: '已把会话复制为 Markdown');
  }

  void _open(String id, String title) { ws.openTab(aiStudioTab(ws, sessionId: id, title: title)); widget.onOpened?.call(); }
  void _new() { openNewAiSession(ws); widget.onOpened?.call(); }

  List<MenuItem> _menu(AiSessionSummary s) => [
        MenuItem('打开', () => _open(s.id, s.title), icon: Icons.open_in_new_rounded),
        MenuItem(s.pinned ? '取消置顶' : '置顶', () => _togglePin(s), icon: s.pinned ? Icons.push_pin : Icons.push_pin_outlined),
        MenuItem('重命名…', () => _rename(s), icon: Icons.drive_file_rename_outline),
        MenuItem('复制为 Markdown', () => _export(s), icon: Icons.copy_all_rounded),
        if (s.running) MenuItem('停止运行', () => ws.guard(() => ws.link!.call('ai.stop', {'id': s.id})), icon: Icons.stop_rounded),
        const MenuItem.separator(),
        MenuItem('删除…', () => _delete(s), icon: Icons.delete_outline_rounded, danger: true),
      ];

  Widget _searchBox(Ide ide) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.s, Space.xs, Space.s, Space.xs),
      child: SizedBox(
        height: 32,
        child: TextField(
          key: const ValueKey('ai-history-search'),
          controller: _searchCtl,
          onChanged: _onSearchChanged,
          style: TextStyle(fontSize: 12.5, color: ide.text),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索历史对话…',
            prefixIcon: Icon(Icons.search_rounded, size: 16, color: ide.textFaint),
            prefixIconConstraints: const BoxConstraints(minWidth: 32),
            suffixIcon: _searchCtl.text.isEmpty
                ? null
                : (_searching
                    ? const Padding(padding: EdgeInsets.all(9), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6)))
                    : IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.close_rounded, size: 14, color: ide.textFaint),
                        onPressed: () {
                          _searchCtl.clear();
                          _onSearchChanged('');
                        },
                      )),
          ),
        ),
      ),
    );
  }

  Widget _groupHeader(Ide ide, String text, {IconData? icon}) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, 2),
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 11, color: ide.textFaint), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ide.textFaint, letterSpacing: 0.3)),
        ]),
      );

  Widget _row(Ide ide, AiSessionSummary s) {
    final active = ws.tab(ws.assistantPanel.active ?? '');
    final selected = active?.id == 'ai:${s.id}' || active?.taskKey == s.id;
    final busy = s.pendingPermission != null ? ide.warn : (s.running ? ide.accent : null);
    return ContextArea(
      items: () => _menu(s),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 1),
        child: InkWell(
          key: ValueKey('ai-session-${s.id}'),
          onTap: () => _open(s.id, s.title),
          borderRadius: BorderRadius.circular(Radii.m),
          hoverColor: selected ? Colors.transparent : ide.hover,
          child: Container(
            padding: const EdgeInsets.fromLTRB(Space.m, 7, Space.s, 7),
            decoration: selected ? BoxDecoration(color: ide.selection, borderRadius: BorderRadius.circular(Radii.m)) : null,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 16,
                height: 18,
                child: Center(
                  child: s.running && s.pendingPermission == null
                      ? const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.6))
                      : (busy != null ? StatusDot(busy, size: 7) : (s.pinned ? Icon(Icons.push_pin, size: 12, color: ide.accent) : Icon(Icons.chat_bubble_outline_rounded, size: 12, color: ide.textFaint))),
                ),
              ),
              const SizedBox(width: Space.s),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ide.text))),
                    const SizedBox(width: 6),
                    Text(relativeTime(s.updatedAt ~/ 1000), style: TextStyle(fontSize: 10.5, color: ide.textFaint)),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    s.pendingPermission != null ? '等待你批准：${s.pendingPermission!.tool}' : (s.preview.isEmpty ? s.workdir : s.preview),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: s.pendingPermission != null ? ide.warn : ide.textDim, height: 1.35),
                  ),
                  const SizedBox(height: 3),
                  Row(children: [
                    _Tag(s.agent == 'plan' ? 'Plan' : 'Build', s.agent == 'plan' ? ide.warn : ide.accent),
                    const SizedBox(width: 5),
                    Flexible(child: Text(s.workdir, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: ide.textFaint))),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _hitRow(Ide ide, AiSearchHit h) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 1),
        child: InkWell(
          key: ValueKey('ai-hit-${h.sessionId}'),
          onTap: () => _open(h.sessionId, h.title),
          borderRadius: BorderRadius.circular(Radii.m),
          hoverColor: ide.hover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: 7),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ide.text)),
              if (h.snippet.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(h.snippet, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ide.textDim, height: 1.35)),
              ],
            ]),
          ),
        ),
      );

  Widget _list(Ide ide) {
    final children = <Widget>[];
    final pinned = _sessions.where((s) => s.pinned).toList();
    if (pinned.isNotEmpty) {
      children.add(_groupHeader(ide, '置顶', icon: Icons.push_pin));
      children.addAll(pinned.map((s) => _row(ide, s)));
    }
    String? last;
    for (final s in _sessions.where((s) => !s.pinned)) {
      final g = aiDayGroup(s.updatedAt);
      if (g != last) {
        children.add(_groupHeader(ide, g));
        last = g;
      }
      children.add(_row(ide, s));
    }
    children.add(const SizedBox(height: Space.xl));
    return ListView(children: children);
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return LinkGate(
      ws: ws,
      builder: (context, _) {
        if (_loading) return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
        if (_error != null) return EmptyHint(icon: Icons.error_outline_rounded, text: _error!, actionLabel: '重试', onAction: _reload);
        final newButton = Padding(
          padding: const EdgeInsets.fromLTRB(Space.s, Space.xs, Space.s, 0),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _new,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('新建 AI 会话'),
            ),
          ),
        );
        if (_sessions.isEmpty) {
          return EmptyHint(
            icon: Icons.auto_awesome_outlined,
            text: '还没有 AI 会话。\n它能在这台服务器上读写代码、运行命令、联网查资料，每一步都能一键回退。',
            actionLabel: '新建 AI 会话',
            onAction: _new,
          );
        }
        final searching = _hits != null;
        return Column(children: [
          newButton,
          _searchBox(ide),
          Expanded(
            child: searching
                ? (_hits!.isEmpty
                    ? EmptyHint(icon: Icons.search_off_rounded, text: _searching ? '搜索中…' : '没有找到包含这些词的对话')
                    : ListView(children: [_groupHeader(ide, '找到 ${_hits!.length} 个对话'), for (final h in _hits!) _hitRow(ide, h)]))
                : _list(ide),
          ),
        ]);
      },
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(Radii.s)),
        child: Text(text, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: color)),
      );
}
