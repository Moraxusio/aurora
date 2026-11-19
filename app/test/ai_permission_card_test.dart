import 'package:aurora/features/ai/ai_models.dart';
import 'package:aurora/features/ai/ai_permission_card.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _patch =
    '--- a/src/main.dart\n+++ b/src/main.dart\n@@ -3,3 +3,3 @@\n void a() {}\n-  var x = 1;\n+  var x = 2;\n void b() {}\n';

AiPermissionQuestion question({
  String action = 'edit',
  String resource = 'src/main.dart',
  String reason = 'File modification requires approval',
  String reasonCode = '',
  String scope = '',
  Map<String, dynamic> metadata = const {},
}) => AiPermissionQuestion(
  id: 'p',
  sessionId: 's',
  tool: action,
  action: action,
  resource: resource,
  reason: reason,
  reasonCode: reasonCode,
  scope: scope,
  metadata: metadata,
);

Future<List<(bool, bool)>> pump(
  WidgetTester t,
  AiPermissionQuestion q, {
  double width = 520,
  String workdir = '/srv/app',
}) async {
  final decisions = <(bool, bool)>[];
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: AiPermissionCard(
              question: q,
              workdir: workdir,
              onDecide: ({required bool allow, bool always = false}) =>
                  decisions.add((allow, always)),
            ),
          ),
        ),
      ),
    ),
  );
  return decisions;
}

void main() {
  group('permission question model', () {
    test('an old agent\'s English reason reads in Chinese, the same as a new agent\'s code', () {
      expect(question().reasonText, '这一步会修改服务器上的文件');
      expect(
        question(reason: '', reasonCode: 'file_modification').reasonText,
        '这一步会修改服务器上的文件',
      );
      expect(
        question(
          action: 'shell',
          reason: 'Shell command execution requires approval',
        ).reasonText,
        '这一步会执行一条命令',
      );
      expect(
        question(
          action: 'shell',
          reason: 'High-impact shell command requires confirmation',
        ).reasonText,
        contains('影响很大'),
      );
      expect(
        question(
          reason: 'Accessing potential secret or environment credential file',
        ).reasonText,
        contains('密钥'),
      );
      expect(
        question(
          action: 'doom_loop',
          reason: 'Agent invoked the exact same tool & arguments 3 times in a row. Continue anyway?',
        ).reasonText,
        contains('循环'),
      );
    });

    test('an unknown reason is shown as it came, not dropped', () {
      expect(
        question(reason: 'Something a newer agent says').reasonText,
        'Something a newer agent says',
      );
    });

    test('the always-allow button says what it covers', () {
      expect(
        question(action: 'shell', resource: 'git push origin main').alwaysLabel,
        '本会话始终允许 git 开头的命令',
      );
      expect(
        question(action: 'shell', resource: '  make   build').alwaysLabel,
        '本会话始终允许 make 开头的命令',
      );
      expect(
        question(action: 'shell', resource: 'ls', scope: 'ls *').alwaysLabel,
        '本会话始终允许 ls 开头的命令',
      );
      expect(question().alwaysLabel, '本会话始终允许修改文件');
      expect(question(action: 'write').alwaysLabel, '本会话始终允许修改文件');
      expect(
        question(action: 'webfetch', resource: 'https://x.test').alwaysLabel,
        '本会话始终允许访问 https://x.test/*',
      );
      expect(
        question(action: 'shell', resource: '').alwaysLabel,
        '本会话始终允许执行命令',
      );
    });

    test('the scope matches the agent\'s savePattern', () {
      expect(
        AiPermissionQuestion.alwaysScope('shell', 'git status --short'),
        'git *',
      );
      expect(AiPermissionQuestion.alwaysScope('edit', 'a.go'), '*');
      expect(AiPermissionQuestion.alwaysScope('shell', ''), '*');
    });

    test('the new agent fields are read', () {
      final q = AiPermissionQuestion.fromJson({
        'id': 'x',
        'session_id': 's',
        'tool': 'shell',
        'action': 'shell',
        'resource': 'git log',
        'reason_code': 'shell_command',
        'always_scope': 'git *',
      });
      expect(q.reasonCode, 'shell_command');
      expect(q.scope, 'git *');
    });
  });

  group('permission patch', () {
    test('is read from the agent\'s FileDiff in the metadata', () {
      final p = PermissionPatch.of(
        question(
          metadata: {
            'diff': {
              'file': 'src/main.dart',
              'additions': 1,
              'deletions': 1,
              'status': 'modified',
              'patch': _patch,
            },
          },
        ),
      )!;
      expect(p.file, 'src/main.dart');
      expect(p.additions, 1);
      expect(p.deletions, 1);
      expect(p.lines.where((l) => l.text.contains('var x = 2')), isNotEmpty);
      // the four file-header lines are not part of what is shown
      expect(
        p.lines.any(
          (l) => l.text.startsWith('--- a/') || l.text.startsWith('+++ b/'),
        ),
        isFalse,
      );
    });

    test('an empty or missing patch is no patch', () {
      expect(PermissionPatch.of(question()), isNull);
      expect(
        PermissionPatch.of(
          question(
            metadata: {
              'diff': {'file': 'a', 'patch': '  '},
            },
          ),
        ),
        isNull,
      );
      expect(
        PermissionPatch.of(question(metadata: {'diff': 'not a map'})),
        isNull,
      );
    });
  });

  group('permission card', () {
    testWidgets('an edit shows the lines that change, not just the file name', (
      t,
    ) async {
      await pump(
        t,
        question(
          metadata: {
            'diff': {
              'file': 'src/main.dart',
              'additions': 1,
              'deletions': 1,
              'status': 'modified',
              'patch': _patch,
            },
          },
        ),
      );
      expect(find.text('需要批准 · 修改文件'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-permission-patch')), findsOneWidget);
      expect(find.text('  var x = 1;'), findsOneWidget);
      expect(find.text('  var x = 2;'), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-permission-reason')),
        findsOneWidget,
      );
      expect(find.text('这一步会修改服务器上的文件'), findsOneWidget);
      expect(find.text('File modification requires approval'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('a command shows itself and the folder it runs in', (t) async {
      await pump(
        t,
        question(
          action: 'shell',
          resource: 'npm run build',
          reason: 'Shell command execution requires approval',
          metadata: {'workdir': '/srv/web'},
        ),
      );
      expect(find.text('\$ npm run build'), findsOneWidget);
      expect(find.text('在 /srv/web 中运行'), findsOneWidget);
      expect(find.text('本会话始终允许 npm 开头的命令'), findsOneWidget);
      // without a workdir in the question, the conversation's folder is used
      await pump(
        t,
        question(
          action: 'shell',
          resource: 'ls',
          reason: 'Shell command execution requires approval',
        ),
      );
      expect(find.text('在 /srv/app 中运行'), findsOneWidget);
    });

    testWidgets(
      'a long patch is cut and can be opened; long lines scroll inside the box',
      (t) async {
        final lines = [
          for (var i = 0; i < 40; i++) '+line number $i ${'x' * 200}',
        ].join('\n');
        await pump(
          t,
          question(
            metadata: {
              'diff': {
                'file': 'a.txt',
                'additions': 40,
                'deletions': 0,
                'status': 'added',
                'patch': '--- a/a.txt\n+++ b/a.txt\n@@ -0,0 +1,40 @@\n$lines\n',
              },
            },
          ),
          width: 360,
        );
        expect(find.text('新建 a.txt'), findsOneWidget);
        expect(find.textContaining('显示全部'), findsOneWidget);
        expect(find.textContaining('line number 39'), findsNothing);
        await t.tap(find.textContaining('显示全部'));
        await t.pump();
        expect(find.text('收起'), findsOneWidget);
        expect(
          t.takeException(),
          isNull,
          reason: 'a 200-character line must not overflow a 360-wide card',
        );
      },
    );

    testWidgets('the three choices report allow, always and deny', (t) async {
      final decisions = await pump(t, question());
      await t.tap(find.byKey(const ValueKey('ai-approve-once')));
      await t.tap(find.byKey(const ValueKey('ai-approve-always')));
      await t.tap(find.byKey(const ValueKey('ai-deny')));
      expect(decisions, [(true, false), (true, true), (false, false)]);
    });

    testWidgets('the always button explains its scope in a tooltip', (t) async {
      await pump(t, question(action: 'edit'));
      expect(find.byTooltip('之后本会话里 AI 修改任何文件都不再询问；新对话仍会询问'), findsOneWidget);
      await pump(t, question(action: 'shell', resource: 'git status'));
      expect(find.byTooltip('之后本会话里同一个命令开头的命令不再询问；新对话仍会询问'), findsOneWidget);
    });

    testWidgets('it fits a phone-width column in light and dark', (t) async {
      for (final b in Brightness.values) {
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(b),
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: AiPermissionCard(
                  question: question(
                    action: 'shell',
                    resource: 'find / -name "*.log" -mtime +30 -print',
                    reason: 'Shell command execution requires approval',
                  ),
                  workdir: '/srv/some/rather/long/working/directory/name',
                  onDecide: ({required bool allow, bool always = false}) {},
                ),
              ),
            ),
          ),
        );
        expect(t.takeException(), isNull, reason: '$b');
      }
    });
  });
}
