import 'package:aurora/ui/aurora_ui.dart';

import '../theme/ide_theme.dart';
import 'editor_tab.dart';
import 'tab_workspace_view.dart';
import 'workspace.dart';
import 'retained_pane.dart';

/// Secondary sidebar, not an editor group. History never reparents a chat.
class AssistantPanelView extends StatefulWidget {
  final Workspace ws;
  final VoidCallback? onNew;
  final Widget Function(VoidCallback onOpened)? historyBuilder;
  const AssistantPanelView({
    super.key,
    required this.ws,
    this.onNew,
    this.historyBuilder,
  });
  @override
  State<AssistantPanelView> createState() => _AssistantPanelViewState();
}

class _AssistantPanelViewState extends State<AssistantPanelView> {
  final Map<EditorTab, Widget> _bodies = {};
  bool _historyOpen = false;
  Widget? _historyBody;
  EditorTab? _activeTab;
  void _history() => setState(() {
    _historyOpen = !_historyOpen;
    _historyBody ??=
        widget.historyBuilder?.call(() {
          if (mounted) setState(() => _historyOpen = false);
        }) ??
        const Center(child: Text('暂无历史'));
  });
  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, ide = Ide.of(context), tabs = ws.assistantTabs;
    final active = ws.tab(ws.assistantPanel.active ?? '');
    // Commands/activity navigation may open a chat while history is visible.
    // Compare document identity: background draft-ID promotion isn't navigation.
    if (!identical(active, _activeTab)) _historyOpen = false;
    _activeTab = active;
    _bodies.removeWhere((tab, _) => !tabs.contains(tab));
    return Material(
      color: ide.editor,
      child: Column(
        children: [
          Container(
            key: const ValueKey('assistant-panel-header'),
            height: 34,
            decoration: BoxDecoration(
              color: ide.tabBar,
              border: Border(bottom: BorderSide(color: ide.border)),
            ),
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 15, color: ide.accent),
                const SizedBox(width: 7),
                Expanded(
                  child: WorkbenchMenuButton<String>(
                    tooltip: '切换已打开的 AI 对话',
                    onSelected: (id) {
                      setState(() => _historyOpen = false);
                      ws.activate(id);
                    },
                    itemBuilder: (_) => [
                      for (final tab in tabs)
                        CheckedPopupMenuItem(
                          value: tab.id,
                          checked: tab.id == ws.assistantPanel.active,
                          child: Text(tab.title),
                        ),
                    ],
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            _historyOpen
                                ? '对话历史'
                                : ws.tab(ws.assistantPanel.active ?? '')?.title ??
                                      'AI 助手',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (!_historyOpen && tabs.length > 1) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.expand_more_rounded,
                            size: 14,
                            color: ide.textDim,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                _action(
                  '新建 AI 对话',
                  Icons.add_rounded,
                  widget.onNew == null
                      ? null
                      : () {
                          setState(() => _historyOpen = false);
                          widget.onNew!();
                        },
                ),
                _action(
                  _historyOpen ? '返回对话' : 'AI 对话历史',
                  _historyOpen ? Icons.arrow_back_rounded : Icons.history_rounded,
                  _history,
                ),
                WorkbenchMenuButton<String>(
                  tooltip: '侧栏布局',
                  onSelected: (v) => v == 'size'
                      ? ws.toggleAssistantMaximized()
                      : ws.hideAssistantPanel(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'size',
                      child: Text(
                        ws.assistantPanel.maximized ? '还原 AI 侧栏' : '展开 AI 对话',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'hide',
                      child: Text('隐藏侧栏 · 保留对话'),
                    ),
                  ],
                  icon: Icon(
                    ws.assistantPanel.maximized
                        ? Icons.close_fullscreen_rounded
                        : Icons.view_sidebar_outlined,
                    size: 16,
                    color: ide.textDim,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, box) => Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  if (tabs.isEmpty && !_historyOpen)
                    Center(
                      child: TextButton.icon(
                        onPressed: widget.onNew,
                        icon: const Icon(Icons.add),
                        label: const Text('新建对话'),
                      ),
                    ),
                  for (final tab in tabs)
                    Builder(
                      key: ObjectKey(tab),
                      builder: (_) {
                        return Positioned.fromRect(
                          rect: Offset.zero & box.biggest,
                          child: RetainedPane(
                            visible:
                                !_historyOpen &&
                                tab.id == ws.assistantPanel.active,
                            viewportKey: ValueKey(
                              'assistant-viewport-${tab.id}',
                            ),
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: (_) => ws.focusAssistantPanel(),
                              child: TabFocusFrame(
                                request:
                                    ws.assistantFocused &&
                                        tab.id == ws.assistantPanel.active
                                    ? ws.assistantFocusRequest
                                    : -1,
                                canFocus: () =>
                                    ws.assistantFocused &&
                                    tab.id == ws.assistantPanel.active,
                                child: _bodies.putIfAbsent(
                                  tab,
                                  () => Builder(builder: tab.builder),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  if (_historyBody != null)
                    Positioned.fill(
                      key: const ValueKey('assistant-history'),
                      child: RetainedPane(
                        visible: _historyOpen,
                        child: _historyBody!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(String tooltip, IconData icon, VoidCallback? action) =>
      SizedBox(
        width: 28,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          onPressed: action,
          icon: Icon(icon, size: 16),
        ),
      );
}
