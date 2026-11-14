// Read-only NVIDIA details. Null values mean unavailable, never zero utilization.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../../theme/ide_theme.dart';
import 'gpu_data.dart';
export 'gpu_data.dart';

double? _number(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
String _value(Object? v, [String unit = '', int digits = 0]) {
  final n = _number(v);
  return n == null ? '—' : '${n.toStringAsFixed(digits)}$unit';
}

String _text(Object? v) => v is String && v.isNotEmpty ? v : '—';
String _memory(Object? v) {
  final n = _number(v);
  if (n == null) return '—';
  return n >= 1024
      ? '${(n / 1024).toStringAsFixed(1)} GiB'
      : '${n.toStringAsFixed(0)} MiB';
}

class GpuPanel extends StatelessWidget {
  final Map<String, dynamic>? data;
  final bool legacy;
  final String? error;
  final Map<String, List<GpuPoint>> history;
  const GpuPanel({
    super.key,
    required this.data,
    required this.legacy,
    required this.history,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context), d = data;
    final cards = (d?['gpus'] as List? ?? const []).cast<Map>();
    final message = error ?? (d?['error'] as String? ?? '');
    final stale = d?['stale'] == true || (error != null && cards.isNotEmpty);
    final ts = _number(d?['ts']);
    final updated = ts == null || ts <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch((ts * 1000).round()).toLocal();
    final clock = updated == null
        ? ''
        : '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}:${updated.second.toString().padLeft(2, '0')}';
    Widget note(String text, {bool warning = false}) => Padding(
      padding: const EdgeInsets.only(bottom: Space.m),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: warning ? ide.warn : ide.textDim),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.m,
          runSpacing: Space.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'GPU',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ide.text,
              ),
            ),
            Text(
              'NVIDIA · ${cards.length} 张显卡',
              style: TextStyle(fontSize: 12, color: ide.textFaint),
            ),
            if (updated != null)
              Text(
                '${stale ? '上次成功' : '更新于'} $clock',
                style: TextStyle(
                  fontSize: 12,
                  color: stale ? ide.warn : ide.textFaint,
                ),
              ),
          ],
        ),
        const SizedBox(height: Space.m),
        if (legacy) note('旧版 agent：仅显示基础 GPU 数据，升级服务器 agent 后可查看详情。'),
        if (message.isNotEmpty)
          note('$message${stale ? ' · 当前显示上次成功数据' : ''}', warning: true),
        if (d == null && error == null) note('正在读取 GPU 状态…'),
        if (d != null && cards.isEmpty && message.isEmpty)
          note(legacy ? '服务器未返回 GPU 数据。' : '未检测到 NVIDIA GPU。'),
        if (!legacy && cards.isNotEmpty)
          note(
            '驱动 ${_text(d?['driver'])} · 驱动支持 CUDA ${_text(d?['cuda'])} · 每 2 秒刷新 · — 表示不可用',
          ),
        for (final g in cards)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.m),
            child: _GpuCard(
              key: ValueKey(gpuIdentity(g)),
              gpu: g,
              legacy: legacy,
              history: history[gpuIdentity(g)] ?? const [],
            ),
          ),
      ],
    );
  }
}

class _GpuCard extends StatelessWidget {
  final Map gpu;
  final bool legacy;
  final List<GpuPoint> history;
  const _GpuCard({
    super.key,
    required this.gpu,
    required this.legacy,
    required this.history,
  });

  @override
  Widget build(BuildContext context) {
    final g = gpu, ide = Ide.of(context);
    final total = _number(g['mem_total']), used = _number(g['mem_used']);
    final mem = total == null || total <= 0 || used == null
        ? null
        : used / total;
    final temp = _number(g['temp']), tempLimit = _number(g['temp_limit']);
    final power = _number(g['power']), powerLimit = _number(g['power_limit']);
    final procs = (g['processes'] as List? ?? const []).cast<Map>();
    return Material(
      color: ide.sideBar,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: ide.border),
        borderRadius: BorderRadius.circular(Radii.island),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.l,
              Space.l,
              Space.l,
              Space.s,
            ),
            child: Wrap(
              spacing: Space.m,
              runSpacing: Space.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.memory_outlined, size: 18, color: ide.accent),
                Text(
                  'GPU ${g['index']} · ${_text(g['name'])}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ide.text,
                  ),
                ),
                if (!legacy)
                  Text(
                    '${_text(g['pstate'])} · ${_text(g['bus_id'])}',
                    style: TextStyle(fontSize: 11.5, color: ide.textFaint),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.l),
            child: LayoutBuilder(
              builder: (context, box) {
                final cols = box.maxWidth >= 760
                    ? 4
                    : (box.maxWidth >= 340 ? 2 : 1);
                final width = (box.maxWidth - Space.m * (cols - 1)) / cols;
                Widget metric(
                  String label,
                  String value,
                  String note,
                  double? fraction,
                  List<double?>? trend,
                ) => SizedBox(
                  width: width,
                  child: _GpuMetric(
                    label: label,
                    value: value,
                    note: note,
                    fraction: fraction,
                    trend: trend,
                  ),
                );
                return Wrap(
                  spacing: Space.m,
                  runSpacing: Space.m,
                  children: [
                    metric(
                      'GPU 利用率',
                      _value(g['util'], ' %', 1),
                      '显存控制器 ${_value(g['mem_util'], ' %')}',
                      _number(g['util']) == null
                          ? null
                          : _number(g['util'])! / 100,
                      history.map((p) => p.util).toList(),
                    ),
                    metric(
                      '显存占用',
                      mem == null ? '—' : '${(mem * 100).toStringAsFixed(1)} %',
                      '${_memory(used)} / ${_memory(total)}',
                      mem,
                      history.map((p) => p.memory).toList(),
                    ),
                    metric(
                      '温度',
                      _value(temp, ' °C'),
                      '风扇 ${_value(g['fan'], ' %')}',
                      temp == null || tempLimit == null || tempLimit <= 0
                          ? null
                          : temp / tempLimit,
                      null,
                    ),
                    metric(
                      '功耗',
                      _value(power, ' W', 1),
                      '上限 ${_value(powerLimit, ' W', 1)}',
                      power == null || powerLimit == null || powerLimit <= 0
                          ? null
                          : power / powerLimit,
                      null,
                    ),
                  ],
                );
              },
            ),
          ),
          if (!legacy)
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey('gpu-details-${gpuIdentity(g)}'),
                // Expanding a data-heavy desktop section should be immediate.
                // Do not lay out every selectable detail while it is collapsed.
                expansionAnimationStyle: AnimationStyle.noAnimation,
                tilePadding: const EdgeInsets.symmetric(horizontal: Space.l),
                childrenPadding: const EdgeInsets.fromLTRB(
                  Space.l,
                  0,
                  Space.l,
                  Space.l,
                ),
                dense: true,
                title: Text(
                  '设备详情与进程${g['processes_available'] == true ? ' · ${procs.length} 个' : ''}',
                  style: TextStyle(fontSize: 12, color: ide.textDim),
                ),
                children: [
                  Builder(builder: (context) => _details(context, procs)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, List<Map> procs) {
    final ide = Ide.of(context), g = gpu;
    final reasons = (g['clock_reasons'] as List? ?? const [])
        .map((r) => _reason('$r'))
        .join('、');
    Widget field(String title, String value) => SizedBox(
      width: 250,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Space.m),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$title  ',
                style: TextStyle(color: ide.textFaint),
              ),
              TextSpan(text: value),
            ],
          ),
          style: TextStyle(fontSize: 12, color: ide.text),
        ),
      ),
    );
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'UUID  ${_text(g['uuid'])}',
            style: TextStyle(fontSize: 11.5, color: ide.textDim),
          ),
          const SizedBox(height: Space.m),
          Wrap(
            spacing: Space.l,
            children: [
              field('架构', _text(g['architecture'])),
              field(
                '图形频率 / 最高',
                '${_value(g['clock_graphics'])} / ${_value(g['clock_graphics_max'], ' MHz')}',
              ),
              field(
                '显存频率 / 最高',
                '${_value(g['clock_memory'])} / ${_value(g['clock_memory_max'], ' MHz')}',
              ),
              field(
                'SM / 视频频率',
                '${_value(g['clock_sm'])} / ${_value(g['clock_video'], ' MHz')}',
              ),
              field(
                'PCIe 当前',
                'Gen ${_value(g['pcie_gen'])} × ${_value(g['pcie_width'])}',
              ),
              field(
                'PCIe 最高',
                'Gen ${_value(g['pcie_gen_max'])} × ${_value(g['pcie_width_max'])}',
              ),
              field(
                '编码 / 解码利用率',
                '${_value(g['encoder_util'], ' %')} / ${_value(g['decoder_util'], ' %')}',
              ),
              field(
                '空闲 / 保留显存',
                '${_memory(g['mem_free'])} / ${_memory(g['mem_reserved'])}',
              ),
              field(
                '显存温度 / 降频阈值',
                '${_value(g['mem_temp'], ' °C')} / ${_value(g['temp_limit'], ' °C')}',
              ),
              field('计算模式', _text(g['compute_mode'])),
              field(
                '持久化 / MIG',
                '${_text(g['persistence'])} / ${_text(g['mig_mode'])}',
              ),
              field(
                '易失 ECC 已纠正 / 未纠正',
                '${_value(g['ecc_corrected'])} / ${_value(g['ecc_uncorrected'])}',
              ),
            ],
          ),
          Text(
            '时钟限制原因  ${g['clock_reasons_available'] != true ? '—' : (reasons.isEmpty ? '无活动限制' : reasons)}',
            style: TextStyle(fontSize: 12, color: ide.textDim),
          ),
          const SizedBox(height: Space.l),
          Text(
            'GPU 进程',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ide.text,
            ),
          ),
          const SizedBox(height: Space.s),
          if (g['processes_available'] != true)
            Text(
              '驱动未提供进程数据。',
              style: TextStyle(fontSize: 12, color: ide.textFaint),
            )
          else if (procs.isEmpty)
            Text(
              '当前没有 GPU 进程。',
              style: TextStyle(fontSize: 12, color: ide.textFaint),
            ),
          if (procs.length <= 6)
            for (final p in procs) _GpuProcess(p)
          else
            SizedBox(
              height: 320,
              child: ListView.builder(
                key: PageStorageKey('gpu-processes-${gpuIdentity(g)}'),
                primary: false,
                itemCount: procs.length,
                itemBuilder: (_, i) => _GpuProcess(procs[i]),
              ),
            ),
        ],
      ),
    );
  }

  static String _processType(Object? type) => switch (type) {
    'C' => '计算',
    'G' => '图形',
    'C+G' => '计算 + 图形',
    _ => _text(type),
  };
  static String _reason(String reason) =>
      const {
        'gpu_idle': '空闲',
        'applications_clocks_setting': '应用频率设置',
        'sw_power_cap': '软件功耗限制',
        'hw_slowdown': '硬件降频',
        'hw_thermal_slowdown': '硬件温度限制',
        'hw_power_brake_slowdown': '硬件功耗限制',
        'sw_thermal_slowdown': '软件温度限制',
        'sync_boost': '同步加速',
        'display_clock_setting': '显示频率设置',
      }[reason] ??
      reason;
}

class _GpuProcess extends StatelessWidget {
  final Map p;
  const _GpuProcess(this.p);
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.l,
            runSpacing: Space.s,
            children: [
              Text(
                'PID ${p['pid']}',
                style: TextStyle(fontSize: 12, color: ide.text),
              ),
              Text(
                '${_GpuCard._processType(p['type'])} · ${_memory(p['mem_used'])}',
                style: TextStyle(fontSize: 12, color: ide.textDim),
              ),
              if (p['gpu_instance_id'] != null)
                Text(
                  'MIG ${_value(p['gpu_instance_id'])} / ${_value(p['compute_instance_id'])}',
                  style: TextStyle(fontSize: 12, color: ide.textFaint),
                ),
            ],
          ),
          Text(
            _text(p['name']),
            style: TextStyle(
              fontSize: 12,
              color: ide.textDim,
              fontFamily: Ide.mono,
              fontFamilyFallback: Ide.monoFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _GpuMetric extends StatelessWidget {
  final String label, value, note;
  final double? fraction;
  final List<double?>? trend;
  const _GpuMetric({
    required this.label,
    required this.value,
    required this.note,
    required this.fraction,
    this.trend,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context), f = (fraction ?? 0).clamp(0.0, 1.0);
    final color = f >= .9 ? ide.warn : ide.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: ide.textFaint)),
        const SizedBox(height: Space.s),
        Text(
          value,
          style: TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.w600,
            color: ide.text,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          note,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: ide.textDim),
        ),
        const SizedBox(height: Space.s),
        if (trend != null && trend!.length > 1)
          Semantics(
            label: '$label，最近 ${trend!.length} 次采样趋势',
            child: SizedBox(
              height: 24,
              width: double.infinity,
              child: CustomPaint(painter: _GpuSpark(trend!, color)),
            ),
          )
        else
          SizedBox(
            height: 24,
            child: Center(
              child: LinearProgressIndicator(
                value: f,
                minHeight: 3,
                color: color,
                backgroundColor: ide.hover,
              ),
            ),
          ),
      ],
    );
  }
}

class _GpuSpark extends CustomPainter {
  final List<double?> values;
  final Color color;
  _GpuSpark(this.values, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    var connected = false;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        connected = false;
        continue;
      }
      final x = size.width * i / (values.length - 1),
          y = size.height * (1 - v.clamp(0, 100) / 100);
      if (connected) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
      }
      connected = true;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _GpuSpark oldDelegate) =>
      color != oldDelegate.color || !listEquals(values, oldDelegate.values);
}
