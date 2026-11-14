// Proxy (service "proxy"): pick the node this server's terminals and git leave
// through. The nodes come from a subscription the user adds here, or from links
// they paste (D-83). The subscription is fetched and read on this PC (D-84);
// the server is only ever sent the one node chosen, and is the one that times
// the nodes, because a node's speed from a server in China is not its speed
// from this PC.
import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_sub/aurora_sub.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/feature.dart';
import '../../kernel/visible_polling.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'proxy_model.dart';

class ProxyFeature extends Feature {
  const ProxyFeature();

  @override
  String get id => 'proxy';
  @override
  String get title => '代理';
  @override
  IconData get icon => Icons.public;
  @override
  String get service => 'proxy';
  @override
  List<String> get ops => const ['proxy.status', 'proxy.set', 'proxy.clear', 'proxy.test', 'proxy.check'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(
    title: '代理',
    body: ProxyPanel(ws: ws),
  );
}

class ProxyPanel extends StatefulWidget {
  final Workspace ws;
  const ProxyPanel({super.key, required this.ws});
  @override
  State<ProxyPanel> createState() => ProxyPanelState();
}

class ProxyPanelState extends State<ProxyPanel> with VisiblePolling<ProxyPanel> {
  Workspace get ws => widget.ws;
  late final ProxyModel model = ws.app.proxies;

  Map<String, dynamic>? _status;
  String? _statusError;
  final Map<String, String> _agentReasons = {}; // node key -> why the agent cannot use it
  final Map<String, NodeRow> _timed = {}; // node key -> last timing, kept across rebuilds
  bool _testing = false;
  bool _cancel = false;
  String? _busy; // source id being refreshed
  String _filter = '';

  @override
  Duration get pollEvery => const Duration(seconds: 5);

  @override
  void poll() => _loadStatus();

  @override
  void initState() {
    super.initState();
    _loadStatus();
    ws.app.addListener(_onApp);
  }

  @override
  void dispose() {
    _cancel = true;
    ws.app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  Future<void> _loadStatus() async {
    final link = ws.link;
    if (link == null) return;
    try {
      final r = await link.call('proxy.status') as Map;
      if (!mounted) return;
      setState(() {
        _status = r.cast<String, dynamic>();
        _statusError = null;
      });
    } on OpError catch (e) {
      if (mounted) setState(() => _statusError = e.message);
    }
  }

  Future<void> _checkSource(ProxySource s) async {
    final link = ws.link;
    if (link == null) return;
    try {
      final nodes = [for (final j in s.nodes) SubNode.fromJson(j)];
      final r = await model.check(link, nodes);
      if (!mounted) return;
      setState(() {
        for (final n in nodes) {
          _agentReasons.remove(n.key);
        }
        _agentReasons.addAll(r);
      });
    } on OpError {
      // an agent without proxy.check: the parser's own reasons still show
    }
  }

  // ---- adding and refreshing ----

  Future<void> _add() async {
    final r = await showWorkbenchDialog<_NewSource>(context: context, builder: (_) => const _AddSourceDialog());
    if (r == null || !mounted) return;
    setState(() => _busy = 'new');
    try {
      final src = r.url != null ? await model.addSubscription(r.name, r.url!) : await model.addPasted(r.name, r.text!);
      ws.toast('已添加“${src.name}”，${src.nodes.length} 个节点');
      await _checkSource(src);
    } on FetchError catch (e) {
      ws.toast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _refresh(ProxySource s) async {
    setState(() => _busy = s.id);
    try {
      final r = await model.refresh(s.id);
      if (!mounted) return;
      if (r.error != null) {
        ws.toast('更新失败，仍用上次的节点：${r.error}', error: true);
        return;
      }
      final fresh = ws.app.profile.proxySource(s.id);
      if (fresh != null) await _checkSource(fresh);
      // A server whose chosen node moved is told, if it is reachable now.
      var pushed = 0;
      for (final id in r.changedServers) {
        final e = ws.app.profile.server(id);
        final l = ws.app.link(id);
        if (e == null || l == null) continue;
        try {
          if (await model.repush(e, l)) pushed++;
        } on OpError {
          // told next time it is chosen, or refreshed while connected
        }
      }
      final notes = <String>[
        '${r.count} 个节点',
        if (pushed > 0) '已把变化的节点参数同步到 $pushed 台服务器',
        if (r.changedServers.length > pushed) '${r.changedServers.length - pushed} 台服务器没连上，没有同步',
        if (r.gone > 0) '${r.gone} 台服务器选的节点已不在订阅里，仍用原来的',
      ];
      ws.toast('已更新：${notes.join('；')}');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _remove(ProxySource s) async {
    final using = ws.app.profile.servers.where((e) => e.proxy?.source == s.id).toList();
    final ok = await showWorkbenchDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除“${s.name}”？'),
        content: Text(
          using.isEmpty ? '会删掉保存的订阅地址和节点。' : '${using.length} 台服务器正在用它的节点：${using.map((e) => e.name).join('、')}。\n删除只是让客户端忘掉这个来源；服务器上已经选好的节点不会改，直到你清除它。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await model.remove(s.id);
  }

  // ---- using a node ----

  Future<void> _choose(NodeRow row) async {
    final link = ws.link, e = ws.entry;
    if (link == null || e == null) return;
    if (!row.usable) {
      ws.toast('这个节点用不了：${row.blocked}', error: true);
      return;
    }
    if (row.node.insecure) {
      final go = await showWorkbenchDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('这个节点不校验服务器证书'),
          content: const Text('机场把它标成了“跳过证书验证”。选用后，服务器上经它走的流量，无法确认对面是不是这个节点本人。仍要使用吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('仍然使用')),
          ],
        ),
      );
      if (go != true) return;
    }
    await ws.guard(() => model.choose(e, link, row));
    await _loadStatus();
  }

  Future<void> _clearChoice() async {
    final link = ws.link, e = ws.entry;
    if (link == null || e == null) return;
    await ws.guard(() => model.clear(e, link));
    await _loadStatus();
  }

  Future<void> _testAll(List<NodeRow> rows) async {
    final link = ws.link;
    if (link == null || _testing) return;
    setState(() {
      _testing = true;
      _cancel = false;
      for (final row in rows.where((r) => r.usable)) {
        row.ms = null;
        row.testError = null;
        _timed[row.node.key] = row;
      }
    });
    try {
      await model.testAll(
        link,
        rows,
        onEach: () {
          if (mounted) setState(() {});
        },
        cancelled: () => _cancel || !mounted,
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _testOne(NodeRow row) async {
    final link = ws.link;
    if (link == null) return;
    setState(() {
      row.ms = null;
      row.testError = null;
      // _source builds fresh rows on every frame. Keep the object the async
      // test fills, so the next build can recover its result instead of
      // throwing it away (and so switching sidebars keeps the result).
      _timed[row.node.key] = row;
    });
    await model.test(link, row);
    if (mounted) setState(() {});
  }

  // ---- view ----

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final entry = ws.entry;
    if (entry == null) return const SizedBox.shrink();
    final sources = ws.app.profile.proxySources;
    final choice = entry.proxy;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _current(ide, entry)),
        SliverToBoxAdapter(
          child: SectionHeader(
            '来源  ${sources.length}',
            actions: [
              if (_busy == 'new')
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                ),
              IconBtn(Icons.add, '添加订阅或节点…', _busy == null ? _add : null),
            ],
          ),
        ),
        if (sources.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text('还没有来源。点 + 填入机场的订阅地址，或粘贴节点链接。订阅只在这台电脑上读取，服务器只会收到你选中的那一个节点。', style: TextStyle(color: ide.textDim, fontSize: 12)),
            ),
          ),
        for (final s in sources) ..._source(ide, s, choice),
      ],
    );
  }

  Widget _current(Ide ide, ServerEntry entry) {
    final st = _status;
    final node = st?['node'] as Map?;
    final running = st?['running'] == true;
    final choice = entry.proxy;
    String line;
    Color? color;
    if (_statusError != null) {
      line = _statusError!;
      color = ide.error;
    } else if (st == null) {
      line = '读取中…';
    } else if (node == null) {
      line = '还没有选节点。新建终端时勾选“走代理”，需要先选一个。';
    } else {
      final verify = switch (node['verify']) {
        'pin' => '指纹校验',
        'none' => '不校验证书',
        'no-tls' => '无 TLS',
        _ => '系统根证书',
      };
      final err = st['last_error'] as String?;
      line =
          '${node['name'] ?? node['host']}  ·  ${node['proto']}  ·  $verify'
          '${running ? '' : '  ·  未运行'}'
          '${(st['total'] ?? 0) == 0 ? '' : '  ·  ${st['total']} 次连接，${st['failed']} 次失败'}'
          '${err == null ? '' : '\n最近的失败：$err'}';
      if (err != null) color = ide.error;
    }
    final moved = choice != null && ws.app.profile.proxySource(choice.source)?.nodes.any((j) => SubNode.fromJson(j).key == choice.key) != true;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: ide.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('这台服务器现在用的节点', style: TextStyle(fontSize: 11, color: ide.textDim)),
              ),
              if (node != null) IconBtn(Icons.link_off, '不再使用代理节点', _clearChoice),
            ],
          ),
          const SizedBox(height: 4),
          Text(line, style: TextStyle(fontSize: 12.5, color: color)),
          if (choice?.pending == true || choice?.syncError != null)
            Text(choice?.syncError ?? '节点参数待同步；连接恢复后会自动重试', style: TextStyle(fontSize: 11.5, color: ide.warn)),
          if (moved)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('这个节点已经不在订阅里了。服务器上仍在用原来的，直到你换一个或清除。', style: TextStyle(fontSize: 11.5, color: ide.warn)),
            ),
        ],
      ),
    );
  }

  List<Widget> _source(Ide ide, ProxySource s, ProxyChoice? choice) {
    final rows = model.rows(s, _agentReasons);
    for (final r in rows) {
      final prev = _timed[r.node.key];
      if (prev != null) {
        r.ms = prev.ms;
        r.testError = prev.testError;
      }
    }
    final q = _filter.trim().toLowerCase();
    final shown = [
      for (final r in rows)
        if (q.isEmpty || r.node.name.toLowerCase().contains(q) || r.node.host.toLowerCase().contains(q)) r,
    ];
    final usable = rows.where((r) => r.usable).length;
    final updated = s.updated == 0 ? '' : formatTime(s.updated * 1000);
    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          '${s.name}  ·  $usable/${rows.length} 可用',
          actions: [
            if (_busy == s.id)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
              ),
            if (_testing)
              IconBtn(Icons.stop, '停止测速', () => setState(() => _cancel = true))
            else
              IconBtn(Icons.speed, '从这台服务器测速', ws.link == null ? null : () => _testAll(rows)),
            if (s.url != null) IconBtn(Icons.refresh, '重新读取订阅', _busy == null ? () => _refresh(s) : null),
            IconBtn(Icons.delete_outline, '删除这个来源', () => _remove(s)),
          ],
        ),
      ),
      if (s.error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            child: Text('上次更新失败：${s.error}', style: TextStyle(color: ide.error, fontSize: 12)),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          child: Text('${s.url == null ? '粘贴的节点' : '订阅'}${updated.isEmpty ? '' : '  ·  更新于 $updated'}', style: TextStyle(color: ide.textDim, fontSize: 11)),
        ),
      ),
      if (rows.length > 12)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
            child: SizedBox(
              height: 30,
              child: TextField(
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(isDense: true, hintText: '按名称或地址筛选', prefixIcon: Icon(Icons.search, size: 16)),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
          ),
        ),
      // Airport subscriptions can contain thousands of entries. Create only
      // visible rows, instead of building the whole source on every visit,
      // filter change or periodic status update.
      SliverList.builder(itemCount: shown.length, itemBuilder: (_, i) => _row(ide, shown[i], choice)),
    ];
  }

  Widget _row(Ide ide, NodeRow r, ProxyChoice? choice) {
    final chosen = choice != null && choice.source == r.source.id && choice.key == r.node.key;
    final t = r.ms != null ? '${r.ms} ms' : (r.testError != null ? '失败' : '');
    final sub = r.usable ? [r.node.proto, r.node.verify, if (r.testError != null) r.testError!].join('  ·  ') : r.blocked;
    return TreeRow(
      leading: chosen
          ? Icon(Icons.check_circle, size: 14, color: ide.ok)
          : Icon(r.usable ? Icons.circle_outlined : Icons.block, size: 14, color: r.usable ? ide.textDim : ide.error),
      label: r.node.name.isEmpty ? r.node.host : r.node.name,
      detail: t.isEmpty ? null : t,
      subtitle: sub,
      labelColor: r.usable ? null : ide.textDim,
      selected: chosen,
      onTap: r.usable ? () => _choose(r) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (r.usable) IconBtn(Icons.speed, '测速', ws.link == null ? null : () => _testOne(r)),
          if (r.usable && !chosen) IconBtn(Icons.check, '用这个节点', () => _choose(r)),
        ],
      ),
      menu: () => [
        if (r.usable) MenuItem('用这个节点', () => _choose(r), icon: Icons.check),
        if (r.usable) MenuItem('测速', () => _testOne(r), icon: Icons.speed),
        MenuItem('复制地址', () => copyText('${r.node.host}:${r.node.port}'), icon: Icons.copy),
      ],
    );
  }
}

class _NewSource {
  final String name;
  final String? url;
  final String? text;
  _NewSource(this.name, {this.url, this.text});
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog();
  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _text = TextEditingController();
  bool _pasted = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _text.dispose();
    super.dispose();
  }

  void _ok() {
    final name = _name.text.trim().isEmpty ? (_pasted ? '粘贴的节点' : '订阅') : _name.text.trim();
    if (_pasted) {
      if (_text.text.trim().isEmpty) return;
      Navigator.pop(context, _NewSource(name, text: _text.text));
    } else {
      if (_url.text.trim().isEmpty) return;
      Navigator.pop(context, _NewSource(name, url: _url.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return AlertDialog(
      title: const Text('添加代理来源'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('订阅地址')),
                ButtonSegment(value: true, label: Text('粘贴节点')),
              ],
              selected: {_pasted},
              onSelectionChanged: (s) => setState(() => _pasted = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称（可不填）'),
            ),
            const SizedBox(height: 8),
            if (!_pasted) ...[
              TextField(
                controller: _url,
                autofocus: true,
                decoration: const InputDecoration(labelText: '订阅地址', hintText: 'https://…'),
                onSubmitted: (_) => _ok(),
              ),
              const SizedBox(height: 8),
              Text(
                '地址里含有你账号的密钥：只保存在这台电脑，加密存放，不会发给服务器。支持 Clash 配置，以及一行一个节点链接的订阅（vless、vmess、trojan、hysteria2）。',
                style: TextStyle(fontSize: 11.5, color: ide.textDim),
              ),
            ] else ...[
              TextField(
                controller: _text,
                autofocus: true,
                maxLines: 6,
                decoration: const InputDecoration(labelText: '节点链接，每行一个；或 Clash 的 proxies 配置'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(color: ide.textDim)),
        ),
        FilledButton(onPressed: _ok, child: const Text('添加')),
      ],
    );
  }
}
