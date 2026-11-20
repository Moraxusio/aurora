import 'package:aurora/features/files/file_tree_row.dart';
import 'package:aurora/features/files/files_feature.dart';
import 'package:aurora/features/files/transfers.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/ui/aurora_ui.dart' show FloatingSurface;
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

Map<String, Object?> dirE(String n, {int mtime = 0}) => {'name': n, 'type': 'dir', 'mtime': mtime, 'mode': 'drwxr-xr-x'};
Map<String, Object?> fileE(String n, int size, {int mtime = 0}) => {'name': n, 'type': 'file', 'size': size, 'mtime': mtime, 'mode': '-rw-r--r--', 'owner': 'root', 'group': 'root'};

/// An in-memory agent for the file operations: it moves entries between the
/// folder listings, refuses taken names like the real one, and totals folders.
class OpsLink extends FileTreeLink {
  final log = <String>[];
  bool transactionalPaste = false;
  String? receipt;
  String pin = 'fixture-pin';
  bool mismatchedReceipt = false;

  @override
  AgentInfo get server => transactionalPaste
      ? AgentInfo({
          ...super.server.raw, 'id': 'fixture-agent',
          'direct': {'cert_sha256': pin},
          'caps': [...super.server.caps, 'fs.paste.replace', 'fs.paste.status'],
        })
      : super.server;

  OpsLink() {
    directories['/project'] = [dirE('src', mtime: 5), fileE('README.md', 42, mtime: 300), fileE('big.bin', 5 * 1024 * 1024, mtime: 100), fileE('a.txt', 12, mtime: 200)];
    directories['/project/src'] = [fileE('main.dart', 3 * 1024 * 1024, mtime: 400)];
  }

  String _parent(String p) => p.substring(0, p.lastIndexOf('/')).isEmpty ? '/' : p.substring(0, p.lastIndexOf('/'));
  String _base(String p) => p.substring(p.lastIndexOf('/') + 1);
  Map<String, Object?>? _find(String p) => directories[_parent(p)]?.where((e) => e['name'] == _base(p)).firstOrNull;

  void _put(String to, Map<String, Object?> e) {
    final name = _base(to);
    final copy = {...e, 'name': name};
    (directories[_parent(to)] ??= []).add(copy);
  }

  void _moveDir(String from, String to, {required bool keep}) {
    final keys = directories.keys.where((k) => k == from || k.startsWith('$from/')).toList();
    for (final k in keys) {
      final nk = to + k.substring(from.length);
      directories[nk] = [for (final e in directories[k]!) {...e}];
      if (!keep) directories.remove(k);
    }
  }

  (int, int) _sum(String dir) {
    var bytes = 0, files = 0;
    for (final e in directories[dir] ?? const <Map<String, Object?>>[]) {
      if (e['type'] == 'dir') {
        final (b, f) = _sum(dir == '/' ? '/${e['name']}' : '$dir/${e['name']}');
        bytes += b;
        files += f;
      } else {
        bytes += e['size'] as int;
        files++;
      }
    }
    return (bytes, files);
  }

  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    final a = args is Map ? args : const {};
    final path = a['path'] as String?;
    switch (op) {
      case 'fs.paste.replace':
        expect(a['if_match'], 'source-version');
        expect(a['to_if_match'], 'target-version');
        log.add(op);
        receipt = a['id'] as String;
        throw OpError(codeUnavailable, 'lost success response');
      case 'fs.paste.status':
        log.add(op);
        if (a['id'] != receipt) throw OpError(codeNotFound, 'receipt unavailable');
        return {
          'committed': true,
          'request': {
            'id': receipt,
            'to_root': 'home',
            'to': mismatchedReceipt ? '/other/README.md' : '/project/src/README.md',
          },
        };
      case 'fs.rename' || 'fs.copy':
        final to = a['to'] as String;
        log.add('$op $path -> $to');
        final e = _find(path!);
        if (e == null) throw OpError(codeNotFound, '文件或目录不存在');
        if (_find(to) != null) throw OpError(codeConflict, '目标位置已存在同名文件或目录');
        _put(to, e);
        if (e['type'] == 'dir') _moveDir(path, to, keep: op == 'fs.copy');
        if (op == 'fs.rename') directories[_parent(path)]!.remove(e);
        return {'path': to};
      case 'fs.delete':
        log.add('fs.delete $path');
        final e = _find(path!);
        if (e == null) throw OpError(codeNotFound, '文件或目录不存在');
        directories[_parent(path)]!.remove(e);
        directories.removeWhere((k, _) => k == path || k.startsWith('$path/'));
        return {'deleted': path};
      case 'fs.du':
        log.add('fs.du $path');
        final (b, f) = _sum(path!);
        final kids = <String, Object?>{};
        for (final e in directories[path] ?? const <Map<String, Object?>>[]) {
          final p = path == '/' ? '/${e['name']}' : '$path/${e['name']}';
          final (cb, cf) = e['type'] == 'dir' ? _sum(p) : (e['size'] as int, 1);
          kids[e['name'] as String] = {'bytes': cb, 'disk': cb + 4096, 'files': cf, 'done': true};
        }
        return {'path': path, 'bytes': b, 'disk': b + 8192, 'files': f, 'dirs': 1, 'partial': false, 'children': kids};
    }
    return super.call(op, args, timeout);
  }
}

class _SwitchingApp extends WorkspaceApp {
  _SwitchingApp(this.active);
  Link active;
  @override
  Link link(String id) => active;
}

void main() {
  late _SwitchingApp app;
  late Workspace ws;
  late OpsLink link;
  late Transfers transfers;
  late InputMode input;
  setUp(() {
    link = OpsLink();
    app = _SwitchingApp(link);
    app.data.servers.single.selectedWorkspace = 'a';
    ws = Workspace(app, 'server');
    transfers = Transfers();
    input = InputMode(touch: false);
  });
  tearDown(() async {
    ws.dispose();
    transfers.dispose();
    input.dispose();
    app.dispose();
  });

  Future<void> pumps(WidgetTester t, [int n = 20]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> mount(WidgetTester t, {double width = 340, double scale = 1, bool dynamicInput = false}) async {
    t.view.physicalSize = const Size(900, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Listener(
        onPointerDown: dynamicInput ? input.onPointer : null,
        child: InputMode.scope(mode: input, child: Scaffold(body: SizedBox(width: width, height: 800, child: FileTree(ws: ws, transfers: transfers)))),
      ),
    ));
    await pumps(t);
  }

  Future<void> finish(WidgetTester t) async {
    expect(t.takeException(), isNull);
    await t.runAsync(() => ws.flushViews()); // folder clicks queue a debounced view save
    await t.pumpWidget(const SizedBox());
  }

  Finder row(String path) => find.byWidgetPredicate((w) => w is FileTreeRow && w.path == path);
  FileTreeRow rowWidget(WidgetTester t, String path) => t.widget<FileTreeRow>(row(path));

  Future<void> ctrlTap(WidgetTester t, String path) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.tap(row(path));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumps(t, 4);
  }

  Future<void> chord(WidgetTester t, LogicalKeyboardKey key) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(key);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumps(t);
  }

  Future<void> menuOn(WidgetTester t, String path, String item, {bool more = false}) async {
    await t.tap(row(path), buttons: kSecondaryButton);
    await pumps(t, 6);
    if (more) {
      await t.tap(find.text('更多选项'));
      await pumps(t, 6);
      expect(find.byType(FloatingSurface, skipOffstage: false), findsOneWidget);
    }
    await t.tap(find.text(item));
    await pumps(t);
  }

  double top(WidgetTester t, String path) => t.getTopLeft(row(path)).dy;

  testWidgets('a row right-click opens one menu on release; blank space has its own commands', (t) async {
    await mount(t);
    final menus = find.byType(FloatingSurface, skipOffstage: false);
    final press = await t.startGesture(t.getCenter(row('/project/src')),
      buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await pumps(t, 8);
    expect(menus, findsNothing, reason: 'tap-down must not launch a menu');
    await press.up();
    await pumps(t, 6);
    expect(menus, findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.text('刷新'), findsNothing);
    expect(find.text('上传到此文件夹…'), findsNothing);
    expect(rowWidget(t, '/project/src').selected, isTrue);
    expect(rowWidget(t, '/project').selected, isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumps(t, 6);
    expect(menus, findsNothing, reason: 'one Escape leaves no hidden menu');

    await t.tap(find.byKey(const ValueKey('file-tree-background')),
      buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await pumps(t, 6);
    expect(menus, findsOneWidget);
    expect(find.text('上传到此文件夹…'), findsOneWidget);
    expect(find.text('复制路径'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumps(t, 6);
    await t.tap(row('/project'), buttons: kSecondaryMouseButton);
    await pumps(t, 6);
    expect(menus, findsOneWidget);
    expect(find.byKey(const ValueKey('menu-action-删除')), findsNothing);
    await t.tap(find.text('更多选项'));
    await pumps(t, 6);
    expect(find.text('从工作区移除文件夹'), findsOneWidget);
    expect(find.text('添加到当前工作区'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumps(t, 6);
    expect(menus, findsNothing);
    await finish(t);
  });

  testWidgets('compact actions honor selection, keyboard menus and refresh', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/README.md');
    await ctrlTap(t, '/project/a.txt');
    await t.tap(row('/project/a.txt'), buttons: kSecondaryMouseButton);
    await pumps(t, 6);
    expect(find.text('取消选择'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-action-重命名')), findsNothing);
    await t.tap(find.byTooltip('复制（Ctrl+C）'));
    await pumps(t, 6);
    expect(ws.fileClipboard.value!.items, hasLength(2));
    expect(rowWidget(t, '/project/README.md').selected, isTrue);
    expect(rowWidget(t, '/project/a.txt').selected, isTrue);

    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await pumps(t, 6);
    expect(find.text('取消选择'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumps(t, 6);
    expect(find.byType(FloatingSurface, skipOffstage: false), findsNothing);

    link.directories['/project']!.add(fileE('new.txt', 9));
    await t.tap(find.byTooltip('刷新（F5）'));
    await pumps(t, 6);
    expect(row('/project/new.txt'), findsOneWidget);
    expect(rowWidget(t, '/project/a.txt').selected, isTrue);
    await finish(t);
  });

  testWidgets('refresh falls back to the surviving folder when a selected item is removed externally', (t) async {
    await mount(t);
    await t.tap(row('/project/a.txt'), buttons: kSecondaryMouseButton);
    await pumps(t, 6);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumps(t, 6);
    link.directories['/project']!.removeWhere((entry) => entry['name'] == 'a.txt');
    await t.sendKeyEvent(LogicalKeyboardKey.f5);
    await pumps(t, 6);
    expect(row('/project/a.txt'), findsNothing);
    expect(rowWidget(t, '/project').selected, isTrue);
    await finish(t);
  });

  testWidgets('narrow touch layout preserves one long-press menu and reachable actions', (t) async {
    await mount(t, width: 216, scale: 1.5, dynamicInput: true);
    expect(find.byTooltip('刷新（F5）').hitTestable(), findsOneWidget);
    expect(find.byTooltip('排序').hitTestable(), findsOneWidget);
    expect(find.text('修改日期'), findsNothing);
    await t.longPress(row('/project/a.txt'));
    await pumps(t, 6);
    expect(input.touch, isTrue);
    expect(find.byType(FloatingSurface, skipOffstage: false), findsOneWidget);
    expect(t.getSize(find.byTooltip('复制（Ctrl+C）')).height, greaterThanOrEqualTo(44));
    await t.tap(find.byTooltip('复制（Ctrl+C）'));
    await pumps(t, 6);
    expect(ws.fileClipboard.value!.items.single.path, '/project/a.txt');
    await finish(t);
  });

  testWidgets('a file row shows its size; a folder shows none until measured', (t) async {
    await mount(t);
    expect(rowWidget(t, '/project/big.bin').detail, '5.0 MB');
    expect(rowWidget(t, '/project/a.txt').detail, '12 B');
    expect(rowWidget(t, '/project/src').detail, isNull, reason: 'a folder size is not known without walking it');
    expect(rowWidget(t, '/project/big.bin').tooltip, allOf(contains('5242880 字节'), contains('-rw-r--r--'), contains('root:root')));
    await finish(t);
  });

  testWidgets('sorting: by size both ways, the choice is saved, folders stay first', (t) async {
    await mount(t);
    // default: name, folders first, natural and case-insensitive
    expect(top(t, '/project/src') < top(t, '/project/a.txt'), isTrue);
    expect(top(t, '/project/a.txt') < top(t, '/project/big.bin') && top(t, '/project/big.bin') < top(t, '/project/README.md'), isTrue);

    await t.tap(find.byTooltip('排序'));
    await pumps(t, 6);
    await t.tap(find.descendant(of: find.byType(FloatingSurface), matching: find.text('大小')));
    await pumps(t);
    expect(app.data.editor.fileSort, 'size');
    expect(top(t, '/project/a.txt') < top(t, '/project/README.md') && top(t, '/project/README.md') < top(t, '/project/big.bin'), isTrue, reason: '12 B, 42 B, 5 MB');
    expect(top(t, '/project/src') < top(t, '/project/a.txt'), isTrue);

    await t.tap(find.byTooltip('排序'));
    await pumps(t, 6);
    await t.tap(find.text('降序'));
    await pumps(t);
    expect(app.data.editor.fileSortDesc, isTrue);
    expect(top(t, '/project/big.bin') < top(t, '/project/README.md') && top(t, '/project/README.md') < top(t, '/project/a.txt'), isTrue);
    expect(top(t, '/project/src') < top(t, '/project/big.bin'), isTrue, reason: 'folders first still holds');

    await t.tap(find.byTooltip('排序'));
    await pumps(t, 6);
    await t.tap(find.text('修改时间'));
    await pumps(t);
    expect(app.data.editor.fileSort, 'mtime');
    // newest first: README (300) > a.txt (200) > big.bin (100); the date is shown on the row
    expect(top(t, '/project/README.md') < top(t, '/project/a.txt') && top(t, '/project/a.txt') < top(t, '/project/big.bin'), isTrue);
    expect(rowWidget(t, '/project/a.txt').detail, contains('12 B'));
    await finish(t);
  });

  testWidgets('wide explorer headers sort the actual list and show direction', (t) async {
    await mount(t, width: 520);
    await t.tap(find.byTooltip('按修改日期排序'));
    await pumps(t, 6);
    expect(app.data.editor.fileSort, 'mtime');
    expect(find.byTooltip('修改日期 · 升序，点击改变顺序'), findsOneWidget);
    expect(top(t, '/project/big.bin'), lessThan(top(t, '/project/README.md')));
    await t.tap(find.byTooltip('修改日期 · 升序，点击改变顺序'));
    await pumps(t, 6);
    expect(app.data.editor.fileSortDesc, isTrue);
    expect(top(t, '/project/README.md'), lessThan(top(t, '/project/big.bin')));
    await finish(t);
  });

  testWidgets('copy a file, paste it into a folder: fs.copy, the original stays, the copy appears', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/README.md');
    await chord(t, LogicalKeyboardKey.keyC);
    expect(ws.fileClipboard.value!.cut, isFalse);
    expect(find.text('已复制 1 项'), findsOneWidget);

    await t.tap(row('/project/src'));
    await pumps(t);
    await chord(t, LogicalKeyboardKey.keyV);
    expect(link.log, contains('fs.copy /project/README.md -> /project/src/README.md'));
    expect(row('/project/src/README.md'), findsOneWidget);
    expect(row('/project/README.md'), findsOneWidget);
    expect(ws.fileClipboard.value, isNotNull, reason: 'a copy can be pasted again');
    await finish(t);
  });

  testWidgets('a cut from a replaced link cannot be pasted on the new link', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/a.txt');
    await chord(t, LogicalKeyboardKey.keyX);
    final replacement = OpsLink();
    app.active = replacement;
    app.notifyListeners();
    await pumps(t);
    expect(ws.fileClipboard.value?.link, same(link));
    await t.tap(row('/project/src'), buttons: kSecondaryMouseButton);
    await pumps(t, 6);
    await t.tap(find.byKey(const ValueKey('menu-action-粘贴')));
    await pumps(t, 6);
    expect(replacement.log, isEmpty);
    expect(link.log, isEmpty);
    expect(ws.fileClipboard.value?.link, same(link));
    await finish(t);
  });

  testWidgets('cut and paste moves with fs.rename and empties the clipboard', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/a.txt');
    await chord(t, LogicalKeyboardKey.keyX);
    expect(rowWidget(t, '/project/a.txt').dimmed, isTrue, reason: 'a cut row is drawn faint');

    await t.tap(row('/project/src'));
    await pumps(t);
    await chord(t, LogicalKeyboardKey.keyV);
    expect(link.log, contains('fs.rename /project/a.txt -> /project/src/a.txt'));
    expect(row('/project/a.txt'), findsNothing);
    expect(row('/project/src/a.txt'), findsOneWidget);
    expect(ws.fileClipboard.value, isNull);
    await finish(t);
  });

  testWidgets('pasting onto a taken name asks; keep both makes a numbered copy', (t) async {
    link.directories['/project/src']!.add(fileE('README.md', 1));
    await mount(t);
    await ctrlTap(t, '/project/README.md');
    await chord(t, LogicalKeyboardKey.keyC);
    await t.tap(row('/project/src'));
    await pumps(t);
    await chord(t, LogicalKeyboardKey.keyV);
    expect(find.textContaining('已有「README.md」'), findsOneWidget);
    expect(link.log.where((l) => l.startsWith('fs.')), isEmpty, reason: 'nothing happens before the answer');
    await t.tap(find.text('保留两者'));
    await pumps(t);
    expect(link.log, contains('fs.copy /project/README.md -> /project/src/README 副本.md'));
    expect(row('/project/src/README 副本.md'), findsOneWidget);
    await finish(t);
  });

  testWidgets('"create copy" in the menu duplicates beside the original without asking', (t) async {
    await mount(t);
    await menuOn(t, '/project/a.txt', '创建副本', more: true);
    expect(link.log, ['fs.copy /project/a.txt -> /project/a 副本.txt']);
    expect(row('/project/a 副本.txt'), findsOneWidget);
    await finish(t);
  });

  testWidgets('lost paste receipt is checked on the same agent without replay or deletion', (t) async {
    link.transactionalPaste = true;
    link.directories['/project']!.firstWhere((e) => e['name'] == 'README.md')['etag'] = 'source-version';
    link.directories['/project/src']!.add(fileE('README.md', 7)..['etag'] = 'target-version');
    await mount(t);
    await ctrlTap(t, '/project/README.md');
    await chord(t, LogicalKeyboardKey.keyX);
    await t.tap(row('/project/src'));
    await pumps(t);
    await chord(t, LogicalKeyboardKey.keyV);
    await t.tap(find.text('替换'));
    await pumps(t);
    expect(link.log, ['fs.paste.replace']);
    expect(ws.pendingPaste.value?.id, link.receipt);
    final saved = app.profile;
    expect(saved.server('server')?.pendingPaste?.id, link.receipt);
    expect(saved.server('server')?.pendingPaste?.toJson().keys,
      unorderedEquals(['id', 'agent_id', 'pin', 'target']));
    final replacement = OpsLink()
      ..transactionalPaste = true
      ..receipt = link.receipt;
    app.active = replacement;
    app.notifyListeners();
    await pumps(t);
    await t.tap(find.byTooltip('查询替换结果'));
    await pumps(t);
    expect(replacement.log, ['fs.paste.status']);
    expect(ws.pendingPaste.value, isNull);
    expect(app.profile.server('server')?.pendingPaste, isNull);
    expect(ws.fileClipboard.value?.cut, isTrue);
    await finish(t);

    // Simulate a restarted client with a profile round-tripped through JSON.
    ws.dispose();
    app.dispose();
    final wrongAgent = OpsLink()..transactionalPaste = true..pin = 'different-pin';
    app = _SwitchingApp(wrongAgent)..data = saved.copy();
    ws = Workspace(app, 'server');
    expect(ws.pendingPaste.value?.id, link.receipt);
    expect(ws.fileClipboard.value, isNull);
    await mount(t);
    await t.tap(find.byTooltip('查询替换结果'));
    await pumps(t);
    expect(wrongAgent.log, isEmpty);
    expect(ws.pendingPaste.value, isNotNull);

    replacement.log.clear();
    replacement.mismatchedReceipt = true;
    app.active = replacement;
    app.notifyListeners();
    await pumps(t);
    await t.tap(find.byTooltip('查询替换结果'));
    await pumps(t);
    expect(ws.pendingPaste.value, isNotNull);
    replacement.mismatchedReceipt = false;
    await t.tap(find.byTooltip('查询替换结果'));
    await pumps(t);
    expect(replacement.log, ['fs.paste.status', 'fs.paste.status']);
    expect(ws.pendingPaste.value, isNull);
    await finish(t);
  });

  testWidgets('does not send replace when the encrypted receipt fails to save', (t) async {
    link.transactionalPaste = true;
    link.directories['/project']!.firstWhere((e) => e['name'] == 'README.md')['etag'] = 'source-version';
    link.directories['/project/src']!.add(fileE('README.md', 7)..['etag'] = 'target-version');
    await mount(t);
    await ctrlTap(t, '/project/README.md');
    await chord(t, LogicalKeyboardKey.keyX);
    await t.tap(row('/project/src'));
    await pumps(t);
    await chord(t, LogicalKeyboardKey.keyV);
    app.failChanges = true;
    await t.tap(find.text('替换'));
    await pumps(t);
    expect(link.log, isEmpty);
    expect(ws.pendingPaste.value, isNull);
    await finish(t);
  });

  testWidgets('calculate size: the folder and the sizes under it appear, and size sorting can use them', (t) async {
    link.directories['/project/src']!.add(dirE('lib'));
    link.directories['/project/src/lib'] = [fileE('x.dart', 1024)];
    await mount(t);
    await t.tap(row('/project/src'));
    await pumps(t);
    await menuOn(t, '/project/src', '属性…');
    await t.tap(find.text('计算大小'));
    await pumps(t);
    expect(link.log, contains('fs.du /project/src'));
    expect(rowWidget(t, '/project/src').detail, '3.0 MB');
    expect(rowWidget(t, '/project/src/lib').detail, '1.0 KB', reason: 'each folder under it gets its size from the same walk');
    expect(rowWidget(t, '/project/src/main.dart').detail, '3.0 MB');
    await t.tap(find.text('关闭'));
    await pumps(t, 6);
    await finish(t);
  });

  testWidgets('Ctrl-click selects several rows and the footer totals them; Escape clears the clipboard', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/README.md');
    await ctrlTap(t, '/project/a.txt');
    expect(find.text('已选 2 项 · 54 B'), findsOneWidget);
    await chord(t, LogicalKeyboardKey.keyC);
    expect(find.textContaining('已复制 2 项'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumps(t, 4);
    expect(ws.fileClipboard.value, isNull);
    await finish(t);
  });

  testWidgets('Delete asks first, then fs.delete; cancelling deletes nothing', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/a.txt');
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await pumps(t, 6);
    expect(find.text('删除 a.txt？'), findsOneWidget);
    await t.tap(find.text('取消'));
    await pumps(t, 6);
    expect(link.log, isEmpty);
    expect(row('/project/a.txt'), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await pumps(t, 6);
    await t.tap(find.text('删除'));
    await pumps(t);
    expect(link.log, ['fs.delete /project/a.txt']);
    expect(row('/project/a.txt'), findsNothing);
    await finish(t);
  });

  testWidgets('confirmation cannot delete through a replacement link', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/a.txt');
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await pumps(t, 6);
    expect(find.text('删除 a.txt？'), findsOneWidget);
    final replacement = OpsLink();
    app.active = replacement;
    app.notifyListeners();
    await pumps(t, 6);
    await t.tap(find.text('删除'));
    await pumps(t, 6);
    expect(link.log, isEmpty);
    expect(replacement.log, isEmpty);
    expect(row('/project/a.txt'), findsOneWidget);
    await finish(t);
  });

  testWidgets('delete rechecks for an edit made while the confirmation is open', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/a.txt');
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await pumps(t, 6);
    final tab = EditorTab(id: 'file:home:/project/a.txt', title: 'a.txt', icon: Icons.edit, builder: (_) => const SizedBox());
    tab.dirty.value = true;
    ws.tabs.add(tab);
    await t.tap(find.text('删除'));
    await pumps(t, 6);
    expect(link.log, isEmpty);
    expect(ws.tabs, contains(tab));
    expect(row('/project/a.txt'), findsOneWidget);
    await finish(t);
  });

  testWidgets('F2 renames; a file with unsaved text open is not renamed from under the editor', (t) async {
    await mount(t);
    await ctrlTap(t, '/project/a.txt');
    await t.sendKeyEvent(LogicalKeyboardKey.f2);
    await pumps(t, 6);
    await t.enterText(find.byType(TextField), 'b.txt');
    await t.tap(find.text('确定'));
    await pumps(t);
    expect(link.log, ['fs.rename /project/a.txt -> /project/b.txt']);
    expect(row('/project/b.txt'), findsOneWidget);

    final tab = EditorTab(id: 'file:home:/project/b.txt', title: 'b.txt', icon: Icons.edit, builder: (_) => const SizedBox());
    tab.dirty.value = true;
    ws.tabs.add(tab);
    link.log.clear();
    await t.sendKeyEvent(LogicalKeyboardKey.f2);
    await pumps(t, 6);
    expect(find.byType(TextField), findsNothing, reason: 'no rename dialog while its text is unsaved');
    await chord(t, LogicalKeyboardKey.keyX);
    expect(ws.fileClipboard.value, isNull, reason: 'cut is refused too');
    expect(link.log, isEmpty);
    await finish(t);
  });

  testWidgets('properties shows size, time, permissions and owner; a folder can be measured from it', (t) async {
    await mount(t);
    await menuOn(t, '/project/big.bin', '属性…');
    expect(find.text('5.0 MB（5242880 字节）'), findsOneWidget);
    expect(find.text('-rw-r--r--'), findsOneWidget);
    expect(find.text('root:root'), findsOneWidget);
    await t.tap(find.text('关闭'));
    await pumps(t, 6);

    await menuOn(t, '/project/src', '属性…');
    expect(find.text('尚未统计'), findsOneWidget);
    await t.tap(find.text('计算大小'));
    await pumps(t);
    expect(find.textContaining('3.0 MB（3145728 字节）'), findsOneWidget);
    expect(rowWidget(t, '/project/src').detail, '3.0 MB', reason: 'the tree learns the measurement too');
    await t.tap(find.text('关闭'));
    await pumps(t, 6);
    await finish(t);
  });
}
