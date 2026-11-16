import 'dart:async';

import 'package:aurora/features/ai/ai_edit_review.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/git/text_diff.dart';
import 'package:aurora/kernel/ai_edits.dart';
import 'package:aurora/kernel/document_model.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/text_fixture.dart';
import 'support/workspace_fixture.dart';

class _Link extends TextFixtureLink {
  @override
  AgentInfo get server => AgentInfo({
    'caps': ['fs.text', 'fs.commit', 'ai.propose'],
  });
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) {
    if (op == 'fs.watch') throw OpError(codeUnavailable, 'not supported');
    return super.open(op, args, priority);
  }
}

Map<String, Object?> response(List<Map<String, String>> changes) => {
  'id': 'proposal',
  'proposal': {'changes': changes},
};
Map<String, String> edit(String path, String old, String replacement) => {
  'path': path,
  'old': old,
  'new': replacement,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Link link;
  late WorkspaceApp app;
  late Workspace ws;
  setUp(() {
    link = _Link();
    app = WorkspaceApp(wire: link);
    app.data.ai.providers.add(
      AiProvider(id: 'fixture', name: 'Fixture', model: 'fixture'),
    );
    ws = Workspace(app, 'server');
  });
  tearDown(() async {
    await ws.documents.flush();
    ws.dispose();
    app.dispose();
    link.disposeFixture();
  });
  Future<DocumentModel> doc(String path) async {
    final d = ws.documents.open('home', path);
    await d.load();
    return d;
  }

  test('partial acceptance composes against original offsets, batches undo and save adds no undo', () async {
    link.contents['/a'] = 'one two three\n';
    final a = await doc('/a'), b = await doc('/b');
    a.replaceText('one two three unsaved\n', expectedVersion: a.version);
    final set = AiEditSet.fromResponse(
      [AiBufferSnapshot(a), AiBufferSnapshot(b)],
      response([
        edit('/a', 'one', 'ONE LONG'),
        edit('/a', 'three', 'THREE'),
        edit('/b', 'second', 'SECOND'),
        edit('/a', 'two', 'TWO'),
      ]),
      active: () => true,
    );
    set.accept([set.chunks[0]]);
    set.reject(set.chunks[3]);
    set.accept([set.chunks[1], set.chunks[2]]);
    expect(a.text, 'ONE LONG two THREE unsaved\n');
    expect(b.text, 'SECOND\n');
    set.undo();
    expect(a.text, 'ONE LONG two three unsaved\n');
    expect(b.text, 'second\n');
    set.accept(set.pending.toList());
    await set.save();
    expect(a.dirty, isFalse);
    set.validationVersions['task'] = {
      a: (a.version, a.etag),
      b: (b.version, b.etag),
    };
    expect(set.validationCurrent('task'), isTrue);
    set.undo();
    expect(a.text, 'ONE LONG two three unsaved\n');
    expect(b.text, 'second\n');
    expect(a.dirty, isTrue);
    expect(set.validationCurrent('task'), isFalse);
    set.undo();
    expect(a.text, 'one two three unsaved\n');
    a.controller.undo();
    expect(a.text, 'one two three\n');
    set.dispose();
  });

  test(
    'no-op batches and CRLF normalization never undo unrelated user work',
    () async {
      link.contents['/a'] = 'ab\r\n';
      final a = await doc('/a');
      a.replaceText('abX\r\n', expectedVersion: a.version);
      final set = AiEditSet.fromResponse(
        [AiBufferSnapshot(a)],
        response([
          edit('/a', 'a', 'ab'),
          edit('/a', 'b', ''),
          edit('/a', '\r\n', '\n'),
        ]),
        active: () => true,
      );
      expect(set.chunks.length, 2);
      set.accept(set.pending.toList());
      set.undo();
      expect(a.text, 'abX\r\n');
      a.controller.undo();
      expect(a.text, 'ab\r\n');
      set.dispose();
      expect(
        () => AiEditSet.fromResponse(
          [AiBufferSnapshot(a)],
          response([edit('/a', '\n', 'x')]),
          active: () => true,
        ),
        throwsStateError,
      );
    },
  );

  test('all selected buffers validated before mutation; user input during save acknowledgement stays dirty', () async {
    final a = await doc('/a'), b = await doc('/b');
    AiEditSet make() => AiEditSet.fromResponse(
      [AiBufferSnapshot(a), AiBufferSnapshot(b)],
      response([
        edit('/a', 'original', 'changed'),
        edit('/b', 'second', 'changed'),
      ]),
      active: () => true,
    );
    final invalid = make();
    b.replaceText('user edit', expectedVersion: b.version);
    expect(() => invalid.accept(invalid.pending.toList()), throwsStateError);
    expect(a.text, 'original\n');
    invalid.dispose();
    b.controller.undo();
    final set = make();
    set.accept(set.pending.toList());
    link.commitGate = Completer<void>();
    final saving = set.save();
    final peer = await link.saw('fs.commit');
    await peer.ended.future;
    a.replaceText('typing during acknowledgement', expectedVersion: a.version);
    link.commitGate!.complete();
    await saving;
    expect(a.text, 'typing during acknowledgement');
    expect(a.baseText, 'changed\n');
    expect(a.dirty, isTrue);
    expect(set.undo, throwsStateError);
    expect(() => set.accept([set.chunks.first]), throwsStateError);
    set.dispose();
  });

  test('cancel covers provider preparation, late handshake, and a changed source during inference', () async {
    final a = await doc('/a');
    final prep = Completer<Map<String, Object?>>();
    var op = AiProposalOperation([AiBufferSnapshot(a)], active: () => true);
    var failed = expectLater(op.run(link, () => prep.future), throwsStateError);
    op.cancel();
    await failed;
    prep.complete({});
    await Future<void>.value();
    expect(link.opens.where((o) => o.op == 'ai.propose'), isEmpty);
    link.openGate = Completer<OpStream>();
    op = AiProposalOperation([AiBufferSnapshot(a)], active: () => true);
    failed = expectLater(op.run(link, () => {}), throwsStateError);
    final late = await link.saw('ai.propose');
    op.cancel();
    await failed;
    link.openGate!.complete(late);
    await late.resetDone.future;
    link.openGate = null;
    op = AiProposalOperation([AiBufferSnapshot(a)], active: () => true);
    failed = expectLater(op.run(link, () => {}), throwsStateError);
    final running = await link.saw('ai.propose', count: 2);
    a.replaceText('typing', expectedVersion: a.version);
    await failed;
    await running.resetDone.future;
    expect(a.text, 'typing');
  });

  test(
    'request carries unsaved snapshot; inline cursor motion cancels result',
    () async {
      final a = await doc('/a');
      a.replaceText('unsaved', expectedVersion: a.version);
      a.controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 7,
      );
      final op = AiProposalOperation(
        [AiBufferSnapshot(a)],
        inline: true,
        active: () => true,
      );
      final failed = expectLater(
        op.run(
          link,
          () => {
            'provider': {'model': 'fixture'},
          },
        ),
        throwsStateError,
      );
      final peer = await link.saw('ai.propose');
      expect(
        (link.opens.last.args['documents'] as List).single['text'],
        'unsaved',
      );
      a.controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 6,
      );
      await failed;
      await peer.resetDone.future;
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'ghost is paint-only; Tab accepts once, Esc and cursor motion reject ($platform)',
      (t) async {
        final input = InputMode();
        final a = await doc('/a');
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.dark).copyWith(platform: platform),
            home: InputMode.scope(
              mode: input,
              child: Scaffold(
                body: FileEditor(ws: ws, root: 'home', path: '/a'),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final editor = t.widget<CodeEditor>(find.byType(CodeEditor));
        editor.focusNode!.requestFocus();
        a.controller.selection = const CodeLineSelection.collapsed(
          index: 0,
          offset: 8,
        );
        final original = a.text, version = a.version;
        void suggest() => a.suggestInline(
          AiEditSet.fromResponse(
            [AiBufferSnapshot(a)],
            {
              'id': 'inline',
              'proposal': {'completion': ' + value\nnext'},
            },
            active: () => true,
            inline: true,
          ),
        );
        suggest();
        await t.pump();
        expect(
          t.widget<CodeEditor>(find.byType(CodeEditor)).ghostText,
          ' + value\nnext',
        );
        expect(a.text, original);
        expect(a.version, version);
        expect(a.dirty, isFalse);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(a.text, 'original + value\nnext\n');
        expect(a.controller.selection.extentIndex, 1);
        expect(a.controller.selection.extentOffset, 4);
        a.controller.undo();
        expect(a.text, original);
        suggest();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        expect(a.inlineSuggestion, isNull);
        expect(a.text, original);
        suggest();
        a.controller.selection = const CodeLineSelection.collapsed(
          index: 0,
          offset: 1,
        );
        await t.pump();
        expect(a.inlineSuggestion, isNull);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        input.dispose();
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'review generates, accepts and saves with narrow or short viewport ($width)',
      (t) async {
        t.view.physicalSize = Size(width, 360);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final input = InputMode(), a = await doc('/a');
        link.configure = (op, args, peer) {
          if (op == 'ai.propose')
            peer.ok(response([edit('/a', 'original', 'reviewed')]));
        };
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
                body: AiEditReview(ws: ws, origin: a),
              ),
            ),
          ),
        );
        await t.enterText(find.byType(TextField), 'improve this');
        await t.ensureVisible(find.text('生成修改建议'));
        await t.runAsync(() async {
          await t.tap(find.text('生成修改建议'));
          final peer = await link.saw('ai.propose');
          await peer.resetDone.future.timeout(const Duration(seconds: 5));
          await t.pump();
          await diffTextsAsync('', '').timeout(const Duration(seconds: 5));
        });
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('接受剩余修改'));
        await t.tap(find.text('接受剩余修改'));
        await t.pumpAndSettle();
        expect(a.text, 'reviewed\n');
        await t.ensureVisible(find.text('整批保存已接受修改'));
        await t.tap(find.text('整批保存已接受修改'));
        await t.pumpAndSettle();
        expect(a.dirty, isFalse);
        expect(link.contents['/a'], 'reviewed\n');
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        input.dispose();
      },
    );
  }
}
