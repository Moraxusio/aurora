import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/tab_workspace_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
        'MaterialIcons': '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
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
      ws.arrangeEditors(EditorArrangement.columns);
      await pump(t);
      await t.enterText(find.byKey(const ValueKey('input-b')), 'retained text');
      final root = ws.tabLayout.root;
      t.view.physicalSize = const Size(390, 760);
      await t.pumpAndSettle();
      expect(find.textContaining('聚焦 · 编辑组'), findsOneWidget);
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
        t.getCenter(destination) - t.getCenter(source),
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
      final target = find.byKey(
        ValueKey('drop-${ws.tabLayout.current.id}-down'),
      );
      await gesture.moveTo(t.getCenter(target));
      await t.pump();
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
      await next.moveTo(
        t.getCenter(find.byKey(ValueKey('drop-$first-center'))),
      );
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
      ws.arrangeEditors(EditorArrangement.columns);
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
      await t.tap(find.byTooltip('标签与编辑区布局').first);
      await t.pumpAndSettle();
      await t.tap(find.text('调整单个标签宽度…'));
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
}
