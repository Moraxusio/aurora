import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/tab_drag.dart';
import 'package:aurora/kernel/tab_workspace_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _Probe extends StatefulWidget {
  final String id;
  final Map<String, int> opened, disposed;
  const _Probe(this.id, this.opened, this.disposed);
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final controller = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.opened.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.disposed.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        Text('Document ${widget.id}'),
        TextField(key: ValueKey('input-${widget.id}'), controller: controller),
      ],
    ),
  );
}

void main() {
  setUpAll(() async {
    if (Platform.environment['AURORA_TAB_SHOTS'] == null) return;
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    for (final entry in <String, String>{
      Ide.ui: r'C:\Windows\Fonts\SegUIVar.ttf',
      'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
      'Microsoft YaHei UI': r'C:\Windows\Fonts\msyh.ttc',
      if (flutterRoot != null)
        'MaterialIcons':
            '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) continue;
      await (FontLoader(entry.key)..addFont(
            Future.value(ByteData.sublistView(file.readAsBytesSync())),
          ))
          .load();
    }
  });
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  late Map<String, int> opened, disposed;
  final shot = GlobalKey();
  setUp(() {
    app = WorkspaceApp();
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
    opened = {};
    disposed = {};
  });
  tearDown(() async {
    await ws.flushViews();
    ws.dispose();
    app.dispose();
    input.dispose();
  });

  void open(String id) => ws.openTab(
    EditorTab(
      id: id,
      title: 'Project $id · 文件与终端',
      icon: id == 'terminal' ? Icons.terminal : Icons.description,
      builder: (_) => _Probe(id, opened, disposed),
    ),
  );
  Future<void> pump(WidgetTester t, {Size size = const Size(1200, 800)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: RepaintBoundary(
              key: shot,
              child: ListenableBuilder(
                listenable: ws,
                builder: (_, _) => TabWorkspaceView(
                  ws: ws,
                  empty: const Center(child: Text('Welcome fixture')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> snapshot(WidgetTester t, String name) async {
    final dir = Platform.environment['AURORA_TAB_SHOTS'];
    if (dir == null || dir.isEmpty) return;
    await t.pump();
    final boundary =
        shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(dir).create(recursive: true);
      await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> finish(WidgetTester t) async {
    await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'all arrangements and tab placements keep ONE live body and unsaved input',
    (t) async {
      for (final id in ['a', 'b', 'c', 'terminal']) {
        open(id);
      }
      await pump(t);
      await t.enterText(
        find.byKey(const ValueKey('input-terminal')),
        'unsaved synthetic command',
      );
      for (final arrangement in EditorArrangement.values) {
        ws.arrangeEditors(arrangement);
        for (final placement in TabPlacement.values) {
          ws.setTabPlacement(placement);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(opened.values, everyElement(1));
          expect(disposed, isEmpty);
          final editor = t.widget<TextField>(
            find.byKey(const ValueKey('input-terminal'), skipOffstage: false),
          );
          expect(editor.controller!.text, 'unsaved synthetic command');
        }
      }
      ws.arrangeEditors(EditorArrangement.grid);
      ws.setTabPlacement(TabPlacement.top);
      await t.pumpAndSettle();
      await snapshot(t, 'tabs-grid-desktop');
      await finish(t);
      expect(disposed.values, everyElement(1));
    },
  );

  testWidgets(
    'phone focuses selected group without losing hidden group or content',
    (t) async {
      open('a');
      open('b');
      ws.splitGroup(SplitAxis.horizontal, tabId: 'b');
      await pump(t);
      await t.enterText(find.byKey(const ValueKey('input-b')), 'retained text');
      final root = ws.tabLayout.root;
      t.view.physicalSize = const Size(390, 760);
      await t.pumpAndSettle();
      expect(find.byTooltip('切换视图'), findsOneWidget);
      expect(find.textContaining('编辑组'), findsNothing);
      expect(find.byKey(const ValueKey('input-b')), findsOneWidget);
      ws.focusGroupAt(0);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('input-a')), findsOneWidget);
      ws.focusGroupAt(1);
      await t.pumpAndSettle();
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('input-b')))
            .controller!
            .text,
        'retained text',
      );
      expect(ws.tabLayout.root, same(root));
      expect(opened, {'a': 1, 'b': 1});
      await snapshot(t, 'tabs-phone-focus');
      await finish(t);
    },
  );

  testWidgets(
    'vertical tab rail and editor divider resize with bounded geometry',
    (t) async {
      open('a');
      open('b');
      await pump(t);
      ws.setTabPlacement(TabPlacement.left);
      await t.pumpAndSettle();
      final group = ws.tabLayout.current.id;
      final before = ws.tabLayout.tabsWidth;
      await t.drag(
        find.byKey(ValueKey('tabs-resize-$group')),
        const Offset(65, 0),
      );
      await t.pumpAndSettle();
      expect(ws.tabLayout.tabsWidth, greaterThan(before));
      expect(ws.tabLayout.tabsWidth, lessThanOrEqualTo(400));
      await snapshot(t, 'tabs-vertical-desktop');
      ws.setTabPlacement(TabPlacement.top);
      ws.arrangeEditors(EditorArrangement.rows);
      await t.pumpAndSettle();
      final split = ws.tabLayout.root as TabSplit;
      final ratio = split.ratio;
      await t.drag(
        find.byKey(ValueKey('group-resize-${split.id}')),
        const Offset(0, 70),
      );
      await t.pumpAndSettle();
      expect(split.ratio, greaterThan(ratio));
      expect(disposed, isEmpty);
      await finish(t);
    },
  );

  testWidgets(
    'mouse drag reorders a tab without recreating its terminal body',
    (t) async {
      open('a');
      open('b');
      open('terminal');
      await pump(t);
      final source = find.byKey(const ValueKey('tab-terminal'));
      final destination = find.byKey(const ValueKey('tab-a'));
      await t.dragFrom(
        t.getCenter(source),
        t.getTopLeft(destination) + const Offset(12, 18) - t.getCenter(source),
      );
      await t.pumpAndSettle();
      expect(ws.tabLayout.current.tabs, ['terminal', 'a', 'b']);
      expect(opened, {'a': 1, 'b': 1, 'terminal': 1});
      expect(disposed, isEmpty);
      await finish(t);
    },
  );

  testWidgets(
    'dropping on a pane edge creates a second row, center moves between groups',
    (t) async {
      open('a');
      open('b');
      await pump(t);
      final start = t.getCenter(find.byKey(const ValueKey('tab-b')));
      final gesture = await t.startGesture(start);
      await gesture.moveBy(const Offset(22, 0));
      await t.pump();
      final group = ws.tabLayout.current.id;
      final target = find.byKey(ValueKey('pane-drop-$group'));
      final rect = t.getRect(target);
      await gesture.moveTo(Offset(rect.center.dx, rect.bottom - 12));
      await t.pump();
      expect(
        ws.tabLayout.groups,
        hasLength(1),
        reason: 'hover is a preview, not a model mutation',
      );
      expect(find.byKey(ValueKey('drop-preview-$group')), findsOneWidget);
      await gesture.up();
      await t.pumpAndSettle();
      expect(ws.tabLayout.groups, hasLength(2));
      expect((ws.tabLayout.root as TabSplit).axis, SplitAxis.vertical);
      expect(ws.focusedId, 'b');
      final first = ws.tabLayout.groups.first.id;
      final next = await t.startGesture(
        t.getCenter(find.byKey(const ValueKey('tab-b'))),
      );
      await next.moveBy(const Offset(22, 0));
      await t.pump();
      await next.moveTo(t.getCenter(find.byKey(ValueKey('pane-drop-$first'))));
      await t.pump();
      await next.up();
      await t.pumpAndSettle();
      expect(ws.tabLayout.groups, hasLength(1));
      expect(disposed, isEmpty);
      await finish(t);
    },
  );

  testWidgets(
    'active label scrolls into view and empty editor still exposes layouts',
    (t) async {
      await pump(t, size: const Size(600, 700));
      expect(find.text('Welcome fixture'), findsOneWidget);
      for (var i = 0; i < 25; i++) {
        open('tab-$i');
      }
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tab-tab-24')).hitTestable(),
        findsOneWidget,
      );
      ws.activate('tab-0');
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tab-tab-0')).hitTestable(),
        findsOneWidget,
      );
      await finish(t);
    },
  );

  testWidgets(
    'focusing another group restores its input focus, not just the highlight',
    (t) async {
      open('a');
      open('b');
      ws.splitGroup(SplitAxis.horizontal, tabId: 'b');
      await pump(t);
      await t.tap(find.byKey(const ValueKey('input-a')));
      await t.pump();
      final a = t
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('input-a')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode;
      await t.tap(find.byKey(const ValueKey('input-b')));
      await t.pump();
      final b = t
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('input-b')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode;
      expect(b.hasFocus, isTrue);
      ws.focusGroupAt(0);
      await t.pump();
      await t.pump();
      expect(a.hasFocus, isTrue);
      expect(b.hasFocus, isFalse);
      await finish(t);
    },
  );

  testWidgets(
    'wrapped active label stays visible after selection, resizing and pinning',
    (t) async {
      for (var i = 0; i < 25; i++) {
        open('tab-$i');
      }
      ws.setTabPlacement(TabPlacement.wrap);
      await pump(t, size: const Size(600, 700));
      final last = find.byKey(const ValueKey('tab-tab-24'));
      expect(last.hitTestable(), findsOneWidget);
      ws.activate('tab-0');
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tab-tab-0')).hitTestable(),
        findsOneWidget,
      );
      ws.activate('tab-24');
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(390, 700);
      await t.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      ws.setTabWidth(220);
      await t.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      ws.pinTab('tab-24');
      await t.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      // Switching away from wrap must also reset/reveal the new scroll axis.
      ws.setTabPlacement(TabPlacement.top);
      await t.pumpAndSettle();
      ws.pinTab('tab-24');
      ws.moveTab('tab-24', ws.tabLayout.current.id);
      await t.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      ws.setTabWidth(260);
      await t.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await finish(t);
    },
  );

  testWidgets(
    'layout menu exposes tab widths and touch targets remain usable',
    (t) async {
      open('a');
      open('b');
      input.dispose();
      input = InputMode(touch: true);
      await pump(t, size: const Size(600, 760));
      expect(
        t.getSize(find.byKey(const ValueKey('tab-a'))).height,
        greaterThanOrEqualTo(40),
      );
      await t.tap(find.byTooltip('视图操作').first);
      await t.pumpAndSettle();
      await t.tap(find.text('标签栏与布局…'));
      await t.pumpAndSettle();
      await t.tap(find.text('标签宽度'));
      await t.pumpAndSettle();
      final before = ws.tabLayout.tabWidth;
      await t.drag(find.byType(Slider), const Offset(60, 0));
      await t.pumpAndSettle();
      expect(ws.tabLayout.tabWidth, greaterThan(before));
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      await finish(t);
    },
  );

  testWidgets(
    'one quiet tab row, focus and restore never change the saved split tree',
    (t) async {
      open('a');
      open('b');
      await pump(t);
      expect(find.textContaining('编辑组'), findsNothing);
      expect(t.getTopLeft(find.text('Document b')).dy, lessThanOrEqualTo(37));
      ws.splitGroup(SplitAxis.horizontal, tabId: 'b');
      await t.pumpAndSettle();
      final root = ws.tabLayout.root;
      await t.tap(find.byTooltip('视图操作').last);
      await t.pumpAndSettle();
      await t.tap(find.text('放大当前视图'));
      await t.pumpAndSettle();
      expect(ws.focusMode, isTrue);
      expect(find.byTooltip('切换视图'), findsOneWidget);
      expect(find.byKey(const ValueKey('input-a')), findsNothing);
      await t.tap(find.byTooltip('视图操作'));
      await t.pumpAndSettle();
      await t.tap(find.text('还原分屏'));
      await t.pumpAndSettle();
      expect(ws.tabLayout.root, same(root));
      expect(find.byKey(const ValueKey('input-a')), findsOneWidget);
      expect(opened, {'a': 1, 'b': 1});
      await finish(t);
    },
  );

  testWidgets('dragging auto scrolls a long strip and commits only on drop', (
    t,
  ) async {
    for (var i = 0; i < 30; i++) {
      open('tab-$i');
    }
    ws.activate('tab-0');
    await pump(t, size: const Size(600, 700));
    var changes = 0;
    void changed() => changes++;
    ws.addListener(changed);
    final gesture = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('tab-tab-0'))),
    );
    await gesture.moveBy(const Offset(24, 0));
    await t.pump();
    final strip = t.getRect(find.byType(TabStripDropTarget));
    await gesture.moveTo(Offset(strip.right - 3, strip.center.dy));
    for (var i = 0; i < 90; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(ws.tabLayout.ordered.first, 'tab-0');
    expect(changes, 0, reason: 'hover and edge scrolling are paint-only');
    await gesture.up();
    await t.pumpAndSettle();
    expect(ws.tabLayout.ordered.indexOf('tab-0'), greaterThan(2));
    expect(changes, 1);
    expect(opened.values, everyElement(1));
    ws.removeListener(changed);
    await finish(t);
  });

  testWidgets(
    'cancelled edge drag clears the preview without changing layout',
    (t) async {
      open('a');
      open('b');
      await pump(t);
      final group = ws.tabLayout.current.id, root = ws.tabLayout.root;
      final gesture = await t.startGesture(
        t.getCenter(find.byKey(const ValueKey('tab-b'))),
      );
      await gesture.moveBy(const Offset(24, 0));
      await t.pump();
      final rect = t.getRect(find.byKey(ValueKey('pane-drop-$group')));
      await gesture.moveTo(Offset(rect.right - 8, rect.center.dy));
      await t.pump();
      expect(find.byKey(ValueKey('drop-preview-$group')), findsOneWidget);
      await gesture.cancel();
      await t.pumpAndSettle();
      expect(ws.tabLayout.root, same(root));
      expect(find.byKey(ValueKey('pane-drop-$group')), findsNothing);
      expect(disposed, isEmpty);
      await finish(t);
    },
  );
  testWidgets(
    'ordinary mouse wheel scrolls the horizontal tab strip without changing focus',
    (t) async {
      for (var i = 0; i < 15; i++) {
        open('tab-$i');
      }
      ws.activate('tab-0');
      await pump(t, size: const Size(600, 700));
      final strip = find.byType(TabStripDropTarget);
      final list = t.widget<ListView>(
        find.descendant(of: strip, matching: find.byType(ListView)),
      );
      await t.sendEventToBinding(
        PointerScrollEvent(
          position: t.getCenter(strip),
          scrollDelta: const Offset(0, 180),
        ),
      );
      await t.pump();
      expect(list.controller!.offset, greaterThan(0));
      expect(ws.focusedId, 'tab-0');
      await finish(t);
    },
  );
}
