// The file tree in the side bar (service "files"). Folders expand in place;
// a click on a file opens it in an editor tab; every row has the same menu on
// right-click and on long-press. Uploads ask before replacing a file that is
// already there, and every transfer can be cancelled.
//
// Beyond browsing: Ctrl/Shift-click selects several rows; Copy, Cut and Paste
// (Ctrl+C / Ctrl+X / Ctrl+V, or the menu) work on the server, inside a root or
// across roots; F2 renames, Delete deletes; the sort button orders a folder by
// name, size, time or type; "Calculate size" totals a folder (fs.du) and shows
// the size of each folder under it; Properties shows everything about one item.
// The logic lives in file_ops.dart so it is tested without widgets.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:aurora_install/aurora_install.dart' show compareVersions, parseVersion;
import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../kernel/feature.dart';
import '../../kernel/input_mode.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../kernel/retained_pages.dart';
import '../../theme/ide_theme.dart';
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
        if (mounted && ws.projectKey == key) ws.restoreFiles((f) => fileEditorTab(ws, root: f.root, path: f.path));
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

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    widget.transfers.addListener(_tick);
    ws.filesRevision.addListener(_onFilesChanged);
    ws.fileClipboard.addListener(_tick);
    ws.addListener(_onWorkspace);
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
    ws.removeListener(_onWorkspace);
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

  void _sortMenu(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    showMenuAt(ctx, at, [
      for (final (k, label) in const [('name', '名称'), ('size', '大小'), ('mtime', '修改时间'), ('type', '类型')])
        MenuItem(label, () => _setSort(sort: k), icon: _sort == k ? Icons.check : null, hint: k == 'size' ? '文件夹需先统计' : null),
      const MenuItem.separator(),
      MenuItem('升序', () => _setSort(desc: false), icon: !_desc ? Icons.check : null, hint: '小→大 旧→新 A→Z'),
      MenuItem('降序', () => _setSort(desc: true), icon: _desc ? Icons.check : null),
      const MenuItem.separator(),
      MenuItem('文件夹排在前面', () => _setSort(folders: !_foldersFirst), icon: _foldersFirst ? Icons.check : null),
    ], anchor: ctx);
  }

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
      if (!mounted || generation != _generation) return;
      final project = ws.entry?.workspace(widget.projectId);
      final nodes = project == null
          ? [for (final x in list) _Node(x['id'] as String, '/', (x['label'] as String?) ?? x['id'] as String, null, location: x['path'] as String?)]
          : [for (final f in project.folders) _Node(f.root, f.path, f.path == '/' ? (list.where((r) => r['id'] == f.root).firstOrNull?['label'] as String? ?? f.root) : f.name,
              null, location: '${f.root}:${f.path}')];
      setState(() {
        _roots
          ..clear()
          ..addAll(nodes);
        _selected = null;
        _anchor = null;
        _picked = {};
        _loadingRoots = false;
        _error = null;
      });
      for (final n in _roots.toList()) {
        if (!mounted || generation != _generation) return;
        final open = _expanded.contains(WorkspacePath(root: n.root, path: n.path)) ||
          (!_treeSet && (project != null || identical(n, _roots.first)));
        if (open) await _expand(n, true, remember: false);
      }
    } on OpError catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e.message;
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
      if (!mounted || generation != _generation || n.request != request || hidden != _hidden) return;
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
      if (_selected != null) {
        // keep the selection on the node that now stands for the same path
        for (final c in nodes) {
          if (c.key == _selected!.key) _selected = c;
        }
      }
      if (restore) {
        for (final c in nodes.where((c) => c.isDir && c.expanded && c.children == null)) {
          if (!mounted || generation != _generation) return;
          await _load(c);
        }
      }
    } on OpError catch (e) {
      if (mounted && generation == _generation && request == n.request && hidden == _hidden) n.error = e.message;
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
    final height = InputMode.row(context) + 2;
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
    return _refreshing ??= _refreshLoop().whenComplete(() => _refreshing = null);
  }

  Future<void> _refreshLoop() async {
    while (_refreshAgain && mounted) {
    _refreshAgain = false;
    final generation = _generation;
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

  void _tap(_Node n) {
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
    _open(n);
  }

  // ---- operations ----

  Future<void> _mkdir(_Node dir) async {
    final name = await askText(context, title: '新建文件夹', hint: '名称');
    if (name == null || name.isEmpty) return;
    await ws.guard(() => ws.link!.call('fs.mkdir', {'root': dir.root, 'path': dir.child(name)}));
    await _expand(dir, true);
    await _load(dir);
  }

  Future<void> _newFile(_Node dir) async {
    final name = await askText(context, title: '新建文件', hint: '名称，例如 notes.txt');
    if (name == null || name.isEmpty) return;
    final ok = await ws.guard(() => ws.link!.call('fs.write', {'root': dir.root, 'path': dir.child(name), 'content': '', 'create': true}));
    await _expand(dir, true);
    await _load(dir);
    if (ok != null) ws.openTab(fileEditorTab(ws, root: dir.root, path: dir.child(name)));
  }

  /// An open tab with unsaved text under [path]: renaming, moving or deleting
  /// the file would leave that text with nowhere to be saved.
  bool _hasUnsaved(String root, String path) =>
      ws.tabs.any((t) => t.dirty.value && (t.id == 'file:$root:$path' || t.id.startsWith('file:$root:$path/')));

  void _warnUnsaved() => ws.toast('这里有打开的文件还没保存，先保存或关闭它再操作', error: true);

  Future<void> _rename(_Node n) async {
    if (n.entry == null) return;
    if (_hasUnsaved(n.root, n.path)) return _warnUnsaved();
    final to = await askText(context, title: '重命名', initial: n.name);
    if (to == null || to.isEmpty || to == n.name) return;
    if (to.contains('/')) return ws.toast('名称里不能有 /', error: true);
    final dest = joinPath(parentPath(n.path), to);
    final wasOpen = !n.isDir && ws.tab('file:${n.root}:${n.path}') != null;
    final ok = await ws.guard(() => ws.link!.call('fs.rename', {'root': n.root, 'path': n.path, 'to': dest}));
    if (ok == null) return;
    ws.dropTabs((t) => t.id == 'file:${n.root}:${n.path}' || t.id.startsWith('file:${n.root}:${n.path}/'));
    if (wasOpen) ws.openTab(fileEditorTab(ws, root: n.root, path: dest)); // keep working on the renamed file
    await _reload(n);
    if (mounted) setState(() => _picked.remove(n.key));
  }

  Future<void> _deleteItems(List<_Node> items) async {
    if (items.isEmpty) return;
    if (items.any((n) => _hasUnsaved(n.root, n.path))) return _warnUnsaved();
    final dirs = items.any((n) => n.entry?['type'] == 'dir');
    final ok = await confirmDialog(context,
        title: items.length == 1 ? '删除 ${items.first.name}？' : '删除这 ${items.length} 项？',
        body: dirs ? '文件夹和里面的所有内容都会被删除，不能恢复。' : '删除后不能恢复。',
        ok: '删除',
        danger: true);
    if (!ok || !mounted) return;
    final errors = <String>[];
    var done = 0;
    setState(() => _busy = '正在删除…');
    try {
      for (var i = 0; i < items.length; i++) {
        final n = items[i];
        if (mounted) setState(() => _busy = '正在删除（${i + 1}/${items.length}）${n.name}');
        try {
          await ws.link!.call('fs.delete', {'root': n.root, 'path': n.path, 'recursive': n.entry?['type'] == 'dir'}, const Duration(minutes: 10));
          ws.dropTabs((t) => t.id == 'file:${n.root}:${n.path}' || t.id.startsWith('file:${n.root}:${n.path}/'));
          done++;
        } on OpError catch (e) {
          errors.add('${n.name}：${e.message}');
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _picked = {};
          _selected = null;
        });
      }
    }
    if (errors.isNotEmpty) ws.toast('${errors.first}${errors.length > 1 ? '（另有 ${errors.length - 1} 项失败）' : ''}', error: true);
    if (done > 0 && errors.isEmpty && items.length > 1) ws.toast('已删除 $done 项');
    await _refreshAll();
  }

  Future<void> _upload(_Node dir) async {
    final link = ws.link;
    if (link == null) return;
    final res = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件');
    await uploadFiles(dir, [for (final f in res) if (f.path != null) File(f.path!)]);
  }

  /// Uploads local files into [dir]. A name that is already there is asked
  /// about (replace, skip, or replace all), never overwritten silently.
  Future<void> uploadFiles(_Node dir, List<File> files) async {
    final link = ws.link;
    if (link == null || files.isEmpty) return;
    if (dir.children == null) await _load(dir);
    final existing = {for (final c in dir.children ?? const <_Node>[]) c.name};
    var replaceAll = false;
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (existing.contains(name) && !replaceAll) {
        final choice = await _askReplace(name, files.length > 1);
        if (choice == 'skip' || choice == null) continue;
        if (choice == 'all') replaceAll = true;
      }
      final size = await f.length();
      widget.transfers.upload(link, f, size, dir.root, dir.child(name), onDone: () {
        if (mounted) _load(dir);
      });
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

  void _open(_Node n) {
    setState(() => _selectOnly(n));
    if (n.isDir) {
      _expand(n, !n.expanded);
    } else {
      ws.openTab(fileEditorTab(ws, root: n.root, path: n.path));
    }
  }

  // ---- clipboard ----

  void _copy({bool cut = false, List<_Node>? nodes}) {
    final items = nodes ?? _selectedItems();
    if (items.isEmpty) return;
    if (cut && items.any((n) => _hasUnsaved(n.root, n.path))) return _warnUnsaved();
    ws.fileClipboard.value = FileClipboard([for (final n in items) ClipItem(n.root, n.path, n.isDir)], cut: cut);
    final what = items.length == 1 ? items.first.name : '${items.length} 项';
    ws.toast(cut ? '已剪切 $what，到目标文件夹里选“粘贴”' : '已复制 $what，到目标文件夹里选“粘贴”');
  }

  bool _crossRootOk() {
    final v = ws.link?.server.version ?? '';
    if (parseVersion(v) == null) return true; // a development build is the newest
    return (compareVersions(v, crossRootAgent) ?? -1) >= 0;
  }

  Future<ConflictChoice?> _askConflict(String name, bool isDir, {required bool more}) {
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
              Text(isDir ? '“替换”用这个文件夹整个换掉旧的，旧的要等新的完整复制好之后才删除；“保留两者”会给新的加上“副本”。' : '“替换”用这个文件换掉旧的；“保留两者”会给新的加上“副本”。'),
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
            FilledButton(style: FilledButton.styleFrom(backgroundColor: ide.error), onPressed: () => Navigator.pop(c, ConflictChoice(Conflict.replace, all: all)), child: const Text('替换')),
          ],
        ),
      ),
    );
  }

  /// The folder Paste goes into for a row: the folder itself, or a file's folder.
  _Node? _pasteTargetFor(_Node? n) => n == null ? _target : (n.isDir ? n : (_findParent(n) ?? _target));

  Future<void> _paste([_Node? onto]) async {
    final clip = ws.fileClipboard.value;
    final dest = _pasteTargetFor(onto);
    if (clip == null || dest == null) return;
    await _runPaste(clip.items, clip.cut, dest);
  }

  Future<void> _duplicate(_Node n) async {
    final parent = _findParent(n);
    if (parent == null || n.entry == null) return;
    await _runPaste([ClipItem(n.root, n.path, n.isDir)], false, parent);
  }

  Future<void> _runPaste(List<ClipItem> items, bool cut, _Node dest) async {
    final link = ws.link;
    if (link == null || _busy != null) return;
    if (items.any((i) => i.root != dest.root) && !_crossRootOk()) {
      ws.toast('在不同根目录之间复制或移动，需要服务器上的 agent 升级到 $crossRootAgent 或更高', error: true);
      return;
    }
    if (cut && items.any((i) => _hasUnsaved(i.root, i.path))) return _warnUnsaved();
    setState(() => _busy = '正在准备粘贴…');
    PasteResult? res;
    try {
      // the real names in the destination, hidden ones included: a taken name is a conflict
      final listing = await ws.guard(() => link.call('fs.list', {'root': dest.root, 'path': dest.path, 'hidden': true})) as Map?;
      if (listing == null) return;
      final existing = {for (final e in listing['entries'] as List) (e as Map)['name'] as String};
      res = await pasteItems(
        call: (op, args) => link.call(op, args, op == 'fs.copy' || op == 'fs.delete' ? const Duration(minutes: 30) : const Duration(seconds: 60)),
        items: items,
        cut: cut,
        destRoot: dest.root,
        destDir: dest.path,
        existing: existing,
        resolve: (name, isDir, {required more}) async => mounted ? _askConflict(name, isDir, more: more) : null,
        onProgress: (i, total, name) {
          if (mounted) setState(() => _busy = '${cut ? '正在移动' : '正在复制'}${total > 1 ? '（${i + 1}/$total）' : ''} $name');
        },
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!mounted) return;
    for (final m in res.moved) {
      ws.dropTabs((t) => t.id == 'file:${m.root}:${m.path}' || t.id.startsWith('file:${m.root}:${m.path}/'));
    }
    if (cut && res.moved.isNotEmpty) {
      // what was moved is gone from the old place: it cannot be pasted again
      final left = [for (final i in items) if (!res.moved.any((m) => m.root == i.root && m.path == i.path)) i];
      ws.fileClipboard.value = left.isEmpty ? null : FileClipboard(left, cut: true);
    }
    await _expand(dest, true);
    await _refreshAll();
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
      MenuItem('复制 ${items.length} 项', () => _copy(), icon: Icons.content_copy_outlined, hint: 'Ctrl+C'),
      MenuItem('剪切 ${items.length} 项', () => _copy(cut: true), icon: Icons.content_cut, hint: 'Ctrl+X'),
      if (dirs.isNotEmpty && _canMeasure) MenuItem('计算文件夹大小', () => _measure(dirs), icon: Icons.data_usage_rounded),
      const MenuItem.separator(),
      MenuItem('删除 ${items.length} 项…', () => _deleteItems(items), icon: Icons.delete_outline, danger: true, hint: 'Delete'),
      const MenuItem.separator(),
      MenuItem('取消选择', () => setState(() {
            _picked = {};
            _selected = null;
          }), icon: Icons.deselect),
    ];
  }

  List<MenuItem> _menu(_Node n) {
    if (_picked.length > 1 && _picked.contains(n.key) && _selectedItems().length > 1) return _multiMenu();
    final dir = n.isDir;
    final isRoot = n.entry == null;
    final clip = ws.fileClipboard.value;
    return [
      if (dir) MenuItem('新建文件…', () => _newFile(n), icon: Icons.note_add_outlined),
      if (dir) MenuItem('新建文件夹…', () => _mkdir(n), icon: Icons.create_new_folder_outlined),
      if (dir) MenuItem('上传到这里…', () => _upload(n), icon: Icons.upload_file),
      if (dir) MenuItem('以此文件夹创建工作区…', () => createProjectWorkspace(context, ws, initial: WorkspacePath(root: n.root, path: n.path)), icon: Icons.workspaces_outline),
      if (dir && ws.project != null) MenuItem('添加到当前工作区', () => ws.addFolder(WorkspacePath(root: n.root, path: n.path)), icon: Icons.create_new_folder_outlined),
      if (!dir) MenuItem('打开', () => _open(n), icon: Icons.edit_note),
      if (!dir) MenuItem('下载…', () => _download(n), icon: Icons.download),
      const MenuItem.separator(),
      if (!isRoot) MenuItem('复制', () => _copy(nodes: [n]), icon: Icons.content_copy_outlined, hint: 'Ctrl+C'),
      if (!isRoot) MenuItem('剪切', () => _copy(cut: true, nodes: [n]), icon: Icons.content_cut, hint: 'Ctrl+X'),
      if (dir || clip != null)
        MenuItem(dir ? '粘贴到这里' : '粘贴到同一文件夹', clip == null ? null : () => _paste(n), icon: Icons.content_paste, hint: 'Ctrl+V'),
      if (!isRoot) MenuItem('创建副本', () => _duplicate(n), icon: Icons.file_copy_outlined),
      const MenuItem.separator(),
      MenuItem('复制路径', () => copyText(ws.entry?.isLocal == true ? ws.app.localAgent.nativePath(n.root, n.path) : n.path, what: '已复制路径'), icon: Icons.copy),
      if (dir) MenuItem('刷新', () => _load(n), icon: Icons.refresh),
      if (dir && _canMeasure) MenuItem(n.du == null ? '计算大小' : '重新计算大小', n.duBusy ? null : () => _measure([n]), icon: Icons.data_usage_rounded),
      if (isRoot && widget.projectId.isNotEmpty) MenuItem('从工作区移除文件夹', () => ws.removeFolder(WorkspacePath(root: n.root, path: n.path)), icon: Icons.folder_off_outlined),
      MenuItem('属性…', () => _properties(n), icon: Icons.info_outline),
      if (!isRoot) ...[
        const MenuItem.separator(),
        MenuItem('重命名…', () => _rename(n), icon: Icons.drive_file_rename_outline, hint: 'F2'),
        MenuItem('删除…', () => _deleteItems([n]), icon: Icons.delete_outline, danger: true, hint: 'Delete'),
      ],
    ];
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || _busy != null) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyC) {
      _copy();
    } else if (ctrl && k == LogicalKeyboardKey.keyX) {
      _copy(cut: true);
    } else if (ctrl && k == LogicalKeyboardKey.keyV) {
      _paste();
    } else if (k == LogicalKeyboardKey.f2) {
      final items = _selectedItems();
      if (items.length == 1) _rename(items.first);
    } else if (k == LogicalKeyboardKey.delete) {
      _deleteItems(_selectedItems());
    } else if (k == LogicalKeyboardKey.escape) {
      if (ws.fileClipboard.value != null) {
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

  Iterable<({_Node node, int depth, String? note})> _rows(_Node n, int depth) sync* {
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
    final sel = _selectedItems();
    if (_busy == null && clip == null && sel.length < 2) return const SizedBox.shrink();
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
      content = Row(children: [
        Expanded(child: Text(parts.join('　'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ide.textDim, height: 1.35))),
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

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final target = _target;
    final rows = [for (final r in _roots) ..._rows(r, 0)];
    final clip = ws.fileClipboard.value;
    return Column(children: [
      ProjectWorkspaceBar(ws: ws, actions: [
          IconBtn(Icons.note_add_outlined, '新建文件', target == null ? null : () => _newFile(target)),
          IconBtn(Icons.refresh, '刷新', _refreshAll),
          IconBtn(Icons.my_location_outlined, '定位当前文件', ws.active?.file == null ? null : _revealActive),
          Builder(builder: (ctx) => SizedBox(width: InputMode.isTouch(context) ? 44 : 28, child: WorkbenchMenuButton<String>(
            tooltip: '文件选项', padding: EdgeInsets.zero,
            icon: Icon(Icons.more_horiz, size: 17, color: _hidden || _sort != 'name' || _desc ? ide.accent : ide.textDim),
            onSelected: (value) {
              if (value == 'folder' && target != null) _mkdir(target);
              if (value == 'paste') _paste();
              if (value == 'upload' && target != null) _upload(target);
              if (value == 'hidden') { setState(() => _hidden = !_hidden); _refreshAll(); }
              if (value == 'sort') _sortMenu(ctx);
              if (value == 'measure' && target != null) _measure([target]);
              if (value == 'collapse') _collapseAll();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'folder', enabled: target != null, child: const MenuLabel('新建文件夹…', icon: Icons.create_new_folder_outlined)),
              if (clip != null) PopupMenuItem(value: 'paste', enabled: _busy == null, child: const MenuLabel('粘贴到选中的文件夹', icon: Icons.content_paste, shortcut: 'Ctrl+V')),
              PopupMenuItem(value: 'upload', enabled: target != null, child: const MenuLabel('上传文件…', icon: Icons.upload_file_outlined)),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(value: 'hidden', checked: _hidden, child: const MenuLabel('显示隐藏文件', icon: Icons.visibility_outlined)),
              const PopupMenuItem(value: 'collapse', child: MenuLabel('折叠所有文件夹', icon: Icons.unfold_less_rounded)),
              PopupMenuItem(value: 'sort', child: MenuLabel('排序：${const {'name': '名称', 'size': '大小', 'mtime': '修改时间', 'type': '类型'}[_sort]}${_desc ? '（降序）' : ''}', icon: Icons.sort_rounded)),
              if (_canMeasure) ...[
                const PopupMenuDivider(),
                PopupMenuItem(value: 'measure', enabled: target != null && !target.duBusy, child: const MenuLabel('计算选中文件夹大小', icon: Icons.data_usage_outlined)),
              ],
            ],
          ))),
        ]),
      Expanded(
        child: _error != null ? EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _loadRoots)
          : _loadingRoots ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          : _roots.isEmpty
          ? EmptyHint(icon: Icons.folder_open_outlined, text: widget.projectId.isEmpty ? '服务器没有可用的根目录' : '工作区里还没有文件夹',
              actionLabel: widget.projectId.isEmpty ? '刷新' : '添加远程文件夹',
              onAction: widget.projectId.isEmpty ? _loadRoots : () => addProjectFolder(context, ws))
          : Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              child: ListView.builder(controller: _scroll, itemExtent: InputMode.row(context) + 2, itemCount: rows.length, itemBuilder: (context, i) {
                final row = rows[i], n = rows[i].node;
                if (row.note != null) { return Tooltip(message: row.note!, child: Padding(padding: EdgeInsets.only(left: 30 + math.min(row.depth * 14.0, 60), right: 8),
                  child: Align(alignment: Alignment.centerLeft, child: Text(row.note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: n.error == null ? ide.textDim : ide.error))))); }
                return FileTreeRow(key: ObjectKey(n), name: n.name, path: n.path, depth: row.depth,
                  folder: n.isDir, expanded: n.expanded, loading: n.loading, selected: _picked.contains(n.key),
                  root: n.entry == null, location: n.location, link: n.entry?['type'] == 'link',
                  active: ws.active?.file == WorkspacePath(root: n.root, path: n.path),
                  modified: n.mtime > 0 ? formatShortTime(n.mtime) : null, preferModified: _sort == 'mtime',
                  onExpand: n.isDir ? () => _expand(n, !n.expanded) : null,
                  dimmed: clip != null && clip.cut && clip.contains(n.root, n.path),
                  tooltip: _tooltip(n), detail: _detail(n), onTap: () => _tap(n),
                  menu: () {
                    // right-click on a row inside a multi-selection keeps it; elsewhere it selects just that row
                    _focus.requestFocus();
                    if (!(_picked.length > 1 && _picked.contains(n.key))) setState(() => _selectOnly(n));
                    return _menu(n);
                  });
              }),
            ),
      ),
      _footer(ide),
      if (widget.transfers.list.isNotEmpty) _TransferList(transfers: widget.transfers),
    ]);
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
              if (!t.finished) IconBtn(Icons.close, '取消', t.cancel) else IconBtn(Icons.close, '移除', () => transfers.remove(t)),
            ]),
          ),
      ]),
    );
  }
}
