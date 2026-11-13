import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/ai/ai_attachments.dart';
import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_feature_test.dart' show FakeAiLink;
import 'support/workspace_fixture.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJZkAAAAASUVORK5CYII=',
);

class _Upload extends Fake implements OpStream {
  final chunks = <Uint8List>[];
  int responses = 0;
  bool ended = false;
  @override
  Future<Object?> response() async => responses++ == 0 ? null : {'id': 'att_0123456789abcdef01234567'};
  @override
  Future<void> sendData(List<int> data) async {
    chunks.add(Uint8List.fromList(data));
  }

  @override
  Future<void> sendEnd() async {
    ended = true;
  }

  @override
  void reset() {}
}

class _Download extends Fake implements OpStream {
  int index = 0;
  final Uint8List bytes = Uint8List.fromList(utf8.encode('fixture server file'));
  @override
  Future<Object?> response() async => {'size': bytes.length, 'name': 'README.md'};
  @override
  Future<Frame?> read() async => index++ == 0 ? Frame(typeData, bytes) : Frame(typeEnd, Uint8List(0));
  @override
  void reset() {}
}

class _InputLink extends FakeAiLink {
  final upload = _Upload();
  @override
  Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async {
    if (op == 'ai.attach.upload') {
      rpcCalls.add((op, (args as Map).cast<String, dynamic>()));
      return upload;
    }
    if (op == 'fs.download') return _Download();
    return super.open(op, args, priority);
  }
}

void main() {
  late _InputLink link;
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  Map<String, Object?> clipboard = {};
  setUp(() async {
    link = _InputLink();
    app = WorkspaceApp(wire: link);
    await app.update((p) {
      p.ai.providers.add(AiProvider(id: 'fixture', name: 'Fixture', model: 'vision-fixture'));
      p.servers.single.selectedWorkspace = 'a';
    });
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('aurora3/input'),
      (call) async => call.method == 'readClipboard' ? clipboard : null,
    );
  });
  tearDown(() {
    ws.dispose();
    app.dispose();
    input.dispose();
    clipboard = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('aurora3/input'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(body: AiStudioView(ws: ws)),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> paste(WidgetTester t, {bool focus = true}) async {
    if (focus) await t.tap(find.byKey(const ValueKey('ai-prompt-input')));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump(const Duration(milliseconds: 100));
  }

  test('attachment sniffing rejects oversized, binary and credential files', () {
    expect(aiAttachmentFromBytes('screenshot.png', _png).mime, 'image/png');
    expect(aiAttachmentFromBytes('a.dart', Uint8List.fromList(utf8.encode('中文 code'))).mime, 'text/plain');
    expect(() => aiAttachmentFromBytes('id_ed25519', Uint8List.fromList([1, 2, 3])), throwsStateError);
    expect(() => aiAttachmentFromBytes('file.bin', Uint8List.fromList([0, 1, 0])), throwsStateError);
    expect(() => aiAttachmentFromBytes('large.png', Uint8List(aiAttachmentLimit + 1)), throwsStateError);
  });
  test('large attachments use bounded data frames and tiny run references', () async {
    final bytes = Uint8List.fromList([...utf8.encode('%PDF-1.7\n'), ...List.filled(1500000, 65)]);
    final attachment = aiAttachmentFromBytes('large.pdf', bytes);
    final ref = await uploadAiAttachment(link, attachment, active: () => true);
    expect(link.upload.chunks.length, greaterThan(20));
    expect(link.upload.chunks.every((b) => b.length <= 65536), isTrue);
    expect(link.upload.chunks.fold<int>(0, (n, b) => n + b.length), bytes.length);
    expect(jsonEncode(ref).length, lessThan(250));
    expect(link.upload.ended, isTrue);
  });
  testWidgets('Ctrl+V pastes image, upload precedes run and JSON never embeds image bytes', (t) async {
    clipboard = {'name': 'screen.png', 'bytes': _png};
    await pump(t);
    await paste(t);
    expect(find.textContaining('screen.png'), findsOneWidget);
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.attach.upload'), isEmpty, reason: 'paste must not upload until send');
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), '解释图片');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await t.pump(const Duration(milliseconds: 300));
    final run = link.rpcCalls.where((c) => c.$1 == 'ai.run').single.$2;
    expect((run['attachments'] as List).single['attachment_id'], 'att_0123456789abcdef01234567');
    expect(jsonEncode(run), isNot(contains('iVBOR')));
    expect(
      link.rpcCalls.indexWhere((c) => c.$1 == 'ai.attach.upload'),
      lessThan(link.rpcCalls.indexWhere((c) => c.$1 == 'ai.run')),
    );
  });
  testWidgets('plain clipboard text replaces selection instead of opening a path', (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': r'C:\example\text.txt'} : null,
    );
    await pump(t);
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'old');
    final field = t.widget<TextField>(find.byKey(const ValueKey('ai-prompt-input')));
    field.controller!.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await paste(t, focus: false);
    expect(field.controller!.text, r'C:\example\text.txt');
    expect(link.rpcCalls.where((c) => c.$1 == 'fs.download'), isEmpty);
  });
  test('clipboard copied files are read only after explicit paste', () async {
    final directory = await Directory.systemTemp.createTemp('aurora-paste-fixture-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fixture.dart');
    await file.writeAsString('void main() {}');
    clipboard = {
      'paths': [file.path],
    };
    final files = await readAiClipboardFiles();
    expect(files.single.label, 'fixture.dart');
    expect(utf8.decode(files.single.bytes!), 'void main() {}');
  });
  testWidgets('workdir dropdown browses folders without a typed path', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('ai-workdir-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('浏览服务器目录…'));
    await t.pumpAndSettle();
    expect(find.text('选择会话工作目录'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ai-path-src')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ai-select-directory')));
    await t.pumpAndSettle();
    expect(find.textContaining('/project/src'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'hello');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await t.pump(const Duration(milliseconds: 300));
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.run').single.$2['workdir'], '/project/src');
  });
  testWidgets('file browser attaches remote file without asking for a path', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('ai-attach-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('浏览服务器文件…'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ai-path-README.md')));
    await t.pumpAndSettle();
    expect(find.textContaining('README.md'), findsOneWidget);
  });
  testWidgets('Enter while composing Chinese does not send an incomplete prompt', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('ai-prompt-input')));
    t.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.run'), isEmpty);
  });
  testWidgets('chat font menu persists its selection in sealed-profile settings', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('ai-chat-font')));
    await t.pumpAndSettle();
    await t.tap(find.text('舒适 · 17'));
    await t.pumpAndSettle();
    expect(app.profile.ai.chatFontSize, 17);
  });
}
