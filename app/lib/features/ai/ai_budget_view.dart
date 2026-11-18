import 'package:aurora/ui/aurora_ui.dart';

import '../../theme/ide_theme.dart';
import 'ai_models.dart';

class AiBudgetView extends StatelessWidget {
  final AiRunBudget budget;
  final VoidCallback? onConfigure;
  const AiBudgetView({super.key, required this.budget, this.onConfigure});

  @override
  Widget build(BuildContext context) {
    final b = budget;
    final ide = Ide.of(context);
    String amount(num v) => v is int ? '$v' : v.toStringAsFixed(2);
    String line(String label, String key, num used) {
      final limit = b.limit(key);
      String value(num v) => key == 'cost' ? v.toStringAsFixed(6) : amount(v);
      return '$label：${value(used)} / ${limit == 0 ? '不限' : value(limit)}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${b.estimated ? '≈ ' : ''}${b.summary}',
          key: const ValueKey('ai-budget-usage'),
          style: TextStyle(
            color: b.blockedBy.isNotEmpty ? ide.warn : ide.textDim,
          ),
        ),
        if (b.limit('tokens') > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: LinearProgressIndicator(
              value: (b.tokens / b.limit('tokens')).clamp(0, 1).toDouble(),
            ),
          ),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            Text(line('模型步骤', 'steps', b.steps)),
            Text(line('耗时（秒）', 'seconds', b.elapsed)),
            Text(line('输出（字节）', 'outputBytes', b.outputBytes)),
            Text(line('估算金额（USD）', 'cost', b.cost)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '来源：${b.source == 'message'
              ? '本次发送覆盖'
              : b.source == 'project'
              ? '项目 .aurora/ai.json'
              : '内置默认'} · 辅助调用 ${b.auxiliary} 次 · 在途预留 ${b.reserved} tokens',
        ),
        if (b.data.containsKey('subagents'))
          Text(
            '子代理${(b.data['subagents'] as Map?)?['enabled'] == false ? '已禁用' : ''}：${b.childrenActive} 个运行中 / 并发上限 ${b.maxParallel} · 已创建 ${b.childrenStarted} 个 · 禁止递归派生',
          ),
        if (b.data.containsKey('auto_compact'))
          Text(
            '本次自动压缩：${b.data['auto_compact'] == true ? '开' : '关'} · 文件快照：${b.data['snapshots'] == true ? '开' : '关'}',
          ),
        if (b.unpriced) const Text('部分模型未配置价格，金额统计不完整。'),
        if (b.estimated) const Text('含估算用量；无 usage 的失败请求不能确定上游实际计费。'),
        if (b.nextInput > 0 && b.blockedBy.isNotEmpty)
          Text('下一步输入预计 ${b.nextInput} tokens，还需要输出空间。'),
        const SizedBox(height: 6),
        const Text('包含重复上下文、子任务、标题和压缩。补充指令共用预算；独立消息（含排队）各自开始新的预算周期。'),
        if (onConfigure != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onConfigure,
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('调整项目预算'),
            ),
          ),
      ],
    );
  }
}
