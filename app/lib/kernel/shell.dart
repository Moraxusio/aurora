// The window: the IDE layout (docs/DESIGN.md D-79).
//
//   wide    activity bar | side bar | editor tabs + content
//   medium  activity bar (icons) | side bar as a drawer | editor tabs + content
//   narrow  one pane at a time: the side bar, or the editor; bottom bar
//
// Widths are decided from the window, not the device, so a resized desktop
// window and a tablet in portrait both end up in the layout that fits.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/monitor/monitor_view.dart';
import '../features/terminal/terminal_feature.dart' show createSession, openSession;
import '../state/app_state.dart';
import '../theme/ide_theme.dart';
import '../ui/add_server.dart';
import '../ui/upgrade_agent.dart';
import 'editor_tab.dart';
import 'feature.dart';
import 'input_mode.dart';
import 'overview.dart';
import 'palette.dart';
import 'registry.dart';
import 'widgets.dart';
import 'workspace.dart';

const double _wide = 900, _narrow = 600;

class Shell extends StatefulWidget {
  final AppState app;
  final Features features;
  const Shell({super.key, required this.app, required this.features});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final Map<String, Workspace> _spaces = {};
  String _featureId = 'terminal';
  bool _sideOpen = true;
  double _sideWidth = 300;
  bool _serversOpen = false;
  int? _mode;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    _onApp();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final w = MediaQuery.sizeOf(context).width;
    final mode = w >= _wide ? 2 : (w >= _narrow ? 1 : 0);
    // Entering the medium layout (a window made narrower, a tablet turned) the
    // side bar starts closed: left open it would become a drawer that dims
    // the editor the moment the window changes.
    if (mode == 1 && _mode != 1) _sideOpen = false;
    _mode = mode;
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    for (final w in _spaces.values) {
      w.dispose();
    }
    super.dispose();
  }

  void _onApp() {
    // workspaces follow the server list
    final ids = {for (final s in app.servers) s.id};
    for (final id in _spaces.keys.toList()) {
      if (!ids.contains(id)) {
        widget.features.forwards.detach(id);
        _spaces.remove(id)?.dispose();
      }
    }
    // forwards follow the link
    for (final id in ids) {
      final l = app.link(id), e = app.server(id);
      if (e == null) continue;
      if (l != null) {
        unawaited(widget.features.forwards.attach(e, l));
      } else {
        unawaited(widget.features.forwards.detach(id));
      }
    }
    if (mounted) setState(() {});
  }

  Workspace? get _ws {
    final id = app.selected;
    if (id == null || app.server(id) == null) return null;
    return _spaces.putIfAbsent(id, () {
      // The first time a server is in front, connect it (the old server page did this).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && app.status(id).state == ConnState.idle) unawaited(app.connect(id));
      });
      return Workspace(app, id);
    });
  }

  Feature get _feature => widget.features.byId(_featureId) ?? widget.features.all.first;

  List<Command> _commands(Workspace? ws) {
    final out = <Command>[
      Command(id: 'server.add', title: '添加服务器…', group: '服务器', icon: Icons.add, run: _addServer),
      for (final s in app.servers)
        Command(id: 'server.go.${s.id}', title: '切换到 ${s.name}', group: '服务器', icon: Icons.dns_outlined, run: () => app.select(s.id)),
    ];
    if (ws != null) {
      out.addAll([
        Command(
          id: 'tab.close',
          title: '关闭当前标签',
          group: '视图',
          icon: Icons.close,
          shortcut: 'Ctrl+W',
          enabled: () => ws.active != null,
          run: () => ws.closeTab(ws.activeId!),
        ),
        Command(id: 'tab.next', title: '下一个标签', group: '视图', shortcut: 'Ctrl+Tab', enabled: () => ws.tabs.length > 1, run: () => ws.next(1)),
        Command(id: 'tab.prev', title: '上一个标签', group: '视图', shortcut: 'Ctrl+Shift+Tab', enabled: () => ws.tabs.length > 1, run: () => ws.next(-1)),
        Command(id: 'side.toggle', title: '显示或隐藏侧栏', group: '视图', shortcut: 'Ctrl+B', run: () => setState(() => _sideOpen = !_sideOpen)),
        Command(id: 'server.overview', title: '服务器概览与设置', group: '服务器', icon: Icons.info_outline, run: () => ws.openTab(overviewTab(ws, widget.features))),
        Command(id: 'server.reconnect', title: '重新连接', group: '服务器', icon: Icons.sync, run: () => app.connect(ws.serverId)),
      ]);
      for (final f in widget.features.all) {
        if (ws.stateOf(f) == FeatureState.available) out.addAll(f.commands(ws));
      }
    }
    return out;
  }

  Future<void> _addServer() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AddServerPage(app: app)));
  }

  void _pick(Workspace ws, Feature f) {
    final st = ws.stateOf(f);
    if (st != FeatureState.available && ws.link != null) {
      // not usable: the side bar explains and offers the fix
      setState(() {
        _featureId = f.id;
        _sideOpen = true;
      });
      return;
    }
    if (f.sideBar(context, ws) == null) {
      f.open(ws);
      return;
    }
    setState(() {
      if (_featureId == f.id && _sideOpen && MediaQuery.sizeOf(context).width >= _wide) {
        _sideOpen = false;
      } else {
        _featureId = f.id;
        _sideOpen = true;
        ws.compactEditor = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = _ws;
    final ide = Ide.of(context);
    final size = MediaQuery.sizeOf(context);
    final mode = size.width >= _wide ? 2 : (size.width >= _narrow ? 1 : 0);
    final cmds = _commands(ws);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): () => showPalette(context, _commands(ws)),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () => setState(() => _sideOpen = !_sideOpen),
        if (ws != null)
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
            if (ws.activeId != null) ws.closeTab(ws.activeId!);
          },
        if (ws != null) const SingleActivator(LogicalKeyboardKey.tab, control: true): () => ws.next(1),
        if (ws != null) const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => ws.next(-1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: ide.editor,
          body: SafeArea(
            child: ws == null
                ? _EmptyShell(app: app, onAdd: _addServer)
                : ListenableBuilder(listenable: ws, builder: (context, _) => _layout(context, ws, mode, cmds, ide)),
          ),
        ),
      ),
    );
  }

  Widget _layout(BuildContext context, Workspace ws, int mode, List<Command> cmds, Ide ide) {
    final side = _SideBar(ws: ws, features: widget.features, feature: _feature, onPickFeature: (f) => _pick(ws, f));
    final editor = _EditorArea(ws: ws, features: widget.features, onAdd: _addServer);
    final activity = _ActivityBar(
      ws: ws,
      features: widget.features,
      current: _sideOpen ? _featureId : null,
      vertical: true,
      onPick: (f) => _pick(ws, f),
      onServers: () => setState(() => _serversOpen = !_serversOpen),
      onPalette: () => showPalette(context, cmds),
      onOverview: () => ws.openTab(overviewTab(ws, widget.features)),
    );
    final status = _StatusBar(ws: ws, app: app, onTapConn: () => app.connect(ws.serverId));
    Widget servers() => _ServerSwitcher(app: app, onClose: () => setState(() => _serversOpen = false), onAdd: _addServer);

    if (mode == 0) {
      // phone: one pane
      final showEditor = ws.compactEditor && ws.tabs.isNotEmpty;
      return Column(
        children: [
          AgentUpgradeNotice(app: app, id: ws.serverId),
          _PhoneTop(
            ws: ws,
            showEditor: showEditor,
            onBack: () => setState(() => ws.compactEditor = false),
            onServers: () => setState(() => _serversOpen = !_serversOpen),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: showEditor ? editor : side),
                if (_serversOpen) Positioned.fill(child: servers()),
              ],
            ),
          ),
          if (!showEditor)
            _ActivityBar(
              ws: ws,
              features: widget.features,
              current: _featureId,
              vertical: false,
              onPick: (f) => _pick(ws, f),
              onServers: () => setState(() => _serversOpen = !_serversOpen),
              onPalette: () => showPalette(context, cmds),
              onOverview: () => ws.openTab(overviewTab(ws, widget.features)),
            ),
          status,
        ],
      );
    }

    final wide = mode == 2;
    return Column(
      children: [
        AgentUpgradeNotice(app: app, id: ws.serverId),
        Expanded(
          child: Row(
            children: [
              activity,
              if (_sideOpen && wide) ...[
                SizedBox(width: _sideWidth, child: side),
                _Splitter(onDrag: (dx) => setState(() => _sideWidth = (_sideWidth + dx).clamp(220, 520))),
              ],
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: editor),
                    // medium: the side bar floats over the editor
                    if (_sideOpen && !wide) ...[
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _sideOpen = false),
                          child: Container(color: Colors.black26),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: 320,
                        child: Material(elevation: 10, color: ide.sideBar, child: side),
                      ),
                    ],
                    if (_serversOpen)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: 300,
                        child: Material(elevation: 10, color: ide.sideBar, child: servers()),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        status,
      ],
    );
  }
}

class _Splitter extends StatelessWidget {
  final void Function(double dx) onDrag;
  const _Splitter({required this.onDrag});
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Container(
          width: 5,
          color: ide.border.withValues(alpha: 0.0),
          child: Center(child: Container(width: 1, color: ide.border)),
        ),
      ),
    );
  }
}

// ---- activity bar ----

class _ActivityBar extends StatelessWidget {
  final Workspace ws;
  final Features features;
  final String? current;
  final bool vertical;
  final void Function(Feature) onPick;
  final VoidCallback onServers, onPalette, onOverview;
  const _ActivityBar({
    required this.ws,
    required this.features,
    required this.current,
    required this.vertical,
    required this.onPick,
    required this.onServers,
    required this.onPalette,
    required this.onOverview,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final touch = InputMode.isTouch(context);
    final box = touch ? 52.0 : 44.0;
    Widget item(IconData icon, String tip, {bool on = false, bool dim = false, VoidCallback? tap, Widget? badge}) => Tooltip(
      message: tip,
      preferBelow: false,
      child: InkWell(
        onTap: tap,
        hoverColor: ide.hover,
        child: SizedBox(
          width: vertical ? 48 : null,
          height: vertical ? box : 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (on)
                Positioned(
                  left: vertical ? 0 : null,
                  top: vertical ? 6 : null,
                  bottom: vertical ? 6 : 0,
                  right: vertical ? null : 8,
                  child: Container(width: vertical ? 2 : null, height: vertical ? null : 2, color: ide.accent),
                ),
              Icon(icon, size: 22, color: on ? ide.text : (dim ? ide.textDim.withValues(alpha: 0.45) : ide.textDim)),
              ?badge,
            ],
          ),
        ),
      ),
    );
    final feats = [
      for (final f in features.all)
        Builder(
          builder: (_) {
            final st = ws.link == null ? FeatureState.available : ws.stateOf(f);
            final usable = st == FeatureState.available || st == FeatureState.loading;
            return item(f.icon, usable ? f.title : '${f.title}（${_stateText(st)}）', on: current == f.id, dim: !usable, tap: () => onPick(f));
          },
        ),
    ];
    final tail = [
      item(Icons.keyboard_command_key, '命令面板（Ctrl+Shift+P）', tap: onPalette),
      item(Icons.dns_outlined, '服务器', tap: onServers),
      item(Icons.tune, '概览与设置', tap: onOverview),
    ];
    if (vertical) {
      return Container(
        width: 48,
        decoration: BoxDecoration(
          color: ide.activityBar,
          border: Border(right: BorderSide(color: ide.border)),
        ),
        child: Column(children: [...feats, const Spacer(), ...tail]),
      );
    }
    // bottom bar: feature icons share the width; the rest sit in a menu
    return Container(
      decoration: BoxDecoration(
        color: ide.activityBar,
        border: Border(top: BorderSide(color: ide.border)),
      ),
      child: Row(
        children: [
          for (final f in feats) Expanded(child: f),
          Expanded(child: item(Icons.more_horiz, '更多', tap: () => _more(context, tail))),
        ],
      ),
    );
  }

  void _more(BuildContext context, List<Widget> tail) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.keyboard_command_key),
              title: const Text('命令面板'),
              onTap: () {
                Navigator.pop(c);
                onPalette();
              },
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('服务器'),
              onTap: () {
                Navigator.pop(c);
                onServers();
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('概览与设置'),
              onTap: () {
                Navigator.pop(c);
                onOverview();
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _stateText(FeatureState s) => switch (s) {
  FeatureState.loading => '正在读取',
  FeatureState.available => '可用',
  FeatureState.disabled => '已关闭',
  FeatureState.unavailable => '不可用',
  FeatureState.outdated => 'agent 版本较旧',
  FeatureState.unreported => 'agent 没有这个服务',
};

// ---- side bar ----

/// The side bar. Each feature's content is built the first time the feature is
/// chosen and then kept, shown with an IndexedStack, as the editor area keeps
/// its tabs. Choosing a feature again does not build its tree again and does
/// not ask the server again: the file tree keeps the folders that are open,
/// the unit list its filter, and nothing flashes a spinner. A new link (after a
/// reconnect) or another server starts every feature afresh, because what was
/// loaded from the old link may be stale.
class _SideBar extends StatefulWidget {
  final Workspace ws;
  final Features features;
  final Feature feature;
  final void Function(Feature) onPickFeature;
  const _SideBar({required this.ws, required this.features, required this.feature, required this.onPickFeature});

  @override
  State<_SideBar> createState() => _SideBarState();
}

class _SideBarState extends State<_SideBar> {
  /// Features that have been shown on this link: only these are built.
  final Set<String> _visited = {};
  final Map<Feature, SideBarView?> _views = {};
  Workspace? _workspace;
  int _revision = -1;
  Link? _link;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _views.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, features = widget.features, feature = widget.feature;
    final ide = Ide.of(context);
    // a different link (reconnect) or none: forget what was built from the old one
    if (!identical(_workspace, ws) || !identical(_link, ws.link)) {
      _workspace = ws;
      _link = ws.link;
      _visited.clear();
      _views.clear();
    }
    if (_revision != ws.viewRevision) {
      _revision = ws.viewRevision;
      _views.clear();
    }
    _visited.add(feature.id);

    // the title and actions of the feature that is shown
    var title = feature.title;
    var actions = const <Widget>[];
    Widget one(Feature f) {
      if (ws.link == null) return NotConnected(ws: ws);
      final st = ws.stateOf(f);
      if (st == FeatureState.loading) return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
      if (st != FeatureState.available) return _Unavailable(ws: ws, feature: f, state: st);
      final v = _views.putIfAbsent(f, () => f.sideBar(context, ws));
      if (v == null) return EmptyHint(icon: f.icon, text: '${f.title}在编辑区里打开', actionLabel: '打开', onAction: () => f.open(ws));
      if (f.id == feature.id) {
        title = v.title;
        actions = v.actions;
      }
      return v.body;
    }

    final order = features.all;
    final children = <Widget>[
      for (final f in order)
        if (_visited.contains(f.id))
          // a stable key per feature and link: the state survives a switch, and a new link starts afresh
          KeyedSubtree(
            key: ValueKey('${ws.serverId}/${f.id}/${identityHashCode(ws.link)}'),
            child: RepaintBoundary(child: one(f)),
          )
        else
          const SizedBox.shrink(),
    ];
    final index = order.indexWhere((f) => f.id == feature.id).clamp(0, order.length - 1);
    return Container(
      color: ide.sideBar,
      child: Column(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ide.textDim, letterSpacing: 0.6),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: index,
              children: [
                for (var k = 0; k < children.length; k++)
                  // a side bar that is not shown gets no ticks and no focus
                  TickerMode(enabled: k == index, child: children[k]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A feature the agent does not offer right now, with the reason and, when it
/// is just switched off, a button to switch it on (D-9, D-26).
class _Unavailable extends StatelessWidget {
  final Workspace ws;
  final Feature feature;
  final FeatureState state;
  const _Unavailable({required this.ws, required this.feature, required this.state});

  @override
  Widget build(BuildContext context) {
    final reason = ws.reasonOf(feature);
    final text = switch (state) {
      FeatureState.disabled => '服务器上的“${feature.title}”服务已关闭。',
      FeatureState.unavailable => '服务器上的“${feature.title}”服务不能用${reason.isEmpty ? '' : '：$reason'}。',
      FeatureState.outdated => '服务器上的 agent 版本较旧，没有“${feature.title}”需要的全部操作。重新安装或配对可以升级它。',
      _ => '服务器上的 agent 没有“${feature.title}”服务。',
    };
    return EmptyHint(
      icon: feature.icon,
      text: text,
      actionLabel: state == FeatureState.disabled ? '打开这个服务' : null,
      onAction: state == FeatureState.disabled
          ? () async {
              await ws.guard(() => ws.link!.call('agent.service', {'id': feature.service, 'enabled': true}));
              await ws.refreshServices();
            }
          : null,
    );
  }
}

// ---- editor area ----

class _EditorArea extends StatefulWidget {
  final Workspace ws;
  final Features features;
  final VoidCallback onAdd;
  const _EditorArea({required this.ws, required this.features, required this.onAdd});

  @override
  State<_EditorArea> createState() => _EditorAreaState();
}

class _EditorAreaState extends State<_EditorArea> {
  final Map<EditorTab, Widget> _bodies = {};
  Workspace? _workspace;
  int _revision = -1;

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, features = widget.features;
    if (!identical(_workspace, ws) || _revision != ws.viewRevision) {
      _workspace = ws;
      _revision = ws.viewRevision;
      _bodies.clear();
    }
    _bodies.removeWhere((tab, _) => !ws.tabs.contains(tab));
    final ide = Ide.of(context);
    if (ws.tabs.isEmpty) return _Welcome(ws: ws, features: features);
    final active = ws.activeId;
    return Column(
      children: [
        _TabStrip(ws: ws),
        Expanded(
          child: Container(
            color: ide.editor,
            // every tab stays built; only the active one is shown, so a terminal
            // keeps its screen and an editor its unsaved text
            child: IndexedStack(
              index: ws.tabs.indexWhere((t) => t.id == active).clamp(0, ws.tabs.length - 1),
              children: [
                for (final t in ws.tabs)
                  TickerMode(
                    key: ObjectKey(t),
                    enabled: t.id == active,
                    child: KeyedSubtree(
                      key: ValueKey(t.id),
                      child: RepaintBoundary(child: _bodies.putIfAbsent(t, () => Builder(builder: t.builder))),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TabStrip extends StatelessWidget {
  final Workspace ws;
  const _TabStrip({required this.ws});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final touch = InputMode.isTouch(context);
    return Container(
      height: touch ? 44 : 34,
      decoration: BoxDecoration(
        color: ide.tabBar,
        border: Border(bottom: BorderSide(color: ide.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [for (final t in ws.tabs) _TabButton(ws: ws, tab: t, active: t.id == ws.activeId)],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final Workspace ws;
  final EditorTab tab;
  final bool active;
  const _TabButton({required this.ws, required this.tab, required this.active});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final touch = InputMode.isTouch(context);
    return ContextArea(
      items: () => [
        MenuItem('关闭', () => ws.closeTab(tab.id), icon: Icons.close, hint: 'Ctrl+W'),
        MenuItem('关闭其它', () async {
          for (final o in ws.tabs.where((x) => x.id != tab.id).toList()) {
            if (!await ws.closeTab(o.id)) break;
          }
        }),
        MenuItem('全部关闭', () async {
          for (final o in ws.tabs.toList()) {
            if (!await ws.closeTab(o.id)) break;
          }
        }),
      ],
      child: Listener(
        // a middle click closes, as in every IDE
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) ws.closeTab(tab.id);
        },
        child: Tooltip(
          message: tab.tooltip ?? tab.title,
          waitDuration: const Duration(milliseconds: 700),
          child: InkWell(
            onTap: () => ws.activate(tab.id),
            hoverColor: active ? Colors.transparent : ide.hover,
            child: Container(
              constraints: BoxConstraints(minWidth: touch ? 110 : 100, maxWidth: 220),
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: active ? ide.tabActive : null,
                border: Border(
                  top: BorderSide(color: active ? ide.accent : Colors.transparent, width: 2),
                  right: BorderSide(color: ide.border),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tab.icon, size: 15, color: tab.iconColor ?? (active ? ide.text : ide.textDim)),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      tab.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: active ? ide.text : ide.textDim),
                    ),
                  ),
                  const SizedBox(width: 4),
                  ValueListenableBuilder<bool>(
                    valueListenable: tab.dirty,
                    builder: (_, dirty, _) => SizedBox(
                      width: touch ? 36 : 22,
                      height: touch ? 36 : 22,
                      child: InkResponse(
                        onTap: () => ws.closeTab(tab.id),
                        radius: 12,
                        hoverColor: ide.hover,
                        child: Center(
                          child: dirty
                              ? Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(color: ide.text, shape: BoxShape.circle),
                                )
                              : Icon(Icons.close, size: 14, color: ide.textDim),
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
    );
  }
}

/// What the editor area shows with no tab open.
class _Welcome extends StatelessWidget {
  final Workspace ws;
  final Features features;
  const _Welcome({required this.ws, required this.features});

  /// The first session if there is one, else a new one.
  Future<void> _openTerminal(BuildContext context) async {
    final link = ws.link;
    if (link == null) return;
    try {
      final r = await link.call('session.list') as Map;
      final list = r['sessions'] as List;
      if (list.isNotEmpty) return openSession(ws, (list.first as Map)['name'] as String);
    } on OpError {
      // fall through to creating one
    }
    if (context.mounted) await createSession(ws, context: context);
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    Future<void> openTerminal() => _openTerminal(context);
    Widget action(IconData i, String t, VoidCallback f) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(i, size: 16, color: ide.accent),
              const SizedBox(width: 10),
              Text(t, style: TextStyle(color: ide.accent)),
            ],
          ),
        ),
      ),
    );
    final connected = ws.link != null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ws.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(connected ? '${ws.link!.server.os} · agent ${ws.link!.server.version}' : '未连接', style: TextStyle(color: ide.textDim)),
            const SizedBox(height: 18),
            if (connected) ...[
              if (ws.stateOf(features.byId('terminal')!) == FeatureState.available) action(Icons.terminal, '打开终端', openTerminal),
              if (ws.stateOf(features.byId('monitor')!) == FeatureState.available)
                action(Icons.monitor_heart_outlined, '查看监控', () => ws.openTab(monitorTab(ws))),
            ] else
              action(Icons.sync, '连接', () => ws.app.connect(ws.serverId)),
            action(Icons.tune, '概览与设置', () => ws.openTab(overviewTab(ws, features))),
            const SizedBox(height: 18),
            Text('Ctrl+Shift+P 打开命令面板', style: TextStyle(color: ide.textDim, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ---- status bar ----

class _StatusBar extends StatelessWidget {
  final Workspace ws;
  final AppState app;
  final VoidCallback onTapConn;
  const _StatusBar({required this.ws, required this.app, required this.onTapConn});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final st = ws.status;
    final (color, text) = switch (st.state) {
      ConnState.connected => (ide.ok, '${ws.name}  ·  ${st.addr ?? ''}'),
      ConnState.connecting => (ide.warn, '${ws.name}  ·  正在连接…'),
      ConnState.waiting => (ide.warn, '${ws.name}  ·  ${st.retryIn?.inSeconds ?? 0} 秒后重试'),
      ConnState.failed => (ide.error, '${ws.name}  ·  ${st.failure?.message ?? '连接失败'}'),
      ConnState.idle => (ide.textDim, '${ws.name}  ·  未连接'),
    };
    return Container(
      height: InputMode.isTouch(context) ? 32 : 24,
      decoration: BoxDecoration(
        color: ide.statusBar,
        border: Border(top: BorderSide(color: ide.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          InkWell(
            onTap: onTapConn,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(color),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Text(
                    text,
                    style: TextStyle(color: ide.statusText, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (ws.active != null)
            ValueListenableBuilder<String>(
              valueListenable: ws.active!.status,
              builder: (_, v, _) => v.isEmpty ? const SizedBox.shrink() : Text(v, style: TextStyle(color: ide.statusText, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

// ---- phone top bar, server switcher, empty shell ----

class _PhoneTop extends StatelessWidget {
  final Workspace ws;
  final bool showEditor;
  final VoidCallback onBack, onServers;
  const _PhoneTop({required this.ws, required this.showEditor, required this.onBack, required this.onServers});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final t = ws.active;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: ide.tabBar,
        border: Border(bottom: BorderSide(color: ide.border)),
      ),
      child: Row(
        children: [
          if (showEditor) IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)) else const SizedBox(width: 12),
          Expanded(
            child: Text(
              showEditor && t != null ? t.title : ws.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showEditor && ws.tabs.length > 1)
            PopupMenuButton<String>(
              tooltip: '切换标签',
              icon: Badge(label: Text('${ws.tabs.length}'), child: const Icon(Icons.tab)),
              onSelected: ws.activate,
              itemBuilder: (_) => [
                for (final x in ws.tabs)
                  PopupMenuItem(
                    value: x.id,
                    child: Row(
                      children: [
                        Icon(x.icon, size: 16),
                        const SizedBox(width: 8),
                        Flexible(child: Text(x.title, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
              ],
            ),
          if (showEditor && t != null) IconButton(onPressed: () => ws.closeTab(t.id), icon: const Icon(Icons.close)),
          if (!showEditor) IconButton(onPressed: onServers, icon: const Icon(Icons.dns_outlined)),
        ],
      ),
    );
  }
}

class _ServerSwitcher extends StatelessWidget {
  final AppState app;
  final VoidCallback onClose, onAdd;
  const _ServerSwitcher({required this.app, required this.onClose, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final p = app.profile;
    return Material(
      color: ide.sideBar,
      child: Column(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '服务器',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ide.textDim, letterSpacing: 0.6),
                  ),
                ),
                IconBtn(Icons.add, '添加服务器', () {
                  onClose();
                  onAdd();
                }),
                IconBtn(Icons.close, '关闭', onClose),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              children: [
                for (final s in p.servers)
                  Builder(
                    builder: (_) {
                      final st = app.status(s.id).state;
                      final color = switch (st) {
                        ConnState.connected => ide.ok,
                        ConnState.failed => ide.error,
                        ConnState.waiting || ConnState.connecting => ide.warn,
                        _ => ide.textDim,
                      };
                      return TreeRow(
                        selected: s.id == p.selected,
                        leading: StatusDot(color),
                        label: s.name,
                        detail: s.ssh?.host,
                        onTap: () {
                          app.select(s.id);
                          onClose();
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyShell extends StatelessWidget {
  final AppState app;
  final VoidCallback onAdd;
  const _EmptyShell({required this.app, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('还没有服务器', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('填写 Linux 服务器的 SSH 地址和账号，Aurora 会通过 SSH 安装 agent，之后直接连接。', style: TextStyle(color: ide.textDim)),
              const SizedBox(height: 20),
              FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add, size: 18), label: const Text('添加服务器')),
            ],
          ),
        ),
      ),
    );
  }
}
