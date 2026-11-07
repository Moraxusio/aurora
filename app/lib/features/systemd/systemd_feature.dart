// systemd units and their logs (services "systemd" and "monitor"). The list
// shows every service unit with its state; start, stop and restart work on a
// unit only after the user has allowed that action for it (D-28: an allowlist
// on the server, changed here with agent.actions). The log of a unit opens in
// a tab (journalctl through log.tail).
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'unit_kind.dart';

class SystemdFeature extends Feature {
  const SystemdFeature();

  @override
  String get id => 'systemd';
  @override
  String get title => '系统服务';
  @override
  IconData get icon => Icons.settings_applications_outlined;
  @override
  String get service => 'systemd';
  @override
  List<String> get ops => const ['svc.list', 'svc.info', 'svc.action'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(title: '系统服务', body: UnitList(ws: ws));
}

class UnitList extends StatefulWidget {
  final Workspace ws;
  const UnitList({super.key, required this.ws});
  @override
  State<UnitList> createState() => _UnitListState();
}

class _UnitListState extends State<UnitList> {
  List<Map<String, dynamic>> _units = [];
  Map<String, List<String>> _allow = {};
  bool _loading = true;
  String? _error;
  final _filter = TextEditingController();
  bool _showAll = false;
  final Set<String> _busy = {};

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final link = ws.link;
    if (link == null) return;
    setState(() => _loading = true);
    try {
      final r = (await link.call('svc.list') as Map).cast<String, dynamic>();
      final a = (await link.call('agent.actions') as Map)['actions'] as Map;
      if (!mounted) return;
      setState(() {
        _units = [for (final u in r['units'] as List) (u as Map).cast<String, dynamic>()];
        _allow = {for (final e in a.entries) '${e.key}': [for (final x in e.value as List) '$x']};
        _error = null;
      });
    } on OpError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(String unit, String action) async {
    final link = ws.link;
    if (link == null) return;
    // Stopping or restarting a unit interrupts whatever depends on it, and a
    // finger can hit the button by mistake: ask every time, not only the first.
    if (action != 'start') {
      final ok = await confirmDialog(context,
          title: '${_actionLabel(action)} $unit？',
          body: action == 'stop' ? '它提供的功能会中断，直到再次启动。' : '它会短暂中断。',
          ok: _actionLabel(action),
          danger: true);
      if (!ok || !mounted) return;
    }
    final allowed = _allow[unit] ?? const [];
    if (!allowed.contains(action)) {
      final label = _actionLabel(action);
      final ok = await confirmDialog(context,
          title: '允许对 $unit 执行“$label”？',
          body: '这会写入服务器的授权名单（agent.json 的 service_actions），并记入审计日志。之后可以在这个单元的菜单里收回。',
          ok: '允许并$label');
      if (!ok) return;
      final next = {...allowed, action}.toList();
      final granted = await ws.guard(() => link.call('agent.actions', {'name': unit, 'actions': next}));
      if (granted == null) return;
      _allow[unit] = next;
    }
    setState(() => _busy.add(unit));
    try {
      final r = (await link.call('svc.action', {'name': unit, 'action': action}) as Map).cast<String, dynamic>();
      ws.toast('$unit：${_actionLabel(action)}完成（${r['active']}）');
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(unit));
    }
    await _load();
  }

  Future<void> _revoke(String unit) async {
    final link = ws.link;
    if (link == null) return;
    final ok = await confirmDialog(context, title: '收回对 $unit 的所有授权？', body: '之后不能从这里启动、停止或重启它，直到再次允许。', ok: '收回');
    if (!ok) return;
    if (await ws.guard(() => link.call('agent.actions', {'name': unit, 'actions': <String>[]})) != null) await _load();
  }

  static String _actionLabel(String a) => switch (a) { 'start' => '启动', 'stop' => '停止', 'restart' => '重启', _ => a };

  void _openLog(String unit) {
    ws.openTab(EditorTab(
      id: 'log:$unit',
      title: '$unit 日志',
      icon: Icons.receipt_long_outlined,
      tooltip: 'journalctl -u $unit',
      builder: (_) => LogView(ws: ws, unit: unit),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _load);
    final q = _filter.text.trim().toLowerCase();
    final shown = _units.where((u) {
      // Most of a system's 100+ units are static or one-shot and not running:
      // they are behind the toggle, so the list shows what is worth a look.
      final kind = unitKind(u['active'] as String? ?? '', u['sub'] as String? ?? '');
      if (!_showAll && kind != UnitKind.running && kind != UnitKind.failed && kind != UnitKind.busy) return false;
      if (u['load'] == 'not-found') return false;
      return q.isEmpty || '${u['name']} ${u['description']}'.toLowerCase().contains(q);
    }).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Row(children: [
          Expanded(child: SizedBox(height: 30, child: TextField(controller: _filter, style: const TextStyle(fontSize: 13), decoration: const InputDecoration(hintText: '筛选服务', prefixIcon: Icon(Icons.search, size: 16), prefixIconConstraints: BoxConstraints(minWidth: 30))))),
          IconBtn(_showAll ? Icons.visibility : Icons.visibility_off_outlined, _showAll ? '只看运行中和失败的' : '显示全部（含未运行的）', () => setState(() => _showAll = !_showAll), color: _showAll ? ide.accent : null),
          IconBtn(Icons.refresh, '刷新', _load),
        ]),
      ),
      const Divider(),
      if (_loading && _units.isEmpty) const Expanded(child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
      if (!(_loading && _units.isEmpty))
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (_, i) => _row(ide, shown[i]),
          ),
        ),
      Container(
        height: 22,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: ide.border))),
        child: Text('${shown.length} / ${_units.where((u) => u['load'] != 'not-found').length} 个服务', style: TextStyle(color: ide.textDim, fontSize: 11)),
      ),
    ]);
  }

  Widget _row(Ide ide, Map<String, dynamic> u) {
    final name = u['name'] as String;
    final kind = unitKind(u['active'] as String? ?? '', u['sub'] as String? ?? '');
    final color = switch (kind) { UnitKind.running => ide.ok, UnitKind.failed => ide.error, UnitKind.busy => ide.warn, _ => ide.textDim };
    final allowed = _allow[name] ?? const <String>[];
    final running = kind == UnitKind.running;
    final canStop = running || kind == UnitKind.busy;
    return TreeRow(
      leading: _busy.contains(name) ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)) : StatusDot(color),
      label: name.endsWith('.service') ? name.substring(0, name.length - 8) : name,
      detail: unitNote(kind, u['file'] as String? ?? ''),
      labelColor: kind == UnitKind.exited || kind == UnitKind.stopped ? ide.textDim : null,
      onTap: () => _openLog(name),
      // Buttons only where they mean something: a finished one-shot has
      // nothing to stop, and a unit that is not running has nothing to
      // restart. The same actions stay in the menu.
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (running) IconBtn(Icons.restart_alt, '重启', _busy.contains(name) ? null : () => _act(name, 'restart')),
        if (canStop) IconBtn(Icons.stop, '停止', _busy.contains(name) ? null : () => _act(name, 'stop')),
        if (!canStop && kind != UnitKind.exited) IconBtn(Icons.play_arrow, '启动', _busy.contains(name) ? null : () => _act(name, 'start')),
      ]),
      menu: () => [
        MenuItem('查看日志', () => _openLog(name), icon: Icons.receipt_long_outlined),
        const MenuItem.separator(),
        if (!running) MenuItem('启动…', () => _act(name, 'start'), icon: Icons.play_arrow),
        if (canStop) MenuItem('停止…', () => _act(name, 'stop'), icon: Icons.stop),
        MenuItem('重启…', () => _act(name, 'restart'), icon: Icons.restart_alt),
        if (allowed.isNotEmpty) MenuItem('收回授权（现允许：${allowed.map(_actionLabel).join('、')}）', () => _revoke(name), icon: Icons.lock_outline),
        const MenuItem.separator(),
        MenuItem('复制名称', () => copyText(name), icon: Icons.copy),
      ],
    );
  }
}

/// The whole system's journal (service "monitor", log.tail).
EditorTab systemLogTab(Workspace ws) => EditorTab(
      id: 'log:',
      title: '系统日志',
      icon: Icons.receipt_long_outlined,
      tooltip: 'journalctl',
      builder: (_) => LinkGate(ws: ws, builder: (_, _) => LogView(ws: ws, unit: '')),
    );

/// journalctl for one unit or the whole system, refreshed on request or
/// every few seconds while "跟随" is on.
class LogView extends StatefulWidget {
  final Workspace ws;

  /// A unit name, or empty for the system journal.
  final String unit;
  const LogView({super.key, required this.ws, required this.unit});
  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  String _text = '';
  bool _loading = true;
  String? _error;
  bool _follow = false;
  int _lines = 300;
  Timer? _timer;
  final _scroll = ScrollController();
  final _filter = TextEditingController();
  bool _stick = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients) _stick = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    });
    _filter.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final link = widget.ws.link;
    if (link == null) return;
    try {
      final r = (await link.call('log.tail', {'name': widget.unit, 'lines': _lines}) as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _text = (r['lines'] as String?) ?? '';
        _error = r['exit_code'] != 0 && _text.isEmpty ? 'journalctl 没有返回内容（退出码 ${r['exit_code']}）。这个用户可能没有读日志的权限，或系统没有 journal。' : null;
        _loading = false;
      });
      if (_stick) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    } on OpError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  void _setFollow(bool on) {
    setState(() => _follow = on);
    _timer?.cancel();
    if (on) {
      _stick = true;
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
    }
  }

  Color _levelColor(Ide ide, String line) {
    final l = line.toLowerCase();
    if (l.contains(' error') || l.contains('failed') || l.contains('fatal') || l.contains('panic')) return ide.error;
    if (l.contains(' warn')) return ide.warn;
    return ide.text;
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final q = _filter.text.trim().toLowerCase();
    var lines = _text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (q.isNotEmpty) lines = lines.where((l) => l.toLowerCase().contains(q)).toList();
    return Column(children: [
      Container(
        height: 34,
        color: ide.sideBar,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          SizedBox(width: 220, height: 26, child: TextField(controller: _filter, style: const TextStyle(fontSize: 12), decoration: const InputDecoration(hintText: '筛选', prefixIcon: Icon(Icons.search, size: 15), prefixIconConstraints: BoxConstraints(minWidth: 28), contentPadding: EdgeInsets.symmetric(vertical: 4)))),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: _lines,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(fontSize: 12, color: ide.text),
            items: const [DropdownMenuItem(value: 100, child: Text('最近 100 行')), DropdownMenuItem(value: 300, child: Text('最近 300 行')), DropdownMenuItem(value: 1000, child: Text('最近 1000 行'))],
            onChanged: (v) {
              setState(() => _lines = v ?? 300);
              _load();
            },
          ),
          const Spacer(),
          Text('${lines.length} 行', style: TextStyle(color: ide.textDim, fontSize: 11)),
          IconBtn(_follow ? Icons.pause_circle_outline : Icons.play_circle_outline, _follow ? '停止跟随' : '跟随（每 3 秒刷新）', () => _setFollow(!_follow), color: _follow ? ide.accent : null),
          IconBtn(Icons.refresh, '刷新', _load),
          IconBtn(Icons.copy, '复制全部', lines.isEmpty ? null : () => copyText(lines.join('\n'), what: '已复制 ${lines.length} 行')),
        ]),
      ),
      const Divider(),
      Expanded(
        child: _loading
            ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
            : _error != null
                ? EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _load)
                : lines.isEmpty
                    ? const EmptyHint(icon: Icons.receipt_long_outlined, text: '没有日志')
                    : SelectionArea(
                        child: Scrollbar(
                          controller: _scroll,
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            itemCount: lines.length,
                            itemBuilder: (_, i) => Text(
                              lines[i],
                              softWrap: false,
                              style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 12.5, height: 1.45, color: _levelColor(ide, lines[i])),
                            ),
                          ),
                        ),
                      ),
      ),
    ]);
  }
}
