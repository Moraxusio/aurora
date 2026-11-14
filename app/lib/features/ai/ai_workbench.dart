import 'package:flutter/material.dart';

import '../../kernel/retained_pane.dart';
import '../../kernel/widgets.dart';
import '../../theme/ide_theme.dart';
import 'ai_transcript.dart';
import 'ai_visuals.dart';
import 'ai_work.dart';

class AiWorkbench extends StatefulWidget {
  final String? sessionId;
  final Widget Function(AiWorkController work, String? sessionId, bool primary)
  conversationBuilder;
  const AiWorkbench({
    super.key,
    this.sessionId,
    required this.conversationBuilder,
  });
  @override
  State<AiWorkbench> createState() => _AiWorkbenchState();
}

class _AiWorkbenchState extends State<AiWorkbench> {
  late final work = AiWorkController(widget.sessionId);
  final _views = <String, Widget>{};
  @override
  void dispose() {
    work.dispose();
    super.dispose();
  }

  Widget _view(String key) => _views.putIfAbsent(key, () {
    if (key.startsWith('work:')) {
      return _WorkOutput(item: work.items[key.substring(5)]!, work: work);
    }
    return widget.conversationBuilder(
      work,
      key == 'main' ? widget.sessionId : key.substring(8),
      key == 'main',
    );
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: work,
    builder: (context, _) {
      final ide = Ide.of(context);
      final root = work.sessions[work.rootId];
      final items = work.items.values.toList().reversed.toList();
      return Column(
        children: [
          Container(
            key: const ValueKey('ai-work-navigation'),
            height: 44,
            decoration: BoxDecoration(
              color: ide.panel,
              border: Border(bottom: BorderSide(color: ide.border)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              children: [
                _WorkTab(
                  key: const ValueKey('ai-work-main'),
                  icon: Icons.chat_bubble_outline,
                  label: root?.parentId.isNotEmpty == true ? '子代理' : '主对话',
                  selected: work.selected == 'main',
                  onTap: () => work.select('main'),
                  waiting: root?.waiting == true,
                  running: root?.running == true,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: items.isEmpty
                      ? Text(
                          '子代理与命令会显示在这里',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: ide.textFaint),
                        )
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 4),
                          itemBuilder: (_, index) {
                            final item = items[index];
                            final target = item.childId.isEmpty
                                ? 'work:${item.key}'
                                : 'session:${item.childId}';
                            return _WorkTab(
                              key: ValueKey('ai-work-tab-${item.key}'),
                              icon: item.childId.isEmpty
                                  ? Icons.terminal
                                  : Icons.account_tree_outlined,
                              label: item.title,
                              selected: work.selected == target,
                              status:
                                  work.sessions[item.childId]?.running == true
                                  ? AiWorkStatus.running
                                  : item.status,
                              waiting:
                                  work.sessions[item.childId]?.waiting == true,
                              onTap: () => work.openItem(item),
                            );
                          },
                        ),
                ),
                IconButton(
                  key: const ValueKey('ai-work-list'),
                  tooltip: '所有工作 · 运行中与已完成',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  onPressed: () => showPicker<void>(
                    context,
                    maxWidth: 500,
                    maxHeight: 580,
                    builder: (_) => _WorkPicker(work: work),
                  ),
                  icon: Badge(
                    isLabelVisible: work.runningCount > 0,
                    label: Text('${work.runningCount}'),
                    child: const Icon(Icons.view_list_outlined, size: 18),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final target in work.opened)
                  RetainedPane(
                    key: ValueKey(target),
                    visible: target == work.selected,
                    child: _view(target),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _WorkTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected, waiting, running;
  final AiWorkStatus? status;
  final VoidCallback onTap;
  const _WorkTab({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.waiting = false,
    this.running = false,
    this.status,
  });
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Tooltip(
      message:
          '$label${waiting
              ? ' · 等待批准'
              : status != null
              ? ' · ${AiStatusMark.text(status!)}'
              : ''}',
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: AiVisuals.radius,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 190),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: selected
                  ? AiVisuals.surface(ide, selected: true)
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: selected ? ide.accent : ide.textDim,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected ? ide.text : ide.textDim,
                      ),
                    ),
                  ),
                  if (waiting) ...[
                    const SizedBox(width: 5),
                    Icon(Icons.shield_outlined, size: 13, color: ide.warn),
                  ] else if (status != null || running) ...[
                    const SizedBox(width: 5),
                    AiStatusMark(status ?? AiWorkStatus.running, label: false),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkPicker extends StatefulWidget {
  final AiWorkController work;
  const _WorkPicker({required this.work});
  @override
  State<_WorkPicker> createState() => _WorkPickerState();
}

class _WorkPickerState extends State<_WorkPicker> {
  final _filter = TextEditingController();
  @override
  void initState() {
    super.initState();
    _filter.addListener(_filterChanged);
  }

  void _filterChanged() => setState(() {});
  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _select(VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.work,
    builder: (context, _) {
      final work = widget.work,
          ide = Ide.of(context),
          query = _filter.text.trim().toLowerCase();
      final items =
          work.items.values
              .where(
                (i) => '${i.title} ${i.name} ${i.sessionTitle} ${i.arguments}'
                    .toLowerCase()
                    .contains(query),
              )
              .toList()
            ..sort(
              (a, b) => (a.status == AiWorkStatus.running ? 0 : 1).compareTo(
                b.status == AiWorkStatus.running ? 0 : 1,
              ),
            );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: AiSectionHeading(
              icon: Icons.account_tree_outlined,
              title: '工作导航',
              subtitle: '主对话、子代理和命令输出 · 完成后仍可查看',
            ),
          ),
          PickerField(
            controller: _filter,
            hint: '查找任务、命令或代理',
            icon: Icons.search,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.chat_bubble_outline, size: 18),
            title: const Text('主对话'),
            onTap: () => _select(() => work.select('main')),
          ),
          Divider(height: 1, color: ide.border),
          Flexible(
            child: items.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无匹配的工作'),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (_, index) {
                      final item = items[index];
                      final child = item.childId.isNotEmpty;
                      return ListTile(
                        key: ValueKey('ai-work-row-${item.key}'),
                        dense: true,
                        leading: Icon(
                          child ? Icons.account_tree_outlined : Icons.terminal,
                          size: 18,
                          color: ide.textDim,
                        ),
                        title: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: ide.text),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              AiStatusMark(item.status),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  child
                                      ? '子代理'
                                      : item.sessionId == work.rootId
                                      ? '主代理 · Shell'
                                      : '子代理 · Shell',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ide.textDim,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        trailing: child
                            ? IconButton(
                                tooltip: '查看任务输出',
                                icon: const Icon(Icons.subject, size: 17),
                                onPressed: () => _select(
                                  () => work.select('work:${item.key}'),
                                ),
                              )
                            : null,
                        onTap: () => _select(() => work.openItem(item)),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
}

class _WorkOutput extends StatefulWidget {
  final AiWorkItem item;
  final AiWorkController work;
  const _WorkOutput({required this.item, required this.work});
  @override
  State<_WorkOutput> createState() => _WorkOutputState();
}

class _WorkOutputState extends State<_WorkOutput> {
  final _scroll = AiTranscriptController();
  bool _visible = true;
  @override
  void initState() {
    super.initState();
    widget.item.addListener(_update);
  }

  void _update() {
    if (mounted && _visible) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    widget.item.removeListener(_update);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item, ide = Ide.of(context);
    final lines = item.output.split('\n');
    final owner = item.childId.isNotEmpty ? item.childId : item.sessionId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
          child: AiSectionHeading(
            icon: Icons.terminal,
            title: item.title,
            trailing: IconBtn(
              Icons.copy_outlined,
              '复制输出',
              () => copyText(item.output, what: '输出已复制'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
          child: Row(
            children: [
              AiStatusMark(item.status),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.sessionId == widget.work.rootId
                      ? '主代理'
                      : '子代理 · ${item.sessionTitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: ide.textDim),
                ),
              ),
              TextButton(
                onPressed: () => widget.work.openSession(owner),
                child: Text(owner == widget.work.rootId ? '返回主对话' : '查看子代理'),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _scroll.followsLatest,
                builder: (_, follows, _) => IconBtn(
                  Icons.vertical_align_bottom,
                  follows ? '正在跟随输出' : '回到最新输出',
                  _scroll.followLatest,
                  color: follows ? ide.textFaint : ide.accent,
                ),
              ),
            ],
          ),
        ),
        ExpansionTile(
          dense: true,
          title: Text(
            '${item.arguments['command'] ?? '任务参数'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: Ide.mono,
              fontFamilyFallback: Ide.monoFallback,
              fontSize: 11.5,
              color: ide.textDim,
            ),
          ),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  item.input,
                  style: TextStyle(fontSize: 12, color: ide.textDim),
                ),
              ),
            ),
          ],
        ),
        if (item.clipped)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '显示最近输出（最多 4096 行 / 256K 字符）；最终结果见工具记录',
              style: TextStyle(fontSize: 11, color: ide.textDim),
            ),
          ),
        Divider(height: 1, color: ide.border),
        Expanded(
          child: item.output.isEmpty
              ? Center(
                  child: Text(
                    item.status == AiWorkStatus.running ? '等待输出…' : '任务没有文本输出',
                    style: TextStyle(color: ide.textDim),
                  ),
                )
              : SelectionArea(
                  child: AiTranscript(
                    key: ValueKey('ai-work-output-${item.key}'),
                    controller: _scroll,
                    ids: [
                      for (var i = 0; i < lines.length; i++)
                        '${item.outputRevision}:${item.firstLine + i}',
                    ],
                    itemBuilder: (_, index) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        lines[index].isEmpty ? ' ' : lines[index],
                        style: TextStyle(
                          fontFamily: Ide.mono,
                          fontFamilyFallback: Ide.monoFallback,
                          fontSize: 12,
                          height: 1.55,
                          color: ide.text,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
