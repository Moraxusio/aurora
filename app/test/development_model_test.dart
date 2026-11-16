import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora/kernel/development/development_model.dart';
import 'package:aurora/kernel/development/protocol_peer.dart';
import 'package:aurora/kernel/development/text_edits.dart';
import 'package:aurora/kernel/document_model.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/features/development/language_actions.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _PeerStream extends Fake implements OpStream {
  final frames = StreamController<Frame>();
  late final iterator = StreamIterator(frames.stream);
  final messages = <Map<String, dynamic>>[];
  final sent = StreamController<Map<String, dynamic>>.broadcast();
  final resetDone = Completer<void>();
  bool closed = false, delayHover = false;
  Object? completion;
  int resets = 0;
  Object syncCapability = {
    'openClose': true,
    'change': 1,
    'save': {'includeText': true},
  };
  void receive(Map<String, Object?> message) {
    if (!closed)
      frames.add(
        Frame(typeData, Uint8List.fromList(utf8.encode(jsonEncode(message)))),
      );
  }

  Future<Map<String, dynamic>> saw(String method) async =>
      messages.where((m) => m['method'] == method).firstOrNull ??
      await sent.stream
          .firstWhere((m) => m['method'] == method)
          .timeout(const Duration(seconds: 3));
  @override
  Future<Object?> response() async => <String, Object?>{};
  @override
  Future<Frame?> read() async =>
      await iterator.moveNext() ? iterator.current : null;
  @override
  Future<void> sendData(List<int> bytes) async {
    final message = (jsonDecode(utf8.decode(bytes)) as Map)
        .cast<String, dynamic>();
    messages.add(message);
    sent.add(message);
    if (message['id'] != null &&
        message['method'] != null &&
        !(delayHover && message['method'] == 'textDocument/hover')) {
      receive({
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': message['method'] == 'initialize'
            ? {
                'capabilities': {
                  'positionEncoding': 'utf-16',
                  'textDocumentSync': syncCapability,
                },
              }
            : message['method'] == 'textDocument/completion'
            ? completion
            : {'contents': 'documentation'},
      });
    }
  }

  @override
  void reset() {
    resets++;
    if (closed) return;
    closed = true;
    resetDone.complete();
    unawaited(frames.close());
    unawaited(sent.close());
  }
}

class _Link extends FileTreeLink {
  final peer = _PeerStream();
  final opened = Completer<void>();
  Completer<OpStream>? gate;
  int opens = 0;
  int configReads = 0;
  bool configFails = false;
  String contents = 'first\nsecond\n';
  @override
  AgentInfo get server => AgentInfo({
    'caps': ['fs.read', 'lsp.start', 'devtools.config'],
  });
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    if (op != 'lsp.start')
      throw OpError(codeUnavailable, 'fixture operation unavailable');
    opens++;
    if (!opened.isCompleted) opened.complete();
    return gate == null ? peer : gate!.future;
  }

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'devtools.config') {
      configReads++;
      if (configFails) throw StateError('invalid config');
      return {
        'rootUri': 'file:///C:/fixture',
        'workspaceUri': 'file:///C:/fixture/project',
        'platform': 'windows',
        'etag': 'config-v1',
        'config': {
          'version': 1,
          'languageServers': [
            {
              'id': 'fixture',
              'languages': ['dart'],
              'command': ['fixture'],
            },
          ],
        },
      };
    }
    if (op == 'fs.read') return {'content': contents, 'etag': 'v1'};
    if (op == 'fs.stat' || op == 'fs.write') return {'etag': 'v1'};
    return super.call(op, args, timeout);
  }
}

class _App extends WorkspaceApp {
  Link current;
  _App(this.current);
  @override
  Link? link(String id) => current;
  void reconnect(Link link) {
    current = link;
    notifyListeners();
  }
}

Future<void> languageReady(DevelopmentModel model, DocumentModel doc) async {
  if (model.sessionFor(doc)?.active == true) return;
  final ready = Completer<void>();
  void changed() {
    if (model.sessionFor(doc)?.active == true && !ready.isCompleted)
      ready.complete();
  }

  model.addListener(changed);
  try {
    await ready.future.timeout(const Duration(seconds: 4));
  } finally {
    model.removeListener(changed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'LSP snippet completion accounts for additional edits, CRLF and one insertion undo',
    (t) async {
      final link = _Link()..contents = '// h\r\npr\r\n';
      link.peer.completion = [
        {
          'label': 'print snippet',
          'insertTextFormat': 2,
          'textEdit': {
            'range': {
              'start': {'line': 1, 'character': 0},
              'end': {'line': 1, 'character': 2},
            },
            'newText': r'print(${1:value})$0',
          },
          'additionalTextEdits': [
            {
              'range': {
                'start': {'line': 0, 'character': 0},
                'end': {'line': 0, 'character': 0},
              },
              'newText': 'import "x";\n',
            },
          ],
        },
      ];
      final app = _App(link),
          ws = Workspace(app, 'server'),
          input = InputMode();
      final doc = ws.documents.open('home', '/project/main.dart');
      await doc.load();
      await ws.development.ensure(doc);
      doc.controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 2,
      );
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          scaffoldMessengerKey: Toast.key,
          home: InputMode.scope(
            mode: input,
            child: Builder(
              builder: (c) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      runLanguageAction(c, ws, doc, LanguageAction.completion),
                  child: const Text('complete'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('complete'));
      await t.pumpAndSettle();
      await t.tap(find.text('print snippet'));
      await t.pumpAndSettle();
      expect(
        ws.development.sessionFor(doc)?.active,
        isTrue,
        reason: '${ws.development.logs}\n${ws.development.failures}',
      );
      expect(
        doc.text,
        'import "x";\r\n// h\r\nprint(value)\r\n',
        reason: t
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((w) => w.data)
            .join('\n'),
      );
      expect(doc.controller.selection.baseIndex, 2);
      expect(doc.selectedText, 'value');
      doc.controller.undo();
      expect(doc.text, link.contents);
      expect(doc.snippet, isNull);
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      app.dispose();
      input.dispose();
    },
  );

  test('scope round trips encoded paths and confines server locations', () {
    const scope = DevelopmentScope(
      'home',
      '/',
      'file:///C:/work%20space',
      'file:///C:/work%20space',
      'windows',
      '',
      {},
    );
    const path = '/中文/hello world.dart';
    expect(scope.pathFromUri(scope.documentUri(path)), path);
    expect(scope.pathFromUri('file:///C:/outside/file.dart'), isNull);
    expect(scope.pathFromUri('https://example.com/file.dart'), isNull);
    expect(scope.pathFromUri('file:///C:/work%20space/%2e%2e/outside'), isNull);
  });

  for (final sync in [
    0,
    {'openClose': false, 'change': 0},
    {'openClose': true, 'change': 2},
  ]) {
    test('language synchronization respects server capability $sync', () async {
      final link = _Link();
      link.peer.syncCapability = sync;
      final app = _App(link), ws = Workspace(app, 'server');
      final model = ws.development,
          doc = ws.documents.open('home', '/project/main.dart');
      await doc.load();
      // A command issued during automatic startup joins the same handshake.
      final session = await model.ensure(doc);
      expect(session, isNotNull);
      expect(link.opens, 1);
      doc.replaceText('new\n', expectedVersion: doc.version);
      await session!.sync(doc);
      final change = link.peer.messages.where(
        (m) => m['method'] == 'textDocument/didChange',
      );
      if (sync is Map && sync['change'] == 2) {
        expect(
          change.single['params']['contentChanges'].single['range']['end'],
          {'line': 2, 'character': 0},
        );
      } else {
        expect(change, isEmpty);
        expect(
          link.peer.messages.where(
            (m) => m['method'] == 'textDocument/didOpen',
          ),
          isEmpty,
        );
      }
      await ws.documents.flush();
      ws.dispose();
      app.dispose();
    });
  }

  test('configuration failures do not retry or log on each edit', () async {
    final link = _Link()..configFails = true;
    final app = _App(link), ws = Workspace(app, 'server');
    final model = ws.development,
        doc = ws.documents.open('home', '/project/main.dart');
    await doc.load();
    await model.ensure(doc);
    for (var i = 0; i < 5; i++) {
      doc.replaceText('edit $i', expectedVersion: doc.version);
      await model.ensure(doc);
    }
    expect(link.configReads, 1);
    expect(model.logs.length, 1);
    link.configFails = false;
    model.restart();
    expect(await model.ensure(doc), isNotNull);
    await ws.documents.flush();
    ws.dispose();
    app.dispose();
  });

  test(
    'oversized buffers pause LSP, cancel pending sync and reopen when reduced',
    () async {
      final link = _Link(), app = _App(_Link());
      app.current = link;
      final ws = Workspace(app, 'server'), model = ws.development;
      final doc = ws.documents.open('home', '/project/main.dart');
      await doc.load();
      final session = (await model.ensure(doc))!;
      doc.replaceText('queued small change', expectedVersion: doc.version);
      doc.replaceText('中' * (1024 * 1024), expectedVersion: doc.version);
      expect(doc.languageSyncEligible, isFalse);
      await session.sync(doc);
      await link.peer.saw('textDocument/didClose');
      expect(model.sessionFor(doc), isNull);
      expect(
        link.peer.messages.where(
          (m) => m['method'] == 'textDocument/didChange',
        ),
        isEmpty,
      );
      doc.replaceText('small again\n', expectedVersion: doc.version);
      expect(await model.ensure(doc), same(session));
      final opens = link.peer.messages.where(
        (m) => m['method'] == 'textDocument/didOpen',
      );
      expect(opens, hasLength(2));
      expect(opens.last['params']['textDocument']['text'], 'small again\n');
      await ws.documents.flush();
      ws.dispose();
      app.dispose();
    },
  );

  test(
    'buffer growing during LSP handshake never sends oversized didOpen',
    () async {
      final link = _Link()..gate = Completer<OpStream>();
      final app = _App(link),
          ws = Workspace(app, 'server'),
          model = ws.development;
      final doc = ws.documents.open('home', '/project/main.dart');
      await doc.load();
      final pending = model.ensure(doc);
      await link.opened.future;
      doc.replaceText('中' * (1024 * 1024), expectedVersion: doc.version);
      link.gate!.complete(link.peer);
      expect(await pending, isNull);
      expect(
        link.peer.messages.where((m) => m['method'] == 'textDocument/didOpen'),
        isEmpty,
      );
      doc.replaceText('back within budget', expectedVersion: doc.version);
      expect(await model.ensure(doc), isNotNull);
      expect(
        (await link.peer.saw(
          'textDocument/didOpen',
        ))['params']['textDocument']['text'],
        'back within budget',
      );
      await ws.documents.flush();
      ws.dispose();
      app.dispose();
    },
  );

  test(
    'request timeout cancels LSP work and closing rejects pending replies',
    () async {
      final link = _Link();
      final peer = await ProtocolPeer.open(
        link,
        'lsp.start',
        {},
        active: () => true,
      );
      link.peer.delayHover = true;
      await expectLater(
        peer.request(
          'textDocument/hover',
          {},
          const Duration(milliseconds: 10),
        ),
        throwsA(isA<ProtocolError>()),
      );
      await link.peer.saw(r'$/cancelRequest');
      final pending = peer.request('textDocument/hover');
      final rejected = expectLater(pending, throwsA(isA<ProtocolError>()));
      peer.close();
      await rejected;
    },
  );

  test('UTF-16 edits preserve CRLF and reject overlapping or split-surrogate ranges', () {
    const text = 'a😀b\r\n中文\r\n';
    expect(positionOffset(text, {'line': 0, 'character': 3}), 3);
    expect(positionOffset(text, {'line': 1, 'character': 2}), 8);
    expect(
      () => positionOffset(text, {'line': 0, 'character': 2}),
      throwsStateError,
    );
    expect(
      applyTextEdits(text, [
        {
          'range': {
            'start': {'line': 1, 'character': 0},
            'end': {'line': 1, 'character': 2},
          },
          'newText': '替换',
        },
        {
          'range': {
            'start': {'line': 0, 'character': 1},
            'end': {'line': 0, 'character': 3},
          },
          'newText': 'X',
        },
      ]),
      'aXb\r\n替换\r\n',
    );
    expect(
      () => applyTextEdits('abc', [
        {
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 0, 'character': 2},
          },
          'newText': 'x',
        },
        {
          'range': {
            'start': {'line': 0, 'character': 1},
            'end': {'line': 0, 'character': 3},
          },
          'newText': 'y',
        },
      ]),
      throwsStateError,
    );
  });

  test('language documents synchronize in order, save, receive diagnostics and close', () async {
    final link = _Link();
    final app = _App(link);
    final ws = Workspace(app, 'server');
    // Initialize the manager before opening to cover registry-driven discovery.
    final model = ws.development;
    final document = ws.documents.open('home', '/project/main.dart');
    await document.load();
    await languageReady(model, document);
    final peer = link.peer;
    await peer.saw('textDocument/didOpen');
    document.replaceText(
      'unsaved\nsecond\n',
      expectedVersion: document.version,
    );
    final reply = await model.request(document, 'textDocument/hover', {
      'position': {'line': 0, 'character': 1},
    });
    expect((reply.result as Map)['contents'], 'documentation');
    final changeAt = peer.messages.indexWhere(
      (m) => m['method'] == 'textDocument/didChange',
    );
    final hoverAt = peer.messages.indexWhere(
      (m) => m['method'] == 'textDocument/hover',
    );
    expect(changeAt, greaterThan(0));
    expect(hoverAt, greaterThan(changeAt));
    expect(
      ((peer.messages[changeAt]['params'] as Map)['contentChanges'] as List)
          .single['text'],
      'unsaved\nsecond\n',
    );
    await document.save();
    await model.sessionFor(document)!.sync(document);
    expect(
      (await peer.saw('textDocument/didSave'))['params']['text'],
      'unsaved\nsecond\n',
    );
    final changed = Completer<void>();
    void diagnostic() {
      if (model.diagnostics.isNotEmpty && !changed.isCompleted)
        changed.complete();
    }

    model.addListener(diagnostic);
    peer.receive({
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': {
        'uri': 'file:///C:/fixture/project/main.dart',
        'version': document.version,
        'diagnostics': [
          {
            'message': 'error here',
            'severity': 1,
            'range': {
              'start': {'line': 1, 'character': 2},
              'end': {'line': 1, 'character': 3},
            },
          },
        ],
      },
    });
    await changed.future.timeout(const Duration(seconds: 3));
    model.removeListener(diagnostic);
    expect(model.diagnostics.single.line, 1);
    await ws.documents.close('home', '/project/main.dart');
    await peer.saw('textDocument/didClose');
    expect(model.diagnostics, isEmpty);
    ws.dispose();
    app.dispose();
    expect(peer.closed, isTrue);
  });

  test('multi-document previews validate every version before mutation and remain undoable', () async {
    final app = _App(_Link());
    final workspace = Workspace(app, 'server');
    final model = workspace.development;
    final a = workspace.documents.open('home', '/project/a.dart'),
        b = workspace.documents.open('home', '/project/b.dart');
    await Future.wait([a.load(), b.load()]);
    await languageReady(model, a);
    final session = model.sessionFor(a)!;
    final change = {
      'range': {
        'start': {'line': 0, 'character': 0},
        'end': {'line': 0, 'character': 5},
      },
      'newText': 'edited',
    };
    final edit = {
      'changes': {
        session.scope.documentUri(a.key.path): [change],
        session.scope.documentUri(b.key.path): [change],
      },
    };
    final plan = await model.prepareEdit(session, edit, model.versions());
    b.replaceText('newer', expectedVersion: b.version);
    expect(plan.apply, throwsStateError);
    expect(a.text, 'first\nsecond\n');
    b.controller.undo();
    final fresh = await model.prepareEdit(session, edit, model.versions());
    fresh.apply();
    expect(a.text, 'edited\nsecond\n');
    expect(b.text, 'edited\nsecond\n');
    a.controller.undo();
    expect(a.text, 'first\nsecond\n');
    await workspace.documents.flush();
    workspace.dispose();
    app.dispose();
  });

  test('a server edit review never blocks replies and a changed document rejects acceptance', () async {
    final link = _Link();
    final app = _App(link);
    final ws = Workspace(app, 'server'), model = ws.development;
    final doc = ws.documents.open('home', '/project/main.dart');
    await doc.load();
    await languageReady(model, doc);
    final review = Completer<void>(), answer = Completer<bool>();
    model.reviewEdit = (_) {
      review.complete();
      return answer.future;
    };
    final response = link.peer.sent.stream.firstWhere(
      (m) => m['id'] == 90 && m.containsKey('result'),
    );
    link.peer.receive({
      'jsonrpc': '2.0',
      'id': 90,
      'method': 'workspace/applyEdit',
      'params': {
        'edit': {
          'changes': {
            'file:///C:/fixture/project/main.dart': [
              {
                'range': {
                  'start': {'line': 0, 'character': 0},
                  'end': {'line': 0, 'character': 5},
                },
                'newText': 'proposal',
              },
            ],
          },
        },
      },
    });
    await review.future;
    final reply = await model.request(doc, 'textDocument/hover', {
      'position': {'line': 0, 'character': 0},
    });
    expect((reply.result as Map)['contents'], 'documentation');
    doc.replaceText('new typing', expectedVersion: doc.version);
    answer.complete(true);
    expect((await response)['result']['applied'], isFalse);
    expect(doc.text, 'new typing');
    await ws.documents.flush();
    ws.dispose();
    app.dispose();
  });

  test(
    'reconnect overtakes a delayed LSP open and resets its late process stream',
    () async {
      final old = _Link()..gate = Completer<OpStream>(), next = _Link();
      final app = _App(old), ws = Workspace(app, 'server');
      final model = ws.development,
          doc = ws.documents.open('home', '/project/main.dart');
      await doc.load();
      await old.opened.future;
      app.reconnect(next);
      await languageReady(model, doc);
      old.gate!.complete(old.peer);
      await old.peer.resetDone.future;
      expect(old.peer.resets, 1);
      expect(model.sessionFor(doc)!.link, same(next));
      ws.dispose();
      app.dispose();
    },
  );
}
