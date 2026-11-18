import 'dart:async';

import 'package:aurora/features/net/net_feature.dart';
import 'package:aurora/features/systemd/systemd_feature.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora/state/local_agent.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/terminal_fixture.dart';
import 'support/workspace_fixture.dart';

class _Link extends FileTreeLink {
  final requests = <String>[];
  Future<Object?> Function(String, Object?)? handler;
  MemoryTerminalStream? terminal;
  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) {
    requests.add(op);
    if (op == 'agent.services' || op == 'fs.roots') return super.call(op, args, timeout);
    return handler?.call(op, args) ?? Future.value({});
  }
  @override
  Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async {
    requests.add(op);
    return terminal!;
  }
}

class _App extends WorkspaceApp {
  Link? current;
  _App(this.current);
  @override
  Link? link(String id) => current;
  void reconnect(Link? next) { current = next; notifyListeners(); }
}

class _Forward extends Fake implements Forward {
  @override
  final String host = '127.0.0.1';
  @override
  final int port = 8080, local = 18080;
  bool closed = false;
  @override
  bool get isClosed => closed;
  @override int get connections => 0;
  @override int get bytesIn => 0;
  @override int get bytesOut => 0;
  @override String? get lastError => null;
  @override
  Future<void> close() async { closed = true; }
}

class _Local extends LocalAgent {
  final gate = Completer<Target>();
  int starts = 0;
  @override
  Future<Target> start(String stateDir) { starts++; return gate.future; }
  @override
  Future<void> stop() async {}
}

class _LocalApp extends AppState {
  final data = Profile(servers: [ServerEntry(id: 'local', name: 'Local', kind: 'local')]);
  _LocalApp(_Local local) : super(localAgent: local) { storePath = r'C:\synthetic\profile.bin'; }
  @override
  Profile get profile => data.copy();
  @override
  ServerEntry? server(String id) => data.server(id);
}

void main() {
  test('concurrent terminal detach finishes once and releases pending heartbeats', () async {
    final stream = MemoryTerminalStream();
    final link = _Link()..terminal = stream;
    final terminal = await Terminal.attach(link, 'main');
    final heartbeat = expectLater(terminal.ping(), throwsA(isA<OpError>()));
    await Future.wait([terminal.close(), terminal.close()]);
    await heartbeat;
    expect(await terminal.done, TerminalEnd.detached);
    expect(stream.closes, 1);
    expect(stream.controls.where((m) => m['type'] == 'close'), hasLength(1));
    await terminal.write([65]);
    expect(stream.input, isEmpty);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  for (final dispose in [false, true]) {
    test('pending forward is closed after ${dispose ? 'disposal' : 'disconnect'}', () async {
      final ready = Completer<void>(), gate = Completer<Forward>();
      final forward = _Forward(), link = _Link();
      final manager = ForwardManager(listen: (_, _) { ready.complete(); return gate.future; });
      final entry = ServerEntry(id: 's', name: 'S', forwards: [ForwardSpec(port: 8080, local: 18080)]);
      final attaching = manager.attach(entry, link);
      await ready.future;
      Future<void>? detached;
      if (dispose) { manager.dispose(); } else { detached = manager.detach('s'); }
      gate.complete(forward);
      await attaching;
      await detached;
      expect(forward.closed, isTrue);
      expect(manager.open('s', 18080), isNull);
      if (!dispose) manager.dispose();
    });
  }

  test('repeated forward restarts share one listener', () async {
    final link = _Link(), forward = _Forward(), gate = Completer<Forward>();
    var calls = 0;
    final manager = ForwardManager(listen: (_, _) { calls++; return gate.future; });
    final entry = ServerEntry(id: 's', name: 'S');
    final spec = ForwardSpec(port: 8080, local: 18080);
    await manager.attach(entry, link);
    final first = manager.restart(entry, link, spec);
    final second = manager.restart(entry, link, spec);
    gate.complete(forward);
    await Future.wait([first, second]);
    expect(calls, 1);
    expect(manager.open('s', 18080), same(forward));
    await manager.detach('s');
    expect(forward.closed, isTrue);
    manager.dispose();
  });

  test('disconnect invalidates local bootstrap and duplicate connects coalesce', () async {
    final local = _Local();
    final active = _LocalApp(local);
    final first = active.connect('local'), second = active.connect('local');
    expect(local.starts, 1);
    await active.disconnect('local');
    local.gate.complete(Target(addrs: ['127.0.0.1:1'], pin: '0' * 64, token: 'fixture'));
    await Future.wait([first, second]);
    expect(active.link('local'), isNull);
    expect(active.status('local').state, ConnState.idle);
    active.dispose();
  });

  Future<void> host(WidgetTester t, Widget child, {bool visible = true}) async {
    final input = InputMode(touch: false);
    addTearDown(input.dispose);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark),
      home: InputMode.scope(mode: input, child: Scaffold(
        body: TickerMode(enabled: visible, child: child),
      )),
    ));
    await t.pump();
  }

  testWidgets('terminal reconnect overtakes a held old attach without duplicate streams', (t) async {
    final old = _Link()..terminal = MemoryTerminalStream(hold: true);
    final next = _Link()..terminal = MemoryTerminalStream();
    final app = _App(old);
    final space = Workspace(app, 'server');
    await host(t, SessionView(ws: space, session: 'main'));
    expect(old.requests.where((op) => op == 'terminal'), hasLength(1));
    app.reconnect(next);
    await t.pump();
    await t.pump();
    expect(next.requests.where((op) => op == 'terminal'), hasLength(1));
    old.terminal!.ready.complete();
    await t.pump();
    await t.pump();
    expect(old.terminal!.closes, greaterThan(0));
    expect(next.terminal!.closes, 0);
    next.terminal!.output('new terminal');
    await t.pump();
    expect(find.text('正在连接…'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    space.dispose(); app.dispose();
  });

  testWidgets('log follow pauses hidden polling and keeps narrow toolbar usable', (t) async {
    t.view.physicalSize = const Size(320, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
    final link = _Link()..handler = (op, _) async => {'lines': 'one\ntwo\n', 'exit_code': 0};
    final app = _App(link);
    final space = Workspace(app, 'server');
    final visibility = ValueNotifier(true);
    final child = ValueListenableBuilder<bool>(
      valueListenable: visibility, child: LogView(ws: space, unit: ''),
      builder: (_, on, child) => TickerMode(enabled: on, child: child!),
    );
    await host(t, child);
    await t.pump();
    await t.tap(find.byTooltip('跟随（每 3 秒刷新）'));
    await t.pump();
    final before = link.requests.where((op) => op == 'log.tail').length;
    visibility.value = false;
    await t.pump();
    await t.pump(const Duration(seconds: 9));
    expect(link.requests.where((op) => op == 'log.tail'), hasLength(before));
    visibility.value = true;
    await t.pump();
    await t.pump();
    expect(link.requests.where((op) => op == 'log.tail').length, greaterThan(before));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    visibility.dispose(); space.dispose(); app.dispose();
  });

  testWidgets('manual port validation keeps the entered address in its dialog', (t) async {
    await host(t, const ForwardDialog());
    await t.enterText(find.byType(TextField).first, 'db.internal:70000');
    await t.tap(find.text('转发'));
    await t.pump();
    expect(find.byType(ForwardDialog), findsOneWidget);
    expect(find.text('db.internal:70000'), findsOneWidget);
    expect(find.textContaining('端口须在'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('failed forward persistence closes only its new listener and preserves saved listeners on failed deletion', (t) async {
    final link = _Link()..handler = (_, _) async => {'ports': []};
    final app = _App(link)..failChanges = true;
    final ws = Workspace(app, 'server');
    final opened = <_Forward>[];
    final manager = ForwardManager(listen: (_, _) async { final f = _Forward(); opened.add(f); return f; });
    await manager.attach(ws.entry!, link);
    await host(t, ForwardPanel(ws: ws, manager: manager));
    await t.tap(find.text('新建转发')); await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '8080');
    await t.enterText(find.byType(TextField).last, '18080');
    await t.tap(find.text('转发')); await t.pumpAndSettle();
    expect(opened.single.closed, isTrue);
    expect(manager.open('server', 18080), isNull);
    expect(app.server('server')!.forwards, isEmpty);
    final spec = ForwardSpec(port: 8080, local: 18080);
    app.data.server('server')!.forwards.add(spec);
    await manager.restart(ws.entry!, link, spec);
    await t.pump();
    expect(manager.open('server', 18080), same(opened.last));
    await t.tap(find.byTooltip('删除这个转发')); await t.pumpAndSettle();
    expect(opened.last.closed, isFalse);
    expect(app.server('server')!.forwards, hasLength(1));
    await t.pumpWidget(const SizedBox()); await t.pump();
    await manager.detach('server'); manager.dispose(); ws.dispose(); app.dispose();
  });

  testWidgets('log follow buffers new content while reading and preserves the scroll anchor', (t) async {
    var revision = 1;
    final link = _Link()..handler = (_, _) async => {
      'lines': List.generate(200, (i) => 'revision $revision / line $i').join('\n'), 'exit_code': 0,
    };
    final app = _App(link);
    final space = Workspace(app, 'server');
    await host(t, LogView(ws: space, unit: 'web.service'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('跟随（每 3 秒刷新）')); await t.pump();
    final list = find.descendant(of: find.byType(LogView), matching: find.byType(ListView));
    final controller = t.widget<ListView>(list).controller!;
    controller.jumpTo(100); await t.pump();
    final before = controller.offset;
    revision = 2;
    await t.pump(const Duration(seconds: 3)); await t.pump();
    expect(controller.offset, before);
    expect(find.textContaining('revision 2'), findsNothing);
    expect(find.textContaining('revision 1'), findsWidgets);
    await t.pumpWidget(const SizedBox()); await t.pump();
    space.dispose(); app.dispose();
  });
}
