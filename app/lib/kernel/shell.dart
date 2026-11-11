// The window: the IDE layout (docs/DESIGN.md D-79, D-103).
//
//   wide    title bar / rail | side bar island | editor island / status bar
//   medium  title bar / rail | editor island (side bar floats over it) / status bar
//   narrow  one pane at a time: the side bar, or the editor; bottom bar
//
// The rail, title bar and status bar sit on the window frame; the side bar
// and the editor are islands on it (rounded, a gap between them). Widths are
// decided from the window, not the device, so a resized desktop window and a
// tablet in portrait both end up in the layout that fits.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/monitor/monitor_view.dart';
import '../features/search/quick_open.dart';
import '../features/terminal/terminal_feature.dart' show createSession, openSession;
import '../state/app_state.dart';
import '../theme/ide_theme.dart';
import '../ui/add_server.dart';
import '../ui/settings_page.dart';
import '../ui/upgrade_agent.dart';
import 'desktop_lifecycle.dart';
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
  late final Future<bool> Function() _exitGuard = _beforeExit;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    DesktopLifecycle.beforeExit = _exitGuard;
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
    if (DesktopLifecycle.beforeExit == _exitGuard) DesktopLifecycle.beforeExit = null;
    app.removeListener(_onApp);
    for (final w in _spaces.values) {
      w.dispose();
    }
    super.dispose();
  }

  Future<bool> _beforeExit() async {
    if (!mounted) return false;
    if (widget.features.transfers.active > 0) {
      final ok = await confirmDialog(context, title: '还有文件正在传输',
        body: '${widget.features.transfers.active} 个传输尚未完成。退出客户端会中断这些传输。点窗口的叉只隐藏到托盘，不会中断。', ok: '仍然退出');
      if (!ok || !mounted) return false;
    }
    // Do not close any tab until every check passed: cancelling a later
    // prompt must not destroy a buffer whose earlier prompt said discard.
    for (final ws in _spaces.values.toList()) {
      for (final tab in ws.tabs.toList()) {
        if (tab.dirty.value && tab.confirmClose != null && !await tab.confirmClose!()) return false;
        if (!mounted) return false;
      }
    }
    for (final ws in _spaces.values.toList()) {
      if (!await ws.flushViews()) return false;
    }
    return true;
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
      final ws = Workspace(app, id);
      // Ctrl+Shift+F or the palette: bring the search view to the front; it
      // takes the focus itself once it is built.
      ws.focusSearch.addListener(() {
        final f = widget.features.byId('search');
        if (mounted && f != null && app.selected == id) _pick(ws, f, open: true);
      });
      return ws;
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
          run: () => ws.closeTab(ws.active!.id),
        ),
        Command(
          id: 'editor.split',
          title: '向右拆分编辑器 / 取消拆分',
          group: '视图',
          icon: Icons.vertical_split_outlined,
          shortcut: 'Ctrl+\\',
          enabled: () => ws.visibleTabs.length > 1 || ws.split,
          run: ws.splitActive,
        ),
        Command(id: 'app.settings', title: '设置（主题、字号、自动换行）', group: '设置', icon: Icons.settings_outlined, run: () => ws.openTab(settingsTab(app))),
        Command(id: 'tab.next', title: '下一个标签', group: '视图', shortcut: 'Ctrl+Tab', enabled: () => ws.visibleTabs.length > 1, run: () => ws.next(1)),
        Command(id: 'tab.prev', title: '上一个标签', group: '视图', shortcut: 'Ctrl+Shift+Tab', enabled: () => ws.visibleTabs.length > 1, run: () => ws.next(-1)),
        Command(id: 'side.toggle', title: '显示或隐藏侧栏', group: '视图', icon: Icons.view_sidebar_outlined, shortcut: 'Ctrl+B', run: _toggleSide),
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

  void _toggleSide() => setState(() => _sideOpen = !_sideOpen);

  bool _usable(Workspace ws, String id) {
    final f = widget.features.byId(id);
    return f != null && ws.stateOf(f) == FeatureState.available;
  }

  /// Quick open when the server offers search, else the command palette.
  void _find(Workspace ws) => _usable(ws, 'search') ? showQuickOpen(ws, context: context) : showPalette(context, _commands(ws));

  /// Shows [f]'s side bar. [open]: never close it when it is already in
  /// front (a shortcut such as Ctrl+Shift+F only ever opens).
  void _pick(Workspace ws, Feature f, {bool open = false}) {
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
      if (!open && _featureId == f.id && _sideOpen && MediaQuery.sizeOf(context).width >= _wide) {
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
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): _toggleSide,
        if (ws != null)
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
            final t = ws.active;
            if (t != null) ws.closeTab(t.id);
          },
        if (ws != null && MediaQuery.sizeOf(context).width >= _narrow)
          const SingleActivator(LogicalKeyboardKey.backslash, control: true): ws.splitActive,
        if (ws != null && _usable(ws, 'search'))
          const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => showQuickOpen(ws, context: context),
        if (ws != null && _usable(ws, 'search'))
          const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => ws.focusSearch.value++,
        if (ws != null) const SingleActivator(LogicalKeyboardKey.tab, control: true): () => ws.next(1),
        if (ws != null) const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => ws.next(-1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: ide.frame,
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
    final narrow = mode == 0;
    final wide = mode == 2;
    final gap = narrow ? 0.0 : Space.gap;
    final side = _SideBar(ws: ws, features: widget.features, feature: _feature, onPickFeature: (f) => _pick(ws, f));
    final editor = IndexedStack(index: _spaces.values.toList().indexOf(ws), children: [
      for (final space in _spaces.values)
        TickerMode(key: ObjectKey(space), enabled: identical(space, ws),
          child: ExcludeFocus(excluding: !identical(space, ws), child: ListenableBuilder(listenable: space,
            builder: (_, _) => _EditorArea(ws: space, features: widget.features, onAdd: _addServer,
              onPalette: () => showPalette(context, _commands(space)), onFind: () => _find(space))))),
    ]);
    void servers() => setState(() => _serversOpen = !_serversOpen);
    final status = _StatusBar(ws: ws, app: app, onTapConn: () => app.connect(ws.serverId));
    final showEditor = !narrow || (ws.compactEditor && ws.visibleTabs.isNotEmpty);
    final sideShown = _sideOpen && wide;

    final body = Column(
      children: [
        AgentUpgradeNotice(app: app, id: ws.serverId),
        if (narrow)
          _PhoneTop(ws: ws, showEditor: showEditor, onBack: () => setState(() => ws.compactEditor = false), onServers: servers)
        else
          _TitleBar(
            ws: ws,
            searchable: _usable(ws, 'search'),
            sideOpen: _sideOpen,
            onServers: servers,
            onFind: () => _find(ws),
            onPalette: () => showPalette(context, cmds),
            onToggleSide: _toggleSide,
          ),
        Expanded(
          key: const ValueKey('main-content'),
          child: Row(
            children: [
              if (!narrow)
                _ActivityBar(
                  ws: ws,
                  features: widget.features,
                  current: _sideOpen ? _featureId : null,
                  vertical: true,
                  onPick: (f) => _pick(ws, f),
                  onServers: servers,
                  onPalette: () => showPalette(context, cmds),
                  onOverview: () => ws.openTab(overviewTab(ws, widget.features)),
                ),
              if (sideShown) ...[
                SizedBox(width: _sideWidth, child: _Island(child: side)),
                _Splitter(width: gap, onDrag: (dx) => setState(() => _sideWidth = (_sideWidth + dx).clamp(220, 560))),
              ],
              Expanded(
                key: const ValueKey('editor-slot'),
                child: Padding(
                  padding: EdgeInsets.only(right: gap),
                  child: _Island(
                    flat: narrow,
                    child: Stack(
                      children: [
                        // Keep this subtree at the same keyed position for every
                        // width/server. A narrow side bar must not unmount dirty
                        // editors or disconnect terminal streams.
                        Positioned.fill(key: const ValueKey('editor-fill'),
                          child: ExcludeFocus(excluding: !showEditor, child: Offstage(offstage: !showEditor,
                            child: TickerMode(enabled: showEditor, child: editor)))),
                        if (narrow && !showEditor) Positioned.fill(child: side),
                        // medium: the side bar floats over the editor
                        if (_sideOpen && mode == 1) ...[
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _sideOpen = false),
                              child: ColoredBox(color: Colors.black.withValues(alpha: ide.isDark ? 0.35 : 0.12)),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: 320,
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: ide.sideBar, border: Border(right: BorderSide(color: ide.border)), boxShadow: ide.float),
                              child: side,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (narrow && !showEditor) _ActivityBar(ws: ws, features: widget.features, current: _featureId, vertical: false,
          onPick: (f) => _pick(ws, f), onServers: servers,
          onPalette: () => showPalette(context, cmds), onOverview: () => ws.openTab(overviewTab(ws, widget.features))),
        status,
      ],
    );
    final width = MediaQuery.sizeOf(context).width;
    return Stack(children: [
      Positioned.fill(child: body),
      if (_serversOpen) ...[
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => setState(() => _serversOpen = false))),
        Positioned(
          left: narrow ? Space.m : 52,
          top: narrow ? 52 : 38,
          width: narrow ? width - Space.m * 2 : 340,
          child: _ServerSwitcher(app: app, onClose: () => setState(() => _serversOpen = false), onAdd: _addServer),
        ),
      ],
    ]);
  }
}

/// A rounded panel on the window frame; [flat] (phones) fills the space.
class _Island extends StatelessWidget {
  final Widget child;
  final bool flat;
  const _Island({required this.child, this.flat = false});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ide.editor,
        borderRadius: BorderRadius.circular(flat ? 0 : Radii.island),
        border: flat ? null : Border.all(color: ide.border),
      ),
      child: child,
    );
  }
}

/// The gap between the side bar and the editor; drag it to resize. A line
/// shows on hover so the handle can be found.
class _Splitter extends StatefulWidget {
  final double width;
  final void Function(double dx) onDrag;
  const _Splitter({required this.width, required this.onDrag});
  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
  bool _hover = false, _drag = false;
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final on = _hover || _drag;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _drag = true),
        onHorizontalDragEnd: (_) => setState(() => _drag = false),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        child: SizedBox(
          width: widget.width,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 2,
              margin: const EdgeInsets.symmetric(vertical: Space.xxl),
              decoration: BoxDecoration(color: on ? ide.accent.withValues(alpha: 0.7) : Colors.transparent, borderRadius: BorderRadius.circular(1)),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- title bar ----

/// The top of the window: the server (and project) in front, the find box in
/// the middle, layout buttons on the right.
class _TitleBar extends StatelessWidget {
  final Workspace ws;
  final bool searchable, sideOpen;
  final VoidCallback onServers, onFind, onPalette, onToggleSide;
  const _TitleBar({
    required this.ws,
    required this.searchable,
    required this.sideOpen,
    required this.onServers,
    required this.onFind,
    required this.onPalette,
    required this.onToggleSide,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final project = ws.project;
    final canSplit = ws.visibleTabs.length > 1 || ws.split;
    return SizedBox(
      height: 40,
      child: Row(children: [
        SizedBox(
          width: 48,
          child: Center(child: Image.asset('assets/branding/aurora3-256.png', width: 18, height: 18, semanticLabel: 'Aurora 3')),
        ),
        Tooltip(
          message: '切换服务器',
          child: InkWell(
            onTap: onServers,
            borderRadius: BorderRadius.circular(Radii.m),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                StatusDot(connColor(ide, ws.status.state), size: 7),
                const SizedBox(width: Space.m),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(ws.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.text)),
                ),
                if (project != null) ...[
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('/', style: TextStyle(color: ide.textFaint, fontSize: 13))),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: ide.textDim)),
                  ),
                ],
                const SizedBox(width: 2),
                Icon(Icons.expand_more_rounded, size: 16, color: ide.textFaint),
              ]),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.l),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: _FindBox(searchable: searchable, onTap: onFind),
              ),
            ),
          ),
        ),
        IconBtn(sideOpen ? Icons.view_sidebar : Icons.view_sidebar_outlined, '显示或隐藏侧栏（Ctrl+B）', onToggleSide),
        IconBtn(Icons.vertical_split_outlined, ws.split ? '取消拆分（Ctrl+\\）' : '向右拆分编辑器（Ctrl+\\）', canSplit ? ws.splitActive : null,
          color: ws.split ? ide.accent : null),
        IconBtn(Icons.keyboard_command_key, '命令面板（Ctrl+Shift+P）', onPalette),
        const SizedBox(width: Space.s),
      ]),
    );
  }
}

/// The box in the middle of the title bar: a button that looks like a search
/// field and opens quick open (or the palette).
class _FindBox extends StatefulWidget {
  final bool searchable;
  final VoidCallback onTap;
  const _FindBox({required this.searchable, required this.onTap});
  @override
  State<_FindBox> createState() => _FindBoxState();
}

class _FindBoxState extends State<_FindBox> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 28,
          padding: const EdgeInsets.only(left: Space.m + 2, right: Space.s),
          decoration: BoxDecoration(
            color: _hover ? ide.hover : ide.editor,
            borderRadius: BorderRadius.circular(Radii.m),
            border: Border.all(color: _hover ? ide.borderStrong : ide.border),
          ),
          child: Row(children: [
            Icon(Icons.search_rounded, size: 15, color: ide.textFaint),
            const SizedBox(width: Space.m),
            Expanded(
              child: Text(widget.searchable ? '搜索文件、输入命令' : '输入命令',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: ide.textFaint)),
            ),
            KeyCaps(widget.searchable ? 'Ctrl+P' : 'Ctrl+Shift+P'),
          ]),
        ),
      ),
    );
  }
}

/// The colour of a connection state.
Color connColor(Ide ide, ConnState s) => switch (s) {
  ConnState.connected => ide.ok,
  ConnState.failed => ide.error,
  ConnState.waiting || ConnState.connecting => ide.warn,
  ConnState.idle => ide.textFaint,
};

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
    Widget rail(IconData icon, String tip, {bool on = false, bool dim = false, VoidCallback? tap}) => Tooltip(
      message: tip,
      preferBelow: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: InkWell(
          onTap: tap,
          hoverColor: on ? Colors.transparent : ide.hover,
          borderRadius: BorderRadius.circular(Radii.l),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: touch ? 44 : 36,
            height: touch ? 44 : 36,
            decoration: BoxDecoration(color: on ? ide.accentSoft : null, borderRadius: BorderRadius.circular(Radii.l)),
            child: Icon(icon, size: 20, color: on ? ide.accent : (dim ? ide.textFaint.withValues(alpha: 0.6) : ide.textDim)),
          ),
        ),
      ),
    );
    Widget tab(IconData icon, String label, String tip, {bool on = false, bool dim = false, VoidCallback? tap}) => Tooltip(
      message: tip,
      child: InkWell(
        onTap: tap,
        child: SizedBox(
          height: 58,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 52,
              height: 28,
              decoration: BoxDecoration(color: on ? ide.accentSoft : null, borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, size: 20, color: on ? ide.accent : (dim ? ide.textFaint : ide.textDim)),
            ),
            const SizedBox(height: 3),
            AnimatedOpacity(
              opacity: on ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.visible,
                style: TextStyle(fontSize: 10.5, color: ide.text, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
    final feats = [
      for (final f in features.all)
        Builder(
          builder: (_) {
            final st = ws.link == null ? FeatureState.available : ws.stateOf(f);
            final usable = st == FeatureState.available || st == FeatureState.loading;
            final tip = usable ? f.title : '${f.title}（${_stateText(st)}）';
            return vertical
                ? rail(f.icon, tip, on: current == f.id, dim: !usable, tap: () => onPick(f))
                : tab(f.icon, f.title, tip, on: current == f.id, dim: !usable, tap: () => onPick(f));
          },
        ),
    ];
    if (vertical) {
      return SizedBox(
        width: 48,
        child: Column(children: [
          Expanded(child: SingleChildScrollView(child: Column(children: feats))),
          rail(Icons.tune_rounded, '服务器概览', tap: onOverview),
          rail(Icons.settings_outlined, '设置', tap: () => ws.openTab(settingsTab(ws.app))),
          const SizedBox(height: Space.xs),
        ]),
      );
    }
    // bottom bar: feature icons share the width; the rest sit in a menu
    return Container(
      decoration: BoxDecoration(color: ide.frame, border: Border(top: BorderSide(color: ide.border))),
      child: Row(
        children: [
          for (final f in feats) Expanded(child: f),
          Expanded(child: tab(Icons.more_horiz_rounded, '更多', '更多', tap: () => _more(context))),
        ],
      ),
    );
  }

  void _more(BuildContext context) {
    void go(BuildContext c, VoidCallback f) {
      Navigator.pop(c);
      f();
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: Space.m),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: const Icon(Icons.keyboard_command_key), title: const Text('命令面板'), onTap: () => go(c, onPalette)),
              ListTile(leading: const Icon(Icons.dns_outlined), title: const Text('服务器'), onTap: () => go(c, onServers)),
              ListTile(leading: const Icon(Icons.tune_rounded), title: const Text('服务器概览'), onTap: () => go(c, onOverview)),
              ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('设置'), onTap: () => go(c, () => ws.openTab(settingsTab(ws.app)))),
            ],
          ),
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
      if (st == FeatureState.loading) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
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
    return ColoredBox(
      color: ide.sideBar,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: Space.l + 2, right: Space.s),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.text),
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
                  TickerMode(enabled: k == index, child: ExcludeFocus(excluding: k != index, child: children[k])),
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
  final VoidCallback onAdd, onPalette, onFind;
  const _EditorArea({required this.ws, required this.features, required this.onAdd, required this.onPalette, required this.onFind});

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
    final shown = ws.visibleTabs;
    final split = ws.split && MediaQuery.sizeOf(context).width >= _narrow;
    final left = shown.any((t) => t.id == ws.activeId) ? ws.activeId : null;
    final right = split ? ws.sideId : null;
    return LayoutBuilder(builder: (context, box) {
      final strip = _TabStrip.heightOf(context);
      final half = split ? (box.maxWidth - 1) / 2 : box.maxWidth;
      // Every tab stays built, in one Stack, at the same place in the tree;
      // splitting only moves it. A terminal keeps its stream and an editor its
      // unsaved text and undo, whichever side shows it.
      Widget body(EditorTab t) {
        final onLeft = t.id == left, onRight = t.id == right;
        final on = onLeft || onRight;
        return Positioned(
          key: ObjectKey(t),
          left: onRight ? half + 1 : 0,
          top: shown.isEmpty ? 0 : strip,
          width: on ? half : box.maxWidth,
          bottom: 0,
          child: Offstage(
            offstage: !on,
            child: TickerMode(
              enabled: on,
              child: KeyedSubtree(
                key: ValueKey(t.id),
                child: ExcludeFocus(
                  excluding: !on,
                  child: Listener(
                    // a click in a pane gives that side the focus (Ctrl+W, Ctrl+Tab)
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (_) => ws.focusSide(onRight),
                    child: RepaintBoundary(child: _bodies.putIfAbsent(t, () => Builder(builder: t.builder))),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      return ColoredBox(
        color: ide.editor,
        child: Stack(children: [
          if (left == null && right == null)
            Positioned.fill(child: _Welcome(ws: ws, features: features, onPalette: widget.onPalette, onFind: widget.onFind)),
          if (shown.isNotEmpty)
            Positioned(
              left: 0,
              top: 0,
              height: strip,
              width: half,
              child: _TabStrip(ws: ws, right: false, focused: !split || !ws.sideFocused),
            ),
          if (split) ...[
            Positioned(left: half + 1, top: 0, height: strip, width: half, child: _TabStrip(ws: ws, right: true, focused: ws.sideFocused)),
            Positioned(left: half, top: 0, bottom: 0, width: 1, child: ColoredBox(color: ide.border)),
          ],
          for (final t in ws.tabs) body(t),
        ]),
      );
    });
  }
}

/// The tabs of one side. Split, the left strip lists every tab but the right
/// side's, and the right strip only its own: one tab is never on both.
class _TabStrip extends StatelessWidget {
  final Workspace ws;
  final bool right;

  /// This side has the focus: its current tab is drawn as the active one.
  final bool focused;
  const _TabStrip({required this.ws, this.right = false, this.focused = true});

  static double heightOf(BuildContext context) => InputMode.isTouch(context) ? 46 : 38;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final split = ws.split;
    final tabs = !split ? ws.visibleTabs : right ? ws.visibleTabs.where((t) => t.id == ws.sideId).toList() : ws.visibleTabs.where((t) => t.id != ws.sideId).toList();
    final current = right ? ws.sideId : ws.activeId;
    return Container(
      height: heightOf(context),
      decoration: BoxDecoration(color: ide.tabBar, border: Border(bottom: BorderSide(color: ide.border))),
      child: Row(children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs + 1, vertical: 5),
            children: [
              for (final t in tabs) _TabButton(ws: ws, tab: t, active: t.id == current, focused: focused, right: right),
            ],
          ),
        ),
        if (right) ...[IconBtn(Icons.close_fullscreen_rounded, '取消拆分（Ctrl+\\）', ws.unsplit), const SizedBox(width: Space.xs)],
      ]),
    );
  }
}

class _TabButton extends StatefulWidget {
  final Workspace ws;
  final EditorTab tab;
  final bool active, focused, right;
  const _TabButton({required this.ws, required this.tab, required this.active, required this.focused, this.right = false});

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, tab = widget.tab, active = widget.active, right = widget.right;
    final ide = Ide.of(context);
    final touch = InputMode.isTouch(context);
    final strong = active && widget.focused;
    final bg = strong ? ide.tabActive : (active || _hover ? ide.hover : null);
    return ContextArea(
      items: () => [
        MenuItem('关闭', () => ws.closeTab(tab.id), icon: Icons.close, hint: 'Ctrl+W'),
        if (!right && !ws.split && ws.visibleTabs.length > 1)
          MenuItem('向右拆分', () {
            ws.activate(tab.id);
            ws.splitActive();
          }, icon: Icons.vertical_split_outlined, hint: 'Ctrl+\\'),
        if (right) MenuItem('移回左侧', ws.unsplit, icon: Icons.close_fullscreen),
        MenuItem('关闭其它', () async {
          for (final o in ws.visibleTabs.where((x) => x.id != tab.id).toList()) {
            if (!await ws.closeTab(o.id)) break;
          }
        }),
        MenuItem('全部关闭', () async {
          for (final o in ws.visibleTabs.toList()) {
            if (!await ws.closeTab(o.id)) break;
          }
        }),
      ],
      child: Listener(
        // a middle click closes, as in every IDE
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) ws.closeTab(tab.id);
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Tooltip(
            message: tab.tooltip ?? tab.title,
            waitDuration: const Duration(milliseconds: 800),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: GestureDetector(
                onTap: () {
                  ws.focusSide(right);
                  ws.activate(tab.id);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  constraints: BoxConstraints(minWidth: touch ? 96 : 72, maxWidth: 240),
                  padding: const EdgeInsets.only(left: Space.m + 2, right: Space.xs),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(Radii.m),
                    border: strong && !ide.isDark ? Border.all(color: ide.border) : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(tab.icon, size: 15, color: tab.iconColor ?? (strong ? ide.accent : ide.textDim)),
                      const SizedBox(width: Space.s + 1),
                      Flexible(
                        child: Text(
                          tab.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: active ? ide.text : ide.textDim, fontWeight: strong ? FontWeight.w500 : FontWeight.w400),
                        ),
                      ),
                      const SizedBox(width: Space.xs),
                      ValueListenableBuilder<bool>(
                        valueListenable: tab.dirty,
                        builder: (_, dirty, _) {
                          final showClose = touch || active || _hover;
                          return SizedBox(
                            width: touch ? 32 : 20,
                            height: touch ? 32 : 20,
                            child: _CloseOrDot(dirty: dirty, showClose: showClose, onClose: () => ws.closeTab(tab.id)),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tab's close button. Unsaved, it is a dot that turns into the button
/// under the mouse, as in VS Code.
class _CloseOrDot extends StatefulWidget {
  final bool dirty, showClose;
  final VoidCallback onClose;
  const _CloseOrDot({required this.dirty, required this.showClose, required this.onClose});
  @override
  State<_CloseOrDot> createState() => _CloseOrDotState();
}

class _CloseOrDotState extends State<_CloseOrDot> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final dot = widget.dirty && !_hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkResponse(
        onTap: widget.onClose,
        radius: 11,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(Radii.s),
        hoverColor: ide.hover,
        child: Center(
          child: dot
              ? Container(width: 8, height: 8, decoration: BoxDecoration(color: ide.textDim, shape: BoxShape.circle))
              : AnimatedOpacity(
                  opacity: widget.showClose || _hover ? 1 : 0,
                  duration: const Duration(milliseconds: 100),
                  child: Icon(Icons.close_rounded, size: 14, color: _hover ? ide.text : ide.textDim),
                ),
        ),
      ),
    );
  }
}

/// What the editor area shows with no tab open: the server, what can be
/// started, and the keys worth knowing.
class _Welcome extends StatelessWidget {
  final Workspace ws;
  final Features features;
  final VoidCallback onPalette, onFind;
  const _Welcome({required this.ws, required this.features, required this.onPalette, required this.onFind});

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
    final connected = ws.link != null;
    bool usable(String id) {
      final f = features.byId(id);
      return f != null && ws.stateOf(f) == FeatureState.available;
    }

    final st = ws.status;
    final subtitle = connected
        ? [ws.link!.server.os, 'agent ${ws.link!.server.version}', ?st.addr].where((s) => s.isNotEmpty).join(' · ')
        : switch (st.state) {
            ConnState.connecting => '正在连接…',
            ConnState.waiting => '${st.retryIn?.inSeconds ?? 0} 秒后重试',
            ConnState.failed => st.failure?.message ?? '连接失败',
            _ => '未连接',
          };
    final actions = <_Action>[
      if (connected) ...[
        if (usable('terminal')) _Action(Icons.terminal_rounded, '打开终端', '继续上次的会话，或新建一个', () => _openTerminal(context)),
        if (usable('search')) _Action(Icons.search_rounded, '快速打开文件', '按文件名模糊查找', onFind, keys: 'Ctrl+P'),
        if (usable('search')) _Action(Icons.manage_search_rounded, '全局搜索', '在项目文件夹里搜文字', () => ws.focusSearch.value++, keys: 'Ctrl+Shift+F'),
        if (usable('monitor')) _Action(Icons.monitor_heart_outlined, '查看监控', 'CPU、内存、磁盘与网络', () => ws.openTab(monitorTab(ws))),
      ] else
        _Action(Icons.sync_rounded, '连接', '连接到这台服务器', () => ws.app.connect(ws.serverId)),
      _Action(Icons.tune_rounded, '概览与设置', '服务器信息、服务开关', () => ws.openTab(overviewTab(ws, features))),
      _Action(Icons.keyboard_command_key, '命令面板', '所有命令都在这里', onPalette, keys: 'Ctrl+Shift+P'),
    ];
    Widget label(String s) => Padding(
      padding: const EdgeInsets.only(bottom: Space.m + 2, left: 2),
      child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.textFaint, letterSpacing: 0.3)),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xxl + 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(color: ide.sideBar, borderRadius: BorderRadius.circular(14), border: Border.all(color: ide.border)),
                  child: Image.asset('assets/branding/aurora3-256.png', semanticLabel: 'Aurora 3'),
                ),
                const SizedBox(width: Space.xl),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(ws.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Row(children: [
                      StatusDot(connColor(ide, st.state), size: 7),
                      const SizedBox(width: Space.s + 1),
                      Flexible(child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: ide.textDim, fontSize: 12.5))),
                    ]),
                  ]),
                ),
              ]),
              const SizedBox(height: Space.xxl + 8),
              label('开始'),
              LayoutBuilder(builder: (context, box) {
                final two = box.maxWidth >= 460;
                final w = two ? (box.maxWidth - Space.m) / 2 : box.maxWidth;
                return Wrap(spacing: Space.m, runSpacing: Space.m, children: [
                  for (final a in actions) SizedBox(width: w, child: _ActionCard(a)),
                ]);
              }),
              if (!InputMode.isTouch(context)) ...[
                const SizedBox(height: Space.xxl + 4),
                label('常用快捷键'),
                for (final (what, keys) in const [
                  ('切换侧栏', 'Ctrl+B'),
                  ('向右拆分编辑器', 'Ctrl+\\'),
                  ('下一个标签', 'Ctrl+Tab'),
                  ('关闭标签', 'Ctrl+W'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                    child: Row(children: [
                      Expanded(child: Text(what, style: TextStyle(color: ide.textDim, fontSize: 12.5))),
                      KeyCaps(keys),
                    ]),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Action {
  final IconData icon;
  final String title, detail;
  final VoidCallback run;
  final String? keys;
  const _Action(this.icon, this.title, this.detail, this.run, {this.keys});
}

class _ActionCard extends StatefulWidget {
  final _Action a;
  const _ActionCard(this.a);
  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final a = widget.a;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: a.run,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(Space.l),
          decoration: BoxDecoration(
            color: _hover ? ide.hover : ide.editor,
            borderRadius: BorderRadius.circular(Radii.l + 2),
            border: Border.all(color: _hover ? ide.borderStrong : ide.border),
          ),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: ide.accentSoft, borderRadius: BorderRadius.circular(Radii.l)),
              child: Icon(a.icon, size: 18, color: ide.accent),
            ),
            const SizedBox(width: Space.l),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ide.text)),
                const SizedBox(height: 2),
                Text(a.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ide.textFaint)),
              ]),
            ),
            if (a.keys != null && !InputMode.isTouch(context)) ...[const SizedBox(width: Space.s), KeyCaps(a.keys!)],
          ]),
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
    final text = switch (st.state) {
      ConnState.connected => st.addr ?? '已连接',
      ConnState.connecting => '正在连接…',
      ConnState.waiting => '${st.retryIn?.inSeconds ?? 0} 秒后重试',
      ConnState.failed => st.failure?.message ?? '连接失败',
      ConnState.idle => '未连接',
    };
    final style = TextStyle(color: ide.statusText, fontSize: 12);
    return Container(
      height: InputMode.isTouch(context) ? 32 : 26,
      color: ide.statusBar,
      padding: const EdgeInsets.symmetric(horizontal: Space.s),
      child: Row(
        children: [
          Tooltip(
            message: st.state == ConnState.connected ? '已连接；点击重新连接' : '点击连接',
            child: InkWell(
              onTap: onTapConn,
              borderRadius: BorderRadius.circular(Radii.s),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusDot(connColor(ide, st.state), size: 7),
                    const SizedBox(width: Space.s + 1),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Text('${ws.name}  ·  $text', style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          if (ws.active != null)
            ValueListenableBuilder<String>(
              valueListenable: ws.active!.status,
              builder: (_, v, _) => v.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(padding: const EdgeInsets.symmetric(horizontal: Space.s), child: Text(v, style: style, maxLines: 1)),
            ),
          if (ws.link != null && MediaQuery.sizeOf(context).width >= _narrow)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.s),
              child: Text('agent ${ws.link!.server.version}', style: style.copyWith(color: ide.textFaint)),
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
      height: 52,
      color: ide.frame,
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Row(
        children: [
          if (showEditor) IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back_rounded)) else const SizedBox(width: Space.l),
          Expanded(
            child: showEditor && t != null
                ? Text(t.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ide.text), maxLines: 1, overflow: TextOverflow.ellipsis)
                : InkWell(
                    onTap: onServers,
                    borderRadius: BorderRadius.circular(Radii.m),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.s),
                      child: Row(children: [
                        StatusDot(connColor(ide, ws.status.state), size: 8),
                        const SizedBox(width: Space.m + 2),
                        Flexible(
                          child: Text(ws.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ide.text), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        Icon(Icons.expand_more_rounded, size: 20, color: ide.textDim),
                      ]),
                    ),
                  ),
          ),
          if (showEditor && ws.visibleTabs.length > 1)
            PopupMenuButton<String>(
              tooltip: '切换标签',
              icon: Badge(label: Text('${ws.visibleTabs.length}'), child: const Icon(Icons.layers_outlined)),
              onSelected: ws.activate,
              itemBuilder: (_) => [
                for (final x in ws.visibleTabs)
                  PopupMenuItem(
                    value: x.id,
                    child: Row(
                      children: [
                        Icon(x.icon, size: 16, color: x.id == ws.activeId ? ide.accent : ide.textDim),
                        const SizedBox(width: Space.m),
                        Flexible(child: Text(x.title, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
              ],
            ),
          if (showEditor && t != null) IconButton(onPressed: () => ws.closeTab(t.id), icon: const Icon(Icons.close_rounded)),
        ],
      ),
    );
  }
}

/// The server list that drops down from the title bar.
class _ServerSwitcher extends StatelessWidget {
  final AppState app;
  final VoidCallback onClose, onAdd;
  const _ServerSwitcher({required this.app, required this.onClose, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final p = app.profile;
    return Container(
      constraints: const BoxConstraints(maxHeight: 440),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ide.surface,
        borderRadius: BorderRadius.circular(Radii.dialog),
        border: Border.all(color: ide.borderStrong.withValues(alpha: 0.7)),
        boxShadow: ide.float,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l + 2, Space.l, Space.l + 2, Space.s),
              child: Text('服务器', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.textFaint, letterSpacing: 0.3)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: Space.xs),
                children: [
                  for (final s in p.servers)
                    TreeRow(
                      selected: s.id == p.selected,
                      leading: StatusDot(connColor(ide, app.status(s.id).state), size: 7),
                      label: s.name,
                      detail: s.ssh?.host,
                      trailing: s.id == p.selected ? Icon(Icons.check_rounded, size: 16, color: ide.accent) : null,
                      onTap: () {
                        app.select(s.id);
                        onClose();
                      },
                    ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: TreeRow(
                leading: Icon(Icons.add_rounded, size: 16, color: ide.textDim),
                label: '添加服务器…',
                onTap: () {
                  onClose();
                  onAdd();
                },
              ),
            ),
          ],
        ),
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
    Widget step(String n, String t) => Padding(
      padding: const EdgeInsets.only(bottom: Space.m),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: ide.accentSoft, shape: BoxShape.circle),
          child: Text(n, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ide.accent)),
        ),
        const SizedBox(width: Space.m + 2),
        Expanded(child: Text(t, style: TextStyle(color: ide.textDim, fontSize: 13, height: 1.5))),
      ]),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xxl),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          padding: const EdgeInsets.all(Space.xxl + 4),
          decoration: BoxDecoration(
            color: ide.editor,
            borderRadius: BorderRadius.circular(Radii.island + 4),
            border: Border.all(color: ide.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Image.asset('assets/branding/aurora3-256.png', width: 48, height: 48, semanticLabel: 'Aurora 3'),
              const SizedBox(height: Space.xl + 2),
              Text('欢迎使用 Aurora', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: Space.s),
              Text('还没有服务器。连上一台 Linux 服务器，就能在这里编辑文件、开终端、管理 git 和服务。',
                style: TextStyle(color: ide.textDim, height: 1.55)),
              const SizedBox(height: Space.xxl),
              step('1', '填写服务器的 SSH 地址和账号'),
              step('2', 'Aurora 通过 SSH 在服务器上安装 agent'),
              step('3', '之后直接加密连接 agent'),
              const SizedBox(height: Space.l),
              FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('添加服务器')),
            ],
          ),
        ),
      ),
    );
  }
}
