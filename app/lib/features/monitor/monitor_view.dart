// The monitor tab (service "monitor"): CPU, memory, load, disks and the top
// processes, from sys.metrics and proc.list every 2 s. sys.metrics returns raw counters; the
// CPU percentage comes from the difference between two samples.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../systemd/systemd_feature.dart' show systemLogTab;

class MonitorFeature extends Feature {
  const MonitorFeature();

  @override
  String get id => 'monitor';
  @override
  String get title => '监控';
  @override
  IconData get icon => Icons.monitor_heart_outlined;
  @override
  String get service => 'monitor';
  @override
  List<String> get ops => const ['sys.metrics', 'proc.list'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => null;

  @override
  void open(Workspace ws) => ws.openTab(monitorTab(ws));

  @override
  List<Command> commands(Workspace ws) => [
        Command(id: 'monitor.open', title: '打开监控', group: '监控', icon: Icons.monitor_heart_outlined, run: () => open(ws)),
        Command(id: 'monitor.syslog', title: '查看系统日志', group: '监控', icon: Icons.receipt_long_outlined, enabled: () => ws.hasOp('log.tail'), run: () => ws.openTab(systemLogTab(ws))),
      ];
}

EditorTab monitorTab(Workspace ws) => EditorTab(id: 'monitor', title: '监控', icon: Icons.monitor_heart_outlined, builder: (_) => LinkGate(ws: ws, builder: (_, link) => MonitorTab(link: link)));

class MonitorTab extends StatefulWidget {
  final Link link;
  const MonitorTab({super.key, required this.link});
  @override
  State<MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<MonitorTab> {
  Timer? _timer;
  Map<String, dynamic>? _m;
  List<int>? _prevCpu;
  double? _cpu;
  final List<double> _history = [];
  final List<double> _memHistory = [];
  List<Map<String, dynamic>> _procs = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (widget.link.isClosed) return;
    try {
      final m = (await widget.link.call('sys.metrics') as Map).cast<String, dynamic>();
      final p = await widget.link.call('proc.list', {'limit': 30}) as Map;
      final cpu = [for (final x in m['cpu'] as List) (x as num).toInt()];
      if (_prevCpu != null && _prevCpu!.length == cpu.length && cpu.length >= 4) {
        final busy = _busy(cpu) - _busy(_prevCpu!);
        final all = cpu.fold<int>(0, (a, b) => a + b) - _prevCpu!.fold<int>(0, (a, b) => a + b);
        _cpu = all <= 0 ? 0 : 100 * busy / all;
        _history.add(_cpu!);
        if (_history.length > 60) _history.removeAt(0);
      }
      _prevCpu = cpu;
      final mem = (m['memory'] as Map?)?.cast<String, dynamic>() ?? const {};
      final total = (mem['MemTotal'] as num? ?? 0).toDouble(), avail = (mem['MemAvailable'] as num? ?? 0).toDouble();
      if (total > 0) {
        _memHistory.add(100 * (total - avail) / total);
        if (_memHistory.length > 60) _memHistory.removeAt(0);
      }
      if (!mounted) return;
      setState(() {
        _m = m;
        _procs = [for (final x in p['processes'] as List) (x as Map).cast<String, dynamic>()];
        _error = null;
      });
    } on OpError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// /proc/stat fields: user nice system idle iowait irq softirq steal.
  static int _busy(List<int> c) => c.fold<int>(0, (a, b) => a + b) - c[3] - (c.length > 4 ? c[4] : 0);

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline_rounded, text: _error!);
    final m = _m;
    if (m == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    final mem = (m['memory'] as Map).cast<String, dynamic>();
    final total = (mem['MemTotal'] as num? ?? 0).toDouble(), avail = (mem['MemAvailable'] as num? ?? 0).toDouble();
    final swapT = (mem['SwapTotal'] as num? ?? 0).toDouble(), swapF = (mem['SwapFree'] as num? ?? 0).toDouble();
    final load = [for (final x in m['load'] as List) (x as num).toDouble()];
    final cores = (m['cpu_count'] as num? ?? 1).toInt().clamp(1, 1 << 12);
    final memUsed = total == 0 ? null : (total - avail) / total;
    // Read-only images (WSL's kernel headers, snaps) are full by design and
    // cannot fill up, so they are left out.
    final disks = (m['disks'] as List).cast<Map>().where((d) => d['ro'] != true).toList();
    Widget chip(IconData i, String s) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: ide.hover, borderRadius: BorderRadius.circular(Radii.s)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(i, size: 13, color: ide.textFaint),
            const SizedBox(width: 5),
            Text(s, style: TextStyle(fontSize: 11.5, color: ide.textDim)),
          ]),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl + 4, Space.xxl, Space.xxl), children: [
      Text('${m['host']}', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: Space.m),
      Wrap(spacing: Space.s, runSpacing: Space.s, children: [
        chip(Icons.dns_outlined, '${m['os']}'),
        chip(Icons.memory_rounded, '${m['cpu_model']} × $cores'),
        chip(Icons.layers_outlined, '内核 ${m['kernel']}'),
        chip(Icons.schedule_rounded, '已运行 ${_dur((m['uptime'] as num).toDouble())}'),
      ]),
      const SizedBox(height: Space.xl + 4),
      LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 1000 ? 4 : (box.maxWidth >= 520 ? 2 : 1);
        final w = (box.maxWidth - Space.l * (cols - 1)) / cols;
        return Wrap(spacing: Space.l, runSpacing: Space.l, children: [
          SizedBox(width: w, child: _Metric(
            label: 'CPU',
            value: _cpu == null ? '…' : _cpu!.toStringAsFixed(1),
            unit: '%',
            note: '$cores 个核心合计',
            fraction: _cpu == null ? null : _cpu! / 100,
            history: _history,
          )),
          SizedBox(width: w, child: _Metric(
            label: '内存',
            value: memUsed == null ? '—' : (memUsed * 100).toStringAsFixed(0),
            unit: '%',
            note: '${_gb(total - avail)} / ${_gb(total)}',
            fraction: memUsed,
            history: _memHistory,
          )),
          SizedBox(width: w, child: _Metric(
            label: '负载',
            value: load.isEmpty ? '—' : load.first.toStringAsFixed(2),
            unit: '',
            note: load.length < 3 ? '' : '5 分钟 ${load[1].toStringAsFixed(2)} · 15 分钟 ${load[2].toStringAsFixed(2)}',
            fraction: load.isEmpty ? null : load.first / cores,
          )),
          SizedBox(width: w, child: _Metric(
            label: '交换',
            value: swapT <= 0 ? '—' : ((swapT - swapF) / swapT * 100).toStringAsFixed(0),
            unit: swapT <= 0 ? '' : '%',
            note: swapT <= 0 ? '没有交换空间' : '${_gb(swapT - swapF)} / ${_gb(swapT)}',
            fraction: swapT <= 0 ? null : (swapT - swapF) / swapT,
          )),
        ]);
      }),
      const SizedBox(height: Space.xxl),
      _heading('磁盘', '${disks.length} 个挂载点'),
      _Panel(children: [
        for (final (i, d) in disks.indexed)
          _DiskRow(
            mount: '${d['mount']}',
            fs: '${d['fstype']}',
            used: (d['used'] as num).toDouble(),
            total: (d['total'] as num).toDouble(),
            last: i == disks.length - 1,
          ),
      ]),
      const SizedBox(height: Space.xxl),
      _heading('进程', '按 CPU 排序 · 100 % 为一个核'),
      _Panel(children: [
        _ProcRow.header(),
        for (final (i, p) in _procs.indexed) _ProcRow(p, last: i == _procs.length - 1),
      ]),
    ]);
  }

  Widget _heading(String title, String note) {
    final ide = Ide.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.m + 2, left: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ide.text)),
        const SizedBox(width: Space.m),
        Text(note, style: TextStyle(fontSize: 12, color: ide.textFaint)),
      ]),
    );
  }

  static String _gb(double b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  static String _dur(double s) {
    final d = s ~/ 86400, h = (s % 86400) ~/ 3600, m = (s % 3600) ~/ 60;
    return d > 0 ? '$d 天 $h 小时' : (h > 0 ? '$h 小时 $m 分' : '$m 分');
  }
}

/// The colour of a load: calm, getting full, full.
Color _level(Ide ide, double f) => f >= 0.9 ? ide.error : (f >= 0.7 ? ide.warn : ide.accent);

/// A rounded panel with rows separated by thin lines.
class _Panel extends StatelessWidget {
  final List<Widget> children;
  const _Panel({required this.children});
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: ide.sideBar, borderRadius: BorderRadius.circular(Radii.island), border: Border.all(color: ide.border)),
      child: Column(children: children),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label, value, unit, note;
  final double? fraction;
  final List<double>? history;
  const _Metric({required this.label, required this.value, required this.unit, required this.note, required this.fraction, this.history});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final f = (fraction ?? 0).clamp(0.0, 1.0);
    final color = _level(ide, f);
    final h = history;
    return Container(
      height: 132,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: ide.sideBar, borderRadius: BorderRadius.circular(Radii.island), border: Border.all(color: ide.border)),
      child: Stack(children: [
        if (h != null && h.length > 1)
          Positioned(left: 0, right: 0, bottom: 0, height: 56, child: CustomPaint(painter: _Spark(h, color))),
        Padding(
          padding: const EdgeInsets.all(Space.l + 2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.textDim, letterSpacing: 0.2)),
            const SizedBox(height: Space.s),
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: ide.text, height: 1.1, letterSpacing: -0.5,
                fontFeatures: const [FontFeature.tabularFigures()])),
              if (unit.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 3), child: Text(unit, style: TextStyle(fontSize: 14, color: ide.textDim))),
            ]),
            const SizedBox(height: 2),
            Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ide.textFaint)),
            const Spacer(),
            if (h == null || h.length < 2)
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: fraction == null ? 0 : f, minHeight: 5, color: color, backgroundColor: ide.hover),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _DiskRow extends StatelessWidget {
  final String mount, fs;
  final double used, total;
  final bool last;
  const _DiskRow({required this.mount, required this.fs, required this.used, required this.total, required this.last});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final f = total == 0 ? 0.0 : (used / total).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.l + 2, vertical: Space.m + 2),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: ide.border))),
      child: Row(children: [
        Icon(Icons.storage_rounded, size: 16, color: ide.textFaint),
        const SizedBox(width: Space.m + 2),
        SizedBox(
          width: 200,
          child: Text.rich(TextSpan(children: [
            TextSpan(text: mount, style: TextStyle(color: ide.text, fontSize: 13)),
            TextSpan(text: '  $fs', style: TextStyle(color: ide.textFaint, fontSize: 11.5)),
          ]), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: f, minHeight: 5, color: _level(ide, f), backgroundColor: ide.hover),
          ),
        ),
        const SizedBox(width: Space.l),
        SizedBox(
          width: 150,
          child: Text('${_MonitorTabState._gb(used)} / ${_MonitorTabState._gb(total)}', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: ide.textDim, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
        SizedBox(
          width: 44,
          child: Text('${(f * 100).toStringAsFixed(0)}%', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: f >= 0.9 ? ide.error : ide.text)),
        ),
      ]),
    );
  }
}

class _ProcRow extends StatelessWidget {
  final Map<String, dynamic>? p;
  final bool last;
  const _ProcRow(this.p, {this.last = false});
  const _ProcRow.header() : p = null, last = false;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final p = this.p;
    final head = p == null;
    final style = TextStyle(
      fontSize: head ? 11.5 : 12.5,
      color: head ? ide.textFaint : ide.text,
      fontWeight: head ? FontWeight.w600 : FontWeight.w400,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final mono = style.copyWith(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 12, color: ide.textDim);
    final cpu = head ? 0.0 : (p['cpu'] as num).toDouble();
    Widget cell(String s, double w) => SizedBox(width: w, child: Text(s, textAlign: TextAlign.right, style: style));
    return Container(
      height: head ? 32 : 30,
      padding: const EdgeInsets.symmetric(horizontal: Space.l + 2),
      decoration: BoxDecoration(
        color: head ? ide.hover.withValues(alpha: 0.5) : null,
        border: last ? null : Border(bottom: BorderSide(color: ide.border.withValues(alpha: head ? 1 : 0.6))),
      ),
      child: Row(children: [
        cell(head ? 'PID' : '${p['pid']}', 64),
        const SizedBox(width: Space.xl),
        SizedBox(width: 90, child: Text(head ? '用户' : '${p['user']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: style.copyWith(color: head ? null : ide.textDim))),
        SizedBox(
          width: 110,
          child: head
              ? Text('CPU %', textAlign: TextAlign.right, style: style)
              : Row(children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FractionallySizedBox(
                        widthFactor: (cpu / 100).clamp(0.02, 1.0),
                        child: Container(height: 4, decoration: BoxDecoration(color: _level(ide, cpu / 100).withValues(alpha: 0.7), borderRadius: BorderRadius.circular(2))),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  SizedBox(width: 40, child: Text(cpu.toStringAsFixed(1), textAlign: TextAlign.right, style: style)),
                ]),
        ),
        cell(head ? '内存' : _MonitorTabState._gb((p['rss'] as num).toDouble()), 84),
        const SizedBox(width: Space.xl + 4),
        Expanded(child: Text(head ? '命令' : '${p['args']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: head ? style : mono)),
      ]),
    );
  }
}

class _Spark extends CustomPainter {
  final List<double> v;
  final Color c;
  _Spark(this.v, this.c);
  @override
  void paint(Canvas canvas, Size s) {
    final line = Path(), fill = Path()..moveTo(0, s.height);
    for (var i = 0; i < v.length; i++) {
      // the top 10 % stays free so a full load does not touch the text
      final x = s.width * i / (v.length - 1), y = s.height * (1 - 0.9 * v[i].clamp(0, 100) / 100);
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
      fill.lineTo(x, y);
    }
    fill
      ..lineTo(s.width, s.height)
      ..close();
    canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [c.withValues(alpha: 0.22), c.withValues(alpha: 0.02)],
          ).createShader(Offset.zero & s));
    canvas.drawPath(
        line,
        Paint()
          ..color = c
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_Spark o) => true;
}
