import 'dart:ui' as ui;

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/files/file_preview.dart';
import 'package:aurora/features/files/file_viewers.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/fake_download.dart';
import 'support/workspace_fixture.dart';

/// fs.read answers with the text the test sets, like the agent would.
class TextLink extends FileTreeLink {
  String content = '';
  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    if (op == 'fs.read') return {'content': content, 'etag': 'fixture-etag', 'size': content.length};
    return super.call(op, args, timeout);
  }
}

void main() {
  late TextLink link;
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  setUp(() {
    link = TextLink();
    app = WorkspaceApp(wire: link);
    app.data.servers.single.selectedWorkspace = 'a';
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
  });
  tearDown(() async {
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  Future<void> show(WidgetTester t, Widget w) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: InputMode.scope(mode: input, child: Scaffold(body: SizedBox(width: 800, height: 600, child: w))),
    ));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  // Dispose the editor and let its cursor/blink timers run out.
  Future<void> settle(WidgetTester t) async {
    FocusManager.instance.primaryFocus?.unfocus(); // stops the cursor blink timer
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  }

  testWidgets('each kind of file gets its own tab view', (t) async {
    Widget viewOf(String path) {
      final tab = fileEditorTab(ws, root: 'home', path: path);
      return Builder(builder: tab.builder);
    }

    await show(t, viewOf('/media/clip.mp4'));
    expect(find.byType(MediaUnsupported), findsOneWidget);
    expect(find.textContaining('视频'), findsOneWidget);

    await show(t, viewOf('/media/song.mp3'));
    expect(find.byType(MediaUnsupported), findsOneWidget);
    expect(find.textContaining('音频'), findsOneWidget);

    await show(t, viewOf('/etc/hosts'));
    expect(find.byType(FileEditor), findsOneWidget);
    await show(t, viewOf('/a/photo.png'));
    expect(find.byType(ImageViewer), findsOneWidget);
    await show(t, viewOf('/a/paper.pdf'));
    expect(find.byType(PdfFileViewer), findsOneWidget);
  });

  testWidgets('markdown: preview follows unsaved edits, the editor keeps them', (t) async {
    link.content = '# Title\n\nhello\n';
    final key = GlobalKey<FileEditorState>();
    await show(t, FileEditor(key: key, ws: ws, root: 'home', path: '/project/README.md'));
    expect(find.byType(MarkdownPreview), findsNothing);

    key.currentState!.text = '# Changed\n\nunsaved\n';
    final editorState = t.state(find.byType(CodeEditor)); // must survive the round trip
    await t.tap(find.byType(CodeEditor)); await t.pump();
    final editorFocus = FocusManager.instance.primaryFocus!;
    await t.tap(find.text('预览'));
    await t.pump();
    expect(find.byType(MarkdownPreview), findsOneWidget);
    expect(t.getSize(find.byType(MarkdownPreview)).height, greaterThan(500), reason: 'the hidden editor must not consume half the viewport');
    expect(find.byType(Markdown), findsOneWidget);
    expect(find.text('Changed', findRichText: true), findsOneWidget);
    expect(find.text('Title', findRichText: true), findsNothing); // the saved text is not what shows
    expect(key.currentState!.dirty, isTrue);
    expect(editorFocus.canRequestFocus, isFalse, reason: 'the hidden source editor must not receive traversal or typing');

    await t.tap(find.text('编辑'));
    await t.pump();
    expect(find.byType(MarkdownPreview), findsNothing);
    expect(key.currentState!.text, '# Changed\n\nunsaved\n'); // nothing lost by looking
    expect(identical(t.state(find.byType(CodeEditor)), editorState), isTrue, reason: 'the editor was rebuilt, losing scroll and cursor');
    await settle(t);
  });

  testWidgets('markdown preview never loads a picture or opens a link', (t) async {
    await show(t, const SizedBox());
    await show(t, const MarkdownPreview(text: '![logo](https://example.invalid/x.png)\n\n[site](https://example.invalid)'));
    expect(find.textContaining('图片未加载'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('csv opens as a table with row and column counts', (t) async {
    link.content = 'name,qty\napple,3\npear,5\n';
    await show(t, FileEditor(ws: ws, root: 'home', path: '/project/data.csv'));
    await t.tap(find.text('表格'));
    await t.pump();
    expect(find.byType(CsvPreview), findsOneWidget);
    expect(find.text('2 行 · 2 列'), findsOneWidget);
    expect(find.text('apple'), findsOneWidget);
    expect(find.text('qty'), findsOneWidget);
    await settle(t);
  });

  testWidgets('a plain text file has no preview switch', (t) async {
    link.content = 'just text\n';
    await show(t, FileEditor(ws: ws, root: 'home', path: '/etc/hosts'));
    expect(find.text('预览'), findsNothing);
    expect(find.text('表格'), findsNothing);
  });

  testWidgets('an image is downloaded, decoded and shown with its size', (t) async {
    final png = await t.runAsync(() async {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 4, 3), ui.Paint()..color = const ui.Color(0xFFFF0000));
      final img = await rec.endRecording().toImage(4, 3);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return bd!.buffer.asUint8List();
    });
    await show(t, ImageViewer(ws: ws, root: 'home', path: '/a/dot.png', opener: (_, _) async => FakeDownload.of(png!)));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.textContaining('4 × 3'), findsOneWidget);
  });

  testWidgets('a broken image says so and offers a download', (t) async {
    await show(t, ImageViewer(ws: ws, root: 'home', path: '/a/bad.png', opener: (_, _) async => FakeDownload.of([1, 2, 3, 4])));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('无法显示这张 PNG 图片'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
  });

  testWidgets('an over-size image is refused with a message, not loaded', (t) async {
    final big = FakeDownload({'length': imageMaxBytes + 1, 'size': imageMaxBytes + 1}, [data([1])]);
    await show(t, ImageViewer(ws: ws, root: 'home', path: '/a/huge.png', opener: (_, _) async => big));
    expect(find.textContaining('超过在线查看的上限'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(big.reads, 0);
  });

  testWidgets('a failed read offers retry and download', (t) async {
    await show(t, ImageViewer(ws: ws, root: 'home', path: '/a/x.png', opener: (_, _) async => throw OpError(codeNotFound, '文件不存在')));
    expect(find.text('文件不存在'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
