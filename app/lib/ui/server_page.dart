// One server: connection state, and tabs for its terminal, files, monitor
// and service switches. Uninstall and re-pairing live in the overview tab.
import 'dart:async';

import 'package:aurora_install/aurora_install.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'add_server.dart';
import 'files_page.dart';
import 'monitor_page.dart';
import 'terminal_page.dart';

class ServerPage extends StatefulWidget {
  final AppState app;
  final String id;
  const ServerPage({super.key, required this.app, required this.id});
  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(ServerPage old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _ensure();
  }

  void _ensure() {
    final st = widget.app.status(widget.id).state;
    if (st == ConnState.idle) unawaited(widget.app.connect(widget.id));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.app.profile.server(widget.id);
    if (s == null) return const Center(child: Text('服务器已删除'));
    final st = widget.app.status(widget.id);
    final link = widget.app.link(widget.id);
    return DefaultTabController(
      length: 5,
      child: Column(children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Column(children: [
            ListTile(
              title: Text(s.name, style: Theme.of(context).textTheme.titleLarge),
              subtitle: Text(_statusText(st, s)),
              leading: _statusIcon(st),
              trailing: _statusAction(st),
            ),
            const TabBar(isScrollable: true, tabs: [
              Tab(text: '终端'),
              Tab(text: '文件'),
              Tab(text: '监控'),
              Tab(text: '服务'),
              Tab(text: '概览'),
            ]),
          ]),
        ),
        Expanded(
          child: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [
            // The terminal keeps its own state across link drops (it attaches
            // again); the others restart with each new link.
            _KeepAlive(child: TerminalTab(key: ValueKey('t${widget.id}'), app: widget.app, id: widget.id)),
            _KeepAlive(child: link == null ? _notConnected(st) : FilesTab(key: ObjectKey(link), link: link)),
            _KeepAlive(child: link == null ? _notConnected(st) : MonitorTab(key: ObjectKey(link), link: link)),
            link == null ? _notConnected(st) : ServicesTab(key: ObjectKey(link), link: link),
            OverviewTab(key: ValueKey('o${widget.id}'), app: widget.app, entry: s, link: link),
          ]),
        ),
      ]),
    );
  }

  String _statusText(ConnStatus st, ServerEntry s) => switch (st.state) {
        ConnState.connected => '已连接 ${st.addr ?? ''} · agent ${st.link?.server.version ?? ''}',
        ConnState.connecting => '正在连接（第 ${st.attempt} 次）…',
        ConnState.waiting => '连接失败，${st.retryIn?.inSeconds ?? 0} 秒后重试：${st.failure?.message ?? ''}',
        ConnState.failed => _failureText(st.failure!),
        ConnState.idle => s.direct?.ready == true ? '未连接' : '还没有直连参数，请重新安装或配对',
      };

  String _failureText(ConnFailure f) => switch (f.kind) {
        DialFailure.auth => '令牌被拒绝：请在“概览”里重新配对',
        DialFailure.pinMismatch => '服务器身份已变化（证书指纹不符），已停止连接。确认服务器重装过之后，在“概览”里重新配对',
        DialFailure.version => '协议版本不兼容：${f.message}',
        _ => '连接失败：${f.message}',
      };

  Widget _statusIcon(ConnStatus st) => switch (st.state) {
        ConnState.connected => const Icon(Icons.circle, color: Colors.green, size: 14),
        ConnState.failed => Icon(Icons.circle, color: st.failure!.needsUser ? Colors.red : Colors.orange, size: 14),
        ConnState.idle => const Icon(Icons.circle_outlined, size: 14),
        _ => const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      };

  Widget? _statusAction(ConnStatus st) => switch (st.state) {
        ConnState.waiting => TextButton(onPressed: () => widget.app.retryNow(widget.id), child: const Text('立即重试')),
        ConnState.failed || ConnState.idle => TextButton(onPressed: () => widget.app.connect(widget.id), child: const Text('连接')),
        _ => null,
      };

  Widget _notConnected(ConnStatus st) => Center(
        child: Text(st.state == ConnState.failed ? _failureText(st.failure!) : '未连接',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
      );
}

/// Keeps a tab's state while another tab is shown (TabBarView would dispose
/// it): the terminal's scrollback, the folder being browsed, the CPU history.
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Service switches (D-9, D-26, D-42 to D-44).
class ServicesTab extends StatefulWidget {
  final Link link;
  const ServicesTab({super.key, required this.link});
  @override
  State<ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<ServicesTab> {
  List<Map<String, dynamic>> _services = [];
  String? _error;
  final Set<String> _busy = {};

  static const _names = {
    'files': '文件',
    'git': 'Git',
    'monitor': '监控',
    'systemd': 'systemd 服务管理',
    'terminal': '终端',
  };

  static const _about = {
    'files': '浏览、上传、下载、改名、删除文件',
    'git': '查看仓库状态、提交历史和差异',
    'monitor': 'CPU、内存、磁盘和进程',
    'systemd': '查看服务状态，按白名单启动、停止、重启服务',
    'terminal': 'tmux 终端会话，断线和 agent 重启后会话不丢',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.link.call('agent.services') as Map;
      setState(() {
        _services = [for (final s in r['services'] as List) (s as Map).cast<String, dynamic>()];
        _error = null;
      });
    } on OpError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _set(String id, bool on) async {
    if (!on && id == 'terminal') {
      final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                title: const Text('关闭终端服务？'),
                content: const Text('已打开的终端窗口会被断开，tmux 会话继续在服务器上运行。之后不能新建或连接会话，但仍可以结束会话。'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('关闭')),
                ],
              ));
      if (ok != true) return;
    }
    setState(() => _busy.add(id));
    try {
      final r = await widget.link.call('agent.service', {'id': id, 'enabled': on}) as Map;
      setState(() => _services = [for (final s in r['services'] as List) (s as Map).cast<String, dynamic>()]);
    } on OpError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('服务开关是功能选择，不是安全边界：持有直连令牌就能取得 root 权限。每次改动都写入服务器的审计日志。',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      for (final s in _services)
        SwitchListTile(
          title: Text(_names[s['id']] ?? s['id'] as String),
          subtitle: Text(s['available'] == false ? '不可用：${s['reason'] ?? ''}' : (_about[s['id']] ?? '')),
          value: s['enabled'] == true,
          onChanged: _busy.contains(s['id']) ? null : (v) => _set(s['id'] as String, v),
        ),
    ]);
  }
}

/// Details, re-pairing, uninstall and removal.
class OverviewTab extends StatefulWidget {
  final AppState app;
  final ServerEntry entry;
  final Link? link;
  const OverviewTab({super.key, required this.app, required this.entry, this.link});
  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  bool _busy = false;
  String? _note;

  Future<SshRemote?> _ssh() async {
    final s = widget.entry.ssh;
    if (s == null) return null;
    var password = s.password, key = s.privateKey;
    if ((password == null || password.isEmpty) && (key == null || key.isEmpty)) {
      password = await _ask('SSH 密码（${s.user}@${s.host}）');
      if (password == null) return null;
    }
    final known = widget.app.profile.knownHost(s.host, s.port);
    return SshRemote.connect(s.host, s.port,
        SshCredentials(user: s.user, password: password, privateKey: key, passphrase: s.passphrase),
        checkHostKey: (k) => known != null && known.fingerprint == k.fingerprint);
  }

  Future<String?> _ask(String label) {
    final c = TextEditingController();
    return showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(label),
              content: TextField(controller: c, obscureText: true, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('确定')),
              ],
            ));
  }

  Future<void> _uninstall({required bool purge}) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(purge ? '彻底清除？' : '卸载 agent？'),
              content: Text(purge
                  ? '停止 agent，删除程序、配置、证书、令牌、审计日志和状态目录。之后重新安装会是一台新的服务器，要重新配对。'
                  : '停止 agent，删除程序和 systemd 单元。配置和身份保留在 /etc/aurora3 和 /var/lib/aurora3，以后重新安装时令牌和指纹不变。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(purge ? '彻底清除' : '卸载')),
              ],
            ));
    if (ok != true) return;
    setState(() {
      _busy = true;
      _note = '正在通过 SSH 登录…';
    });
    SshRemote? r;
    try {
      r = await _ssh();
      if (r == null) {
        setState(() => _note = '没有登录信息，或主机密钥与记录不符，已取消');
        return;
      }
      final inst = Installer(r, const [], sudoPassword: widget.entry.ssh?.sudoPassword);
      var o = await inst.uninstall(purge: purge);
      if (o.result == 'sessions' && mounted) {
        final force = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
                  title: const Text('还有终端会话在运行'),
                  content: Text('会话：${o.sessions.join('、')}\n\n继续卸载会结束这些会话和里面运行的程序。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('结束会话并卸载')),
                  ],
                ));
        if (force != true) {
          setState(() => _note = '已取消，没有做任何改动');
          return;
        }
        o = await inst.uninstall(purge: purge, force: true);
      }
      if (o.ok) {
        await widget.app.disconnect(widget.entry.id);
        if (purge) {
          await widget.app.update((p) => p.server(widget.entry.id)?.direct = null);
        }
        setState(() => _note = o.kept.isEmpty ? '已卸载并清除' : '已卸载，保留了 ${o.kept.join('、')}');
      } else {
        setState(() => _note = o.message);
      }
    } on SshException catch (e) {
      setState(() => _note = e.message);
    } finally {
      await r?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('从列表中删除？'),
              content: const Text('只删除本机保存的登录信息和直连参数，服务器上的 agent 不受影响。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
              ],
            ));
    if (ok == true) await widget.app.removeServer(widget.entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry, s = e.ssh, d = e.direct;
    final kh = s == null ? null : widget.app.profile.knownHost(s.host, s.port);
    final info = widget.link?.server;
    return ListView(padding: const EdgeInsets.all(16), children: [
      _kv('SSH', s == null ? '—' : '${s.user}@${s.host}:${s.port}'),
      _kv('主机密钥', kh == null ? '—' : '${kh.type} ${kh.fingerprint}'),
      _kv('直连地址', d == null ? '—' : d.addrs.join('  ')),
      _kv('证书指纹', d?.pin ?? '—'),
      if (info != null) ...[
        _kv('系统', info.os),
        _kv('主机名', info.host),
        _kv('agent 版本', info.version),
      ],
      _kv('保存的密码', s == null ? '—' : [if ((s.password ?? '').isNotEmpty) 'SSH 密码', if ((s.privateKey ?? '').isNotEmpty) '私钥', if ((s.sudoPassword ?? '').isNotEmpty) 'sudo 密码'].join('、').ifEmpty('无')),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => AddServerPage(app: widget.app, existing: e)));
                  if (mounted) unawaited(widget.app.connect(e.id));
                },
          icon: const Icon(Icons.sync),
          label: const Text('重新安装或配对'),
        ),
        TextButton.icon(onPressed: _busy ? null : _remove, icon: const Icon(Icons.remove_circle_outline), label: const Text('从列表中删除')),
      ]),
      const SizedBox(height: 32),
      // Removing the agent changes the server; kept apart and marked.
      Text('危险操作', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.error)),
      const SizedBox(height: 8),
      Wrap(spacing: 12, runSpacing: 12, children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: _busy ? null : () => _uninstall(purge: false),
          icon: const Icon(Icons.delete_outline),
          label: const Text('卸载 agent'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError),
          onPressed: _busy ? null : () => _uninstall(purge: true),
          icon: const Icon(Icons.delete_forever),
          label: const Text('彻底清除（删除证书和令牌）'),
        ),
      ]),
      if (_note != null) ...[const SizedBox(height: 16), SelectableText(_note!)],
    ]);
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 100, child: Text(k, style: Theme.of(context).textTheme.labelLarge)),
          Expanded(child: SelectableText(v)),
        ]),
      );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
