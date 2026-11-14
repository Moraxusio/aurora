// Dragging is transient presentation state, not a workspace mutation. Only a
// completed drop changes the layout. Pointer motion repaints one small overlay.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/ide_theme.dart';
import 'editor_tab.dart';
import 'tab_layout.dart';
import 'workspace.dart';

class TabDragData {
  final Workspace workspace;
  final String project;
  final int generation;
  final EditorTab tab;
  final TabLayout layout;
  final int revision;
  bool cancelled = false;
  TabDragData(this.workspace, this.tab)
    : project = workspace.projectKey,
      generation = workspace.projectGeneration,
      layout = workspace.tabLayout,
      revision = workspace.tabLayout.revision;
  bool valid(Workspace ws) =>
      identical(workspace, ws) &&
      project == ws.projectKey &&
      generation == ws.projectGeneration &&
      identical(ws.tab(tab.id), tab) &&
      !cancelled &&
      identical(layout, ws.tabLayout) &&
      revision == layout.revision &&
      tab.isEditor &&
      ws.tabLayout.owner(tab.id) != null;
}

/// VS Code's editor drop contract: center moves, outer 10% splits. Direction
/// selection is normalized, so corner behavior is not biased by pane aspect.
class TabDropPolicy {
  static TabDropEdge? resolve(
    TabDragData data,
    Workspace ws,
    String group,
    Size size,
    Offset p,
  ) {
    if (!data.valid(ws) ||
        ws.tabLayout.group(group) == null ||
        !(Offset.zero & size).contains(p) ||
        size.isEmpty) {
      return null;
    }
    final source = ws.tabLayout.owner(data.tab.id)!;
    final x = p.dx / size.width, y = p.dy / size.height;
    if (x > .1 && x < .9 && y > .1 && y < .9) {
      return source.id == group ? null : TabDropEdge.center;
    }
    if (source.id == group && source.tabs.length == 1) return null;
    if (ws.tabLayout.groups.length >= TabLayout.maxGroups &&
        source.tabs.length > 1) {
      return null;
    }
    final edge = x < 1 / 3
        ? TabDropEdge.left
        : x > 2 / 3
        ? TabDropEdge.right
        : y < .5
        ? TabDropEdge.top
        : TabDropEdge.bottom;
    final horizontal = edge == TabDropEdge.left || edge == TabDropEdge.right;
    if ((horizontal ? size.width < 420 : size.height < 280)) {
      return source.id == group ? null : TabDropEdge.center;
    }
    return edge;
  }
}

class PaneDropTarget extends StatefulWidget {
  final Workspace ws;
  final String group;
  const PaneDropTarget({super.key, required this.ws, required this.group});
  @override
  State<PaneDropTarget> createState() => _PaneDropTargetState();
}

class _PaneDropTargetState extends State<PaneDropTarget> {
  TabDropEdge? _edge;
  TabDropEdge? _intent(TabDragData data, Offset global) {
    final box = context.findRenderObject() as RenderBox;
    return TabDropPolicy.resolve(
      data,
      widget.ws,
      widget.group,
      box.size,
      box.globalToLocal(global),
    );
  }

  void _move(DragTargetDetails<TabDragData> d) {
    final next = _intent(d.data, d.offset);
    if (next != _edge) setState(() => _edge = next);
  }

  @override
  Widget build(BuildContext context) => DragTarget<TabDragData>(
    hitTestBehavior: HitTestBehavior.opaque,
    onWillAcceptWithDetails: (d) {
      _move(d);
      // Acceptance is stable for the gesture. A drag can enter at the center
      // (no-op here) and later move to a valid edge without re-entering.
      return d.data.valid(widget.ws);
    },
    onMove: _move,
    onLeave: (_) {
      if (_edge != null) setState(() => _edge = null);
    },
    onAcceptWithDetails: (d) {
      final edge = _intent(d.data, d.offset);
      setState(() => _edge = null);
      if (edge == null) return;
      widget.ws.dropEditorTab(d.data.tab.id, widget.group, edge);
    },
    builder: (_, _, _) => SizedBox.expand(
      key: ValueKey('pane-drop-${widget.group}'),
      child: _edge == null
          ? null
          : RepaintBoundary(
              child: CustomPaint(
                key: ValueKey('drop-preview-${widget.group}'),
                painter: _PanePreview(_edge!, Ide.of(context)),
              ),
            ),
    ),
  );
}

class _PanePreview extends CustomPainter {
  final TabDropEdge edge;
  final Ide ide;
  const _PanePreview(this.edge, this.ide);
  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final rect = switch (edge) {
      TabDropEdge.left => Rect.fromLTWH(0, 0, size.width / 2, size.height),
      TabDropEdge.right => Rect.fromLTWH(
        size.width / 2,
        0,
        size.width / 2,
        size.height,
      ),
      TabDropEdge.top => Rect.fromLTWH(0, 0, size.width, size.height / 2),
      TabDropEdge.bottom => Rect.fromLTWH(
        0,
        size.height / 2,
        size.width,
        size.height / 2,
      ),
      TabDropEdge.center => full,
    };
    final shape = RRect.fromRectAndRadius(
      rect.deflate(5),
      const Radius.circular(7),
    );
    canvas.drawRRect(shape, Paint()..color = ide.accent.withValues(alpha: .13));
    canvas.drawRRect(
      shape,
      Paint()
        ..color = ide.accent.withValues(alpha: .65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_PanePreview old) => old.edge != edge || old.ide != ide;
}

/// One target for the entire strip, rather than one target per tab. Scrolling
/// while dragging uses a ticker and a paint-only insertion marker, never JSON
/// snapshots or editor rebuilds. Works for mouse and long-press touch drags.
class TabStripDropTarget extends StatefulWidget {
  final Workspace ws;
  final TabGroup group;
  final ScrollController scroll;
  final bool vertical, wrap;
  final double width, row;
  final ValueListenable<TabDragData?> drag;
  final Widget child;
  const TabStripDropTarget({
    super.key,
    required this.ws,
    required this.group,
    required this.scroll,
    required this.vertical,
    required this.wrap,
    required this.width,
    required this.row,
    required this.drag,
    required this.child,
  });
  @override
  State<TabStripDropTarget> createState() => _TabStripDropTargetState();
}

class _TabStripDropTargetState extends State<TabStripDropTarget>
    with SingleTickerProviderStateMixin {
  final _slot = ValueNotifier<int?>(null);
  late final Ticker _ticker = createTicker(_tick);
  Duration? _previous;
  DragTargetDetails<TabDragData>? _pointer;
  double _velocity = 0;
  @override
  void initState() {
    super.initState();
    widget.drag.addListener(_dragChanged);
  }

  @override
  void didUpdateWidget(TabStripDropTarget old) {
    super.didUpdateWidget(old);
    if (old.drag != widget.drag) {
      old.drag.removeListener(_dragChanged);
      widget.drag.addListener(_dragChanged);
    }
  }

  void _dragChanged() {
    if (widget.drag.value == null) _clear();
  }

  void _clear() {
    _pointer = null;
    _slot.value = null;
    _velocity = 0;
    _ticker.stop();
    _previous = null;
  }

  void _move(DragTargetDetails<TabDragData> d) {
    if (!d.data.valid(widget.ws) ||
        !identical(widget.ws.tabLayout.group(widget.group.id), widget.group) ||
        !widget.scroll.hasClients) {
      return _clear();
    }
    _pointer = d;
    final box = context.findRenderObject() as RenderBox;
    final p = box.globalToLocal(d.offset), size = box.size;
    if (size.width <= 0 || size.height <= 0) return _clear();
    final across = widget.vertical || widget.wrap ? p.dy : p.dx;
    final extent = widget.vertical || widget.wrap ? size.height : size.width;
    final scroll = widget.scroll.position;
    final offset = across + scroll.pixels;
    var at = 0;
    if (widget.wrap) {
      final columns = math.max(1, (size.width / widget.width).floor());
      final column = (p.dx / math.min(widget.width, size.width)).floor().clamp(
        0,
        columns - 1,
      );
      final after =
          p.dx % math.min(widget.width, size.width) >=
          math.min(widget.width, size.width) / 2;
      at = (offset / widget.row).floor() * columns + column + (after ? 1 : 0);
    } else {
      at = (offset / (widget.vertical ? widget.row : widget.width) + .5)
          .floor();
    }
    final pins = widget.group.tabs
        .where(widget.ws.tabLayout.pinned.contains)
        .length;
    at = widget.ws.tabLayout.pinned.contains(d.data.tab.id)
        ? at.clamp(0, pins)
        : at.clamp(pins, widget.group.tabs.length);
    _slot.value = at;
    const edge = 36.0;
    _velocity = across < edge && scroll.pixels > 0
        ? -500 * (1 - across.clamp(0, edge) / edge)
        : across > extent - edge && scroll.pixels < scroll.maxScrollExtent
        ? 500 * (1 - (extent - across).clamp(0, edge) / edge)
        : 0;
    if (_velocity != 0 && !_ticker.isActive) {
      _previous = null;
      _ticker.start();
    }
    if (_velocity == 0) {
      _ticker.stop();
      _previous = null;
    }
  }

  void _tick(Duration elapsed) {
    final previous = _previous ?? elapsed;
    _previous = elapsed;
    if (_pointer == null || !widget.scroll.hasClients) return _clear();
    final p = widget.scroll.position;
    final seconds =
        (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    widget.scroll.jumpTo(
      (p.pixels + _velocity * seconds.clamp(0, .05)).clamp(
        0,
        p.maxScrollExtent,
      ),
    );
    _move(_pointer!);
  }

  @override
  void dispose() {
    widget.drag.removeListener(_dragChanged);
    _ticker.dispose();
    _slot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DragTarget<TabDragData>(
    onWillAcceptWithDetails: (d) {
      _move(d);
      return d.data.valid(widget.ws);
    },
    onMove: _move,
    onLeave: (_) => _clear(),
    onAcceptWithDetails: (d) {
      _move(d);
      final slot = _slot.value;
      _clear();
      if (slot != null && d.data.valid(widget.ws)) {
        widget.ws.dropEditorTab(
          d.data.tab.id,
          widget.group.id,
          TabDropEdge.center,
          index: slot,
        );
      }
    },
    builder: (_, _, _) => Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _InsertionMarker(
                  _slot,
                  widget.scroll,
                  widget.vertical,
                  widget.wrap,
                  widget.width,
                  widget.row,
                  Ide.of(context).accent,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _InsertionMarker extends CustomPainter {
  final ValueListenable<int?> slot;
  final ScrollController scroll;
  final bool vertical, wrap;
  final double width, row;
  final Color color;
  _InsertionMarker(
    this.slot,
    this.scroll,
    this.vertical,
    this.wrap,
    this.width,
    this.row,
    this.color,
  ) : super(repaint: Listenable.merge([slot, scroll]));
  @override
  void paint(Canvas canvas, Size size) {
    if (slot.value == null || !scroll.hasClients) return;
    final index = slot.value!, offset = scroll.offset;
    final columns = math.max(1, (size.width / width).floor());
    final start = vertical
        ? Offset(2, index * row - offset)
        : wrap
        ? Offset(
            index % columns * math.min(width, size.width),
            index ~/ columns * row - offset,
          )
        : Offset(index * width - offset, 3);
    final end = vertical
        ? Offset(size.width - 2, start.dy)
        : Offset(start.dx, start.dy + row - 6);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InsertionMarker old) =>
      old.vertical != vertical ||
      old.wrap != wrap ||
      old.width != width ||
      old.row != row ||
      old.color != color;
}
