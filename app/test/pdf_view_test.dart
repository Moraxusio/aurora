import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/files/pdf_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/overlays.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:aurora/features/files/remote_bytes.dart';

import 'support/test_pdf.dart';
import 'support/workspace_fixture.dart';
import 'support/range_server.dart';

void main() {
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  setUp(() {
    resetPdfReaderMemory();
    app = WorkspaceApp(wire: FileTreeLink());
    app.data.servers.single.selectedWorkspace = 'a';
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
    // pdfrx asks path_provider for a cache folder; there is no plugin in a test host
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  /// PDFium works on its own isolate: give real time, then draw frames.
  Future<void> work(WidgetTester t, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> show(WidgetTester t, Server srv) async {
    t.view.physicalSize = const Size(1100, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: PdfFileViewer(
              ws: ws,
              root: 'home',
              path: '/doc.pdf',
              opener: srv.open,
            ),
          ),
        ),
      ),
    );
    await work(t);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  }

  PdfViewerController controller(WidgetTester t) =>
      t.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
  Offset documentPoint(WidgetTester t, Offset point) =>
      t.getTopLeft(find.byKey(const ValueKey('pdf-reading-surface'))) +
      controller(t).documentToLocal(point);

  testWidgets(
    'mouse selection, hand dragging and temporary space pan remain distinct',
    (t) async {
      await show(t, Server(buildTestPdf(pages: 5)));
      final c = controller(t), page = controller(t).layout.pageLayouts.first;
      final start = documentPoint(t, page.topLeft + const Offset(73, 83));
      final end = documentPoint(t, page.topLeft + const Offset(220, 83));
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: start);
      await t.pump();
      await mouse.down(start);
      await mouse.moveTo(end);
      await mouse.up();
      await work(t, rounds: 5);
      expect(c.textSelectionDelegate.selectedTextIfLoaded, contains('Page'));
      final before = c.centerPosition;
      await t.tap(find.byKey(const ValueKey('pdf-mode-hand')));
      await t.pump();
      await t.dragFrom(
        t.getCenter(find.byKey(const ValueKey('pdf-reading-surface'))),
        const Offset(0, -130),
        kind: PointerDeviceKind.mouse,
      );
      await work(t, rounds: 3);
      expect(c.centerPosition.dy, greaterThan(before.dy + 30));
      await t.sendKeyEvent(LogicalKeyboardKey.keyV);
      await t.pump();
      expect(
        t.widget<PdfViewer>(find.byType(PdfViewer)).params.panEnabled,
        isFalse,
      );
      await t.sendKeyDownEvent(LogicalKeyboardKey.space);
      await t.pump();
      expect(
        t.widget<PdfViewer>(find.byType(PdfViewer)).params.panEnabled,
        isTrue,
      );
      await t.sendKeyUpEvent(LogicalKeyboardKey.space);
      await t.pump();
      expect(
        t.widget<PdfViewer>(find.byType(PdfViewer)).params.panEnabled,
        isFalse,
      );
      await mouse.removePointer();
      await close(t);
    },
  );

  testWidgets(
    'wheel scroll, control zoom and first touch drag work without switching tools',
    (t) async {
      await show(t, Server(buildTestPdf(pages: 5)));
      final c = controller(t),
          surface = find.byKey(const ValueKey('pdf-reading-surface'));
      final center = t.getCenter(surface), initial = c.centerPosition;
      final zoom = c.currentZoom;
      t.binding.handlePointerEvent(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 160)),
      );
      await t.pump();
      expect(c.centerPosition.dy, greaterThan(initial.dy + 50));
      expect(c.currentZoom, closeTo(zoom, .01));
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      t.binding.handlePointerEvent(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, -120),
        ),
      );
      await t.pump();
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(c.currentZoom, greaterThan(zoom));
      final beforeTouch = c.centerPosition;
      // A real finger drag crosses frames: the first down switches the input
      // device before the following move, rather than batching an entire
      // down/move/up into a single synthetic frame.
      final finger = await t.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await t.pump(const Duration(milliseconds: 16));
      await finger.moveBy(const Offset(0, -50));
      await t.pump(const Duration(milliseconds: 16));
      await finger.moveBy(const Offset(0, -100));
      await t.pump(const Duration(milliseconds: 16));
      await finger.up();
      await work(t, rounds: 3);
      expect(c.centerPosition.dy, greaterThan(beforeTouch.dy + 30));
      final touchZoom = c.currentZoom;
      final a = await t.startGesture(center - const Offset(50, 0), pointer: 11);
      final b = await t.startGesture(center + const Offset(50, 0), pointer: 12);
      await t.pump();
      await a.moveBy(const Offset(-45, 0));
      await b.moveBy(const Offset(45, 0));
      await t.pump();
      await a.up();
      await b.up();
      await work(t, rounds: 2);
      expect(c.currentZoom, greaterThan(touchZoom));
      final trackpad = await t.createGesture(kind: PointerDeviceKind.trackpad);
      final beforeTrackpad = c.centerPosition;
      await trackpad.panZoomStart(center);
      await t.pump();
      await trackpad.panZoomUpdate(center, pan: const Offset(0, -60));
      await t.pump();
      await trackpad.panZoomUpdate(center, pan: const Offset(0, -150));
      await t.pump();
      await trackpad.panZoomEnd();
      await work(t, rounds: 2);
      expect(c.centerPosition.dy, greaterThan(beforeTrackpad.dy));
      await close(t);
    },
  );

  testWidgets(
    'facing pages, navigation history and session bookmarks survive reopening in a narrow pane',
    (t) async {
      final srv = Server(buildTestPdf(pages: 5));
      await show(t, srv);
      await t.enterText(find.byKey(const ValueKey('pdf-page')), '4');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await work(t, rounds: 5);
      await t.tap(find.byTooltip('返回上一阅读位置（Alt+←）'));
      await work(t, rounds: 3);
      expect(controller(t).pageNumber, 1);
      await t.tap(find.byTooltip('前进阅读位置（Alt+→）'));
      await work(t, rounds: 3);
      expect(controller(t).pageNumber, 4);
      await t.tap(find.byKey(const ValueKey('pdf-reader-menu')));
      await t.pumpAndSettle();
      await t.tap(
        find.ancestor(
          of: find.text('标记当前页（Ctrl+D）'),
          matching: find.byType(WorkbenchMenuEntry<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pdf-reader-menu')));
      await t.pumpAndSettle();
      await t.tap(
        find.ancestor(
          of: find.text('双页阅读 · 封面独立'),
          matching: find.byType(WorkbenchMenuEntry<String>),
        ),
      );
      await work(t, rounds: 6);
      final pages = controller(t).layout.pageLayouts;
      expect(pages[1].top, pages[2].top);
      expect(pages[1].right, lessThan(pages[2].left));
      expect(pages.first.bottom, lessThan(pages[1].top));
      await close(t);
      await show(t, srv);
      expect(
        controller(t).layout.pageLayouts[1].top,
        controller(t).layout.pageLayouts[2].top,
      );
      t.view.physicalSize = const Size(390, 800);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('pdf-reader-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('阅读标记 · 本次会话'));
      await t.pumpAndSettle();
      await work(t, rounds: 3);
      expect(find.byKey(const ValueKey('pdf-bookmark-4')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pdf-bookmark-4')));
      await work(t, rounds: 3);
      expect(find.byKey(const ValueKey('pdf-side-2')), findsNothing);
      expect(t.takeException(), isNull);
      await close(t);
    },
  );

  testWidgets('search options distinguish case and whole words', (t) async {
    await show(
      t,
      Server(buildTestPdf(pages: 2, extra: 'alpha Alpha alphabet')),
    );
    await t.tap(find.byTooltip('搜索（Ctrl+F）'));
    await t.pump();
    await t.enterText(find.byKey(const ValueKey('pdf-search')), 'alpha');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await work(t, rounds: 8);
    expect(find.text('1 / 6'), findsOneWidget);
    await t.tap(find.text('全词匹配'));
    await work(t, rounds: 8);
    expect(find.text('1 / 4'), findsOneWidget);
    await t.tap(find.text('区分大小写'));
    await work(t, rounds: 8);
    expect(find.text('1 / 2'), findsOneWidget);
    await close(t);
  });

  testWidgets('a PDF opens, shows its page count, and the page box jumps', (
    t,
  ) async {
    final srv = Server(buildTestPdf(pages: 5));
    await show(t, srv);
    expect(find.text('/ 5'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-zoom')), findsOneWidget);
    expect(
      srv.requests.length,
      1,
      reason: 'a small file is one block: opening it asked the server once',
    );

    await t.enterText(find.byKey(const ValueKey('pdf-page')), '4');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await work(t);
    expect(
      (t.widget(
        find.byKey(const ValueKey('pdf-page')),
      ) as TextField).controller!.text,
      '4',
    );
    await close(t);
  });

  testWidgets(
    'the side bar lists the outline and a click jumps to that chapter',
    (t) async {
      final srv = Server(buildTestPdf(pages: 3));
      await show(t, srv);
      await t.tap(find.byTooltip('目录和缩略图'));
      await work(t, rounds: 6);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Chapter 3'), findsOneWidget);
      await t.tap(find.text('Chapter 3'));
      await work(t);
      expect(
        (t.widget(
          find.byKey(const ValueKey('pdf-page')),
        ) as TextField).controller!.text,
        '3',
      );

      await t.tap(find.byKey(const ValueKey('pdf-side-1')));
      await work(t, rounds: 6);
      expect(find.byKey(const ValueKey('pdf-thumb-2')), findsOneWidget);
      await close(t);
    },
  );

  testWidgets('a PDF without an outline says so', (t) async {
    final srv = Server(buildTestPdf(pages: 2, outline: false));
    await show(t, srv);
    await t.tap(find.byTooltip('目录和缩略图'));
    await work(t, rounds: 6);
    expect(find.text('这个 PDF 没有目录'), findsOneWidget);
    await close(t);
  });

  testWidgets(
    'search finds the words, counts the matches and steps through them',
    (t) async {
      final srv = Server(buildTestPdf(pages: 4, extra: 'needle here'));
      await show(t, srv);
      await t.tap(find.byTooltip('搜索（Ctrl+F）'));
      await work(t, rounds: 2);
      await t.enterText(find.byKey(const ValueKey('pdf-search')), 'needle');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await work(t, rounds: 20);
      expect(
        find.text('1 / 4'),
        findsOneWidget,
        reason: 'one match on each of the four pages',
      );
      await t.tap(find.byTooltip('下一个'));
      await work(t, rounds: 8);
      expect(find.text('2 / 4'), findsOneWidget);

      await t.enterText(find.byKey(const ValueKey('pdf-search')), 'zebra');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await work(t, rounds: 20);
      expect(find.text('没有结果'), findsOneWidget);

      await t.tap(find.byTooltip('关闭搜索（Esc）'));
      await work(t, rounds: 2);
      expect(find.byKey(const ValueKey('pdf-search')), findsNothing);
      await close(t);
    },
  );

  testWidgets(
    'a file that is not a PDF is explained, with retry and download',
    (t) async {
      final srv = Server(
        Uint8List.fromList(utf8.encode('<html>login page</html>')),
      );
      await show(t, srv);
      expect(find.textContaining('不是有效的 PDF'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      await close(t);
    },
  );

  testWidgets('an empty file is said to be empty', (t) async {
    final srv = Server(Uint8List(0));
    await show(t, srv);
    expect(find.textContaining('空文件'), findsOneWidget);
    await close(t);
  });

  testWidgets('a failing server shows the error and retry works', (t) async {
    var fail = true;
    final good = Server(buildTestPdf(pages: 2));
    Future<DownloadStream> open(String r, String p, int o, int l) async {
      if (fail) throw Exception('网络断了');
      return good.open(r, p, o, l);
    }

    t.view.physicalSize = const Size(1100, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: PdfFileViewer(
              ws: ws,
              root: 'home',
              path: '/doc.pdf',
              opener: open,
            ),
          ),
        ),
      ),
    );
    await work(t, rounds: 3);
    expect(find.textContaining('网络断了'), findsOneWidget);
    fail = false;
    await t.tap(find.text('重试'));
    await work(t);
    expect(find.text('/ 2'), findsOneWidget);
    await close(t);
  });

  testWidgets(
    'a bigger PDF is fetched completely first, with progress, then opens',
    (t) async {
      // a PDF of about 1.2 MB (three blocks of 512 KiB): small enough to be fetched completely first
      final bytes = buildTestPdf(pages: 2, padBytes: pdfChunkForTest * 2 + 100);
      expect(bytes.length, greaterThan(pdfChunkForTest * 2));
      final srv = Server(bytes);
      await show(t, srv);
      await work(t, rounds: 30);
      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .toList();
      expect(
        srv.requests.length,
        3,
        reason: 'every block was fetched exactly once before the viewer opened',
      );
      expect(find.text('/ 2'), findsOneWidget, reason: 'screen shows $texts');
      await close(t);
    },
  );
}

const pdfChunkForTest = 512 * 1024;
