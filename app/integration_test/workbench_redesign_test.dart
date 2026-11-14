// Real Windows engine, synthetic data only. Run with flutter drive --profile.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/tab_drag.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/theme/workbench_scale.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart';

import '../test/support/workspace_fixture.dart';
import '../test/workbench_visual_test.dart' show VisualWorkbenchLink;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows live typography, docking, retained buffers and engine frame timings', (t) async {
    const output = String.fromEnvironment('AURORA_REVIEW_OUT');
    expect(output, isNotEmpty);
    final features = Features(), input = InputMode(touch: false);
    final link = VisualWorkbenchLink(features), shell = GlobalKey(), frame = GlobalKey();
    final app = WorkspaceApp(wire: link);
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark),
      home: RepaintBoundary(key: frame, child: ListenableBuilder(listenable: app.appearance,
        child: InputMode.scope(mode: input, child: Shell(key: shell, app: app, features: features)),
        builder: (_, child) => WorkbenchScale(scale: app.appearance.value.uiScale, child: child!)))));
    await t.pumpAndSettle();
    final ws = (shell.currentState as dynamic).debugWorkspace as Workspace;
    for (var i = 0; i < 12; i++) {
      ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/src/document-$i.dart'));
    }
    openSession(ws, 'main');
    ws.openTab(EditorTab(id: 'ai:review', title: '工作台评审', icon: Icons.auto_awesome_outlined,
      builder: (_) => AiStudioView(ws: ws, initialSessionId: 'ses_1')));
    ws.activate('file:home:/project/src/document-0.dart');
    await t.pumpAndSettle();
    final doc = t.state<FileEditorState>(find.byType(FileEditor));
    doc.text = 'const unsaved = true;\n';
    final controller = t.widget<CodeEditor>(find.byType(CodeEditor)).controller;
    final terminal = t.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final timings = <ui.FrameTiming>[];
    void capture(List<ui.FrameTiming> frames) => timings.addAll(frames);
    SchedulerBinding.instance.addTimingsCallback(capture);
    final samples = <Map<String, Object>>[];
    var maxSidebarPointerError = 0.0;
    Future<void> measure(String name, Future<void> Function() task) async {
      timings.clear();
      await task();
      await t.pump(const Duration(milliseconds: 1100));
      final builds = timings.map((f) => f.buildDuration.inMicroseconds).toList()..sort();
      final rasters = timings.map((f) => f.rasterDuration.inMicroseconds).toList()..sort();
      int percentile(List<int> data, double p) => data.isEmpty ? 0 : data[((data.length-1)*p).round()];
      samples.add({'operation': name, 'frames': timings.length,
        'build_p95_us': percentile(builds, .95), 'build_max_us': percentile(builds, 1),
        'raster_p95_us': percentile(rasters, .95), 'raster_max_us': percentile(rasters, 1),
        'over_16ms': timings.where((f) => f.buildDuration.inMicroseconds > 16667 || f.rasterDuration.inMicroseconds > 16667).length});
    }
    await measure('file sidebar high-rate pointer drag', () async {
      final handle = find.byKey(const ValueKey('sidebar-resize'));
      final start = t.getCenter(handle);
      final gesture = await t.startGesture(start, kind: PointerDeviceKind.mouse);
      for (var frame = 0; frame < 32; frame++) {
        var dx = 0.0;
        for (var event = 1; event <= 4; event++) {
          final step = frame * 4 + event;
          dx = step <= 64 ? step.toDouble() : (128 - step).toDouble();
          await gesture.moveTo(start + Offset(dx, 0));
        }
        await t.pump(const Duration(milliseconds: 16));
        final error = (t.getCenter(handle).dx - start.dx - dx).abs();
        if (error > maxSidebarPointerError) maxSidebarPointerError = error;
        expect(error, lessThan(.1), reason: 'the divider must track the pointer, not merely render quickly');
      }
      await gesture.up();
    });
    await measure('live editor / terminal / chat font', () async {
      for (var i = 0; i < 24; i++) {
        final n = 12 + i % 12 * .5;
        app.appearance.set('editorFont', n);
        app.appearance.set('terminalFont', n);
        app.appearance.set('chatFont', n);
        await t.pump(const Duration(milliseconds: 16));
        expect(t.widget<CodeEditor>(find.byType(CodeEditor)).style!.fontSize, n);
        expect(t.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize, n);
      }
    });
    await measure('assistant divider drag', () async {
      final handle = find.byKey(const ValueKey('assistant-panel-resize'));
      final g = await t.startGesture(t.getCenter(handle), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 36; i++) {
        await g.moveBy(Offset(i < 18 ? -3 : 3, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
    });
    await measure('12 retained editor switches', () async {
      for (var i = 0; i < 36; i++) {
        ws.activate('file:home:/project/src/document-${i%12}.dart');
        await t.pump(const Duration(milliseconds: 16));
      }
    });
    ws.activate('file:home:/project/src/document-0.dart');
    await t.pumpAndSettle();
    expect(t.widget<CodeEditor>(find.byType(CodeEditor)).controller, same(controller));
    expect(doc.text, 'const unsaved = true;\n');
    expect(doc.dirty, isTrue);
    ws.hideAssistantPanel();
    await t.pumpAndSettle();
    // A pointer actually moves across the native Flutter surface to the new
    // visible compass, rather than directly invoking the layout mutation.
    final group = ws.tabLayout.focused;
    final drag = await t.startGesture(t.getCenter(find.byKey(const ValueKey('tab-file:home:/project/src/document-1.dart'))), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(24, 0)); await t.pump();
    final pane = t.getRect(find.byKey(ValueKey('pane-drop-$group')));
    final target = TabDropPolicy.compass(pane.size)[TabDropEdge.right]!.center + pane.topLeft;
    await drag.moveTo(target); await t.pump();
    expect(find.byKey(ValueKey('drop-preview-$group')), findsOneWidget);
    await drag.up(); await t.pumpAndSettle();
    expect(ws.tabLayout.groups, hasLength(2));
    ws.showAssistantPanel();
    await t.pumpAndSettle();
    expect(find.byType(CodeEditor), findsNWidgets(2), reason: 'the desktop editor column must keep both split documents visible beside AI');
    await measure('whole workbench zoom', () async {
      for (final scale in [1.1, 1.25, .9, 1.0]) {
        app.appearance.set('uiScale', scale);
        await t.pump(const Duration(milliseconds: 80));
      }
    });
    expect(t.widget<TerminalView>(find.byType(TerminalView)).terminal, same(terminal));
    expect(link.terminalStreams, hasLength(1));
    expect(t.takeException(), isNull);
    SchedulerBinding.instance.removeTimingsCallback(capture);
    final boundary = frame.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$output.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    await File('$output.json').writeAsString(const JsonEncoder.withIndent('  ').convert({
      'mode': const bool.fromEnvironment('dart.vm.profile') ? 'profile' : 'debug',
      'platform': Platform.operatingSystem, 'samples': samples,
      'physical_width': t.view.physicalSize.width, 'physical_height': t.view.physicalSize.height,
      'device_pixel_ratio': t.view.devicePixelRatio,
      'max_sidebar_pointer_error_logical_px': maxSidebarPointerError,
      'tabs': 12, 'terminal_attaches': link.terminalStreams.length, 'dirty_buffer_retained': doc.dirty,
      'native_engine': true, 'synthetic_data': true,
    }));
    await app.appearance.flush(); await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    app.dispose(); features.dispose(); input.dispose();
  });
}
