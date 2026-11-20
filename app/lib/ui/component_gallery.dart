import 'aurora_ui.dart';
import '../theme/ide_theme.dart';

/// A production route, using the same controls and tokens as feature screens.
class ComponentGallery extends StatefulWidget {
  const ComponentGallery({super.key});
  @override
  State<ComponentGallery> createState() => _ComponentGalleryState();
}

class _ComponentGalleryState extends State<ComponentGallery> {
  final input = TextEditingController();
  bool selected = false;
  String status = '使用 Tab 切换焦点，Enter／Space 激活；触控控件至少 44 px。';
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UiPanel(
    title: 'Aurora GUI 组件',
    description: '紧凑 IDE · 明暗主题 · 动态密度 · 键盘与触控 · 缩放与语义',
    actions: [
      FilledButton(
        onPressed: () => setState(() => status = '主要操作已执行'),
        child: const Text('主要操作'),
      ),
      OutlinedButton(
        onPressed: () => setState(() => status = '次要操作已执行'),
        child: const Text('次要操作'),
      ),
      TextButton(
        onPressed: () => setState(() => status = '轻量操作已执行'),
        child: const Text('轻量操作'),
      ),
      const FilledButton(onPressed: null, child: Text('不可用')),
      IconBtn(Icons.refresh, '刷新组件', () => setState(() => status = '已刷新')),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Ide.of(context).error),
        onPressed: () => setState(() => status = '危险操作示例'),
        child: const Text('危险操作'),
      ),
    ],
    notice: Notice(tone: Tone.info, title: '交互状态', body: status),
    slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: input,
                decoration: const InputDecoration(
                  labelText: '编辑字段',
                  hintText: '支持 IME、选择、复制和粘贴',
                ),
              ),
              const SizedBox(height: Space.l),
              const TextField(
                enabled: false,
                decoration: InputDecoration(labelText: '禁用字段'),
              ),
              const SizedBox(height: Space.l),
              const TextField(
                decoration: InputDecoration(
                  labelText: '错误字段',
                  errorText: '输入内容需要修正',
                ),
              ),
              FormSection(
                title: '表单与开关',
                children: [
                  FormRow(
                    title: '功能选项',
                    subtitle: '选中状态同时提供视觉与语义信息',
                    trailing: SmallSwitch(
                      value: selected,
                      onChanged: (value) => setState(() => selected = value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.l),
              const Notice(
                tone: Tone.ok,
                title: '完成',
                body: '成功状态使用文字与图标共同表达。',
              ),
              const SizedBox(height: Space.m),
              const Notice(tone: Tone.warn, title: '需要注意', body: '警告内容可选择并复制。'),
              const SizedBox(height: Space.m),
              const Notice(
                tone: Tone.error,
                title: '操作失败',
                body: '错误状态保留用户输入，并提供重试入口。',
              ),
              const SizedBox(height: Space.l),
              UiPanelHeader(title: '工作区工具', subtitle: '标题、上下文与常用操作', icon: Icons.folder_open,
                actions: [IconBtn(Icons.refresh, '刷新面板', () => setState(() => status = '面板已刷新'))]),
              Row(children: [
                for (final (label, icon) in const [('文件', Icons.folder_outlined), ('搜索', Icons.search), ('Git', Icons.fork_right)])
                  SizedBox(width: 68, child: UiNavigationItem(icon: icon, label: label, tooltip: label,
                    selected: label == '文件', onTap: () => setState(() => status = '导航到$label'))),
              ]),
              const SizedBox(height: Space.l),
               const KeyCaps('Ctrl+Shift+P'),
               Builder(builder: (context) => OutlinedButton(
                 onPressed: () => showMenuAt(
                   context,
                   Offset.zero,
                   [
                     MenuItem('复制', () => setState(() => status = '已复制示例'), icon: Icons.content_copy_outlined, hint: 'Ctrl+C', quick: true),
                     MenuItem('删除', () => setState(() => status = '已选择删除示例'), icon: Icons.delete_outline, danger: true, quick: true),
                     MenuItem('属性…', () => setState(() => status = '已选择属性'), icon: Icons.info_outline),
                   ],
                   anchor: context,
                 ),
                 child: const Text('图标操作菜单'),
               )),
            ],
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SectionHeader('虚拟列表 · 10,000 行')),
      SliverFixedExtentList.builder(
        itemExtent: PickerRow.heightOf(context),
        itemCount: 10000,
        itemBuilder: (_, index) => TreeRow(
          label: '组件条目 $index',
          detail: '按需构建',
          selected: index == 0,
          leading: const Icon(Icons.description_outlined, size: 16),
          onTap: () => setState(() => status = '选择了条目 $index'),
        ),
      ),
    ],
  );
}
