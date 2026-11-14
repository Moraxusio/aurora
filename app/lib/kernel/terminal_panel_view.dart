import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'overlays.dart';

import '../theme/ide_theme.dart';
import 'editor_tab.dart';
import 'input_mode.dart';
import 'tab_workspace_view.dart';
import 'workspace.dart';
import 'retained_pane.dart';

class TerminalPanelView extends StatefulWidget {
  final Workspace ws;
  final VoidCallback? onNew;
  final Widget Function(VoidCallback onOpened)? sessionsBuilder;
  const TerminalPanelView({
    super.key,
    required this.ws,
    this.onNew,
    this.sessionsBuilder,
  });
  @override
  State<TerminalPanelView> createState() => _TerminalPanelViewState();
}

class _TerminalPanelViewState extends State<TerminalPanelView> {
  final Map<EditorTab, Widget> _bodies = {};
  bool? _sessionsWanted;
  String? _active;
  int _revision = -1;

  @override
  void didUpdateWidget(TerminalPanelView old) {
    super.didUpdateWidget(old);
    if (old.ws != widget.ws) {
      _bodies.clear();
      _sessionsWanted = null;
      _active = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, ide = Ide.of(context), tabs = ws.terminalTabs;
    if (_revision != ws.viewRevision) {
      _revision = ws.viewRevision;
      _bodies.clear();
    }
    final live = tabs.toSet();
    _bodies.removeWhere((tab, _) => !live.contains(tab));
    final row = InputMode.isTouch(context) ? 44.0 : 36.0;
    return Material(
      color: ide.editor,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => ws.focusTerminalPanel(),
        child: LayoutBuilder(
          builder: (_, box) {
            final wide = box.maxWidth >= 700;
            if (_active != ws.terminalActiveId) {
              _active = ws.terminalActiveId;
              if (!wide) _sessionsWanted = false;
            }
            final hasTerminal = tabs.any(
              (tab) => tab.id == ws.terminalActiveId,
            );
            final showSessions = !hasTerminal || (_sessionsWanted ?? wide);
            final split = hasTerminal && wide && showSessions;
            final headerHeight = math.min(row, box.maxHeight);
            final area = Rect.fromLTWH(
              0,
              headerHeight,
              box.maxWidth,
              math.max(0, box.maxHeight - headerHeight),
            );
            final listWidth = math.min(
              200.0,
              math.max(150.0, box.maxWidth * .22),
            );
            final terminalRect = split
                ? Rect.fromLTWH(
                    0,
                    area.top,
                    math.max(0, area.width - listWidth - 1),
                    area.height,
                  )
                : area;
            final sessionsRect = split
                ? Rect.fromLTWH(
                    terminalRect.right + 1,
                    area.top,
                    listWidth,
                    area.height,
                  )
                : area;
            final showBody = hasTerminal && (!showSessions || split);
            final sessions =
                widget.sessionsBuilder?.call(() {
                  if (mounted && !wide) setState(() => _sessionsWanted = false);
                }) ??
                const Center(child: Text('在这里选择或新建终端会话'));
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final tab in tabs)
                  Builder(
                    key: ObjectKey(tab),
                    builder: (_) {
                      final shown = showBody && ws.terminalActiveId == tab.id;
                      return Positioned.fromRect(
                        rect: terminalRect,
                        child: RetainedPane(
                          visible: shown,
                          viewportKey: ValueKey('terminal-viewport-${tab.id}'),
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (_) => ws.focusTerminalPanel(),
                            child: TabFocusFrame(
                              request: shown && ws.terminalFocused
                                  ? ws.terminalFocusRequest
                                  : -1,
                              canFocus: () =>
                                  ws.terminalFocused &&
                                  ws.terminalActiveId == tab.id,
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
                Positioned.fromRect(
                  key: const ValueKey('terminal-sessions-host'),
                  rect: sessionsRect,
                  child: RetainedPane(
                    visible: showSessions,
                    viewportKey: const ValueKey('terminal-sessions'),
                    child: sessions,
                  ),
                ),
                if (split)
                  Positioned(
                    left: terminalRect.right,
                    top: area.top,
                    bottom: 0,
                    width: 1,
                    child: ColoredBox(color: ide.border),
                  ),
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  height: headerHeight,
                  child: ClipRect(
                    child: Container(
                      key: const ValueKey('terminal-panel-header'),
                      decoration: BoxDecoration(
                        color: ide.tabBar,
                        border: Border(bottom: BorderSide(color: ide.border)),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          Container(
                            alignment: Alignment.center,
                            height: row,
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: ide.accent, width: 2),
                              ),
                            ),
                            child: Text(
                              '终端',
                              style: TextStyle(fontSize: 12, color: ide.text),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: tabs.isEmpty
                                ? const SizedBox()
                                : Align(
                                    alignment: Alignment.centerRight,
                                    child: WorkbenchMenuButton<String>(
                                      key: const ValueKey('terminal-selector'),
                                      tooltip: '切换终端会话',
                                      onSelected: ws.activate,
                                      itemBuilder: (_) => [
                                        for (final tab in tabs)
                                          CheckedPopupMenuItem(
                                            value: tab.id,
                                            checked:
                                                tab.id == ws.terminalActiveId,
                                            child: Text(tab.title),
                                          ),
                                      ],
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.terminal,
                                              size: 14,
                                              color: ide.textDim,
                                            ),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                ws
                                                        .tab(
                                                          ws.terminalActiveId ??
                                                              '',
                                                        )
                                                        ?.title ??
                                                    '',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: ide.textDim,
                                                ),
                                              ),
                                            ),
                                            Icon(
                                              Icons.expand_more,
                                              size: 14,
                                              color: ide.textDim,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                          _action(
                            Icons.add,
                            '新建终端会话（Ctrl+Shift+`）',
                            widget.onNew,
                          ),
                          _action(
                            Icons.list_alt_outlined,
                            '终端会话列表',
                            () =>
                                setState(() => _sessionsWanted = !showSessions),
                            selected: showSessions,
                          ),
                          if (hasTerminal)
                            _action(
                              Icons.delete_outline,
                              ws.entry?.isLocal == true
                                  ? '结束当前本地终端'
                                  : '关闭终端视图（远程会话保留）',
                              () => ws.closeTab(ws.terminalActiveId!),
                            ),
                          _action(
                            ws.terminalPanel.maximized
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_up,
                            ws.terminalPanel.maximized ? '还原终端面板' : '最大化终端面板',
                            ws.toggleTerminalMaximized,
                          ),
                          _action(
                            Icons.close,
                            '隐藏终端面板（保留会话）',
                            ws.hideTerminalPanel,
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _action(
    IconData icon,
    String tooltip,
    VoidCallback? onTap, {
    bool selected = false,
  }) => SizedBox(
    width: InputMode.isTouch(context) ? 40 : 28,
    child: IconButton(
      padding: EdgeInsets.zero,
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(
        icon,
        size: 16,
        color: selected ? Ide.of(context).accent : Ide.of(context).textDim,
      ),
    ),
  );
}
