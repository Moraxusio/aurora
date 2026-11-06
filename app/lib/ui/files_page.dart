// Files tab: browse the agent's roots, upload, download, new folder, rename,
// delete (agent/internal/files). Transfers run on the bulk priority so the
// terminal stays responsive (DESIGN 5.3).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class FilesTab extends StatefulWidget {
  final Link link;
  const FilesTab({super.key, required this.link});
  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  List<Map<String, dynamic>> _roots = [];
  String? _root;
  String _path = '/';
  List<Map<String, dynamic>> _entries = [];
  bool _hidden = false;
  bool _loading = false;
  String? _error;
  final List<_Transfer> _transfers = [];

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  Future<void> _loadRoots() async {
    try {
      final r = await widget.link.call('fs.roots') as Map;
      final roots = [for (final x in r['roots'] as List) (x as Map).cast<String, dynamic>()];
      setState(() {
        _roots = roots;
        _root ??= roots.isEmpty ? null : roots.first['id'] as String;
      });
      await _list();
    } on OpError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _list([String? path]) async {
    if (_root == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.link.call('fs.list', {'root': _root, 'path': path ?? _path, 'hidden': _hidden}) as Map;
      final list = [for (final e in r['entries'] as List) (e as Map).cast<String, dynamic>()];
      setState(() {
        _path = r['path'] as String? ?? path ?? _path;
        _entries = _hidden ? list : list.where((e) => !(e['name'] as String).startsWith('.')).toList();
      });
    } on OpError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _join(String name) => _path == '/' ? '/$name' : '$_path/$name';

  String get _parent {
    if (_path == '/' || _path.isEmpty) return '/';
    final i = _path.lastIndexOf('/');
    return i <= 0 ? '/' : _path.substring(0, i);
  }

  bool _isDir(Map<String, dynamic> e) => e['type'] == 'dir' || e['target'] == 'dir';

  Future<void> _open(Map<String, dynamic> e) async {
    if (!_isDir(e)) return;
    if (e['link_root'] != null && e['link_root'] != _root) {
      setState(() => _root = e['link_root'] as String);
      await _list(e['link_path'] as String? ?? '/');
      return;
    }
    await _list(e['type'] == 'link' && e['link_path'] != null ? e['link_path'] as String : _join(e['name'] as String));
  }

  Future<String?> _ask(String title, String initial) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: TextField(controller: c, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定')),
              ],
            ));
  }

  Future<void> _do(Future<Object?> Function() f) async {
    try {
      await f();
    } on OpError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    await _list();
  }

  Future<void> _mkdir() async {
    final n = await _ask('新建文件夹', '');
    if (n == null || n.isEmpty) return;
    await _do(() => widget.link.call('fs.mkdir', {'root': _root, 'path': _join(n)}));
  }

  Future<void> _rename(Map<String, dynamic> e) async {
    final n = await _ask('重命名', e['name'] as String);
    if (n == null || n.isEmpty || n == e['name']) return;
    await _do(() => widget.link.call('fs.rename', {'root': _root, 'path': _join(e['name'] as String), 'to': _join(n)}));
  }

  Future<void> _delete(Map<String, dynamic> e) async {
    final dir = _isDir(e) && e['type'] == 'dir';
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text('删除 ${e['name']}？'),
              content: Text(dir ? '文件夹和里面的所有内容都会被删除，不能恢复。' : '删除后不能恢复。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
              ],
            ));
    if (ok != true) return;
    await _do(() => widget.link.call('fs.delete', {'root': _root, 'path': _join(e['name'] as String), 'recursive': dir}));
  }

  Future<void> _upload() async {
    final res = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件');
    for (final f in res) {
      if (f.path == null) continue;
      final local = File(f.path!);
      final size = await local.length();
      final t = _Transfer('上传 ${f.name}', size);
      setState(() => _transfers.add(t));
      unawaited(_runUpload(t, local, _root!, _join(f.name)));
    }
  }

  Future<void> _runUpload(_Transfer t, File local, String root, String path) async {
    try {
      final s = await widget.link.open('fs.upload', {'root': root, 'path': path, 'size': t.total}, Priority.bulk);
      await s.response();
      await for (final chunk in local.openRead()) {
        for (var off = 0; off < chunk.length; off += 256 * 1024) {
          final end = off + 256 * 1024 < chunk.length ? off + 256 * 1024 : chunk.length;
          await s.sendData(Uint8List.sublistView(chunk is Uint8List ? chunk : Uint8List.fromList(chunk), off, end));
          t.done += end - off;
          if (mounted) setState(() {});
        }
      }
      await s.sendEnd();
      await s.response();
      await s.close();
      t.finish();
    } on Object catch (e) {
      t.finish('$e');
    }
    if (mounted) setState(() {});
    if (_root == root) await _list();
  }

  /// Downloads into a folder the user picks; the file streams to disk, so
  /// its size does not matter. An existing file of that name is not
  /// overwritten.
  Future<void> _download(Map<String, dynamic> e) async {
    final name = e['name'] as String;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '下载 $name 到…');
    if (dir == null) return;
    var where = '$dir${Platform.pathSeparator}$name';
    for (var n = 1; await File(where).exists(); n++) {
      final dot = name.lastIndexOf('.');
      where = dot > 0
          ? '$dir${Platform.pathSeparator}${name.substring(0, dot)} ($n)${name.substring(dot)}'
          : '$dir${Platform.pathSeparator}$name ($n)';
    }
    final t = _Transfer('下载 $name', (e['size'] as num?)?.toInt() ?? 0);
    setState(() => _transfers.add(t));
    unawaited(_runDownload(t, _root!, _join(name), where));
  }

  Future<void> _runDownload(_Transfer t, String root, String path, String where) async {
    final tmp = File('$where.aurora3-part');
    IOSink? out;
    try {
      final s = await widget.link.open('fs.download', {'root': root, 'path': path}, Priority.bulk);
      final meta = await s.response() as Map;
      t.total = (meta['length'] as num).toInt();
      out = tmp.openWrite();
      var ended = false;
      while (true) {
        final f = await s.read();
        if (f == null) break;
        if (f.type == typeData) {
          out.add(f.payload);
          t.done += f.payload.length;
          if (mounted) setState(() {});
        } else if (f.type == typeEnd) {
          ended = true;
          break;
        }
      }
      await out.close();
      out = null;
      if (!ended || t.done != t.total) throw StateError('下载不完整：${t.done} / ${t.total} 字节');
      await tmp.rename(where);
      t.finish();
    } on Object catch (e) {
      await out?.close();
      if (await tmp.exists()) await tmp.delete();
      t.finish('$e');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(children: [
          DropdownButton<String>(
            value: _root,
            items: [for (final r in _roots) DropdownMenuItem(value: r['id'] as String, child: Text(r['label'] as String? ?? r['id'] as String))],
            onChanged: (v) {
              setState(() {
                _root = v;
                _path = '/';
              });
              _list('/');
            },
          ),
          IconButton(onPressed: _path == '/' ? null : () => _list(_parent), icon: const Icon(Icons.arrow_upward), tooltip: '上一级'),
          Expanded(child: SelectableText(_path, maxLines: 1)),
          FilterChip(label: const Text('显示隐藏文件'), selected: _hidden, onSelected: (v) {
            setState(() => _hidden = v);
            _list();
          }),
          IconButton(onPressed: () => _list(), icon: const Icon(Icons.refresh), tooltip: '刷新'),
          IconButton(onPressed: _mkdir, icon: const Icon(Icons.create_new_folder_outlined), tooltip: '新建文件夹'),
          IconButton(onPressed: _upload, icon: const Icon(Icons.upload), tooltip: '上传'),
        ]),
      ),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
      Expanded(
        child: ListView.builder(
          itemCount: _entries.length,
          itemBuilder: (_, i) {
            final e = _entries[i];
            final dir = _isDir(e);
            return ListTile(
              dense: true,
              leading: Icon(dir ? Icons.folder : (e['type'] == 'link' ? Icons.link : Icons.description_outlined)),
              title: Text(e['name'] as String),
              subtitle: Text('${dir ? '' : '${_size(e['size'] as num? ?? 0)}  '}${_time(e['mtime'] as num? ?? 0)}  ${e['mode'] ?? ''}'),
              onTap: dir ? () => _open(e) : null,
              trailing: PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'download' => _download(e),
                  'rename' => _rename(e),
                  'delete' => _delete(e),
                  _ => null,
                },
                itemBuilder: (_) => [
                  if (!dir) const PopupMenuItem(value: 'download', child: Text('下载')),
                  const PopupMenuItem(value: 'rename', child: Text('重命名')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            );
          },
        ),
      ),
      if (_transfers.isNotEmpty)
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Column(children: [
            for (final t in _transfers.reversed.take(4))
              ListTile(
                dense: true,
                title: Text(t.label),
                subtitle: t.error != null
                    ? Text(t.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                    : (t.finished ? Text('完成 · ${_size(t.total)}') : LinearProgressIndicator(value: t.total == 0 ? null : t.done / t.total)),
                trailing: t.finished ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _transfers.remove(t))) : Text(_rate(t)),
              ),
          ]),
        ),
    ]);
  }

  static String _size(num n) {
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = n.toDouble(), i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return i == 0 ? '$n B' : '${v.toStringAsFixed(1)} ${u[i]}';
  }

  static String _time(num ms) {
    if (ms == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    String two(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _rate(_Transfer t) {
    final s = t.sw.elapsedMicroseconds / 1e6;
    return s < 0.2 ? '' : '${_size(t.done / s)}/s';
  }
}

class _Transfer {
  final String label;
  int total;
  int done = 0;
  bool finished = false;
  String? error;
  final Stopwatch sw = Stopwatch()..start();
  _Transfer(this.label, this.total);
  void finish([String? err]) {
    finished = true;
    error = err;
    sw.stop();
  }
}
