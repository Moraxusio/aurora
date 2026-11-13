// Regression evidence for the reported right-pane overlay and unstable layout.
// Memory-only widgets: no native window, profile, server or real project.
import 'dart:ui' as ui;

import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/tab_workspace_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _OverflowPaint extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      (Offset.zero & size).inflate(4000),
      Paint()..color = Colors.red,
    );
  }

  @override
  bool shouldRepaint(_OverflowPaint old) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'changing the split direction preserves group identities and contents',
    () {
      final layout = TabLayout()
        ..add('a')
        ..add('b')
        ..add('c');
      layout.split(layout.current.id, SplitAxis.horizontal, tab: 'c');
      final before = [
        for (final g in layout.groups) (g.id, List.of(g.tabs), g.active),
      ];
      final focused = layout.focused;
      layout.arrange(EditorArrangement.rows);
      expect(
        layout.groups.map((g) => g.id),
        before.map((g) => g.$1),
        reason: 'layout is geometry, not a redistribution of tasks',
      );
      for (var i = 0; i < before.length; i++) {
        expect(layout.groups[i].tabs, before[i].$2);
        expect(layout.groups[i].active, before[i].$3);
      }
      expect(layout.focused, focused);
    },
  );

  test(
    'terminal sessions never enter or replace the document layout',
    () async {
      final app = WorkspaceApp();
      final ws = Workspace(app, 'server');
      final file = EditorTab(
        id: 'doc',
        title: 'Document',
        icon: Icons.description,
        builder: (_) => const SizedBox(),
      );
      ws.openTab(file);
      ws.openTab(
        EditorTab(
          id: 'term:main',
          title: 'main',
          icon: Icons.terminal,
          builder: (_) => const SizedBox(),
        ),
      );
      final editorActive = ws.tabLayout.current.active;
      final terminalOwner = ws.tabLayout.owner('term:main');
      await ws.flushViews();
      ws.dispose();
      app.dispose();
      expect(terminalOwner, isNull);
      expect(editorActive, file.id);
    },
  );

  testWidgets(
    'right-hand documents cannot paint over a sibling or their own tabs',
    (t) async {
      t.view.physicalSize = const Size(1400, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final app = WorkspaceApp(), input = InputMode(touch: false);
      final ws = Workspace(app, 'server'), shot = GlobalKey();
      ws.openTab(
        EditorTab(
          id: 'left',
          title: 'Left',
          icon: Icons.description,
          builder: (_) => const ColoredBox(color: Colors.green),
        ),
      );
      ws.openTab(
        EditorTab(
          id: 'right',
          title: 'Right',
          icon: Icons.description,
          builder: (_) => CustomPaint(painter: _OverflowPaint()),
        ),
      );
      ws.splitGroup(SplitAxis.horizontal, tabId: 'right');
      ws.setTabPlacement(TabPlacement.right);
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
                  builder: (_, _) =>
                      TabWorkspaceView(ws: ws, empty: const SizedBox()),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final left = const Offset(120, 200);
      final rail = t.getCenter(find.byKey(const ValueKey('tab-right')));
      final boundary =
          shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
      late Color leftPixel, tabPixel;
      await t.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        Color at(Offset point) {
          final i = (point.dy.floor() * image.width + point.dx.floor()) * 4;
          return Color.fromARGB(
            bytes!.getUint8(i + 3),
            bytes.getUint8(i),
            bytes.getUint8(i + 1),
            bytes.getUint8(i + 2),
          );
        }

        leftPixel = at(left);
        tabPixel = at(rail);
        image.dispose();
      });
      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
      input.dispose();
      expect(
        leftPixel.toARGB32(),
        Colors.green.toARGB32(),
        reason: 'the right viewport must clip its own paint',
      );
      expect(
        tabPixel.toARGB32(),
        isNot(Colors.red.toARGB32()),
        reason: 'document paint must not cover the tab strip',
      );
    },
  );

  testWidgets('the welcome page respects a right-hand tab rail too', (t) async {
    t.view.physicalSize = const Size(900, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final app = WorkspaceApp(), input = InputMode(touch: false);
    final ws = Workspace(app, 'server');
    ws.setTabPlacement(TabPlacement.right);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: TabWorkspaceView(
              ws: ws,
              empty: const SizedBox.expand(key: ValueKey('welcome-viewport')),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final welcome = t.getRect(find.byKey(const ValueKey('welcome-viewport')));
    final rail = t.getRect(
      find.byKey(ValueKey('tab-list-${ws.tabLayout.current.id}')),
    );
    await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    ws.dispose();
    app.dispose();
    input.dispose();
    expect(welcome.right, lessThanOrEqualTo(rail.left));
  });

  testWidgets(
    'every split, tab position and responsive width keeps viewport and tab hit regions disjoint',
    (t) async {
      t.view.physicalSize = const Size(1800, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final app = WorkspaceApp(), input = InputMode(touch: false);
      final ws = Workspace(app, 'server');
      for (var i = 0; i < 8; i++) {
        ws.openTab(
          EditorTab(
            id: 'doc-$i',
            title: 'Document $i',
            icon: Icons.description,
            builder: (_) => const SizedBox.expand(),
          ),
        );
      }
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: ListenableBuilder(
                listenable: ws,
                builder: (_, _) =>
                    TabWorkspaceView(ws: ws, empty: const SizedBox()),
              ),
            ),
          ),
        ),
      );
      for (final arrangement in EditorArrangement.values) {
        ws.arrangeEditors(arrangement);
        final groups = ws.tabLayout.groups.toList();
        for (var i = 0; i < groups.length; i++) {
          ws.moveTab('doc-$i', groups[i].id);
        }
        for (final placement in TabPlacement.values) {
          ws.setTabPlacement(placement);
          for (final size in const [
            Size(1800, 1000),
            Size(1100, 650),
            Size(600, 500),
            Size(390, 760),
            Size(1800, 1000),
          ]) {
            t.view.physicalSize = size;
            await t.pumpAndSettle();
            expect(t.takeException(), isNull);
            final bodies = find.byWidgetPredicate(
              (widget) =>
                  widget is ClipRect &&
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'editor-viewport-',
                  ),
            );
            final rectangles = [
              for (final element in bodies.evaluate())
                t.getRect(
                  find.byElementPredicate((other) => identical(element, other)),
                ),
            ];
            final bars = [
              for (final group in ws.tabLayout.groups)
                if (find
                    .byKey(ValueKey('tab-list-${group.id}'))
                    .evaluate()
                    .isNotEmpty)
                  t.getRect(find.byKey(ValueKey('tab-list-${group.id}'))),
            ];
            for (var i = 0; i < rectangles.length; i++) {
              expect(rectangles[i].left, greaterThanOrEqualTo(0));
              expect(rectangles[i].top, greaterThanOrEqualTo(0));
              expect(rectangles[i].right, lessThanOrEqualTo(size.width));
              expect(rectangles[i].bottom, lessThanOrEqualTo(size.height));
              for (final bar in bars) {
                expect(rectangles[i].overlaps(bar), isFalse);
              }
              for (final other in rectangles.skip(i + 1)) {
                expect(rectangles[i].overlaps(other), isFalse);
              }
            }
            for (final group in ws.tabLayout.groups) {
              if (group.active == null ||
                  find
                      .byKey(ValueKey('tab-list-${group.id}'))
                      .evaluate()
                      .isEmpty) {
                continue;
              }
              expect(
                find.byKey(ValueKey('tab-${group.active}')).hitTestable(),
                findsOneWidget,
              );
            }
          }
        }
      }
      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
      input.dispose();
    },
  );
}
