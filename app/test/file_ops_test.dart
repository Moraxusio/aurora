import 'package:aurora/features/files/file_ops.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tiny in-memory agent: paths per root, with the same refusals the real
/// one has (taken names, missing sources), and a log of every call.
class FakeFs {
  final Map<String, Set<String>> tree; // root -> every path (files and folders)
  final calls = <String>[];
  final Set<String> failOn = {};
  FakeFs(this.tree);

  Future<Object?> call(String op, Map<String, Object?> a) async {
    final root = a['root'] as String, path = a['path'] as String;
    calls.add('$op $root:$path${a['to'] == null ? '' : ' -> ${a['to_root'] ?? root}:${a['to']}'}');
    if (failOn.contains(op)) throw OpError(codeUnavailable, '$op 失败');
    final src = tree[root]!;
    if (!src.contains(path)) throw OpError(codeNotFound, '文件或目录不存在');
    switch (op) {
      case 'fs.rename' || 'fs.copy':
        final dstRoot = tree[(a['to_root'] as String?) ?? root]!;
        final to = a['to'] as String;
        if (dstRoot.contains(to)) throw OpError(codeConflict, '目标位置已存在同名文件或目录');
        final moved = src.where((p) => p == path || p.startsWith('$path/')).toList();
        for (final p in moved) {
          dstRoot.add(to + p.substring(path.length));
          if (op == 'fs.rename') src.remove(p);
        }
      case 'fs.delete':
        src.removeWhere((p) => p == path || p.startsWith('$path/'));
    }
    return {};
  }
}

void main() {
  group('uniqueName', () {
    test('keeps a free name and numbers the rest', () {
      expect(uniqueName('a.txt', {}), 'a.txt');
      expect(uniqueName('a.txt', {'a.txt'}), 'a 副本.txt');
      expect(uniqueName('a.txt', {'a.txt', 'a 副本.txt'}), 'a 副本 2.txt');
      expect(uniqueName('src', {'src'}, isDir: true), 'src 副本');
      expect(uniqueName('v1.2', {'v1.2'}, isDir: true), 'v1.2 副本', reason: 'a folder has no extension');
      expect(uniqueName('.env', {'.env'}), '.env 副本', reason: 'a dotfile is all stem');
      expect(uniqueName('archive.tar.gz', {'archive.tar.gz'}), 'archive.tar 副本.gz');
    });
  });

  group('paths', () {
    test('join, parent, base, inside', () {
      expect(joinPath('/', 'a'), '/a');
      expect(joinPath('/x', 'a'), '/x/a');
      expect(parentPath('/x/a'), '/x');
      expect(parentPath('/a'), '/');
      expect(baseName('/x/a.txt'), 'a.txt');
      expect(isSameOrInside('/x/y', '/x'), isTrue);
      expect(isSameOrInside('/x', '/x'), isTrue);
      expect(isSameOrInside('/xy', '/x'), isFalse);
      expect(isSameOrInside('/anything', '/'), isTrue);
    });
  });

  group('paste', () {
    Future<ConflictChoice?> never(String n, bool d, {required bool more}) async => fail('unexpected conflict on $n');

    test('copy keeps the source; cut inside one root is a rename', () async {
      final fs = FakeFs({'home': {'/a', '/a/f.txt', '/dst'}});
      var r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/a', true)], cut: false, destRoot: 'home', destDir: '/dst', existing: {}, resolve: never);
      expect(r.done, 1);
      expect(fs.tree['home'], containsAll(['/a', '/a/f.txt', '/dst/a', '/dst/a/f.txt']));
      expect(fs.calls.single, 'fs.copy home:/a -> home:/dst/a');

      fs.calls.clear();
      r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/dst/a', true)], cut: true, destRoot: 'home', destDir: '/', existing: {'a', 'dst'}, resolve: (n, d, {required more}) async => const ConflictChoice(Conflict.keepBoth));
      expect(r.done, 1);
      expect(fs.calls.single, 'fs.rename home:/dst/a -> home:/a 副本');
      expect(r.moved.single.path, '/dst/a');
      expect(fs.tree['home']!.contains('/dst/a'), isFalse);
    });

    test('cut across roots copies first and deletes the original only afterwards', () async {
      final fs = FakeFs({'home': {'/f.txt'}, 'data': {}});
      final r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/f.txt', false)], cut: true, destRoot: 'data', destDir: '/', existing: {}, resolve: never);
      expect(r.done, 1);
      expect(fs.calls, ['fs.copy home:/f.txt -> data:/f.txt', 'fs.delete home:/f.txt']);
      expect(fs.tree['home'], isEmpty);
      expect(fs.tree['data'], contains('/f.txt'));
    });

    test('a failed copy leaves the original in place even for a cut', () async {
      final fs = FakeFs({'home': {'/f.txt'}, 'data': {}})..failOn.add('fs.copy');
      final r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/f.txt', false)], cut: true, destRoot: 'data', destDir: '/', existing: {}, resolve: never);
      expect(r.done, 0);
      expect(r.errors.single, contains('fs.copy 失败'));
      expect(fs.tree['home'], contains('/f.txt'));
      expect(fs.calls.where((c) => c.startsWith('fs.delete')), isEmpty);
      expect(r.moved, isEmpty);
    });

    test('copy beside itself makes a numbered copy without asking', () async {
      final fs = FakeFs({'home': {'/d', '/d/a.txt'}});
      final r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/d/a.txt', false)], cut: false, destRoot: 'home', destDir: '/d', existing: {'a.txt'}, resolve: never);
      expect(r.done, 1);
      expect(fs.tree['home'], contains('/d/a 副本.txt'));
    });

    test('cut into the folder it is already in does nothing', () async {
      final fs = FakeFs({'home': {'/d', '/d/a.txt'}});
      final r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/d/a.txt', false)], cut: true, destRoot: 'home', destDir: '/d', existing: {'a.txt'}, resolve: never);
      expect(r.done, 0);
      expect(r.skipped, 1);
      expect(fs.calls, isEmpty);
    });

    test('a folder cannot go into itself', () async {
      final fs = FakeFs({'home': {'/a', '/a/b'}});
      final r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/a', true)], cut: true, destRoot: 'home', destDir: '/a/b', existing: {}, resolve: never);
      expect(r.done, 0);
      expect(r.errors.single, contains('不能移动到自身'));
      expect(fs.calls, isEmpty);
    });

    test('conflict: skip, keep both, replace; replace parks the old item and restores it on failure', () async {
      final fs = FakeFs({'home': {'/s/x.txt', '/s/y.txt', '/s/z.txt', '/t', '/t/x.txt', '/t/y.txt', '/t/z.txt'}});
      final asked = <String>[];
      final answers = [const ConflictChoice(Conflict.skip), const ConflictChoice(Conflict.keepBoth), const ConflictChoice(Conflict.replace)];
      final r = await pasteItems(
        call: fs.call,
        items: const [ClipItem('home', '/s/x.txt', false), ClipItem('home', '/s/y.txt', false), ClipItem('home', '/s/z.txt', false)],
        cut: false,
        destRoot: 'home',
        destDir: '/t',
        existing: {'x.txt', 'y.txt', 'z.txt'},
        resolve: (n, d, {required more}) async {
          asked.add(n);
          return answers.removeAt(0);
        },
      );
      expect(asked, ['x.txt', 'y.txt', 'z.txt']);
      expect(r.skipped, 1);
      expect(r.done, 2);
      expect(fs.tree['home'], containsAll(['/t/y 副本.txt', '/t/z.txt']));
      // replace: renamed aside, copied, aside deleted
      final replaceCalls = fs.calls.where((c) => c.contains('z.txt')).toList();
      expect(replaceCalls[0], startsWith('fs.rename home:/t/z.txt -> home:/t/.aurora-old-'));
      expect(replaceCalls[1], 'fs.copy home:/s/z.txt -> home:/t/z.txt');
      expect(replaceCalls[2], startsWith('fs.delete home:/t/.aurora-old-'));

      // now the same replace, but the copy fails: the old item must come back
      final fs2 = FakeFs({'home': {'/s/z.txt', '/t', '/t/z.txt'}})..failOn.add('fs.copy');
      final r2 = await pasteItems(call: fs2.call, items: const [ClipItem('home', '/s/z.txt', false)], cut: false, destRoot: 'home', destDir: '/t', existing: {'z.txt'}, resolve: (n, d, {required more}) async => const ConflictChoice(Conflict.replace));
      expect(r2.done, 0);
      expect(fs2.tree['home'], contains('/t/z.txt'), reason: 'the old file must be back');
      expect(fs2.tree['home']!.where((p) => p.contains('.aurora-old-')), isEmpty);
    });

    test('"apply to all" asks once and covers the remaining conflicts', () async {
      final fs = FakeFs({'home': {'/s/a', '/s/b', '/s/c', '/t', '/t/a', '/t/b', '/t/c'}});
      var asked = 0;
      final r = await pasteItems(
        call: fs.call,
        items: const [ClipItem('home', '/s/a', false), ClipItem('home', '/s/b', false), ClipItem('home', '/s/c', false)],
        cut: false,
        destRoot: 'home',
        destDir: '/t',
        existing: {'a', 'b', 'c'},
        resolve: (n, d, {required more}) async {
          asked++;
          return const ConflictChoice(Conflict.skip, all: true);
        },
      );
      expect(asked, 1);
      expect(r.skipped, 3);
      expect(fs.calls, isEmpty);
    });

    test('cancelling the question stops the rest', () async {
      final fs = FakeFs({'home': {'/s/a', '/s/b', '/t', '/t/a'}});
      final r = await pasteItems(call: fs.call, items: const [ClipItem('home', '/s/a', false), ClipItem('home', '/s/b', false)], cut: false, destRoot: 'home', destDir: '/t', existing: {'a'}, resolve: (n, d, {required more}) async => null);
      expect(r.stopped, isTrue);
      expect(r.done, 0);
      expect(fs.calls, isEmpty, reason: 'b must not be pasted after the user stopped at a');
    });
  });

  group('sorting', () {
    List<String> sorted(List<SortItem> l, String sort, {bool desc = false, bool folders = true}) =>
        (l.toList()..sort((a, b) => compareSort(a, b, sort: sort, desc: desc, foldersFirst: folders))).map((e) => e.name).toList();

    final items = [
      const SortItem('file10.txt', false, 5, 300),
      const SortItem('file2.txt', false, 5000, 100),
      const SortItem('Zoo', true, null, 50),
      const SortItem('app', true, 9000, 200),
      const SortItem('b.go', false, 70, 200),
      const SortItem('a.dart', false, 70, 400),
    ];

    test('name is natural and case-insensitive, folders first', () {
      expect(sorted(items, 'name'), ['app', 'Zoo', 'a.dart', 'b.go', 'file2.txt', 'file10.txt']);
      expect(sorted(items, 'name', desc: true), ['Zoo', 'app', 'file10.txt', 'file2.txt', 'b.go', 'a.dart']);
      expect(sorted(items, 'name', folders: false).first, 'a.dart');
    });

    test('size: ascending, descending, unmeasured folders always last, ties by name', () {
      expect(sorted(items, 'size'), ['app', 'Zoo', 'file10.txt', 'a.dart', 'b.go', 'file2.txt']);
      expect(sorted(items, 'size', desc: true), ['app', 'Zoo', 'file2.txt', 'a.dart', 'b.go', 'file10.txt'], reason: 'the folder of unknown size stays last, not first; equal sizes keep name order');
      expect(sorted(items, 'size', folders: false), ['file10.txt', 'a.dart', 'b.go', 'file2.txt', 'app', 'Zoo']);
    });

    test('mtime and type', () {
      expect(sorted(items, 'mtime'), ['Zoo', 'app', 'file2.txt', 'b.go', 'file10.txt', 'a.dart']);
      expect(sorted(items, 'mtime', desc: true), ['app', 'Zoo', 'a.dart', 'file10.txt', 'b.go', 'file2.txt']);
      // by extension (dart < go < txt), equal extensions by natural name
      expect(sorted(items, 'type'), ['app', 'Zoo', 'a.dart', 'b.go', 'file2.txt', 'file10.txt']);
    });

    test('naturalCompare', () {
      expect(naturalCompare('a2', 'a10') < 0, isTrue);
      expect(naturalCompare('a02', 'a2'), 0);
      expect(naturalCompare('B', 'a') > 0, isTrue);
      expect(naturalCompare('', 'a') < 0, isTrue);
    });
  });

  group('du', () {
    test('parses totals and keeps only finished children', () {
      final r = parseDu({
        'bytes': 1750,
        'disk': 8192,
        'files': 3,
        'dirs': 2,
        'partial': false,
        'skipped': ['/mnt'],
        'errors': 1,
        'children': {
          'sub': {'bytes': 750, 'disk': 4096, 'files': 2, 'done': true},
          'cut': {'bytes': 5, 'disk': 4096, 'files': 1, 'done': false},
        },
      });
      expect(r.total.bytes, 1750);
      expect(r.total.partial, isFalse);
      expect(r.children.keys, ['sub'], reason: 'a child the walk stopped inside is not a total');
      expect(r.children['sub']!.files, 2);
      expect(r.skipped, ['/mnt']);
      expect(r.errors, 1);
      expect(parseDu({'bytes': 1, 'partial': true}).total.partial, isTrue);
    });
  });

  test('formatShortTime', () {
    final now = DateTime(2026, 11, 13, 12);
    expect(formatShortTime(DateTime(2026, 3, 4, 5, 6).millisecondsSinceEpoch, now: now), '03-04 05:06');
    expect(formatShortTime(DateTime(2024, 3, 4, 5, 6).millisecondsSinceEpoch, now: now), '2024-03-04');
    expect(formatShortTime(0, now: now), '');
  });
}
