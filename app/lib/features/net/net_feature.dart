// Port forwarding (service "net"): a server port, such as a web app or
// Jupyter, opened on this PC at 127.0.0.1:<local>. The list of forwards is
// saved with the server; they open again when the server connects. The
// listener is on the loopback only (aurora_wire Forward), so nothing else on
// the network can use it.
import 'dart:async';
import 'dart:io';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/feature.dart';
import '../../kernel/visible_polling.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';

class NetFeature extends Feature {
  final ForwardManager manager;
  const NetFeature(this.manager);

  @override
  String get id => 'net';
  @override
  String get title => '端口转发';
  @override
  IconData get icon => Icons.swap_horiz;
  @override
  String get service => 'net';
  @override
  List<String> get ops => const ['net.ports', 'net.dial'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(title: '端口转发', body: ForwardPanel(ws: ws, manager: manager));
}

/// The open forwards of every server, kept across side bar switches. A forward
/// belongs to a link: when the link is replaced (reconnect) it is opened again
/// on the new one, on the same local port.
class ForwardManager extends ChangeNotifier {
  final Future<Forward> Function(Link, ForwardSpec) _listen;
  ForwardManager({Future<Forward> Function(Link, ForwardSpec)? listen})
      : _listen = listen ?? ((link, spec) => Forward.start(link, host: spec.host, port: spec.port, local: spec.local));
  final Map<String, Map<int, Forward>> _open = {}; // server -> local port -> forward
  final Map<String, Map<int, String>> _failed = {}; // server -> local port -> why it is not open
  final Map<String, Link> _links = {};
  final Map<String, int> _epochs = {};
  final Map<String, Future<void>> _tails = {};
  final Set<(String, int)> _pending = {};
  bool _disposed = false;

  Forward? open(String server, int local) => _open[server]?[local];
  String? failure(String server, int local) => _failed[server]?[local];
  bool busy(String server, int local) => _pending.contains((server, local));

  void _notify() { if (!_disposed) notifyListeners(); }
  bool _current(String server, Link link, int epoch) =>
      !_disposed && _epochs[server] == epoch && identical(_links[server], link);

  Future<T> _serial<T>(String server, Future<T> Function() task) {
    final result = (_tails[server] ?? Future<void>.value()).then((_) => task());
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _tails[server] = tail;
    unawaited(tail.then((_) {
      if (identical(_tails[server], tail)) _tails.remove(server);
    }));
    return result;
  }

  /// Opens the saved forwards of [entry] on [link], and closes forwards left
  /// on an older link.
  Future<void> attach(ServerEntry entry, Link link) async {
    if (_disposed || identical(_links[entry.id], link)) return;
    _links[entry.id] = link;
    final epoch = (_epochs[entry.id] ?? 0) + 1;
    _epochs[entry.id] = epoch;
    await _serial(entry.id, () async {
      await _closeAll(entry.id);
      for (final spec in entry.forwards.toList()) {
        if (!_current(entry.id, link, epoch)) return;
        await _start(entry.id, link, spec, epoch);
      }
    });
    _notify();
  }

  Future<void> detach(String server) async {
    _links.remove(server);
    _epochs[server] = (_epochs[server] ?? 0) + 1;
    await _serial(server, () => _closeAll(server));
    _notify();
  }

  Future<void> _closeAll(String server) async {
    final m = _open.remove(server);
    _failed.remove(server);
    if (m != null) {
      for (final f in m.values) {
        await f.close();
      }
    }
  }

  Future<bool> _start(String server, Link link, ForwardSpec spec, int epoch) async {
    if (!_current(server, link, epoch)) return false;
    final existing = open(server, spec.local);
    if (existing != null && !existing.isClosed) {
      return existing.host == spec.host && existing.port == spec.port;
    }
    try {
      final f = await _listen(link, spec);
      if (!_current(server, link, epoch)) {
        await f.close();
        return false;
      }
      (_open[server] ??= {})[spec.local] = f;
      _failed[server]?.remove(spec.local);
      return true;
    } on Object catch (e) {
      if (_current(server, link, epoch)) {
        (_failed[server] ??= {})[spec.local] = '本机端口 ${spec.local} 打不开：${e is SocketException ? e.osError?.message ?? e.message : e}';
      }
      return false;
    }
  }

  /// Starts one forward now. Throws a message string on failure.
  Future<void> add(ServerEntry entry, Link link, ForwardSpec spec) async {
    final key = (entry.id, spec.local), epoch = _epochs[entry.id] ?? 0;
    if (_disposed || !_pending.add(key)) throw OpError(codeConflict, '转发正在处理');
    _notify();
    try {
      final ok = await _serial(entry.id, () => _start(entry.id, link, spec, epoch));
      if (!ok) throw OpError(codeUnavailable, failure(entry.id, spec.local) ?? '连接已变化，或本机端口已被其他转发使用');
    } finally {
      _pending.remove(key);
      _notify();
    }
  }

  Future<void> stop(String server, int local, {Forward? expected}) async {
    await _serial(server, () async {
      if (expected != null && !identical(open(server, local), expected)) return;
      final f = _open[server]?.remove(local);
      _failed[server]?.remove(local);
      await f?.close();
    });
    _notify();
  }

  /// Opens a saved forward that is not running (it failed, or was stopped).
  Future<void> restart(ServerEntry entry, Link link, ForwardSpec spec) async {
    if (busy(entry.id, spec.local)) return;
    await add(entry, link, spec);
  }

  /// Called often by the panel to show live byte counts.
  void poke() => _notify();

  @override
  void dispose() {
    _disposed = true;
    _links.clear();
    for (final m in _open.values) {
      for (final f in m.values) {
        f.close();
      }
    }
    _open.clear();
    super.dispose();
  }
}

/// Who can reach a listening address: what the user wants to know about a
/// port before forwarding it, and about the rest of the list.
String _where(String addr) {
  if (addr == '0.0.0.0' || addr == '::') return '所有网卡';
  if (addr.startsWith('127.') || addr == '::1') return '仅本机';
  return addr;
}

class ForwardPanel extends StatefulWidget {
  final Workspace ws;
  final ForwardManager manager;
  const ForwardPanel({super.key, required this.ws, required this.manager});
  @override
  State<ForwardPanel> createState() => _ForwardPanelState();
}

class _ForwardPanelState extends State<ForwardPanel> with VisiblePolling<ForwardPanel> {
  List<Map<String, dynamic>>? _ports;
  bool _loadingPorts = false;
  String? _portsError;
  Link? _portsLink;
  int _portsGeneration = 0;
  bool _adding = false, _manualOpen = false;
  final Set<int> _changing = {};

  Workspace get ws => widget.ws;
  ForwardManager get mgr => widget.manager;

  // the live byte counters redraw once a second, while the panel is visible
  @override
  Duration get pollEvery => const Duration(seconds: 1);

  @override
  void poll() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    mgr.addListener(_tick);
    ws.addListener(_connectionChanged);
    _portsLink = ws.link;
    _loadPorts();
  }

  @override
  void dispose() {
    mgr.removeListener(_tick);
    ws.removeListener(_connectionChanged);
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  void _connectionChanged() {
    if (identical(_portsLink, ws.link)) return;
    _portsLink = ws.link;
    _portsGeneration++;
    _loadingPorts = false;
    _ports = null;
    _loadPorts();
  }

  Future<void> _loadPorts() async {
    final link = ws.link;
    if (_loadingPorts) return;
    if (link == null) {
      setState(() => _portsError = '未连接，连接后可查看监听端口');
      return;
    }
    final generation = ++_portsGeneration;
    bool current() => mounted && generation == _portsGeneration && identical(link, ws.link);
    setState(() => _loadingPorts = true);
    try {
      final r = (await link.call('net.ports') as Map).cast<String, dynamic>();
      if (!current()) return;
      setState(() {
        _ports = [for (final p in r['ports'] as List) (p as Map).cast<String, dynamic>()];
        _portsError = null;
      });
    } on Object catch (e) {
      if (current()) setState(() => _portsError = e is OpError ? e.message : '$e');
    } finally {
      if (current()) setState(() => _loadingPorts = false);
    }
  }

  /// A local port: the same as the server's when it is free, else any free one.
  Future<int> _freeLocal(int want) async {
    if (want >= 1024) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, want);
        await s.close();
        return want;
      } on SocketException {
        // taken: fall through
      }
    }
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  Future<void> _forward(int port, {String host = '127.0.0.1', String label = '', int? local}) async {
    final entry = ws.entry, link = ws.link;
    if (entry == null || link == null || _adding) return;
    if (entry.forwards.any((f) => f.host == host && f.port == port)) {
      return ws.toast('$host:$port 已经在转发了');
    }
    setState(() => _adding = true);
    ForwardSpec? spec;
    Forward? opened;
    try {
      spec = ForwardSpec(host: host, port: port, local: local ?? await _freeLocal(port), label: label);
      if (!mounted || !identical(link, ws.link)) return;
      if (ws.entry?.forwards.any((f) => f.local == spec!.local) == true) {
        throw StateError('本机端口 ${spec.local} 已有转发，请换一个端口');
      }
      await mgr.add(entry, link, spec);
      opened = mgr.open(entry.id, spec.local);
      await ws.app.update((p) {
        if (!identical(link, ws.link) || p.server(entry.id) == null) throw StateError('连接已变化，请重试');
        p.server(entry.id)!.forwards.add(spec!);
      });
      if (mounted) ws.toast('127.0.0.1:${spec.local} → 服务器 $host:$port');
    } on Object catch (e) {
      if (opened != null && spec != null) await mgr.stop(entry.id, spec.local, expected: opened);
      if (mounted) ws.toast(e is OpError ? e.message : '$e', error: true);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _addManual() async {
    if (_manualOpen || _adding) return;
    final link = ws.link;
    _manualOpen = true;
    try {
      final value = await showWorkbenchDialog<(String, int, int?)>(
        context: context, builder: (_) => const ForwardDialog(),
      );
      if (value != null && mounted && identical(link, ws.link)) await _forward(value.$2, host: value.$1, local: value.$3);
    } finally {
      _manualOpen = false;
    }
  }

  Future<void> _remove(ForwardSpec spec) async {
    final entry = ws.entry;
    if (entry == null || !_changing.add(spec.local)) return;
    setState(() {});
    try {
      await ws.app.update((p) => p.server(entry.id)?.forwards.removeWhere((f) => f.local == spec.local));
      await mgr.stop(entry.id, spec.local);
    } on Object catch (e) {
      if (mounted) ws.toast('删除转发失败：$e', error: true);
    } finally {
      _changing.remove(spec.local);
      if (mounted) setState(() {});
    }
  }

  Future<void> _restart(ServerEntry entry, ForwardSpec spec) async {
    final link = ws.link;
    if (link == null || _changing.contains(spec.local)) return;
    try {
      await mgr.restart(entry, link, spec);
    } on Object catch (e) {
      if (mounted) ws.toast(e is OpError ? e.message : '$e', error: true);
    }
  }

  Future<void> _openInBrowser(int local) async {
    final url = 'http://127.0.0.1:$local/';
    try {
      if (Platform.isWindows) {
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
    } on Object {
      copyText(url, what: '打不开浏览器，已复制 $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final entry = ws.entry;
    if (entry == null) return const SizedBox.shrink();
    final forwarded = {for (final f in entry.forwards) f.port};
    final ports = (_ports ?? const []).where((p) => !forwarded.contains(p['port'])).toList();
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(child: UiToolbar(children: [
        FilledButton.icon(onPressed: _adding || ws.link == null ? null : _addManual,
          busy: _adding, icon: const Icon(Icons.add, size: 16), label: const Text('新建转发')),
      ])),
      SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('已保存的转发  ${entry.forwards.length}', actions: [IconBtn(Icons.add, _adding ? '正在创建转发…' : '转发一个端口…', _adding || ws.link == null ? null : _addManual)]),
      if (entry.forwards.isEmpty)
        Padding(
          padding: const EdgeInsets.all(14),
          child: Text('还没有转发。从下面服务器上正在监听的端口里选一个，或点 + 输入端口。', style: TextStyle(color: ide.textDim, fontSize: 12)),
        ),
      ])),
      SliverList.builder(itemCount: entry.forwards.length,
        itemBuilder: (_, index) => _forwardRow(ide, entry, entry.forwards[index])),
      SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('服务器上监听的端口  ${ports.length}', actions: [
        if (_loadingPorts) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))),
        IconBtn(Icons.refresh, '刷新', _loadingPorts ? null : _loadPorts),
      ]),
      if (_portsError != null) Padding(padding: const EdgeInsets.all(10), child: Text(_portsError!, style: TextStyle(color: ide.error, fontSize: 12))),
      if (ports.isEmpty && !_loadingPorts && _portsError == null)
        Padding(padding: const EdgeInsets.all(Space.l), child: Text('没有其它监听端口；也可以手动输入目标地址。', style: TextStyle(color: ide.textDim, fontSize: 12))),
      ])),
      SliverList.builder(itemCount: ports.length, itemBuilder: (_, index) {
        final p = ports[index];
        return TreeRow(
          leading: Icon(Icons.dns_outlined, size: 14, color: ide.textDim),
          label: '${p['port']}',
          detail: [if ((p['process'] as String?)?.isNotEmpty ?? false) p['process'], _where('${p['addr']}')].join(' · '),
          onTap: () => _forward(p['port'] as int, label: (p['process'] as String?) ?? ''),
          trailing: IconBtn(Icons.arrow_forward, '转发到本机', () => _forward(p['port'] as int, label: (p['process'] as String?) ?? '')),
          menu: () => [
            MenuItem('转发到本机', () => _forward(p['port'] as int, label: (p['process'] as String?) ?? ''), icon: Icons.arrow_forward),
            if ((p['command'] as String?)?.isNotEmpty ?? false) MenuItem('复制命令行', () => copyText(p['command'] as String), icon: Icons.copy),
          ],
        );
      }),
    ]);
  }

  Widget _forwardRow(Ide ide, ServerEntry entry, ForwardSpec spec) {
    final live = mgr.open(entry.id, spec.local);
    final why = mgr.failure(entry.id, spec.local);
    final running = live != null && !live.isClosed;
    final busy = mgr.busy(entry.id, spec.local) || _changing.contains(spec.local);
    return TreeRow(
      leading: StatusDot(running ? ide.ok : (why != null ? ide.error : ide.textDim)),
      label: '127.0.0.1:${spec.local}  →  ${spec.host == '127.0.0.1' ? '' : '${spec.host}:'}${spec.port}',
      detail: spec.label.isEmpty ? null : spec.label,
      subtitle: busy ? '正在处理…' : why ?? (running ? '${live.connections} 个连接 · ↑${formatSize(live.bytesOut)} ↓${formatSize(live.bytesIn)}${live.lastError == null ? '' : ' · ${live.lastError}'}' : '未运行'),
      labelColor: running ? null : ide.textDim,
      onTap: running ? () => _openInBrowser(spec.local) : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (running) IconBtn(Icons.open_in_browser, '在浏览器打开', () => _openInBrowser(spec.local)),
        if (!running) IconBtn(Icons.play_arrow, '重新打开', ws.link == null || busy ? null : () => _restart(entry, spec)),
        IconBtn(Icons.close, '删除这个转发', busy ? null : () => _remove(spec)),
      ]),
      menu: () => [
        if (running) MenuItem('在浏览器打开', () => _openInBrowser(spec.local), icon: Icons.open_in_browser),
        MenuItem('复制本机地址', () => copyText('127.0.0.1:${spec.local}'), icon: Icons.copy),
        const MenuItem.separator(),
        MenuItem('删除', busy ? null : () => _remove(spec), icon: Icons.close, danger: true),
      ],
    );
  }
}

class ForwardDialog extends StatefulWidget {
  const ForwardDialog({super.key});
  @override
  State<ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<ForwardDialog> {
  final _address = TextEditingController(), _local = TextEditingController();
  String? _error;
  void _submit() {
    final text = _address.text.trim();
    final address = splitHostPort(text.contains(':') ? text : '127.0.0.1:$text');
    final local = _local.text.trim().isEmpty ? null : int.tryParse(_local.text.trim());
    if (address == null || address.$1.contains(RegExp(r'\s')) ||
        (_local.text.trim().isNotEmpty && (local == null || local < 1 || local > 65535))) {
      setState(() => _error = '请输入有效地址，端口须在 1–65535 之间');
      return;
    }
    Navigator.pop(context, (address.$1, address.$2, local));
  }

  @override
  void dispose() { _address.dispose(); _local.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('转发一个端口'),
    content: SizedBox(width: 380, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(controller: _address, autofocus: true, onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(labelText: '服务器上的地址', hintText: '8080 或 db.internal:5432', helperText: '只写端口时使用 127.0.0.1；IPv6 用 [::1]:8080')),
        const SizedBox(height: 12),
        TextField(controller: _local, onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(labelText: '本机端口（可选）', helperText: '留空则自动选择可用端口')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(_error!, style: TextStyle(color: Ide.of(context).error))),
      ],
    ))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _submit, child: const Text('转发')),
    ],
  );
}
