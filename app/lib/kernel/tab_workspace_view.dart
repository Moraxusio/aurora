import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';

import '../theme/ide_theme.dart';
import 'editor_tab.dart';
import 'input_mode.dart';
import 'tab_layout.dart';
import 'widgets.dart';
import 'workspace.dart';

const _gap = 6.0, _header = 30.0;
double _rowOf(BuildContext context) => InputMode.isTouch(context) ? 44 : 34;

String arrangementLabel(EditorArrangement a) => switch (a) {
  EditorArrangement.single => '单编辑组',
  EditorArrangement.columns => '左右两列',
  EditorArrangement.rows => '上下两行',
  EditorArrangement.threeColumns => '三列并排',
  EditorArrangement.grid => '四宫格',
};
String placementLabel(TabPlacement p) => switch (p) {
  TabPlacement.top => '顶部单行',
  TabPlacement.bottom => '底部单行',
  TabPlacement.left => '左侧纵向标签',
  TabPlacement.right => '右侧纵向标签',
  TabPlacement.wrap => '顶部多行',
};

/// The same discoverable menu is available in the title bar and every group.
class TabLayoutMenu extends StatelessWidget {
  final Workspace ws;
  const TabLayoutMenu({super.key, required this.ws});
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '标签与编辑区布局',
    icon: const Icon(Icons.dashboard_customize_outlined, size: 18),
    onSelected: (value) {
      for (final a in EditorArrangement.values) {
        if (value == 'layout:${a.name}') ws.arrangeEditors(a);
      }
      for (final p in TabPlacement.values) {
        if (value == 'tabs:${p.name}') ws.setTabPlacement(p);
      }
      if (value == 'reset') {
        ws.setSideWidth(300);
        ws.setTabsWidth(180);
        ws.setTabWidth(160);
      }
      if (value == 'width') {
        showDialog<void>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialog) => AlertDialog(
              title: const Text('标签宽度'),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('单行 / 多行标签 · ${ws.tabLayout.tabWidth.round()} px'),
                    Slider(
                      value: ws.tabLayout.tabWidth,
                      min: 100,
                      max: 260,
                      divisions: 32,
                      label: '${ws.tabLayout.tabWidth.round()} px',
                      onChanged: (value) {
                        ws.setTabWidth(value);
                        setDialog(() {});
                      },
                    ),
                    const Text(
                      '纵向标签和主侧栏可直接拖动边缘；双击分隔条恢复默认值。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        );
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem<String>(
        enabled: false,
        child: Text('编辑区排布 · 内容不会重新打开'),
      ),
      for (final a in EditorArrangement.values)
        PopupMenuItem(
          value: 'layout:${a.name}',
          child: Text(arrangementLabel(a)),
        ),
      const PopupMenuDivider(),
      for (final p in TabPlacement.values)
        CheckedPopupMenuItem(
          value: 'tabs:${p.name}',
          checked: ws.tabLayout.placement == p,
          child: Text(placementLabel(p)),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'width', child: Text('调整单个标签宽度…')),
      const PopupMenuItem(value: 'reset', child: Text('恢复默认侧栏 / 标签宽度')),
    ],
  );
}

class _TabDrag {
  final Workspace workspace;
  final String project, id;
  const _TabDrag(this.workspace, this.project, this.id);
  bool valid(Workspace ws) =>
      identical(workspace, ws) &&
      project == ws.projectKey &&
      ws.tab(id) != null;
}

class _DividerGeometry {
  final TabSplit split;
  final Rect rect;
  final double extent;
  const _DividerGeometry(this.split, this.rect, this.extent);
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
  Workspace? _workspace;
  int _revision = -1;
  bool _dragging = false;

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
    _bodies.removeWhere((tab, _) => !ws.tabs.contains(tab));
    final ide = Ide.of(context), layout = ws.tabLayout;
    return LayoutBuilder(
      builder: (context, box) {
        final rects = <String, Rect>{}, contents = <String, Rect>{};
        final row = _rowOf(context);
        final dividers = <_DividerGeometry>[];
        final minimum = _minimum(layout.root);
        final compact =
            box.maxWidth < minimum.width || box.maxHeight < minimum.height;
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
          final tabs = ws.tabsInGroup(g.id);
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
          final columns = math.max(1, (rect.width / layout.tabWidth).floor());
          final rows = placement == TabPlacement.wrap
              ? (tabs.length / columns).ceil().clamp(1, 3)
              : 1;
          final strip = math.min(
            row * rows,
            math.max(0.0, rect.height - _header - 60),
          );
          final headerHeight = math.min(_header, rect.height);
          var content = Rect.fromLTWH(
            rect.left,
            rect.top + headerHeight,
            rect.width,
            math.max(0.0, rect.height - headerHeight),
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
                  onDelta: (delta) =>
                      ws.setTabsWidth(width + (left ? delta : -delta)),
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
              rect: Rect.fromLTWH(
                rect.left,
                rect.top,
                rect.width,
                headerHeight,
              ),
              child: _GroupHeader(ws: ws, group: g, compact: compact),
            ),
          );
          chrome.add(
            Positioned.fromRect(
              rect: tabRect,
              child: _TabList(
                key: ValueKey('tab-list-${g.id}'),
                ws: ws,
                group: g,
                vertical: vertical,
                wrap: placement == TabPlacement.wrap,
                onDrag: (value) {
                  if (mounted) setState(() => _dragging = value);
                },
              ),
            ),
          );
          if (g.active == null &&
              (layout.groups.length > 1 || ws.visibleTabs.isNotEmpty)) {
            chrome.add(
              Positioned.fromRect(
                rect: content,
                child: DragTarget<_TabDrag>(
                  onWillAcceptWithDetails: (d) => d.data.valid(ws),
                  onAcceptWithDetails: (d) => ws.moveTab(d.data.id, g.id),
                  builder: (_, candidates, _) => Material(
                    color: candidates.isNotEmpty ? ide.accentSoft : ide.editor,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '将标签拖到这里\n或在此组打开文件 / 终端',
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
                    final group = layout.owner(t.id);
                    final rect = group != null && group.active == t.id
                        ? contents[group.id]
                        : null;
                    final on = rect != null;
                    return Positioned.fromRect(
                      rect: rect ?? bounds,
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
                      d.split.ratio + delta / math.max(1, d.extent),
                    ),
                    onReset: () => ws.resizeGroup(d.split.id, .5),
                  ),
                ),
              if (_dragging)
                for (final item in contents.entries)
                  Positioned.fromRect(
                    rect: item.value,
                    child: _DropZones(ws: ws, group: item.key),
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
            child: ColoredBox(
              color: _hover || _drag
                  ? ide.accent.withValues(alpha: .6)
                  : ide.frame,
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final Workspace ws;
  final TabGroup group;
  final bool compact;
  const _GroupHeader({
    required this.ws,
    required this.group,
    required this.compact,
  });
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context), layout = ws.tabLayout;
    final focused = layout.focused == group.id;
    return Material(
      color: focused ? ide.accentSoft : ide.tabBar,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: PopupMenuButton<String>(
              tooltip: compact && layout.groups.length > 1
                  ? '窄屏聚焦模式 · 切换编辑组（保留原布局）'
                  : '切换编辑组',
              onSelected: ws.focusGroup,
              itemBuilder: (_) => [
                for (var i = 0; i < layout.groups.length; i++)
                  CheckedPopupMenuItem(
                    value: layout.groups[i].id,
                    checked: layout.focused == layout.groups[i].id,
                    child: Text(
                      '编辑组 ${i + 1} · ${ws.tab(layout.groups[i].active ?? '')?.title ?? '空组'}',
                    ),
                  ),
              ],
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${compact && layout.groups.length > 1 ? '聚焦 · ' : ''}编辑组 ${layout.groups.indexOf(group) + 1} · ${group.tabs.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: focused ? ide.accent : ide.textDim,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: _OpenTabsMenu(ws: ws, group: group),
          ),
          SizedBox(width: 28, child: TabLayoutMenu(ws: ws)),
          SizedBox(
            width: 28,
            child: PopupMenuButton<String>(
              tooltip: '编辑组操作',
              icon: const Icon(Icons.more_horiz, size: 16),
              onSelected: (value) {
                if (value == 'right') {
                  ws.splitGroup(SplitAxis.horizontal, group: group.id);
                }
                if (value == 'down') {
                  ws.splitGroup(SplitAxis.vertical, group: group.id);
                }
                if (value == 'merge') ws.mergeGroup(group.id);
                if (value == 'close') ws.closeTabs(group.tabs);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'right',
                  enabled: layout.groups.length < TabLayout.maxGroups,
                  child: const Text('向右拆分此组'),
                ),
                PopupMenuItem(
                  value: 'down',
                  enabled: layout.groups.length < TabLayout.maxGroups,
                  child: const Text('向下拆分此组'),
                ),
                if (layout.groups.length > 1)
                  const PopupMenuItem(
                    value: 'merge',
                    child: Text('合并此组（保留所有标签）'),
                  ),
                const PopupMenuItem(value: 'close', child: Text('关闭此组的未固定标签')),
              ],
            ),
          ),
          const SizedBox(width: 4),
        ],
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
    tooltip: '此组全部标签',
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
  final ValueChanged<bool> onDrag;
  const _TabList({
    super.key,
    required this.ws,
    required this.group,
    required this.vertical,
    required this.wrap,
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
    Widget tab(int index) => DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (d) => d.data.valid(ws),
      onAcceptWithDetails: (d) => ws.moveTab(d.data.id, group.id, index: index),
      builder: (_, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border(
                  left: BorderSide(color: Ide.of(context).accent, width: 3),
                ),
        ),
        child: _TabTile(
          ws: ws,
          tab: tabs[index],
          group: group,
          vertical: widget.vertical,
          onDrag: widget.onDrag,
        ),
      ),
    );
    final end = DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (d) => d.data.valid(ws),
      onAcceptWithDetails: (d) => ws.moveTab(d.data.id, group.id),
      builder: (_, candidates, _) => SizedBox(
        width: widget.vertical ? double.infinity : 40,
        height: row,
        child: candidates.isEmpty
            ? null
            : ColoredBox(color: Ide.of(context).accentSoft),
      ),
    );
    final ide = Ide.of(context);
    return Material(
      color: ide.tabBar,
      child: LayoutBuilder(
        builder: (_, box) {
          _revealActive(group, box, row, width);
          return widget.wrap
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
                  child: ListView.builder(
                    controller: _scroll,
                    scrollDirection: widget.vertical
                        ? Axis.vertical
                        : Axis.horizontal,
                    itemExtent: widget.vertical ? row : width,
                    itemCount: tabs.length + 1,
                    itemBuilder: (_, i) => i == tabs.length ? end : tab(i),
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
  final ValueChanged<bool> onDrag;
  const _TabTile({
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
          '向右拆分',
          () => ws.splitGroup(
            SplitAxis.horizontal,
            group: group.id,
            tabId: tab.id,
          ),
          icon: Icons.vertical_split_outlined,
        ),
        MenuItem(
          '向下拆分',
          () =>
              ws.splitGroup(SplitAxis.vertical, group: group.id, tabId: tab.id),
          icon: Icons.horizontal_split_outlined,
        ),
        for (final g in layout.groups)
          if (g.id != group.id)
            MenuItem(
              '移至编辑组 ${layout.groups.indexOf(g) + 1}',
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
        MenuItem('关闭此组未固定标签', () => ws.closeTabs(group.tabs)),
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
                margin: const EdgeInsets.all(2),
                padding: const EdgeInsets.only(left: 8, right: 3),
                decoration: BoxDecoration(
                  color: on && focused
                      ? ide.tabActive
                      : on || _hover
                      ? ide.hover
                      : null,
                  borderRadius: BorderRadius.circular(6),
                  border: on && focused
                      ? Border(left: BorderSide(color: ide.accent, width: 2))
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(
                      tab.icon,
                      size: 15,
                      color: tab.iconColor ?? (on ? ide.accent : ide.textDim),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
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
    final drag = _TabDrag(ws, ws.projectKey, tab.id);
    final feedback = Material(
      elevation: 6,
      color: ide.surface,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 180,
        height: _rowOf(context),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            tab.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ide.text, fontSize: 12),
          ),
        ),
      ),
    );
    if (InputMode.isTouch(context)) {
      return LongPressDraggable<_TabDrag>(
        data: drag,
        feedback: feedback,
        onDragStarted: () => widget.onDrag(true),
        onDragEnd: (_) => widget.onDrag(false),
        childWhenDragging: Opacity(opacity: .35, child: tile),
        child: tile,
      );
    }
    return Draggable<_TabDrag>(
      data: drag,
      feedback: feedback,
      onDragStarted: () => widget.onDrag(true),
      onDragEnd: (_) => widget.onDrag(false),
      childWhenDragging: Opacity(opacity: .35, child: tile),
      child: tile,
    );
  }
}

class _DropZones extends StatelessWidget {
  final Workspace ws;
  final String group;
  const _DropZones({required this.ws, required this.group});
  @override
  Widget build(BuildContext context) {
    Widget zone(String direction, String label) => DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (d) =>
          d.data.valid(ws) &&
          (direction == 'center' ||
              ws.tabLayout.groups.length < TabLayout.maxGroups),
      onAcceptWithDetails: (d) {
        if (direction == 'center') {
          ws.moveTab(d.data.id, group);
          return;
        }
        ws.splitGroup(
          direction == 'left' || direction == 'right'
              ? SplitAxis.horizontal
              : SplitAxis.vertical,
          group: group,
          tabId: d.data.id,
          before: direction == 'left' || direction == 'up',
        );
      },
      builder: (_, candidates, _) => Container(
        key: ValueKey('drop-$group-$direction'),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Ide.of(context).accent
              .withValues(alpha: candidates.isEmpty ? .06 : .25),
          border: Border.all(
            color: Ide.of(context).accent.withValues(alpha: .45),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(color: Ide.of(context).accent, fontSize: 12),
        ),
      ),
    );
    return Column(
      children: [
        Expanded(child: zone('up', '在上方拆分')),
        Expanded(
          flex: 3,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: zone('left', '左侧')),
              Expanded(flex: 2, child: zone('center', '移入此组')),
              Expanded(child: zone('right', '右侧')),
            ],
          ),
        ),
        Expanded(child: zone('down', '在下方拆分')),
      ],
    );
  }
}
