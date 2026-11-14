import 'dart:math' as math;
import 'dart:ui';

import 'tab_layout.dart';

class EditorDivider {
  final TabSplit split;
  final Rect rect;
  final double extent, minRatio, maxRatio;
  const EditorDivider(
    this.split,
    this.rect,
    this.extent,
    this.minRatio,
    this.maxRatio,
  );
}

/// A deterministic constrained grid, independent of widget order or focus.
/// Small changes compress a grid rather than hiding every other group at its
/// aggregate minimum. Only genuinely narrow screens use one-group navigation.
class EditorGridGeometry {
  static const gap = 5.0;
  final Map<String, Rect> groups = {};
  final List<EditorDivider> dividers = [];
  late final bool compact;
  EditorGridGeometry(TabLayout layout, Size size, {bool focusMode = false, bool? compactWindow}) {
    final bounds =
        Offset.zero & Size(math.max(0, size.width), math.max(0, size.height));
    compact = focusMode || (compactWindow ?? (size.width < 600 || size.height < 260)) || size.width < 240 || size.height < 120;
    if (compact) {
      groups[layout.focused] = bounds;
    } else {
      _place(layout.root, bounds);
    }
  }
  Size _minimum(TabNode node) {
    if (node is TabLeaf) return const Size(240, 140);
    final a = _minimum((node as TabSplit).first), b = _minimum(node.second);
    return node.axis == SplitAxis.horizontal
        ? Size(a.width + b.width + gap, math.max(a.height, b.height))
        : Size(math.max(a.width, b.width), a.height + b.height + gap);
  }

  void _place(TabNode node, Rect rect) {
    if (node is TabLeaf) {
      groups[node.group] = rect;
      return;
    }
    final split = node as TabSplit,
        horizontal = split.axis == SplitAxis.horizontal;
    final sash = math.min(gap, horizontal ? rect.width : rect.height);
    final extent = math.max(
      0.0,
      (horizontal ? rect.width : rect.height) - sash,
    );
    final a = _minimum(split.first), b = _minimum(split.second);
    var low = horizontal ? a.width : a.height,
        other = horizontal ? b.width : b.height;
    if (low + other > extent) {
      final scale = extent / (low + other);
      low *= scale;
      other *= scale;
    }
    final high = math.max(low, extent - other);
    final first = (extent * split.ratio).clamp(low, high);
    if (horizontal) {
      _place(
        split.first,
        Rect.fromLTWH(rect.left, rect.top, first, rect.height),
      );
      _place(
        split.second,
        Rect.fromLTWH(
          rect.left + first + sash,
          rect.top,
          extent - first,
          rect.height,
        ),
      );
    } else {
      _place(
        split.first,
        Rect.fromLTWH(rect.left, rect.top, rect.width, first),
      );
      _place(
        split.second,
        Rect.fromLTWH(
          rect.left,
          rect.top + first + sash,
          rect.width,
          extent - first,
        ),
      );
    }
    dividers.add(
      EditorDivider(
        split,
        horizontal
            ? Rect.fromLTWH(rect.left + first, rect.top, sash, rect.height)
            : Rect.fromLTWH(rect.left, rect.top + first, rect.width, sash),
        extent,
        extent == 0 ? .5 : low / extent,
        extent == 0 ? .5 : high / extent,
      ),
    );
  }
}
