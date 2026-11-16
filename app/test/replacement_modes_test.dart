import 'dart:async';

import 'package:aurora/features/development/language_actions.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/search/search_model.dart';
import 'package:aurora/features/search/search_scope.dart';
import 'package:aurora/kernel/development/text_edits.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/text_fixture.dart';
import 'support/workspace_fixture.dart';

class _LargeLink extends TextFixtureLink {
  final pages = <Map>[];
  TextPeer? held;
  bool hold = false;
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    if (op != 'fs.text') return super.open(op, args, priority);
    final params = args as Map, peer = TextPeer();
    opens.add((op: op, args: params, peer: peer));
    pages.add(params);
    if (hold) {
      held = peer;
      return peer;
    }
    if (params['window'] != true) {
      peer.text('', {
        'large': true,
        'etag': 'big-v1',
        'encoding': 'utf-8',
        'size': 64 * 1024 * 1024,
      });
    } else {
      final offset = params['offset'] as int;
      peer.text('字节窗口 $offset\n', {
        'offset': offset,
        'nextOffset': offset + 65536,
        'eof': false,
        'etag': 'big-v1',
        'encoding': 'utf-8',
        'size': 64 * 1024 * 1024,
      });
    }
    return peer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('replacement deduplicates overlapping folders, uses dirty buffers and validates the whole preview', () async {
    final link = TextFixtureLink()
      ..contents.addAll({'/a': 'cat\n', '/b': 'cat\n'});
    final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
    final model = SearchModel(
      ws,
      folders: (_) async => [
        const SearchFolder('home', '/', 'root'),
        const SearchFolder('home', '/nested', 'overlap'),
      ],
    );
    await model.search(const SearchOptions('cat'));
    final a = ws.documents.open('home', '/a');
    await a.load();
    a.replaceText('cat with unsaved edits\n', expectedVersion: a.version);
    final plan = await model.previewReplacement('dog');
    expect(plan.edits.length, 2);
    expect(plan.edits.first.after, 'dog with unsaved edits\n');
    expect(link.opens.where((o) => o.op == 'fs.replace.preview').length, 2);
    final b = ws.documents.find('home', '/b')!;
    b.replaceText('typing after preview', expectedVersion: b.version);
    expect(plan.apply, throwsStateError);
    expect(a.text, 'cat with unsaved edits\n');
    final fresh = await model.previewReplacement('dog');
    expect(fresh.edits.length, 1);
    model.clear();
    expect(fresh.apply, throwsStateError);
    await ws.documents.flush();
    model.dispose();
    ws.dispose();
    app.dispose();
    link.disposeFixture();
  });

  test('cancelling a replacement resets its stream without applying partial buffers', () async {
    final link = TextFixtureLink()..contents['/a'] = 'cat';
    final app = WorkspaceApp(wire: link), ws = Workspace(app, 'server');
    final model = SearchModel(
      ws,
      folders: (_) async => [const SearchFolder('home', '/', 'root')],
    );
    await model.search(const SearchOptions('cat'));
    final gate = Completer<void>();
    link.configure = (op, _, peer) {
      if (op == 'fs.replace.preview') {
        final finish = peer.onEnd;
        peer.onEnd = () async {
          await gate.future;
          await finish?.call();
        };
      }
    };
    final preview = model.previewReplacement('dog');
    final failed = expectLater(preview, throwsStateError);
    final peer = await link.saw('fs.replace.preview');
    await peer.ended.future;
    model.cancel();
    await failed;
    expect(peer.closed, isTrue);
    expect(ws.documents.find('home', '/a')!.text, 'cat');
    gate.complete();
    model.dispose();
    ws.dispose();
    app.dispose();
    link.disposeFixture();
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'large text is paged and cancelled at $width with enlarged text',
      (t) async {
        t.view.physicalSize = Size(width, 740);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final link = _LargeLink();
        final connected = WorkspaceApp(wire: link),
            ws = Workspace(connected, 'server');
        final input = InputMode(touch: width < 500);
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.dark),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: InputMode.scope(
              mode: input,
              child: Scaffold(
                body: FileEditor(ws: ws, root: 'home', path: '/big'),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('大文件阅读模式'));
        await t.pumpAndSettle();
        expect(find.text('字节窗口 0'), findsOneWidget);
        expect(ws.documents.find('home', '/big')!.text, '');
        await t.tap(find.byTooltip('下一段'));
        await t.pumpAndSettle();
        expect(find.text('字节窗口 65536'), findsOneWidget);
        expect(link.pages.last['if_match'], 'big-v1');
        expect(link.pages.last['length'], 65536);
        link.hold = true;
        await t.tap(find.byTooltip('下一段'));
        await t.pump();
        await t.pumpWidget(const SizedBox());
        expect(link.held!.closed, isTrue);
        expect(t.takeException(), isNull);
        ws.dispose();
        connected.dispose();
        input.dispose();
        link.disposeFixture();
      },
    );
  }

  testWidgets(
    'review can accept and save all documents as one undoable transaction',
    (t) async {
      final link = TextFixtureLink();
      final connected = WorkspaceApp(wire: link),
          ws = Workspace(connected, 'server');
      final doc = ws.documents.open('home', '/a');
      await doc.load();
      final plan = DocumentEditPlan([
        PlannedDocumentEdit(doc, doc.version, doc.text, 'saved proposal\n'),
      ], active: () => true);
      final input = InputMode();
      var accepted = false;
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: InputMode.scope(
            mode: input,
            child: Builder(
              builder: (c) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    accepted = await reviewDocumentEdits(
                      c,
                      plan,
                      allowSave: true,
                    );
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
      await t.tap(find.text('接受并整批保存'));
      await t.pumpAndSettle();
      expect(accepted, isTrue);
      expect(doc.text, 'saved proposal\n');
      expect(doc.dirty, isFalse);
      expect(link.opens.where((o) => o.op == 'fs.commit').length, 1);
      doc.controller.undo();
      expect(doc.text, 'original\n');
      expect(doc.dirty, isTrue);
      await t.pumpWidget(const SizedBox());
      await ws.documents.flush();
      ws.dispose();
      connected.dispose();
      input.dispose();
      link.disposeFixture();
    },
  );
}
