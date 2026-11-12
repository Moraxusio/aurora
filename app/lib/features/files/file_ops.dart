// The logic behind the file tree's clipboard, sorting and folder sizes, kept
// free of widgets so it can be tested against a scripted agent.
//
// Copy and cut only remember what was chosen (nothing is read or moved yet);
// paste does the work on the server: fs.copy, or fs.rename inside one root.
// A cut across two roots is a copy followed by a delete, and the delete only
// happens after the copy succeeded. A name that is already taken is never
// overwritten without asking, and "replace" keeps the old item aside until
// the new one is in place, so a failure never loses the old one.
import 'package:aurora_wire/aurora_wire.dart';

typedef RpcCall = Future<Object?> Function(String op, Map<String, Object?> args);

// ------------------------------------------------------------------ paths

String joinPath(String dir, String name) => dir == '/' ? '/$name' : '$dir/$name';

String parentPath(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

String baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

bool isSameOrInside(String path, String ancestor) => path == ancestor || path.startsWith(ancestor == '/' ? '/' : '$ancestor/');

/// "a.txt" -> "a 副本.txt" -> "a 副本 2.txt"; folders and dotfiles keep their whole name as the stem.
String uniqueName(String name, Set<String> taken, {bool isDir = false}) {
  if (!taken.contains(name)) return name;
  final dot = name.lastIndexOf('.');
  final hasExt = !isDir && dot > 0 && dot < name.length - 1;
  final stem = hasExt ? name.substring(0, dot) : name;
  final ext = hasExt ? name.substring(dot) : '';
  var n = 1;
  while (true) {
    final cand = '$stem 副本${n == 1 ? '' : ' $n'}$ext';
    if (!taken.contains(cand)) return cand;
    n++;
  }
}

// -------------------------------------------------------------- clipboard

class ClipItem {
  final String root;
  final String path;
  final bool isDir;
  const ClipItem(this.root, this.path, this.isDir);
  String get name => baseName(path);
}

class FileClipboard {
  final List<ClipItem> items;
  final bool cut;
  const FileClipboard(this.items, {required this.cut});
  bool contains(String root, String path) => items.any((i) => i.root == root && i.path == path);
}

// ------------------------------------------------------------------ paste

enum Conflict { replace, keepBoth, skip }

class ConflictChoice {
  final Conflict action;

  /// Use this answer for the rest of the items without asking again.
  final bool all;
  const ConflictChoice(this.action, {this.all = false});
}

/// Asks what to do about a name that is already in the destination.
/// Return null to stop the whole paste.
typedef ConflictResolver = Future<ConflictChoice?> Function(String name, bool isDir, {required bool more});

class PasteResult {
  int done = 0;
  int skipped = 0;
  bool stopped = false;
  final List<String> errors = [];
  final List<ClipItem> moved = []; // cut items that no longer exist at the old path
  final List<String> createdPaths = [];
}

int _tmpCounter = 0;

Future<PasteResult> pasteItems({
  required RpcCall call,
  required List<ClipItem> items,
  required bool cut,
  required String destRoot,
  required String destDir,
  required Set<String> existing,
  required ConflictResolver resolve,
  void Function(int index, int total, String name)? onProgress,
}) async {
  final res = PasteResult();
  final taken = {...existing};
  ConflictChoice? sticky; // "apply to all"
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    onProgress?.call(i, items.length, it.name);
    final sameRoot = it.root == destRoot;
    final inPlace = sameRoot && parentPath(it.path) == destDir;
    try {
      if (sameRoot && it.isDir && isSameOrInside(destDir, it.path)) {
        res.errors.add('${it.name}：不能${cut ? '移动' : '复制'}到自身或其子文件夹中');
        continue;
      }
      if (inPlace && cut) {
        res.skipped++; // moving to where it already is
        continue;
      }
      var name = it.name;
      var replace = false;
      if (taken.contains(name)) {
        if (inPlace) {
          name = uniqueName(name, taken, isDir: it.isDir); // a copy beside itself
        } else {
          final choice = sticky ?? await resolve(name, it.isDir, more: i < items.length - 1);
          if (choice == null) {
            res.stopped = true;
            break;
          }
          if (choice.all) sticky = choice;
          if (choice.action == Conflict.skip) {
            res.skipped++;
            continue;
          }
          if (choice.action == Conflict.keepBoth) {
            name = uniqueName(name, taken, isDir: it.isDir);
          } else {
            replace = true;
          }
        }
      }
      final dest = joinPath(destDir, name);
      String? aside;
      if (replace) {
        aside = joinPath(destDir, '.aurora-old-${DateTime.now().millisecondsSinceEpoch}-${_tmpCounter++}-$name');
        await call('fs.rename', {'root': destRoot, 'path': dest, 'to': aside});
      }
      try {
        await _transfer(call, it, cut: cut, destRoot: destRoot, dest: dest);
      } on Object {
        if (aside != null) {
          try {
            await call('fs.rename', {'root': destRoot, 'path': aside, 'to': dest}); // put the old one back
          } on Object {
            res.errors.add('${it.name}：旧的同名项被暂存为 $aside，没能自动还原');
          }
        }
        rethrow;
      }
      if (aside != null) {
        try {
          await call('fs.delete', {'root': destRoot, 'path': aside, 'recursive': true});
        } on Object catch (e) {
          res.errors.add('${it.name}：已替换，但没能删除暂存的旧项 $aside（${_msg(e)}）');
        }
      }
      taken.add(name);
      res.done++;
      res.createdPaths.add(dest);
      if (cut) res.moved.add(it);
    } on Object catch (e) {
      res.errors.add('${it.name}：${_msg(e)}');
    }
  }
  return res;
}

String _msg(Object e) => e is OpError ? e.message : '$e';

Future<void> _transfer(RpcCall call, ClipItem it, {required bool cut, required String destRoot, required String dest}) async {
  if (cut && it.root == destRoot) {
    await call('fs.rename', {'root': it.root, 'path': it.path, 'to': dest});
    return;
  }
  await call('fs.copy', {
    'root': it.root,
    'path': it.path,
    'to': dest,
    if (it.root != destRoot) 'to_root': destRoot,
  });
  if (cut) {
    // The copy is complete: only now is the original removed.
    await call('fs.delete', {'root': it.root, 'path': it.path, 'recursive': it.isDir});
  }
}

// ---------------------------------------------------------------- sorting

class SortItem {
  final String name;
  final bool dir;
  final int? size; // null: a folder whose size was not measured
  final int mtime;
  const SortItem(this.name, this.dir, this.size, this.mtime);
  String get ext {
    if (dir) return '';
    final i = name.lastIndexOf('.');
    return i <= 0 ? '' : name.substring(i + 1).toLowerCase();
  }
}

/// Compares digit runs by value: file2 < file10.
int naturalCompare(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var i = 0, j = 0;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    final dx = cx >= 48 && cx <= 57, dy = cy >= 48 && cy <= 57;
    if (dx && dy) {
      var ei = i, ej = j;
      while (ei < x.length && x.codeUnitAt(ei) >= 48 && x.codeUnitAt(ei) <= 57) {
        ei++;
      }
      while (ej < y.length && y.codeUnitAt(ej) >= 48 && y.codeUnitAt(ej) <= 57) {
        ej++;
      }
      final nx = x.substring(i, ei).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final ny = y.substring(j, ej).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      i = ei;
      j = ej;
    } else {
      if (cx != cy) return cx - cy;
      i++;
      j++;
    }
  }
  return (x.length - i) - (y.length - j);
}

int compareSort(SortItem a, SortItem b, {required String sort, required bool desc, required bool foldersFirst}) {
  if (foldersFirst && a.dir != b.dir) return a.dir ? -1 : 1;
  int byName() {
    final c = naturalCompare(a.name, b.name);
    return c != 0 ? c : a.name.compareTo(b.name);
  }

  int c;
  switch (sort) {
    case 'size':
      // An unmeasured folder goes last in either direction: it is unknown, not small.
      if (a.size == null || b.size == null) {
        if (a.size == null && b.size == null) return byName();
        return a.size == null ? 1 : -1;
      }
      c = a.size!.compareTo(b.size!);
    case 'mtime':
      c = a.mtime.compareTo(b.mtime);
    case 'type':
      c = a.ext.compareTo(b.ext);
    default:
      return desc ? -byName() : byName();
  }
  if (c != 0) return desc ? -c : c;
  return byName();
}

// ------------------------------------------------------------ folder size

class DuInfo {
  final int bytes; // sum of file sizes
  final int disk; // blocks actually used
  final int files;
  final int dirs;
  final bool partial; // the walk stopped early: the real size is at least this
  final DateTime at;
  const DuInfo({required this.bytes, required this.disk, required this.files, required this.dirs, required this.partial, required this.at});
}

class DuResult {
  final DuInfo total;
  final Map<String, DuInfo> children; // only the ones fully counted
  final List<String> skipped;
  final int errors;
  const DuResult(this.total, this.children, this.skipped, this.errors);
}

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

DuResult parseDu(Map<String, dynamic> r, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final partial = r['partial'] == true;
  final total = DuInfo(bytes: _int(r['bytes']), disk: _int(r['disk']), files: _int(r['files']), dirs: _int(r['dirs']), partial: partial, at: at);
  final kids = <String, DuInfo>{};
  final raw = r['children'];
  if (raw is Map) {
    raw.forEach((k, v) {
      if (v is! Map) return;
      // a child the walk stopped inside is not a total
      if (v['done'] != true) return;
      kids[k as String] = DuInfo(bytes: _int(v['bytes']), disk: _int(v['disk']), files: _int(v['files']), dirs: 0, partial: false, at: at);
    });
  }
  return DuResult(total, kids, [for (final s in (r['skipped'] as List? ?? const [])) '$s'], _int(r['errors']));
}

// ---------------------------------------------------------------- display

String formatShortTime(int ms, {DateTime? now}) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  String two(int x) => x.toString().padLeft(2, '0');
  if (d.year == n.year) return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
