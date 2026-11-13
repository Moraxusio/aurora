import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/tab_workspace_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/kernel/workbench_view.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _LayoutProbe extends SingleChildRenderObjectWidget {
  final VoidCallback onLayout;
  const _LayoutProbe(this.onLayout) : super(child: const SizedBox.expand());
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _LayoutCounter(onLayout);
  @override
  void updateRenderObject(BuildContext context, _LayoutCounter renderObject) =>
      renderObject.onLayout = onLayout;
}

class _LayoutCounter extends RenderProxyBox {
  VoidCallback onLayout;
  _LayoutCounter(this.onLayout);
  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}

void main() {
  testWidgets('resizing a viewport does not relayout every hidden document', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final app = WorkspaceApp(),
        counts = <String, int>{},
        input = InputMode(touch: false);
    final ws = Workspace(app, 'server');
    for (var i = 0; i < 30; i++) {
      final id = 'doc-$i';
      ws.openTab(
        EditorTab(
          id: id,
          title: id,
          icon: Icons.description,
          builder: (_) => _LayoutProbe(
            () => counts.update(id, (n) => n + 1, ifAbsent: () => 1),
          ),
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
    await t.pumpAndSettle();
    final before = Map<String, int>.from(counts);
    final watch = Stopwatch()..start();
    for (var i = 1; i <= 24; i++) {
      t.view.physicalSize = Size(1200 + i * 2, 800);
      await t.pump();
    }
    watch.stop();
    final hiddenLayouts = [
      for (var i = 0; i < 29; i++) counts['doc-$i']! - before['doc-$i']!,
    ].fold(0, (a, b) => a + b);
    // This is a deterministic work counter, not a claim about release FPS.
    debugPrint(
      'UI_RESIZE_BENCH frames=24 tabs=30 hiddenLayouts=$hiddenLayouts elapsedUs=${watch.elapsedMicroseconds}',
    );
    await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    ws.dispose();
    app.dispose();
    input.dispose();
    expect(
      hiddenLayouts,
      0,
      reason: 'offstage buffers should retain their last constraints',
    );
  });

  testWidgets(
    'a burst of geometry updates does not fan out to service listeners',
    (t) async {
      final app = WorkspaceApp();
      final ws = Workspace(app, 'server');
      ws.openTab(
        EditorTab(
          id: 'live',
          title: 'live',
          icon: Icons.terminal,
          builder: (_) => const SizedBox(),
        ),
      );
      ws.arrangeEditors(EditorArrangement.columns);
      await ws.flushViews();
      await t.pump();
      var serviceNotifications = 0;
      var geometryFrames = 0;
      ws.geometryRevision.addListener(() => geometryFrames++);
      ws.addListener(() => serviceNotifications++);
      final watch = Stopwatch()..start();
      for (var i = 0; i < 240; i++) {
        ws.setSideWidth(240 + i.toDouble());
      }
      watch.stop();
      expect(
        ws.viewForCurrent().tabLayout['side_width'],
        300,
        reason: 'no JSON snapshots inside the pointer-update loop',
      );
      debugPrint(
        'UI_GEOMETRY_BENCH updates=240 serviceNotifications=$serviceNotifications elapsedUs=${watch.elapsedMicroseconds}',
      );
      await ws.flushViews();
      await t.pump();
      expect(ws.tabLayout.sideWidth, 479);
      expect(geometryFrames, 1);
      expect(ws.viewForCurrent().tabLayout['side_width'], 479);
      ws.dispose();
      app.dispose();
      expect(
        serviceNotifications,
        0,
        reason: 'widths must use the separate frame-coalesced geometry signal',
      );
    },
  );

  testWidgets(
    'terminal panel resize is frame coalesced and hidden terminal buffers keep their constraints',
    (t) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final app = WorkspaceApp(),
          input = InputMode(touch: false),
          counts = <String, int>{};
      final ws = Workspace(app, 'server');
      ws.openTab(
        EditorTab(
          id: 'doc',
          title: 'doc',
          icon: Icons.description,
          builder: (_) => const SizedBox(),
        ),
      );
      for (var i = 0; i < 12; i++) {
        final id = 'term:$i';
        ws.openTab(
          EditorTab(
            id: id,
            title: id,
            icon: Icons.terminal,
            builder: (_) => _LayoutProbe(
              () => counts.update(id, (n) => n + 1, ifAbsent: () => 1),
            ),
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
                    WorkbenchView(ws: ws, empty: const SizedBox()),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await ws.flushViews();
      final before = Map.of(counts);
      var business = 0, geometry = 0;
      ws.addListener(() => business++);
      ws.geometryRevision.addListener(() => geometry++);
      for (var i = 0; i < 240; i++) {
        ws.setTerminalHeight(260 + i.toDouble());
      }
      expect(
        ws.viewForCurrent().tabLayout['panel_height'],
        isNull,
        reason: 'do not serialize inside a drag',
      );
      await t.pump();
      expect(business, 0);
      expect(geometry, 1);
      final hidden = [
        for (var i = 0; i < 11; i++) counts['term:$i']! - before['term:$i']!,
      ].fold(0, (a, b) => a + b);
      expect(hidden, 0);
      await ws.flushViews();
      expect(
        app.data.servers.single.browserView.tabLayout['panel_height'],
        499,
      );
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
      input.dispose();
      debugPrint(
        'PANEL_RESIZE_BENCH updates=240 businessNotifications=$business geometryFrames=$geometry hiddenTerminalLayouts=$hidden',
      );
    },
  );
}
