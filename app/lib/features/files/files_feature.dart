// The file tree in the side bar (service "files"). Folders expand in place;
// a click on a file opens it in an editor tab; every row has the same menu on
// right-click and on long-press. Uploads ask before replacing a file that is
// already there, and every transfer can be cancelled.
import 'dart:async';
import 'dart:io';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../kernel/feature.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'file_editor.dart';
import 'transfers.dart';

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
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(title: '文件', body: FileTree(ws: ws, transfers: transfers), actions: const []);

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
  final Map<String, dynamic>? entry; // null for a root
  bool expanded = false;
  bool loading = false;
  String? error;
  List<_Node>? children;
  _Node(this.root, this.path, this.name, this.entry);

  bool get isDir => entry == null || entry!['type'] == 'dir' || entry!['target'] == 'dir';
  String child(String n) => path == '/' ? '/$n' : '$path/$n';
}

class FileTree extends StatefulWidget {
  final Workspace ws;
  final Transfers transfers;
  const FileTree({super.key, required this.ws, required this.transfers});
  @override
  State<FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends State<FileTree> {
  final List<_Node> _roots = [];
  _Node? _selected;
  bool _hidden = false;
  String? _error;
  bool _loadingRoots = true;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    widget.transfers.addListener(_tick);
    ws.filesRevision.addListener(_onFilesChanged);
    _loadRoots();
  }

  @override
  void dispose() {
    widget.transfers.removeListener(_tick);
    ws.filesRevision.removeListener(_onFilesChanged);
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

  Future<void> _loadRoots() async {
    final link = ws.link;
    if (link == null) return;
    try {
      final r = await link.call('fs.roots') as Map;
      final list = [for (final x in r['roots'] as List) (x as Map).cast<String, dynamic>()];
      if (!mounted) return;
      setState(() {
        _roots
          ..clear()
          ..addAll([for (final x in list) _Node(x['id'] as String, '/', (x['label'] as String?) ?? x['id'] as String, null)]);
        _loadingRoots = false;
        _error = null;
      });
      if (_roots.isNotEmpty) await _expand(_roots.first, true);
    } on OpError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loadingRoots = false;
        });
      }
    }
  }

  Future<void> _load(_Node n) async {
    final link = ws.link;
    if (link == null) return;
    setState(() {
      n.loading = true;
      n.error = null;
    });
    try {
      final r = await link.call('fs.list', {'root': n.root, 'path': n.path, 'hidden': _hidden}) as Map;
      final list = [for (final e in r['entries'] as List) (e as Map).cast<String, dynamic>()];
      list.sort((a, b) {
        final da = a['type'] == 'dir' || a['target'] == 'dir', db = b['type'] == 'dir' || b['target'] == 'dir';
        if (da != db) return da ? -1 : 1;
        return (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
      });
      final shown = _hidden ? list : list.where((e) => !(e['name'] as String).startsWith('.')).toList();
      // A reload builds new nodes, but a folder the user had open stays open,
      // with what it already showed until it is loaded again: otherwise a
      // refresh would collapse the tree, and the walk in _refreshAll would stop
      // at the first collapsed folder and never reload the ones below it.
      final old = {for (final c in n.children ?? const <_Node>[]) c.name: c};
      n.children = [
        for (final e in shown)
          () {
            final node = _Node(n.root, n.child(e['name'] as String), e['name'] as String, e);
            final was = old[node.name];
            if (was != null && was.isDir && node.isDir) {
              node.expanded = was.expanded;
              node.children = was.children;
            }
            return node;
          }()
      ];
      if (_selected != null) {
        // keep the selection on the node that now stands for the same path
        for (final c in n.children!) {
          if (c.root == _selected!.root && c.path == _selected!.path) _selected = c;
        }
      }
    } on OpError catch (e) {
      n.error = e.message;
    } finally {
      if (mounted) setState(() => n.loading = false);
    }
  }

  Future<void> _expand(_Node n, bool on) async {
    setState(() => n.expanded = on);
    if (on && n.children == null) await _load(n);
  }

  Future<void> _refreshAll() async {
    Future<void> walk(_Node n) async {
      if (!n.expanded) return;
      await _load(n);
      for (final c in n.children ?? const <_Node>[]) {
        await walk(c);
      }
    }

    for (final r in _roots) {
      await walk(r);
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

  Future<void> _rename(_Node n) async {
    final to = await askText(context, title: '重命名', initial: n.name);
    if (to == null || to.isEmpty || to == n.name) return;
    final parent = n.path.substring(0, n.path.lastIndexOf('/'));
    final dest = parent.isEmpty ? '/$to' : '$parent/$to';
    await ws.guard(() => ws.link!.call('fs.rename', {'root': n.root, 'path': n.path, 'to': dest}));
    ws.dropTabs((t) => t.id == 'file:${n.root}:${n.path}');
    await _reload(n);
  }

  Future<void> _delete(_Node n) async {
    final dir = n.entry?['type'] == 'dir';
    final ok = await confirmDialog(context,
        title: '删除 ${n.name}？', body: dir ? '文件夹和里面的所有内容都会被删除，不能恢复。' : '删除后不能恢复。', ok: '删除', danger: true);
    if (!ok) return;
    await ws.guard(() => ws.link!.call('fs.delete', {'root': n.root, 'path': n.path, 'recursive': dir}));
    ws.dropTabs((t) => t.id == 'file:${n.root}:${n.path}' || t.id.startsWith('file:${n.root}:${n.path}/'));
    if (identical(_selected, n)) _selected = null;
    await _reload(n);
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
    return showDialog<String>(
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

  Future<void> _download(_Node n) async {
    final link = ws.link;
    if (link == null) return;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '下载 ${n.name} 到…');
    if (dir == null) return;
    var where = '$dir${Platform.pathSeparator}${n.name}';
    for (var i = 1; await File(where).exists(); i++) {
      final dot = n.name.lastIndexOf('.');
      where = dot > 0 ? '$dir${Platform.pathSeparator}${n.name.substring(0, dot)} ($i)${n.name.substring(dot)}' : '$dir${Platform.pathSeparator}${n.name} ($i)';
    }
    widget.transfers.download(link, n.root, n.path, where, (n.entry?['size'] as num?)?.toInt() ?? 0, onDone: () => Toast.show('已下载 ${n.name}'));
  }

  void _open(_Node n) {
    setState(() => _selected = n);
    if (n.isDir) {
      _expand(n, !n.expanded);
    } else {
      ws.openTab(fileEditorTab(ws, root: n.root, path: n.path));
    }
  }

  List<MenuItem> _menu(_Node n) {
    final dir = n.isDir;
    final isRoot = n.entry == null;
    return [
      if (dir) MenuItem('新建文件…', () => _newFile(n), icon: Icons.note_add_outlined),
      if (dir) MenuItem('新建文件夹…', () => _mkdir(n), icon: Icons.create_new_folder_outlined),
      if (dir) MenuItem('上传到这里…', () => _upload(n), icon: Icons.upload_file),
      if (!dir) MenuItem('打开', () => _open(n), icon: Icons.edit_note),
      if (!dir) MenuItem('下载…', () => _download(n), icon: Icons.download),
      const MenuItem.separator(),
      MenuItem('复制路径', () => copyText(n.path, what: '已复制路径'), icon: Icons.copy),
      if (dir) MenuItem('刷新', () => _load(n), icon: Icons.refresh),
      if (!isRoot) ...[
        const MenuItem.separator(),
        MenuItem('重命名…', () => _rename(n), icon: Icons.drive_file_rename_outline),
        MenuItem('删除…', () => _delete(n), icon: Icons.delete_outline, danger: true),
      ],
    ];
  }

  // ---- build ----

  Iterable<Widget> _rows(_Node n, int depth) sync* {
    final ide = Ide.of(context);
    yield TreeRow(
      depth: depth,
      selected: identical(_selected, n),
      leading: n.loading
          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
          : n.isDir
              ? Icon(n.expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: ide.textDim)
              : const SizedBox.shrink(), // keeps a file's name under its folder's name
      label: n.name,
      labelColor: n.entry?['type'] == 'link' ? ide.accent : null,
      detail: n.isDir || n.entry == null ? null : formatSize((n.entry!['size'] as num?) ?? 0),
      onTap: () => _open(n),
      menu: () {
        setState(() => _selected = n);
        return _menu(n);
      },
    );
    if (n.expanded) {
      if (n.error != null) {
        yield Padding(padding: EdgeInsets.only(left: 28.0 + depth * 14, top: 2, bottom: 4, right: 8), child: Text(n.error!, style: TextStyle(color: ide.error, fontSize: 12)));
      }
      for (final c in n.children ?? const <_Node>[]) {
        yield* _rows(c, depth + 1);
      }
      if (n.children != null && n.children!.isEmpty && n.error == null) {
        yield Padding(padding: EdgeInsets.only(left: 28.0 + depth * 14, top: 2, bottom: 4), child: Text('（空）', style: TextStyle(color: ide.textDim, fontSize: 12)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _loadRoots);
    if (_loadingRoots) return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    final target = _target;
    return Column(children: [
      Container(
        height: 30,
        color: ide.sideBar,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(children: [
          IconBtn(Icons.note_add_outlined, '新建文件', target == null ? null : () => _newFile(target)),
          IconBtn(Icons.create_new_folder_outlined, '新建文件夹', target == null ? null : () => _mkdir(target)),
          IconBtn(Icons.upload_file, '上传', target == null ? null : () => _upload(target)),
          IconBtn(_hidden ? Icons.visibility : Icons.visibility_off_outlined, _hidden ? '隐藏以 . 开头的文件' : '显示隐藏文件', () {
            setState(() => _hidden = !_hidden);
            _refreshAll();
          }, color: _hidden ? ide.accent : null),
          const Spacer(),
          IconBtn(Icons.refresh, '刷新', _refreshAll),
        ]),
      ),
      const Divider(),
      Expanded(
        child: ListView(children: [for (final r in _roots) ..._rows(r, 0)]),
      ),
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
