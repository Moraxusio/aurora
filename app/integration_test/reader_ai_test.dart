import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/features/ai/ai_model_picker.dart';
import 'package:aurora/features/ai/ai_settings_dialog.dart';
import 'package:aurora/features/files/pdf_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/overlays.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../test/ai_runtime_test.dart' show RuntimeLink;
import '../test/support/range_server.dart';
import '../test/support/test_pdf.dart';
import '../test/support/workspace_fixture.dart';
import 'native_window.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native reader and retained AI work views, dark and light', (
    t,
  ) async {
    const output = String.fromEnvironment('AURORA_REVIEW_OUT');
    expect(output, isNotEmpty);
    // The live integration binding leaves platform text input enabled. Register
    // the synthetic channel before enterText so the draft is actually entered.
    t.testTextInput.register();
    addTearDown(t.testTextInput.unregister);
    NativeTestWindow? window;
    final link = RuntimeLink();
    final app = WorkspaceApp(
      wire: link,
      profile: Profile(
        servers: [ServerEntry(id: 'server', name: 'fixture')],
        selected: 'server',
        ai: AiSettings(
          providers: [
            AiProvider(
              id: 'synthetic',
              name: 'Preview provider',
              model: 'preview-model',
              models: ['preview-model', 'review-model'],
            ),
          ],
        ),
      ),
    );
    final ws = Workspace(app, 'server'), input = InputMode(touch: false);
    final pdf = Server(
      buildTestPdf(pages: 8, extra: 'Aurora reader - alpha Alpha alphabet'),
    );
    final boundary = GlobalKey(), panel = GlobalKey();
    var brightness = Brightness.dark;
    Future<void> settle([int count = 8]) async {
      for (var i = 0; i < count; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(t.takeException(), isNull);
    }

    Widget host() => RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: PdfFileViewer(
                    ws: ws,
                    root: 'home',
                    path: '/preview.pdf',
                    opener: pdf.open,
                  ),
                ),
                SizedBox(
                  width: 440,
                  child: AiStudioView(
                    key: panel,
                    ws: ws,
                    initialSessionId: 'ses_1',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Future<void> shot(String name) async {
      await settle(3);
      final image = await t
          .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output-$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    try {
      await t.pumpWidget(host());
      await settle(24);
      window = NativeTestWindow();
      window.resize(const Size(1440, 960));
      await settle();
      expect(find.text('/ 8'), findsOneWidget);
      final c = t.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
      await t.tap(find.byKey(const ValueKey('pdf-mode-hand')));
      await settle(2);
      final before = c.centerPosition;
      await t.dragFrom(
        t.getCenter(find.byKey(const ValueKey('pdf-reading-surface'))),
        const Offset(0, -140),
        kind: PointerDeviceKind.mouse,
      );
      await settle(4);
      expect(c.centerPosition.dy, greaterThan(before.dy));
      await t.tap(find.byKey(const ValueKey('pdf-reader-menu')));
      await settle(3);
      await t.tap(
        find.ancestor(
          of: find.text('双页阅读 · 封面独立'),
          matching: find.byType(WorkbenchMenuEntry<String>),
        ),
      );
      await settle();
      expect(c.layout.pageLayouts[1].top, c.layout.pageLayouts[2].top);
      await t.tap(find.byTooltip('目录和缩略图'));
      await settle();
      await t.tap(find.text('Chapter 2'));
      await settle();
      link.events.emit({
        'type': 'tool.running',
        'tool_call_id': 'task',
        'tool_name': 'subagent',
        'input': {'description': '检查项目结构'},
        'metadata': {'child_session_id': 'child-1'},
      });
      link.events.emit({
        'type': 'tool.running',
        'tool_call_id': 'build',
        'tool_name': 'shell',
        'input': {'command': 'pwsh -NoProfile -Command build'},
      });
      link.events.emit({
        'type': 'tool.progress',
        'tool_call_id': 'build',
        'delta': 'Building Aurora…\nResolving modules\n42 files checked\nWaiting for compilation',
      });
      await settle();
      await shot('dark-main');
      await t.enterText(
        find.byKey(const ValueKey('ai-prompt-input')),
        '主对话未发送草稿',
      );
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('ai-prompt-input')))
            .controller!
            .text,
        '主对话未发送草稿',
      );
      await t.tap(find.byKey(const ValueKey('ai-work-tab-ses_1:build')));
      await settle();
      expect(find.text('42 files checked'), findsOneWidget);
      await shot('dark-output');
      await t.tap(find.byKey(const ValueKey('ai-work-list')));
      await settle();
      await t.tap(find.byKey(const ValueKey('ai-work-row-ses_1:task')));
      await settle();
      expect(
        find.text('child conversation reply', findRichText: true),
        findsOneWidget,
      );
      await t.enterText(
        find.byKey(const ValueKey('ai-prompt-input')),
        '子代理未发送草稿',
      );
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('ai-prompt-input')))
            .controller!
            .text,
        '子代理未发送草稿',
      );
      await shot('dark-child');
      await t.tap(find.byKey(const ValueKey('ai-work-main')));
      await settle();
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('ai-prompt-input')))
            .controller!
            .text,
        '主对话未发送草稿',
      );
      await t.tap(find.byKey(const ValueKey('ai-work-list')));
      await settle();
      await t.tap(find.byKey(const ValueKey('ai-work-row-ses_1:task')));
      await settle();
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('ai-prompt-input')))
            .controller!
            .text,
        '子代理未发送草稿',
      );
      await t.tap(find.byKey(const ValueKey('ai-work-main')));
      await settle();
      brightness = Brightness.light;
      await t.pumpWidget(host());
      await settle();
      await shot('light-main');
      final context = panel.currentContext!;
      showAiModelPicker(context, ws);
      await shot('light-models');
      await t.tap(find.byTooltip('关闭'));
      await settle();
      showAiSettingsDialog(panel.currentContext!, app: app, ws: ws);
      await shot('light-settings');
      await t.tap(find.byTooltip('关闭'));
      await settle();
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      input.dispose();
      app.dispose();
      window?.restore();
    }
  });
}
