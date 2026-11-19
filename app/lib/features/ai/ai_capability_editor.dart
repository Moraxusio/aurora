import 'package:aurora/ui/aurora_ui.dart';

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
