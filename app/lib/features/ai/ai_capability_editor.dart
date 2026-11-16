import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora/ui/aurora_ui.dart';

import 'ai_reasoning_field.dart';

const aiCapabilityLabels = <String, (String, String)>{
  'tool_calling': ('工具调用', '关闭后只对话，不向模型提供工具'),
  'image_input': ('图片输入', '附件和 read 读取的图片作为视觉内容发送'),
  'pdf_input': ('PDF 输入', '附件和 read 读取的 PDF 作为文件内容发送'),
  'read': ('读取文件', '文本、目录、图片与 PDF'),
  'glob': ('查找路径', '按文件名模式查找'),
  'grep': ('搜索内容', '按文本或正则查找'),
  'write': ('写入文件', '创建或整体替换'),
  'edit': ('精确编辑', '匹配原文后替换'),
  'apply_patch': ('多文件补丁', '新增、修改、移动、删除；先校验后执行'),
  'shell': ('运行命令', '在当前本机或服务器执行'),
  'webfetch': ('读取网页', '获取 URL 内容'),
  'websearch': ('联网搜索', '检索资料'),
  'todowrite': ('任务计划', '维护当前任务的进度'),
  'subagent': ('子代理', '将子任务交给独立上下文'),
  'question': ('询问用户', '选项、自由回答与多选'),
  'skill': ('项目技能', '按需读取用户和项目的技能指令'),
  'mcp': ('MCP 扩展', '连接配置的服务并使用工具、资源与提示词'),
};

class AiCapabilityEditor extends StatelessWidget {
  final Map<String, bool> values, inherited;
  final bool model;
  final ValueChanged<Map<String, bool>> onChanged;
  const AiCapabilityEditor({
    super.key,
    required this.values,
    required this.inherited,
    required this.onChanged,
    this.model = false,
  });
  Widget _row(String key) {
    final info = aiCapabilityLabels[key]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.$1, style: const TextStyle(fontSize: 12.5)),
                Text(info.$2, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (model)
            DropdownButton<String>(
              key: ValueKey('ai-capability-$key'),
              value: values[key] == null
                  ? 'inherit'
                  : values[key]!
                  ? 'on'
                  : 'off',
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(
                  value: 'inherit',
                  child: Text('继承 · ${inherited[key] != false ? '开' : '关'}'),
                ),
                const DropdownMenuItem(value: 'on', child: Text('开启')),
                const DropdownMenuItem(value: 'off', child: Text('关闭')),
              ],
              onChanged: (value) {
                final next = Map<String, bool>.of(values);
                if (value == 'inherit') {
                  next.remove(key);
                } else {
                  next[key] = value == 'on';
                }
                onChanged(next);
              },
            )
          else
            Switch(
              key: ValueKey('ai-capability-$key'),
              value: values[key] ?? inherited[key] ?? true,
              onChanged: (value) => onChanged({...values, key: value}),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final key in ['tool_calling', 'image_input', 'pdf_input']) _row(key),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('工具清单', style: TextStyle(fontSize: 13)),
        subtitle: Text(
          model ? '按工具覆盖全局默认' : '新请求的默认工具能力',
          style: const TextStyle(fontSize: 11),
        ),
        children: [
          for (final key in aiCapabilityLabels.keys.skip(3)) _row(key),
        ],
      ),
    ],
  );
}

class AiModelOptionsEditor extends StatelessWidget {
  final AiProvider provider;
  final String model;
  final Map<String, bool> defaults;
  final ValueChanged<AiModelOptions> onChanged;
  const AiModelOptionsEditor({
    super.key,
    required this.provider,
    required this.model,
    required this.defaults,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final options = provider.modelOptions[model] ?? AiModelOptions();
    void change(void Function(AiModelOptions) update) {
      final next = AiModelOptions.fromJson(options.toJson());
      update(next);
      onChanged(next);
    }

    final inherited = {
      ...aiCapabilityDefaults,
      if (provider.modelImageSupport[model] case final bool image)
        'image_input': image,
      ...defaults,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          model,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text('模型覆盖优先于全局默认；工具权限仍单独生效。', style: TextStyle(fontSize: 11)),
        AiCapabilityEditor(
          model: true,
          values: options.capabilities,
          inherited: inherited,
          onChanged: (v) => change((o) => o.capabilities = v),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('继承连接的思考预设', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            provider.reasoningEffort.isEmpty
                ? '当前：不发送思考参数'
                : '当前：${provider.reasoningEffort}',
          ),
          value: options.reasoningEffort == null,
          onChanged: (v) => change(
            (o) => o.reasoningEffort = v
                ? null
                : provider.effectiveReasoning(model),
          ),
        ),
        if (options.reasoningEffort != null)
          AiReasoningField(
            value: options.reasoningEffort!,
            suggestions: options.reasoningEfforts.isEmpty
                ? const ['low', 'medium', 'high', 'max']
                : options.reasoningEfforts.keys,
            onChanged: (v) => change((o) => o.reasoningEffort = v),
          ),
        const SizedBox(height: 12),
        TextFormField(
          key: ValueKey('ai-effort-choices-${provider.id}-$model'),
          initialValue: options.reasoningEfforts.entries
              .map((e) => e.key == e.value ? e.key : '${e.key}=${e.value}')
              .join(', '),
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: '可选档位与发送值',
            hintText: 'high, max 或 high=high, max=ultra, off=',
            helperText: '逗号分隔；未配置的手填值原样发送。空发送值表示省略参数。',
            helperMaxLines: 3,
          ),
          onChanged: (v) => change((o) {
            o.reasoningEfforts = {};
            for (final row in v.split(RegExp(r'[,，\n]'))) {
              final at = row.indexOf('=');
              final name = (at < 0 ? row : row.substring(0, at)).trim();
              if (name.isNotEmpty)
                o.reasoningEfforts[name] = at < 0
                    ? name
                    : row.substring(at + 1).trim();
            }
          }),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey(
            'ai-thinking-mode-${provider.id}-$model-${options.reasoningMode}',
          ),
          initialValue: options.reasoningMode,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '思考参数格式'),
          items: [
            const DropdownMenuItem(value: 'protocol', child: Text('跟随连接协议')),
            const DropdownMenuItem(value: 'disabled', child: Text('不发送思考参数')),
            if (provider.protocol == 'anthropic-messages' ||
                options.reasoningMode.startsWith('anthropic-')) ...[
              const DropdownMenuItem(
                value: 'anthropic-adaptive',
                child: Text('Anthropic · 自适应 effort'),
              ),
              const DropdownMenuItem(
                value: 'anthropic-budget',
                child: Text('Anthropic · Token 预算'),
              ),
            ],
          ],
          onChanged: (v) => change((o) => o.reasoningMode = v!),
        ),
        if (options.reasoningMode == 'anthropic-budget') ...[
          const SizedBox(height: 12),
          TextFormField(
            key: ValueKey('ai-thinking-budget-${provider.id}-$model'),
            initialValue: options.thinkingBudget > 0
                ? '${options.thinkingBudget}'
                : '',
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '思考 Token 预算（至少 1024）',
            ),
            onChanged: (v) =>
                change((o) => o.thinkingBudget = int.tryParse(v) ?? 0),
          ),
        ],
      ],
    );
  }
}
