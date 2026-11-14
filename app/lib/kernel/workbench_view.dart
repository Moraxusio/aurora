// A VS Code-style workbench: editor grid above, independent terminal panel
// below. Fixed keyed hosts survive hide/maximize, server and window changes.
import 'package:flutter/material.dart';

import 'tab_workspace_view.dart';
import 'terminal_panel_state.dart';
import 'terminal_panel_view.dart';
import 'workbench_geometry.dart';
import 'workspace.dart';
import 'assistant_panel_view.dart';

typedef TerminalSessionsBuilder = Widget Function(VoidCallback onOpened);

class WorkbenchView extends StatefulWidget {
  final Workspace ws;
  final Widget empty;
  final VoidCallback? onNewTerminal;
  final TerminalSessionsBuilder? terminalSessionsBuilder;
  final VoidCallback? onNewAssistant;
  final Widget Function(VoidCallback onOpened)? assistantHistoryBuilder;
  const WorkbenchView({
    super.key,
    required this.ws,
    required this.empty,
    this.onNewTerminal,
    this.terminalSessionsBuilder,
    this.onNewAssistant,
    this.assistantHistoryBuilder,
  });
  @override
  State<WorkbenchView> createState() => _WorkbenchViewState();
}

class _WorkbenchViewState extends State<WorkbenchView> {
  Rect? _editorRect, _terminalRect;
  Rect? _assistantRect;
  bool _assistantVisited = false;
  bool _terminalVisited = false;
  @override
  void initState() {
    super.initState();
    widget.ws.geometryRevision.addListener(_geometryChanged);
  }

  @override
  void didUpdateWidget(WorkbenchView old) {
    super.didUpdateWidget(old);
    if (old.ws != widget.ws) {
      old.ws.geometryRevision.removeListener(_geometryChanged);
      widget.ws.geometryRevision.addListener(_geometryChanged);
      _editorRect = _terminalRect = null;
      _terminalVisited = false;
      _assistantRect = null;
      _assistantVisited = false;
    }
  }

  void _geometryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.ws.geometryRevision.removeListener(_geometryChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, box) {
      final ws = widget.ws, panel = ws.terminalPanel;
      final geometry = WorkbenchGeometry(
        size: box.biggest,
        panelVisible: panel.visible,
        panelFocused: ws.terminalFocused,
        panelMaximized: panel.maximized,
        preferredHeight: panel.height,
        assistantVisible: ws.assistantPanel.visible,
        assistantFocused: ws.assistantFocused,
        assistantMaximized: ws.assistantPanel.maximized,
        assistantWidth: ws.assistantPanel.width,
      );
      final bounds = Offset.zero & box.biggest;
      if (geometry.assistant != null) {
        _assistantRect = geometry.assistant;
        _assistantVisited = true;
      }
      if (geometry.editor != null) _editorRect = geometry.editor;
      if (geometry.terminal != null) {
        _terminalRect = geometry.terminal;
        _terminalVisited = true;
      }
      Widget region(String key, Rect rect, bool shown, Widget child) =>
          Positioned.fromRect(
            key: ValueKey('$key-host'),
            rect: rect,
            child: Offstage(
              offstage: !shown,
              child: ClipRect(
                key: ValueKey(key),
                child: TickerMode(
                  enabled: shown,
                  child: ExcludeFocus(excluding: !shown, child: child),
                ),
              ),
            ),
          );
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          region(
            'workbench-editor',
            _editorRect ?? bounds,
            geometry.editor != null,
            TabWorkspaceView(ws: ws, empty: widget.empty),
          ),
          region(
            'workbench-terminal',
            _terminalRect ?? bounds,
            geometry.terminal != null,
            _terminalVisited
                ? TerminalPanelView(
                    ws: ws,
                    onNew: widget.onNewTerminal,
                    sessionsBuilder: widget.terminalSessionsBuilder,
                  )
                : const SizedBox.shrink(),
          ),
          region(
            'workbench-assistant',
            _assistantRect ?? bounds,
            geometry.assistant != null,
            _assistantVisited
                ? AssistantPanelView(
                    ws: ws,
                    onNew: widget.onNewAssistant,
                    historyBuilder: widget.assistantHistoryBuilder,
                  )
                : const SizedBox.shrink(),
          ),
          if (geometry.assistantDivider != null)
            Positioned.fromRect(
              rect: geometry.assistantDivider!,
              child: TabResizeHandle(
                key: const ValueKey('assistant-panel-resize'),
                axis: Axis.horizontal,
                label: '调整 AI 侧栏宽度',
                value: geometry.assistant!.width,
                reverse: true,
                onChanged: ws.setAssistantWidth,
                onReset: () => ws.setAssistantWidth(420),
              ),
            ),
          if (geometry.divider != null)
            Positioned.fromRect(
              rect: geometry.divider!,
              child: TabResizeHandle(
                key: const ValueKey('terminal-panel-resize'),
                axis: Axis.vertical,
                label: '调整终端面板高度',
                value: geometry.terminal!.height,
                reverse: true,
                onChanged: ws.setTerminalHeight,
                onReset: () =>
                    ws.setTerminalHeight(TerminalPanelState.defaultHeight),
              ),
            ),
        ],
      );
    },
  );
}
