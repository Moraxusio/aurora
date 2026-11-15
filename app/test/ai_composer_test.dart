import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_runtime_test.dart' show RuntimeLink;
import 'support/workspace_fixture.dart';

void main() {
  group('composer wording', () {
    test('the two switches say what they do, in Chinese first', () {
      expect(AiComposerText.agent('build', narrow: false), '构建 · 可改文件');
      expect(AiComposerText.agent('plan', narrow: false), '规划 · 只读');
      expect(AiComposerText.agent('build', narrow: true), '构建');
      expect(AiComposerText.permission('ask', narrow: false), '先询问');
      expect(AiComposerText.permission('auto', narrow: false), '自动执行');
      expect(AiComposerText.permission('ask', narrow: true), '询问');
      for (final s in [
        AiComposerText.agent('build', narrow: true),
        AiComposerText.agent('plan', narrow: true),
        AiComposerText.permission('ask', narrow: true),
        AiComposerText.permission('auto', narrow: true),
      ]) {
        expect(RegExp(r'[A-Za-z]').hasMatch(s), isFalse, reason: '"$s" still has English in the narrow layout');
      }
    });

    test('the tooltips keep the English mode names beside the Chinese ones', () {
      expect(AiComposerText.agentTip('plan'), contains('Plan'));
      expect(AiComposerText.agentTip('build'), contains('Build'));
      expect(AiComposerText.permissionTip('ask'), contains('Ask'));
      expect(AiComposerText.permissionTip('auto'), contains('Auto'));
      expect(AiComposerText.permissionTip('auto'), contains('高风险'));
    });

    test('sending into a running task is called what it is', () {
      expect(AiComposerText.send(running: false, sending: false), '发送');
      expect(AiComposerText.send(running: true, sending: false), '补充指令');
      expect(AiComposerText.send(running: true, sending: true), '准备中');
      expect(AiComposerText.hint(running: true, agentMode: 'build'), contains('补充指令'));
      expect(AiComposerText.hint(running: true, agentMode: 'build'), isNot(contains('Steer')));
      expect(AiComposerText.hint(running: false, agentMode: 'plan'), contains('不修改文件'));
    });
  });

  group('conversation view', () {
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
          ai: AiSettings(providers: [AiProvider(id: 'p', name: '新网关', model: 'new-model')]),
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

    Future<void> open(WidgetTester t, {double width = 900, double height = 900}) async {
      t.view.physicalSize = Size(width, height);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(mode: input, child: Scaffold(body: AiStudioView(ws: ws, initialSessionId: 'ses_1'))),
      ));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('while a permission is pending the run says it waits for the user, not for the model', (t) async {
      await open(t);
      expect(find.byKey(const ValueKey('ai-permission-card')), findsOneWidget);
      expect(find.textContaining('等待你的批准'), findsOneWidget);
      expect(find.textContaining('等待模型响应'), findsNothing);
      // the card's own reason is Chinese
      expect(find.text('这一步会修改服务器上的文件'), findsOneWidget);
      expect(find.text('File modification requires approval'), findsNothing);
    });

    testWidgets('the approve button names what it covers', (t) async {
      await open(t);
      expect(find.text('本会话始终允许修改文件'), findsOneWidget);
    });

    testWidgets('a running task offers 补充指令, and the switches have Chinese names and tooltips', (t) async {
      await open(t);
      expect(find.text('补充指令'), findsOneWidget);
      expect(find.text('Steer'), findsNothing);
      expect(find.text('构建 · 可改文件'), findsOneWidget);
      expect(find.text('先询问'), findsOneWidget);
      expect(find.byTooltip(AiComposerText.agentTip('build')), findsOneWidget);
      expect(find.byTooltip(AiComposerText.permissionTip('ask')), findsOneWidget);
      expect(find.byTooltip(AiComposerText.sendTip(running: true)), findsOneWidget);
    });

    testWidgets('the context size from the model name is marked as an estimate', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('ai-context-indicator')));
      await t.pump();
      final usage = t.widget<Text>(find.byKey(const ValueKey('ai-context-usage'))).data!;
      expect(usage, contains('约 500.0k'));
      expect(usage, contains('上限为估计值'));
    });

    testWidgets('the switches fit a 360-wide column without overflow', (t) async {
      await open(t, width: 360);
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('ai-agent-mode')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-permission-mode')), findsOneWidget);
    });

    testWidgets('a 240-high window keeps the input and no chrome overflows', (t) async {
      await open(t, width: 420, height: 240);
      expect(find.byKey(const ValueKey('ai-prompt-input')).hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
