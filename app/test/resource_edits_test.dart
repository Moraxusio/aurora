import 'dart:async';

import 'package:aurora/features/development/language_actions.dart';
import 'package:aurora/kernel/development/text_edits.dart';
import 'package:aurora/kernel/development/workspace_edit.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/text_fixture.dart';
import 'support/workspace_fixture.dart';

Map insert(String text) => {
  'range': {
    'start': {'line': 0, 'character': 0},
    'end': {'line': 0, 'character': 0},
  },
  'newText': text,
};
Future<DocumentEditPlan> plan(Workspace ws, List<Map> changes) =>
    prepareWorkspaceEdit(
      documents: ws.documents,
      root: 'home',
      caseSensitive: false,
      pathFromUri: (uri) => uri.startsWith('file:///C:/work/')
          ? Uri.parse(uri).path.substring('/C:/work'.length)
          : null,
      edit: {'documentChanges': changes},
      expected: {},
      active: () => true,
    );
String uri(String path) => 'file:///C:/work$path';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ordered resource edits commit together, preserve dirty source and encoding, and undo disk and buffers', () async {
    final link = TextFixtureLink()..strictFiles = true;
    final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
    final a = ws.documents.open('home', '/a');
    await a.load();
    a.replaceText('unsaved a\n', expectedVersion: a.version);
    a.fileMode = 493;
    final change = await plan(ws, [
      {'kind': 'create', 'uri': uri('/new/deep/c')},
      {
        'textDocument': {'uri': uri('/new/deep/c'), 'version': null},
        'edits': [insert('created\n')],
      },
      {'kind': 'rename', 'oldUri': uri('/a'), 'newUri': uri('/moved')},
      {
        'textDocument': {'uri': uri('/moved'), 'version': a.version},
        'edits': [insert('header\n')],
      },
      {'kind': 'delete', 'uri': uri('/b')},
    ]);
    expect(change.resources.length, 3);
    expect(change.apply, throwsStateError);
    expect(link.contents['/a'], 'original\n');
    expect(a.text, 'unsaved a\n');
    await change.applyAndSave();
    expect(link.contents, {
      '/new/deep/c': 'created\n',
      '/moved': 'header\nunsaved a\n',
    });
    expect(a.text, 'unsaved a\n');
    expect(a.outside, 'deleted');
    expect(a.dirty, isTrue);
    final moved = ws.documents.find('home', '/moved')!;
    expect(moved.fileMode, 493);
    expect(moved.dirty, isFalse);
    expect(change.canUndo, isTrue);
    await change.undo();
    expect(link.contents, {'/a': 'original\n', '/b': 'second\n'});
    expect(a.text, 'unsaved a\n');
    expect(a.baseText, 'original\n');
    expect(a.dirty, isTrue);
    expect(a.outside, isNull);
    expect(moved.outside, 'deleted');
    expect(moved.text, 'header\nunsaved a\n');
    expect(change.undone, isTrue);
    await ws.documents.flush();
    ws.dispose();
    app.dispose();
    link.disposeFixture();
  });

  test('resource plans reject conflicts, unsafe paths and buffer changes before any end frame', () async {
    final link = TextFixtureLink()..strictFiles = true;
    final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
    await expectLater(
      plan(ws, [
        {'kind': 'rename', 'oldUri': uri('/a'), 'newUri': uri('/b')},
      ]),
      throwsStateError,
    );
    await expectLater(
      plan(ws, [
        {'kind': 'delete', 'uri': 'file:///C:/outside'},
      ]),
      throwsStateError,
    );
    final change = await plan(ws, [
      {
        'kind': 'rename',
        'oldUri': uri('/a'),
        'newUri': uri('/b'),
        'options': {'overwrite': true},
      },
    ]);
    final gate = Completer<void>();
    link.configure = (op, _, peer) {
      if (op == 'fs.refactor') peer.onData = () => gate.future;
    };
    final failed = expectLater(change.applyAndSave(), throwsStateError);
    final peer = await link.saw('fs.refactor');
    await peer.dataSeen.future;
    final b = ws.documents.find('home', '/b')!;
    b.replaceText('changed during transfer', expectedVersion: b.version);
    gate.complete();
    await failed;
    expect(peer.ended.isCompleted, isFalse);
    expect(link.contents, {'/a': 'original\n', '/b': 'second\n'});
    expect(change.applied, isFalse);
    await ws.documents.flush();
    ws.dispose();
    app.dispose();
    link.disposeFixture();
  });

  test(
    'resource undo refuses both later buffer edits and external disk edits',
    () async {
      for (final external in [false, true]) {
        final link = TextFixtureLink()..strictFiles = true;
        final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
        final change = await plan(ws, [
          {'kind': 'rename', 'oldUri': uri('/a'), 'newUri': uri('/new')},
        ]);
        await change.applyAndSave();
        if (external) {
          link.contents['/new'] = 'external';
          link.tags['/new'] = 'external-tag';
        } else {
          final doc = ws.documents.find('home', '/new')!;
          doc.replaceText(
            'typing after refactor',
            expectedVersion: doc.version,
          );
        }
        await expectLater(change.undo(), throwsA(isA<Object>()));
        expect(link.contents.containsKey('/a'), isFalse);
        expect(change.undone, isFalse);
        await ws.documents.flush();
        ws.dispose();
        app.dispose();
        link.disposeFixture();
      }
    },
  );

  testWidgets(
    'resource review exposes operations, transaction save and guarded undo',
    (t) async {
      final link = TextFixtureLink()..strictFiles = true;
      final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
      final input = InputMode();
      final change = await plan(ws, [
        {'kind': 'rename', 'oldUri': uri('/a'), 'newUri': uri('/new')},
      ]);
      var accepted = true;
      await t.pumpWidget(
        MaterialApp(
          home: InputMode.scope(
            mode: input,
            child: Builder(
              builder: (c) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    accepted = await reviewDocumentEdits(c, change);
                  },
                  child: const Text('review'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('review'));
      await t.pump();
      expect(find.text('接受全部修改'), findsNothing);
      expect(find.textContaining('移动 /a → /new'), findsOneWidget);
      await t.tap(find.text('接受并整批保存'));
      await t.pump();
      expect(link.contents.containsKey('/new'), isTrue);
      expect(find.text('撤销整批资源修改'), findsOneWidget);
      await t.tap(find.text('撤销整批资源修改'));
      await t.pumpAndSettle();
      expect(accepted, isFalse);
      expect(link.contents['/a'], 'original\n');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await ws.documents.flush();
      ws.dispose();
      app.dispose();
      input.dispose();
      link.disposeFixture();
    },
  );
}
