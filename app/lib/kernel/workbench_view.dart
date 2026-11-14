// A VS Code-style workbench: editor grid above, independent terminal panel
// below. Fixed keyed hosts survive hide/maximize, server and window changes.
import 'package:flutter/material.dart';

import 'tab_workspace_view.dart';
import 'terminal_panel_state.dart';
import 'terminal_panel_view.dart';
import 'workbench_geometry.dart';
import 'workspace.dart';
import 'assistant_panel_view.dart';
import 'retained_pane.dart';

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
  late Widget _editorView;
  Widget? _terminalView, _assistantView;
  bool _assistantVisited = false;
  bool _terminalVisited = false;
  @override
  void initState() {
    super.initState();
    _updateViews();
    widget.ws.geometryRevision.addListener(_geometryChanged);
  }

  @override
  void didUpdateWidget(WorkbenchView old) {
    super.didUpdateWidget(old);
    _updateViews();
    if (old.ws != widget.ws) {
      old.ws.geometryRevision.removeListener(_geometryChanged);
      widget.ws.geometryRevision.addListener(_geometryChanged);
      _terminalVisited = false;
      _assistantVisited = false;
    }
  }

  void _updateViews() {
    _editorView = TabWorkspaceView(ws: widget.ws, empty: widget.empty);
    _terminalView = _assistantView = null;
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
        _assistantVisited = true;
      }
      if (geometry.terminal != null) {
        _terminalVisited = true;
      }
      Widget region(String key, Rect rect, bool shown, Widget child) =>
          Positioned.fromRect(
            key: ValueKey('$key-host'),
            rect: rect,
            child: RetainedPane(
              visible: shown,
              viewportKey: ValueKey(key),
              child: child,
            ),
          );
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          region(
            'workbench-editor',
            geometry.editor ?? bounds,
            geometry.editor != null,
            _editorView,
          ),
          region(
            'workbench-terminal',
            geometry.terminal ?? bounds,
            geometry.terminal != null,
            _terminalVisited
                ? _terminalView ??= TerminalPanelView(
                    ws: ws,
                    onNew: widget.onNewTerminal,
                    sessionsBuilder: widget.terminalSessionsBuilder,
                  )
                : const SizedBox.shrink(),
          ),
          region(
            'workbench-assistant',
            geometry.assistant ?? bounds,
            geometry.assistant != null,
            _assistantVisited
                ? _assistantView ??= AssistantPanelView(
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
