// One fs.watch stream per workspace, shared by everything that wants to know
// when a file on the server changes (open editors). Watchers register a file;
// the stream watches its parent folder (the agent watches folders, not files)
// and calls the watcher when the folder reports the file's name, or reports
// itself gone. A new link starts a new stream; an agent without fs.watch, or
// one that refuses it, simply never calls anybody.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';

typedef FileChanged = void Function();

class _Key {
  final String root, dir, name;
  const _Key(this.root, this.dir, this.name);
  @override
  bool operator ==(Object other) => other is _Key && other.root == root && other.dir == dir && other.name == name;
  @override
  int get hashCode => Object.hash(root, dir, name);
}

class FileWatch {
  final Link? Function() link;
  FileWatch(this.link);

  final Map<_Key, Set<FileChanged>> _watchers = {};
  OpStream? _stream;
  Link? _streamLink;
  bool _opening = false;
  bool _disposed = false;
  Timer? _resend;

  static (String, String) _split(String path) {
    final i = path.lastIndexOf('/');
    return (i <= 0 ? '/' : path.substring(0, i), path.substring(i + 1));
  }

  /// Calls [onChange] when [root]:[path] may have changed. Returns a function
  /// that stops it.
  void Function() watch(String root, String path, FileChanged onChange) {
    final (dir, name) = _split(path);
    final k = _Key(root, dir, name);
    final fresh = !_watchers.containsKey(k);
    (_watchers[k] ??= {}).add(onChange);
    if (fresh) _changed();
    return () {
      final set = _watchers[k];
      if (set == null) return;
      set.remove(onChange);
      if (set.isEmpty) {
        _watchers.remove(k);
        if (_watchers.isEmpty) {
          // nothing left to watch: close now, no batching needed
          _resend?.cancel();
          _drop();
        } else {
          _changed();
        }
      }
    };
  }

  /// The link changed (reconnect): the old stream is dead, start again.
  void relink() {
    if (identical(link(), _streamLink)) return;
    _drop();
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    // several editors open at once: one "set" for all of them
    _resend?.cancel();
    _resend = Timer(const Duration(milliseconds: 50), _sync);
  }

  Future<void> _sync() async {
    if (_disposed) return;
    if (_watchers.isEmpty) return _drop();
    final l = link();
    if (l == null) return _drop();
    if (_stream == null || !identical(_streamLink, l)) {
      if (_opening) return;
      _drop();
      _opening = true;
      try {
        final s = await l.open('fs.watch');
        await s.response();
        if (_disposed) {
          s.reset();
          return;
        }
        _stream = s;
        _streamLink = l;
        unawaited(_read(s));
      } on Object {
        return; // an agent without the operation, no inotify, or no link: no notices
      } finally {
        _opening = false;
      }
    }
    final dirs = {for (final k in _watchers.keys) '${k.root}\u0000${k.dir}'};
    try {
      await _stream?.sendJson({
        'type': 'set',
        'items': [for (final d in dirs) {'root': d.split('\u0000')[0], 'path': d.split('\u0000')[1]}],
      });
    } on Object {
      _drop();
    }
  }

  Future<void> _read(OpStream s) async {
    try {
      while (true) {
        final f = await s.read();
        if (f == null) break;
        if (!f.isJson) continue;
        final m = (f.json() as Map).cast<String, dynamic>();
        _event(m);
      }
    } on Object {
      // the link went away; relink() starts a new stream
    }
    if (identical(_stream, s)) {
      _stream = null;
      _streamLink = null;
    }
  }

  void _event(Map<String, dynamic> m) {
    final type = m['type'];
    final calls = <FileChanged>[];
    if (type == 'overflow') {
      for (final s in _watchers.values) {
        calls.addAll(s);
      }
    } else if (type == 'change') {
      final root = m['root'] as String?, dir = m['path'] as String?;
      final names = {for (final n in (m['names'] as List? ?? const [])) '$n'};
      for (final e in _watchers.entries) {
        if (e.key.root != root || e.key.dir != dir) continue;
        if (m['self'] == true || names.contains(e.key.name)) calls.addAll(e.value);
      }
    }
    for (final c in calls) {
      c();
    }
  }

  /// Test hook: feeds one event as if the agent sent it.
  void debugEvent(Map<String, dynamic> m) => _event(m);

  void _drop() {
    _stream?.reset();
    _stream = null;
    _streamLink = null;
  }

  void dispose() {
    _disposed = true;
    _resend?.cancel();
    _drop();
    _watchers.clear();
  }
}
