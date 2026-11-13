import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show
        kMiddleMouseButton,
        kPrimaryMouseButton,
        PointerScrollEvent,
        GestureBinding;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/ide_theme.dart';
import 'editor_tab.dart';
import 'tab_drag.dart';
import 'tab_layout_menu.dart';
import 'input_mode.dart';
import 'tab_layout.dart';
import 'widgets.dart';
import 'workspace.dart';

export 'tab_layout_menu.dart'
    show TabLayoutMenu, arrangementLabel, placementLabel;

const _gap = 5.0;
double _rowOf(BuildContext context) => InputMode.isTouch(context) ? 44 : 36;

class _DividerGeometry {
  final TabSplit split;
  final Rect rect;
  final double extent;
  final double minRatio, maxRatio;
  const _DividerGeometry(
    this.split,
    this.rect,
    this.extent,
    this.minRatio,
    this.maxRatio,
  );
}

/// All document bodies stay direct, keyed siblings in ONE stack. Even changing
/// orientation, group count, sidebar width or phone size cannot unmount them.
class TabWorkspaceView extends StatefulWidget {
  final Workspace ws;
  final Widget empty;
  const TabWorkspaceView({super.key, required this.ws, required this.empty});
  @override
  State<TabWorkspaceView> createState() => _TabWorkspaceViewState();
}

class _TabWorkspaceViewState extends State<TabWorkspaceView> {
  final Map<EditorTab, Widget> _bodies = {};
  final Map<EditorTab, Rect> _lastRects = {};
  final _drag = ValueNotifier<TabDragData?>(null);
  Workspace? _workspace;
  int _revision = -1;
  @override
  void initState() {
    super.initState();
    widget.ws.geometryRevision.addListener(_reflow);
  }

  @override
  void didUpdateWidget(TabWorkspaceView old) {
    super.didUpdateWidget(old);
    if (old.ws != widget.ws) {
      old.ws.geometryRevision.removeListener(_reflow);
      widget.ws.geometryRevision.addListener(_reflow);
      _lastRects.clear();
    }
  }

  void _reflow() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.ws.geometryRevision.removeListener(_reflow);
    _drag.dispose();
    super.dispose();
  }

  Size _minimum(TabNode node) {
    if (node is TabLeaf) return const Size(260, 160);
    final s = node as TabSplit,
        a = _minimum((node).first),
        b = _minimum(node.second);
    return s.axis == SplitAxis.horizontal
        ? Size(a.width + b.width + _gap, math.max(a.height, b.height))
        : Size(math.max(a.width, b.width), a.height + b.height + _gap);
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws;
    if (!identical(_workspace, ws) || _revision != ws.viewRevision) {
      _workspace = ws;
      _revision = ws.viewRevision;
      _bodies.clear();
    }
    final live = ws.tabs.toSet();
    _bodies.removeWhere((tab, _) => !live.contains(tab));
    _lastRects.removeWhere((tab, _) => !live.contains(tab));
    final tabsById = {for (final t in ws.tabs) t.id: t};
    final ide = Ide.of(context), layout = ws.tabLayout;
    return LayoutBuilder(
      builder: (context, box) {
        final rects = <String, Rect>{}, contents = <String, Rect>{};
        final row = _rowOf(context);
        final dividers = <_DividerGeometry>[];
        final minimum = _minimum(layout.root);
        final compact =
            box.maxWidth < minimum.width ||
            box.maxHeight < minimum.height ||
            ws.focusMode;
        void place(TabNode node, Rect rect) {
          if (node is TabLeaf) {
            rects[node.group] = rect;
            return;
          }
          final split = node as TabSplit;
          final horizontal = split.axis == SplitAxis.horizontal;
          final extent = (horizontal ? rect.width : rect.height) - _gap;
          final aMin = _minimum(split.first), bMin = _minimum(split.second);
          final low = horizontal ? aMin.width : aMin.height,
              high = extent - (horizontal ? bMin.width : bMin.height);
          final first = (extent * split.ratio)
              .clamp(math.min(low, high), math.max(low, high))
              .toDouble();
          if (horizontal) {
            place(
              split.first,
              Rect.fromLTWH(rect.left, rect.top, first, rect.height),
            );
            place(
              split.second,
              Rect.fromLTWH(
                rect.left + first + _gap,
                rect.top,
                extent - first,
                rect.height,
              ),
            );
            dividers.add(
              _DividerGeometry(
                split,
                Rect.fromLTWH(rect.left + first, rect.top, _gap, rect.height),
                extent,
                low / extent,
                high / extent,
              ),
            );
          } else {
            place(
              split.first,
              Rect.fromLTWH(rect.left, rect.top, rect.width, first),
            );
            place(
              split.second,
              Rect.fromLTWH(
                rect.left,
                rect.top + first + _gap,
                rect.width,
                extent - first,
              ),
            );
            dividers.add(
              _DividerGeometry(
                split,
                Rect.fromLTWH(rect.left, rect.top + first, rect.width, _gap),
                extent,
                low / extent,
                high / extent,
              ),
            );
          }
        }

        final bounds = Offset.zero & Size(box.maxWidth, box.maxHeight);
        if (compact) {
          rects[layout.current.id] = bounds;
        } else {
          place(layout.root, bounds);
        }
        final chrome = <Widget>[];
        for (final g in layout.groups) {
          final rect = rects[g.id];
          if (rect == null) continue;
          final tabs = [for (final id in g.tabs) ?tabsById[id]];
          final requested = layout.placement;
          final vertical =
              (requested == TabPlacement.left ||
                  requested == TabPlacement.right) &&
              rect.width >= 500;
          final placement =
              vertical ||
                  requested == TabPlacement.bottom ||
                  requested == TabPlacement.wrap
              ? requested
              : TabPlacement.top;
          final width = vertical
              ? layout.tabsWidth
                    .clamp(120.0, math.min(400.0, rect.width - 280))
                    .toDouble()
              : rect.width;
          final railSpace = 64 + (compact && layout.groups.length > 1 ? 42 : 0);
          final columns = math.max(
            1,
            ((rect.width - railSpace) / layout.tabWidth).floor(),
          );
          final rows = placement == TabPlacement.wrap
              ? (tabs.length / columns).ceil().clamp(1, 3)
              : 1;
          final strip = math.min(row * rows, math.max(0.0, rect.height - 60));
          var content = Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width,
            rect.height,
          );
          Rect tabRect;
          if (vertical) {
            final left = placement == TabPlacement.left;
            tabRect = Rect.fromLTWH(
              left ? rect.left : rect.right - width,
              content.top,
              width,
              content.height,
            );
            final dividerRect = Rect.fromLTWH(
              left ? tabRect.right : tabRect.left - _gap,
              content.top,
              _gap,
              content.height,
            );
            content = Rect.fromLTWH(
              left ? dividerRect.right : rect.left,
              content.top,
              math.max(0.0, rect.width - width - _gap),
              content.height,
            );
            chrome.add(
              Positioned.fromRect(
                rect: dividerRect,
                child: TabResizeHandle(
                  key: ValueKey('tabs-resize-${g.id}'),
                  axis: Axis.horizontal,
                  label: '调整纵向标签宽度',
                  onDelta: (delta) => ws.setTabsWidth(
                    layout.tabsWidth.clamp(
                          120.0,
                          math.min(400.0, rect.width - 280),
                        ) +
                        (left ? delta : -delta),
                  ),
                  onReset: () => ws.setTabsWidth(180),
                ),
              ),
            );
          } else {
            final bottom = placement == TabPlacement.bottom;
            tabRect = Rect.fromLTWH(
              rect.left,
              bottom ? rect.bottom - strip : content.top,
              rect.width,
              strip,
            );
            content = Rect.fromLTWH(
              rect.left,
              bottom ? content.top : content.top + strip,
              rect.width,
              math.max(0.0, content.height - strip),
            );
          }
          contents[g.id] = content;
          chrome.add(
            Positioned.fromRect(
              rect: tabRect,
              child: _PaneBar(
                key: ValueKey('tab-list-${g.id}'),
                ws: ws,
                group: g,
                vertical: vertical,
                wrap: placement == TabPlacement.wrap,
                compact: compact,
                drag: _drag,
                onDrag: (data) {
                  if (mounted) _drag.value = data;
                },
              ),
            ),
          );
          if (g.active == null &&
              (layout.groups.length > 1 || ws.visibleTabs.isNotEmpty)) {
            chrome.add(
              Positioned.fromRect(
                rect: content,
                child: DragTarget<TabDragData>(
                  onWillAcceptWithDetails: (d) => d.data.valid(ws),
                  onAcceptWithDetails: (d) => ws.moveTab(d.data.tab.id, g.id),
                  builder: (_, candidates, _) => Material(
                    color: candidates.isNotEmpty ? ide.accentSoft : ide.editor,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '拖入标签，或在这里打开文件',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: ide.textDim, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        }
        final owners = {
          for (final group in layout.groups)
            for (final id in group.tabs) id: group,
        };
        return Material(
          color: ide.editor,
          child: Stack(
            children: [
              if (ws.visibleTabs.isEmpty && layout.groups.length == 1)
                Positioned.fill(child: widget.empty),
              ...chrome,
              for (final t in ws.tabs)
                Builder(
                  key: ObjectKey(t),
                  builder: (_) {
                    final group = owners[t.id];
                    final rect = group != null && group.active == t.id
                        ? contents[group.id]
                        : null;
                    final on = rect != null;
                    if (rect != null) _lastRects[t] = rect;
                    return Positioned.fromRect(
                      rect: rect ?? _lastRects.putIfAbsent(t, () => bounds),
                      child: Offstage(
                        offstage: !on,
                        child: TickerMode(
                          enabled: on,
                          child: ExcludeFocus(
                            excluding: !on,
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: (_) {
                                if (group != null) ws.focusGroup(group.id);
                              },
                              child: _TabFocusFrame(
                                request: on && layout.current.active == t.id
                                    ? ws.editorFocusRequest
                                    : -1,
                                child: RepaintBoundary(
                                  child: _bodies.putIfAbsent(
                                    t,
                                    () => Builder(builder: t.builder),
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
              for (final d in dividers)
                Positioned.fromRect(
                  rect: d.rect,
                  child: TabResizeHandle(
                    key: ValueKey('group-resize-${d.split.id}'),
                    axis: d.split.axis == SplitAxis.horizontal
                        ? Axis.horizontal
                        : Axis.vertical,
                    label: '调整编辑组大小',
                    onDelta: (delta) => ws.resizeGroup(
                      d.split.id,
                      d.split.ratio.clamp(d.minRatio, d.maxRatio) +
                          delta / math.max(1, d.extent),
                    ),
                    onReset: () => ws.resizeGroup(d.split.id, .5),
                  ),
                ),
              Positioned.fill(
                child: ValueListenableBuilder<TabDragData?>(
                  valueListenable: _drag,
                  builder: (_, data, _) => data == null || !data.valid(ws)
                      ? const SizedBox.shrink()
                      : Stack(
                          children: [
                            for (final item in contents.entries)
                              Positioned.fromRect(
                                rect: item.value,
                                child: PaneDropTarget(ws: ws, group: item.key),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TabFocusFrame extends StatefulWidget {
  final int request;
  final Widget child;
  const _TabFocusFrame({required this.request, required this.child});
  @override
  State<_TabFocusFrame> createState() => _TabFocusFrameState();
}

class _TabFocusFrameState extends State<_TabFocusFrame> {
  final _scope = FocusScopeNode();
  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(_TabFocusFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) _request();
  }

  void _request() {
    final serial = widget.request;
    if (serial < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.request == serial && !_scope.hasFocus) {
        _scope.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FocusScope(node: _scope, child: widget.child);
}

/// Mouse, keyboard and screen-reader operable; a double click resets the size.
class TabResizeHandle extends StatefulWidget {
  final Axis axis;
  final String label;
  final ValueChanged<double> onDelta;
  final VoidCallback onReset;
  const TabResizeHandle({
    super.key,
    required this.axis,
    required this.label,
    required this.onDelta,
    required this.onReset,
  });
  @override
  State<TabResizeHandle> createState() => _TabResizeHandleState();
}

class _TabResizeHandleState extends State<TabResizeHandle> {
  bool _hover = false, _drag = false;
  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal, ide = Ide.of(context);
    return Semantics(
      label: widget.label,
      onIncrease: () => widget.onDelta(16),
      onDecrease: () => widget.onDelta(-16),
      child: MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: widget.onReset,
          onHorizontalDragStart: horizontal
              ? (_) => setState(() => _drag = true)
              : null,
          onHorizontalDragUpdate: horizontal
              ? (d) => widget.onDelta(d.delta.dx)
              : null,
          onHorizontalDragEnd: horizontal
              ? (_) => setState(() => _drag = false)
              : null,
          onHorizontalDragCancel: horizontal
              ? () => setState(() => _drag = false)
              : null,
          onVerticalDragStart: !horizontal
              ? (_) => setState(() => _drag = true)
              : null,
          onVerticalDragUpdate: !horizontal
              ? (d) => widget.onDelta(d.delta.dy)
              : null,
          onVerticalDragEnd: !horizontal
              ? (_) => setState(() => _drag = false)
              : null,
          onVerticalDragCancel: !horizontal
              ? () => setState(() => _drag = false)
              : null,
          child: SizedBox.expand(
            child: Center(
              child: SizedBox(
                width: horizontal ? (_hover || _drag ? 2 : 1) : double.infinity,
                height: horizontal
                    ? double.infinity
                    : (_hover || _drag ? 2 : 1),
                child: ColoredBox(
                  color: _hover || _drag
                      ? ide.accent.withValues(alpha: .7)
                      : ide.border,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaneBar extends StatelessWidget {
  final Workspace ws;
  final TabGroup group;
  final bool compact, vertical, wrap;
  final ValueNotifier<TabDragData?> drag;
  final ValueChanged<TabDragData?> onDrag;
  const _PaneBar({
    super.key,
    required this.ws,
    required this.group,
    required this.compact,
    required this.vertical,
    required this.wrap,
    required this.drag,
    required this.onDrag,
  });
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context), layout = ws.tabLayout, row = _rowOf(context);
    final switcher = compact && layout.groups.length > 1
        ? SizedBox(
            width: 42,
            height: row,
            child: PopupMenuButton<String>(
              tooltip: '切换视图',
              padding: EdgeInsets.zero,
              onSelected: ws.focusGroup,
              itemBuilder: (_) => [
                for (var i = 0; i < layout.groups.length; i++)
                  CheckedPopupMenuItem(
                    value: layout.groups[i].id,
                    checked: layout.focused == layout.groups[i].id,
                    child: Text(
                      '${i + 1}  ${ws.tab(layout.groups[i].active ?? '')?.title ?? '空视图'}',
                    ),
                  ),
              ],
              child: Center(
                child: Text(
                  '${layout.groups.indexOf(group) + 1}/${layout.groups.length}',
                  style: TextStyle(fontSize: 11, color: ide.textDim),
                ),
              ),
            ),
          )
        : null;
    final actions = SizedBox(
      width: 32,
      height: row,
      child: PopupMenuButton<String>(
        tooltip: '视图操作',
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_horiz, size: 17),
        onSelected: (value) {
          if (value == 'right') {
            ws.splitGroup(SplitAxis.horizontal, group: group.id);
          }
          if (value == 'down') {
            ws.splitGroup(SplitAxis.vertical, group: group.id);
          }
          if (value == 'merge') ws.mergeGroup(group.id);
          if (value == 'close') ws.closeTabs(group.tabs);
          if (value == 'layout') showTabLayoutDialog(context, ws);
          if (value == 'focus') {
            ws.focusGroup(group.id);
            ws.toggleFocusMode();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'right',
            enabled: layout.groups.length < TabLayout.maxGroups,
            child: const Text('向右分屏'),
          ),
          PopupMenuItem(
            value: 'down',
            enabled: layout.groups.length < TabLayout.maxGroups,
            child: const Text('向下分屏'),
          ),
          if (layout.groups.length > 1) ...[
            PopupMenuItem(
              value: 'focus',
              child: Text(ws.focusMode ? '还原分屏' : '放大当前视图'),
            ),
            const PopupMenuItem(value: 'merge', child: Text('合并此视图（保留标签）')),
          ],
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'layout', child: Text('标签栏与布局…')),
          const PopupMenuItem(value: 'close', child: Text('关闭未固定标签')),
        ],
      ),
    );
    final strip = _TabList(
      ws: ws,
      group: group,
      vertical: vertical,
      wrap: wrap,
      drag: drag,
      onDrag: onDrag,
    );
    return Material(
      color: ide.tabBar,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: vertical
              ? null
              : Border(bottom: BorderSide(color: ide.border)),
        ),
        child: vertical
            ? Column(
                children: [
                  SizedBox(
                    height: row,
                    child: Row(
                      children: [
                        ?switcher,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '标签',
                            style: TextStyle(
                              fontSize: 11,
                              color: ide.textFaint,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 28,
                          child: _OpenTabsMenu(ws: ws, group: group),
                        ),
                        actions,
                      ],
                    ),
                  ),
                  Expanded(child: strip),
                ],
              )
            : LayoutBuilder(
                builder: (_, box) {
                  final overflow =
                      !wrap &&
                      group.tabs.length * layout.tabWidth >
                          box.maxWidth - 32 - (switcher != null ? 42 : 0);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ?switcher,
                      Expanded(child: strip),
                      if (overflow)
                        SizedBox(
                          width: 28,
                          height: row,
                          child: _OpenTabsMenu(ws: ws, group: group),
                        ),
                      actions,
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _OpenTabsMenu extends StatelessWidget {
  final Workspace ws;
  final TabGroup group;
  const _OpenTabsMenu({required this.ws, required this.group});
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '所有标签',
    icon: const Icon(Icons.expand_more, size: 17),
    onSelected: ws.activate,
    itemBuilder: (_) => [
      for (final t in ws.tabsInGroup(group.id))
        CheckedPopupMenuItem(
          value: t.id,
          checked: group.active == t.id,
          child: SizedBox(
            width: 220,
            child: Text(
              '${ws.tabLayout.pinned.contains(t.id) ? '📌 ' : ''}${t.title}${t.dirty.value ? ' ●' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
    ],
  );
}

class _TabList extends StatefulWidget {
  final Workspace ws;
  final TabGroup group;
  final bool vertical, wrap;
  final ValueListenable<TabDragData?> drag;
  final ValueChanged<TabDragData?> onDrag;
  const _TabList({
    required this.ws,
    required this.group,
    required this.vertical,
    required this.wrap,
    required this.drag,
    required this.onDrag,
  });
  @override
  State<_TabList> createState() => _TabListState();
}

class _TabListState extends State<_TabList> {
  final _scroll = ScrollController();
  Object? _revealSignature;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _revealActive(
    TabGroup group,
    BoxConstraints box,
    double row,
    double width,
  ) {
    final index = group.tabs.indexOf(group.active ?? '');
    final signature = (
      group.active,
      index,
      widget.vertical,
      widget.wrap,
      box.maxWidth,
      box.maxHeight,
      row,
      width,
    );
    if (_revealSignature == signature) return;
    _revealSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _revealSignature != signature ||
          !_scroll.hasClients ||
          index < 0) {
        return;
      }
      final columns = math.max(1, (box.maxWidth / width).floor());
      final extent = widget.vertical || widget.wrap ? row : width;
      final start = (widget.wrap ? index ~/ columns : index) * extent;
      final end = start + extent, position = _scroll.position;
      if (start < position.pixels) {
        _scroll.jumpTo(start.clamp(0, position.maxScrollExtent));
      } else if (end > position.pixels + position.viewportDimension) {
        _scroll.jumpTo(
          (end - position.viewportDimension).clamp(0, position.maxScrollExtent),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws,
        group = widget.group,
        tabs = ws.tabsInGroup(group.id),
        width = ws.tabLayout.tabWidth;
    final row = _rowOf(context);
    Widget tab(int index) => _TabTile(
      key: ObjectKey(tabs[index]),
      ws: ws,
      tab: tabs[index],
      group: group,
      vertical: widget.vertical,
      onDrag: widget.onDrag,
    );
    final end = SizedBox(
      width: widget.vertical ? double.infinity : 40,
      height: row,
    );
    final ide = Ide.of(context);
    return Material(
      color: ide.tabBar,
      child: LayoutBuilder(
        builder: (_, box) {
          _revealActive(group, box, row, width);
          final list = widget.wrap
              ? Builder(
                  builder: (_) {
                    final itemWidth = math.min(width, box.maxWidth);
                    return SingleChildScrollView(
                      controller: _scroll,
                      child: Wrap(
                        children: [
                          for (var i = 0; i < tabs.length; i++)
                            SizedBox(
                              width: itemWidth,
                              height: row,
                              child: tab(i),
                            ),
                          end,
                        ],
                      ),
                    );
                  },
                )
              : Scrollbar(
                  controller: _scroll,
                  thickness: widget.vertical ? 4 : 2,
                  child: ListView.builder(
                    controller: _scroll,
                    scrollDirection: widget.vertical
                        ? Axis.vertical
                        : Axis.horizontal,
                    itemExtent: widget.vertical ? row : width,
                    itemCount: tabs.length + 1,
                    findChildIndexCallback: (key) {
                      if (key is! ObjectKey || key.value is! EditorTab) {
                        return null;
                      }
                      final index = tabs.indexOf(key.value as EditorTab);
                      return index < 0 ? null : index;
                    },
                    itemBuilder: (_, i) => i == tabs.length ? end : tab(i),
                  ),
                );
          return TabStripDropTarget(
            ws: ws,
            group: group,
            scroll: _scroll,
            vertical: widget.vertical,
            wrap: widget.wrap,
            width: width,
            row: row,
            drag: widget.drag,
            child: Listener(
              onPointerSignal: (event) {
                if (widget.vertical ||
                    widget.wrap ||
                    event is! PointerScrollEvent ||
                    !_scroll.hasClients) {
                  return;
                }
                GestureBinding.instance.pointerSignalResolver.register(event, (
                  _,
                ) {
                  if (mounted && _scroll.hasClients) {
                    _scroll.position.pointerScroll(
                      event.scrollDelta.dx != 0
                          ? event.scrollDelta.dx
                          : event.scrollDelta.dy,
                     );
                  }
                });
              },
              child: list,
            ),
          );
        },
      ),
    );
  }
}

class _TabTile extends StatefulWidget {
  final Workspace ws;
  final EditorTab tab;
  final TabGroup group;
  final bool vertical;
  final ValueChanged<TabDragData?> onDrag;
  const _TabTile({
    super.key,
    required this.ws,
    required this.tab,
    required this.group,
    required this.vertical,
    required this.onDrag,
  });
  @override
  State<_TabTile> createState() => _TabTileState();
}

class _TabTileState extends State<_TabTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ws = widget.ws,
        tab = widget.tab,
        group = widget.group,
        layout = ws.tabLayout;
    final ide = Ide.of(context),
        on = group.active == tab.id,
        focused = group.id == layout.focused;
    final pin = layout.pinned.contains(tab.id);
    final tile = ContextArea(
      items: () => [
        MenuItem(
          pin ? '取消固定' : '固定标签',
          () => ws.pinTab(tab.id),
          icon: pin ? Icons.push_pin : Icons.push_pin_outlined,
        ),
        MenuItem(
          '向右分屏',
          () => ws.splitGroup(
            SplitAxis.horizontal,
            group: group.id,
            tabId: tab.id,
          ),
          icon: Icons.vertical_split_outlined,
        ),
        MenuItem(
          '向下分屏',
          () =>
              ws.splitGroup(SplitAxis.vertical, group: group.id, tabId: tab.id),
          icon: Icons.horizontal_split_outlined,
        ),
        for (final g in layout.groups)
          if (g.id != group.id)
            MenuItem(
              '移到视图 ${layout.groups.indexOf(g) + 1}',
              () => ws.moveTab(tab.id, g.id),
            ),
        const MenuItem.separator(),
        MenuItem(
          '关闭',
          () => ws.closeTab(tab.id),
          icon: Icons.close,
          hint: 'Ctrl+W',
        ),
        MenuItem(
          '关闭其它（保留固定）',
          () => ws.closeTabs(group.tabs.where((id) => id != tab.id)),
        ),
        MenuItem(
          '关闭右侧 / 后续标签',
          () => ws.closeTabs(group.tabs.skip(group.tabs.indexOf(tab.id) + 1)),
        ),
        MenuItem('关闭未固定标签', () => ws.closeTabs(group.tabs)),
      ],
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) ws.closeTab(tab.id);
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Tooltip(
            message: tab.tooltip ?? tab.title,
            child: GestureDetector(
              onTap: () => ws.activate(tab.id),
              child: Container(
                key: ValueKey('tab-${tab.id}'),
                height: _rowOf(context),
                margin: widget.vertical
                    ? const EdgeInsets.symmetric(horizontal: 5, vertical: 1)
                    : EdgeInsets.zero,
                padding: const EdgeInsets.only(left: 12, right: 5),
                decoration: BoxDecoration(
                  color: on
                      ? ide.editor
                      : _hover
                      ? ide.hover
                      : null,
                  borderRadius: widget.vertical
                      ? BorderRadius.circular(5)
                      : null,
                  border: on && focused
                      ? (widget.vertical
                            ? Border(
                                left: BorderSide(color: ide.accent, width: 2),
                              )
                            : Border(
                                top: BorderSide(color: ide.accent, width: 2),
                              ))
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(
                      tab.icon,
                      size: 15,
                      color: tab.iconColor ?? ide.textDim,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: on ? ide.text : ide.textDim,
                        ),
                      ),
                    ),
                    if (pin)
                      Padding(
                        padding: const EdgeInsets.only(left: 3),
                        child: Icon(
                          Icons.push_pin,
                          size: 12,
                          color: ide.textDim,
                        ),
                      ),
                    ValueListenableBuilder<bool>(
                      valueListenable: tab.dirty,
                      builder: (_, dirty, _) => SizedBox(
                        width: InputMode.isTouch(context) ? 38 : 24,
                        height: InputMode.isTouch(context) ? 40 : 28,
                        child: Semantics(
                          button: true,
                          label: '关闭 ${tab.title}${dirty ? '（有未保存修改）' : ''}',
                          child: InkResponse(
                            onTap: () => ws.closeTab(tab.id),
                            child: Center(
                              child: dirty && !_hover
                                  ? Icon(
                                      Icons.circle,
                                      size: 7,
                                      color: ide.textDim,
                                    )
                                  : Opacity(
                                      opacity:
                                          on ||
                                              _hover ||
                                              InputMode.isTouch(context)
                                          ? 1
                                          : 0,
                                      child: Icon(
                                        Icons.close,
                                        size: 14,
                                        color: ide.textDim,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final drag = TabDragData(ws, tab);
    final feedback = Transform.translate(
      offset: const Offset(12, 12),
      child: Material(
        elevation: 4,
        color: ide.surface,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 180,
          height: _rowOf(context),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Icon(tab.icon, size: 15, color: tab.iconColor ?? ide.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: ide.text, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (InputMode.isTouch(context)) {
      return LongPressDraggable<TabDragData>(
        data: drag,
        feedback: feedback,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        maxSimultaneousDrags: 1,
        onDragStarted: () => widget.onDrag(drag),
        onDragEnd: (_) => widget.onDrag(null),
        childWhenDragging: Opacity(opacity: .35, child: tile),
        child: tile,
      );
    }
    return Draggable<TabDragData>(
      data: drag,
      feedback: feedback,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
      maxSimultaneousDrags: 1,
      onDragStarted: () => widget.onDrag(drag),
      onDragEnd: (_) => widget.onDrag(null),
      childWhenDragging: Opacity(opacity: .35, child: tile),
      child: tile,
    );
  }
}
