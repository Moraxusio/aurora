import 'dart:math' as math;
import 'dart:ui';

/// The editor grid and terminal panel own disjoint rectangles. Compact windows
/// temporarily show the focused region; this never rewrites the editor tree.
class WorkbenchGeometry {
  static const dividerSize = 5.0, minimumEditorHeight = 200.0;
  final Rect? editor, terminal, divider, assistant, assistantDivider;
  final bool compact;
  const WorkbenchGeometry._(
    this.editor,
    this.terminal,
    this.divider,
    this.compact, [
    this.assistant,
    this.assistantDivider,
  ]);

  factory WorkbenchGeometry({
    required Size size,
    required bool panelVisible,
    required bool panelFocused,
    required bool panelMaximized,
    required double preferredHeight,
    bool assistantVisible = false,
    bool assistantFocused = false,
    bool assistantMaximized = false,
    double assistantWidth = 420,
    bool besideAssistant = false,
  }) {
    final width = size.width.isFinite ? math.max(0.0, size.width) : 0.0;
    final height = size.height.isFinite ? math.max(0.0, size.height) : 0.0;
    final bounds = Rect.fromLTWH(0, 0, width, height);
    // A desktop editor column beside AI is not a phone. The assistant already
    // reserves >=420px for it, enough for vertically stacked editor/terminal.
    final compact = (!besideAssistant && width < 600) || height < 360;
    if (assistantVisible) {
      if (assistantMaximized || width < 880) {
        if (assistantFocused || assistantMaximized) {
          return WorkbenchGeometry._(null, null, null, true, bounds);
        }
      } else {
        final dock = (assistantWidth.isFinite ? assistantWidth : 420.0)
            .clamp(320.0, math.min(800.0, width - 420.0 - dividerSize))
            .toDouble();
        final rest = WorkbenchGeometry(
          size: Size(width - dock - dividerSize, height),
          panelVisible: panelVisible,
          panelFocused: panelFocused,
          panelMaximized: panelMaximized,
          preferredHeight: preferredHeight,
          besideAssistant: true,
        );
        return WorkbenchGeometry._(
          rest.editor,
          rest.terminal,
          rest.divider,
          rest.compact,
          Rect.fromLTWH(width - dock, 0, dock, height),
          Rect.fromLTWH(width - dock - dividerSize, 0, dividerSize, height),
        );
      }
    }
    if (!panelVisible) return WorkbenchGeometry._(bounds, null, null, compact);
    if (compact) {
      return panelFocused
          ? WorkbenchGeometry._(null, bounds, null, true)
          : WorkbenchGeometry._(bounds, null, null, true);
    }
    if (panelMaximized) return WorkbenchGeometry._(null, bounds, null, false);
    final maximum = height - minimumEditorHeight - dividerSize;
    final panelHeight = (preferredHeight.isFinite ? preferredHeight : 260.0)
        .clamp(120.0, maximum);
    final top = height - panelHeight;
    return WorkbenchGeometry._(
      Rect.fromLTWH(0, 0, width, top - dividerSize),
      Rect.fromLTWH(0, top, width, panelHeight),
      Rect.fromLTWH(0, top - dividerSize, width, dividerSize),
      false,
    );
  }
}
