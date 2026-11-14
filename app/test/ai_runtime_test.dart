import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/features/ai/ai_transcript.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_feature_test.dart' show FakeAiLink;
import 'support/workspace_fixture.dart';

const _runtime = {
  'provider_id': 'old-provider',
  'provider_name': 'ChatGPT 订阅',
  'model': 'gpt-6.1-sol',
  'protocol': 'openai-responses',
  'auth_mode': 'chatgpt-device',
};
const _context = {'tokens': 42000, 'limit': 500000, 'last_input': 40000, 'estimated': true, 'limit_source': 'default'};

class EventStream implements OpStream {
  final controller = StreamController<Frame>();
  late final iterator = StreamIterator(controller.stream);
  @override
  Future<Object?> response() async => null;
  @override
  Future<Frame?> read() async => await iterator.moveNext() ? iterator.current : null;
  @override
  Future<void> sendJson(Object? v) async {}
  @override
  void reset() {
    unawaited(controller.close());
  }

  void emit(Map<String, dynamic> event) =>
      controller.add(Frame(typeJson, Uint8List.fromList(utf8.encode(jsonEncode({'session_id': 'ses_1', ...event})))));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RuntimeLink extends FakeAiLink {
  final events = EventStream();
  final childEvents = <String, EventStream>{};
  OpStream? firstStream;
  Completer<Object?>? rootsGate;
  int opens = 0;
  bool legacy = false;
  bool longHistory = false;
  @override
  Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async {
    final sid = args is Map ? args['session_id'] as String? : null;
    if (op == 'ai.stream' && sid != null && sid != 'ses_1') return childEvents.putIfAbsent(sid, EventStream.new);
    opens++;
    return opens == 1 ? firstStream ?? events : events;
  }
  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    if (op == 'fs.roots' && rootsGate != null) return rootsGate!.future;
    final result = await super.call(op, args, timeout);
    if (op == 'ai.get' && args is Map && args['id'] != 'ses_1') {
      return {'running': false, 'session': {'id': args['id'], 'parent_id': 'ses_1', 'title': '检查本地项目',
        'root': 'home', 'workdir': '/project', 'messages': [
          {'id': 'child-message', 'role': 'assistant', 'parts': [{'type': 'text', 'text': 'child conversation reply'}]},
        ]}};
    }
    if (op == 'ai.get' && !legacy) {
      final session = (result as Map)['session'] as Map;
      session['runtime'] = _runtime;
      session['context'] = _context;
      (session['messages'] as List).last['runtime'] = _runtime;
      if (longHistory) {
        ((session['messages'] as List).first['parts'] as List).first['text'] = List.filled(
          60,
          '较长的历史记录，用于验证向上阅读时不会被新回复拉回底部。',
        ).join('\n');
      }
    }
    return result;
  }
}

class _RejectedEventStream extends EventStream {
  int resets = 0;
  @override Future<Object?> response() async => throw StateError('synthetic stream handshake failure');
  @override void reset() { resets++; super.reset(); }
}

void main() {
  final shots = Platform.environment['AURORA_AI_SHOTS'];
  final shotKey = GlobalKey();
  setUpAll(() async {
    if (shots == null) return;
    for (final entry in <String, List<String>>{
      Ide.ui: [r'C:\Windows\Fonts\SegUIVar.ttf'],
      'Segoe UI': [r'C:\Windows\Fonts\segoeui.ttf'],
      'Microsoft YaHei UI': [r'C:\Windows\Fonts\msyh.ttc'],
      'Cascadia Mono': [r'C:\Windows\Fonts\CascadiaMono.ttf'],
      'Consolas': [r'C:\Windows\Fonts\consola.ttf'],
      'MaterialIcons': [r'C:\dev\VPS\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final path in entry.value) {
        final file = File(path);
        if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      }
      await loader.load();
    }
    Directory(shots).createSync(recursive: true);
  });
  Future<void> snapshot(WidgetTester t, String name) async {
    if (shots == null) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$shots/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  late RuntimeLink link;
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  setUp(() {
    link = RuntimeLink();
    app = WorkspaceApp(
      wire: link,
      profile: Profile(
        servers: [ServerEntry(id: 'server', name: 'fixture')],
        selected: 'server',
        ai: AiSettings(
          providers: [AiProvider(id: 'next-provider', name: '新网关', model: 'new-model')],
        ),
      ),
    );
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
  });
  tearDown(() {
    ws.dispose();
    input.dispose();
    app.dispose();
  });
  Future<void> pump(WidgetTester t, {double width = 1000, Brightness brightness = Brightness.dark, String sessionId = 'ses_1'}) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: AiStudioView(ws: ws, initialSessionId: sessionId),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  String text(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;
  Future<void> expandDetails(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('ai-context-indicator')));
    await t.pump();
  }
  testWidgets('failed event handshake releases stream before retrying the healthy link', (t) async {
    final rejected = _RejectedEventStream();
    link.firstStream = rejected;
    await pump(t);
    expect(rejected.resets, 1);
    expect(find.textContaining('实时状态流中断'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(milliseconds: 100));
    expect(link.opens, 2);
    expect(find.textContaining('实时状态流中断'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('late roots response after closing AI tab cannot reopen streams or setState', (t) async {
    final roots = Completer<Object?>();
    link.rootsGate = roots;
    await pump(t);
    await t.pumpWidget(const SizedBox());
    roots.complete({'roots': <Object>[]});
    await t.pump(const Duration(milliseconds: 100));
    expect(link.opens, 0);
    expect(t.takeException(), isNull);
  });
  testWidgets('actual provider/model differs from next selection and context is not total', (t) async {
    await pump(t);
    expect(find.byKey(const ValueKey('ai-next-model')), findsNothing);
    expect(t.getSize(find.byKey(const ValueKey('ai-runtime-bar'))).height, lessThanOrEqualTo(34));
    await expandDetails(t);
    expect(text(t, 'ai-actual-model'), contains('ChatGPT 订阅 / gpt-6.1-sol'));
    expect(text(t, 'ai-next-model'), contains('新网关 / new-model'));
    expect(text(t, 'ai-context-usage'), contains('42.0k / 500.0k'));
    expect(text(t, 'ai-context-usage'), contains('8.4%'));
    expect(text(t, 'ai-total-usage'), contains('1.5k'));
    expect(find.text('ChatGPT 订阅 / gpt-6.1-sol'), findsOneWidget);
    await snapshot(t, 'ai-runtime-desktop');
  });
  testWidgets('step metadata, duplicate finish and compaction use authoritative state', (t) async {
    await pump(t);
    await expandDetails(t);
    final next = {..._runtime, 'provider_name': 'Step 网关', 'model': 'step-model'};
    link.events.emit({
      'type': 'step.start',
      'runtime': next,
      'context': {..._context, 'tokens': 50000},
    });
    await t.pump();
    expect(text(t, 'ai-actual-model'), contains('Step 网关 / step-model'));
    final finish = <String, dynamic>{
      'type': 'step.finish',
      'runtime': next,
      'context': {..._context, 'tokens': 60000},
      'total_usage': {'total_tokens': 1600},
      'message': {
        'id': 'msg_new',
        'role': 'assistant',
        'runtime': next,
        'parts': [
          {'type': 'text', 'text': 'a reply'},
        ],
        'usage': {'total_tokens': 100},
      },
    };
    link.events.emit(finish);
    link.events.emit(finish);
    await t.pump();
    expect(text(t, 'ai-total-usage'), contains('1.6k'));
    expect(text(t, 'ai-context-usage'), contains('12.0%'));
    final compact = <String, dynamic>{
      'type': 'compaction.done',
      'context': {..._context, 'tokens': 1000, 'last_input': 0},
      'total_usage': {'total_tokens': 1900},
      'message': {
        'id': 'cp',
        'role': 'compaction',
        'parts': [
          {'type': 'compaction', 'text': 'checkpoint'},
        ],
      },
    };
    link.events.emit(compact);
    link.events.emit(compact);
    await t.pump();
    expect(text(t, 'ai-context-usage'), contains('1.0k / 500.0k'));
    expect(text(t, 'ai-total-usage'), contains('1.9k'));
  });
  testWidgets('legacy session never attributes old messages to selected provider', (t) async {
    link.legacy = true;
    await pump(t);
    await expandDetails(t);
    expect(text(t, 'ai-actual-model'), contains('未知提供商'));
    expect(text(t, 'ai-context-usage'), contains('暂无统计'));
    expect(text(t, 'ai-next-model'), contains('新网关'));
  });
  testWidgets('runtime dashboard fits a narrow mobile viewport', (t) async {
    await pump(t, width: 390);
    expect(find.byKey(const ValueKey('ai-runtime-bar')), findsOneWidget);
    await snapshot(t, 'ai-runtime-mobile');
  });
  testWidgets('working shell and child agents show live output and finish independently', (t) async {
    await pump(t);
    link.events.emit({'type':'tool.running','tool_call_id':'parent-task','tool_name':'subagent','input':{'agent':'explore','description':'检查本地项目'},'metadata':{'child_session_id':'child-1'}});
    link.events.emit({'type':'tool.running','session_id':'child-1','root_session_id':'ses_1','session_title':'检查本地项目','tool_call_id':'child-shell','tool_name':'shell','input':{'command':'Get-ChildItem'},'metadata':{'proxy_mode':'environment'}});
    link.events.emit({'type':'tool.progress','session_id':'child-1','root_session_id':'ses_1','tool_call_id':'child-shell','delta':'synthetic live output'});
    await t.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('ai-work-navigation')), findsOneWidget);
    expect(find.text('Get-ChildItem'), findsOneWidget);
    await t.tap(find.text('Get-ChildItem'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
    expect(find.text('synthetic live output'), findsOneWidget);
    await snapshot(t, 'ai-working-agents-desktop');
    link.events.emit({'type':'tool.done','session_id':'child-1','root_session_id':'ses_1','tool_call_id':'child-shell'});
    await t.pump();
    await t.pump();
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('synthetic live output'), findsOneWidget);
    link.events.emit({'type':'tool.done','tool_call_id':'parent-task'});
    await t.pump();
    expect(find.byKey(const ValueKey('ai-work-tab-ses_1:parent-task')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ai-work-main')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('ai-work-tab-child-1:child-shell')));
    await t.pump();
    expect(find.text('synthetic live output'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('main, child and long output keep independent drafts and reading anchors', (t) async {
    link.longHistory = true;
    await pump(t, width: 440);
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'main unsent draft');
    final main = t.widget<CustomScrollView>(find.byKey(const ValueKey('ai-transcript'))).controller! as AiTranscriptController;
    main.reveal('msg_u1'); await t.pump(); await t.pump();
    main.jumpTo(main.offset + 220); await t.pump();
    final anchor = main.debugReadingAnchor!;
    link.events.emit({'type':'tool.running','tool_call_id':'parent-task','tool_name':'subagent','input':{'description':'检查本地项目'},'metadata':{'child_session_id':'child-1'}});
    await t.pump();
    await t.tap(find.byKey(const ValueKey('ai-work-tab-ses_1:parent-task')));
    for (var i = 0; i < 5; i++) { await t.pump(const Duration(milliseconds: 50)); }
    expect(find.text('child conversation reply', findRichText: true), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), 'child unsent draft');
    expect(link.childEvents.length, 1);
    link.events.emit({'type':'tool.running','tool_call_id':'shell','tool_name':'shell','input':{'command':'long build'}});
    link.events.emit({'type':'tool.progress','tool_call_id':'shell','delta': List.generate(300, (i) => 'line $i build output').join('\n')});
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.byKey(const ValueKey('ai-work-tab-ses_1:shell')));
    await t.pump(); await t.pump();
    final output = t.widget<CustomScrollView>(find.byKey(const ValueKey('ai-transcript'))).controller! as AiTranscriptController;
    output.reveal('0:40'); await t.pump(); await t.pump();
    final outputAnchor = output.debugReadingAnchor!;
    link.events.emit({'type':'tool.progress','tool_call_id':'shell','delta':'\nmore output arriving'});
    await t.pump(); await t.pump(const Duration(milliseconds: 40));
    expect(output.debugReadingAnchor!.$1, outputAnchor.$1);
    expect(output.followsLatest.value, isFalse);
    await t.tap(find.byKey(const ValueKey('ai-work-main'))); await t.pump(); await t.pump();
    expect(t.widget<TextField>(find.byKey(const ValueKey('ai-prompt-input'))).controller!.text, 'main unsent draft');
    expect(main.debugReadingAnchor!.$1, anchor.$1);
    await t.tap(find.byKey(const ValueKey('ai-work-list'))); await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ai-work-row-ses_1:parent-task'))); await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byKey(const ValueKey('ai-prompt-input'))).controller!.text, 'child unsent draft');
    expect(link.childEvents.length, 1);
    expect(link.opens, 1, reason: 'switching panes does not replace the root stream');
    await snapshot(t, 'ai-child-sidebar');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('work switcher and output remain readable in a light narrow pane', (t) async {
    await pump(t, width: 390, brightness: Brightness.light);
    link.events.emit({'type':'tool.running','tool_call_id':'shell','tool_name':'shell','input':{'command':'pwsh -NoProfile -Command build'}});
    link.events.emit({'type':'tool.progress','tool_call_id':'shell','delta':'Compiling project…\n42 files checked\nWaiting for build completion'});
    await t.pump(); await t.pump(const Duration(milliseconds: 40));
    await t.tap(find.byKey(const ValueKey('ai-work-tab-ses_1:shell'))); await t.pump(); await t.pump();
    expect(find.text('42 files checked'), findsOneWidget);
    expect(t.takeException(), isNull);
    await snapshot(t, 'ai-work-light-sidebar');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a child opened directly from history exposes its parent conversation', (t) async {
    await pump(t, sessionId: 'child-1');
    expect(find.text('child conversation reply', findRichText: true), findsOneWidget);
    await t.tap(find.byTooltip('返回上级代理'));
    await t.pump();
    expect(ws.assistantPanel.active, 'ai:ses_1');
    expect(ws.tab('ai:ses_1')?.taskKey, 'ses_1');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('working activity fits phone width and sync event reloads history', (t) async {
    await pump(t, width: 390);
    link.events.emit({'type':'tool.running','tool_call_id':'shell','tool_name':'shell','input':{'command':'pwsh -NoProfile -Command "build a long project path with spaces"'},'metadata':{'proxy_mode':'agent'}});
    await t.pump();
    await snapshot(t, 'ai-working-shell-mobile');
    final before = link.rpcCalls.where((c) => c.$1 == 'ai.get').length;
    link.events.emit({'type':'sync.required'});
    for (var i=0;i<3;i++) { await t.pump(const Duration(milliseconds: 30)); }
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.get').length, greaterThan(before));
  });
  testWidgets('stream text is coalesced and reading history is not forcibly scrolled', (t) async {
    link.longHistory = true;
    await pump(t);
    final list = t.widget<CustomScrollView>(find.byKey(const ValueKey('ai-transcript')));
    expect(list.controller!.position.maxScrollExtent - list.controller!.position.minScrollExtent, greaterThan(200));
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await t.pump();
    link.events.emit({'type': 'text.delta', 'delta': 'batched '});
    link.events.emit({'type': 'text.delta', 'delta': 'reply'});
    await t.pump();
    expect(find.text('batched reply', findRichText: true), findsNothing);
    await t.pump(const Duration(milliseconds: 34));
    // The buffers are flushed together, not rendered once for each token.
    expect(find.text('batched reply', findRichText: true), findsWidgets);
    (list.controller! as AiTranscriptController).reveal('msg_u1');
    await t.pump(); await t.pump();
    list.controller!.jumpTo(list.controller!.offset + 200);
    await t.pump();
    final readingOffset = list.controller!.offset;
    expect(find.byKey(const ValueKey('ai-jump-latest')), findsOneWidget);
    link.events.emit({'type': 'text.delta', 'delta': ' while reading history'});
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(list.controller!.offset, closeTo(readingOffset, .1));
    await t.tap(find.byKey(const ValueKey('ai-jump-latest')));
    await t.pump();
    expect(list.controller!.offset, closeTo(list.controller!.position.maxScrollExtent, 1));
    final latestOffset = list.controller!.offset;
    for (var frame = 0; frame < 6; frame++) {
      await t.pump(const Duration(milliseconds: 30));
      expect(list.controller!.offset, closeTo(latestOffset, .1));
    }
  });
  testWidgets('mobile composer previews pasted image and file without uploading', (t) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('aurora3/input'), (call) async {
      if (call.method != 'readClipboard') return null;
      return {
        'files': [
          {
            'name': '一张较长文件名的示例截图.png',
            'bytes': base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJZkAAAAASUVORK5CYII=',
            ),
          },
          {'name': 'README.md', 'bytes': Uint8List.fromList(utf8.encode('# 合成测试文件'))},
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('aurora3/input'), null));
    await pump(t, width: 390);
    await t.tap(find.byKey(const ValueKey('ai-attach-menu')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('粘贴图片 / 文件 / 文本'));
    // The conversation is still streaming, so it never globally settles.
    // Draw the route exit, then the asynchronous clipboard result.
    for (var i = 0; i < 4; i++) { await t.pump(const Duration(milliseconds: 100)); }
    expect(find.textContaining('示例截图.png'), findsOneWidget);
    expect(find.textContaining('README.md'), findsOneWidget);
    expect(t.takeException(), isNull);
    expect(link.rpcCalls.where((c) => c.$1 == 'ai.run' || c.$1 == 'ai.attach.upload'), isEmpty);
    await snapshot(t, 'ai-attachments-mobile');
  });
  testWidgets('completed plans disappear immediately, new unfinished plans can appear again', (t) async {
    await pump(t, width: 420);
    expect(find.byKey(const ValueKey('ai-active-plan')), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('ai-active-plan'))).height, lessThanOrEqualTo(40));
    link.events.emit({'type': 'todos.updated', 'todos': [
      {'id':'one','content':'finished work','status':'completed'},
      {'id':'two','content':'no longer needed','status':'cancelled'},
    ]});
    await t.pump();
    expect(find.byKey(const ValueKey('ai-active-plan')), findsNothing);
    await snapshot(t, 'ai-plan-completed-sidebar');
    link.events.emit({'type': 'todos.updated', 'todos': [
      {'id':'next','content':'new active task','status':'in_progress'},
    ]});
    await t.pump();
    expect(find.byKey(const ValueKey('ai-active-plan')), findsOneWidget);
    expect(find.text('new active task'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('fixed message navigation survives resize and background resync while reading', (t) async {
    link.longHistory = true;
    await pump(t, width: 520);
    final controller = t.widget<CustomScrollView>(find.byKey(const ValueKey('ai-transcript'))).controller! as AiTranscriptController;
    controller.reveal('msg_u1'); await t.pump(); await t.pump();
    controller.jumpTo(controller.offset + 320); await t.pump();
    final anchor = controller.debugReadingAnchor!;
    final navigationTop = t.getTopLeft(find.byKey(const ValueKey('ai-message-navigation'))).dy;
    t.view.physicalSize = const Size(420, 900); await t.pump();
    expect(controller.debugReadingAnchor!.$1, anchor.$1);
    expect(t.getTopLeft(find.byKey(const ValueKey('ai-message-navigation'))).dy, navigationTop);
    for (final font in [20.0, 12.0, 18.0, 15.0]) {
      app.appearance.set('chatFont', font);
      await t.pump();
      expect(controller.debugReadingAnchor!.$1, anchor.$1);
      expect(controller.followsLatest.value, isFalse);
      expect(t.widget<TextField>(find.byKey(const ValueKey('ai-prompt-input'))).style!.fontSize, font);
    }
    final before = controller.offset;
    link.events.emit({'type':'sync.required'});
    await t.pump(); await t.pump(); await t.pump(const Duration(milliseconds: 100));
    expect(controller.debugReadingAnchor!.$1, anchor.$1);
    expect(controller.offset, closeTo(before, 1.5));
    expect(controller.followsLatest.value, isFalse);
    await t.tap(find.byKey(const ValueKey('ai-next-message'))); await t.pump(); await t.pump();
    expect(find.byKey(const ValueKey('msg_a1')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ai-previous-message'))); await t.pump(); await t.pump();
    expect(find.byKey(const ValueKey('msg_u1')), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('short windows retain a usable composer without chrome overflowing the conversation', (t) async {
    await pump(t, width: 420);
    t.view.physicalSize = const Size(420, 240); await t.pump();
    expect(find.byKey(const ValueKey('ai-prompt-input')).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-message-navigation')).hitTestable(), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
