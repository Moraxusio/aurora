// One server's workspace: its editor tabs, what its agent reports about each
// service, and the way features reach the link. It outlives the widgets: the
// shell can be rebuilt, or another server shown, and the tabs stay.
import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../state/app_state.dart';
import '../features/files/transfers.dart';
import 'editor_tab.dart';
import 'feature.dart';
import 'widgets.dart';

class Workspace extends ChangeNotifier {
  final AppState app;
  final String serverId;
  final List<EditorTab> tabs = [];
  String? activeId;
  String? _projectId;
  final Map<String, String?> _activeByProject = {};
  final Set<String> _restored = {};
  final Map<String, WorkspaceView> _views = {};
  final Set<String> _dirtyViews = {};
  Future<bool>? _flushingViews;
  String? viewSaveError;
  Timer? _saveViewTimer;
  bool _disposed = false;
  Future<void> _projectChanges = Future.value();
  bool _notifyQueued = false;

  String get projectKey => _projectId ?? '';
  ProjectWorkspace? get project => entry?.workspace(_projectId);
  List<EditorTab> get visibleTabs => tabs.where((t) => t.file == null || t.projects.contains(projectKey)).toList();

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

  /// The transfer list the file tree shows; set when the tree is built. The
  /// viewers download through it, so their transfers appear in the same list.
  Transfers? transfers;

  /// Narrow layouts show either the side bar or the editor area.
  bool compactEditor = false;

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
      if (_restored.contains(projectKey)) _activeByProject[projectKey] = activeId;
      _projectId = selected;
      activeId = _activeByProject[projectKey];
      if (!visibleTabs.any((t) => t.id == activeId)) activeId = visibleTabs.firstOrNull?.id;
    }
    viewRevision++;
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
      services = [for (final s in r['services'] as List) (s as Map).cast<String, dynamic>()];
      servicesError = null;
    } on OpError catch (e) {
      servicesError = e.message;
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

  EditorTab? get active {
    for (final t in tabs) {
      if (t.id == activeId) return t;
    }
    return null;
  }

  EditorTab? tab(String id) {
    for (final t in tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Opens [t], or brings the open tab with the same id to the front.
  void openTab(EditorTab t) {
    final existing = tab(t.id);
    if (existing != null) {
      if (existing.file != null) existing.projects.add(projectKey);
      if (!identical(t, existing)) t.dispose();
      activate(t.id);
      return;
    }
    tabs.add(t);
    if (t.file != null) t.projects.add(projectKey);
    activeId = t.id;
    _activeByProject[projectKey] = activeId;
    compactEditor = true;
    rememberFiles();
    notifyListeners();
  }

  void activate(String id) {
    final t = tab(id);
    if (t == null) return;
    if (t.file != null) t.projects.add(projectKey);
    activeId = id;
    _activeByProject[projectKey] = activeId;
    compactEditor = true;
    rememberFiles();
    notifyListeners();
  }

  /// Closes a tab; asks first when it has unsaved changes. Returns whether it closed.
  Future<bool> closeTab(String id) async {
    final t = tab(id);
    if (t == null) return true;
    final key = projectKey;
    if (!visibleTabs.contains(t)) return false;
    final shared = t.file != null && t.projects.length > 1;
    if (!shared && t.confirmClose != null && !await t.confirmClose!()) return false;
    if (_disposed || !tabs.contains(t)) return true;
    final shown = _tabsFor(key);
    final i = shown.indexOf(t);
    // Closing a project membership must not discard a shared buffer that is
    // still open elsewhere. Its final close retains the normal dirty prompt.
    if (t.file != null && t.projects.length > 1) {
      t.projects.remove(key);
    } else {
      tabs.remove(t);
      t.dispose();
    }
    final remaining = _tabsFor(key);
    final next = remaining.isEmpty ? null : remaining[i.clamp(0, remaining.length - 1)].id;
    if (_activeByProject[key] == id) _activeByProject[key] = next;
    if (activeId == id && key == projectKey) activeId = next;
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
      if (activeId == t.id) activeId = visibleTabs.firstOrNull?.id;
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

  void next(int step) {
    final shown = visibleTabs;
    if (shown.length < 2) return;
    final i = shown.indexWhere((t) => t.id == activeId);
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
    if (!_restored.add(key)) return;
    final view = _viewForKey(key);
    for (final file in view.files) {
      final candidate = build(file);
      final existing = tab(candidate.id);
      if (existing == null) { candidate.projects.add(key); tabs.add(candidate); }
      else { existing.projects.add(key); candidate.dispose(); }
    }
    final activeFile = view.activeFile;
    activeId = _activeByProject.containsKey(key) ? _activeByProject[key] :
      (activeFile == null ? null : tabs.where((t) => t.file == activeFile && t.projects.contains(key)).firstOrNull?.id) ?? activeId;
    if (!visibleTabs.any((t) => t.id == activeId)) activeId = visibleTabs.firstOrNull?.id;
    _activeByProject[key] = activeId;
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
    final view = _viewForKey(key);
    final files = [for (final t in _tabsFor(key)) if (t.file != null) t.file!];
    // Other service tabs can open before the file feature restores saved
    // files. Keep those references instead of silently replacing them by [].
    final next = _restored.contains(key) ? files : {...view.files, ...files}.toList();
    if (removed != null) next.remove(removed);
    final activeFile = tab(key == projectKey ? activeId ?? '' : _activeByProject[key] ?? '')?.file;
    if (listEquals(view.files, next) && view.activeFile == activeFile) return;
    view.files = next;
    if (_restored.contains(key) || activeFile != null) view.activeFile = activeFile;
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
    if (_disposed || _dirtyViews.isEmpty) return;
    _saveViewTimer?.cancel();
    _saveViewTimer = Timer(const Duration(milliseconds: 500), () { unawaited(flushViews()); });
  }

  Future<bool> flushViews() async {
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
    while (_dirtyViews.isNotEmpty) {
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
    app.removeListener(_onApp);
    for (final t in tabs) {
      t.dispose();
    }
    filesRevision.dispose();
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
