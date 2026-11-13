import 'dart:math' as math;
import 'dart:ui';

/// The editor grid and terminal panel own disjoint rectangles. Compact windows
/// temporarily show the focused region; this never rewrites the editor tree.
class WorkbenchGeometry {
  static const dividerSize = 5.0, minimumEditorHeight = 200.0;
  final Rect? editor, terminal, divider;
  final bool compact;
  const WorkbenchGeometry._(
    this.editor,
    this.terminal,
    this.divider,
    this.compact,
  );

  factory WorkbenchGeometry({
    required Size size,
    required bool panelVisible,
    required bool panelFocused,
    required bool panelMaximized,
    required double preferredHeight,
  }) {
    final width = size.width.isFinite ? math.max(0.0, size.width) : 0.0;
    final height = size.height.isFinite ? math.max(0.0, size.height) : 0.0;
    final bounds = Rect.fromLTWH(0, 0, width, height);
    final compact = width < 600 || height < 360;
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
