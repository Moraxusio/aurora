// A server's overview tab: how it is reached, the agent's services and their
// switches (D-9, D-26), re-pairing, uninstall and removal. The services list
// is the agent's own report, so a service added to the agent shows up here
// without a client change.
import 'dart:async';

import 'package:aurora_install/aurora_install.dart';
import 'package:flutter/material.dart';

import '../theme/ide_theme.dart';
import '../ui/add_server.dart';
import '../ui/upgrade_agent.dart';
import 'editor_tab.dart';
import 'registry.dart';
import 'widgets.dart';
import 'workspace.dart';

EditorTab overviewTab(Workspace ws, Features features) => EditorTab(
      id: 'overview',
      title: '概览',
      icon: Icons.tune,
      builder: (_) => OverviewView(ws: ws, features: features),
    );

class OverviewView extends StatefulWidget {
  final Workspace ws;
  final Features features;
  const OverviewView({super.key, required this.ws, required this.features});
  @override
  State<OverviewView> createState() => _OverviewViewState();
}

class _OverviewViewState extends State<OverviewView> {
  bool _busy = false;
  String? _note;
  final Set<String> _switching = {};

  Workspace get ws => widget.ws;

  static const _names = {
    'files': '文件',
    'git': 'Git',
    'monitor': '监控与日志',
    'systemd': 'systemd 服务管理',
    'terminal': '终端',
    'net': '端口转发',
    'proxy': '代理出口',
  };
  static const _about = {
    'files': '浏览、编辑、上传、下载、改名、删除文件',
    'git': '查看仓库状态、提交历史和差异，暂存、提交、拉取、推送',
    'monitor': 'CPU、内存、磁盘、进程，以及系统和服务的日志',
    'systemd': '查看服务状态，按授权名单启动、停止、重启服务',
    'terminal': 'tmux 终端会话，断线和 agent 重启后会话不丢',
    'net': '列出服务器上监听的端口，转发到本机',
    'proxy': '终端和 Git 的代理出口；关闭会中断代理连接，会话本身保留',
  };

  Future<void> _switch(String id, bool on) async {
    final link = ws.link;
    if (link == null || !mounted) return;
    if (!on && id == 'terminal') {
      final ok = await confirmDialog(context,
          title: '关闭终端服务？', body: '已打开的终端窗口会被断开，tmux 会话继续在服务器上运行。之后不能新建或连接会话，但仍可以结束会话。', ok: '关闭');
      if (!ok || !mounted) return;
    }
    if (!on && id == 'net') {
      final ok = await confirmDialog(context, title: '关闭端口转发服务？', body: '正在转发的连接会中断，之后新的连接也会失败，直到再打开。', ok: '关闭');
      if (!ok) return;
    }
    if (!on && id == 'proxy') {
      String affected;
      try {
        final r = await link.call('session.proxy') as Map;
        affected = '将影响 ${r['count']} 个代理会话';
        final names = (r['sessions'] as List).cast<String>();
        if (names.isNotEmpty) affected += '：${names.join('、')}';
        if ((r['unknown'] as num) > 0) affected += '。另有 ${r['unknown']} 个旧会话的代理状态未知';
      } on Object {
        affected = '当前 agent 无法准确统计代理会话数量';
      }
      if (!mounted) return;
      final ok = await confirmDialog(context, title: '关闭代理服务？', body: '$affected。\n现有代理连接会中断，但终端会话和进程仍保留；Git 将改为直连。', ok: '关闭');
      if (!ok || !mounted) return;
    }
    setState(() => _switching.add(id));
    await ws.guard(() => link.call('agent.service', {'id': id, 'enabled': on}));
    await ws.refreshServices();
    if (mounted) setState(() => _switching.remove(id));
  }

  Future<SshRemote?> _ssh() async {
    final s = ws.entry?.ssh;
    if (s == null) return null;
    var password = s.password, key = s.privateKey;
    if ((password == null || password.isEmpty) && (key == null || key.isEmpty)) {
      password = await askText(context, title: 'SSH 密码（${s.user}@${s.host}）', obscure: true);
      if (password == null) return null;
    }
    final known = ws.app.profile.knownHost(s.host, s.port);
    return SshRemote.connect(s.host, s.port, SshCredentials(user: s.user, password: password, privateKey: key, passphrase: s.passphrase),
        checkHostKey: (k) => known != null && known.fingerprint == k.fingerprint);
  }

  Future<void> _uninstall({required bool purge}) async {
    final ok = await confirmDialog(context,
        title: purge ? '彻底清除？' : '卸载 agent？',
        body: purge
            ? '停止 agent，删除程序、配置、证书、令牌、审计日志和状态目录。之后重新安装会是一台新的服务器，要重新配对。'
            : '停止 agent，删除程序和 systemd 单元。配置和身份保留在 /etc/aurora3 和 /var/lib/aurora3，以后重新安装时令牌和指纹不变。',
        ok: purge ? '彻底清除' : '卸载',
        danger: true);
    if (!ok) return;
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
      var sudo = ws.entry?.ssh?.sudoPassword;
      final inst = Installer(r, const [], sudoPassword: sudo);
      var o = await inst.uninstall(purge: purge);
      if (o.result == 'sessions' && mounted) {
        final force = await confirmDialog(context, title: '还有终端会话在运行', body: '会话：${o.sessions.join('、')}\n\n继续卸载会结束这些会话和里面运行的程序。', ok: '结束会话并卸载', danger: true);
        if (!force) {
          setState(() => _note = '已取消，没有做任何改动');
          return;
        }
        o = await inst.uninstall(purge: purge, force: true);
      }
      if (o.ok) {
        final id = ws.serverId;
        await ws.app.disconnect(id);
        if (purge) await ws.app.update((p) => p.server(id)?.direct = null);
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
    final e = ws.entry;
    if (e == null) return;
    final ok = await confirmDialog(context, title: '从列表中删除？', body: '只删除本机保存的登录信息和直连参数，服务器上的 agent 不受影响。', ok: '删除', danger: true);
    if (ok) await ws.app.removeServer(e.id);
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final e = ws.entry;
    if (e == null) return const SizedBox.shrink();
    final s = e.ssh, d = e.direct;
    final kh = s == null ? null : ws.app.profile.knownHost(s.host, s.port);
    final info = ws.link?.server;
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 96, child: Text(k, style: TextStyle(color: ide.textDim))),
            Expanded(child: SelectableText(v)),
          ]),
        );
    Widget section(String t) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 8), child: Text(t, style: Theme.of(context).textTheme.titleSmall));
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(padding: const EdgeInsets.all(24), children: [
          Text(e.name, style: Theme.of(context).textTheme.titleLarge),
          section('连接'),
          kv('SSH', s == null ? '—' : '${s.user}@${s.host}:${s.port}'),
          kv('主机密钥', kh == null ? '—' : '${kh.type} ${kh.fingerprint}'),
          kv('直连地址', d == null ? '—' : d.addrs.join('  ')),
          kv('证书指纹', d?.pin ?? '—'),
          if (info != null) ...[kv('系统', info.os), kv('主机名', info.host), kv('agent 版本', info.version)],
          if(info!=null) Align(alignment:Alignment.centerLeft,child:TextButton.icon(onPressed:()=>showAgentUpgrade(context,ws.app,ws.serverId),icon:const Icon(Icons.system_update_alt),label:const Text('检查并升级 agent'))),
          kv('保存的密码', s == null ? '—' : ([if ((s.password ?? '').isNotEmpty) 'SSH 密码', if ((s.privateKey ?? '').isNotEmpty) '私钥', if ((s.sudoPassword ?? '').isNotEmpty) 'sudo 密码'].join('、')).ifEmpty('无')),
          section('服务'),
          Text('服务开关是功能选择，不是安全边界：持有直连令牌就能取得 root 权限。每次改动都写入服务器的审计日志。', style: TextStyle(color: ide.textDim, fontSize: 12)),
          const SizedBox(height: 8),
          if (ws.link == null)
            Text('连接后显示。', style: TextStyle(color: ide.textDim))
          else if (ws.servicesError != null)
            Text(ws.servicesError!, style: TextStyle(color: ide.error))
          else
            for (final svc in ws.services) _serviceRow(ide, svc),
          section('服务器'),
          Wrap(spacing: 10, runSpacing: 10, children: [
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => AddServerPage(app: ws.app, existing: e)));
                      if (mounted) unawaited(ws.app.connect(e.id));
                    },
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('重新安装或配对'),
            ),
            TextButton.icon(onPressed: _busy ? null : _remove, icon: const Icon(Icons.remove_circle_outline, size: 16), label: const Text('从列表中删除')),
          ]),
          section('危险操作'),
          Wrap(spacing: 10, runSpacing: 10, children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: ide.error, side: BorderSide(color: ide.error.withValues(alpha: 0.6))),
              onPressed: _busy ? null : () => _uninstall(purge: false),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('卸载 agent'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: ide.error),
              onPressed: _busy ? null : () => _uninstall(purge: true),
              icon: const Icon(Icons.delete_forever, size: 16),
              label: const Text('彻底清除（删除证书和令牌）'),
            ),
          ]),
          if (_note != null) ...[const SizedBox(height: 14), SelectableText(_note!)],
        ]),
      ),
    );
  }

  Widget _serviceRow(Ide ide, Map<String, dynamic> svc) {
    final id = svc['id'] as String;
    final unavailable = svc['available'] == false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_names[id] ?? id, style: const TextStyle(fontWeight: FontWeight.w500)),
            Text(unavailable ? '不可用：${svc['reason'] ?? ''}' : (_about[id] ?? ''), style: TextStyle(color: unavailable ? ide.warn : ide.textDim, fontSize: 12)),
          ]),
        ),
        Switch(key: ValueKey('service-switch-$id'), value: svc['enabled'] == true, onChanged: _switching.contains(id) ? null : (v) => _switch(id, v)),
      ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
