import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/features/development/debug_panel.dart';
import 'package:aurora/kernel/development/debug_model.dart';
import 'package:aurora/kernel/development/development_model.dart';
import 'package:aurora/kernel/development/development_store.dart';
import 'package:aurora/kernel/development/task_model.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/workspace_fixture.dart';

class _Stream extends Fake implements OpStream {
  final frames = StreamController<Frame>();
  late final iterator = StreamIterator(frames.stream);
  final messages = <Map<String, dynamic>>[];
  final sent = StreamController<Map<String, dynamic>>.broadcast();
  final resetDone = Completer<void>();
  void Function()? onResponse;
  void Function(Map<String, dynamic>)? onMessage;
  bool closed = false;
  void receive(Map<String, Object?> event, {bool data = false}) {
    if (!closed)
      frames.add(
        Frame(
          data ? typeData : typeJson,
          Uint8List.fromList(utf8.encode(jsonEncode(event))),
        ),
      );
  }

  @override
  Future<Object?> response() async {
    onResponse?.call();
    return {};
  }

  @override
  Future<Frame?> read() async =>
      await iterator.moveNext() ? iterator.current : null;
  @override
  Future<void> sendData(List<int> bytes) async {
    final message = (jsonDecode(utf8.decode(bytes)) as Map)
        .cast<String, dynamic>();
    messages.add(message);
    sent.add(message);
    onMessage?.call(message);
  }

  Future<Map<String, dynamic>> saw(String command) async =>
      messages.where((m) => m['command'] == command).firstOrNull ??
      await sent.stream
          .firstWhere((m) => m['command'] == command)
          .timeout(const Duration(seconds: 3));
  @override
  void reset() {
    if (closed) return;
    closed = true;
    resetDone.complete();
    unawaited(frames.close());
    unawaited(sent.close());
  }
}

class _Link extends FileTreeLink {
  final task = _Stream(), dap = _Stream();
  final opened = <String>[];
  Completer<OpStream>? taskGate, debugGate;
  @override
  AgentInfo get server => AgentInfo({
    'caps': ['task.run', 'dap.start', 'devtools.config'],
  });
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    opened.add(op);
    if (op == 'task.run') return taskGate?.future ?? task;
    return debugGate?.future ?? dap;
  }
}

class _App extends WorkspaceApp {
  Link current;
  _App(this.current);
  @override
  Link? link(String id) => current;
  void reconnect(Link next) {
    current = next;
    notifyListeners();
  }
}

DevelopmentScope fixtureScope({String? prelaunch}) => DevelopmentScope(
  'home',
  '/project',
  'file:///C:/work%20space',
  'file:///C:/work%20space/project',
  'windows',
  'etag',
  {
    'version': 1,
    'tasks': [
      {
        'id': 'test',
        'command': ['go', 'test', '-json', './...'],
        'group': 'test',
        'testFormat': 'go-json',
      },
    ],
    'debug': [
      {
        'id': 'dart',
        'command': ['dart', 'debug_adapter'],
        'request': 'launch',
        'arguments': {'program': r'${workspaceFolder}/main.dart'},
        if (prelaunch != null) 'preLaunchTask': prelaunch,
      },
    ],
  },
);

Future<void> changedUntil(
  ChangeNotifier model,
  bool Function() predicate,
) async {
  if (predicate()) return;
  final done = Completer<void>();
  void changed() {
    if (predicate() && !done.isCompleted) done.complete();
  }

  model.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 4));
  } finally {
    model.removeListener(changed);
  }
}

void _dartAdapter(_Stream stream, {bool holdVariables = false}) {
  Map<String, dynamic>? launch;
  void reply(Map message, Object? body) => stream.receive({
    'type': 'response',
    'seq': 1000 + (message['seq'] as int),
    'request_seq': message['seq'],
    'command': message['command'],
    'success': true,
    'body': body,
  }, data: true);
  stream.onMessage = (m) {
    switch (m['command']) {
      case 'initialize':
        reply(m, {
          'supportsConfigurationDoneRequest': true,
          'supportsConditionalBreakpoints': true,
          'supportsHitConditionalBreakpoints': true,
          'supportsLogPoints': true,
        });
      case 'launch':
        launch = m;
        stream.receive({'type': 'event', 'event': 'initialized'}, data: true);
      case 'setBreakpoints':
        final points = m['arguments']['breakpoints'] as List;
        reply(m, {
          'breakpoints': [
            for (var i = 0; i < points.length; i++)
              {'id': i + 1, 'verified': true, 'line': points[i]['line']},
          ],
        });
      case 'configurationDone':
        reply(m, {});
        reply(launch!, {});
      case 'threads':
        reply(m, {
          'threads': [
            {'id': 1, 'name': 'main'},
          ],
        });
      case 'stackTrace':
        reply(m, {
          'totalFrames': 1,
          'stackFrames': [
            {
              'id': 10,
              'name': 'main',
              'line': 3,
              'column': 1,
              'source': {'path': r'C:\work space\project\main.dart'},
            },
          ],
        });
      case 'scopes':
        reply(m, {
          'scopes': [
            {'name': 'Locals', 'variablesReference': 20},
          ],
        });
      case 'variables':
        if (!holdVariables)
          reply(m, {
            'variables': [
              {'name': 'answer', 'value': '42', 'variablesReference': 0},
            ],
          });
      case 'evaluate':
        reply(m, {'result': '42'});
      case 'source':
        reply(m, {'content': 'virtual source\n'});
      default:
        reply(m, {});
    }
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('task completion already in transport cannot undo cancellation', () async {
    final link = _Link();
    final app = _App(link);
    final ws = Workspace(app, 'server');
    final run = await ws.tasks.start(fixtureScope(), 'test');
    await Future<void>.delayed(Duration.zero);
    link.task.receive({'type': 'complete', 'code': 0});
    ws.tasks.cancel(run.id);
    await Future<void>.delayed(Duration.zero);
    expect(run.status, 'cancelled');
    expect(await run.done, -1);
    ws.dispose(); app.dispose();
  });

  test('debug control is single-flight even when its acknowledgement is held', () async {
    final link = _Link();
    _dartAdapter(link.dap);
    final app = _App(link);
    final ws = Workspace(app, 'server'), model = ws.debugger;
    await model.start(fixtureScope(), 'dart');
    link.dap.receive({'type': 'event', 'event': 'stopped', 'body': {'threadId': 1}}, data: true);
    await changedUntil(model, () => model.stopped && model.frameId != null);
    final original = link.dap.onMessage!;
    Map<String, dynamic>? held;
    link.dap.onMessage = (m) {
      if (m['command'] == 'next') { held = m; } else { original(m); }
    };
    final first = model.control('next');
    await link.dap.saw('next');
    await model.control('next');
    expect(model.controlling, isTrue);
    expect(link.dap.messages.where((m) => m['command'] == 'next'), hasLength(1));
    original(held!);
    await first;
    expect(model.controlling, isFalse);
    expect(model.phase, DebugPhase.running);
    await model.stop();
    ws.dispose(); app.dispose();
  });

  testWidgets(
    'narrow breakpoint editor saves every field and virtual source is read-only',
    (t) async {
      t.view.physicalSize = const Size(360, 740);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final link = _Link();
      _dartAdapter(link.dap);
      final app = _App(link),
          ws = Workspace(app, 'server'),
          model = ws.debugger;
      final input = InputMode(touch: true);
      Widget host(Widget child) => InputMode.scope(
        mode: input,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(body: child),
        ),
      );
      await model.toggleBreakpoint('home', '/project/main.dart', 3);
      await t.pumpWidget(host(DebugPanel(ws: ws)));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('编辑断点'));
      await t.pumpAndSettle();
      for (final pair in [
        ('条件表达式', 'answer > 0'),
        ('命中次数条件', '3'),
        ('日志断点消息', 'answer {answer}'),
      ]) {
        final field = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == pair.$1,
        );
        await t.ensureVisible(field);
        await t.pumpAndSettle();
        await t.enterText(field, pair.$2);
      }
      await t.tap(find.text('保存断点'));
      await t.pumpAndSettle();
      expect(model.breakpoints.single.condition, 'answer > 0');
      expect(model.breakpoints.single.hitCondition, '3');
      expect(model.breakpoints.single.logMessage, 'answer {answer}');
      final starting = model.start(fixtureScope(), 'dart');
      await t.pumpAndSettle();
      expect(model.phase, DebugPhase.running);
      await starting;
      await t.pumpWidget(
        host(
          DebugSourceView(
            model: model,
            name: 'generated.dart',
            frame: const {
              'line': 1,
              'source': {'name': 'generated.dart', 'sourceReference': 42},
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      final editor = t.widget<CodeEditor>(find.byType(CodeEditor));
      expect(editor.readOnly, isTrue);
      expect(editor.controller!.text, 'virtual source\n');
      expect(ws.documents.all, isEmpty);
      final stopping = model.stop();
      await t.pumpAndSettle();
      expect(model.phase, DebugPhase.terminated);
      await stopping;
      expect(editor.controller!.text, 'virtual source\n');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
      input.dispose();
    },
  );

  test('breakpoints follow multiline edits, undo and whole-document deletion and persist', () async {
    final link = _Link(), app = _App(_Link());
    app.current = link;
    final ws = Workspace(app, 'server'), model = ws.debugger;
    final doc = ws.documents.open('home', '/project/main.dart');
    await doc.load();
    doc.replaceText('header\ntarget\ntail\n', expectedVersion: doc.version);
    await model.toggleBreakpoint('home', '/project/main.dart', 2);
    doc.replaceText(
      'inserted\nheader\ntarget\ntail\n',
      expectedVersion: doc.version,
    );
    expect(model.breakpoints.single.line, 3);
    doc.controller.undo();
    expect(model.breakpoints.single.line, 2);
    doc.replaceText('', expectedVersion: doc.version);
    expect(model.breakpoints.single.line, 1);
    await model.flush();
    await ws.documents.flush();
    ws.dispose();
    final restored = Workspace(app, 'server');
    await restored.debugger.ready;
    expect(restored.debugger.breakpoints.single.line, 1);
    restored.dispose();
    app.dispose();
  });

  test('conditional, hit-count and log breakpoints reach DAP and virtual source remains a snapshot', () async {
    final link = _Link();
    _dartAdapter(link.dap);
    final app = _App(link), ws = Workspace(app, 'server'), model = ws.debugger;
    await model.toggleBreakpoint('home', '/project/main.dart', 3);
    await model.updateBreakpoint(
      model.breakpoints.single,
      condition: 'answer > 0',
      hitCondition: '3',
      logMessage: 'answer {answer}',
    );
    await model.start(fixtureScope(), 'dart');
    final sent = await link.dap.saw('setBreakpoints');
    expect(sent['arguments']['breakpoints'], [
      {
        'line': 3,
        'condition': 'answer > 0',
        'hitCondition': '3',
        'logMessage': 'answer {answer}',
      },
    ]);
    final content = await model.readSource({
      'source': {'name': 'virtual.dart', 'sourceReference': 42},
    });
    expect(content, 'virtual source\n');
    expect((await link.dap.saw('source'))['arguments']['sourceReference'], 42);
    expect(ws.documents.all, isEmpty);
    await model.stop();
    ws.dispose();
    app.dispose();
  });

  test('task parsers preserve chunked Unicode, compiler paths, Go JSON and TAP results', () {
    final scope = fixtureScope();
    final run = TaskRun(
      '1',
      'test',
      'Test',
      'home',
      '/project',
      'test',
      DateTime.now(),
    );
    final parser = TaskOutputParser(run, scope);
    parser.started('build', {}, scope.workspaceUri);
    parser.append('build', 'stderr', 'src/中文.dart:12:3: warn');
    parser.append('build', 'stderr', 'ing: sample\n');
    parser.append(
      'build',
      'stderr',
      r'C:\work space\project\main.dart:3: problem',
    );
    parser.started('test', {'testFormat': 'go-json'}, scope.workspaceUri);
    final json =
        '${jsonEncode({'Action': 'output', 'Package': 'pkg', 'Test': 'Test一', 'Output': '中文\n'})}\n'
        '${jsonEncode({'Action': 'pass', 'Package': 'pkg', 'Test': 'Test一', 'Elapsed': 0.25})}\n';
    parser.append('test', 'stdout', json.substring(0, 17));
    parser.append('test', 'stdout', json.substring(17));
    parser.started('tap', {'testFormat': 'tap'}, scope.workspaceUri);
    parser.append(
      'tap',
      'stdout',
      'ok 1 - first\nnot ok 2 - second\nok 3 - third # SKIP unavailable\n',
    );
    parser.finish();
    expect(run.problems.map((p) => p.path), [
      '/project/src/中文.dart',
      '/project/main.dart',
    ]);
    expect(run.problems.first.severity, 'warning');
    expect(run.tests.values.map((t) => t.status), [
      'pass',
      'pass',
      'fail',
      'skip',
    ]);
    expect(run.tests.values.first.output, '中文\n');
    expect(run.tests.values.first.elapsed, 0.25);
    expect(
      developmentPath(scope, '../../outside.dart', scope.workspaceUri),
      isNull,
    );
    parser.append('test', 'stdout', 'x' * (200 * 1024));
    expect(run.output.length, lessThanOrEqualTo(128 * 1024));
    expect(run.outputTruncated, isTrue);
  });

  test('completed tasks retain logs, exit status, tests and survive workspace recreation', () async {
    final link = _Link(), app = _App(_Link());
    app.current = link;
    final ws = Workspace(app, 'server'), scope = fixtureScope();
    link.task.onResponse = () {
      link.task.receive({
        'type': 'started',
        'task': 'test',
        'configuration': {'testFormat': 'go-json'},
        'cwd': scope.workspaceUri,
      });
      link.task.receive({
        'type': 'output',
        'task': 'test',
        'stream': 'stdout',
        'text':
            '${jsonEncode({'Action': 'fail', 'Package': 'pkg', 'Test': 'TestFailure'})}\nmain.dart:2:1: failure\n',
      });
      link.task.receive({'type': 'complete', 'code': 1});
    };
    final run = await ws.tasks.start(scope, 'test');
    expect(await run.done, 1);
    expect(run.status, 'failed');
    expect(run.tests.values.single.status, 'fail');
    expect(run.problems.single.path, '/project/main.dart');
    await ws.tasks.flush();
    ws.dispose();
    final reopened = Workspace(app, 'server');
    await reopened.tasks.ready;
    expect(reopened.tasks.history.single.exitCode, 1);
    expect(reopened.tasks.history.single.output, contains('failure'));
    reopened.dispose();
    app.dispose();
  });

  test(
    'cancelled late task handshake is reset and never changes the result',
    () async {
      final link = _Link()..taskGate = Completer<OpStream>();
      final app = _App(link), ws = Workspace(app, 'server');
      final run = await ws.tasks.start(fixtureScope(), 'test');
      ws.tasks.cancel(run.id);
      expect(await run.done, -1);
      link.taskGate!.complete(link.task);
      await link.task.resetDone.future;
      expect(run.status, 'cancelled');
      expect(run.output, isEmpty);
      ws.dispose();
      app.dispose();
    },
  );

  test(
    'agent RE2 problems are consumed once, scoped, bounded and persisted',
    () async {
      final link = _Link(), app = _App(_Link());
      app.current = link;
      final ws = Workspace(app, 'server'), scope = fixtureScope();
      // RE2 accepts this syntax; the client must not compile it as Dart regex.
      (scope.config['tasks'] as List).single['problemPattern'] =
          r'(?P<file>.+):(?P<line>\d+):(?P<message>.+)';
      link.task.onResponse = () {
        link.task.receive({
          'type': 'started',
          'task': 'test',
          'configuration': scope.entries('tasks').single,
          'cwd': scope.workspaceUri,
          'problemMatching': 'agent-re2',
        });
        link.task.receive({
          'type': 'output',
          'task': 'test',
          'stream': 'stderr',
          'text': 'ignored.dart:1:1: already parsed on agent\n',
        });
        for (final path in ['../../outside', 'src/中文.dart', 'src/中文.dart']) {
          link.task.receive({
            'type': 'problem',
            'task': 'test',
            'problem': {
              'file': path,
              'line': 12,
              'column': 3,
              'message': '警告',
              'severity': 'warning',
            },
          });
        }
        for (var i = 0; i < 600; i++) {
          link.task.receive({
            'type': 'problem',
            'task': 'test',
            'problem': {
              'file': 'src/item$i.dart',
              'line': 1,
              'message': 'error $i',
            },
          });
        }
        link.task.receive({'type': 'complete', 'code': 1});
      };
      final run = await ws.tasks.start(scope, 'test');
      expect(await run.done, 1);
      expect(run.problems, hasLength(500));
      expect(run.problems.first.path, '/project/src/中文.dart');
      expect(run.problems.first.severity, 'warning');
      expect(
        run.problems.where((p) => p.path.endsWith('ignored.dart')),
        isEmpty,
      );
      await ws.tasks.flush();
      ws.dispose();
      final restored = Workspace(app, 'server');
      await restored.tasks.ready;
      expect(restored.tasks.history.single.problems, hasLength(500));
      restored.dispose();
      app.dispose();
    },
  );

  test('DAP waits for configuration before launch, verifies breakpoints, selects stack and evaluates', () async {
    final link = _Link();
    _dartAdapter(link.dap);
    final app = _App(link), ws = Workspace(app, 'server');
    final model = ws.debugger;
    await model.toggleBreakpoint('home', '/project/main.dart', 3);
    await model.addWatch('answer');
    await model.start(fixtureScope(), 'dart');
    expect(model.phase, DebugPhase.running);
    expect(model.breakpoints.single.verified, isTrue);
    final commands = link.dap.messages.map((m) => m['command']).toList();
    expect(
      commands.indexOf('setBreakpoints'),
      lessThan(commands.indexOf('configurationDone')),
    );
    expect(
      (await link.dap.saw('launch'))['arguments']['program'],
      r'C:\work space\project/main.dart',
    );
    link.dap.receive({
      'type': 'event',
      'event': 'stopped',
      'body': {'threadId': 1, 'reason': 'breakpoint'},
    }, data: true);
    await changedUntil(model, () => model.watchValues['answer'] == '42');
    expect(model.frameId, 10);
    expect(model.pathForFrame(model.frames.single), '/project/main.dart');
    expect((await model.variables(20)).single['value'], '42');
    await model.control('next');
    expect(model.phase, DebugPhase.running);
    expect(model.scopes, isEmpty);
    await model.stop();
    expect(link.dap.closed, isTrue);
    expect(model.phase, DebugPhase.terminated);
    await model.flush();
    ws.dispose();
    final restored = Workspace(app, 'server');
    await restored.debugger.ready;
    expect(restored.debugger.breakpoints.single.line, 3);
    expect(restored.debugger.watches, ['answer']);
    restored.dispose();
    app.dispose();
  });

  test('late variables after continue are discarded and failed prelaunch never starts adapter', () async {
    final link = _Link();
    _dartAdapter(link.dap, holdVariables: true);
    final app = _App(link), ws = Workspace(app, 'server');
    final model = ws.debugger;
    await model.start(fixtureScope(), 'dart');
    link.dap.receive({
      'type': 'event',
      'event': 'stopped',
      'body': {'threadId': 1},
    }, data: true);
    await changedUntil(model, () => model.scopes.isNotEmpty);
    final pending = model.variables(20);
    final request = await link.dap.saw('variables');
    await model.control('continue');
    link.dap.receive({
      'type': 'response',
      'request_seq': request['seq'],
      'success': true,
      'body': {
        'variables': [
          {'name': 'stale', 'value': 'old'},
        ],
      },
    }, data: true);
    expect(await pending, isEmpty);
    await model.stop();
    final newLink = _Link();
    newLink.task.onResponse = () =>
        newLink.task.receive({'type': 'complete', 'code': 7});
    app.reconnect(newLink);
    await model.start(fixtureScope(prelaunch: 'test'), 'dart');
    expect(model.phase, DebugPhase.failed);
    expect(newLink.opened, ['task.run']);
    expect(model.error, contains('前置任务失败'));
    ws.dispose();
    app.dispose();
  });

  test('reconnect cancels delayed adapter startup without replacing the new session', () async {
    final old = _Link()..debugGate = Completer<OpStream>(), next = _Link();
    _dartAdapter(next.dap);
    final app = _App(old), ws = Workspace(app, 'server'), model = ws.debugger;
    final starting = model.start(fixtureScope(), 'dart');
    await changedUntil(model, () => model.phase == DebugPhase.starting);
    app.reconnect(next);
    await model.start(fixtureScope(), 'dart');
    old.debugGate!.complete(old.dap);
    await starting;
    await old.dap.resetDone.future;
    expect(model.phase, DebugPhase.running);
    expect(next.dap.closed, isFalse);
    ws.dispose();
    app.dispose();
  });

  test('encrypted development sections survive concurrent writes and corrupt bytes remain intact', () async {
    final base = Directory(
      '${Platform.environment['LOCALAPPDATA']}/Temp/opencode',
    );
    final directory = await base.createTemp('aurora-development-');
    addTearDown(() => directory.delete(recursive: true));
    final store = DevelopmentStore.file(directory, DpapiSealer());
    await Future.wait([
      store.write('fixture', 'tasks', [
        {'output': 'private compiler output'},
      ]),
      store.write('fixture', 'debug', {
        'breakpoints': [1, 2],
      }),
    ]);
    final file = (await directory.list().toList()).whereType<File>().single;
    final encrypted = await file.readAsBytes();
    expect(
      utf8.decode(encrypted, allowMalformed: true),
      isNot(contains('private compiler output')),
    );
    final reopened = DevelopmentStore.file(directory, DpapiSealer());
    expect(await reopened.read('fixture', 'debug'), {
      'breakpoints': [1, 2],
    });
    await file.writeAsBytes([1, 2, 3, 4], flush: true);
    await expectLater(
      reopened.write('fixture', 'tasks', []),
      throwsA(isA<Object>()),
    );
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
  }, skip: !Platform.isWindows);
}
