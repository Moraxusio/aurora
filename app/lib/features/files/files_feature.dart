// The file tree in the side bar (service "files"). Folders expand in place;
// a click on a file opens it in an editor tab; every row has the same menu on
// right-click and on long-press. Uploads ask before replacing a file that is
// already there, and every transfer can be cancelled.
//
// Beyond browsing: Ctrl/Shift-click selects several rows; Copy, Cut and Paste
// (Ctrl+C / Ctrl+X / Ctrl+V, or the menu) work on the server, inside a root or
// across roots; F2 renames, Delete deletes; the sort button orders a folder by
// name, size, time or type; Properties can measure a folder (fs.du) and feed
// the sizes of its children back into the tree.
// The logic lives in file_ops.dart so it is tested without widgets.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;

import 'package:aurora_install/aurora_install.dart' show compareVersions, parseVersion;
import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:file_picker/file_picker.dart';
import 'package:aurora/ui/aurora_ui.dart';
import 'package:flutter/services.dart';

import '../../kernel/feature.dart';
import '../../kernel/input_mode.dart';
import '../../kernel/workspace.dart';
import '../../kernel/retained_pages.dart';
import '../../theme/ide_theme.dart';
import '../terminal/terminal_feature.dart' show openSession;
import '../search/quick_open.dart' show showQuickOpen;
import 'file_editor.dart';
import 'file_info_dialog.dart';
import 'file_ops.dart';
import 'download_action.dart';
import 'transfers.dart';
import 'project_workspaces.dart';
import 'file_tree_row.dart';

/// Copying or moving between two roots needs an agent that understands
/// `to_root`; an older one would ignore it and copy inside the source root.
const crossRootAgent = '3.11.0';

class FilesFeature extends Feature {
  final Transfers transfers;
  const FilesFeature(this.transfers);

  @override
  String get id => 'files';
  @override
  String get title => '文件';
  @override
  IconData get icon => Icons.folder_outlined;
  @override
  String get service => 'files';
  @override
  List<String> get ops => const ['fs.roots', 'fs.list', 'fs.read', 'fs.write', 'fs.mkdir', 'fs.rename', 'fs.delete', 'fs.upload', 'fs.download'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) {
    ws.transfers = transfers;
    return SideBarView(title: '文件', body: FileTree(ws: ws, transfers: transfers), actions: const []);
  }

  @override
  List<Command> commands(Workspace ws) => [
        Command(
          id: 'files.upload',
          title: '上传文件到服务器…',
          group: '文件',
          icon: Icons.upload_file,
          run: () => Toast.show('在“文件”侧栏里选一个文件夹，再点上传'),
        ),
      ];
}

class _Node {
  final String root;
  final String path; // "/" for a root
  final String name;
  Map<String, dynamic>? entry; // null for a root
  final String? location;
  bool expanded = false;
  bool loading = false;
  String? error;
  List<_Node>? children;
  int request = 0;

  /// The measured size of a folder (null until "Calculate size"), the folder's
  /// own mtime when it was measured, and whether a measurement is running.
  DuInfo? du;
  int duMtime = 0;
  bool duBusy = false;
  _Node(this.root, this.path, this.name, this.entry, {this.location});

  bool get isDir => entry == null || entry!['type'] == 'dir' || entry!['target'] == 'dir';
  String child(String n) => path == '/' ? '/$n' : '$path/$n';
  int get mtime => (entry?['mtime'] as num?)?.toInt() ?? 0;
  int get fileSize => (entry?['size'] as num?)?.toInt() ?? 0;
  String get key => '$root:$path';
}

class FileTree extends StatefulWidget {
  final Workspace ws;
  final Transfers transfers;
  const FileTree({super.key, required this.ws, required this.transfers});
  @override
  State<FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends State<FileTree> {
  final Set<String> _visited = {};
  final Map<String, Widget> _pages = {};
  String? _restoring;
  @override
  void initState() {
    super.initState();
    widget.ws.addListener(_changed);
  }
  @override
  void dispose() {
    widget.ws.removeListener(_changed);
    super.dispose();
  }
  void _changed() { if (mounted) setState(() {}); }
  @override
  Widget build(BuildContext context) {
    final ws = widget.ws;
    final key = ws.projectKey;
    _visited.add(key);
    final ids = {'', ...?ws.entry?.workspaces.map((p) => p.id)};
    _visited.removeWhere((id) => !ids.contains(id));
    _pages.removeWhere((id, _) => !ids.contains(id));
    final keys = _visited.toList();
    if (_restoring != key) {
      _restoring = key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ws.projectKey == key) {
          ws.restoreFiles((f) => fileEditorTab(ws, root: f.root, path: f.path));
          unawaited(ws.restoreRecovery((f) => fileEditorTab(ws, root: f.root, path: f.path)));
        }
      });
    }
    return RetainedPages(index: keys.indexOf(key), children: [
        for (final id in keys) TickerMode(key: ValueKey(id), enabled: id == key,
          child: ExcludeFocus(excluding: id != key, child: RepaintBoundary(child: _pages.putIfAbsent(id, () => _FileTreePage(ws: ws, transfers: widget.transfers, projectId: id))))),
      ]);
  }
}

class _FileTreePage extends StatefulWidget {
  final Workspace ws;
  final Transfers transfers;
  final String projectId;
  const _FileTreePage({required this.ws, required this.transfers, required this.projectId});
  @override
  State<_FileTreePage> createState() => _FileTreePageState();
}

class _FileTreePageState extends State<_FileTreePage> {
  final List<_Node> _roots = [];
  _Node? _selected; // the item the folder-level actions (new, upload) refer to
  _Node? _anchor; // where Shift-click ranges start
  Set<String> _picked = {}; // keys of every selected row
  bool _hidden = false;
  String? _error;
  bool _loadingRoots = true;
  Set<WorkspacePath> _expanded = {};
  String _folderShape = '';
  final _scroll = ScrollController();
  final _fileViewport = GlobalKey();
  final _focus = FocusNode(debugLabel: 'file-tree');
  int _generation = 0;
  bool _treeSet = false;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  String? _busy; // a paste or delete in progress, shown in the footer
  String _sort = 'name';
  bool _desc = false;
  bool _foldersFirst = true;
  String? _activeFile;
  Link? _link;
  bool _filterOpen = false;
  String _filterQuery = '';
  final _filterCtl = TextEditingController();
  final _filterFocus = FocusNode(debugLabel: 'file-filter');
  String? _dragOverKey;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    widget.transfers.addListener(_tick);
    ws.filesRevision.addListener(_onFilesChanged);
    ws.fileClipboard.addListener(_tick);
    ws.pendingPaste.addListener(_tick);
    ws.addListener(_onWorkspace);
    _filterCtl.addListener(() {
      final q = _filterCtl.text.trim();
      if (q != _filterQuery && mounted) setState(() => _filterQuery = q);
    });
    _link = ws.link;
    final view = ws.viewForProject(widget.projectId);
    _expanded = view.expanded.toSet();
    _treeSet = view.treeSet;
    _folderShape = _shape();
    _syncSort();
    _loadRoots();
  }

  @override
  void dispose() {
    widget.transfers.removeListener(_tick);
    ws.filesRevision.removeListener(_onFilesChanged);
    ws.fileClipboard.removeListener(_tick);
    ws.pendingPaste.removeListener(_tick);
    ws.removeListener(_onWorkspace);
    _filterCtl.dispose();
    _filterFocus.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A save changed a file: reload the folders that are open, so the size and
  /// time in the tree are not those of the file before the save.
  void _onFilesChanged() {
    if (mounted) _refreshAll();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  String _shape() => ws.entry?.workspace(widget.projectId)?.folders.map((f) => '${f.root}:${f.path}').join('|') ?? '';
  void _onWorkspace() {
    if (!identical(_link, ws.link)) {
      _link = ws.link;
      _generation++;
      _refreshing = null;
      _refreshAgain = false;
      setState(() {
        _roots.clear();
        _picked.clear();
        _selected = _anchor = null;
        _loadingRoots = _link != null;
      });
      if (_link != null) _loadRoots();
    }
    final active = ws.active?.file;
    final activeKey = active == null ? null : '${active.root}:${active.path}';
    if (_activeFile != activeKey) { _activeFile = activeKey; if (mounted) setState(() {}); }
    if (_syncSort() && mounted) setState(_resortAll);
    final shape = _shape();
    if (shape == _folderShape) return;
    _folderShape = shape;
    _loadRoots();
  }

  /// Reads the sort choice from the profile; true when it changed.
  bool _syncSort() {
    if (!ws.app.ready) return false;
    final e = ws.app.editorSettings;
    final changed = e.fileSort != _sort || e.fileSortDesc != _desc || e.foldersFirst != _foldersFirst;
    _sort = e.fileSort;
    _desc = e.fileSortDesc;
    _foldersFirst = e.foldersFirst;
    return changed;
  }

  // ---- sorting ----

  SortItem _item(_Node n) => SortItem(n.name, n.isDir, n.isDir ? n.du?.bytes : n.fileSize, n.mtime);

  void _sortNodes(List<_Node> list) =>
      list.sort((a, b) => compareSort(_item(a), _item(b), sort: _sort, desc: _desc, foldersFirst: _foldersFirst));

  void _resortAll() {
    void walk(_Node n) {
      final c = n.children;
      if (c == null) return;
      _sortNodes(c);
      for (final x in c) {
        walk(x);
      }
    }

    for (final r in _roots) {
      walk(r);
    }
  }

  Future<void> _setSort({String? sort, bool? desc, bool? folders}) async {
    if (!ws.app.ready) {
      ws.toast('配置文件不可用，排序无法保存', error: true);
      return;
    }
    try {
      await ws.app.update((p) {
        if (sort != null) p.editor.fileSort = sort;
        if (desc != null) p.editor.fileSortDesc = desc;
        if (folders != null) p.editor.foldersFirst = folders;
      });
    } on Object catch (e) {
      ws.toast('保存排序方式失败：$e', error: true);
      return;
    }
    if (mounted) {
      _syncSort();
      setState(_resortAll);
    }
  }

  List<MenuItem> _sortItems() => [
      for (final (k, label) in const [('name', '名称'), ('size', '大小'), ('mtime', '修改时间'), ('type', '类型')])
        MenuItem(label, () => _setSort(sort: k), icon: _sort == k ? Icons.check : null, hint: k == 'size' ? '文件夹需先统计' : null),
      const MenuItem.separator(),
      MenuItem('升序', () => _setSort(desc: false), icon: !_desc ? Icons.check : null, hint: '小→大 旧→新 A→Z'),
      MenuItem('降序', () => _setSort(desc: true), icon: _desc ? Icons.check : null),
      const MenuItem.separator(),
      MenuItem('文件夹排在前面', () => _setSort(folders: !_foldersFirst), icon: _foldersFirst ? Icons.check : null),
    ];

  void _rememberExpansion() {
    _treeSet = true;
    if (ws.projectKey == widget.projectId) ws.rememberExpanded(_expanded.toList());
  }

  Future<void> _loadRoots() async {
    final generation = ++_generation;
    final link = ws.link;
    if (link == null) return;
    try {
      final r = await link.call('fs.roots') as Map;
      final list = [for (final x in r['roots'] as List) (x as Map).cast<String, dynamic>()];
      if (!mounted || generation != _generation || !identical(link, ws.link)) return;
      final project = ws.entry?.workspace(widget.projectId);
      final nodes = project == null
          ? [for (final x in list) _Node(x['id'] as String, '/', (x['label'] as String?) ?? x['id'] as String, null, location: x['path'] as String?)]
          : [for (final f in project.folders) _Node(f.root, f.path, f.path == '/' ? (list.where((r) => r['id'] == f.root).firstOrNull?['label'] as String? ?? f.root) : f.name,
              null, location: '${f.root}:${f.path}')];
      final old = {for (final n in _roots) n.key: n};
      setState(() {
        _roots
          ..clear()
          ..addAll(nodes.map((n) => old[n.key] ?? n));
        _loadingRoots = false;
        _error = null;
      });
      for (final n in _roots.toList()) {
        if (!mounted || generation != _generation) return;
        final open = _expanded.contains(WorkspacePath(root: n.root, path: n.path)) ||
          (!_treeSet && (project != null || identical(n, _roots.first)));
        if (open) {
          n.expanded = true;
          await _load(n);
        }
      }
    } on Object catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e is OpError ? e.message : '$e';
          _loadingRoots = false;
        });
      }
    }
  }

  Future<void> _load(_Node n, {bool restore = true}) async {
    if (!mounted) return;
    final generation = _generation;
    final request = ++n.request;
    final hidden = _hidden;
    final link = ws.link;
    if (link == null) return;
    setState(() {
      n.loading = true;
      n.error = null;
    });
    try {
      final r = await link.call('fs.list', {'root': n.root, 'path': n.path, 'hidden': _hidden}) as Map;
      if (!mounted || generation != _generation || n.request != request || hidden != _hidden || !identical(link, ws.link)) return;
      final list = [for (final e in r['entries'] as List) (e as Map).cast<String, dynamic>()];
      final shown = _hidden ? list : list.where((e) => !(e['name'] as String).startsWith('.')).toList();
      // A reload builds new nodes, but a folder the user had open stays open,
      // with what it already showed until it is loaded again: otherwise a
      // refresh would collapse the tree, and the walk in _refreshAll would stop
      // at the first collapsed folder and never reload the ones below it.
      final old = {for (final c in n.children ?? const <_Node>[]) c.name: c};
      final nodes = <_Node>[
        for (final e in shown)
          () {
            final node = _Node(n.root, n.child(e['name'] as String), e['name'] as String, e);
            final was = old[node.name];
            if (was != null && was.isDir == node.isDir) {
              old.remove(node.name);
              was.entry = e;
              // a measured size is a snapshot: a changed folder (its own mtime moved) is no longer that size
              if (was.du != null && was.duMtime != was.mtime) was.du = null;
              return was;
            } else if (node.isDir) {
              node.expanded = _expanded.contains(WorkspacePath(root: node.root, path: node.path));
            }
            return node;
          }()
      ];
      _sortNodes(nodes);
      n.children = nodes;
      if (old.isNotEmpty && (_picked.isNotEmpty || _selected != null || _anchor != null)) {
        // An external deletion or a changed entry type can invalidate selection
        // and toolbar destinations. Reconcile after attaching the new listing.
        final retained = <String, _Node>{
          for (final node in _allNodes())
            if (_picked.contains(node.key) ||
                node.key == _selected?.key || node.key == _anchor?.key)
              node.key: node,
        };
        _picked.removeWhere((key) => !retained.containsKey(key));
        final before = _selected;
        if (before != null) {
          _selected = retained[before.key];
          if (_selected == null) {
            _selected = _picked.isEmpty ? n : retained[_picked.last];
            if (_selected != null) _picked.add(_selected!.key);
          }
        }
        _anchor = retained[_anchor?.key] ?? _selected;
      }
      if (restore) {
        for (final c in nodes.where((c) => c.isDir && c.expanded)) {
          if (!mounted || generation != _generation) return;
          await _load(c);
        }
      }
    } on Object catch (e) {
      if (mounted && generation == _generation && request == n.request && hidden == _hidden) n.error = e is OpError ? e.message : '$e';
    } finally {
      if (mounted && generation == _generation && request == n.request) setState(() => n.loading = false);
    }
  }

  Future<void> _expand(_Node n, bool on, {bool remember = true}) async {
    if (!mounted) return;
    setState(() => n.expanded = on);
    final path = WorkspacePath(root: n.root, path: n.path);
    on ? _expanded.add(path) : _expanded.remove(path);
    if (remember) _rememberExpansion();
    if (on && n.children == null) await _load(n);
  }

  Future<void> _revealActive() async {
    final file = ws.active?.file;
    if (file == null) return;
    final height = FileTreeRow.heightOf(context);
    final link = ws.link, generation = _generation;
    bool current() => mounted && generation == _generation && identical(link, ws.link) && ws.active?.file == file && ws.projectKey == widget.projectId;
    final roots = _roots.where((n) => n.root == file.root && isSameOrInside(file.path, n.path)).toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    if (roots.isEmpty) { ws.toast('当前文件不在此工作区的文件夹中'); return; }
    if (!_hidden && file.path.split('/').any((s) => s.startsWith('.'))) {
      setState(() => _hidden = true);
      await _refreshAll();
      if (!current()) return;
    }
    var node = roots.first;
    while (node.path != file.path) {
      await _expand(node, true);
      if (!current()) return;
      final next = node.children?.where((n) => isSameOrInside(file.path, n.path)).firstOrNull;
      if (next == null) { ws.toast('当前文件已移动或暂时无法读取', error: true); return; }
      node = next;
    }
    setState(() => _selectOnly(node));
    final rows = [for (final r in _roots) ..._rows(r, 0)];
    final index = rows.indexWhere((r) => identical(r.node, node) && r.note == null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current() || !_scroll.hasClients || index < 0) return;
      _scroll.jumpTo((index * height - _scroll.position.viewportDimension / 3).clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  void _collapseAll() {
    setState(() { for (final n in _allNodes()) { n.expanded = false; } _expanded.clear(); });
    _rememberExpansion();
  }

  Future<void> _refreshAll() {
    _refreshAgain = true;
    if (_refreshing != null) return _refreshing!;
    late final Future<void> work;
    work = _refreshLoop().whenComplete(() { if (identical(_refreshing, work)) _refreshing = null; });
    return _refreshing = work;
  }

  Future<void> _refreshFromCommand() async {
    if (ws.link == null || _loadingRoots || _busy != null) return;
    if (_roots.isEmpty || _error != null) {
      await _loadRoots();
      return;
    }
    // A collapsed selection can still have cached children. Reload it without
    // opening it; keep the rest of the visible tree fresh as usual.
    final target = _target;
    if (target != null && !target.expanded) await _load(target, restore: false);
    await _refreshAll();
  }

  Future<void> _refreshLoop() async {
    final generation = _generation;
    while (_refreshAgain && mounted && generation == _generation) {
    _refreshAgain = false;
    Future<void> walk(_Node n) async {
      if (!mounted || generation != _generation || !n.expanded) return;
      await _load(n, restore: false);
      if (!mounted || generation != _generation) return;
      for (final c in List<_Node>.of(n.children ?? const <_Node>[])) {
        await walk(c);
      }
    }

    for (final r in _roots.toList()) {
      await walk(r);
    }
    }
  }

  /// The folder a new item goes into: the selected folder, or the parent of
  /// the selected file, or the first root.
  _Node? get _target {
    final s = _selected;
    if (s == null) return _roots.isEmpty ? null : _roots.first;
    if (s.isDir) return s;
    return _findParent(s) ?? (_roots.isEmpty ? null : _roots.first);
  }

  _Node? _findParent(_Node n) {
    _Node? hit;
    void walk(_Node p) {
      for (final c in p.children ?? const <_Node>[]) {
        if (identical(c, n)) hit = p;
        walk(c);
      }
    }

    for (final r in _roots) {
      walk(r);
    }
    return hit;
  }

  Future<void> _reload(_Node n) async {
    final dir = n.isDir ? n : _findParent(n);
    if (dir != null) await _load(dir);
  }

  Iterable<_Node> _allNodes() sync* {
    Iterable<_Node> walk(_Node n) sync* {
      yield n;
      for (final c in n.children ?? const <_Node>[]) {
        yield* walk(c);
      }
    }

    for (final r in _roots) {
      yield* walk(r);
    }
  }

  // ---- selection ----

  void _selectOnly(_Node n) {
    _selected = n;
    _anchor = n;
    _picked = {n.key};
  }

  /// The selected items that can be acted on (not a project folder's own
  /// row), without any whose parent folder is selected too.
  List<_Node> _selectedItems() {
    if (_picked.isEmpty) return const [];
    final seen = <String>{};
    final list = [for (final n in _allNodes()) if (n.entry != null && _picked.contains(n.key) && seen.add(n.key)) n];
    return [
      for (final n in list)
        if (!list.any((o) => o.root == n.root && o.path != n.path && isSameOrInside(n.path, o.path))) n
    ];
  }

  Iterable<_Node> _visibleNodes(_Node n) sync* {
    yield n;
    if (n.expanded) {
      for (final c in n.children ?? const <_Node>[]) {
        yield* _visibleNodes(c);
      }
    }
  }

  void _tap(_Node n, {bool keep = false}) {
    _focus.requestFocus();
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (kb.isShiftPressed && _anchor != null) {
      final vis = [for (final r in _roots) ..._visibleNodes(r)];
      final a = vis.indexWhere((x) => identical(x, _anchor)), b = vis.indexWhere((x) => identical(x, n));
      if (a >= 0 && b >= 0) {
        setState(() {
          _picked = {for (var i = math.min(a, b); i <= math.max(a, b); i++) vis[i].key};
          _selected = n;
        });
        return;
      }
    }
    if (ctrl) {
      setState(() {
        if (_picked.contains(n.key)) {
          _picked.remove(n.key);
          if (identical(_selected, n)) _selected = _allNodes().where((x) => _picked.contains(x.key)).lastOrNull;
        } else {
          _picked.add(n.key);
          _selected = n;
        }
        _anchor = n;
      });
      return;
    }
    _open(n, preview: !keep);
  }

  // ---- operations ----

  (Link, int)? _fileAction([Iterable<_Node> targets = const []]) {
    final link = ws.link;
    if (link == null || !identical(_link, link) || ws.projectKey != widget.projectId || ws.app.selected != ws.serverId) return null;
    final remaining = targets.toSet();
    for (final n in _allNodes()) {
      if (remaining.isEmpty) break;
      remaining.remove(n);
    }
    if (remaining.isNotEmpty) return null;
    return (link, _generation);
  }

  bool _sameFileAction((Link, int) action) =>
      mounted && _generation == action.$2 && identical(ws.link, action.$1) &&
      ws.projectKey == widget.projectId && ws.app.selected == ws.serverId;

  bool _requireFileAction((Link, int) action) {
    if (_sameFileAction(action)) return true;
    if (mounted) ws.toast('连接或工作区已变化，请重新确认文件操作', error: true);
    return false;
  }

  static bool _simpleName(String name) =>
      name != '.' && name != '..' && !name.contains('/') && !name.contains('\\');

  Future<void> _mkdir(_Node dir) async {
    final action = _fileAction([dir]);
    if (action == null) return;
    final name = await askText(context, title: '新建文件夹', hint: '名称');
    if (name == null || name.isEmpty || !_requireFileAction(action)) return;
    if (!_simpleName(name)) return ws.toast('请输入单个文件夹名称，不能包含路径', error: true);
    final result = await ws.guard(() => action.$1.call('fs.mkdir', {'root': dir.root, 'path': dir.child(name)}));
    if (result == null || !_sameFileAction(action)) return;
    await _expand(dir, true);
    if (_sameFileAction(action)) await _load(dir);
  }

  Future<void> _newFile(_Node dir) async {
    final action = _fileAction([dir]);
    if (action == null) return;
    final name = await askText(context, title: '新建文件', hint: '名称，例如 notes.txt');
    if (name == null || name.isEmpty || !_requireFileAction(action)) return;
    if (!_simpleName(name)) return ws.toast('请输入单个文件名称，不能包含路径', error: true);
    final ok = await ws.guard(() => action.$1.call('fs.write', {'root': dir.root, 'path': dir.child(name), 'content': '', 'create': true}));
    if (ok == null || !_sameFileAction(action)) return;
    await _expand(dir, true);
    if (!_sameFileAction(action)) return;
    await _load(dir);
    if (_sameFileAction(action)) ws.openTab(fileEditorTab(ws, root: dir.root, path: dir.child(name)));
  }

  /// An open tab with unsaved text under [path]: renaming, moving or deleting
  /// the file would leave that text with nowhere to be saved.
  bool _hasUnsaved(String root, String path) =>
      ws.tabs.any((t) => t.dirty.value && (t.id == 'file:$root:$path' || t.id.startsWith('file:$root:$path/')));

  void _warnUnsaved() => ws.toast('这里有打开的文件还没保存，先保存或关闭它再操作', error: true);

  Future<void> _rename(_Node n) async {
    final action = _fileAction([n]);
    if (n.entry == null || action == null) return;
    final stamp = n.entry?['etag'];
    if (_hasUnsaved(n.root, n.path)) return _warnUnsaved();
    final to = await askText(context, title: '重命名', initial: n.name);
    if (to == null || to.isEmpty || to == n.name || !_requireFileAction(action)) return;
    if (!_simpleName(to)) return ws.toast('请输入单个名称，不能包含路径', error: true);
    if (_hasUnsaved(n.root, n.path)) return _warnUnsaved();
    final dest = joinPath(parentPath(n.path), to);
    final wasOpen = !n.isDir && ws.tab('file:${n.root}:${n.path}') != null;
    final ok = await ws.guard(() => action.$1.call('fs.rename', {
      'root': n.root, 'path': n.path, 'to': dest, if (stamp is String) 'if_match': stamp,
    }));
    if (ok == null || !_sameFileAction(action)) return;
    ws.dropTabs((t) => !t.dirty.value &&
        (t.id == 'file:${n.root}:${n.path}' || t.id.startsWith('file:${n.root}:${n.path}/')));
    if (wasOpen && !_hasUnsaved(n.root, n.path)) ws.openTab(fileEditorTab(ws, root: n.root, path: dest));
    await _reload(n);
    if (_sameFileAction(action)) setState(() => _picked.remove(n.key));
  }

  Future<void> _deleteItems(List<_Node> items) async {
    final action = _fileAction(items);
    if (items.isEmpty || action == null || _busy != null) return;
    final targets = [for (final n in items) (n, n.entry?['etag'], n.entry?['type'] == 'dir')];
    if (items.any((n) => _hasUnsaved(n.root, n.path))) return _warnUnsaved();
    final dirs = items.any((n) => n.entry?['type'] == 'dir');
    final ok = await confirmDialog(context,
        title: items.length == 1 ? '删除 ${items.first.name}？' : '删除这 ${items.length} 项？',
        body: dirs ? '文件夹和里面的所有内容都会被删除，不能恢复。' : '删除后不能恢复。',
        ok: '删除',
        danger: true);
    if (!ok || !_requireFileAction(action) || _busy != null) return;
    final errors = <String>[];
    var done = 0;
    setState(() => _busy = '正在删除…');
    try {
      for (var i = 0; i < items.length; i++) {
        if (!_requireFileAction(action)) return;
        final (n, stamp, recursive) = targets[i];
        if (_hasUnsaved(n.root, n.path)) {
          errors.add('${n.name}：文件出现未保存的修改');
          continue;
        }
        setState(() => _busy = '正在删除（${i + 1}/${items.length}）${n.name}');
        try {
          await action.$1.call('fs.delete', {
            'root': n.root, 'path': n.path, 'recursive': recursive, if (stamp is String) 'if_match': stamp,
          }, const Duration(minutes: 10));
          if (!_requireFileAction(action)) return;
          ws.dropTabs((t) => !t.dirty.value &&
              (t.id == 'file:${n.root}:${n.path}' || t.id.startsWith('file:${n.root}:${n.path}/')));
          done++;
        } on OpError catch (e) {
          errors.add('${n.name}：${e.message}');
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          if (_sameFileAction(action)) {
            _picked = {};
            _selected = null;
            _anchor = null;
          }
        });
      }
    }
    if (errors.isNotEmpty) ws.toast('${errors.first}${errors.length > 1 ? '（另有 ${errors.length - 1} 项失败）' : ''}', error: true);
    if (done > 0 && errors.isEmpty && items.length > 1) ws.toast('已删除 $done 项');
    await _refreshAll();
  }

  Future<void> _upload(_Node dir) async {
    final action = _fileAction([dir]);
    if (action == null) return;
    final res = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件');
    if (res.isEmpty || !_requireFileAction(action)) return;
    await _uploadFiles(action, dir, [for (final f in res) if (f.path != null) File(f.path!)]);
  }

  /// Uploads local files into [dir]. A name that is already there is asked
  /// about (replace, skip, or replace all), never overwritten silently.
  Future<void> _uploadFiles((Link, int) action, _Node dir, List<File> files) async {
    final link = action.$1;
    var replaceAll = false;
    for (final f in files) {
      if (!_requireFileAction(action)) return;
      final name = f.uri.pathSegments.last;
      final path = dir.child(name);
      try {
        Map? existing;
        try {
          existing = await link.call('fs.stat', {'root': dir.root, 'path': path}) as Map;
        } on OpError catch (e) {
          if (e.code != codeNotFound) rethrow;
        }
        if (!_requireFileAction(action)) return;
        final stamp = existing?['etag'];
        if (existing != null) {
          if (existing['type'] != 'file' || stamp is! String || stamp.isEmpty) {
            ws.toast('无法安全替换「$name」：目标不是普通文件或无法获取版本', error: true);
            continue;
          }
          if (!replaceAll) {
            final choice = await _askReplace(name, files.length > 1);
            if (choice == 'skip' || choice == null) continue;
            if (choice == 'all') replaceAll = true;
          }
        }
        if (!_requireFileAction(action)) return;
        if (_hasUnsaved(dir.root, path)) {
          _warnUnsaved();
          continue;
        }
        final size = await f.length();
        if (!_requireFileAction(action)) return;
        widget.transfers.upload(link, f, size, dir.root, path,
          ifMatch: stamp as String?,
          currentLink: () => _sameFileAction(action) ? link : null,
          verifyTarget: () {
            if (_hasUnsaved(dir.root, path)) throw OpError(codeConflict, '目标有未保存的修改，请保存后重新确认上传');
          },
          onDone: () {
            if (_sameFileAction(action)) _load(dir);
          });
      } on Object catch (e) {
        if (!_requireFileAction(action)) return;
        ws.toast('无法上传「$name」：${e is OpError ? e.message : e}', error: true);
      }
    }
  }

  Future<String?> _askReplace(String name, bool several) {
    final ide = Ide.of(context);
    return showWorkbenchDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('服务器上已有 $name'),
        content: const Text('上传会替换它，原来的内容不能恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'skip'), child: Text('跳过', style: TextStyle(color: ide.textDim))),
          if (several) OutlinedButton(onPressed: () => Navigator.pop(c, 'all'), child: const Text('全部替换')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: ide.error), onPressed: () => Navigator.pop(c, 'one'), child: const Text('替换')),
        ],
      ),
    );
  }

  Future<void> _download(_Node n) =>
      downloadRemoteFile(ws, root: n.root, path: n.path, size: (n.entry?['size'] as num?)?.toInt() ?? 0);

  void _open(_Node n, {bool preview = false}) {
    setState(() => _selectOnly(n));
    if (n.isDir) {
      _expand(n, !n.expanded);
    } else {
      ws.openTab(fileEditorTab(ws, root: n.root, path: n.path), preview: preview);
    }
  }

  // ---- clipboard ----

  void _copy({bool cut = false, List<_Node>? nodes}) {
    final items = nodes ?? _selectedItems();
    if (items.isEmpty) return;
    if (cut && items.any((n) => _hasUnsaved(n.root, n.path))) return _warnUnsaved();
    final action = _fileAction(items);
    if (action == null) return;
    ws.fileClipboard.value = FileClipboard([for (final n in items) _clipItem(n)], cut: cut, link: action.$1);
    final what = items.length == 1 ? items.first.name : '${items.length} 项';
    ws.toast(cut ? '已剪切 $what，到目标文件夹里选“粘贴”' : '已复制 $what，到目标文件夹里选“粘贴”');
  }

  ClipItem _clipItem(_Node n) => ClipItem(n.root, n.path, n.isDir, etag: n.entry?['etag'] as String?);

  bool _crossRootOk() {
    final v = ws.link?.server.version ?? '';
    if (parseVersion(v) == null) return true; // a development build is the newest
    return (compareVersions(v, crossRootAgent) ?? -1) >= 0;
  }

  Future<ConflictChoice?> _askConflict(String name, {required bool more, required bool canReplace}) {
    final ide = Ide.of(context);
    var all = false;
    return showWorkbenchDialog<ConflictChoice>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('目标文件夹里已有「$name」'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(canReplace ? '“替换”将安全地写入普通文件；“保留两者”会给新的加上“副本”。' :
                  '此目标不支持安全替换（目录、超过大小限制或旧版 agent）。可跳过或保留两者。'),
              if (more)
                CheckboxListTile(
                  value: all,
                  onChanged: (v) => set(() => all = v == true),
                  title: const Text('对剩下的同名项都这样处理'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, ConflictChoice(Conflict.skip, all: all)), child: Text('跳过', style: TextStyle(color: ide.textDim))),
            OutlinedButton(onPressed: () => Navigator.pop(c, ConflictChoice(Conflict.keepBoth, all: all)), child: const Text('保留两者')),
            if (canReplace)
              FilledButton(style: FilledButton.styleFrom(backgroundColor: ide.error), onPressed: () => Navigator.pop(c, ConflictChoice(Conflict.replace, all: all)), child: const Text('替换')),
          ],
        ),
      ),
    );
  }

  Future<void> _queryPaste() async {
    final link = ws.link, receipt = ws.pendingPaste.value;
    if (!mounted || _busy != null || receipt == null) return;
    if (link == null || !receipt.matches(link)) {
      ws.toast('请连接发起替换的 agent 再查询', error: true);
      return;
    }
    setState(() => _busy = '正在查询替换结果…');
    try {
      final result = await link.call('fs.paste.status', {'id': receipt.id});
      if (!mounted || !identical(ws.link, link) || !identical(ws.pendingPaste.value, receipt)) return;
      if (receipt.confirmedBy(result)) {
        try {
          await ws.clearPasteReceipt(receipt.id);
        } on Object {
          if (mounted) ws.toast('已确认替换，但无法保存查询结果；原记录已保留', error: true);
          return;
        }
        if (!mounted || !identical(ws.link, link)) return;
        ws.toast('已确认写入 ${receipt.target.path}；若曾剪切，请核对源文件（不会自动删除）');
        await _refreshAll();
      } else {
        ws.toast('替换收据与原请求不符，查询记录已保留', error: true);
      }
    } on OpError catch (e) {
      if (!mounted || !identical(ws.link, link) || !identical(ws.pendingPaste.value, receipt)) return;
      if (e.code == codeNotFound) {
        final clear = await confirmDialog(context, title: '尚未查到替换收据',
           body: '请核对 ${receipt.target.path} 与源文件。可保留查询，或清除这条查询记录；不会重复执行替换。',
           ok: '清除查询记录');
        if (clear && mounted && identical(ws.pendingPaste.value, receipt)) {
          try {
            await ws.clearPasteReceipt(receipt.id);
          } on Object {
            if (mounted) ws.toast('无法清除查询记录，原记录已保留', error: true);
          }
        }
      } else {
        ws.toast(e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// The folder Paste goes into for a row: the folder itself, or a file's folder.
  _Node? _pasteTargetFor(_Node? n) => n == null ? _target : (n.isDir ? n : (_findParent(n) ?? _target));

  Future<void> _paste([_Node? onto]) async {
    final clip = ws.fileClipboard.value;
    final dest = _pasteTargetFor(onto);
    if (clip == null || dest == null) return;
    if (!identical(clip.link, ws.link)) {
      ws.toast('连接已变化，请重新复制或剪切源文件', error: true);
      return;
    }
    await _runPaste(clip.items, clip.cut, dest);
  }

  Future<void> _duplicate(_Node n) async {
    final parent = _findParent(n);
    if (parent == null || n.entry == null) return;
    await _runPaste([_clipItem(n)], false, parent);
  }

  Future<void> _runPaste(List<ClipItem> items, bool cut, _Node dest) async {
    final action = _fileAction([dest]);
    if (action == null || _busy != null) return;
    final link = action.$1;
    if (items.any((i) => i.root != dest.root) && !_crossRootOk()) {
      ws.toast('在不同根目录之间复制或移动，需要服务器上的 agent 升级到 $crossRootAgent 或更高', error: true);
      return;
    }
    if (cut && items.any((i) => _hasUnsaved(i.root, i.path))) return _warnUnsaved();
    final clipboard = ws.fileClipboard.value, observed = ws.tabs.toSet();
    setState(() => _busy = '正在准备粘贴…');
    PasteResult? res;
    try {
      // the real names in the destination, hidden ones included: a taken name is a conflict
      final listing = await ws.guard(() => link.call('fs.list', {'root': dest.root, 'path': dest.path, 'hidden': true})) as Map?;
      if (listing == null || !_requireFileAction(action)) return;
      final entries = (listing['entries'] as List).cast<Map>();
      final existing = {for (final e in entries) e['name'] as String};
      final versions = {for (final e in entries) if (e['etag'] case final String version) e['name'] as String: version};
      final eligible = {
        for (final e in entries)
          if (e['type'] == 'file' && e['size'] is num && (e['size'] as num) <= 64 << 20)
            e['name'] as String,
      };
      final supportsReplace = link.server.caps.contains('fs.paste.replace') &&
          link.server.caps.contains('fs.paste.status') &&
          link.server.id.isNotEmpty && pasteReceiptPin(link) != null;
      void checkSource(ClipItem item) {
        if (cut && _hasUnsaved(item.root, item.path)) {
          throw OpError(codeConflict, '源文件出现未保存的修改，请保存后重试');
        }
      }
      res = await pasteItems(
        call: (op, args) {
          if (!_sameFileAction(action)) throw OpError(codeUnavailable, '连接或工作区已变化，请核对文件后重试');
          return link.call(op, args, op == 'fs.copy' || op == 'fs.delete' ? const Duration(minutes: 30) : const Duration(seconds: 60));
        },
        items: items,
        cut: cut,
        destRoot: dest.root,
        destDir: dest.path,
        existing: existing,
        existingVersions: versions,
        resolve: (name, isDir, {required more}) async => _sameFileAction(action)
            ? _askConflict(name, more: more, canReplace: supportsReplace &&
                !isDir && eligible.contains(name) && ws.pendingPaste.value == null)
            : null,
        replaceFile: supportsReplace ? (item, path, targetVersion) async {
          if (!_sameFileAction(action)) throw OpError(codeUnavailable, '连接或工作区已变化');
          if (ws.pendingPaste.value != null) throw OpError(codeConflict, '请先查询上一次替换的结果');
          if (item.isDir || item.etag == null || targetVersion == null || !eligible.contains(baseName(path))) {
            throw OpError(codeConflict, '无法安全替换，请刷新后选择“保留两者”');
          }
          final random = math.Random.secure();
          final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
          final receipt = PasteRecoveryRecord(id: id, agentId: link.server.id,
            pin: pasteReceiptPin(link)!, target: WorkspacePath(root: dest.root, path: path));
          try {
            await ws.savePasteReceipt(receipt);
          } on Object {
            throw OpError(codeUnavailable, '无法保存加密替换收据，未提交替换');
          }
          if (!_sameFileAction(action) ||
              _hasUnsaved(dest.root, path) || (cut && _hasUnsaved(item.root, item.path))) {
            // No request left the client; the durable record is safe to clear.
            try {
              await ws.clearPasteReceipt(id);
            } on Object {
              // Keep the query-only record if storage is unavailable.
            }
            throw OpError(codeConflict, '连接、工作区或未保存的修改已变化，未提交替换');
          }
          try {
            final result = await link.call('fs.paste.replace', {
              'id': id, 'root': item.root, 'path': item.path, 'if_match': item.etag,
              'to_root': dest.root, 'to': path, 'to_if_match': targetVersion,
            }, const Duration(minutes: 5));
            if (!receipt.confirmedBy(result)) {
              throw OpError(codeUnavailable, '替换结果未知，请在文件栏查询');
            }
            try {
              await ws.clearPasteReceipt(id);
            } on Object {
              throw OpError(codeUnavailable, '无法保存已确认的替换结果，请在文件栏查询');
            }
          } on OpError catch (e) {
            if (e.code == codeConflict || e.code == codeBadRequest || e.code == codeNotFound || e.code == codeForbidden) {
              try {
                await ws.clearPasteReceipt(id);
              } on Object {
                // Preserve the existing record; never retry a mutation here.
              }
              rethrow;
            }
            throw OpError(codeUnavailable, '替换结果未知，请在文件栏查询（$id）');
          }
        } : null,
        beforeTransfer: (item, replacing) {
          if (!_sameFileAction(action)) throw OpError(codeUnavailable, '连接或工作区已变化');
          checkSource(item);
          if (replacing != null && _hasUnsaved(dest.root, replacing)) {
            throw OpError(codeConflict, '目标有未保存的修改，请保存后重试');
          }
        },
        beforeSourceDelete: checkSource,
        onProgress: (i, total, name) {
          if (mounted) setState(() => _busy = '${cut ? '正在移动' : '正在复制'}${total > 1 ? '（${i + 1}/$total）' : ''} $name');
        },
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!_sameFileAction(action)) {
      if (mounted && res.errors.isNotEmpty) ws.toast(res.errors.first, error: true);
      return;
    }
    for (final m in res.moved) {
      ws.dropTabs((t) => observed.contains(t) && !t.dirty.value &&
          (t.id == 'file:${m.root}:${m.path}' || t.id.startsWith('file:${m.root}:${m.path}/')));
    }
    if (cut && res.moved.isNotEmpty && identical(clipboard, ws.fileClipboard.value)) {
      // what was moved is gone from the old place: it cannot be pasted again
      final left = [for (final i in items) if (!res.moved.any((m) => m.root == i.root && m.path == i.path)) i];
      ws.fileClipboard.value = left.isEmpty ? null : FileClipboard(left, cut: true, link: link);
    }
    await _expand(dest, true);
    if (!_sameFileAction(action)) return;
    await _refreshAll();
    if (!_sameFileAction(action)) return;
    final verb = cut ? '移动' : '复制';
    if (res.errors.isNotEmpty) {
      ws.toast('${res.errors.first}${res.errors.length > 1 ? '（另有 ${res.errors.length - 1} 项失败）' : ''}', error: true);
    } else if (res.done > 0) {
      ws.toast('已$verb ${res.done} 项${res.skipped > 0 ? '，跳过 ${res.skipped} 项' : ''}');
    } else if (res.skipped > 0 && !res.stopped) {
      ws.toast(cut ? '这些项已经在这个文件夹里了' : '没有$verb任何项');
    }
  }

  // ---- folder sizes ----

  Future<DuResult> _du(_Node d) async {
    final r = await ws.link!.call('fs.du', {'root': d.root, 'path': d.path, 'children': true, 'timeout_ms': 30000}, const Duration(seconds: 75)) as Map;
    return parseDu(r.cast<String, dynamic>());
  }

  /// Stores a measurement on the folder and on each folder directly under it.
  void _applyDu(_Node d, DuResult r) {
    d.du = r.total;
    d.duMtime = d.mtime;
    for (final c in d.children ?? const <_Node>[]) {
      final info = c.isDir ? r.children[c.name] : null;
      if (info != null) {
        c.du = info;
        c.duMtime = c.mtime;
      }
    }
    if (_sort == 'size') _resortAll();
  }

  Future<void> _measure(List<_Node> dirs) async {
    for (final d in dirs) {
      if (d.duBusy || !mounted) continue;
      setState(() => d.duBusy = true);
      try {
        final r = await _du(d);
        if (!mounted) return;
        setState(() => _applyDu(d, r));
        if (r.total.partial) ws.toast('「${d.name}」太大，统计超时，显示的是已统计到的部分', error: true);
      } on OpError catch (e) {
        ws.toast(e.message, error: true);
      } finally {
        if (mounted) setState(() => d.duBusy = false);
      }
    }
  }

  void _properties(_Node n) {
    showFileInfo(
      context,
      root: n.root,
      path: ws.entry?.isLocal == true ? ws.app.localAgent.nativePath(n.root, n.path) : n.path,
      entry: n.entry,
      isDir: n.isDir,
      du: n.du,
      measure: n.isDir && _canMeasure ? () => _du(n) : null,
      onMeasured: (r) {
        if (mounted) setState(() => _applyDu(n, r));
      },
    );
  }

  // ---- menu and keys ----
  bool get _canMeasure => ws.entry?.isLocal != true || ws.hasOp('fs.du');

  List<MenuItem> _multiMenu() {
    final items = _selectedItems();
    final dirs = items.where((n) => n.isDir).toList();
    return [
      MenuItem('剪切', _busy != null ? null : () => _copy(cut: true, nodes: items), icon: Icons.content_cut, hint: 'Ctrl+X', quick: true),
      MenuItem('复制', _busy != null ? null : () => _copy(nodes: items), icon: Icons.content_copy_outlined, hint: 'Ctrl+C', quick: true),
      MenuItem('删除', _busy != null ? null : () => _deleteItems(items), icon: Icons.delete_outline, danger: true, hint: 'Delete', quick: true),
      if (dirs.isNotEmpty && _canMeasure) MenuItem('计算文件夹大小', () => _measure(dirs), icon: Icons.data_usage_rounded),
      MenuItem('取消选择', () => setState(() {
             _picked = {};
             _selected = null;
             _anchor = null;
           }), icon: Icons.deselect),
    ];
  }

  Future<void> _openInTerminal(_Node dir) async {
    final link = ws.link;
    if (link == null) return;
    var taken = <String>{};
    try {
      final r = await link.call('session.list') as Map;
      taken = {for (final s in r['sessions'] as List) (s as Map)['name'] as String};
    } on OpError {
      // Server checks duplicates on create.
    }
    var base = dir.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (base.isEmpty) base = 'term';
    if (base.length > 24) base = base.substring(0, 24);
    var name = base;
    for (var i = 2; taken.contains(name); i++) {
      name = '$base-$i';
    }
    final res = await ws.guard(() => link.call('session.create', {
      'name': name,
      'root': dir.root,
      'path': dir.path,
    }));
    if (res != null && identical(link, ws.link)) {
      openSession(ws, name);
    }
  }

  String _relativePath(_Node n) {
    final matches = _roots
        .where((r) => r.root == n.root && isSameOrInside(n.path, r.path))
        .toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    if (matches.isEmpty) return n.path;
    final base = matches.first.path;
    if (n.path == base) return '.';
    final prefix = base == '/' ? '/' : '$base/';
    return n.path.startsWith(prefix) ? n.path.substring(prefix.length) : n.path;
  }

  void _toggleFilter({bool? open}) {
    final next = open ?? !_filterOpen;
    setState(() {
      _filterOpen = next;
      if (!next) {
        _filterCtl.clear();
        _filterQuery = '';
      }
    });
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _filterFocus.requestFocus();
      });
    } else {
      _focus.requestFocus();
    }
  }

  List<MenuItem> _newItems(_Node n) => [
    MenuItem('新建文件…', () => _newFile(n), icon: Icons.note_add_outlined),
    MenuItem('新建文件夹…', () => _mkdir(n), icon: Icons.create_new_folder_outlined),
  ];

  MenuItem _pasteItem(_Node n) => MenuItem(
    '粘贴',
    _busy != null || ws.fileClipboard.value == null ? null : () => _paste(n),
    icon: Icons.content_paste_outlined,
    hint: 'Ctrl+V',
    quick: true,
  );

  List<MenuItem> _backgroundMenu() {
    final target = _target;
    if (target == null) return const [];
    _focus.requestFocus();
    return [
      _pasteItem(target),
      ..._newItems(target),
      MenuItem('上传到此文件夹…', () => _upload(target), icon: Icons.upload_file_outlined),
      if (ws.hasOp('session.create'))
        MenuItem('在终端中打开', () => _openInTerminal(target), icon: Icons.terminal),
    ];
  }

  List<MenuItem> _rowMenu(_Node n) {
    _focus.requestFocus();
    if (!(_picked.length > 1 && _picked.contains(n.key))) {
      setState(() => _selectOnly(n));
    }
    return _menu(n);
  }

  List<MenuItem> _menu(_Node n) {
    if (_picked.length > 1 && _picked.contains(n.key) && _selectedItems().length > 1) return _multiMenu();
    final dir = n.isDir;
    final isRoot = n.entry == null;
    final folder = WorkspacePath(root: n.root, path: n.path);
    final canAdd = dir && ws.project != null && !ws.project!.folders.contains(folder);
    return [
      if (!isRoot) ...[
        MenuItem('剪切', _busy != null ? null : () => _copy(cut: true, nodes: [n]), icon: Icons.content_cut, hint: 'Ctrl+X', quick: true),
        MenuItem('复制', _busy != null ? null : () => _copy(nodes: [n]), icon: Icons.content_copy_outlined, hint: 'Ctrl+C', quick: true),
      ],
      _pasteItem(n),
      if (!isRoot) ...[
        MenuItem('重命名', _busy != null ? null : () => _rename(n), icon: Icons.drive_file_rename_outline, hint: 'F2', quick: true),
        MenuItem('删除', _busy != null ? null : () => _deleteItems([n]), icon: Icons.delete_outline, danger: true, hint: 'Delete', quick: true),
      ],
      if (dir) MenuItem.more('新建', () => _newItems(n), icon: Icons.add),
      if (dir && ws.hasOp('session.create')) MenuItem('在终端中打开', () => _openInTerminal(n), icon: Icons.terminal),
      if (!dir) MenuItem('打开', () => _open(n), icon: Icons.edit_note),
      if (!dir) MenuItem('下载…', () => _download(n), icon: Icons.download),
      MenuItem('复制路径', () => copyText(ws.entry?.isLocal == true ? ws.app.localAgent.nativePath(n.root, n.path) : n.path, what: '已复制路径'), icon: Icons.link),
      MenuItem('属性…', () => _properties(n), icon: Icons.info_outline, hint: 'Alt+Enter'),
      const MenuItem.separator(),
      MenuItem.more('更多选项', () => [
        if (!isRoot) MenuItem('复制相对路径', () => copyText(_relativePath(n), what: '已复制相对路径'), icon: Icons.content_copy),
        if (!isRoot) MenuItem('创建副本', _busy != null ? null : () => _duplicate(n), icon: Icons.file_copy_outlined),
        if (dir) MenuItem('上传到这里…', () => _upload(n), icon: Icons.upload_file_outlined),
        if (dir) MenuItem('以此文件夹创建工作区…', () => createProjectWorkspace(context, ws, initial: folder), icon: Icons.workspaces_outline),
        if (canAdd) MenuItem('添加到当前工作区', () => ws.addFolder(folder), icon: Icons.create_new_folder_outlined),
        if (isRoot && widget.projectId.isNotEmpty)
          MenuItem('从工作区移除文件夹', () => ws.removeFolder(folder), icon: Icons.folder_off_outlined),
      ]),
    ];
  }

  void _keyboardMenu() {
    final ctx = _fileViewport.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final selected = _selected;
    var y = 0.0;
    if (selected != null && _scroll.hasClients) {
      final rows = [for (final r in _roots) ..._rows(r, 0)];
      final i = rows.indexWhere((row) => row.note == null && identical(row.node, selected));
      if (i >= 0) {
        final offset = (i + 1) * FileTreeRow.heightOf(context) - _scroll.offset;
        y = offset.clamp(0.0, box.size.height);
      }
    }
    showMenuAt(ctx!, box.localToGlobal(Offset(24, y)),
      selected == null ? _backgroundMenu() : _rowMenu(selected));
  }

  void _scrollToNode(_Node target) {
    final rows = [for (final r in _roots) ..._rows(r, 0)];
    final index = rows.indexWhere((r) => identical(r.node, target) && r.note == null);
    if (index < 0 || !_scroll.hasClients) return;
    final height = FileTreeRow.heightOf(context);
    final top = index * height;
    final bottom = top + height;
    final vp = _scroll.position.viewportDimension;
    final cur = _scroll.offset;
    if (top < cur) {
      _scroll.jumpTo(top.clamp(0.0, _scroll.position.maxScrollExtent));
    } else if (bottom > cur + vp) {
      _scroll.jumpTo((bottom - vp).clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  void _moveSelection(int delta, {bool extend = false}) {
    final visible = [
      for (final r in _roots)
        for (final row in _rows(r, 0))
          if (row.note == null) row.node,
    ];
    if (visible.isEmpty) return;
    final curIdx = _selected == null ? -1 : visible.indexWhere((n) => identical(n, _selected));
    final nextIdx = curIdx < 0
        ? (delta > 0 ? 0 : visible.length - 1)
        : (curIdx + delta).clamp(0, visible.length - 1);
    final next = visible[nextIdx];
    setState(() {
      if (extend && _anchor != null) {
        final a = visible.indexWhere((n) => identical(n, _anchor));
        if (a >= 0) {
          _picked = {for (var i = math.min(a, nextIdx); i <= math.max(a, nextIdx); i++) visible[i].key};
          _selected = next;
          return;
        }
      }
      _selectOnly(next);
    });
    _scrollToNode(next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || _busy != null) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final shift = kb.isShiftPressed;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyC) {
      _copy();
    } else if (ctrl && k == LogicalKeyboardKey.keyX) {
      _copy(cut: true);
    } else if (ctrl && k == LogicalKeyboardKey.keyV) {
      _paste();
    } else if (ctrl && k == LogicalKeyboardKey.keyF) {
      _toggleFilter(open: true);
    } else if (k == LogicalKeyboardKey.f5) {
      _refreshFromCommand();
    } else if (k == LogicalKeyboardKey.contextMenu || (shift && k == LogicalKeyboardKey.f10)) {
      _keyboardMenu();
    } else if (kb.isAltPressed && (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter)) {
      final selected = _selected;
      if (selected != null && _picked.length == 1) _properties(selected);
    } else if (k == LogicalKeyboardKey.f2) {
      final items = _selectedItems();
      if (items.length == 1) _rename(items.first);
    } else if (k == LogicalKeyboardKey.delete) {
      _deleteItems(_selectedItems());
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1, extend: shift);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1, extend: shift);
    } else if (k == LogicalKeyboardKey.home) {
      _moveSelection(-1000000);
    } else if (k == LogicalKeyboardKey.end) {
      _moveSelection(1000000);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      final s = _selected;
      if (s != null && s.isDir) {
        if (!s.expanded) {
          _expand(s, true);
        } else if (s.children != null && s.children!.isNotEmpty) {
          _moveSelection(1);
        }
      }
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      final s = _selected;
      if (s != null) {
        if (s.isDir && s.expanded) {
          _expand(s, false);
        } else {
          final parent = _findParent(s);
          if (parent != null) {
            setState(() => _selectOnly(parent));
            _scrollToNode(parent);
          }
        }
      }
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      final s = _selected;
      if (s != null) _open(s);
    } else if (k == LogicalKeyboardKey.escape) {
      if (_filterOpen) {
        _toggleFilter(open: false);
      } else if (ws.fileClipboard.value != null) {
        ws.fileClipboard.value = null;
      } else {
        setState(() => _picked = _selected == null ? {} : {_selected!.key});
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---- build ----

  bool _matchesFilter(_Node n, String q) {
    if (n.name.toLowerCase().contains(q)) return true;
    for (final c in n.children ?? const <_Node>[]) {
      if (_matchesFilter(c, q)) return true;
    }
    return false;
  }

  Iterable<({_Node node, int depth, String? note})> _rows(_Node n, int depth) sync* {
    final q = _filterQuery.toLowerCase();
    if (q.isNotEmpty) {
      if (!_matchesFilter(n, q)) return;
      yield (node: n, depth: depth, note: null);
      for (final c in n.children ?? const <_Node>[]) {
        yield* _rows(c, depth + 1);
      }
      return;
    }
    yield (node: n, depth: depth, note: null);
    if (n.expanded) {
      if (n.error != null) {
        yield (node: n, depth: depth + 1, note: n.error);
      }
      for (final c in n.children ?? const <_Node>[]) {
        yield* _rows(c, depth + 1);
      }
      if (n.children != null && n.children!.isEmpty && n.error == null) {
        yield (node: n, depth: depth + 1, note: '（空文件夹）');
      }
    }
  }

  /// "12 KB", a folder's measured size, and the time when the list is sorted by it.
  String? _detail(_Node n) {
    if (n.entry == null) return null;
    final parts = <String>[];
    if (n.isDir) {
      if (n.duBusy) {
        parts.add('计算中…');
      } else if (n.du != null) {
        parts.add('${n.du!.partial ? '≥ ' : ''}${formatSize(n.du!.bytes)}');
      }
    } else {
      parts.add(formatSize(n.fileSize));
    }
    return parts.isEmpty ? null : parts.join('  ');
  }

  String _tooltip(_Node n) {
    final e = n.entry;
    if (e == null) return n.location ?? n.path;
    final lines = [ws.entry?.isLocal == true ? ws.app.localAgent.nativePath(n.root, n.path) : n.path];
    if (!n.isDir) {
      lines.add('大小 ${formatSize(n.fileSize)}（${n.fileSize} 字节）');
    } else if (n.du != null) {
      lines.add('大小 ${n.du!.partial ? '至少 ' : ''}${formatSize(n.du!.bytes)} · ${n.du!.files} 个文件');
    }
    if (n.mtime > 0) lines.add('修改 ${formatTime(n.mtime)}');
    if (e['mode'] != null) lines.add('权限 ${e['mode']}${(e['owner'] as String? ?? '').isEmpty ? '' : '  ${e['owner']}:${e['group'] ?? ''}'}');
    return lines.join('\n');
  }

  Widget _footer(Ide ide) {
    final clip = ws.fileClipboard.value;
    final pendingPaste = ws.pendingPaste.value;
    final sel = _selectedItems();
    if (_busy == null && clip == null && pendingPaste == null && sel.length < 2) return const SizedBox.shrink();
    Widget content;
    if (_busy != null) {
      content = Row(children: [
        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6)),
        const SizedBox(width: 8),
        Expanded(child: Text(_busy!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ide.textDim))),
      ]);
    } else {
      final parts = <String>[];
      if (sel.length > 1) {
        var total = 0, unknown = 0;
        for (final n in sel) {
          if (n.isDir) {
            n.du == null ? unknown++ : total += n.du!.bytes;
          } else {
            total += n.fileSize;
          }
        }
        parts.add('已选 ${sel.length} 项 · ${formatSize(total)}${unknown > 0 ? '（另有 $unknown 个文件夹未统计）' : ''}');
      }
      if (clip != null) parts.add('${clip.cut ? '已剪切' : '已复制'} ${clip.items.length} 项');
      if (pendingPaste != null) parts.add('替换结果待核对');
      content = Row(children: [
        Expanded(child: Text(parts.join('　'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ide.textDim, height: 1.35))),
        if (pendingPaste != null)
          IconBtn(Icons.receipt_long_outlined, '查询替换结果', _queryPaste, size: 14),
        if (clip != null) ...[
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
            onPressed: () => _paste(),
            child: const Text('粘贴', style: TextStyle(fontSize: 12)),
          ),
          IconBtn(Icons.close, '清除剪贴板', () => ws.fileClipboard.value = null, size: 14),
        ],
      ]);
    }
    return Container(
      key: const ValueKey('file-footer'),
      padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
      decoration: BoxDecoration(color: ide.sideBar, border: Border(top: BorderSide(color: ide.border))),
      child: content,
    );
  }

  double _newButtonWidth(BuildContext context) =>
      (40 + 2 * MediaQuery.textScalerOf(context).scale(12)).ceilToDouble();

  double _commandWidth(BuildContext context) =>
      _newButtonWidth(context) + 5 * ((InputMode.isTouch(context) ? UiMetrics.touchRow : UiMetrics.compactRow) + Space.xs);

  Widget _commandBar(Ide ide, _Node? target) {
    final touch = InputMode.isTouch(context);
    return UiToolbar(
          key: const ValueKey('file-command-bar'),
          padding: EdgeInsets.zero,
          spacing: Space.xs,
          children: [
            WorkbenchMenuButton<int>(
              tooltip: '新建',
              enabled: target != null && _busy == null,
              itemBuilder: (_) => [
                const PopupMenuItem(value: 0, child: MenuLabel('文件…', icon: Icons.note_add_outlined)),
                const PopupMenuItem(value: 1, child: MenuLabel('文件夹…', icon: Icons.create_new_folder_outlined)),
              ],
              onSelected: (value) {
                if (target == null) return;
                if (value == 0) {
                  _newFile(target);
                } else {
                  _mkdir(target);
                }
              },
              child: SizedBox(
                width: _newButtonWidth(context),
                height: touch ? UiMetrics.touchRow : UiMetrics.compactRow,
                child: Center(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.add, size: 17, color: target == null || _busy != null ? ide.textFaint : ide.accent),
                    const SizedBox(width: Space.xs),
                    Flexible(child: Text('新建', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: target == null || _busy != null ? ide.textFaint : ide.text))),
                    Icon(Icons.expand_more, size: 15, color: ide.textDim),
                  ]),
                ),
              ),
            ),
            IconBtn(Icons.refresh_rounded, '刷新（F5）',
              ws.link == null || _loadingRoots || _busy != null ? null : _refreshFromCommand),
            Builder(builder: (anchor) => IconBtn(
              Icons.sort_rounded,
              '排序',
              () => showMenuAt(anchor, Offset.zero, _sortItems(), anchor: anchor),
              color: _sort != 'name' || _desc || !_foldersFirst ? ide.accent : null,
            )),
            IconBtn(Icons.filter_list_rounded, '过滤文件（Ctrl+F）', _toggleFilter,
              color: _filterOpen ? ide.accent : null),
            IconBtn(Icons.my_location_outlined, '定位当前文件',
              ws.active?.file == null ? null : _revealActive),
            WorkbenchMenuButton<String>(
              tooltip: '文件选项',
              icon: Icon(Icons.more_horiz, size: 17, color: _hidden ? ide.accent : ide.textDim),
              onSelected: (value) {
                switch (value) {
                  case 'upload':
                    if (target != null) _upload(target);
                  case 'hidden':
                    setState(() => _hidden = !_hidden);
                    _refreshAll();
                  case 'collapse':
                    _collapseAll();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'upload', enabled: target != null && _busy == null,
                  child: const MenuLabel('上传文件…', icon: Icons.upload_file_outlined)),
                const PopupMenuDivider(),
                CheckedPopupMenuItem(value: 'hidden', checked: _hidden,
                  child: const MenuLabel('显示隐藏文件', icon: Icons.visibility_outlined)),
                const PopupMenuItem(value: 'collapse',
                  child: MenuLabel('折叠所有文件夹', icon: Icons.unfold_less_rounded)),
              ],
            ),
          ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final target = _target;
    final rows = [for (final r in _roots) ..._rows(r, 0)];
    final clip = ws.fileClipboard.value;
    return Column(children: [
      ValueListenableBuilder<String?>(valueListenable: ws.watch.status, builder: (_, status, _) =>
        status == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.all(8),
          child: Text(status, style: TextStyle(color: ide.warn, fontSize: 11)))),
      ProjectWorkspaceBar(ws: ws, commands: _commandBar(ide, target), commandWidth: _commandWidth(context)),
      if (_filterOpen)
        Container(
          key: const ValueKey('file-filter-bar'),
          padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
          decoration: BoxDecoration(
            color: ide.sideBar,
            border: Border(bottom: BorderSide(color: ide.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: InputMode.isTouch(context) ? UiMetrics.touchRow : UiMetrics.compactRow,
                  ),
                  child: Focus(
                    onKeyEvent: (_, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        _toggleFilter(open: false);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _filterCtl,
                      focusNode: _filterFocus,
                      style: const TextStyle(fontSize: 12.5),
                      decoration: InputDecoration(
                        hintText: '过滤已展开文件名…',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        prefixIcon: Icon(
                          Icons.filter_alt_outlined,
                          size: 14,
                          color: ide.textDim,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 24,
                        ),
                        suffixIcon: _filterQuery.isEmpty
                            ? null
                            : IconBtn(
                                Icons.close,
                                '清除过滤',
                                () => _filterCtl.clear(),
                                size: 14,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              IconBtn(
                Icons.close,
                '关闭过滤（Esc）',
                () => _toggleFilter(open: false),
                size: 15,
              ),
            ],
          ),
        ),
      if (rows.isNotEmpty && !_loadingRoots && _error == null)
        FileTreeHead(
          sort: _sort,
          descending: _desc,
          onSort: (column) => _setSort(sort: column, desc: _sort == column && !_desc),
        ),
      Expanded(
        child: _error != null ? EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _loadRoots)
          : _loadingRoots ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          : _roots.isEmpty
          ? EmptyHint(icon: Icons.folder_open_outlined, text: widget.projectId.isEmpty ? '服务器没有可用的根目录' : '工作区里还没有文件夹',
              actionLabel: widget.projectId.isEmpty ? '刷新' : '添加远程文件夹',
              onAction: widget.projectId.isEmpty ? _loadRoots : () => addProjectFolder(context, ws))
          : _filterQuery.isNotEmpty && rows.isEmpty
          ? EmptyHint(
              icon: Icons.search_off_rounded,
              text: '当前展开树中没有匹配「$_filterQuery」的文件',
              actionLabel: ws.hasOp('fs.find') ? '全项目查找（Ctrl+P）' : '清除过滤',
              onAction: ws.hasOp('fs.find')
                  ? () => showQuickOpen(ws, context: context)
                  : () => _filterCtl.clear(),
            )
           : Focus(
                 focusNode: _focus,
                 onKeyEvent: _onKey,
                 child: CustomScrollView(
                   key: _fileViewport,
                   controller: _scroll,
                   semanticChildCount: rows.length,
                   slivers: [
                     SliverFixedExtentList.builder(itemExtent: FileTreeRow.heightOf(context), itemCount: rows.length, itemBuilder: (context, i) {
                  final row = rows[i], n = rows[i].node;
                  if (row.note != null) { return Tooltip(message: row.note!, child: Padding(padding: EdgeInsets.only(left: 30 + math.min(row.depth * 14.0, 60), right: 8),
                    child: Align(alignment: Alignment.centerLeft, child: Text(row.note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: n.error == null ? ide.textDim : ide.error))))); }
                  Widget treeRow = FileTreeRow(key: ObjectKey(n), name: n.name, path: n.path, depth: row.depth,
                    folder: n.isDir, expanded: _filterQuery.isNotEmpty ? true : n.expanded, loading: n.loading, selected: _picked.contains(n.key),
                    root: n.entry == null, location: n.location, link: n.entry?['type'] == 'link',
                    active: ws.active?.file == WorkspacePath(root: n.root, path: n.path),
                    modified: n.mtime > 0 ? formatShortTime(n.mtime) : null, preferModified: _sort == 'mtime',
                    dragOver: _dragOverKey == n.key,
                    onExpand: n.isDir ? () => _expand(n, !n.expanded) : null,
                    dimmed: clip != null && clip.cut && clip.contains(n.root, n.path),
                     tooltip: _tooltip(n), detail: _detail(n), onTap: () => _tap(n),
                     onDoubleTap: n.isDir || InputMode.isTouch(context) ? null : () => _tap(n, keep: true),
                     menu: () => _rowMenu(n));
                  if (n.isDir) {
                    final inner = treeRow;
                    treeRow = DragTarget<_TreeDragData>(
                      onWillAcceptWithDetails: (d) {
                        if (_busy != null || !identical(d.data.link, ws.link)) return false;
                        final ok = d.data.canDropInto(n);
                        if (ok && _dragOverKey != n.key) setState(() => _dragOverKey = n.key);
                        return ok;
                      },
                      onLeave: (_) {
                        if (_dragOverKey == n.key) setState(() => _dragOverKey = null);
                      },
                      onAcceptWithDetails: (d) {
                        if (_dragOverKey == n.key) setState(() => _dragOverKey = null);
                        if (identical(d.data.link, ws.link)) unawaited(_runPaste(d.data.items, true, n));
                      },
                      builder: (_, _, _) => inner,
                    );
                  }
                   if (n.entry != null) {
                     // Switching input devices on pointer-down must not unmount
                     // the row's active long-press recognizer.
                    final dragNodes = _picked.length > 1 && _picked.contains(n.key) ? _selectedItems() : [n];
                     final dragData = _TreeDragData([for (final x in dragNodes) _clipItem(x)], ws.link);
                    treeRow = Draggable<_TreeDragData>(
                      data: dragData,
                      allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
                       maxSimultaneousDrags: InputMode.isTouch(context) ? 0 : 1,
                      feedback: Material(
                        elevation: 4,
                        color: ide.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(Radii.m),
                          side: BorderSide(color: ide.accent),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FileIcon(name: n.name, folder: n.isDir, size: 15),
                              const SizedBox(width: 6),
                              Text(
                                dragNodes.length > 1 ? '${n.name} 等 ${dragNodes.length} 项' : n.name,
                                style: TextStyle(fontSize: 12, color: ide.text),
                              ),
                            ],
                          ),
                        ),
                      ),
                      child: treeRow,
                    );
                  }
                  return treeRow;
                     }),
                     SliverFillRemaining(
                       hasScrollBody: false,
                       child: ContextArea(
                         key: const ValueKey('file-tree-background'),
                         items: _backgroundMenu,
                         child: const SizedBox.shrink(),
                       ),
                     ),
                   ],
                 ),
             ),
      ),
      _footer(ide),
      if (widget.transfers.list.isNotEmpty) _TransferList(transfers: widget.transfers),
    ]);
  }
}

class _TreeDragData {
  final List<ClipItem> items;
  final Link? link;
  const _TreeDragData(this.items, this.link);

  bool canDropInto(_Node dest) {
    if (!dest.isDir || items.isEmpty) return false;
    for (final it in items) {
      if (it.root == dest.root) {
        if (parentPath(it.path) == dest.path) return false;
        if (it.isDir && isSameOrInside(dest.path, it.path)) return false;
      }
    }
    return true;
  }
}

class _TransferList extends StatelessWidget {
  final Transfers transfers;
  const _TransferList({required this.transfers});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final list = transfers.list.reversed.take(5).toList();
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: ide.border))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SectionHeader('传输${transfers.active > 0 ? '（${transfers.active} 进行中）' : ''}', actions: [
          if (transfers.list.any((t) => t.finished)) IconBtn(Icons.clear_all, '清除已完成', transfers.clearFinished),
        ]),
        if (transfers.aggregateFraction != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 3, 10, 1),
            child: Row(children: [
              Expanded(child: LinearProgressIndicator(value: transfers.aggregateFraction, minHeight: 3)),
              const SizedBox(width: 8),
              Text('${(transfers.aggregateFraction! * 100).round()}%', style: TextStyle(fontSize: 11, color: ide.textDim)),
            ]),
          ),
        for (final t in list)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 2, 4),
            child: Row(children: [
              Icon(t.upload ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: t.error != null ? ide.error : ide.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  if (t.error != null)
                    Text(t.error!, style: TextStyle(color: ide.error, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis)
                  else if (t.cancelled)
                    Text('已取消', style: TextStyle(color: ide.textDim, fontSize: 11))
                  else if (t.finished)
                    Text('完成 · ${formatSize(t.total)}', style: TextStyle(color: ide.ok, fontSize: 11))
                  else
                    Row(children: [
                      Expanded(child: LinearProgressIndicator(value: t.fraction, minHeight: 3)),
                      const SizedBox(width: 8),
                      Text('${formatSize(t.rate)}/s', style: TextStyle(color: ide.textDim, fontSize: 11)),
                    ]),
                ]),
              ),
              if (!t.finished)
                IconBtn(Icons.close, '取消', t.cancel)
              else if (t.error != null) ...[
                IconBtn(Icons.refresh, '重试', t.retry),
                IconBtn(Icons.close, '移除', () => transfers.remove(t)),
              ] else
                IconBtn(Icons.close, '移除', () => transfers.remove(t)),
            ]),
          ),
      ]),
    );
  }
}
