// Port forwarding (service "net"): a server port, such as a web app or
// Jupyter, opened on this PC at 127.0.0.1:<local>. The list of forwards is
// saved with the server; they open again when the server connects. The
// listener is on the loopback only (aurora_wire Forward), so nothing else on
// the network can use it.
import 'dart:async';
import 'dart:io';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/feature.dart';
import '../../kernel/visible_polling.dart';
import '../../kernel/widgets.dart';
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
  final Map<String, Map<int, Forward>> _open = {}; // server -> local port -> forward
  final Map<String, Map<int, String>> _failed = {}; // server -> local port -> why it is not open
  final Map<String, Link> _links = {};

  Forward? open(String server, int local) => _open[server]?[local];
  String? failure(String server, int local) => _failed[server]?[local];

  /// Opens the saved forwards of [entry] on [link], and closes forwards left
  /// on an older link.
  Future<void> attach(ServerEntry entry, Link link) async {
    if (identical(_links[entry.id], link)) return;
    _links[entry.id] = link;
    await _closeAll(entry.id);
    for (final spec in entry.forwards) {
      await _start(entry.id, link, spec);
    }
    notifyListeners();
  }

  Future<void> detach(String server) async {
    _links.remove(server);
    await _closeAll(server);
    notifyListeners();
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

  Future<void> _start(String server, Link link, ForwardSpec spec) async {
    try {
      final f = await Forward.start(link, host: spec.host, port: spec.port, local: spec.local);
      (_open[server] ??= {})[spec.local] = f;
      _failed[server]?.remove(spec.local);
    } on SocketException catch (e) {
      (_failed[server] ??= {})[spec.local] = '本机端口 ${spec.local} 打不开：${e.osError?.message ?? e.message}';
    }
  }

  /// Starts one forward now. Throws a message string on failure.
  Future<void> add(ServerEntry entry, Link link, ForwardSpec spec) async {
    await _start(entry.id, link, spec);
    final why = _failed[entry.id]?[spec.local];
    if (why != null) throw why;
    notifyListeners();
  }

  Future<void> stop(String server, int local) async {
    final f = _open[server]?.remove(local);
    _failed[server]?.remove(local);
    await f?.close();
    notifyListeners();
  }

  /// Opens a saved forward that is not running (it failed, or was stopped).
  Future<void> restart(ServerEntry entry, Link link, ForwardSpec spec) async {
    await stop(entry.id, spec.local);
    await _start(entry.id, link, spec);
    notifyListeners();
  }

  /// Called often by the panel to show live byte counts.
  void poke() => notifyListeners();

  @override
  void dispose() {
    for (final m in _open.values) {
      for (final f in m.values) {
        f.close();
      }
    }
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
    _loadPorts();
  }

  @override
  void dispose() {
    mgr.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPorts() async {
    final link = ws.link;
    if (link == null) return;
    setState(() => _loadingPorts = true);
    try {
      final r = (await link.call('net.ports') as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _ports = [for (final p in r['ports'] as List) (p as Map).cast<String, dynamic>()];
        _portsError = null;
      });
    } on OpError catch (e) {
      if (mounted) setState(() => _portsError = e.message);
    } finally {
      if (mounted) setState(() => _loadingPorts = false);
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
    if (entry == null || link == null) return;
    if (entry.forwards.any((f) => f.host == host && f.port == port)) {
      return ws.toast('$host:$port 已经在转发了');
    }
    final spec = ForwardSpec(host: host, port: port, local: local ?? await _freeLocal(port), label: label);
    try {
      await mgr.add(entry, link, spec);
    } catch (e) {
      return ws.toast('$e', error: true);
    }
    await ws.app.update((p) => p.server(entry.id)?.forwards.add(spec));
    ws.toast('127.0.0.1:${spec.local} → 服务器 $host:$port');
  }

  Future<void> _addManual() async {
    final c = TextEditingController();
    final local = TextEditingController();
    final ide = Ide.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转发一个端口'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: '服务器上的地址', hintText: '8080 或 db.internal:5432', helperText: '只写端口时，指服务器自己的 127.0.0.1')),
            const SizedBox(height: 12),
            TextField(controller: local, decoration: const InputDecoration(labelText: '本机端口（可选）', helperText: '留空则优先用同一个端口号，被占用就换一个')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: ide.textDim))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('转发')),
        ],
      ),
    );
    if (ok != true) return;
    final text = c.text.trim();
    final i = text.lastIndexOf(':');
    final host = i > 0 ? text.substring(0, i) : '127.0.0.1';
    final port = int.tryParse(i > 0 ? text.substring(i + 1) : text);
    final lp = local.text.trim().isEmpty ? null : int.tryParse(local.text.trim());
    if (port == null || port < 1 || port > 65535 || (local.text.trim().isNotEmpty && (lp == null || lp < 1 || lp > 65535))) {
      return ws.toast('端口要在 1 到 65535 之间', error: true);
    }
    await _forward(port, host: host, local: lp);
  }

  Future<void> _remove(ForwardSpec spec) async {
    final entry = ws.entry;
    if (entry == null) return;
    await mgr.stop(entry.id, spec.local);
    await ws.app.update((p) => p.server(entry.id)?.forwards.removeWhere((f) => f.local == spec.local));
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
    return ListView(children: [
      SectionHeader('转发中  ${entry.forwards.length}', actions: [IconBtn(Icons.add, '转发一个端口…', _addManual)]),
      if (entry.forwards.isEmpty)
        Padding(
          padding: const EdgeInsets.all(14),
          child: Text('还没有转发。从下面服务器上正在监听的端口里选一个，或点 + 输入端口。', style: TextStyle(color: ide.textDim, fontSize: 12)),
        ),
      for (final f in entry.forwards) _forwardRow(ide, entry, f),
      SectionHeader('服务器上监听的端口  ${ports.length}', actions: [
        if (_loadingPorts) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))),
        IconBtn(Icons.refresh, '刷新', _loadPorts),
      ]),
      if (_portsError != null) Padding(padding: const EdgeInsets.all(10), child: Text(_portsError!, style: TextStyle(color: ide.error, fontSize: 12))),
      for (final p in ports)
        TreeRow(
          leading: Icon(Icons.dns_outlined, size: 14, color: ide.textDim),
          label: '${p['port']}',
          detail: [if ((p['process'] as String?)?.isNotEmpty ?? false) p['process'], _where('${p['addr']}')].join(' · '),
          onTap: () => _forward(p['port'] as int, label: (p['process'] as String?) ?? ''),
          trailing: IconBtn(Icons.arrow_forward, '转发到本机', () => _forward(p['port'] as int, label: (p['process'] as String?) ?? '')),
          menu: () => [
            MenuItem('转发到本机', () => _forward(p['port'] as int, label: (p['process'] as String?) ?? ''), icon: Icons.arrow_forward),
            if ((p['command'] as String?)?.isNotEmpty ?? false) MenuItem('复制命令行', () => copyText(p['command'] as String), icon: Icons.copy),
          ],
        ),
    ]);
  }

  Widget _forwardRow(Ide ide, ServerEntry entry, ForwardSpec spec) {
    final live = mgr.open(entry.id, spec.local);
    final why = mgr.failure(entry.id, spec.local);
    final running = live != null && !live.isClosed;
    return TreeRow(
      leading: StatusDot(running ? ide.ok : (why != null ? ide.error : ide.textDim)),
      label: '127.0.0.1:${spec.local}  →  ${spec.host == '127.0.0.1' ? '' : '${spec.host}:'}${spec.port}',
      detail: spec.label.isEmpty ? null : spec.label,
      subtitle: why ?? (running ? '${live.connections} 个连接 · ↑${formatSize(live.bytesOut)} ↓${formatSize(live.bytesIn)}${live.lastError == null ? '' : ' · ${live.lastError}'}' : '未运行'),
      labelColor: running ? null : ide.textDim,
      onTap: running ? () => _openInBrowser(spec.local) : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (running) IconBtn(Icons.open_in_browser, '在浏览器打开', () => _openInBrowser(spec.local)),
        if (!running) IconBtn(Icons.play_arrow, '重新打开', ws.link == null ? null : () => mgr.restart(entry, ws.link!, spec)),
        IconBtn(Icons.close, '删除这个转发', () => _remove(spec)),
      ]),
      menu: () => [
        if (running) MenuItem('在浏览器打开', () => _openInBrowser(spec.local), icon: Icons.open_in_browser),
        MenuItem('复制本机地址', () => copyText('127.0.0.1:${spec.local}'), icon: Icons.copy),
        const MenuItem.separator(),
        MenuItem('删除', () => _remove(spec), icon: Icons.close, danger: true),
      ],
    );
  }
}
