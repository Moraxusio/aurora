import 'dart:math' as math;

import 'package:aurora/ui/aurora_ui.dart';

import '../theme/ide_theme.dart';
import 'editor_tab.dart';
import 'input_mode.dart';
import 'retained_pane.dart';
import 'tab_workspace_view.dart';
import 'workspace.dart';

enum _TerminalAction { create, maximize, close }

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
  bool _sessionsWanted = false, _sessionsVisited = false;
  String? _active;
  int _revision = -1;

  @override
  void didUpdateWidget(TerminalPanelView old) {
    super.didUpdateWidget(old);
    if (old.ws != widget.ws) {
      _bodies.clear();
      _sessionsWanted = _sessionsVisited = false;
      _active = null;
    }
  }

  void _sessions(bool open) => setState(() => _sessionsWanted = open);

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, ide = Ide.of(context), tabs = ws.terminalTabs;
    if (_revision != ws.viewRevision) {
      _revision = ws.viewRevision;
      _bodies.clear();
    }
    final live = tabs.toSet();
    _bodies.removeWhere((tab, _) => !live.contains(tab));
    final active = tabs
        .where((tab) => tab.id == ws.terminalActiveId)
        .firstOrNull;
    if (active?.id != _active) {
      _active = active?.id;
      _sessionsWanted = false;
    }
    final touch = InputMode.isTouch(context);
    return Material(
      color: ide.panel,
      child: LayoutBuilder(
        builder: (_, box) {
          final showSessions = active == null || _sessionsWanted;
          final split = active != null && showSessions && box.maxWidth >= 690;
          final showOutput = active != null && (!showSessions || split);
          if (showSessions) _sessionsVisited = true;
          final height = math.min(touch ? 48.0 : 38.0, box.maxHeight);
          final bodyHeight = math.max(0.0, box.maxHeight - height);
          final listWidth = (box.maxWidth * .25).clamp(185.0, 250.0);
          final outputWidth = split
              ? box.maxWidth - listWidth - 1
              : box.maxWidth;
          final outputRect = Rect.fromLTWH(0, height, outputWidth, bodyHeight);
          final sessionsRect = split
              ? Rect.fromLTWH(outputWidth + 1, height, listWidth, bodyHeight)
              : outputRect;
          return Stack(
            children: [
              for (final tab in tabs)
                Builder(
                  key: ObjectKey(tab),
                  builder: (_) {
                    final shown = showOutput && active.id == tab.id;
                    return Positioned.fromRect(
                      rect: outputRect,
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
              if (_sessionsVisited)
                Positioned.fromRect(
                  key: const ValueKey('terminal-sessions-host'),
                  rect: sessionsRect,
                  child: RetainedPane(
                    visible: showSessions,
                    viewportKey: const ValueKey('terminal-sessions'),
                    child: ColoredBox(
                      color: ide.sideBar,
                      child:
                          widget.sessionsBuilder?.call(
                            () => _sessions(false),
                          ) ??
                          const Center(child: Text('在这里选择或新建终端会话')),
                    ),
                  ),
                ),
              if (split)
                Positioned(
                  left: outputWidth,
                  top: height,
                  bottom: 0,
                  width: 1,
                  child: ColoredBox(color: ide.border),
                ),
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                height: height,
                child: ClipRect(
                  child: _header(
                    context,
                    tabs,
                    active,
                    showSessions,
                    touch,
                    box.maxWidth,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(
    BuildContext context,
    List<EditorTab> tabs,
    EditorTab? active,
    bool showSessions,
    bool touch,
    double width,
  ) {
    final ws = widget.ws, ide = Ide.of(context);
    final local = ws.entry?.isLocal == true;
    final extra = width >= (touch ? 260 : 190);
    final sidePadding = width >= 160 ? Space.m : Space.xs;
    final showMetadata = width >= 440 && !touch && active != null;
    final label = active?.title ?? '终端';
    final Color glyph = ws.terminalFocused ? ide.accent : ide.textDim;
    final actionSize = touch ? UiMetrics.touchRow : UiMetrics.compactRow;
    return Container(
      key: const ValueKey('terminal-panel-header'),
      padding: EdgeInsets.symmetric(horizontal: sidePadding),
      decoration: BoxDecoration(
        color: ide.frame,
        border: Border(bottom: BorderSide(color: ide.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: WorkbenchMenuButton<String>(
                  key: const ValueKey('terminal-selector'),
                  tooltip: '切换或管理终端会话',
                  enabled: active != null,
                  onSelected: (value) {
                    if (value == '@sessions') {
                      _sessions(!showSessions);
                    } else {
                      _sessions(false);
                      ws.activate(value);
                    }
                  },
                  itemBuilder: (_) => [
                    for (final tab in tabs)
                      CheckedPopupMenuItem(
                        value: tab.id,
                        checked: tab.id == active?.id,
                        child: Text(
                          tab.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (widget.sessionsBuilder != null) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: '@sessions',
                        child: MenuLabel(
                          showSessions ? '返回输出' : '管理全部会话',
                          icon: showSessions
                              ? Icons.terminal_rounded
                              : Icons.list_alt_rounded,
                        ),
                      ),
                    ],
                  ],
                  child: Container(
                    height: touch ? 44 : 28,
                    padding: EdgeInsets.symmetric(
                      horizontal: width >= 160 ? Space.m : Space.xs,
                    ),
                    decoration: active == null
                        ? null
                        : BoxDecoration(
                            color: ide.surface,
                            borderRadius: UiMetrics.controlCorners,
                            border: Border.all(color: ide.border),
                          ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (width >= 100)
                          Icon(Icons.terminal_rounded, size: 16, color: glyph),
                        if (width >= 150) const SizedBox(width: Space.m),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ide.text,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (active != null && width >= 155) ...[
                          const SizedBox(width: Space.s),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 15,
                            color: ide.textDim,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (showMetadata)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Tooltip(
                message: active.tooltip ?? label,
                child: Text(
                  local ? '本机 · PowerShell' : '远程 · tmux',
                  style: TextStyle(color: ide.textFaint, fontSize: 11),
                ),
              ),
            ),
          if (extra && widget.onNew != null)
            IconBtn(
              Icons.add_rounded,
              '新建终端会话（Ctrl+Shift+`）',
              widget.onNew,
              color: ide.accent,
            ),
          SizedBox(
            width: actionSize,
            child: WorkbenchMenuButton<_TerminalAction>(
              key: const ValueKey('terminal-panel-actions'),
              tooltip: '终端操作',
              icon: Icon(
                Icons.more_horiz_rounded,
                size: 19,
                color: ide.textDim,
              ),
              onSelected: (action) {
                switch (action) {
                  case _TerminalAction.create:
                    widget.onNew?.call();
                  case _TerminalAction.maximize:
                    ws.toggleTerminalMaximized();
                  case _TerminalAction.close:
                    if (active != null) ws.closeTab(active.id);
                }
              },
              itemBuilder: (_) => [
                if (!extra && widget.onNew != null)
                  const PopupMenuItem(
                    value: _TerminalAction.create,
                    child: MenuLabel('新建终端会话…', icon: Icons.add_rounded),
                  ),
                PopupMenuItem(
                  value: _TerminalAction.maximize,
                  child: MenuLabel(
                    ws.terminalPanel.maximized ? '还原面板高度' : '最大化终端面板',
                    icon: ws.terminalPanel.maximized
                        ? Icons.close_fullscreen
                        : Icons.open_in_full,
                  ),
                ),
                if (active != null) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: _TerminalAction.close,
                    child: MenuLabel(
                      local ? '结束本地终端…' : '关闭视图（会话继续运行）',
                      icon: local
                          ? Icons.stop_circle_outlined
                          : Icons.close_rounded,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconBtn(
            Icons.keyboard_arrow_down_rounded,
            '隐藏终端面板（会话继续运行，Ctrl+J 再显示）',
            ws.hideTerminalPanel,
            key: const ValueKey('terminal-hide'),
          ),
        ],
      ),
    );
  }
}
