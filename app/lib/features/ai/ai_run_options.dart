import 'package:aurora/ui/aurora_ui.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/services.dart';

import 'ai_visuals.dart';

/// Conversation-level send & execution policy settings.
class AiSendSettings {
  final String agent, permission, delivery;
  final AiSessionPolicy policy;
  const AiSendSettings({
    required this.agent,
    required this.permission,
    required this.delivery,
    required this.policy,
  });
}

Future<AiSendSettings?> showAiSessionPolicyDialog(
  BuildContext context, {
  required AiSendSettings initial,
  required AiSessionPolicy defaultPolicy,
  required bool running,
  bool child = false,
}) => showWorkbenchDialog<AiSendSettings>(
  context: context,
  builder: (_) => _SessionPolicyDialog(
    initial: initial,
    defaultPolicy: defaultPolicy,
    running: running,
    child: child,
  ),
);

/// Reusable editor for `AiSessionPolicy` (used in Settings default policy and per-conversation policy).
class AiSessionPolicyEditor extends StatelessWidget {
  final AiSessionPolicy policy;
  final bool child;
  final int epoch;
  final VoidCallback onChanged;

  const AiSessionPolicyEditor({
    super.key,
    required this.policy,
    required this.onChanged,
    this.child = false,
    this.epoch = 0,
  });

  Widget _intField(
    String keyName,
    String label,
    String help,
    int value,
    int min,
    int max,
    ValueChanged<int> apply,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      key: ValueKey('ai-policy-$keyName-$epoch'),
      initialValue: '$value',
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 2,
      ),
      validator: (text) {
        final n = int.tryParse(text ?? '');
        return n == null || n < min || n > max ? '请输入 $min–$max 之间的整数' : null;
      },
      onChanged: (text) {
        final n = int.tryParse(text);
        if (n != null && n >= min && n <= max) {
          apply(n);
          onChanged();
        }
      },
    ),
  );

  Widget _doubleField(
    String keyName,
    String label,
    String help,
    double value,
    double max,
    ValueChanged<double> apply,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      key: ValueKey('ai-policy-$keyName-$epoch'),
      initialValue: '$value',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 2,
      ),
      validator: (text) {
        final n = double.tryParse(text ?? '');
        return n == null || !n.isFinite || n < 0 || n > max
            ? '请输入 0–$max 之间的数值'
            : null;
      },
      onChanged: (text) {
        final n = double.tryParse(text);
        if (n != null && n.isFinite && n >= 0 && n <= max) {
          apply(n);
          onChanged();
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AiSectionHeading(
          icon: Icons.speed_outlined,
          title: '运行预算',
          subtitle: '每条独立任务使用一份预算（含子代理、标题与摘要）；0 表示不限该项。',
        ),
        SwitchListTile(
          key: ValueKey('ai-policy-budget-enabled-$epoch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('启用运行预算上限'),
          value: policy.budgetEnabled,
          onChanged: (v) {
            policy.budgetEnabled = v;
            onChanged();
          },
        ),
        if (policy.budgetEnabled) ...[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ActionChip(
                label: const Text('标准预算'),
                onPressed: () {
                  policy.budgetSteps = 60;
                  policy.budgetSeconds = 900;
                  policy.budgetTokens = 500000;
                  policy.budgetOutputBytes = 2097152;
                  policy.budgetCost = 0;
                  onChanged();
                },
              ),
              ActionChip(
                label: const Text('长任务预算'),
                onPressed: () {
                  policy.budgetSteps = 200;
                  policy.budgetSeconds = 7200;
                  policy.budgetTokens = 5000000;
                  policy.budgetOutputBytes = 8388608;
                  policy.budgetCost = 0;
                  onChanged();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _intField(
            'tokens',
            '累计 Token 上限',
            '输入、输出、缓存与思考总计上限。',
            policy.budgetTokens,
            0,
            1000000000,
            (v) => policy.budgetTokens = v,
          ),
          Row(
            children: [
              Expanded(
                child: _intField(
                  'steps',
                  '模型调用步数',
                  '每步可包含多个工具调用',
                  policy.budgetSteps,
                  0,
                  10000,
                  (v) => policy.budgetSteps = v,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _intField(
                  'seconds',
                  '运行时间（秒）',
                  '含模型响应与命令执行',
                  policy.budgetSeconds,
                  0,
                  604800,
                  (v) => policy.budgetSeconds = v,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _intField(
                  'outputBytes',
                  '模型输出（字节）',
                  '模型返回内容总字节',
                  policy.budgetOutputBytes,
                  0,
                  1073741824,
                  (v) => policy.budgetOutputBytes = v,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _doubleField(
                  'cost',
                  '估算金额（USD）',
                  '0 表示不限金额',
                  policy.budgetCost,
                  1000000,
                  (v) => policy.budgetCost = v,
                ),
              ),
            ],
          ),
        ],
        const AiSectionHeading(
          icon: Icons.account_tree_outlined,
          title: '子代理协作',
          subtitle: '子代理共享当前任务预算，始终禁止继续派生子代理。',
        ),
        if (child)
          const Text('当前为子会话，不能再创建子代理。')
        else ...[
          SwitchListTile(
            key: ValueKey('ai-policy-subagents-$epoch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('允许主代理创建子代理'),
            value: policy.subagentsEnabled,
            onChanged: (v) {
              policy.subagentsEnabled = v;
              onChanged();
            },
          ),
          if (policy.subagentsEnabled) ...[
            Row(
              children: [
                Expanded(
                  child: _intField(
                    'maxParallel',
                    '并发子代理数 (1–16)',
                    '1 为顺序执行',
                    policy.subagentsMaxParallel,
                    1,
                    16,
                    (v) => policy.subagentsMaxParallel = v,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _intField(
                    'maxTotal',
                    '单次任务总量',
                    '0 表示不限',
                    policy.subagentsMaxTotal,
                    0,
                    1000,
                    (v) => policy.subagentsMaxTotal = v,
                  ),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'ai-policy-subagent-perm-${policy.subagentsPermissionMode}-$epoch',
              ),
              initialValue:
                  const {
                    '',
                    'ask',
                    'readOnly',
                    'auto',
                    'full_access',
                  }.contains(policy.subagentsPermissionMode)
                  ? policy.subagentsPermissionMode
                  : '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '子代理默认权限策略'),
              items: const [
                DropdownMenuItem(
                  value: '',
                  child: Text('继承主会话 / 乐手 Persona 权限'),
                ),
                DropdownMenuItem(value: 'ask', child: Text('先询问 · 修改与命令需确认')),
                DropdownMenuItem(
                  value: 'readOnly',
                  child: Text('仅只读 · 强制降级为探索子代理'),
                ),
                DropdownMenuItem(value: 'auto', child: Text('自动执行 · 高风险仍确认')),
                DropdownMenuItem(
                  value: 'full_access',
                  child: Text('完全权限 · 免确认放行'),
                ),
              ],
              onChanged: (v) {
                policy.subagentsPermissionMode = v ?? '';
                onChanged();
              },
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('子代理仅允许只读探索'),
              value: policy.subagentsReadOnly,
              onChanged: (v) {
                policy.subagentsReadOnly = v;
                onChanged();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许子代理访问外部网络'),
              value: policy.subagentsAllowNetwork,
              onChanged: (v) {
                policy.subagentsAllowNetwork = v;
                onChanged();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许子代理执行 Shell 命令'),
              value: policy.subagentsAllowShell,
              onChanged: (v) {
                policy.subagentsAllowShell = v;
                onChanged();
              },
            ),
          ],
        ],
        const AiSectionHeading(
          icon: Icons.build_circle_outlined,
          title: '工具边界与自动处理',
        ),
        Row(
          children: [
            Expanded(
              child: _intField(
                'maxCallsPerStep',
                '单步最大工具调用数',
                '默认 64',
                policy.toolMaxCallsPerStep,
                1,
                256,
                (v) => policy.toolMaxCallsPerStep = v,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _intField(
                'repeatLimit',
                '重复调用告警阈值',
                '默认 3',
                policy.toolRepeatLimit,
                1,
                32,
                (v) => policy.toolRepeatLimit = v,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _intField(
                'shellDefaultSeconds',
                '命令默认超时（秒）',
                '默认 120',
                policy.shellDefaultSeconds,
                1,
                3600,
                (v) => policy.shellDefaultSeconds = v,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _intField(
                'shellMaxSeconds',
                '命令最大超时（秒）',
                '默认 600',
                policy.shellMaxSeconds,
                1,
                3600,
                (v) => policy.shellMaxSeconds = v,
              ),
            ),
          ],
        ),
        SwitchListTile(
          key: ValueKey('ai-policy-auto-title-$epoch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('自动生成会话标题'),
          value: policy.autoTitle,
          onChanged: (v) {
            policy.autoTitle = v;
            onChanged();
          },
        ),
        SwitchListTile(
          key: ValueKey('ai-policy-auto-compact-$epoch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('自动压缩上下文'),
          value: policy.autoCompact,
          onChanged: (v) {
            policy.autoCompact = v;
            onChanged();
          },
        ),
        SwitchListTile(
          key: ValueKey('ai-policy-snapshots-$epoch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('修改前创建文件快照'),
          value: policy.snapshots,
          onChanged: (v) {
            policy.snapshots = v;
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('ai-policy-instructions-$epoch'),
          initialValue: policy.instructions.join('\n'),
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '对话附加指令（每行一条，可选）',
            hintText: '例如：优先运行单元测试、保持中文回复…',
          ),
          onChanged: (v) {
            policy.instructions = v
                .split(RegExp(r'\r?\n'))
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
            onChanged();
          },
        ),
      ],
    );
  }
}

class _SessionPolicyDialog extends StatefulWidget {
  final AiSendSettings initial;
  final AiSessionPolicy defaultPolicy;
  final bool running, child;
  const _SessionPolicyDialog({
    required this.initial,
    required this.defaultPolicy,
    required this.running,
    required this.child,
  });
  @override
  State<_SessionPolicyDialog> createState() => _SessionPolicyDialogState();
}

class _SessionPolicyDialogState extends State<_SessionPolicyDialog> {
  final _form = GlobalKey<FormState>();
  late String _agent = widget.initial.agent;
  late String _permission = widget.initial.permission;
  late String _delivery = widget.initial.delivery;
  late AiSessionPolicy _policy = widget.initial.policy.copy();
  int _epoch = 0;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('此对话的执行策略'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '按当前对话生效；新对话默认继承「AI 设置 → 对话与编排」中的全局配置。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('ai-send-agent-$_epoch'),
                initialValue: _agent,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '工作模式'),
                items: [
                  if (_agent == 'explore')
                    const DropdownMenuItem(
                      value: 'explore',
                      child: Text('探索 · 只读'),
                    ),
                  const DropdownMenuItem(
                    value: 'build',
                    child: Text('构建 · 可修改文件'),
                  ),
                  const DropdownMenuItem(value: 'plan', child: Text('规划 · 只读')),
                  const DropdownMenuItem(
                    value: 'orchestrator',
                    child: Text('编排 · 指挥调度乐手'),
                  ),
                ],
                onChanged: widget.child && _agent == 'explore'
                    ? null
                    : (v) => setState(() => _agent = v!),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                key: ValueKey('ai-send-permission-$_epoch'),
                initialValue: _permission,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '执行权限'),
                items: const [
                  DropdownMenuItem(value: 'ask', child: Text('先询问')),
                  DropdownMenuItem(value: 'auto', child: Text('自动执行')),
                  DropdownMenuItem(value: 'full_access', child: Text('完全权限')),
                ],
                onChanged: (v) => setState(() => _permission = v!),
              ),
              if (widget.running) ...[
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  key: ValueKey('ai-send-delivery-$_epoch'),
                  initialValue: _delivery,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '发送方式'),
                  items: const [
                    DropdownMenuItem(
                      value: 'steer',
                      child: Text('补充指令 · 插入当前任务'),
                    ),
                    DropdownMenuItem(
                      value: 'queue',
                      child: Text('排队发送 · 当前任务结束后'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _delivery = v!),
                ),
              ],
              const SizedBox(height: 12),
              AiSessionPolicyEditor(
                policy: _policy,
                child: widget.child,
                epoch: _epoch,
                onChanged: () => setState(() {}),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(() {
          _policy = widget.defaultPolicy.copy();
          _epoch++;
        }),
        child: const Text('恢复默认策略'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('ai-send-options-apply'),
        onPressed: () {
          if (_form.currentState?.validate() != true) return;
          Navigator.pop(
            context,
            AiSendSettings(
              agent: _agent,
              permission: _permission,
              delivery: _delivery,
              policy: _policy,
            ),
          );
        },
        child: const Text('应用到本对话'),
      ),
    ],
  );
}
