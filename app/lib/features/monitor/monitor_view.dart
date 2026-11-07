// The monitor tab (service "monitor"): CPU, memory, load, disks and the top
// processes, from sys.metrics and proc.list every 2 s. sys.metrics returns raw counters; the
// CPU percentage comes from the difference between two samples.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
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
    if (_error != null) return Center(child: Text(_error!));
    final m = _m;
    if (m == null) return const Center(child: CircularProgressIndicator());
    final mem = (m['memory'] as Map).cast<String, dynamic>();
    final total = (mem['MemTotal'] as num? ?? 0).toDouble(), avail = (mem['MemAvailable'] as num? ?? 0).toDouble();
    final swapT = (mem['SwapTotal'] as num? ?? 0).toDouble(), swapF = (mem['SwapFree'] as num? ?? 0).toDouble();
    final load = [for (final x in m['load'] as List) (x as num).toDouble()];
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('${m['host']} · ${m['os']} · 内核 ${m['kernel']} · 已运行 ${_dur((m['uptime'] as num).toDouble())}', style: t.bodySmall),
      Text('${m['cpu_model']} × ${m['cpu_count']}', style: t.bodySmall),
      const SizedBox(height: 12),
      Wrap(spacing: 16, runSpacing: 16, children: [
        _gauge('CPU', _cpu == null ? null : _cpu! / 100, _cpu == null ? '…' : '${_cpu!.toStringAsFixed(1)} %'),
        _gauge('内存', total == 0 ? null : (total - avail) / total, '${_gb(total - avail)} / ${_gb(total)}'),
        if (swapT > 0) _gauge('交换', (swapT - swapF) / swapT, '${_gb(swapT - swapF)} / ${_gb(swapT)}'),
        _card('负载', '${load.map((x) => x.toStringAsFixed(2)).join('  ')}\n1 / 5 / 15 分钟'),
      ]),
      if (_history.length > 1) ...[
        const SizedBox(height: 16),
        Text('CPU，最近 ${_history.length * 2} 秒（0–100 %）', style: t.labelLarge),
        const SizedBox(height: 4),
        Container(
          height: 64,
          decoration: BoxDecoration(color: Ide.of(context).panel, border: Border.all(color: Ide.of(context).border), borderRadius: BorderRadius.circular(4)),
          padding: const EdgeInsets.all(4),
          child: CustomPaint(painter: _Spark(_history, Theme.of(context).colorScheme.primary), size: Size.infinite),
        ),
      ],
      const SizedBox(height: 16),
      Text('磁盘', style: t.titleMedium),
      // Read-only images (WSL's kernel headers, snaps) are full by design and
      // cannot fill up, so they are left out.
      for (final d in (m['disks'] as List).cast<Map>().where((d) => d['ro'] != true))
        ListTile(
          dense: true,
          title: Text('${d['mount']}  (${d['fstype']})'),
          subtitle: LinearProgressIndicator(value: (d['total'] as num) == 0 ? 0 : (d['used'] as num) / (d['total'] as num)),
          trailing: Text('${_gb((d['used'] as num).toDouble())} / ${_gb((d['total'] as num).toDouble())}'),
        ),
      const SizedBox(height: 16),
      Text('进程（按 CPU 排序）', style: t.titleMedium),
      DataTable(columnSpacing: 16, headingRowHeight: 30, dataRowMinHeight: 26, dataRowMaxHeight: 28, dividerThickness: 0.5, columns: const [
        DataColumn(label: Text('PID'), numeric: true),
        DataColumn(label: Text('用户')),
        // Per process, 100 % is one core; the CPU card is all cores together.
        DataColumn(label: Tooltip(message: '100 % 为一个核；上面的 CPU 卡片是全部核心合计', child: Text('CPU %（单核）')), numeric: true),
        DataColumn(label: Text('内存'), numeric: true),
        DataColumn(label: Text('命令')),
      ], rows: [
        for (final p in _procs)
          DataRow(cells: [
            DataCell(Text('${p['pid']}')),
            DataCell(Text('${p['user']}')),
            DataCell(Text((p['cpu'] as num).toStringAsFixed(1))),
            DataCell(Text(_gb((p['rss'] as num).toDouble()))),
            DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: Text('${p['args']}', overflow: TextOverflow.ellipsis))),
          ]),
      ]),
    ]);
  }

  Widget _gauge(String label, double? v, String text) => SizedBox(
        width: 200,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: v, minHeight: 8),
              const SizedBox(height: 8),
              Text(text),
            ]),
          ),
        ),
      );

  Widget _card(String label, String text) => SizedBox(
        width: 200,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(text),
            ]),
          ),
        ),
      );

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

class _Spark extends CustomPainter {
  final List<double> v;
  final Color c;
  _Spark(this.v, this.c);
  @override
  void paint(Canvas canvas, Size s) {
    // A dashed 50 % line, so an idle (flat, near zero) curve still reads as
    // a measurement and not as the frame.
    final guide = Paint()
      ..color = c.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var x = 0.0; x < s.width; x += 8) {
      canvas.drawLine(Offset(x, s.height / 2), Offset(x + 4, s.height / 2), guide);
    }
    final line = Path(), fill = Path()..moveTo(0, s.height);
    for (var i = 0; i < v.length; i++) {
      final x = s.width * i / (v.length - 1), y = s.height * (1 - v[i].clamp(0, 100) / 100);
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
      fill.lineTo(x, y);
    }
    fill
      ..lineTo(s.width, s.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = c.withValues(alpha: 0.15));
    canvas.drawPath(
        line,
        Paint()
          ..color = c
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_Spark o) => true;
}
