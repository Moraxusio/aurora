// AI Agent feature (service "ai", D-104): sidebar session list + Agent Studio tabs.
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
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(
        title: 'AI 智能体',
        actions: [
          IconBtn(
            Icons.add_rounded,
            '新建 AI 会话',
            () => _openNewSession(ws),
          ),
          IconBtn(
            Icons.tune_rounded,
            '配置 OpenCode 模型与密钥',
            () => showAiSettingsDialog(context, app: ws.app, ws: ws),
          ),
        ],
        body: AiSessionSidebar(ws: ws),
      );

  @override
  List<Command> commands(Workspace ws) => [
        Command(
          id: 'ai.new',
          title: '新建 AI 智能体会话',
          group: 'AI 助手',
          icon: Icons.auto_awesome_rounded,
          run: () => _openNewSession(ws),
        ),
        Command(
          id: 'ai.settings',
          title: '配置 AI 模型与 OpenCode 协议…',
          group: 'AI 助手',
          icon: Icons.key_rounded,
          run: () {
            final ctx = Toast.key.currentContext;
            if (ctx != null) showAiSettingsDialog(ctx, app: ws.app, ws: ws);
          },
        ),
      ];

  static void _openNewSession(Workspace ws) {
    ws.dropTabs((t) => t.id == 'ai:new');
    ws.openTab(aiStudioTab(ws));
  }
}

class AiSessionSidebar extends StatefulWidget {
  final Workspace ws;
  const AiSessionSidebar({super.key, required this.ws});

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
    setState(() {
      _loading = _sessions.isEmpty;
      _error = null;
    });
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
        if (type == 'session.status' || type == 'session.title' || type == 'message.added' || type == 'permission.ask') {
          unawaited(_reload());
        }
      }
    } on Object {
      // reconnect handled via _onWs
    }
  }

  Future<void> _delete(AiSessionSummary s) async {
    final link = ws.link;
    if (link == null) return;
    final ok = await confirmDialog(
      context,
      title: '删除会话「${s.title}」？',
      body: '仅删除此 AI 对话历史，已修改的工作区文件不会被改动。',
      ok: '删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ws.guard(() => link.call('ai.delete', {'id': s.id}));
    ws.dropTabs((t) => t.id == 'ai:${s.id}');
    await _reload();
  }

  void _open(AiSessionSummary s) {
    ws.openTab(aiStudioTab(ws, sessionId: s.id, title: s.title));
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return LinkGate(
      ws: ws,
      builder: (context, _) {
        if (_loading) {
          return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
        }
        if (_error != null) {
          return EmptyHint(icon: Icons.error_outline_rounded, text: _error!, actionLabel: '重试', onAction: _reload);
        }
        if (_sessions.isEmpty) {
          return EmptyHint(
            icon: Icons.auto_awesome_outlined,
            text: '还没有 AI 会话。\n支持 OpenCode 协议的模型可在远程工作区读写编辑代码、运行命令并一键快照回退。',
            actionLabel: '新建 AI 会话',
            onAction: () {
              ws.dropTabs((t) => t.id == 'ai:new');
              ws.openTab(aiStudioTab(ws));
            },
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.s, Space.xs, Space.s, Space.xs),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    ws.dropTabs((t) => t.id == 'ai:new');
                    ws.openTab(aiStudioTab(ws));
                  },
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('新建 AI 会话'),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _sessions.length,
                itemBuilder: (context, i) {
                  final s = _sessions[i];
                  final selected = ws.focusedId == 'ai:${s.id}';
                  final statusColor = s.pendingPermission != null
                      ? ide.warn
                      : s.running
                          ? ide.accent
                          : ide.textFaint;
                  return TreeRow(
                    key: ValueKey('ai-session-${s.id}'),
                    selected: selected,
                    leading: s.running && s.pendingPermission == null
                        ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8))
                        : StatusDot(statusColor, size: 7),
                    label: s.title,
                    subtitle: '${s.agent == 'plan' ? 'Plan' : 'Build'} · ${s.workdir}',
                    trailing: IconBtn(Icons.delete_outline_rounded, '删除会话', () => _delete(s), size: 14),
                    onTap: () => _open(s),
                    menu: () => [
                      MenuItem('打开会话', () => _open(s), icon: Icons.open_in_new_rounded),
                      if (s.running)
                        MenuItem('停止运行', () => ws.guard(() => ws.link!.call('ai.stop', {'id': s.id})), icon: Icons.stop_rounded),
                      const MenuItem.separator(),
                      MenuItem('删除会话…', () => _delete(s), icon: Icons.delete_outline_rounded, danger: true),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
