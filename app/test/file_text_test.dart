import 'dart:async';
import 'dart:typed_data';

import 'package:aurora/kernel/development/text_edits.dart';
import 'package:aurora/kernel/document_model.dart';
import 'package:aurora/kernel/document_recovery.dart';
import 'package:aurora/kernel/file_text.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/text_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('framed text preserves split Unicode and rejects incomplete or oversized streams', () async {
    final link = TextFixtureLink()..contents['/a'] = '中😀\r\n' * 3000;
    addTearDown(link.disposeFixture);
    final result = await FileTextOperation(active: () => true)
        .read(link, 'home', '/a');
    expect(result['content'], link.contents['/a']);
    expect(link.opens.single.peer.closed, isTrue);
    for (final length in [2, 20 * 1024 * 1024]) {
      final peer = TextPeer()..ok({'textBytes': length});
      peer.frames.add(Frame(typeEnd, Uint8List(0)));
      link.openGate = Completer<OpStream>()..complete(peer);
      await expectLater(
        FileTextOperation(active: () => true).read(link, 'home', '/a'),
        throwsStateError,
      );
      expect(peer.closed, isTrue);
    }
  });

  test('three-slot budget cancels queued and late handshakes without leaking permits', () async {
    final link = TextFixtureLink();
    addTearDown(link.disposeFixture);
    final gates = <Completer<OpStream>>[];
    final operations = List.generate(
      5,
      (_) => FileTextOperation(active: () => true),
    );
    final futures = <Future<Map<String, dynamic>>>[];
    for (var i = 0; i < 3; i++) {
      final gate = Completer<OpStream>();
      gates.add(gate);
      link.openGate = gate;
      futures.add(operations[i].read(link, 'home', '/a'));
      await link.saw('fs.text', count: i + 1);
    }
    final queued = operations[3].read(link, 'home', '/a');
    final rejectsQueued = expectLater(queued, throwsStateError);
    futures.add(operations[4].read(link, 'home', '/a'));
    operations[3].cancel();
    await rejectsQueued;
    expect(link.opens.length, 3);
    final rejectedLate = expectLater(futures[0], throwsStateError);
    link.openGate = null;
    operations[0].cancel();
    await rejectedLate;
    await link.saw('fs.text', count: 4);
    gates[0].complete(link.opens[0].peer);
    await link.opens[0].peer.resetDone.future;
    for (var i = 1; i < 3; i++) {
      gates[i].complete(link.opens[i].peer);
    }
    await Future.wait(futures.skip(1));
    expect(link.opens.length, 4);
    expect(
      (await FileTextOperation(active: () => true)
          .read(link, 'home', '/a'))['content'],
      'original\n',
    );
  });

  test('encoding conversion advances disk decoder and recovery retains the saved encoding', () async {
    final link = TextFixtureLink()..encodings['/a'] = 'gb18030';
    addTearDown(link.disposeFixture);
    final store = MemoryDocumentRecoveryStore();
    final key = DocumentKey('server', 'home', '/a');
    final doc = DocumentModel(key, () => link, store);
    await doc.reopenEncoding('gb18030');
    doc.setSaveEncoding('utf-16le-bom');
    await doc.save();
    expect(doc.dirty, isFalse);
    expect((await doc.readDisk())['encoding'], 'utf-16le-bom');
    doc.setSaveEncoding('big5');
    await doc.flushRecovery();
    await doc.close();
    final restored = DocumentModel(key, () => link, store);
    await restored.load();
    expect(restored.recovered, isTrue);
    expect(restored.encoding, 'big5');
    expect(restored.savedEncoding, 'utf-16le-bom');
    expect((await restored.readDisk())['encoding'], 'utf-16le-bom');
    expect(restored.dirty, isTrue);
    await restored.close();
  });

  test('batch validates again after transfer before applying any buffer or end frame', () async {
    final link = TextFixtureLink(), store = MemoryDocumentRecoveryStore();
    addTearDown(link.disposeFixture);
    final a = DocumentModel(
      DocumentKey('server', 'home', '/a'),
      () => link,
      store,
    );
    final b = DocumentModel(
      DocumentKey('server', 'home', '/b'),
      () => link,
      store,
    );
    await Future.wait([a.load(), b.load()]);
    final plan = DocumentEditPlan([
      PlannedDocumentEdit(a, a.version, a.text, 'new a\n'),
      PlannedDocumentEdit(b, b.version, b.text, 'new b\n'),
    ], active: () => true);
    final gate = Completer<void>();
    link.configure = (op, _, peer) {
      if (op == 'fs.commit') peer.onData = () => gate.future;
    };
    final saving = plan.applyAndSave(),
        failed = expectLater(saving, throwsStateError);
    final peer = await link.saw('fs.commit');
    await peer.dataSeen.future;
    b.replaceText('typed b\n', expectedVersion: b.version);
    gate.complete();
    await failed;
    expect(peer.ended.isCompleted, isFalse);
    expect(a.text, 'original\n');
    expect(b.text, 'typed b\n');
    expect(plan.applied, isFalse);
    expect(a.saving || b.saving, isFalse);
    await Future.wait([a.close(), b.close()]);
  });

  test('batch acknowledgement preserves typing, submitted save points and genuine undo', () async {
    final link = TextFixtureLink()..commitGate = Completer<void>();
    addTearDown(link.disposeFixture);
    final store = MemoryDocumentRecoveryStore();
    final a = DocumentModel(
      DocumentKey('server', 'home', '/a'),
      () => link,
      store,
    );
    final b = DocumentModel(
      DocumentKey('server', 'home', '/b'),
      () => link,
      store,
    );
    await Future.wait([a.load(), b.load()]);
    final plan = DocumentEditPlan([
      PlannedDocumentEdit(a, a.version, a.text, 'new a\n'),
      PlannedDocumentEdit(b, b.version, b.text, 'new b\n'),
    ], active: () => true);
    link.statGate = Completer<Object?>();
    final oldWatch = a.checkOutside();
    final saving = plan.applyAndSave();
    final peer = await link.saw('fs.commit');
    await peer.ended.future;
    expect(a.text, 'new a\n');
    expect(b.text, 'new b\n');
    a.replaceText('new a\ntyped\n', expectedVersion: a.version);
    await a.checkOutside();
    expect(link.stats, 1);
    link.commitGate!.complete();
    await saving;
    link.statGate!.complete({'etag': 'unrelated-old-stat'});
    await oldWatch;
    expect(a.baseText, 'new a\n');
    expect(a.text, 'new a\ntyped\n');
    expect(a.dirty, isTrue);
    expect(b.dirty, isFalse);
    a.controller.undo();
    expect(a.text, 'new a\n');
    expect(a.dirty, isFalse);
    a.controller.undo();
    expect(a.text, 'original\n');
    expect(a.dirty, isTrue);
    b.controller.undo();
    expect(b.text, 'second\n');
    expect(b.dirty, isTrue);
    expect(link.opens.where((o) => o.op == 'fs.text').length, 2);
    await Future.wait([a.close(), b.close()]);
  });

  test('cancelled acknowledgement and external conflicts retain editable dirty proposals', () async {
    for (final cancel in [false, true]) {
      final link = TextFixtureLink()..rejectCommit = !cancel;
      if (cancel) link.commitGate = Completer<void>();
      final doc = DocumentModel(
        DocumentKey('server', 'home', '/a'),
        () => link,
        MemoryDocumentRecoveryStore(),
      );
      await doc.load();
      final plan = DocumentEditPlan([
        PlannedDocumentEdit(doc, doc.version, doc.text, 'proposal'),
      ], active: () => true);
      final operation = FileTextOperation(active: () => true);
      final saving = plan.applyAndSave(operation: operation);
      final failed = expectLater(saving, throwsA(isA<Object>()));
      await (await link.saw('fs.commit')).ended.future;
      if (cancel) operation.cancel();
      await failed;
      link.commitGate?.complete();
      expect(doc.text, 'proposal');
      expect(doc.baseText, 'original\n');
      expect(doc.etag, 'v1');
      expect(doc.dirty, isTrue);
      expect(doc.saving, isFalse);
      doc.controller.undo();
      expect(doc.text, 'original\n');
      await doc.close();
      link.disposeFixture();
    }
  });
}
