import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/files/pdf_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  /// PDFium works on its own isolate: give real time, then draw frames.
  Future<void> work(WidgetTester t, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> show(WidgetTester t, Server srv) async {
    t.view.physicalSize = const Size(1100, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: InputMode.scope(mode: input, child: Scaffold(body: PdfFileViewer(ws: ws, root: 'home', path: '/doc.pdf', opener: srv.open))),
    ));
    await work(t);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  }

  testWidgets('a PDF opens, shows its page count, and the page box jumps', (t) async {
    final srv = Server(buildTestPdf(pages: 5));
    await show(t, srv);
    expect(find.text('/ 5'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-zoom')), findsOneWidget);
    expect(srv.requests.length, 1, reason: 'a small file is one block: opening it asked the server once');

    await t.enterText(find.byKey(const ValueKey('pdf-page')), '4');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await work(t);
    expect((t.widget(find.byKey(const ValueKey('pdf-page'))) as TextField).controller!.text, '4');
    await close(t);
  });

  testWidgets('the side bar lists the outline and a click jumps to that chapter', (t) async {
    final srv = Server(buildTestPdf(pages: 3));
    await show(t, srv);
    await t.tap(find.byTooltip('目录和缩略图'));
    await work(t, rounds: 6);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 3'), findsOneWidget);
    await t.tap(find.text('Chapter 3'));
    await work(t);
    expect((t.widget(find.byKey(const ValueKey('pdf-page'))) as TextField).controller!.text, '3');

    await t.tap(find.byKey(const ValueKey('pdf-side-1')));
    await work(t, rounds: 6);
    expect(find.byKey(const ValueKey('pdf-thumb-2')), findsOneWidget);
    await close(t);
  });

  testWidgets('a PDF without an outline says so', (t) async {
    final srv = Server(buildTestPdf(pages: 2, outline: false));
    await show(t, srv);
    await t.tap(find.byTooltip('目录和缩略图'));
    await work(t, rounds: 6);
    expect(find.text('这个 PDF 没有目录'), findsOneWidget);
    await close(t);
  });

  testWidgets('search finds the words, counts the matches and steps through them', (t) async {
    final srv = Server(buildTestPdf(pages: 4, extra: 'needle here'));
    await show(t, srv);
    await t.tap(find.byTooltip('搜索（Ctrl+F）'));
    await work(t, rounds: 2);
    await t.enterText(find.byKey(const ValueKey('pdf-search')), 'needle');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await work(t, rounds: 20);
    expect(find.text('1 / 4'), findsOneWidget, reason: 'one match on each of the four pages');
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
  });

  testWidgets('a file that is not a PDF is explained, with retry and download', (t) async {
    final srv = Server(Uint8List.fromList(utf8.encode('<html>login page</html>')));
    await show(t, srv);
    expect(find.textContaining('不是有效的 PDF'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    await close(t);
  });

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
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: InputMode.scope(mode: input, child: Scaffold(body: PdfFileViewer(ws: ws, root: 'home', path: '/doc.pdf', opener: open))),
    ));
    await work(t, rounds: 3);
    expect(find.textContaining('网络断了'), findsOneWidget);
    fail = false;
    await t.tap(find.text('重试'));
    await work(t);
    expect(find.text('/ 2'), findsOneWidget);
    await close(t);
  });

  testWidgets('a bigger PDF is fetched completely first, with progress, then opens', (t) async {
    // a PDF of about 1.2 MB (three blocks of 512 KiB): small enough to be fetched completely first
    final bytes = buildTestPdf(pages: 2, padBytes: pdfChunkForTest * 2 + 100);
    expect(bytes.length, greaterThan(pdfChunkForTest * 2));
    final srv = Server(bytes);
    await show(t, srv);
    await work(t, rounds: 30);
    final texts = t.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList();
    expect(srv.requests.length, 3, reason: 'every block was fetched exactly once before the viewer opened');
    expect(find.text('/ 2'), findsOneWidget, reason: 'screen shows $texts');
    await close(t);
  });
}

const pdfChunkForTest = 512 * 1024;
