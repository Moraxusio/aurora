import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_studio_view.dart';
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
  bool legacy = false;
  @override
  Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async => events;
  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    final result = await super.call(op, args, timeout);
    if (op == 'ai.get' && !legacy) {
      final session = (result as Map)['session'] as Map;
      session['runtime'] = _runtime;
      session['context'] = _context;
      (session['messages'] as List).last['runtime'] = _runtime;
    }
    return result;
  }
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
  Future<void> pump(WidgetTester t, {double width = 1000}) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(
              body: AiStudioView(ws: ws, initialSessionId: 'ses_1'),
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
  testWidgets('actual provider/model differs from next selection and context is not total', (t) async {
    await pump(t);
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
    expect(text(t, 'ai-actual-model'), contains('未知提供商'));
    expect(text(t, 'ai-context-usage'), contains('暂无统计'));
    expect(text(t, 'ai-next-model'), contains('新网关'));
  });
  testWidgets('runtime dashboard fits a narrow mobile viewport', (t) async {
    await pump(t, width: 390);
    expect(find.byKey(const ValueKey('ai-runtime-bar')), findsOneWidget);
    await snapshot(t, 'ai-runtime-mobile');
  });
}
