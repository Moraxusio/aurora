// One continuous workbench. Desktop sidebars resize beside the editor, never
// over it; narrow windows show one region at a time. All bodies retain identity.
import 'dart:async';
import 'dart:io';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';
import 'package:flutter/services.dart';

import '../features/search/quick_open.dart';
import '../features/search/search_feature.dart' show desktopSearchMinWidth;
import '../features/files/file_editor.dart' show fileEditorTab;
import '../features/ai/ai_feature.dart' show openNewAiSession, AiSessionSidebar;
import '../features/terminal/terminal_feature.dart' show createSession, SessionList;
import '../state/app_state.dart';
import '../theme/ide_theme.dart';
import '../ui/add_server.dart';
import '../ui/settings_page.dart';
import '../ui/upgrade_agent.dart';
import '../ui/open_local_folder.dart';
import 'desktop_lifecycle.dart';
import 'feature.dart';
import 'input_mode.dart';
import 'overview.dart';
import 'registry.dart';
import 'window_frame.dart';
import 'workspace.dart';
import 'tab_layout.dart';
import 'tab_layout_menu.dart' show arrangementIcon, arrangementLabel, placementLabel;
import 'tab_workspace_view.dart';
import 'workbench_view.dart';
import 'retained_pages.dart';
import 'retained_pane.dart';
import 'workbench_shortcuts.dart';
import 'ui_diagnostics.dart';

const double _wide = 900, _narrow = desktopSearchMinWidth;
const double _railWidth = 68;

class Shell extends StatefulWidget {
  final AppState app;
  final Features features;
  const Shell({super.key, required this.app, required this.features});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final Map<String, Workspace> _spaces = {};
  final Map<Workspace, Widget> _editorViews = {};
  final Map<String, String> _featureIds = {};
  String get _featureId => _featureIds[app.selected] ?? 'files';
  set _featureId(String value) {
    final id = app.selected;
    if (id != null) _featureIds[id] = value;
  }
  bool _sideOpen = true;
  bool _serversOpen = false;
  bool _searchPickerOpen = false;
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
    // Only the initial default depends on size. Dragging or zooming through a
    // breakpoint must not silently change the user's sidebar visibility.
    if (mode == 1 && _mode == null) _sideOpen = false;
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
    if (!await app.appearance.flush()) {
      Toast.show('设置尚未保存，请在设置页重试', error: true);
      return false;
    }
    if (!mounted) return false;
    if (widget.features.transfers.active > 0) {
      final ok = await confirmDialog(context, title: '还有文件正在传输',
        body: '${widget.features.transfers.active} 个传输尚未完成。退出客户端会中断这些传输。点窗口的叉只隐藏到托盘，不会中断。', ok: '仍然退出');
      if (!ok || !mounted) return false;
    }
    // Hot exit: preserve dirty buffers in independent encrypted checkpoints.
    // Explicit tab close still offers save/discard/cancel.
    for (final ws in _spaces.values.toList()) {
      for (final tab in ws.tabs.toList()) {
        // Merge decisions are transient views, outside DocumentRegistry.
        if (tab.file == null && tab.dirty.value && tab.confirmClose != null) {
          if (!await tab.confirmClose!() || !mounted) return false;
        }
      }
    }
    for (final ws in _spaces.values.toList()) {
      if (!await ws.documents.flush()) {
        Toast.show('未保存文档尚未写入恢复记录，请检查磁盘后重试退出', error: true);
        return false;
      }
      if (!mounted) return false;
    }
    for (final ws in _spaces.values.toList()) {
      if (!await ws.flushViews()) return false;
    }
    if (app.servers.any((s) => s.isLocal && app.link(s.id) != null)) {
      if (!mounted || !await confirmDialog(context, title: '退出本机开发环境', body: '完全退出将结束本地终端、AI 和受管开发任务。隐藏到托盘则会继续运行。远程服务器任务不受影响。', ok: '结束本地任务并退出')) return false;
    }
    await app.localAgent.stop();
    for (final ws in _spaces.values.toList()) {
      if (!await ws.documents.flush()) return false;
    }
    return true;
  }

  void _onApp() {
    // workspaces follow the server list
    final ids = {for (final s in app.servers) s.id};
    for (final id in _spaces.keys.toList()) {
      if (!ids.contains(id)) {
        widget.features.forwards.detach(id);
        final gone = _spaces.remove(id);
        _editorViews.remove(gone);
        _featureIds.remove(id);
        gone?.dispose();
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
        if (mounted && app.allowAutoConnect && app.status(id).state == ConnState.idle) {
          unawaited(app.connect(id));
        }
      });
      final ws = Workspace(app, id);
      ws.openQuickSearch = () => _find(ws);
      ws.openContentSearch = () => _findContents(ws);
      // A committed content query shows its results, not another desktop
      // search field. The phone results pane retains its own tactile input.
      ws.focusSearch.addListener(() {
        final f = widget.features.byId('search');
        if (mounted && f != null && app.selected == id) _pick(ws, f, open: true);
      });
      return ws;
    });
  }

  /// The workspace in front (tests).
  @visibleForTesting
  Workspace? get debugWorkspace => _ws;

  List<Command> _commands(Workspace? ws) {
    final out = <Command>[
      Command(id: 'diagnostics.copyGui', title: '复制界面诊断', group: '诊断', icon: Icons.bug_report_outlined, run: () async {
        await Clipboard.setData(ClipboardData(text: UiDiagnostics.shared.snapshot()));
        Toast.show('已复制界面诊断');
      }),
      if (Platform.isWindows) Command(id: 'local.open', title: '打开本机文件夹…', group: '本机', icon: Icons.folder_open, run: () => openLocalFolder(app)),
      Command(id: 'server.add', title: '添加服务器…', group: '服务器', icon: Icons.add, run: _addServer),
      Command(id: 'view.zoomIn', title: '放大界面', group: '外观', shortcut: 'Ctrl++', run: () => _zoom(.1)),
      Command(id: 'view.zoomOut', title: '缩小界面', group: '外观', shortcut: 'Ctrl+-', run: () => _zoom(-.1)),
      Command(id: 'view.zoomReset', title: '还原界面缩放', group: '外观', shortcut: 'Ctrl+0', run: () => app.appearance.set('uiScale', 1.0)),
      // the server in front is not a place to switch to
      for (final s in app.servers)
        if (s.id != app.selected) Command(id: 'server.go.${s.id}', title: '切换到 ${s.name}', group: '服务器', icon: Icons.dns_outlined, run: () => app.select(s.id)),
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
           title: '向右分屏',
          group: '视图',
          icon: Icons.vertical_split_outlined,
          shortcut: 'Ctrl+\\',
           enabled: () => ws.tabLayout.groups.length < TabLayout.maxGroups,
           run: () => ws.splitGroup(SplitAxis.horizontal),
         ),
        Command(id: 'editor.splitDown', title: '向下分屏', group: '标签与布局', shortcut: 'Ctrl+Shift+\\', icon: Icons.horizontal_split_outlined, run: () => ws.splitGroup(SplitAxis.vertical)),
        Command(id: 'editor.focus', title: '放大当前视图 / 还原分屏', group: '视图', shortcut: 'Ctrl+Shift+Enter', icon: Icons.fit_screen_outlined, enabled: () => ws.split, run: ws.toggleFocusMode),
        for (final arrangement in EditorArrangement.values)
          Command(id: 'editor.layout.${arrangement.name}', title: arrangementLabel(arrangement), group: '标签与布局', icon: arrangementIcon(arrangement), run: () => ws.arrangeEditors(arrangement)),
        for (final placement in TabPlacement.values)
          Command(id: 'editor.tabs.${placement.name}', title: placementLabel(placement), group: '标签与布局', icon: Icons.tab_outlined, run: () => ws.setTabPlacement(placement)),
        Command(id: 'tab.pin', title: '固定 / 取消固定当前标签', group: '标签与布局', icon: Icons.push_pin_outlined, enabled: () => ws.active != null, run: () => ws.pinTab(ws.active!.id)),
        Command(id: 'app.settings', title: '设置（主题、字号、自动换行）', group: '设置', icon: Icons.settings_outlined, run: () => ws.openTab(settingsTab(app))),
        Command(id: 'tab.next', title: '下一个标签', group: '视图', shortcut: 'Ctrl+Tab', enabled: () => ws.navigationTabs.length > 1, run: () => ws.next(1)),
        Command(id: 'tab.prev', title: '上一个标签', group: '视图', shortcut: 'Ctrl+Shift+Tab', enabled: () => ws.navigationTabs.length > 1, run: () => ws.next(-1)),
        Command(id: 'panel.toggle', title: '显示或隐藏终端面板', group: '视图', shortcut: 'Ctrl+J', icon: Icons.terminal, run: ws.toggleTerminalPanel),
        Command(id: 'assistant.toggle', title: '显示或隐藏 AI 侧栏', group: '视图', shortcut: 'Ctrl+Alt+I', icon: Icons.auto_awesome_outlined, run: ws.toggleAssistantPanel),
        Command(id: 'terminal.focus', title: '聚焦终端面板', group: '终端', shortcut: 'Ctrl+`', icon: Icons.terminal, run: ws.showTerminalPanel),
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
  void _zoom(double delta) => app.appearance.set('uiScale', ((app.appearance.value.uiScale + delta) * 100).round() / 100);

  bool _usable(Workspace ws, String id) {
    final f = widget.features.byId(id);
    return f != null && ws.stateOf(f) == FeatureState.available;
  }

  void _find(Workspace ws) => _search(ws, WorkbenchSearchMode.files);

  void _findContents(Workspace ws) {
    if (!_usable(ws, 'search')) return;
    if (MediaQuery.sizeOf(context).width < _narrow) {
      ws.focusSearch.value++;
    } else {
      _search(ws, WorkbenchSearchMode.contents);
    }
  }

  Future<void> _search(Workspace? ws, WorkbenchSearchMode mode) async {
    if (_searchPickerOpen) return;
    final searchable = ws != null && _usable(ws, 'search');
    _searchPickerOpen = true;
    await showWorkbenchSearch(
        context,
        workspace: ws,
        fileSearch: searchable,
        commands: _commands(ws),
        initialMode: mode,
        onPickerClosed: () => _searchPickerOpen = false,
        onContents: !searchable ? null : (query) {
          if (!mounted || !identical(_ws, ws) || !_usable(ws, 'search')) return;
          if (query != ws.searchQuery.text) ws.searchQuery.text = query;
          ws.focusSearch.value++;
          // Refresh the same query, as well as a changed one, on Enter.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(_ws, ws)) ws.submitSearch.value++;
          });
        },
    );
  }

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
      // In a one-pane layout, the bottom navigation is only visible while
      // the console is offstage. Treat it as navigation, not as a hide toggle.
      if (f.id == 'terminal' && MediaQuery.sizeOf(context).width < _narrow) {
        ws.showTerminalPanel();
      } else {
        f.open(ws);
      }
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
    return WorkbenchShortcuts(
      bindings: {
        if (_serversOpen) const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _serversOpen = false),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () => _zoom(.1),
        const SingleActivator(LogicalKeyboardKey.equal, control: true, shift: true): () => _zoom(.1),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () => _zoom(-.1),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () => app.appearance.set('uiScale', 1.0),
        if (ws != null) const SingleActivator(LogicalKeyboardKey.comma, control: true): () => ws.openTab(settingsTab(app)),
        const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): () => _search(ws, WorkbenchSearchMode.commands),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): _toggleSide,
        if (ws != null)
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
            final t = ws.active;
            if (t != null) ws.closeTab(t.id);
          },
        if (ws != null && MediaQuery.sizeOf(context).width >= _narrow)
          const SingleActivator(LogicalKeyboardKey.backslash, control: true): () => ws.splitGroup(SplitAxis.horizontal),
        if (ws != null && MediaQuery.sizeOf(context).width >= _narrow)
          const SingleActivator(LogicalKeyboardKey.backslash, control: true, shift: true): () => ws.splitGroup(SplitAxis.vertical),
        if (ws != null) ...{
          const SingleActivator(LogicalKeyboardKey.keyJ, control: true): ws.toggleTerminalPanel,
          const SingleActivator(LogicalKeyboardKey.keyI, control: true, alt: true): ws.toggleAssistantPanel,
          const SingleActivator(LogicalKeyboardKey.backquote, control: true): ws.showTerminalPanel,
          const SingleActivator(LogicalKeyboardKey.backquote, control: true, shift: true): () {
            if (_usable(ws, 'terminal')) { createSession(ws, context: context); } else { ws.showTerminalPanel(); }
          },
          const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => ws.focusGroupAt(0),
          const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => ws.focusGroupAt(1),
          const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => ws.focusGroupAt(2),
          const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => ws.focusGroupAt(3),
          const SingleActivator(LogicalKeyboardKey.pageUp, control: true, shift: true): () => ws.reorderActive(-1),
          const SingleActivator(LogicalKeyboardKey.pageDown, control: true, shift: true): () => ws.reorderActive(1),
          const SingleActivator(LogicalKeyboardKey.enter, control: true, shift: true): ws.toggleFocusMode,
        },
        if (ws != null)
          const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => _find(ws),
        if (ws != null)
          const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => _findContents(ws),
        if (ws != null) const SingleActivator(LogicalKeyboardKey.tab, control: true): () => ws.next(1),
        if (ws != null) const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => ws.next(-1),
      },
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          backgroundColor: ide.frame,
          body: SafeArea(
            child: ws == null
                ? _EmptyShell(app: app, onAdd: _addServer)
                : ListenableBuilder(listenable: ws, builder: (context, _) => _layout(context, ws, mode, ide)),
          ),
        ),
      ),
    );
  }

  Widget _layout(BuildContext context, Workspace ws, int mode, Ide ide) {
    // Restore buffers even when disconnected or the file sidebar is hidden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _spaces[ws.serverId] != ws) return;
      ws.restoreFiles((f) => fileEditorTab(ws, root: f.root, path: f.path));
      unawaited(ws.restoreRecovery((f) => fileEditorTab(ws, root: f.root, path: f.path)));
    });
    final narrow = mode == 0;
    final side = RetainedPages(index: _spaces.values.toList().indexOf(ws), children: [
      for (final space in _spaces.values)
        TickerMode(key: ObjectKey(space), enabled: identical(space, ws),
          child: ExcludeFocus(excluding: !identical(space, ws),
            child: ListenableBuilder(listenable: space, builder: (_, _) =>
              _SideBar(ws: space, features: widget.features,
                feature: widget.features.byId(_featureIds[space.serverId] ?? 'files') ?? widget.features.all.first,
                onPickFeature: (f) => _pick(space, f))))),
    ]);
    final editor = RetainedPages(index: _spaces.values.toList().indexOf(ws), children: [
      for (final space in _spaces.values)
        TickerMode(key: ObjectKey(space), enabled: identical(space, ws),
          child: ExcludeFocus(excluding: !identical(space, ws), child: _editorViews.putIfAbsent(space, () => ListenableBuilder(listenable: space,
             builder: (_, _) => _EditorArea(ws: space, features: widget.features, onAdd: _addServer,
                onPalette: () => _search(space, WorkbenchSearchMode.commands), onFind: () => _find(space)))))),
    ]);
    void servers() => setState(() => _serversOpen = !_serversOpen);
    final status = _StatusBar(
      ws: ws,
      app: app,
      onTapConn: () => ws.status.state == ConnState.connected
          ? ws.openTab(overviewTab(ws, widget.features))
          : app.connect(ws.serverId),
      onToggleAssistant: () {
        if (ws.assistantTabs.isEmpty) {
          openNewAiSession(ws);
        } else if (MediaQuery.sizeOf(context).width >= 600 &&
            ws.assistantPanel.visible) {
          ws.hideAssistantPanel();
        } else {
          ws.toggleAssistantPanel();
        }
      },
    );
    final showEditor = !narrow || (ws.compactEditor && (ws.visibleTabs.isNotEmpty || ws.terminalPanel.visible || ws.assistantPanel.visible));

    final body = Column(
      children: [
        if (narrow)
          _PhoneTop(ws: ws, showEditor: showEditor, onBack: () => setState(() => ws.compactEditor = false), onServers: servers)
        else
          _TitleBar(
            key: ObjectKey(ws),
            ws: ws,
            searchable: _usable(ws, 'search'),
            searching: _sideOpen && _featureId == 'search' && _usable(ws, 'search'),
            sideOpen: _sideOpen,
            onServers: servers,
            onSearch: () => _search(ws, _sideOpen && _featureId == 'search'
              ? WorkbenchSearchMode.contents : WorkbenchSearchMode.files),
            onToggleSide: _toggleSide,
          ),
        // Below the title bar: the window buttons cover the top-right 40 px.
        AgentUpgradeNotice(app: app, id: ws.serverId),
        Expanded(
          key: const ValueKey('main-content'),
          child: _ShellBody(ws: ws, mode: mode, sideOpen: _sideOpen,
            showEditor: showEditor, side: side, editor: editor,
            activity: _ActivityBar(
                  ws: ws,
                  features: widget.features,
                  current: _sideOpen ? _featureId : null,
                  vertical: true,
                  onPick: (f) => _pick(ws, f),
                  onServers: servers,
                   onPalette: () => _search(ws, WorkbenchSearchMode.commands),
                  onOverview: () => ws.openTab(overviewTab(ws, widget.features)),
                ),
          ),
        ),
        if (narrow && !showEditor) _ActivityBar(ws: ws, features: widget.features, current: _featureId, vertical: false,
          onPick: (f) => _pick(ws, f), onServers: servers,
           onPalette: () => _search(ws, WorkbenchSearchMode.commands), onOverview: () => ws.openTab(overviewTab(ws, widget.features))),
        status,
      ],
    );
    final width = MediaQuery.sizeOf(context).width;
    return Stack(children: [
      Positioned.fill(child: body),
      if (_serversOpen) ...[
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => setState(() => _serversOpen = false))),
        Positioned(
           left: narrow ? Space.m : _railWidth,
          top: narrow ? 52 : 38,
          width: narrow ? width - Space.m * 2 : 340,
          child: _ServerSwitcher(app: app, onClose: () => setState(() => _serversOpen = false), onAdd: _addServer,
            onOverview: (id) {
              // the overview belongs to the server in front: bring it forward first
              if (app.selected != id) app.select(id);
              setState(() => _serversOpen = false);
              final target = _spaces[id] ?? _ws;
              if (target != null) target.openTab(overviewTab(target, widget.features));
            }),
        ),
      ],
    ]);
  }
}

/// Sidebar and document workspace never change parents. Geometry signals
/// rebuild just these slots; hidden bodies keep their last constraints.
class _ShellBody extends StatefulWidget {
  final Workspace ws;
  final int mode;
  final bool sideOpen, showEditor;
  final Widget side, editor, activity;
  const _ShellBody({required this.ws, required this.mode, required this.sideOpen,
    required this.showEditor, required this.side, required this.editor,
    required this.activity});
  @override
  State<_ShellBody> createState() => _ShellBodyState();
}

class _ShellBodyState extends State<_ShellBody> {
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.ws.geometryRevision,
    builder: (context, _) => LayoutBuilder(builder: (_, box) {
      final ws = widget.ws;
      final narrow = widget.mode == 0;
      final docked = !narrow && widget.sideOpen;
      final rail = narrow ? 0.0 : _railWidth;
      final sideVisible = docked || (narrow && !widget.showEditor);
      // A desktop-scale window keeps enough room for editor + terminal. The
      // labelled rail must not push a 150% layout into the phone-only region.
      final minimumWorkspace = widget.mode == 2 ? 480.0 : 240.0;
      final width = narrow ? box.maxWidth : ws.tabLayout.sideWidth.clamp(180.0,
        (box.maxWidth - rail - 5 - minimumWorkspace).clamp(180.0, 640.0));
      final sideRect = Rect.fromLTWH(rail, 0, width, box.maxHeight);
      final left = rail + (docked ? width + 5 : 0);
      final editorRect = Rect.fromLTWH(left, 0, box.maxWidth-left, box.maxHeight);
      Widget host(String id, Rect rect, bool visible, Widget child) => Positioned.fromRect(key: ValueKey(id), rect: rect,
        child: RetainedPane(visible: visible, child: child));
      return Stack(children: [
        host('editor-slot', editorRect, widget.showEditor, widget.editor),
        host('main-sidebar', sideRect, sideVisible, widget.side),
        if (docked) Positioned(left: rail+width, top: 0, bottom: 0, width: 5,
          child: TabResizeHandle(key: const ValueKey('sidebar-resize'), axis: Axis.horizontal,
            label: '调整侧栏宽度', value: width, onChanged: ws.setSideWidth, onReset: () => ws.setSideWidth(300))),
        if (!narrow) Positioned(left: 0, top: 0, bottom: 0, width: rail, child: widget.activity),
      ]);
    }));
}

/// The gap between the side bar and the editor; drag it to resize. A line
/// shows on hover so the handle can be found.

// ---- title bar ----

/// The top of the window: the server (and project) in front, the find box in
/// the middle, layout buttons on the right.
class _TitleBar extends StatelessWidget {
  final Workspace ws;
  final bool searchable, searching, sideOpen;
  final VoidCallback onServers, onSearch, onToggleSide;
  const _TitleBar({
    super.key,
    required this.ws,
    required this.searchable,
    required this.searching,
    required this.sideOpen,
    required this.onServers,
    required this.onSearch,
    required this.onToggleSide,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final project = ws.project;
    return Container(
      height: WindowFrame.height,
      decoration: BoxDecoration(color: ide.frame, border: Border(bottom: BorderSide(color: ide.border))),
      child: Stack(children: [
        // the empty parts of the bar move the window
        const Positioned.fill(child: WindowDragArea(child: SizedBox.expand())),
        Row(children: [
        SizedBox(
          width: _railWidth,
          child: WorkbenchMenuButton<String>(tooltip: '工作台菜单', padding: EdgeInsets.zero,
            icon: Image.asset('assets/branding/aurora3-256.png', width: 18, height: 18, semanticLabel: 'Aurora 3'),
            onSelected: (action) {
              if (action == 'folder') openLocalFolder(ws.app);
              if (action == 'settings') ws.openTab(settingsTab(ws.app));
              if (action == 'ai') openNewAiSession(ws);
            },
            itemBuilder: (_) => [
              if (Platform.isWindows) const PopupMenuItem(value: 'folder', child: MenuLabel('打开本机文件夹…', icon: Icons.folder_open_outlined)),
              const PopupMenuItem(value: 'ai', child: MenuLabel('新建 AI 对话', icon: Icons.chat_bubble_outline)),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'settings', child: MenuLabel('设置…', icon: Icons.settings_outlined, shortcut: 'Ctrl+,')),
            ]),
        ),
         ConstrainedBox(constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width * .25).clamp(140.0, 300.0)), child: Tooltip(
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
                Flexible(child: Text('${ws.name}${project == null ? '' : ' / ${project.name}'}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.text))),
                const SizedBox(width: 2),
                Icon(Icons.expand_more_rounded, size: 16, color: ide.textFaint),
              ]),
            ),
          ),
        )),
         Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.l),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                 child: _WorkspaceSearchEntry(
                   ws: ws,
                   searchable: searchable,
                   searching: searching,
                    onSearch: onSearch,
                 ),
              ),
            ),
          ),
        ),
         IconBtn(
           sideOpen ? Icons.view_sidebar : Icons.view_sidebar_outlined,
           '显示或隐藏侧栏（Ctrl+B）',
           onToggleSide,
           color: sideOpen ? ide.accent : null,
         ),
         IconBtn(
           ws.assistantPanel.visible
               ? Icons.auto_awesome
               : Icons.auto_awesome_outlined,
           '切换 AI 侧栏（Ctrl+Alt+I）',
           () {
             if (ws.assistantTabs.isEmpty) {
               openNewAiSession(ws);
             } else if (MediaQuery.sizeOf(context).width >= 600 &&
                 ws.assistantPanel.visible) {
               ws.hideAssistantPanel();
             } else {
               ws.toggleAssistantPanel();
             }
           },
           color: ws.assistantPanel.visible ? ide.accent : null,
         ),
         SizedBox(width: 28, height: 28, child: TabLayoutMenu(ws: ws)),
        const SizedBox(width: Space.s),
        const WindowButtonsGap(),
        ]),
      ]),
    );
  }
}

/// One title-bar entry for file names, file contents and commands.
class _WorkspaceSearchEntry extends StatelessWidget {
  final Workspace ws;
  final bool searchable, searching;
  final VoidCallback onSearch;
  const _WorkspaceSearchEntry({
    required this.ws,
    required this.searchable,
    required this.searching,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return LayoutBuilder(
      builder: (context, box) => Tooltip(
        message: searchable ? '搜索文件名、内容或命令' : '搜索命令',
        child: Semantics(
          button: true,
          child: Material(
            color: ide.surface,
            shape: RoundedRectangleBorder(
              borderRadius: UiMetrics.controlCorners,
              side: BorderSide(color: searching ? ide.accent.withValues(alpha: .48) : ide.borderStrong),
            ),
            child: InkWell(
              key: const ValueKey('workbench-quick-open'),
              onTap: onSearch,
              borderRadius: UiMetrics.controlCorners,
              child: SizedBox(
                height: 28,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: ws.searchQuery,
                  builder: (_, value, _) => Padding(
                    padding: EdgeInsets.symmetric(horizontal: box.maxWidth >= 85 ? Space.m : 0),
                    child: Row(
                      mainAxisAlignment: box.maxWidth < 85 ? MainAxisAlignment.center : MainAxisAlignment.start,
                      children: [
                        if (box.maxWidth >= 18)
                          Icon(Icons.search_rounded, size: 17,
                            color: searching ? ide.accent : ide.textDim),
                        if (box.maxWidth >= 85) ...[
                          const SizedBox(width: Space.m),
                          Expanded(child: Text(
                            searching ? (value.text.isEmpty ? '搜索文件内容…' : '内容搜索：${value.text}')
                              : searchable ? '搜索文件、内容或命令…' : '搜索命令…',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: ide.textDim),
                          )),
                        ],
                        if (box.maxWidth >= 270) ...[
                          const SizedBox(width: Space.m),
                          Text(searching ? 'Ctrl+Shift+F' : searchable ? 'Ctrl+P' : 'Ctrl+Shift+P',
                            style: TextStyle(fontSize: 10.5, color: ide.textFaint)),
                        ],
                      ],
                    ),
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
    Widget item(IconData icon, String label, String tip, {bool on = false, bool dim = false, required VoidCallback tap}) =>
      UiNavigationItem(icon: icon, label: label, tooltip: tip, selected: on, dim: dim, onTap: tap);
    String label(Feature f) => switch (f.id) {
      'files' => '文件', 'git' => 'Git', 'development' => '开发',
      'systemd' => '服务', 'monitor' => '监控', 'net' => '端口', 'ai' => 'AI',
      _ => f.title,
    };
    final visibleFeatures = [for (final f in features.all)
      if (ws.entry?.isLocal != true || const ['files', 'terminal', 'search', 'git', 'development', 'ai', 'monitor', 'proxy'].contains(f.id)) f];
    final primary = [for (final id in const ['files', 'search', 'git', 'terminal', 'ai'])
      ...visibleFeatures.where((f) => f.id == id)];
    final secondary = visibleFeatures.where((f) => !primary.contains(f)).toList();
    final feats = [
      for (final f in primary)
        if (!vertical || f.id != 'search')
        Builder(
          builder: (_) {
            final st = ws.link == null ? FeatureState.available : ws.stateOf(f);
            final usable = st == FeatureState.available || st == FeatureState.loading;
            final tip = !usable ? '${f.title}（${_stateText(st)}）'
                : f.id == 'terminal' && vertical ? '切换终端面板（Ctrl+J）' : f.title;
            return item(f.icon, label(f), tip, on: current == f.id || (f.id == 'terminal' && ws.terminalPanel.visible) || (f.id == 'ai' && ws.assistantPanel.visible), dim: !usable, tap: () => onPick(f));
          },
        ),
    ];
    if (vertical) {
      return Container(
        width: _railWidth,
        decoration: BoxDecoration(color: ide.activityBar, border: Border(right: BorderSide(color: ide.border))),
        child: Column(children: [
          // Monitoring, services, ports and proxy are what a server tool is for:
          // they sit on the bar, after a thin rule, not behind a menu.
          Expanded(child: SingleChildScrollView(child: Column(children: [
            ...feats,
            if (secondary.isNotEmpty) Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Divider(height: 1, color: ide.border),
            ),
            for (final f in secondary)
              Builder(builder: (_) {
                final st = ws.link == null ? FeatureState.available : ws.stateOf(f);
                final usable = st == FeatureState.available || st == FeatureState.loading;
                return item(f.icon, label(f), usable ? f.title : '${f.title}（${_stateText(st)}）', on: current == f.id, dim: !usable, tap: () => onPick(f));
              }),
          ]))),
          item(Icons.tune_rounded, '概览', '服务器概览与设置', tap: onOverview),
          item(Icons.settings_outlined, '设置', '设置（Ctrl+,）', tap: () => ws.openTab(settingsTab(ws.app))),
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
          Expanded(child: item(Icons.more_horiz_rounded, '更多', '更多', tap: () => _more(context))),
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
        child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.only(bottom: Space.m),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: const Icon(Icons.keyboard_command_key), title: const Text('命令面板'), onTap: () => go(c, onPalette)),
              for (final f in features.all.where((f) => !const ['files', 'search', 'git', 'terminal', 'ai'].contains(f.id)))
                if (ws.entry?.isLocal != true || const ['development', 'monitor', 'proxy'].contains(f.id)) ListTile(leading: Icon(f.icon), title: Text(f.title), onTap: () => go(c, () => onPick(f))),
              ListTile(leading: const Icon(Icons.dns_outlined), title: const Text('服务器'), onTap: () => go(c, onServers)),
              ListTile(leading: const Icon(Icons.tune_rounded), title: const Text('服务器概览'), onTap: () => go(c, onOverview)),
              ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('设置'), onTap: () => go(c, () => ws.openTab(settingsTab(ws.app)))),
            ],
          ),
        )),
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
/// the unit list its filter. Each workspace owns a host. Connection gates hide
/// unavailable tools without destroying them; feature models refresh their data
/// when the connection changes.
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
  /// Features visited in this workspace are created lazily and retained.
  final Set<String> _visited = {};
  final Map<Feature, SideBarView?> _views = {};
  int _revision = -1;
  bool _dependenciesChanged = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dependenciesChanged = true;
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, features = widget.features, feature = widget.feature;
    final ide = Ide.of(context);
    final refresh = _dependenciesChanged || _revision != ws.viewRevision;
    _revision = ws.viewRevision;
    _dependenciesChanged = false;
    _visited.add(feature.id);

    // the title and actions of the feature that is shown
    var title = feature.title;
    var actions = const <Widget>[];
    Widget one(Feature f) {
      final st = ws.stateOf(f);
      final available = ws.link != null && st == FeatureState.available;
      if (available && (refresh || !_views.containsKey(f))) _views[f] = f.sideBar(context, ws);
      final v = _views[f];
      if (f.id == feature.id) {
        title = v?.title ?? f.title;
        if (available) actions = v?.actions ?? const [];
      }
      return RetainedPages(index: available ? 0 : 1, children: [
        v?.body ?? EmptyHint(icon: f.icon, text: '${f.title}在编辑区里打开', actionLabel: '打开', onAction: () => f.open(ws)),
        if (ws.link == null) NotConnected(ws: ws)
        else if (st == FeatureState.loading) const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
        else _Unavailable(ws: ws, feature: f, state: st),
      ]);
    }

    final order = features.all;
    final children = <Widget>[
      for (final f in order)
        if (_visited.contains(f.id))
          // Link changes refresh models, never the feature's state identity.
          KeyedSubtree(
            key: ValueKey('${ws.serverId}/${f.id}'),
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
           if (feature.id != 'files' && !(feature.id == 'search' &&
               MediaQuery.sizeOf(context).width >= desktopSearchMinWidth &&
               ws.stateOf(feature) == FeatureState.available)) UiPanelHeader(title: title, icon: feature.icon,
            subtitle: ws.project?.name ?? ws.name, actions: actions),
          Expanded(
            child: RetainedPages(
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
  @override
  Widget build(BuildContext context) {
    final ws = widget.ws, features = widget.features;
    final terminal = features.byId('terminal');
    return WorkbenchView(ws: ws,
      collapseEmptyEditor: MediaQuery.sizeOf(context).width >= _narrow,
      empty: _Welcome(ws: ws, features: features, onPalette: widget.onPalette, onFind: widget.onFind),
      onNewAssistant: () => openNewAiSession(ws),
      assistantHistoryBuilder: (onOpened) => AiSessionSidebar(ws: ws, onOpened: onOpened, showNewButton: false),
      onNewTerminal: ws.link != null && terminal != null && ws.stateOf(terminal) == FeatureState.available
        ? () => createSession(ws, context: context) : null,
      terminalSessionsBuilder: (onOpened) => LinkGate(ws: ws, builder: (_, _) {
        final feature = features.byId('terminal');
        if (feature == null) return const SizedBox();
        final state = ws.stateOf(feature);
        if (state == FeatureState.loading) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
        if (state != FeatureState.available) return _Unavailable(ws: ws, feature: feature, state: state);
        return SessionList(ws: ws, compact: true, onOpened: onOpened);
      }),
    );
  }
}

/// The tabs of one side. Split, the left strip lists every tab but the right
/// side's, and the right strip only its own: one tab is never on both.

/// A tab's close button. Unsaved, it is a dot that turns into the button
/// under the mouse, as in VS Code.

/// What the editor area shows with no tab open: the server, what can be
/// started, and the keys worth knowing.
class _Welcome extends StatelessWidget {
  final Workspace ws;
  final Features features;
  final VoidCallback onPalette, onFind;
  const _Welcome({required this.ws, required this.features, required this.onPalette, required this.onFind});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final connected = ws.link != null;
    final desktop = MediaQuery.sizeOf(context).width >= _narrow;
    bool usable(String id) {
      final f = features.byId(id);
      return f != null && ws.stateOf(f) == FeatureState.available;
    }

    final st = ws.status;
    final subtitle = connected
        // The local agent listens on a random port: that address means nothing to
        // the user, so only a remote server's is shown (the status bar tooltip has both).
        ? [ws.link!.server.os, 'agent ${ws.link!.server.version}', if (ws.entry?.isLocal != true) ?st.addr].where((s) => s.isNotEmpty).join(' · ')
        : switch (st.state) {
            ConnState.connecting => '正在连接…',
            ConnState.waiting => '${st.retryIn?.inSeconds ?? 0} 秒后重试',
            ConnState.failed => st.failure?.message ?? '连接失败',
            _ => '未连接',
          };
    final actions = <_Action>[
      if (ws.entry?.isLocal == true) _Action(Icons.folder_open, '打开本机文件夹', '无需服务器，直接开发本机项目', () => openLocalFolder(ws.app)),
      if (connected && !desktop) ...[
        if (usable('search')) _Action(Icons.search_rounded, '快速打开文件', '按文件名模糊查找', onFind, keys: 'Ctrl+P'),
      ] else if (!connected)
        _Action(Icons.sync_rounded, ws.entry?.isLocal == true ? '启动本地 agent' : '连接', ws.entry?.isLocal == true ? '随客户端运行，不需要管理员权限' : '连接到这台服务器', () => ws.app.connect(ws.serverId)),
      if (!desktop)
        _Action(Icons.keyboard_command_key, '命令面板', '查找命令、切换布局与管理工作台', onPalette, keys: 'Ctrl+Shift+P'),
      if (!desktop || (connected && !usable('search')))
        _Action(Icons.tune_rounded, '工作区概览', '连接信息、服务开关与 agent 管理', () => ws.openTab(overviewTab(ws, features))),
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  padding: const EdgeInsets.all(5),
                  child: Image.asset('assets/branding/aurora3-256.png', semanticLabel: 'Aurora 3'),
                ),
                const SizedBox(width: Space.xl),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(ws.project?.name ?? '开始工作', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Row(children: [
                      StatusDot(connColor(ide, st.state), size: 7),
                      const SizedBox(width: Space.s + 1),
                      Flexible(child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: ide.textDim, fontSize: 12.5))),
                    ]),
                  ]),
                ),
              ]),
              if (actions.isEmpty) ...[
                const SizedBox(height: Space.l),
                Text('从顶部搜索开始，或在文件树中打开文件。',
                  style: TextStyle(fontSize: 12, color: ide.textDim)),
              ] else ...[
                const SizedBox(height: Space.l),
                LayoutBuilder(builder: (_, box) => Wrap(spacing: Space.m, runSpacing: Space.m, children: [
                  for (final a in actions) SizedBox(width: box.maxWidth >= 560 ? (box.maxWidth - Space.m) / 2 : box.maxWidth,
                    child: _ActionCard(a)),
                ])),
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
      child: InkWell(
        onTap: a.run,
        borderRadius: BorderRadius.circular(Radii.m),
        focusColor: ide.selection,
        child: Tooltip(message: a.detail, child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.all(Space.l),
          decoration: BoxDecoration(
            color: _hover ? ide.hover : ide.sideBar,
            borderRadius: BorderRadius.circular(Radii.m),
            border: Border.all(color: _hover ? ide.borderStrong : ide.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(a.icon, size: 18, color: ide.accent),
              const SizedBox(width: Space.m),
              Expanded(child: Text(a.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.text))),
              Icon(Icons.arrow_forward_rounded, size: 14, color: ide.textFaint),
            ]),
            const SizedBox(height: Space.s),
            Text(a.detail, style: TextStyle(fontSize: 12, color: ide.textDim, height: 1.4)),
            if (a.keys != null && !InputMode.isTouch(context)) ...[const SizedBox(height: Space.s), KeyCaps(a.keys!)],
          ]),
        )),
      ),
    );
  }
}

// ---- status bar ----

class _StatusBar extends StatelessWidget {
  final Workspace ws;
  final AppState app;
  final VoidCallback onTapConn, onToggleAssistant;
  const _StatusBar({
    required this.ws,
    required this.app,
    required this.onTapConn,
    required this.onToggleAssistant,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final st = ws.status;
    final warning = app.connectionWarnings[ws.serverId];
    final text = switch (st.state) {
      ConnState.connected => ws.entry?.isLocal == true ? '本机已就绪' : '已连接',
      ConnState.connecting => '正在连接…',
      ConnState.waiting => '${st.retryIn?.inSeconds ?? 0} 秒后重试',
      ConnState.failed => st.failure?.message ?? '连接失败',
      ConnState.idle => '未连接',
    };
    final style = TextStyle(color: ide.statusText, fontSize: 12);
    Widget quickItem(
      IconData icon,
      String label,
      String tip,
      bool active,
      VoidCallback onTap,
    ) => Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: active ? ide.accent : ide.statusText.withValues(alpha: 0.78),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: style.copyWith(
                  color: active ? ide.text : ide.statusText,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Container(
      height: InputMode.isTouch(context) ? 32 : 23,
      decoration: BoxDecoration(color: ide.statusBar, border: Border(top: BorderSide(color: ide.border))),
      padding: const EdgeInsets.symmetric(horizontal: Space.s),
      child: Row(
        children: [
          Expanded(flex: 2, child: Tooltip(
            message: '${ws.name}${st.addr == null ? '' : '\n${st.addr}'}${ws.link == null ? '' : '\nagent ${ws.link!.server.version}'}${warning == null ? '' : '\n$warning'}\n${st.state == ConnState.connected ? '点击打开服务器概览' : '点击重新连接'}',
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
                    Expanded(
                      child: Text(warning == null ? text : '$text · 记录待重试', style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
          )),
          if (ws.active != null)
            Flexible(child: ValueListenableBuilder<String>(
              valueListenable: ws.active!.status,
              builder: (_, v, _) {
                if (v.isEmpty) return const SizedBox.shrink();
                final tap = ws.active?.onStatusTap;
                final label = Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: 2),
                  child: Text(v, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                );
                if (tap == null) return label;
                return Tooltip(
                  message: '点击跳转到行（Ctrl+G）',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.s),
                    onTap: tap,
                    child: label,
                  ),
                );
              },
            )),
          if (!InputMode.isTouch(context)) ...[
            quickItem(
              Icons.auto_awesome_outlined,
              'AI',
              'AI 侧栏（Ctrl+Alt+I）',
              ws.assistantPanel.visible,
              onToggleAssistant,
            ),
          ],
          ListenableBuilder(listenable: app.appearance, builder: (_, _) => Tooltip(message: '界面缩放 · 点击打开设置（Ctrl+,）',
            child: InkWell(borderRadius: BorderRadius.circular(Radii.s), onTap: () => ws.openTab(settingsTab(app)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text('${(app.appearance.value.uiScale * 100).round()}%', style: style))))),
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
    final terminal = showEditor && ws.terminalFocused && ws.terminalPanel.visible;
    return Container(
      height: 52,
      color: ide.frame,
      padding: const EdgeInsets.only(left: Space.xs),
      child: WindowDragArea(
        child: Row(
        children: [
          if (showEditor) IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back_rounded)) else const SizedBox(width: Space.l),
          Expanded(
            child: terminal
                ? Text(ws.project?.name ?? ws.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ide.textDim))
                : showEditor && t != null
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
          if (showEditor && !terminal && ws.visibleTabs.length > 1)
            WorkbenchMenuButton<String>(
              tooltip: '切换标签',
              icon: Badge(label: Text('${ws.visibleTabs.length}'), child: const Icon(Icons.layers_outlined)),
              onSelected: ws.activate,
              itemBuilder: (_) => [
                for (final x in ws.visibleTabs)
                  PopupMenuItem(
                    value: x.id,
                    child: Row(
                      children: [
                        Icon(x.icon, size: 16, color: x.id == ws.focusedId ? ide.accent : ide.textDim),
                        const SizedBox(width: Space.m),
                        Flexible(child: Text(x.title, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
              ],
            ),
          if (showEditor && !terminal && t != null) IconButton(onPressed: () => ws.closeTab(t.id), icon: const Icon(Icons.close_rounded)),
          const WindowButtonsGap(),
        ],
      ),
      ),
    );
  }
}

/// The server list that drops down from the title bar.
class _ServerSwitcher extends StatelessWidget {
  final AppState app;
  final VoidCallback onClose, onAdd;

  /// Opens the settings and services page of a server (by id).
  final void Function(String id) onOverview;
  const _ServerSwitcher({required this.app, required this.onClose, required this.onAdd, required this.onOverview});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final p = app.profile;
    return FloatingSurface(
      constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height - 80).clamp(100.0, 440.0)),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l + 2, Space.l, Space.l + 2, Space.s),
              child: Text('本机与远程服务器', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.textFaint, letterSpacing: 0.3)),
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
                      detail: s.isLocal ? '本地 agent · 当前 Windows 用户' : s.ssh?.host,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (s.id == p.selected) Icon(Icons.check_rounded, size: 16, color: ide.accent),
                        IconBtn(Icons.tune_rounded, '服务器概览与设置：服务开关、升级 agent、重新配对、卸载', () => onOverview(s.id), size: 15),
                      ]),
                      onTap: () {
                        app.select(s.id);
                        onClose();
                      },
                    ),
                ],
              ),
            ),
            const Divider(),
            if (Platform.isWindows) TreeRow(leading: Icon(Icons.folder_open, size: 16, color: ide.accent), label: '打开本机文件夹…', onTap: () { onClose(); unawaited(openLocalFolder(app)); }),
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
    return Column(children: [
      WindowDragArea(
        child: SizedBox(
          height: WindowFrame.height,
          child: Row(children: [
            SizedBox(
              width: 48,
              child: Center(child: Image.asset('assets/branding/aurora3-256.png', width: 18, height: 18, semanticLabel: 'Aurora 3')),
            ),
            Text('Aurora', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.textDim)),
          ]),
        ),
      ),
      Expanded(child: Center(
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
              Text(Platform.isWindows ? '直接打开本机文件夹，编辑代码、运行 PowerShell 和使用 AI。也可以连接远程 Linux 服务器。' : '连上一台 Linux 服务器，就能编辑文件、开终端、管理 git 和服务。',
                style: TextStyle(color: ide.textDim, height: 1.55)),
              const SizedBox(height: Space.xxl),
              if (Platform.isWindows) ...[
                FilledButton.icon(onPressed: () => openLocalFolder(app), icon: const Icon(Icons.folder_open), label: const Text('打开本机文件夹')),
                const SizedBox(height: Space.l),
              ],
              step('1', '填写服务器的 SSH 地址和账号'),
              step('2', 'Aurora 通过 SSH 在服务器上安装 agent'),
              step('3', '之后直接加密连接 agent'),
              const SizedBox(height: Space.l),
              FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('添加服务器')),
            ],
          ),
        ),
      ),
      )),
    ]);
  }
}
