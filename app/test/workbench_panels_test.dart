import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/workbench_view.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart' as w;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'support/workspace_fixture.dart';
import 'support/terminal_fixture.dart';

class _Buffer extends StatefulWidget {
  final String id;
  final Map<String, int> opened, disposed;
  const _Buffer(this.id, this.opened, this.disposed);
  @override
  State<_Buffer> createState() => _BufferState();
}

class _BufferState extends State<_Buffer> {
  final text = TextEditingController(), focus = FocusNode();
  @override
  void initState() {
    super.initState();
    widget.opened.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.disposed.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Align(
      alignment: Alignment.topLeft,
      child: TextField(
        key: ValueKey('buffer-${widget.id}'),
        controller: text,
        focusNode: focus,
      ),
    ),
  );
}

class _TerminalLink extends FileTreeLink {
  final List<MemoryTerminalStream> streams = [];
  final List<String> killed = [];
  bool hold = false;
  @override
  Future<w.OpStream> open(
    String op, [
    Object? args,
    w.Priority priority = w.Priority.interactive,
  ]) async {
    if (op != 'terminal') throw StateError('Unexpected fixture stream');
    final stream = MemoryTerminalStream(hold: hold);
    streams.add(stream);
    return stream;
  }

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'session.kill') {
      killed.add((args as Map)['name'] as String);
      return {'ok': true};
    }
    if (op == 'session.list') {
      return {
        'sessions': [
          {'name': 'main'},
        ],
      };
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  late WorkspaceApp app;
  late Workspace ws;
  late InputMode input;
  late Map<String, int> opened, disposed;
  setUp(() {
    app = WorkspaceApp();
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
    opened = {};
    disposed = {};
  });
  tearDown(() async {
    await ws.flushViews();
    ws.dispose();
    app.dispose();
    input.dispose();
  });
  void open(String id, {bool terminal = false}) => ws.openTab(
    EditorTab(
      id: id,
      title: id,
      area: terminal ? TabArea.terminal : TabArea.editor,
      icon: terminal ? Icons.terminal : Icons.description,
      builder: (_) => _Buffer(id, opened, disposed),
    ),
  );
  Future<void> pump(
    WidgetTester t, {
    Size size = const Size(1200, 800),
    bool settle = true,
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(
            body: ListenableBuilder(
              listenable: ws,
              builder: (_, _) => WorkbenchView(
                ws: ws,
                empty: const Center(child: Text('Editor welcome')),
                terminalSessionsBuilder: (_) => const Text('Session catalog'),
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) await t.pumpAndSettle();
  }

  Future<void> finish(WidgetTester t) async {
    await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    await t.pump();
  }

  TextField field(WidgetTester t, String id) => t.widget<TextField>(
    find.byKey(ValueKey('buffer-$id'), skipOffstage: false),
  );

  testWidgets(
    'terminal lives below the document grid, hiding and maximizing retain every buffer',
    (t) async {
      open('a');
      open('b');
      ws.splitGroup(SplitAxis.horizontal, tabId: 'b');
      open('term:main', terminal: true);
      await pump(t);
      final editor = t.getRect(find.byKey(const ValueKey('workbench-editor')));
      final terminal = t.getRect(
        find.byKey(const ValueKey('workbench-terminal')),
      );
      expect(editor.bottom, lessThan(terminal.top));
      expect(find.byKey(const ValueKey('tab-term:main')), findsNothing);
      expect(ws.tabLayout.owner('term:main'), isNull);
      await t.enterText(
        find.byKey(const ValueKey('buffer-term:main')),
        'pending shell input',
      );
      await t.tap(find.byKey(const ValueKey('buffer-a')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('buffer-a')),
        'unsaved document',
      );
      final root = ws.tabLayout.root;
      for (var i = 0; i < 5; i++) {
        ws.hideTerminalPanel();
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('buffer-term:main')), findsNothing);
        ws.showTerminalPanel();
        await t.pumpAndSettle();
        ws.toggleTerminalMaximized();
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('buffer-a')), findsNothing);
        ws.toggleTerminalMaximized();
        await t.pumpAndSettle();
      }
      expect(ws.tabLayout.root, same(root));
      expect(field(t, 'a').controller!.text, 'unsaved document');
      expect(field(t, 'term:main').controller!.text, 'pending shell input');
      expect(opened, {'a': 1, 'b': 1, 'term:main': 1});
      expect(disposed, isEmpty);
      await finish(t);
    },
  );

  testWidgets(
    'selection and keyboard focus are independent between editor and terminal',
    (t) async {
      open('a');
      open('term:main', terminal: true);
      open('term:other', terminal: true);
      await pump(t);
      await t.tap(find.byKey(const ValueKey('buffer-term:other')));
      await t.pump();
      expect(ws.focusedId, 'term:other');
      expect(field(t, 'term:other').focusNode!.hasFocus, isTrue);
      ws.focusGroupAt(0);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('buffer-a')));
      await t.pump();
      expect(ws.focusedId, 'a');
      expect(ws.terminalActiveId, 'term:other');
      ws.setTerminalHeight(310);
      await t.pumpAndSettle();
      expect(
        field(t, 'a').focusNode!.hasFocus,
        isTrue,
        reason: 'a resize must not activate the terminal',
      );
      ws.showTerminalPanel();
      await t.pumpAndSettle();
      expect(field(t, 'term:other').focusNode!.hasFocus, isTrue);
      ws.next(1);
      await t.pumpAndSettle();
      expect(ws.focusedId, 'term:main');
      expect(ws.editorActiveId, 'a');
      ws.hideTerminalPanel();
      await t.pumpAndSettle();
      expect(ws.focusedId, 'a');
      await finish(t);
    },
  );

  testWidgets(
    'compact windows switch regions, returning wide restores the unchanged editor grid',
    (t) async {
      open('a');
      open('b');
      ws.splitGroup(SplitAxis.horizontal, tabId: 'b');
      open('term:main', terminal: true);
      await pump(t);
      final root = ws.tabLayout.root;
      t.view.physicalSize = const Size(390, 700);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('buffer-term:main')), findsOneWidget);
      expect(find.byKey(const ValueKey('buffer-b')), findsNothing);
      ws.activate('b');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('buffer-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('buffer-term:main')), findsNothing);
      ws.activate('term:main');
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(1200, 800);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('buffer-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('buffer-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('buffer-term:main')), findsOneWidget);
      expect(ws.tabLayout.root, same(root));
      expect(opened.values, everyElement(1));
      await finish(t);
    },
  );

  testWidgets(
    'dragging a document over the terminal is not a cross-host drop',
    (t) async {
      open('a');
      open('b');
      open('term:main', terminal: true);
      await pump(t);
      final before = ws.tabLayout.toJson().toString();
      final gesture = await t.startGesture(
        t.getCenter(find.byKey(const ValueKey('tab-b'))),
      );
      await gesture.moveBy(const Offset(25, 0));
      await t.pump();
      await gesture.moveTo(
        t.getCenter(find.byKey(const ValueKey('terminal-viewport-term:main'))),
      );
      await t.pump();
      await gesture.up();
      await t.pumpAndSettle();
      expect(ws.tabLayout.toJson().toString(), before);
      expect(ws.terminalTabs.single.id, 'term:main');
      expect(disposed, isEmpty);
      await finish(t);
    },
  );

  testWidgets(
    'terminal panel resize has bounded geometry and no editor/terminal overlap',
    (t) async {
      open('a');
      open('term:main', terminal: true);
      await pump(t);
      await t.drag(
        find.byKey(const ValueKey('terminal-panel-resize')),
        const Offset(0, -120),
      );
      await t.pumpAndSettle();
      expect(ws.terminalPanel.height, greaterThan(260));
      final editor = t.getRect(find.byKey(const ValueKey('workbench-editor')));
      final terminal = t.getRect(
        find.byKey(const ValueKey('workbench-terminal')),
      );
      expect(editor.height, greaterThanOrEqualTo(200));
      expect(editor.overlaps(terminal), isFalse);
      ws.setTerminalHeight(1200);
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byKey(const ValueKey('workbench-editor'))).height,
        200,
      );
      expect(t.takeException(), isNull);
      await finish(t);
    },
  );

  Future<_TerminalLink> realTerminalFixture() async {
    await ws.flushViews();
    ws.dispose();
    app.dispose();
    final link = _TerminalLink();
    app = WorkspaceApp(
      wire: link,
      profile: Profile(
        selected: 'server',
        servers: [
          ServerEntry(id: 'server', name: 'local fixture', kind: 'local'),
        ],
      ),
    );
    ws = Workspace(app, 'server');
    return link;
  }

  testWidgets(
    'real terminal output and its one attachment survive hide, resize and maximize',
    (t) async {
      final link = await realTerminalFixture();
      open('a');
      openSession(ws, 'main');
      await pump(t);
      expect(link.streams, hasLength(1));
      final stream = link.streams.single;
      final terminal = t
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      stream.output('visible fixture\r\n');
      await t.pump();
      ws.hideTerminalPanel();
      await t.pumpAndSettle();
      final resizes = stream.controls
          .where((message) => message['type'] == 'resize')
          .length;
      stream.output('background output retained\r\n');
      await t.pump();
      t.view.physicalSize = const Size(1400, 900);
      await t.pumpAndSettle();
      expect(
        stream.controls.where((message) => message['type'] == 'resize').length,
        resizes,
      );
      for (var i = 0; i < 4; i++) {
        ws.showTerminalPanel();
        await t.pumpAndSettle();
        ws.toggleTerminalMaximized();
        await t.pumpAndSettle();
        ws.hideTerminalPanel();
        await t.pumpAndSettle();
      }
      final screen = [
        for (var i = 0; i < terminal.buffer.lines.length; i++)
          terminal.buffer.lines[i].toString(),
      ].join('\n');
      expect(screen, contains('background output retained'));
      expect(link.streams, hasLength(1));
      expect(stream.closes, 0);
      expect(link.killed, isEmpty);
      await ws.closeTab('term:main');
      await t.pumpAndSettle();
      expect(stream.closes, 1);
      expect(link.killed, ['main']);
      expect(ws.visibleTabs.single.id, 'a');
      await finish(t);
    },
  );

  testWidgets(
    'a delayed terminal attach cannot steal focus back from an editor',
    (t) async {
      final link = (await realTerminalFixture())..hold = true;
      open('a');
      openSession(ws, 'main');
      await pump(t, settle: false);
      await t.pump();
      expect(link.streams, hasLength(1));
      ws.activate('a');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('buffer-a')));
      await t.pump();
      link.streams.single.ready.complete();
      await t.pumpAndSettle();
      expect(ws.focusedId, 'a');
      expect(field(t, 'a').focusNode!.hasFocus, isTrue);
      final view = t.widget<TerminalView>(find.byType(TerminalView));
      expect(view.focusNode!.hasFocus, isFalse);
      await finish(t);
    },
  );

  testWidgets(
    'a late terminal attachment also leaves an open dialog in control of focus',
    (t) async {
      final link = (await realTerminalFixture())..hold = true;
      open('a');
      openSession(ws, 'main');
      await pump(t, settle: false);
      await t.pump();
      final focus = FocusNode();
      final dialog = showDialog<void>(
        context: t.element(find.byType(WorkbenchView)),
        builder: (context) => AlertDialog(
          title: const Text('Synthetic dialog'),
          content: TextField(
            key: const ValueKey('dialog-input'),
            focusNode: focus,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close fixture'),
            ),
          ],
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      link.streams.single.ready.complete();
      await t.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(
        t.widget<TerminalView>(find.byType(TerminalView)).focusNode!.hasFocus,
        isFalse,
      );
      await t.tap(find.text('Close fixture'));
      await t.pumpAndSettle();
      await dialog;
      await finish(t);
      focus.dispose();
    },
  );
}
