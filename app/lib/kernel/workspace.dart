// One server's workspace: its editor tabs, what its agent reports about each
// service, and the way features reach the link. It outlives the widgets: the
// shell can be rebuilt, or another server shown, and the tabs stay.
import 'dart:async';
import 'dart:convert';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../state/app_state.dart';
import '../features/files/transfers.dart';
import '../features/files/file_ops.dart' show FileClipboard;
import 'editor_tab.dart';
import 'feature.dart';
import 'file_watch.dart';
import 'widgets.dart';
import 'tab_layout.dart';

class Workspace extends ChangeNotifier {
  final AppState app;
  final String serverId;
  final List<EditorTab> tabs = [];
  final Map<String, TabLayout> _layouts = {};
  final Map<String, Future<bool>> _closingTabs = {};
  int editorFocusRequest = 0;
  String? get activeId => tabLayout.groups.first.active;
  set activeId(String? id) => tabLayout.groups.first.active = id;
  String? _projectId;
  int _projectRevision = 0;
  final Map<String, String?> _activeByProject = {};
  final Set<String> _restored = {};
  final Map<String, WorkspaceView> _views = {};
  final Set<String> _dirtyViews = {};
  Future<bool>? _flushingViews;
  String? viewSaveError;
  Timer? _saveViewTimer;
  final Set<String> _geometryDirty = {};
  final ValueNotifier<int> geometryRevision = ValueNotifier(0);
  int? _geometryFrame;
  bool focusMode = false;
  bool _disposed = false;
  Future<void> _projectChanges = Future.value();
  bool _notifyQueued = false;

  String get projectKey => _projectId ?? '';
  ProjectWorkspace? get project => entry?.workspace(_projectId);
  List<EditorTab> get visibleTabs {
    final visible = {for (final t in _tabsFor(projectKey)) t.id: t};
    return [for (final id in tabLayout.ordered) if (visible[id] != null) visible[id]!];
  }

  TabLayout get tabLayout => _layoutFor(projectKey);
  TabLayout _layoutFor(String key) => _layouts.putIfAbsent(key, () {
    final view = _viewForKey(key);
    final ids = {..._tabsFor(key).map((t) => t.id), if (!_restored.contains(key)) ...view.files.map((f) => 'file:${f.root}:${f.path}')};
    final layout = TabLayout.fromJson(view.tabLayout, ids);
    if (view.tabLayout.isEmpty) {
      final id = _activeByProject[key] ?? (view.activeFile == null ? null : 'file:${view.activeFile!.root}:${view.activeFile!.path}');
      if (id != null) layout.activate(id);
    }
    return layout;
  });

  List<EditorTab> tabsInGroup(String id) {
    final byId = {for (final t in tabs) t.id: t};
    return [for (final tabId in tabLayout.group(id)?.tabs ?? <String>[]) ?byId[tabId]];
  }
  int get projectGeneration => _projectRevision;

  void _syncLayout(String key) {
    final view = _viewForKey(key);
    _layoutFor(key).reconcile({..._tabsFor(key).map((t) => t.id), if (!_restored.contains(key)) ...view.files.map((f) => 'file:${f.root}:${f.path}')});
  }

  /// agent.services: id, enabled, available, reason, ops.
  List<Map<String, dynamic>> services = [];
  String? servicesError;
  Link? _servicesFor;

  /// Whether services is the answer of the current link. False from the
  /// moment a link is up until agent.services has answered.
  bool servicesLoaded = false;

  /// Connection/profile/service changes invalidate view configurations. Tab
  /// activation alone does not: a retained editor must not be rebuilt merely
  /// because the user chooses a different side bar or editor tab.
  int viewRevision = 0;

  /// Raised when a file on the server changed because of something done here
  /// (a save): the file tree reloads what it shows.
  final ValueNotifier<int> filesRevision = ValueNotifier(0);

  /// What the file tree's Copy or Cut remembered. Shared by every project page
  /// of this server, so something copied in one project can be pasted in another.
  final ValueNotifier<FileClipboard?> fileClipboard = ValueNotifier(null);

  /// The transfer list the file tree shows; set when the tree is built. The
  /// viewers download through it, so their transfers appear in the same list.
  Transfers? transfers;

  /// Narrow layouts show either the side bar or the editor area.
  bool compactEditor = false;

  /// Raised by Ctrl+Shift+F: the search view puts the cursor in its query.
  final ValueNotifier<int> focusSearch = ValueNotifier(0);

  /// Notices of files changed on the server, for open editors.
  late final FileWatch watch = FileWatch(() => link);

  Workspace(this.app, this.serverId) {
    final e = entry;
    _projectId = e?.workspace(e.selectedWorkspace)?.id;
    app.addListener(_onApp);
    _onApp();
  }

  ServerEntry? get entry => app.server(serverId);
  String get name => entry?.name ?? serverId;
  Link? get link => app.link(serverId);
  ConnStatus get status => app.status(serverId);

  void _onApp() {
    if (_disposed) return;
    final e = entry;
    final selected = e?.workspace(e.selectedWorkspace)?.id;
    if (_projectId != selected) {
      if (_restored.contains(projectKey)) _activeByProject[projectKey] = focusedId;
      _projectRevision++;
      _projectId = selected;
      focusMode = false;
      _syncLayout(projectKey);
    }
    viewRevision++;
    watch.relink();
    final l = link;
    if (l != null && !identical(l, _servicesFor)) {
      _servicesFor = l;
      servicesLoaded = false;
      unawaited(refreshServices());
    }
    if (l == null) {
      _servicesFor = null;
      servicesLoaded = false;
    }
    _queueNotify();
  }

  /// Profile updates may arrive while a caller is still inside AppState's
  /// synchronous ChangeNotifier dispatch. Queueing the workspace notification
  /// prevents a feature listener from starting another profile write
  /// re-entrantly and also keeps view saves out of that dispatch stack.
  void _queueNotify() {
    if (_disposed || _notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  /// Reads the service list again (after a switch, or a new link).
  Future<void> refreshServices() async {
    final l = link;
    if (l == null) return;
    try {
      final r = await l.call('agent.services') as Map;
      if (_disposed || !identical(l, link)) return;
      services = [for (final s in r['services'] as List) (s as Map).cast<String, dynamic>()];
      servicesError = null;
    } on OpError catch (e) {
      if (_disposed || !identical(l, link)) return;
      servicesError = e.message;
    } on Object {
      if (_disposed || !identical(l, link)) return;
      servicesError = '服务列表读取失败，请重试连接';
    }
    // an answer or an error: either way the wait is over
    if (identical(l, link)) servicesLoaded = true;
    if (_disposed) return;
    viewRevision++;
    _queueNotify();
  }

  // ---- what the agent offers ----

  Map<String, dynamic>? serviceInfo(String id) {
    for (final s in services) {
      if (s['id'] == id) return s;
    }
    return null;
  }

  FeatureState stateOf(Feature f) {
    if (link != null && !servicesLoaded) return FeatureState.loading;
    final s = serviceInfo(f.service);
    if (s == null) return FeatureState.unreported;
    if (s['enabled'] != true) return FeatureState.disabled;
    if (s['available'] == false) return FeatureState.unavailable;
    final ops = ((s['ops'] as List?) ?? const []).cast<String>();
    for (final op in f.ops) {
      if (!ops.contains(op)) return FeatureState.outdated;
    }
    return FeatureState.available;
  }

  String reasonOf(Feature f) => (serviceInfo(f.service)?['reason'] as String?) ?? '';

  /// Whether the agent reports an operation (an optional part of a feature).
  bool hasOp(String op) => link?.server.caps.contains(op) ?? false;

  // ---- tabs ----

  /// The tab the user is working in (the focused side when split).
  EditorTab? get active {
    final id = focusedId;
    for (final t in tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  EditorTab? tab(String id) {
    for (final t in tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  void updateTabTitle(String id, String title) {
    final current = tab(id);
    if (_disposed || current == null || title.isEmpty || current.title == title) return;
    current.title = title;
    notifyListeners();
  }

  /// Opens [t], or brings the open tab with the same id to the front.
  void openTab(EditorTab t) {
    final existing = tab(t.id);
    if (existing != null) {
      if (existing.file != null) existing.projects.add(projectKey);
      _syncLayout(projectKey);
      if (!identical(t, existing)) t.dispose();
      activate(t.id);
      return;
    }
    tabs.add(t);
    if (t.file != null) t.projects.add(projectKey);
    _syncLayout(projectKey);
    _show(t.id);
    compactEditor = true;
    rememberFiles();
    notifyListeners();
  }

  void activate(String id) {
    final t = tab(id);
    if (t == null) return;
    if (t.file != null) t.projects.add(projectKey);
    _syncLayout(projectKey);
    _show(id);
    compactEditor = true;
    rememberFiles();
    notifyListeners();
  }

  /// Reveals [id] in its group, or adds a new tab to the focused group.
  void _show(String id) {
    tabLayout.add(id);
    editorFocusRequest++;
    _activeByProject[projectKey] = focusedId;
  }

  // ---- editor groups ----
  // The layout owns groups and geometry, not document state. The older
  // sideId/sideFocused/splitActive API remains only for dual-pane callers.

  /// The tab on the right side, or null when the editor is not split.
  String? get sideId => tabLayout.groups.length > 1 ? tabLayout.groups[1].active : null;

  /// Which side has the focus for Ctrl+W, Ctrl+Tab and the status bar.
  bool get sideFocused => tabLayout.groups.length > 1 && tabLayout.focused == tabLayout.groups[1].id;

  bool get split => tabLayout.groups.length > 1;

  /// The tab the user is working in: the right one when that side has focus.
  String? get focusedId => tabLayout.current.active;

  /// Legacy dual-pane toggle; the shell's Ctrl+\ uses splitGroup instead.
  void splitActive() {
    final id = focusedId;
    if (id == null) return;
    if (split && id == sideId) return unsplit();
    final others = visibleTabs.where((t) => t.id != id).toList();
    if (others.isEmpty) return toast('再打开一个标签才能拆分');
    // the left side shows the tab that was before it, the right side this one
    final i = visibleTabs.indexWhere((t) => t.id == id);
    final from = tabLayout.owner(id)!;
    tabLayout.split(from.id, SplitAxis.horizontal, tab: id);
    from.active = others[(i - 1).clamp(0, others.length - 1)].id;
    _layoutChanged();
  }

  void unsplit() {
    arrangeEditors(EditorArrangement.single);
  }

  void focusSide(bool right) {
    focusGroup(tabLayout.groups[right && split ? 1 : 0].id);
  }

  void focusGroup(String id) {
    if (tabLayout.focused == id || tabLayout.group(id) == null) return;
    tabLayout.focus(id);
    editorFocusRequest++;
    _layoutChanged();
  }

  void focusGroupAt(int index) {
    if (index >= 0 && index < tabLayout.groups.length) focusGroup(tabLayout.groups[index].id);
  }

  void arrangeEditors(EditorArrangement arrangement) { focusMode = false; tabLayout.arrange(arrangement); _layoutChanged(); }
  void splitGroup(SplitAxis axis, {String? group, String? tabId, bool before = false}) {
    final from = group ?? tabLayout.focused;
    if (tabLayout.split(from, axis, tab: tabId ?? tabLayout.group(from)?.active, before: before) == null) {
      toast('最多同时显示 4 个编辑组；可将标签拖入已有分组');
      return;
    }
    focusMode = false;
    _layoutChanged();
  }
  void mergeGroup(String id) { focusMode = false; tabLayout.mergeGroup(id); _layoutChanged(); }
  void moveTab(String id, String group, {int? index}) {
    if (tab(id) == null) return;
    if (tabLayout.move(id, group, index: index)) _layoutChanged();
  }
  void reorderActive(int delta) {
    final id = focusedId;
    if (id == null) return;
    final g = tabLayout.owner(id)!;
    final i = g.tabs.indexOf(id);
    moveTab(id, g.id, index: (i + (delta > 0 ? 2 : -1)).clamp(0, g.tabs.length));
  }
  void pinTab(String id) { tabLayout.togglePin(id); _layoutChanged(); }
  void setTabPlacement(TabPlacement placement) { tabLayout.placement = placement; _layoutChanged(); }
  void setSideWidth(double width) {
    if (!width.isFinite) return;
    final next = width.clamp(180.0, 640.0);
    if (next == tabLayout.sideWidth) return;
    tabLayout.sideWidth = next; _geometryChanged();
  }
  void setTabsWidth(double width) {
    if (!width.isFinite) return;
    final next = width.clamp(120.0, 400.0);
    if (next == tabLayout.tabsWidth) return;
    tabLayout.tabsWidth = next; _geometryChanged();
  }
  void setTabWidth(double width) {
    if (!width.isFinite) return;
    final next = width.clamp(100.0, 260.0);
    if (next == tabLayout.tabWidth) return;
    tabLayout.tabWidth = next; _geometryChanged();
  }
  void resizeGroup(String split, double ratio) {
    if (tabLayout.resizeSplit(split, ratio)) _geometryChanged();
  }
  void toggleFocusMode() {
    if (!split) { focusMode = false; return; }
    focusMode = !focusMode;
    _scheduleGeometryFrame();
  }
  // Dragging never invalidates file trees, AI configurations or terminal
  // listeners. Reflow at most once per frame; serialize once after the gesture.
  void _geometryChanged() {
    if (_disposed) return;
    _geometryDirty.add(projectKey);
    _scheduleViewSave();
    _scheduleGeometryFrame();
  }
  void _scheduleGeometryFrame() {
    if (_disposed || _geometryFrame != null) return;
    _geometryFrame = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _geometryFrame = null;
      if (!_disposed) geometryRevision.value++;
    });
  }
  void _captureGeometry() {
    final keys = _geometryDirty.toList();
    _geometryDirty.clear();
    for (final key in keys) { _rememberFilesFor(key); }
  }
  void _layoutChanged() {
    if (_disposed) return;
    _activeByProject[projectKey] = focusedId;
    rememberFiles();
    notifyListeners();
  }

  /// Snapshot instances, not only IDs; leaving the project cancels the rest
  /// even if it is selected again before a dirty prompt is answered.
  Future<void> closeTabs(Iterable<String> ids, {bool keepPinned = true}) async {
    final revision = _projectRevision;
    final closing = [for (final id in ids) ?tab(id)];
    for (final current in closing) {
      if (_disposed || revision != _projectRevision) break;
      if (!identical(tab(current.id), current)) continue;
      if (keepPinned && tabLayout.pinned.contains(current.id)) continue;
      if (!await closeTab(current.id)) break;
    }
  }

  /// Closes a tab; asks first when it has unsaved changes. Returns whether it closed.
  Future<bool> closeTab(String id) {
    final key = '$projectKey\u0000$id';
    return _closingTabs[key] ??= _closeTab(id, projectKey).whenComplete(() { _closingTabs.remove(key); });
  }

  Future<bool> _closeTab(String id, String key) async {
    final t = tab(id);
    if (t == null) return true;
    if (!visibleTabs.contains(t)) return false;
    final shared = t.file != null && t.projects.length > 1;
    if (!shared && t.confirmClose != null && !await t.confirmClose!()) return false;
    if (_disposed || !tabs.contains(t)) return true;
    // Closing a project membership must not discard a shared buffer that is
    // still open elsewhere. Its final close retains the normal dirty prompt.
    if (t.file != null && t.projects.length > 1) {
      t.projects.remove(key);
    } else {
      tabs.remove(t);
      for (final layout in _layouts.values) { layout.remove(id); }
      t.dispose();
    }
    _layoutFor(key).remove(id);
    _activeByProject[key] = _layoutFor(key).current.active;
    _rememberFilesFor(key, removed: t.file);
    notifyListeners();
    return true;
  }

  /// Closes tabs that match [test] without asking (their content is gone from
  /// the server, e.g. a session that ended).
  void dropTabs(bool Function(EditorTab) test) {
    final gone = tabs.where(test).toList();
    if (gone.isEmpty) return;
    for (final t in gone) {
      tabs.remove(t);
      for (final layout in _layouts.values) { layout.remove(t.id); }
      if (t.file != null) {
        for (final key in t.projects) {
          final view = _viewForKey(key);
          view.files.remove(t.file);
          if (view.activeFile == t.file) view.activeFile = null;
          _dirtyViews.add(key);
        }
      }
      t.dispose();
    }
    _scheduleViewSave();
    notifyListeners();
  }

  /// Ctrl+Tab cycles within the focused editor group.
  void next(int step) {
    final shown = tabsInGroup(tabLayout.focused);
    if (shown.length < 2) return;
    final i = shown.indexWhere((t) => t.id == focusedId);
    activate(shown[((i < 0 ? 0 : i) + step) % shown.length].id);
  }

  Future<void> _changeProject(Future<void> Function() action) {
    final work = _projectChanges.then((_) async {
      if (!_disposed) await action();
    });
    _projectChanges = work.catchError((Object _) {
      if (!_disposed) toast('工作区修改未能保存，请检查本机磁盘后重试', error: true);
    });
    return _projectChanges;
  }

  Future<void> selectProject(String? id) => _changeProject(() async {
    if (id != null) {
      final currentEntry = entry;
      if (currentEntry?.workspace(id) == null) return;
    }
    if (_projectId == id) return;
    rememberFiles();
    if (_dirtyViews.isNotEmpty && !await flushViews()) return;
    await app.update((p) {
      final server = p.server(serverId);
      if (server != null) server.selectedWorkspace = id;
    });
  });

  Future<void> createProject(String name, List<WorkspacePath> folders) => _changeProject(() async {
    if (name.trim().isEmpty) return;
    final id = newId();
    rememberFiles();
    if (_dirtyViews.isNotEmpty && !await flushViews()) return;
    await app.update((p) {
      final s = p.server(serverId);
      if (s == null) return;
      s.workspaces.add(ProjectWorkspace(id: id, name: name.trim(), folders: folders.toSet().toList()));
      s.selectedWorkspace = id;
    });
  });

  Future<void> renameProject(String name) async {
    final id = _projectId;
    if (name.trim().isEmpty) return;
    await _changeProject(() => app.update((p) { final w = p.server(serverId)?.workspace(id); if (w != null) w.name = name.trim(); }));
  }

  Future<void> addFolder(WorkspacePath folder) async {
    final id = _projectId;
    await _changeProject(() => app.update((p) {
      final w = p.server(serverId)?.workspace(id);
      if (w != null && !w.folders.contains(folder)) w.folders.add(folder);
    }));
  }

  Future<void> removeFolder(WorkspacePath folder) async {
    final id = _projectId;
    await _changeProject(() => app.update((p) => p.server(serverId)?.workspace(id)?.folders.remove(folder)));
  }

  Future<void> deleteProject() async {
    final id = _projectId;
    if (id == null) return;
    await _changeProject(() async {
    rememberFiles();
    if (_dirtyViews.isNotEmpty && !await flushViews()) return;
    // Removing a workspace forgets its grouping only. Dirty buffers are moved
    // to the server browser; no file or remote session is deleted.
    final moved = tabs.where((t) => t.projects.contains(id)).toList();
    await app.update((p) {
      final s = p.server(serverId);
      final removed = s?.workspace(id);
      if (s != null && removed != null) {
        s.browserView.files = {...s.browserView.files, ...removed.view.files}.toList();
        s.browserView.activeFile ??= removed.view.activeFile;
      }
      s?.workspaces.removeWhere((w) => w.id == id);
      if (s?.selectedWorkspace == id) s?.selectedWorkspace = null;
    });
    for (final t in moved) { t.projects..remove(id)..add(''); }
    _views.remove(id);
    _dirtyViews.remove(id);
    _restored.remove(id);
    _activeByProject.remove(id);
    _layouts.remove(id);
    _geometryDirty.remove(id);
    // Includes references from a project that has never been restored in this
    // process. They must survive deleting the grouping as well.
    _views[''] = WorkspaceView.fromJson(entry!.browserView.toJson());
    if (_restored.contains('')) {
      _restored.remove('');
    }
    rememberFiles();
    notifyListeners();
    });
  }

  /// Restore file references, never unsaved text, from the sealed profile.
  /// The kernel accepts a feature-provided builder and does not import files.
  void restoreFiles(EditorTab Function(WorkspacePath file) build) {
    final key = projectKey;
    final layout = _layoutFor(key);
    if (!_restored.add(key)) return;
    final view = _viewForKey(key);
    for (final file in view.files) {
      final candidate = build(file);
      final existing = tab(candidate.id);
      if (existing == null) { candidate.projects.add(key); tabs.add(candidate); }
      else { existing.projects.add(key); candidate.dispose(); }
    }
    final activeFile = view.activeFile;
    _syncLayout(key);
    if (view.tabLayout.isEmpty) {
      final id = _activeByProject[key] ?? (activeFile == null ? null : tabs.where((t) => t.file == activeFile && t.projects.contains(key)).firstOrNull?.id);
      if (id != null) layout.activate(id);
    }
    _activeByProject[key] = focusedId;
    notifyListeners();
  }

  WorkspaceView _viewForKey(String key) => _views.putIfAbsent(key, () {
    final value = entry?.viewFor(key);
    return value == null ? WorkspaceView() : WorkspaceView.fromJson(value.toJson());
  });

  WorkspaceView viewForCurrent() => _viewForKey(projectKey);
  WorkspaceView viewForProject(String key) => _viewForKey(key);

  List<EditorTab> _tabsFor(String key) => tabs.where((t) => t.file == null || t.projects.contains(key)).toList();

  void rememberFiles() => _rememberFilesFor(projectKey);

  void _rememberFilesFor(String key, {WorkspacePath? removed}) {
    _geometryDirty.remove(key);
    final view = _viewForKey(key);
    final files = [for (final t in _tabsFor(key)) if (t.file != null) t.file!];
    // Other service tabs can open before the file feature restores saved
    // files. Keep those references instead of silently replacing them by [].
    final next = _restored.contains(key) ? files : {...view.files, ...files}.toList();
    if (removed != null) next.remove(removed);
    final layout = _layoutFor(key);
    final activeFile = tab(layout.current.active ?? '')?.file;
    final allowed = {for (final file in next) 'file:${file.root}:${file.path}'};
    final defaults = layout.groups.length == 1 && layout.placement == TabPlacement.top && layout.sideWidth == 300 && layout.tabsWidth == 180 && layout.tabWidth == 160 && !layout.pinned.any(allowed.contains);
    final snapshot = next.isEmpty && defaults ? <String, dynamic>{} : layout.toJson(allowed: allowed);
    final nextActive = _restored.contains(key) || activeFile != null ? activeFile : view.activeFile;
    if (listEquals(view.files, next) && view.activeFile == nextActive && jsonEncode(view.tabLayout) == jsonEncode(snapshot)) return;
    view.files = next;
    view.activeFile = nextActive;
    view.tabLayout = snapshot;
    _queueView(key, view);
  }

  void rememberExpanded(List<WorkspacePath> paths) {
    final view = viewForCurrent();
    if (view.treeSet && listEquals(view.expanded, paths)) return;
    view.expanded = List.of(paths);
    view.treeSet = true;
    _queueView(projectKey, view);
  }

  void _queueView(String key, WorkspaceView view) {
    if (_disposed) return;
    _views[key] = view;
    _dirtyViews.add(key);
    _scheduleViewSave();
  }

  void _scheduleViewSave() {
    if (_disposed || (_dirtyViews.isEmpty && _geometryDirty.isEmpty)) return;
    _saveViewTimer?.cancel();
    _saveViewTimer = Timer(const Duration(milliseconds: 500), () { unawaited(flushViews()); });
  }

  Future<bool> flushViews() async {
    _captureGeometry();
    _saveViewTimer?.cancel();
    _saveViewTimer = null;
    if (_flushingViews != null) {
      return await _flushingViews!;
    }
    if (_dirtyViews.isEmpty) {
      return true;
    }
    final work = _flushLoop();
    final tracked = work.whenComplete(() => _flushingViews = null);
    _flushingViews = tracked;
    return await tracked;
  }

  Future<bool> _flushLoop() async {
    while (_dirtyViews.isNotEmpty || _geometryDirty.isNotEmpty) {
      _captureGeometry();
      if (_dirtyViews.isEmpty) break;
      final pending = {for (final key in _dirtyViews) key: WorkspaceView.fromJson(_viewForKey(key).toJson())};
      _dirtyViews.clear();
      if (!await _writeViews(pending)) return false;
    }
    _saveViewTimer?.cancel();
    _saveViewTimer = null;
    return true;
  }

  Future<bool> _writeViews(Map<String, WorkspaceView> pending) async {
    try {
      await app.saveWorkspaceViews(serverId, pending);
      viewSaveError = null;
      return true;
    } on Object {
      _dirtyViews.addAll(pending.keys);
      viewSaveError = '工作区视图未能保存到本机，请检查磁盘空间后重试';
      if (!_disposed) toast(viewSaveError!, error: true);
      return false;
    }
  }

  // ---- messages ----

  void toast(String msg, {bool error = false}) => Toast.show(msg, error: error);

  /// Runs [f] and shows an agent error as a message instead of throwing.
  Future<T?> guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on OpError catch (e) {
      toast(e.message, error: true);
    }
    return null;
  }

  @override
  void dispose() {
    unawaited(flushViews().then<void>((_) {}));
    _disposed = true;
    if (_geometryFrame != null) SchedulerBinding.instance.cancelFrameCallbackWithId(_geometryFrame!);
    geometryRevision.dispose();
    app.removeListener(_onApp);
    for (final t in tabs) {
      t.dispose();
    }
    filesRevision.dispose();
    fileClipboard.dispose();
    focusSearch.dispose();
    watch.dispose();
    super.dispose();
  }
}

/// Builds [builder] with the link, or says why there is none. Rebuilds with a
/// fresh state when the link is replaced (reconnect), because what a feature
/// loaded from the old link may be stale.
class LinkGate extends StatelessWidget {
  final Workspace ws;
  final Widget Function(BuildContext context, Link link) builder;
  const LinkGate({super.key, required this.ws, required this.builder});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ws,
      builder: (context, _) {
        final l = ws.link;
        if (l == null) return NotConnected(ws: ws);
        return KeyedSubtree(key: ObjectKey(l), child: builder(context, l));
      },
    );
  }
}

/// The side bar or tab body while the server is not connected.
class NotConnected extends StatelessWidget {
  final Workspace ws;
  const NotConnected({super.key, required this.ws});

  @override
  Widget build(BuildContext context) {
    final st = ws.status;
    final connecting = st.state == ConnState.connecting || st.state == ConnState.waiting;
    final text = switch (st.state) {
      ConnState.connecting => '正在连接…',
      ConnState.waiting => '连接失败，${st.retryIn?.inSeconds ?? 0} 秒后重试\n${st.failure?.message ?? ''}',
      ConnState.failed => st.failure?.message ?? '连接失败',
      _ => '未连接',
    };
    return EmptyHint(
      icon: connecting ? Icons.sync : Icons.link_off,
      text: text,
      actionLabel: connecting ? null : '连接',
      onAction: connecting ? null : () => ws.app.connect(ws.serverId),
    );
  }
}
