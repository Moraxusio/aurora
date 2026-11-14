import 'package:flutter/material.dart';

import '../theme/ide_theme.dart';
import 'editor_tab.dart';
import 'tab_workspace_view.dart';
import 'workspace.dart';

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
  final Map<EditorTab, Rect> _rects = {};
  Future<void> _history() => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 460,
        height: MediaQuery.sizeOf(context).height * .75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  const Expanded(child: Text('对话历史')),
                  IconButton(
                    tooltip: '关闭历史',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child:
                  widget.historyBuilder?.call(() => Navigator.pop(context)) ??
                  const Center(child: Text('暂无历史')),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, ide = Ide.of(context), tabs = ws.assistantTabs;
    _bodies.removeWhere((tab, _) => !tabs.contains(tab));
    _rects.removeWhere((tab, _) => !tabs.contains(tab));
    return Material(
      color: ide.editor,
      child: Column(
        children: [
          Container(
            key: const ValueKey('assistant-panel-header'),
            height: 36,
            decoration: BoxDecoration(
              color: ide.tabBar,
              border: Border(bottom: BorderSide(color: ide.border)),
            ),
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 15, color: ide.accent),
                const SizedBox(width: 7),
                Expanded(
                  child: PopupMenuButton<String>(
                    tooltip: '切换已打开的 AI 对话',
                    onSelected: ws.activate,
                    itemBuilder: (_) => [
                      for (final tab in tabs)
                        CheckedPopupMenuItem(
                          value: tab.id,
                          checked: tab.id == ws.assistantPanel.active,
                          child: Text(tab.title),
                        ),
                    ],
                    child: Text(
                      ws.tab(ws.assistantPanel.active ?? '')?.title ?? 'AI 助手',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                _action('新建 AI 对话', Icons.add, widget.onNew),
                _action('AI 对话历史', Icons.history, _history),
                _action(
                  ws.assistantPanel.maximized ? '还原 AI 侧栏' : '展开 AI 对话',
                  ws.assistantPanel.maximized
                      ? Icons.close_fullscreen
                      : Icons.open_in_full,
                  ws.toggleAssistantMaximized,
                ),
                _action('隐藏 AI 侧栏（保留对话）', Icons.close, ws.hideAssistantPanel),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, box) => Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  if (tabs.isEmpty)
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
                        if (tab.id == ws.assistantPanel.active) {
                          _rects[tab] = Offset.zero & box.biggest;
                        }
                        return Positioned.fromRect(
                          rect: _rects.putIfAbsent(
                            tab,
                            () => Offset.zero & box.biggest,
                          ),
                          child: Offstage(
                            offstage: tab.id != ws.assistantPanel.active,
                            child: TickerMode(
                              enabled: tab.id == ws.assistantPanel.active,
                              child: ExcludeFocus(
                                excluding: tab.id != ws.assistantPanel.active,
                                child: Listener(
                                  behavior: HitTestBehavior.translucent,
                                  onPointerDown: (_) =>
                                      ws.focusAssistantPanel(),
                                  child: ClipRect(
                                    key: ValueKey(
                                      'assistant-viewport-${tab.id}',
                                    ),
                                    child: TabFocusFrame(
                                      request:
                                          ws.assistantFocused &&
                                              tab.id == ws.assistantPanel.active
                                          ? ws.assistantFocusRequest
                                          : -1,
                                      canFocus: () =>
                                          ws.assistantFocused &&
                                          tab.id == ws.assistantPanel.active,
                                      child: RepaintBoundary(
                                        child: _bodies.putIfAbsent(
                                          tab,
                                          () => Builder(builder: tab.builder),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
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
