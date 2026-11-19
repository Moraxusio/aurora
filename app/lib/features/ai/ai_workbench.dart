import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/retained_pane.dart';
import '../../theme/ide_theme.dart';
import 'ai_transcript.dart';
import 'ai_visuals.dart';
import 'ai_work.dart';

class AiWorkbench extends StatefulWidget {
  final String? sessionId;
  final ValueChanged<String>? onStopSession;
  final Widget Function(AiWorkController work, String? sessionId, bool primary)
  conversationBuilder;
  const AiWorkbench({
    super.key,
    this.sessionId,
    this.onStopSession,
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
    if (key == 'tasks')
      return _WorkPicker(
        work: work,
        embedded: true,
        onStopSession: widget.onStopSession,
      );
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
      return Column(
        children: [
          if (work.showNavigation)
            Container(
              key: const ValueKey('ai-work-navigation'),
              decoration: BoxDecoration(
                color: ide.panel,
                border: Border(bottom: BorderSide(color: ide.border)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: ide.editor,
                          borderRadius: AiVisuals.radius,
                          border: Border.all(color: ide.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _WorkTab(
                              key: const ValueKey('ai-work-main'),
                              icon: Icons.chat_bubble_outline_rounded,
                              label: '对话',
                              selected: work.selected == 'main',
                              onTap: () => work.select('main'),
                              waiting: root?.waiting == true,
                              running: root?.running == true,
                            ),
                            const SizedBox(width: 2),
                            _WorkTab(
                              key: const ValueKey('ai-work-list'),
                              icon: Icons.checklist_rounded,
                              label: work.runningCount > 0
                                  ? '任务 · ${work.runningCount}'
                                  : '任务',
                              selected: work.selected == 'tasks',
                              waiting: work.sessions.values.any(
                                (s) => s.waiting,
                              ),
                              onTap: () => work.select('tasks'),
                            ),
                            for (final target in work.opened)
                              if (target.startsWith('work:') ||
                                  target.startsWith('session:')) ...[
                                const SizedBox(width: 2),
                                Builder(
                                  builder: (_) {
                                    final isWork = target.startsWith('work:');
                                    final id = isWork
                                        ? target.substring(5)
                                        : target.substring(8);
                                    final item = isWork ? work.items[id] : null;
                                    final sess = !isWork
                                        ? work.sessions[id]
                                        : null;
                                    final label =
                                        item?.title ?? sess?.title ?? '子视图';
                                    final waiting =
                                        sess?.waiting == true ||
                                        (item != null &&
                                            item.childId.isNotEmpty &&
                                            work
                                                    .sessions[item.childId]
                                                    ?.waiting ==
                                                true);
                                    final running =
                                        item?.status == AiWorkStatus.running ||
                                        sess?.running == true;
                                    return _WorkTab(
                                      key: ValueKey('ai-work-tab-$id'),
                                      icon: isWork
                                          ? Icons.terminal_rounded
                                          : Icons.account_tree_outlined,
                                      label: label,
                                      selected: work.selected == target,
                                      waiting: waiting,
                                      running: running,
                                      onTap: () => work.select(target),
                                      onClose: () {
                                        _views.remove(target);
                                        work.closeTarget(target);
                                      },
                                    );
                                  },
                                ),
                              ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            key: const ValueKey('ai-work-pages'),
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
  final VoidCallback onTap;
  final VoidCallback? onClose;
  const _WorkTab({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onClose,
    this.waiting = false,
    this.running = false,
  });
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Tooltip(
      message:
          '$label${waiting
              ? ' · 等待批准'
              : running
              ? ' · 运行中'
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
              constraints: const BoxConstraints(maxWidth: 200, minHeight: 26),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? ide.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.s + 2),
                border: Border.all(
                  color: selected
                      ? ide.accent.withValues(alpha: 0.35)
                      : Colors.transparent,
                ),
              ),
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
                  ] else if (running) ...[
                    const SizedBox(width: 5),
                    const AiStatusMark(AiWorkStatus.running, label: false),
                  ],
                  if (onClose != null) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: onClose,
                      borderRadius: BorderRadius.circular(Radii.s),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: ide.textFaint,
                        ),
                      ),
                    ),
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
  final bool embedded;
  final ValueChanged<String>? onStopSession;
  const _WorkPicker({
    required this.work,
    this.embedded = false,
    this.onStopSession,
  });
  @override
  State<_WorkPicker> createState() => _WorkPickerState();
}

class _WorkPickerState extends State<_WorkPicker> {
  final _filter = TextEditingController();
  String _status = 'all';
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
    if (!widget.embedded) Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.work,
    builder: (context, _) {
      final work = widget.work,
          ide = Ide.of(context),
          query = _filter.text.trim().toLowerCase();
      bool waiting(AiWorkItem item) =>
          work
              .sessions[item.childId.isEmpty ? item.sessionId : item.childId]
              ?.waiting ==
          true;
      final items =
          work.items.values
              .where(
                (i) =>
                    (_status == 'all' ||
                        _status == 'running' &&
                            (i.status == AiWorkStatus.running || waiting(i)) ||
                        _status == 'error' &&
                            (i.status == AiWorkStatus.error ||
                                i.status == AiWorkStatus.interrupted ||
                                waiting(i))) &&
                    '${i.title} ${i.name} ${i.sessionTitle} ${i.arguments}'
                        .toLowerCase()
                        .contains(query),
              )
              .toList()
            ..sort(
              (a, b) => (a.status == AiWorkStatus.running ? 0 : 1).compareTo(
                b.status == AiWorkStatus.running ? 0 : 1,
              ),
            );
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: AiSectionHeading(
                    icon: Icons.account_tree_outlined,
                    title: '任务',
                    subtitle: '子代理与命令的进展、审批和结果',
                  ),
                ),
                PickerField(
                  controller: _filter,
                  hint: '查找任务、命令或代理',
                  icon: Icons.search,
                ),
                UiToolbar(
                  children: [
                    for (final entry in {
                      'all': '全部',
                      'running': '进行中',
                      'error': '需处理',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _status == entry.key,
                        onSelected: (_) => setState(() => _status = entry.key),
                      ),
                  ],
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.chat_bubble_outline, size: 18),
                  title: const Text('主对话'),
                  onTap: () => _select(() => work.select('main')),
                ),
                Divider(height: 1, color: ide.border),
              ],
            ),
          ),
          if (items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无匹配的任务。子代理与命令执行后会自动显示在这里。'),
              ),
            )
          else
            SliverList.builder(
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
                        if (waiting(item))
                          Text('等待你的决定', style: TextStyle(color: ide.warn))
                        else
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
                            style: TextStyle(fontSize: 11, color: ide.textDim),
                          ),
                        ),
                      ],
                    ),
                  ),
                  trailing: WorkbenchMenuButton<String>(
                    tooltip: '任务操作',
                    onSelected: (v) {
                      if (v == 'output') {
                        _select(() => work.select('work:${item.key}'));
                      } else {
                        widget.onStopSession?.call(
                          child ? item.childId : item.sessionId,
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'output', child: Text('查看输出')),
                      if (item.status == AiWorkStatus.running &&
                          widget.onStopSession != null)
                        PopupMenuItem(
                          value: 'stop',
                          child: Text(child ? '停止此子代理' : '停止所属任务'),
                        ),
                    ],
                    icon: const Icon(Icons.more_horiz, size: 18),
                  ),
                  onTap: () => _select(() {
                    if (waiting(item) && !child) {
                      work.openSession(item.sessionId);
                    } else {
                      work.openItem(item);
                    }
                  }),
                );
              },
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
