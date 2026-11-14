import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/main.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:re_editor/re_editor.dart';

import '../test/support/workspace_fixture.dart';
import '../test/workbench_visual_test.dart' show VisualWorkbenchLink;
import 'native_window.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native shared surfaces, transitions and retained work', (
    t,
  ) async {
    const output = String.fromEnvironment('AURORA_REVIEW_OUT');
    expect(output, isNotEmpty);
    t.testTextInput.register();
    addTearDown(t.testTextInput.unregister);
    final features = Features();
    final link = VisualWorkbenchLink(features);
    final app = WorkspaceApp(wire: link);
    app.data.servers.single.selectedWorkspace = 'a';
    app.appearance.set('theme', 'dark');
    final frame = GlobalKey();
    NativeTestWindow? window;
    Workspace? workspace;
    final evidence = <String, Object>{};
    Future<void> settle([int count = 6]) async {
      for (var i = 0; i < count; i++) {
        await t.pump(const Duration(milliseconds: 60));
      }
      expect(t.takeException(), isNull);
      expect(find.byType(ErrorWidget, skipOffstage: false), findsNothing);
    }

    Future<void> click(Finder target) async {
      expect(target.hitTestable(), findsOneWidget);
      await t.tapAt(t.getCenter(target), kind: PointerDeviceKind.mouse);
      await settle();
    }

    Future<void> escape() async {
      await t.sendKeyEvent(
        LogicalKeyboardKey.escape,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await settle();
    }

    Future<void> shot(String name) async {
      final image =
          await (frame.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output-$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    double opacity() => t
        .widget<Opacity>(
          find.ancestor(
            of: find.byType(FloatingSurface),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;
    try {
      await t.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: AuroraApp(app: app),
        ),
      );
      await settle(16);
      window = NativeTestWindow();
      window.resize(const Size(1440, 960));
      await settle();
      final ws = workspace =
          (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;
      await click(find.byKey(const ValueKey('project-switcher')));
      await click(find.text('Alpha').last);
      ws.openTab(
        fileEditorTab(ws, root: 'home', path: '/project/src/main.dart'),
      );
      openSession(ws, 'main');
      await settle();
      final document = t.state<FileEditorState>(find.byType(FileEditor));
      final editor = t.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
      final original = document.text;
      document.text = '// unsaved UI review draft\n';
      await settle();
      for (final theme in ['dark', 'light']) {
        app.appearance.set('theme', theme);
        await settle();
        final button = find.byTooltip('文件选项');
        await t.tapAt(t.getCenter(button), kind: PointerDeviceKind.mouse);
        await t.pump();
        await t.pump(const Duration(milliseconds: 40));
        final entrance = opacity();
        evidence['$theme-menu-enter-opacity'] = entrance;
        expect(entrance, inExclusiveRange(0, 1));
        await shot('$theme-menu-enter');
        await settle();
        final surface = t.getRect(find.byType(FloatingSurface));
        expect(surface.top, closeTo(t.getRect(button).bottom + 4, .1));
        final rows = find.byType(WorkbenchMenuEntry<String>);
        for (final element in rows.evaluate()) {
          expect(t.getSize(find.byWidget(element.widget)).height, 32);
        }
        expect(
          t.getTopLeft(find.text('新建文件夹…')).dx,
          t.getTopLeft(find.text('显示隐藏文件')).dx,
        );
        await shot('$theme-files-menu');
        await click(find.text('显示隐藏文件'));
        await click(button);
        expect(
          t
              .widget<WorkbenchMenuEntry<String>>(
                find.ancestor(of: find.text('显示隐藏文件'), matching: rows),
              )
              .item,
          isA<CheckedPopupMenuItem<String>>(),
        );
        await shot('$theme-files-checked');
        await t.tapAt(
          t.getCenter(find.text('新建文件夹…')),
          kind: PointerDeviceKind.mouse,
        );
        await t.pump();
        await t.pump(const Duration(milliseconds: 25));
        evidence['$theme-menu-exit-opacity'] = opacity();
        expect(find.byType(AlertDialog), findsNothing);
        await shot('$theme-menu-exit');
        await t.pump(const Duration(milliseconds: 85));
        await t.pump();
        await t.pump(const Duration(milliseconds: 40));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(FloatingSurface), findsNothing);
        await shot('$theme-dialog-enter');
        await settle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(FloatingSurface), findsNothing);
        await t.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '合成目录名称',
        );
        await settle(2);
        await shot('$theme-text-dialog');
        await click(find.text('取消'));
        expect(document.text, '// unsaved UI review draft\n');
        expect(
          t.widget<CodeEditor>(find.byType(CodeEditor)).controller,
          same(editor),
        );
      }
      await click(find.byTooltip('工作台菜单'));
      await shot('light-workbench-menu');
      await escape();
      await click(find.byTooltip('文件选项'));
      window.resize(const Size(760, 640));
      await settle();
      final rect = t.getRect(find.byType(FloatingSurface));
      final size = t.view.physicalSize / t.view.devicePixelRatio;
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(size.width - 8));
      expect(rect.bottom, lessThanOrEqualTo(size.height - 8));
      await shot('light-narrow-menu');
      await escape();
      window.resize(const Size(1440, 960));
      await settle();
      app.appearance.set('uiScale', 1.5);
      await settle();
      // Medium layouts deliberately collapse the sidebar on entry.
      if (find.byTooltip('文件选项').hitTestable().evaluate().isEmpty) {
        await click(find.byTooltip('显示或隐藏侧栏（Ctrl+B）'));
      }
      await click(find.byTooltip('文件选项'));
      await shot('light-150-menu');
      await escape();
      expect(document.dirty, isTrue);
      editor.undo();
      await settle();
      expect(document.text, original);
      editor.redo();
      await settle();
      expect(document.text, '// unsaved UI review draft\n');
      expect(link.terminalStreams, hasLength(1));
      evidence['retained-draft-undo-redo-and-terminal'] = true;
      await app.appearance.flush();
      await ws.flushViews();
      // A separate synthetic host exercises the platform reduced-motion policy.
      await t.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: WorkbenchMenuButton<int>(
                  tooltip: '减少动画菜单',
                  itemBuilder: (_) => const [
                    CheckedPopupMenuItem(
                      value: 1,
                      checked: true,
                      child: Text('减少动画已启用'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await settle();
      await t.tapAt(
        t.getCenter(find.byTooltip('减少动画菜单')),
        kind: PointerDeviceKind.mouse,
      );
      await t.pump();
      await t.pump();
      expect(
        ModalRoute.of(t.element(find.text('减少动画已启用')))!.animation!.value,
        1,
      );
      await shot('reduced-motion');
      await escape();
      evidence['reduced-motion-immediate'] = true;
      await File('$output-results.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    } finally {
      await app.appearance.flush();
      if (workspace != null && find.byType(Shell).evaluate().isNotEmpty) {
        await workspace.flushViews();
      }
      await t.pumpWidget(const SizedBox());
      app.dispose();
      features.dispose();
      window?.restore();
    }
  });
}
