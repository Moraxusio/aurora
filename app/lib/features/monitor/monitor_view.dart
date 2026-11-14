// The monitor tab (service "monitor"): system/process and GPU polling run
// independently every 2 s while visible. CPU rates come from raw counter deltas;
// old agents fall back to the basic GPU fields in sys.metrics.
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../systemd/systemd_feature.dart' show systemLogTab;
import 'gpu_panel.dart';
import 'monitor_controller.dart';

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
    Command(
      id: 'monitor.open',
      title: '打开监控',
      group: '监控',
      icon: Icons.monitor_heart_outlined,
      run: () => open(ws),
    ),
    Command(
      id: 'monitor.syslog',
      title: '查看系统日志',
      group: '监控',
      icon: Icons.receipt_long_outlined,
      enabled: () => ws.hasOp('log.tail'),
      run: () => ws.openTab(systemLogTab(ws)),
    ),
  ];
}

EditorTab monitorTab(Workspace ws) => EditorTab(
  id: 'monitor',
  title: '监控',
  icon: Icons.monitor_heart_outlined,
  builder: (_) => LinkGate(
    ws: ws,
    builder: (_, link) =>
        MonitorTab(link: link, gpuDetails: ws.hasOp('gpu.info')),
  ),
);

class MonitorTab extends StatefulWidget {
  final Link link;
  final bool gpuDetails;
  const MonitorTab({super.key, required this.link, this.gpuDetails = false});
  @override
  State<MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<MonitorTab> {
  late final _monitor = MonitorController(
    widget.link,
    gpuDetails: widget.gpuDetails,
  );
  final _scroll = ScrollController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _monitor.setVisible(TickerMode.valuesOf(context).enabled);
  }

  @override
  void didUpdateWidget(MonitorTab old) {
    super.didUpdateWidget(old);
    _monitor.bind(widget.link, gpuDetails: widget.gpuDetails);
  }

  @override
  void dispose() {
    _monitor.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const PageStorageKey('monitor-scroll'),
    controller: _scroll,
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          Space.xxl,
          Space.xl + 4,
          Space.xxl,
          Space.xxl,
        ),
        sliver: SliverMainAxisGroup(
          slivers: [
            ValueListenableBuilder<SystemReading>(
              valueListenable: _monitor.system,
              builder: (_, reading, _) =>
                  SliverToBoxAdapter(child: _SystemSummary(reading)),
            ),
            ValueListenableBuilder<GpuReading>(
              valueListenable: _monitor.gpu,
              builder: (_, reading, _) => SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.xxl),
                  child: GpuPanel(
                    data: reading.data,
                    legacy: reading.legacy,
                    history: reading.history,
                    error: reading.error,
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<SystemReading>(
              valueListenable: _monitor.system,
              builder: (_, reading, _) => _SystemDetails(reading),
            ),
          ],
        ),
      ),
    ],
  );

  static String _gb(double b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }
}

class _SystemSummary extends StatelessWidget {
  final SystemReading reading;
  const _SystemSummary(this.reading);
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final error = reading.error, cpu = reading.cpu;
    if (error != null && reading.data == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(error, style: TextStyle(color: ide.error)),
      );
    }
    final m = reading.data;
    if (m == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final mem = (m['memory'] as Map).cast<String, dynamic>();
    final total = (mem['MemTotal'] as num? ?? 0).toDouble(),
        avail = (mem['MemAvailable'] as num? ?? 0).toDouble();
    final swapT = (mem['SwapTotal'] as num? ?? 0).toDouble(),
        swapF = (mem['SwapFree'] as num? ?? 0).toDouble();
    final windows = m['platform'] == 'windows';
    final commit = (mem['CommitTotal'] as num? ?? 0).toDouble(),
        commitLimit = (mem['CommitLimit'] as num? ?? 0).toDouble();
    final load = [for (final x in m['load'] as List) (x as num).toDouble()];
    final cores = (m['cpu_count'] as num? ?? 1).toInt().clamp(1, 1 << 12);
    final memUsed = total == 0 ? null : (total - avail) / total;
    Widget chip(IconData i, String s) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ide.hover,
        borderRadius: BorderRadius.circular(Radii.s),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(i, size: 13, color: ide.textFaint),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              s,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: ide.textDim),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.m),
            child: Text('$error · 当前显示上次数据', style: TextStyle(color: ide.warn)),
          ),
        Text('${m['host']}', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: Space.m),
        Wrap(
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            chip(Icons.dns_outlined, '${m['os']}'),
            chip(Icons.memory_rounded, '${m['cpu_model']} × $cores'),
            chip(Icons.layers_outlined, '内核 ${m['kernel']}'),
            chip(
              Icons.schedule_rounded,
              '已运行 ${_dur((m['uptime'] as num).toDouble())}',
            ),
          ],
        ),
        const SizedBox(height: Space.xl + 4),
        LayoutBuilder(
          builder: (context, box) {
            final cols = box.maxWidth >= 1000
                ? 4
                : (box.maxWidth >= 520 ? 2 : 1);
            final w = (box.maxWidth - Space.l * (cols - 1)) / cols;
            return Wrap(
              spacing: Space.l,
              runSpacing: Space.l,
              children: [
                SizedBox(
                  width: w,
                  child: _Metric(
                    label: 'CPU',
                    value: cpu == null ? '…' : cpu.toStringAsFixed(1),
                    unit: '%',
                    note: '$cores 个核心合计',
                    fraction: cpu == null ? null : cpu / 100,
                    history: reading.cpuHistory,
                  ),
                ),
                SizedBox(
                  width: w,
                  child: _Metric(
                    label: '内存',
                    value: memUsed == null
                        ? '—'
                        : (memUsed * 100).toStringAsFixed(0),
                    unit: '%',
                    note: '${_gb(total - avail)} / ${_gb(total)}',
                    fraction: memUsed,
                    history: reading.memoryHistory,
                  ),
                ),
                SizedBox(
                  width: w,
                  child: _Metric(
                    label: '负载',
                    value: load.isEmpty ? '—' : load.first.toStringAsFixed(2),
                    unit: '',
                    note: m['load_supported'] == false
                        ? 'Windows 不提供 Unix 负载'
                        : load.length < 3
                        ? ''
                        : '5 分钟 ${load[1].toStringAsFixed(2)} · 15 分钟 ${load[2].toStringAsFixed(2)}',
                    fraction: load.isEmpty ? null : load.first / cores,
                  ),
                ),
                SizedBox(
                  width: w,
                  child: _Metric(
                    label: windows ? '提交内存' : '交换',
                    value: windows
                        ? (commitLimit <= 0
                              ? '—'
                              : (commit / commitLimit * 100).toStringAsFixed(0))
                        : swapT <= 0
                        ? '—'
                        : ((swapT - swapF) / swapT * 100).toStringAsFixed(0),
                    unit: (windows ? commitLimit : swapT) <= 0 ? '' : '%',
                    note: windows
                        ? '${_gb(commit)} / ${_gb(commitLimit)}'
                        : swapT <= 0
                        ? '没有交换空间'
                        : '${_gb(swapT - swapF)} / ${_gb(swapT)}',
                    fraction: windows
                        ? (commitLimit <= 0 ? null : commit / commitLimit)
                        : swapT <= 0
                        ? null
                        : (swapT - swapF) / swapT,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  static String _gb(double b) => _MonitorTabState._gb(b);
  static String _dur(double s) {
    final d = s ~/ 86400, h = (s % 86400) ~/ 3600, m = (s % 3600) ~/ 60;
    return d > 0 ? '$d 天 $h 小时' : (h > 0 ? '$h 小时 $m 分' : '$m 分');
  }
}

class _SystemDetails extends StatelessWidget {
  final SystemReading reading;
  const _SystemDetails(this.reading);
  @override
  Widget build(BuildContext context) {
    final m = reading.data;
    if (m == null) return const SliverToBoxAdapter(child: SizedBox());
    final disks = (m['disks'] as List)
        .cast<Map>()
        .where((d) => d['ro'] != true)
        .toList();
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading(context, '磁盘', '${disks.length} 个挂载点'),
              _Panel(
                children: [
                  for (final (i, d) in disks.indexed)
                    _DiskRow(
                      mount: '${d['mount']}',
                      fs: '${d['fstype']}',
                      used: (d['used'] as num).toDouble(),
                      total: (d['total'] as num).toDouble(),
                      last: i == disks.length - 1,
                    ),
                ],
              ),
              const SizedBox(height: Space.xxl),
              _heading(context, '进程', '按 CPU 排序 · 100 % 为一个核'),
              _ProcRow.header(),
            ],
          ),
        ),
        SliverList.builder(
          itemCount: reading.processes.length,
          itemBuilder: (_, i) => _ProcRow(
            reading.processes[i],
            last: i == reading.processes.length - 1,
          ),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context, String title, String note) {
    final ide = Ide.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.m + 2, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: ide.text,
            ),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: Text(
              note,
              style: TextStyle(fontSize: 12, color: ide.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}

/// The colour of a load: calm, getting full, full.
Color _level(Ide ide, double f) =>
    f >= 0.9 ? ide.error : (f >= 0.7 ? ide.warn : ide.accent);

/// A rounded panel with rows separated by thin lines.
class _Panel extends StatelessWidget {
  final List<Widget> children;
  const _Panel({required this.children});
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ide.sideBar,
        borderRadius: BorderRadius.circular(Radii.island),
        border: Border.all(color: ide.border),
      ),
      child: Column(children: children),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label, value, unit, note;
  final double? fraction;
  final List<double>? history;
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    required this.note,
    required this.fraction,
    this.history,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final f = (fraction ?? 0).clamp(0.0, 1.0);
    final color = _level(ide, f);
    final h = history;
    return Container(
      height: 132,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ide.sideBar,
        borderRadius: BorderRadius.circular(Radii.island),
        border: Border.all(color: ide.border),
      ),
      child: Stack(
        children: [
          if (h != null && h.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 56,
              child: CustomPaint(painter: _Spark(h, color)),
            ),
          Padding(
            padding: const EdgeInsets.all(Space.l + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ide.textDim,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: Space.s),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: ide.text,
                        height: 1.1,
                        letterSpacing: -0.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (unit.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 3),
                        child: Text(
                          unit,
                          style: TextStyle(fontSize: 14, color: ide.textDim),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: ide.textFaint),
                ),
                const Spacer(),
                if (h == null || h.length < 2)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: fraction == null ? 0 : f,
                      minHeight: 5,
                      color: color,
                      backgroundColor: ide.hover,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiskRow extends StatelessWidget {
  final String mount, fs;
  final double used, total;
  final bool last;
  const _DiskRow({
    required this.mount,
    required this.fs,
    required this.used,
    required this.total,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final f = total == 0 ? 0.0 : (used / total).clamp(0.0, 1.0);
    final caption =
        '${_MonitorTabState._gb(used)} / ${_MonitorTabState._gb(total)}';
    final title = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: mount,
            style: TextStyle(color: ide.text, fontSize: 13),
          ),
          TextSpan(
            text: '  $fs',
            style: TextStyle(color: ide.textFaint, fontSize: 11.5),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final bar = LinearProgressIndicator(
      value: f,
      minHeight: 5,
      color: _level(ide, f),
      backgroundColor: ide.hover,
    );
    return LayoutBuilder(
      builder: (_, box) {
        if (box.maxWidth < 600) {
          return Container(
            padding: const EdgeInsets.all(Space.l),
            decoration: BoxDecoration(
              border: last
                  ? null
                  : Border(bottom: BorderSide(color: ide.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: Space.s),
                Text(
                  '$caption · ${(f * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: ide.textDim),
                ),
                const SizedBox(height: Space.s),
                bar,
              ],
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.l + 2,
            vertical: Space.m + 2,
          ),
          decoration: BoxDecoration(
            border: last ? null : Border(bottom: BorderSide(color: ide.border)),
          ),
          child: Row(
            children: [
              Icon(Icons.storage_rounded, size: 16, color: ide.textFaint),
              const SizedBox(width: Space.m + 2),
              SizedBox(width: 200, child: title),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: bar,
                ),
              ),
              const SizedBox(width: Space.l),
              SizedBox(
                width: 150,
                child: Text(
                  caption,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    color: ide.textDim,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${(f * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: f >= 0.9 ? ide.error : ide.text,
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
    final mono = style.copyWith(
      fontFamily: Ide.mono,
      fontFamilyFallback: Ide.monoFallback,
      fontSize: 12,
      color: ide.textDim,
    );
    final cpu = head ? 0.0 : (p['cpu'] as num?)?.toDouble() ?? 0;
    final memory = head
        ? '内存'
        : p['rss'] == null
        ? '—'
        : _MonitorTabState._gb((p['rss'] as num).toDouble());
    final cpuText = head
        ? 'CPU %'
        : p['cpu'] == null
        ? '—'
        : cpu.toStringAsFixed(1);
    final command = Text(
      head ? '命令' : '${p['args']}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: head ? style : mono,
    );
    Widget cell(String s, double w) => SizedBox(
      width: w,
      child: Text(
        s,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: style,
      ),
    );
    return LayoutBuilder(
      builder: (_, box) => Container(
        height: box.maxWidth < 420 ? (head ? 32 : 54) : (head ? 32 : 30),
        padding: const EdgeInsets.symmetric(horizontal: Space.l + 2),
        decoration: BoxDecoration(
          color: head ? ide.hover.withValues(alpha: 0.5) : ide.sideBar,
          border: last
              ? null
              : Border(
                  bottom: BorderSide(
                    color: ide.border.withValues(alpha: head ? 1 : 0.6),
                  ),
                ),
        ),
        child: box.maxWidth < 420
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    head
                        ? 'PID / CPU / 内存 / 命令'
                        : '${p['pid']} · $cpuText % · $memory',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                  if (!head) command,
                ],
              )
            : Row(
                children: [
                  cell(head ? 'PID' : '${p['pid']}', 56),
                  const SizedBox(width: Space.m),
                  if (box.maxWidth >= 700)
                    SizedBox(
                      width: 90,
                      child: Text(
                        head ? '用户' : '${p['user']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style.copyWith(color: head ? null : ide.textDim),
                      ),
                    ),
                  SizedBox(
                    width: 80,
                    child: head
                        ? Text(
                            'CPU %',
                            textAlign: TextAlign.right,
                            style: style,
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: FractionallySizedBox(
                                    widthFactor: (cpu / 100).clamp(0.02, 1.0),
                                    child: Container(
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: _level(
                                          ide,
                                          cpu / 100,
                                        ).withValues(alpha: 0.7),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: Space.s),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  cpuText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: style,
                                ),
                              ),
                            ],
                          ),
                  ),
                  cell(memory, 80),
                  const SizedBox(width: Space.m),
                  Expanded(child: command),
                ],
              ),
      ),
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
      final x = s.width * i / (v.length - 1),
          y = s.height * (1 - 0.9 * v[i].clamp(0, 100) / 100);
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
        ).createShader(Offset.zero & s),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = c
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_Spark o) => c != o.c || !listEquals(v, o.v);
}
