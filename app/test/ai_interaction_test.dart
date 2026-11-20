import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_model_picker.dart';
import 'package:aurora/features/ai/ai_settings_dialog.dart';
import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ai_runtime_test.dart' show RuntimeLink;
import 'support/workspace_fixture.dart';
import 'support/test_pdf.dart';

class _MediaDownload extends Fake implements OpStream {
  final Uint8List bytes;
  bool sent = false;
  _MediaDownload(this.bytes);
  @override
  Future<Object?> response() async => {'size': bytes.length};
  @override
  Future<Frame?> read() async {
    if (sent) return Frame(typeEnd, Uint8List(0));
    sent = true;
    return Frame(typeData, bytes);
  }

  @override
  void reset() {}
}

class _Link extends RuntimeLink {
  Completer<Object?>? catalog, approval;
  Completer<Object?>? answer;
  Map<String, dynamic>? question;
  bool modern = false;
  int answers = 0;
  int approvals = 0;
  int downloads = 0;
  final media = <String, Uint8List>{};
  List<Map<String, dynamic>>? history;
  Map<String, Object?>? revertPreview, revertRequest;
  final List<Map<String, dynamic>> inbox = [];
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    if (op == 'ai.attach.download') {
      downloads++;
      return _MediaDownload(media[(args as Map)['id']]!);
    }
    return super.open(op, args, priority);
  }

  @override
  AgentInfo get server => AgentInfo({
    'version': '3.21.3',
    'arch': 'amd64',
    'caps': [
      'ai.inbox',
      'ai.permissions',
      if (revertPreview != null) 'ai.revert.preview',
      if (modern) ...['ai.capabilities', 'ai.question'],
    ],
  });
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'ai.revert.preview') return revertPreview;
    if (op == 'ai.revert') {
      revertRequest = Map<String, Object?>.from(args as Map);
      return {'restored_files': 1};
    }
    if (op == 'ai.question') {
      final input = args as Map;
      if (input['id'] == null) return {'question': question};
      answers++;
      if (answer != null) return answer!.future;
      question = null;
      return {'accepted': true};
    }
    if (op == 'ai.models' && catalog != null) return catalog!.future;
    if (op == 'ai.approve') {
      approvals++;
      if (approval != null) return approval!.future;
    }
    if (op == 'ai.inbox') {
      if (args is Map && args['action'] == 'cancel') {
        inbox.removeWhere((item) => item['id'] == args['id']);
      }
      return {'items': List.of(inbox)};
    }
    final result = await super.call(op, args, timeout);
    if (op == 'ai.get') {
      ((result as Map)['session'] as Map)['inbox'] = List.of(inbox);
      if (history != null) {
        result['running'] = false;
        (result['session'] as Map)['messages'] = history;
        (result['session'] as Map)['todos'] = [];
      }
    }
    return result;
  }
}

void main() {
  late _Link link;
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  final shots = Platform.environment['AURORA_AI_SHOTS'];
  final boundary = GlobalKey();

  setUpAll(() async {
    if (shots == null) return;
    for (final entry in {
      Ide.ui: r'C:\Windows\Fonts\SegUIVar.ttf',
      Ide.mono: r'C:\Windows\Fonts\consola.ttf',
      'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
      'Microsoft YaHei UI': r'C:\Windows\Fonts\msyh.ttc',
      'Consolas': r'C:\Windows\Fonts\consola.ttf',
      'MaterialIcons': r'C:\dev\VPS\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) continue;
      final loader = FontLoader(entry.key)
        ..addFont(Future.value(ByteData.sublistView(await file.readAsBytes())));
      await loader.load();
    }
    Directory(shots).createSync(recursive: true);
  });
  setUp(() {
    link = _Link();
    app = WorkspaceApp(
      wire: link,
      profile: Profile(
        servers: [ServerEntry(id: 'server', name: '测试工作区')],
        selected: 'server',
        ai: AiSettings(
          selectedProviderId: 'a',
          providers: [
            AiProvider(
              id: 'a',
              name: '连接 A',
              model: 'model-a',
              models: ['model-a', 'model-new'],
              apiKey: 'fixture-a',
            ),
            AiProvider(
              id: 'b',
              name: '连接 B',
              model: 'model-b',
              models: ['model-b'],
              apiKey: 'fixture-b',
            ),
          ],
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

  Future<void> frames(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(
    WidgetTester t,
    Widget child, {
    Size size = const Size(1000, 800),
    Brightness brightness = Brightness.dark,
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness),
          home: InputMode.scope(
            mode: input,
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    await frames(t);
  }

  Future<void> settings(
    WidgetTester t, {
    Size size = const Size(1000, 800),
    Brightness brightness = Brightness.dark,
  }) async {
    await pump(
      t,
      Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showAiSettingsDialog(ctx, app: app, ws: ws),
          child: const Text('打开设置'),
        ),
      ),
      size: size,
      brightness: brightness,
    );
    await t.tap(find.text('打开设置'));
    await t.pumpAndSettle();
  }

  Future<void> page(WidgetTester t, String id) async {
    final selector = find.byKey(const ValueKey('ai-settings-nav-selector'));
    if (selector.evaluate().isNotEmpty) {
      await t.ensureVisible(selector);
      await t.pumpAndSettle();
      await t.tap(selector);
      await t.pumpAndSettle();
    }
    final nav = find.byKey(ValueKey('ai-settings-nav-$id'));
    await t.ensureVisible(nav);
    await t.pumpAndSettle();
    await t.tap(nav.hitTestable());
    await t.pumpAndSettle();
    if (selector.evaluate().isNotEmpty) {
      expect(t.widget<DropdownButton<String>>(selector).value, id);
    }
  }

  Future<void> provider(WidgetTester t, String from, String label) async {
    await t.tap(find.byKey(ValueKey('ai-provider-select-$from')));
    await t.pumpAndSettle();
    await t.tap(find.text(label).last);
    await t.pumpAndSettle();
  }

  Future<void> snapshot(WidgetTester t, String name) async {
    if (shots == null) return;
    final render = t.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
    await t.runAsync(() async {
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$shots/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'editing another provider saves its draft without switching the default',
    (t) async {
      await settings(t);
      await provider(t, 'a', '连接 B');
      await page(t, 'connection');
      await t.enterText(
        find.byKey(const ValueKey('ai-model-id')),
        'model-b-edited',
      );
      await t.tap(find.byKey(const ValueKey('ai-save-settings')));
      await t.pumpAndSettle();
      expect(app.profile.ai.selectedProviderId, 'a');
      expect(app.profile.ai.providers.last.model, 'model-b-edited');
      expect(app.profile.ai.activeProvider!.apiKey, 'fixture-a');
    },
  );

  testWidgets(
    'dirty state covers text edits and discard preserves saved provider',
    (t) async {
      await settings(t);
      await t.enterText(
        find.byKey(const ValueKey('ai-provider-name')),
        'draft name',
      );
      await t.pump();
      expect(find.text('有未保存的修改'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await t.tap(find.text('放弃修改'));
      await t.pumpAndSettle();
      expect(find.byType(AiSettingsDialog), findsNothing);
      expect(app.profile.ai.providers.first.name, '连接 A');
    },
  );

  testWidgets(
    'outdated catalog cannot overwrite provider after switching away and back',
    (t) async {
      link.catalog = Completer<Object?>();
      await settings(t);
      await page(t, 'connection');
      await t.tap(find.byKey(const ValueKey('ai-fetch-models')));
      await t.pump();
      await provider(t, 'a', '连接 B');
      await provider(t, 'b', '连接 A · 默认');
      link.catalog!.complete({
        'models': [
          {'id': 'stale-model'},
        ],
      });
      await t.pumpAndSettle();
      expect(find.text('stale-model'), findsNothing);
      await t.tap(find.byKey(const ValueKey('ai-save-settings')));
      await t.pumpAndSettle();
      expect(
        app.profile.ai.providers.first.models,
        isNot(contains('stale-model')),
      );
    },
  );

  testWidgets(
    'browsing persona picker then cancel changes neither default nor session',
    (t) async {
      String? result;
      await pump(
        t,
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await showAiPersonaPicker(ctx, ws);
            },
            child: const Text('人设'),
          ),
        ),
      );
      await t.tap(find.text('人设'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('关闭'));
      await t.pumpAndSettle();
      expect(result, isNull);
      expect(app.profile.ai.selectedProviderId, 'a');
    },
  );

  testWidgets(
    'narrow sidebar retains model selection and send dispatches slash commands',
    (t) async {
      await pump(
        t,
        AiStudioView(ws: ws, initialSessionId: 'ses_1'),
        size: const Size(360, 800),
      );
      expect(
        find.byKey(const ValueKey('ai-model-btn')).hitTestable(),
        findsOneWidget,
      );
      await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), '/plan');
      await t.tap(find.byKey(const ValueKey('ai-send-btn')));
      await frames(t);
      expect(link.rpcCalls.where((x) => x.$1 == 'ai.run'), isEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ai-mode-pill')),
          matching: find.text('规划'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ai-perm-pill')),
          matching: find.text('询问'),
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
      await snapshot(t, 'conversation-narrow-dark');
    },
  );

  testWidgets(
    'approval disables duplicate submissions and retains failed request for retry',
    (t) async {
      link.approval = Completer<Object?>();
      await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
      final button = find.byKey(const ValueKey('ai-approve-once'));
      await t.tap(button);
      await t.pump();
      expect(t.widget<FilledButton>(button).onPressed, isNull);
      expect(link.approvals, 1);
      link.approval!.completeError(OpError(codeNotFound, '审批测试失败'));
      await frames(t);
      expect(find.byKey(const ValueKey('ai-approval-error')), findsOneWidget);
      expect(button, findsOneWidget);
      expect(t.widget<FilledButton>(button).onPressed, isNotNull);
      link.approval = null;
      await t.tap(button);
      await frames(t);
      expect(link.approvals, 2);
      expect(button, findsNothing);
    },
  );

  testWidgets(
    'short running window keeps both send and stop and exposes approval details',
    (t) async {
      await pump(
        t,
        AiStudioView(ws: ws, initialSessionId: 'ses_1'),
        size: const Size(420, 240),
      );
      expect(
        find.byKey(const ValueKey('ai-send-btn')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byTooltip('停止当前运行').hitTestable(), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ai-permission-details')));
      await frames(t);
      expect(find.text('src/main.dart'), findsOneWidget);
      expect(find.text('返回审批').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'resizing a sidebar with expanded runtime keeps decisions and input reachable',
    (t) async {
      await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
      await t.tap(find.byKey(const ValueKey('ai-context-indicator')));
      await frames(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames(t);
      for (final size in [
        const Size(320, 480),
        const Size(280, 600),
        const Size(420, 240),
      ]) {
        t.view.physicalSize = size;
        await frames(t);
        expect(
          find.byKey(const ValueKey('ai-prompt-input')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ai-approve-once')).hitTestable(),
          findsOneWidget,
        );
        expect(t.takeException(), isNull, reason: '$size');
        await snapshot(
          t,
          'conversation-${size.width.toInt()}x${size.height.toInt()}-dark',
        );
      }
    },
  );

  testWidgets(
    'persona search filters immediately and applies only to this conversation',
    (t) async {
      await app.update((p) {
        p.ai.personas = [
          AiPersona(id: 'pa', name: '人设 A', providerId: 'a', model: 'model-a'),
          AiPersona(id: 'pb', name: '人设 New', providerId: 'a', model: 'model-new'),
        ];
        p.ai.activePersonaId = 'pa';
      });
      await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
      await t.tap(find.byKey(const ValueKey('ai-model-btn')));
      await frames(t);
      final filter = find.byKey(const ValueKey('ai-picker-search'));
      await t.enterText(filter, 'model-new');
      await frames(t);
      expect(find.text('人设 A'), findsNothing);
      await t.tap(find.byKey(const ValueKey('ai-persona-option-pb')));
      await frames(t);
      expect(app.profile.ai.activePersonaId, 'pa');
      expect(find.text('人设 New · model-new'), findsOneWidget);
    },
  );

  testWidgets(
    'short persona picker selects persona and sends its reasoning effort',
    (t) async {
      await app.update((p) {
        p.ai.personas = [
          AiPersona(id: 'pa', name: '人设 A', providerId: 'a', model: 'model-a'),
          AiPersona(
            id: 'pmax',
            name: '极速思考',
            providerId: 'a',
            model: 'custom-model',
            reasoningEffort: 'max',
          ),
        ];
        p.ai.activePersonaId = 'pa';
      });
      await pump(
        t,
        AiStudioView(ws: ws, initialSessionId: 'ses_1'),
        size: const Size(420, 300),
      );
      await t.tap(find.byKey(const ValueKey('ai-compact-menu')));
      await frames(t);
      await t.tap(find.text('人设 A · model-a'));
      await frames(t);
      await t.tap(find.byKey(const ValueKey('ai-persona-option-pmax')));
      await frames(t);
      expect(t.takeException(), isNull);
      await t.enterText(
        find.byKey(const ValueKey('ai-prompt-input')),
        'test effort',
      );
      await t.tap(find.byKey(const ValueKey('ai-send-btn')));
      await frames(t);
      final wire =
          link.rpcCalls.where((x) => x.$1 == 'ai.run').single.$2['provider']
              as Map;
      expect(wire['model'], 'custom-model');
      expect(wire['reasoning_effort'], 'max');
      expect(app.aiSettings.activePersonaId, 'pa');
    },
  );

  testWidgets(
    'question is restored on load and failed answer is retained for retry',
    (t) async {
      link.modern = true;
      link.question = {
        'id': 'q1',
        'session_id': 'ses_1',
        'questions': [
          {
            'question': '选择实现方式',
            'options': [
              {'label': '简洁'},
              {'label': '完整'},
            ],
          },
          {
            'question': '需要哪些输出',
            'multiple': true,
            'options': [
              {'label': '源码'},
              {'label': '文档'},
            ],
          },
        ],
      };
      link.answer = Completer<Object?>();
      await pump(
        t,
        AiStudioView(ws: ws, initialSessionId: 'ses_1'),
        size: const Size(390, 700),
      );
      await t.tap(find.byKey(const ValueKey('ai-question-open')));
      await frames(t);
      await t.tap(find.text('简洁'));
      await t.tap(find.text('源码'));
      await t.tap(find.text('文档'));
      await t.tap(find.byKey(const ValueKey('ai-question-submit')));
      await frames(t);
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('ai-question-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(link.answers, 1);
      link.answer!.completeError(OpError(codeNotFound, '连接暂时中断'));
      await frames(t);
      expect(find.text('连接暂时中断'), findsOneWidget);
      expect(
        t
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .where((w) => w.value == true),
        hasLength(3),
      );
      await snapshot(t, 'question-retry');
      link.answer = null;
      await t.tap(find.byKey(const ValueKey('ai-question-submit')));
      await frames(t);
      expect(link.answers, 2);
      expect(find.byKey(const ValueKey('ai-question-open')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'model overrides persist without switching default and are sent as a snapshot',
    (t) async {
      link.modern = true;
      await settings(t);
      await page(t, 'connection');
      await t.ensureVisible(find.text('model-new'));
      final modelRow = find.ancestor(
        of: find.text('model-new').first,
        matching: find.byType(ListTile),
      );
      await t.tap(find.descendant(of: modelRow, matching: find.text('生成 Persona')));
      await t.pumpAndSettle();
      final image = find.byKey(const ValueKey('ai-capability-image_input'));
      await t.ensureVisible(image);
      await t.tap(image);
      await t.pumpAndSettle();
      await t.tap(find.text('关闭').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-save-settings')));
      await t.pumpAndSettle();
      expect(app.aiSettings.activeProvider!.model, 'model-a');
      expect(
        app.aiSettings.personas.single.capabilities['image_input'],
        isFalse,
      );
      await app.update(
        (p) => p.ai.toolDefaults.addAll({'grep': false, 'image_input': false}),
      );
      await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
      expect(find.byTooltip('图片输入已关闭'), findsOneWidget);
      await t.enterText(
        find.byKey(const ValueKey('ai-prompt-input')),
        'test capabilities',
      );
      await t.tap(find.byKey(const ValueKey('ai-send-btn')));
      await frames(t);
      final wire =
          link.rpcCalls.where((x) => x.$1 == 'ai.run').single.$2['provider']
              as Map;
      expect(wire['capabilities'], containsPair('grep', false));
      expect(wire['capabilities'], containsPair('image_input', false));
    },
  );

  testWidgets('old agent cannot silently ignore explicit capability settings', (
    t,
  ) async {
    await app.update((p) => p.ai.toolDefaults['shell'] = false);
    await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
    final field = find.byKey(const ValueKey('ai-prompt-input'));
    await t.enterText(field, 'preserve my draft');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await frames(t);
    expect(link.rpcCalls.where((x) => x.$1 == 'ai.run'), isEmpty);
    expect(t.widget<TextField>(field).controller!.text, 'preserve my draft');
  });

  testWidgets(
    'tool media loads on expansion and image and PDF open from immutable references',
    (t) async {
      link.pendingPermission = null;
      link.media['image-ref'] = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJZkAAAAASUVORK5CYII=',
      );
      link.media['pdf-ref'] = buildTestPdf(pages: 1, extra: 'Harness document');
      link.history = [
        {
          'id': 'media-step',
          'role': 'assistant',
          'finish': 'stop',
          'parts': [
            {
              'type': 'tool-call',
              'name': 'read',
              'tool_call_id': 'media-call',
              'input': {'path': 'chart.png'},
            },
            {
              'type': 'tool-result',
              'name': 'read',
              'tool_call_id': 'media-call',
              'output': 'Captured media attached.',
              'attachments': [
                {
                  'type': 'image',
                  'attachment_id': 'image-ref',
                  'filename': 'chart.png',
                  'mime': 'image/png',
                  'size': link.media['image-ref']!.length,
                },
                {
                  'type': 'file',
                  'attachment_id': 'pdf-ref',
                  'filename': 'report.pdf',
                  'mime': 'application/pdf',
                  'size': link.media['pdf-ref']!.length,
                },
              ],
            },
          ],
        },
      ];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => Directory.systemTemp.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await pump(
        t,
        AiStudioView(ws: ws, initialSessionId: 'ses_1'),
        size: const Size(390, 800),
      );
      expect(link.downloads, 0);
      await t.tap(find.text('读取 chart.png'));
      await frames(t);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(
        link.downloads,
        1,
        reason: 'only the expanded image thumbnail loads',
      );
      await t.tap(find.text('chart.png'));
      await frames(t);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await t.tap(find.text('关闭'));
      await frames(t);
      await t.ensureVisible(find.text('report.pdf'));
      await t.tap(find.text('report.pdf'));
      for (var i = 0; i < 12; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(PdfViewer), findsOneWidget);
      expect(link.downloads, 2);
      expect(t.takeException(), isNull);
      await snapshot(t, 'tool-pdf-preview-390');
      await t.pumpWidget(const SizedBox());
      // pdfrx checks disposal on the next background-page timer. Advance the
      // fake clock as well as giving its native document worker time to exit.
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await t.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets('delivery selector sends queue only after explicit selection', (
    t,
  ) async {
    await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
    await t.tap(find.byKey(const ValueKey('ai-send-options')));
    await frames(t);
    await t.tap(find.byKey(const ValueKey('ai-send-delivery-0')));
    await frames(t);
    await t.tap(find.text('排队发送 · 当前任务结束后').last);
    await frames(t);
    await t.tap(find.byKey(const ValueKey('ai-send-options-apply')));
    await frames(t);
    await t.enterText(find.byKey(const ValueKey('ai-prompt-input')), '下一项任务');
    await t.tap(find.byKey(const ValueKey('ai-send-btn')));
    await frames(t);
    final call = link.rpcCalls.where((x) => x.$1 == 'ai.run').single.$2;
    expect(call['delivery'], 'queue');
    expect(call['text'], '下一项任务');
  });

  testWidgets('AI revert rechecks edits that appear while confirming', (t) async {
    link.history = [
      {
        'id': 'prompt',
        'role': 'user',
        'parts': [
          {'type': 'text', 'text': 'fixture prompt'},
        ],
      },
    ];
    await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
    await t.tap(find.text('回退'));
    await frames(t);
    expect(find.text('回退到此消息之前？'), findsOneWidget);

    final tab = EditorTab(
      id: 'file:home:/project/notes.md',
      file: WorkspacePath(root: 'home', path: '/project/notes.md'),
      title: 'notes.md',
      icon: Icons.edit,
      builder: (_) => const SizedBox(),
    );
    ws.tabs.add(tab);
    tab.dirty.value = true;
    await t.tap(find.text('仅回退对话'));
    await frames(t);
    expect(link.revertRequest, isNull);
    expect(tab.dirty.value, isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('AI revert does not preselect files and only submits explicit choices', (t) async {
    link.revertPreview = {'revision': 'review-revision', 'paths': ['ai.txt', 'manual.txt']};
    link.history = [
      {
        'id': 'prompt',
        'role': 'user',
        'parts': [
          {'type': 'text', 'text': 'fixture prompt'},
        ],
      },
    ];
    await pump(t, AiStudioView(ws: ws, initialSessionId: 'ses_1'));
    await t.tap(find.text('回退'));
    await frames(t);
    expect(find.text('仅回退对话'), findsOneWidget);
    final choices = find.byType(CheckboxListTile);
    expect(t.widgetList<CheckboxListTile>(choices).map((tile) => tile.value), [false, false]);
    await t.tap(find.text('ai.txt'));
    await frames(t);
    await t.tap(find.text('恢复所选文件和对话'));
    await frames(t);
    expect(link.revertRequest, containsPair('files', true));
    expect(link.revertRequest?['review'], {'revision': 'review-revision', 'paths': ['ai.txt']});
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unfinished rule form participates in save and discard protection',
    (t) async {
      await settings(t);
      await page(t, 'execution');
      final resource = find.byKey(const ValueKey('ai-rule-resource'));
      await t.ensureVisible(resource);
      await t.enterText(resource, 'git status *');
      await t.pump();
      expect(find.text('有未保存的修改'), findsOneWidget);
      await page(t, 'defaults');
      await t.tap(find.byKey(const ValueKey('ai-save-settings')));
      await t.pumpAndSettle();
      expect(app.profile.ai.permissionRules.single.resource, 'git status *');
      await settings(t);
      await page(t, 'execution');
      await t.ensureVisible(resource);
      await t.enterText(resource, 'git diff *');
      await t.tap(find.byTooltip('关闭 AI 设置'));
      await t.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await t.tap(find.text('放弃修改'));
      await t.pumpAndSettle();
      expect(app.profile.ai.permissionRules, hasLength(1));
    },
  );

  testWidgets(
    'open inbox follows stop events and retained input can be removed',
    (t) async {
      link.inbox.add({
        'id': 'queued-1',
        'text': '接着检查构建结果',
        'delivery': 'queue',
        'runtime': {'provider_name': '连接 A', 'model': 'model-a'},
        'attachments': [
          {'label': 'build.log'},
        ],
      });
      await pump(
        t,
        AiStudioView(ws: ws, initialSessionId: 'ses_1'),
        size: const Size(360, 700),
      );
      await t.tap(find.byKey(const ValueKey('ai-inbox-open')));
      await frames(t);
      expect(find.text('改为补充'), findsOneWidget);
      expect(find.text('附件 · build.log'), findsOneWidget);
      await snapshot(t, 'inbox-running-360-dark');
      link.inbox.single['held'] = true;
      link.events.emit({'type': 'session.status', 'status': 'idle'});
      await frames(t);
      expect(find.text('改为补充'), findsNothing);
      expect(find.text('用当前选择重新发送'), findsOneWidget);
      await t.tap(find.text('移除'));
      await frames(t);
      expect(find.text('没有待发送输入'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('short composer can inspect and remove pasted attachments', (
    t,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('aurora3/input');
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'readClipboard'
          ? {
              'files': [
                {
                  'name': 'context.txt',
                  'bytes': Uint8List.fromList([65, 66, 67]),
                },
              ],
            }
          : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await pump(
      t,
      AiStudioView(ws: ws, initialSessionId: 'ses_1'),
      size: const Size(420, 240),
    );
    await t.tap(find.byKey(const ValueKey('ai-compact-menu')));
    await frames(t);
    await t.ensureVisible(find.text('粘贴图片 / 文件 / 文本'));
    await t.tap(find.text('粘贴图片 / 文件 / 文本'));
    await frames(t);
    await t.tap(find.byKey(const ValueKey('ai-compact-menu')));
    await frames(t);
    await t.ensureVisible(find.text('管理 1 个附件…'));
    await t.tap(find.text('管理 1 个附件…'));
    await frames(t);
    expect(find.text('context.txt'), findsOneWidget);
    await t.tap(find.byTooltip('移除 context.txt'));
    await frames(t);
    expect(find.text('没有待发送附件'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  for (final size in [const Size(390, 800), const Size(1100, 820)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'settings pages stay independent at ${size.width} ${brightness.name}',
        (t) async {
          await settings(t, size: size, brightness: brightness);
          for (final id in [
            'personas',
            'connection',
            'execution',
            'defaults',
          ]) {
            await page(t, id);
            expect(
              find.byKey(const ValueKey('ai-save-settings')).hitTestable(),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('ai-api-key')),
              id == 'connection' ? findsOneWidget : findsNothing,
            );
            expect(t.takeException(), isNull);
            await snapshot(
              t,
              'settings-$id-${size.width.toInt()}-${brightness.name}',
            );
          }
        },
      );
    }
  }

  test('project permissions bind to both server and project and survive serialization', () {
    final rule = AiPermissionRule(
      action: 'shell',
      resource: 'git *',
      effect: 'allow',
      scope: 'project',
      serverId: 'server',
      projectId: 'project',
    );
    final saved = AiPermissionRule.fromJson(rule.toJson());
    expect(saved.appliesTo('server', 'project'), isTrue);
    expect(saved.appliesTo('other-server', 'project'), isFalse);
    expect(saved.appliesTo('server', null), isFalse);
    expect(
      AiPermissionRule(
        action: 'read',
        resource: '*',
        effect: 'allow',
        scope: 'project',
      ).appliesTo('', null),
      isFalse,
    );
  });
}
