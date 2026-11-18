import 'dart:convert';

import 'package:aurora/ui/aurora_ui.dart';
import 'package:aurora_wire/aurora_wire.dart';

import '../../theme/ide_theme.dart';
import 'ai_visuals.dart';

/// A composer draft. Run overrides are consumed only by a successful send.
class AiSendSettings {
  final String agent, permission, delivery;
  final Map<String, dynamic> options;
  const AiSendSettings({
    required this.agent,
    required this.permission,
    required this.delivery,
    this.options = const {},
  });
}

Future<AiSendSettings?> showAiRunOptions(
  BuildContext context, {
  required Link link,
  required String root,
  required String workdir,
  required AiSendSettings initial,
  required bool running,
  bool child = false,
}) => showWorkbenchDialog<AiSendSettings>(
  context: context,
  builder: (_) => _RunOptions(
    link: link,
    root: root,
    workdir: workdir,
    initial: initial,
    running: running,
    child: child,
  ),
);

class _RunOptions extends StatefulWidget {
  final Link link;
  final String root, workdir;
  final AiSendSettings initial;
  final bool running, child;
  const _RunOptions({
    required this.link,
    required this.root,
    required this.workdir,
    required this.initial,
    required this.running,
    required this.child,
  });
  @override
  State<_RunOptions> createState() => _RunOptionsState();
}

class _RunOptionsState extends State<_RunOptions> {
  final _form = GlobalKey<FormState>();
  late String _agent = widget.initial.agent;
  late String _permission = widget.initial.permission;
  late String _delivery = widget.initial.delivery;
  late Map<String, dynamic> _options = (jsonDecode(
    jsonEncode(widget.initial.options),
  ) as Map).cast<String, dynamic>();
  Map<String, dynamic>? _defaults;
  String? _error;
  bool _loading = false;
  int _epoch = 0;
  bool get _supported => widget.link.server.caps.contains('ai.run.options');
  bool get _steering => widget.running && _delivery == 'steer';
  bool get _editable => _supported && !_steering && _defaults != null;
  String get _budgetMode => _options['budgetMode'] as String? ?? 'inherit';

  @override
  void initState() {
    super.initState();
    if (_supported) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.link.call('ai.run.options', {
        'root': widget.root,
        'workdir': widget.workdir,
      });
      if (mounted)
        setState(() => _defaults = (data as Map).cast<String, dynamic>());
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _choice(
    String key,
    String label,
    String value,
    Map<String, String> choices,
    ValueChanged<String>? changed, {
    String? help,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<String>(
      key: ValueKey('ai-send-$key-$_epoch'),
      initialValue: value,
      isExpanded: true,
      style: TextStyle(
        fontFamily: Ide.ui,
        fontFamilyFallback: Ide.uiFallback,
        fontSize: 13,
        fontWeight: FontWeight.normal,
        color: Ide.of(context).text,
      ),
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 3,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        labelStyle: TextStyle(fontSize: 12, color: Ide.of(context).textDim),
        floatingLabelStyle: TextStyle(
          fontSize: 12,
          color: Ide.of(context).textDim,
        ),
      ),
      items: [
        for (final e in choices.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: changed == null
          ? null
          : (v) {
              if (v != null) setState(() => changed(v));
            },
    ),
  );

  Widget _toggle(String key, String label, bool defaultValue, {String? help}) =>
      _choice(
        key,
        label,
        _options[key] == null ? 'inherit' : '${_options[key]}',
        {
          'inherit': '使用项目设置 · ${defaultValue ? '开启' : '关闭'}',
          'true': '本次开启',
          'false': '本次关闭',
        },
        _editable
            ? (v) {
                if (v == 'inherit') {
                  _options.remove(key);
                } else {
                  _options[key] = v == 'true';
                }
              }
            : null,
        help: help,
      );

  Widget _limit(String key, String label, num max, {bool decimal = false}) {
    final limits = _options['budget'] as Map;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        key: ValueKey('ai-send-limit-$key-$_epoch'),
        enabled: _editable,
        initialValue: '${limits[key] ?? 0}',
        decoration: InputDecoration(labelText: label, helperText: '0 表示不限'),
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        validator: (v) {
          if (!_editable || _budgetMode != 'custom') return null;
          final n = decimal ? double.tryParse(v ?? '') : int.tryParse(v ?? '');
          return n == null || !n.isFinite || n < 0 || n > max
              ? '请输入 0–$max 的${decimal ? '数值' : '整数'}'
              : null;
        },
        onChanged: (v) =>
            limits[key] = (decimal ? double.tryParse(v) : int.tryParse(v)) ?? v,
      ),
    );
  }

  void _apply() {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_options['budgetMode'] != 'custom') _options.remove('budget');
    if (_options['budgetMode'] == 'inherit') _options.remove('budgetMode');
    if (_options['maxParallel'] == 0) _options.remove('maxParallel');
    Navigator.pop(
      context,
      AiSendSettings(
        agent: _agent,
        permission: _permission,
        delivery: _delivery,
        options: _options,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('本次发送'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${widget.root}:${widget.workdir}'),
              const SizedBox(height: 8),
              const Text('模式与权限保留在当前对话；下面的运行覆盖仅用于这条消息，发送成功后恢复项目设置。'),
              const SizedBox(height: 20),
              _choice(
                'agent',
                '工作模式',
                _agent,
                {
                  if (_agent == 'explore') 'explore': '探索 · 只读',
                  'build': '构建 · 可修改文件',
                  'plan': '规划 · 只读',
                },
                widget.child && _agent == 'explore' ? null : (v) => _agent = v,
              ),
              _choice(
                'permission',
                '执行权限',
                _permission,
                {'ask': '先询问', 'auto': '自动执行'},
                (v) => _permission = v,
                help: '按模型工具开关与权限规则执行；高风险命令仍需确认。',
              ),
              if (widget.running)
                _choice('delivery', '发送方式', _delivery, {
                  'steer': '补充指令 · 插入当前任务',
                  'queue': '排队发送 · 当前任务结束后',
                }, (v) => _delivery = v),
              if (_steering)
                const Notice(
                  tone: Tone.info,
                  title: '沿用当前任务设置',
                  body: '补充指令共用当前预算。暂存的运行覆盖仅在排队或空闲后发送时使用。',
                ),
              if (!_supported)
                const Notice(
                  tone: Tone.info,
                  title: '需要更新 agent',
                  body: '当前 agent 支持模式与权限；逐条消息的运行覆盖需要新版 agent。',
                ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null)
                Notice(
                  tone: Tone.error,
                  title: '未能读取项目策略',
                  body: _error,
                  action: TextButton(
                    onPressed: _loading ? null : _load,
                    child: const Text('重试'),
                  ),
                ),
              if (_supported) ...[
                const AiSectionHeading(
                  icon: Icons.speed_outlined,
                  title: '运行预算',
                  subtitle: '含主代理、子代理、标题与摘要。关闭限制仍保留用量统计。',
                ),
                _choice(
                  'budget',
                  '本条消息的预算',
                  _budgetMode,
                  {
                    'inherit':
                        '使用项目设置 · ${_defaults?['budgetEnabled'] == false ? '关闭' : '开启'}',
                    'on': '开启 · 使用项目限额',
                    'off': '关闭 · 不限制本次运行',
                    'custom': '自定义本次限额',
                  },
                  _editable
                      ? (v) {
                          _options['budgetMode'] = v;
                          if (v == 'custom') {
                            _options['budget'] ??= Map<String, dynamic>.from(
                              _defaults!['budget'] as Map,
                            );
                          }
                        }
                      : null,
                ),
                if (_budgetMode == 'custom') ...[
                  _limit('tokens', '累计 Token 上限', 1000000000),
                  _limit('steps', '模型调用步数', 10000),
                  _limit('seconds', '运行时间（秒）', 604800),
                  _limit('outputBytes', '模型输出（字节）', 1073741824),
                  _limit('cost', '估算金额（USD）', 1000000, decimal: true),
                ],
                const AiSectionHeading(
                  icon: Icons.account_tree_outlined,
                  title: '代理协作',
                  subtitle: '子代理共享当前任务预算，始终禁止继续创建子代理。',
                ),
                if (widget.child)
                  const Text('这是子会话，不能派生新的子代理。')
                else ...[
                  _toggle(
                    'subagents',
                    '允许主代理创建子代理',
                    (_defaults?['subagents'] as Map?)?['enabled'] != false,
                  ),
                  _choice(
                    'parallel',
                    '同时运行的子代理数',
                    '${_options['maxParallel'] ?? 0}',
                    {
                      '0':
                          '使用项目设置 · ${(_defaults?['subagents'] as Map?)?['maxParallel'] ?? 1} 个',
                      for (var i = 1; i <= 16; i++) '$i': '$i 个',
                    },
                    _editable
                        ? (v) {
                            _options['maxParallel'] = int.parse(v);
                          }
                        : null,
                    help: '独立子任务可并发；总量与只读策略由项目设置控制。',
                  ),
                ],
                const AiSectionHeading(
                  icon: Icons.auto_awesome_outlined,
                  title: '自动处理',
                ),
                _toggle(
                  'autoCompact',
                  '自动压缩上下文',
                  _defaults?['autoCompact'] != false,
                ),
                _toggle(
                  'snapshots',
                  '修改前创建文件快照',
                  _defaults?['snapshots'] != false,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(() {
          _options = {};
          _epoch++;
        }),
        child: const Text('恢复项目设置'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('ai-send-options-apply'),
        onPressed: _apply,
        child: const Text('应用到输入框'),
      ),
    ],
  );
}
