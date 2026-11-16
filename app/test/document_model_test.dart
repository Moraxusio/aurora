import 'dart:async';
import 'dart:io';

import 'package:aurora/kernel/document_model.dart';
import 'package:aurora/kernel/document_recovery.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import 'support/workspace_fixture.dart';

class _Link extends FileTreeLink {
  String content = 'original\n', etag = 'v1';
  Completer<Object?>? writeGate, readGate;
  final writes = <Map>[];
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'fs.read') {
      final gate = readGate;
      readGate = null;
      return gate == null ? {'content': content, 'etag': etag} : gate.future;
    }
    if (op == 'fs.stat') return {'etag': etag};
    if (op == 'fs.write') {
      writes.add(args as Map);
      final gate = writeGate;
      writeGate = null;
      if (gate != null) return gate.future;
      if (args['if_match'] != etag) throw OpError(codeConflict, 'changed');
      content = args['content'] as String;
      etag = 'v${writes.length + 1}';
      return {'etag': etag};
    }
    return super.call(op, args, timeout);
  }
}

class _FailingStore extends MemoryDocumentRecoveryStore {
  bool fail = true;
  @override
  Future<void> save(DocumentRecovery recovery) async {
    if (fail) throw const FileSystemException('disk full');
    await super.save(recovery);
  }
}

class _UnreadableStore extends MemoryDocumentRecoveryStore {
  bool fail = true;
  @override
  Future<DocumentRecovery?> load(DocumentKey key) async {
    if (fail) throw const FormatException('damaged checkpoint');
    return super.load(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = DocumentKey('server', 'home', '/src/a.dart');

  test('dirty is exact across edit/undo and cursor changes do not materialize text', () async {
    final link = _Link();
    final doc = DocumentModel(key, () => link, MemoryDocumentRecoveryStore());
    await doc.load();
    final version = doc.version, materialized = doc.textMaterializations;
    for (var i = 0; i < 500; i++) {
      doc.controller.selection = CodeLineSelection.collapsed(
        index: 0,
        offset: i % 8,
      );
    }
    expect(doc.version, version);
    expect(doc.textMaterializations, materialized);
    doc.replaceText('modified\n', expectedVersion: version);
    expect(doc.dirty, isTrue);
    doc.controller.undo();
    expect(doc.text, 'original\n');
    expect(doc.dirty, isFalse);
    doc.controller.redo();
    expect(doc.text, 'modified\n');
    expect(doc.dirty, isTrue);
    expect(
      () => doc.replaceText('stale', expectedVersion: version),
      throwsStateError,
    );
    await doc.close();
  });

  test(
    'save acknowledges only the submitted version while typing continues',
    () async {
      final link = _Link(), store = MemoryDocumentRecoveryStore();
      final doc = DocumentModel(key, () => link, store);
      await doc.load();
      doc.controller.text = 'submitted\n';
      final submittedVersion = doc.version;
      final gate = link.writeGate = Completer<Object?>();
      final saving = doc.save();
      doc.controller.text = 'newer unsaved\n';
      gate.complete({'etag': 'v2'});
      await saving;
      expect(doc.savedVersion, submittedVersion);
      expect(doc.dirty, isTrue);
      expect(doc.text, 'newer unsaved\n');
      expect((await store.load(key))!.text, 'newer unsaved\n');
      expect((await store.load(key))!.etag, 'v2');
      await doc.close();
    },
  );

  test('restart offline restores text, baseline and cursor, then detects changed disk', () async {
    final store = MemoryDocumentRecoveryStore(), link = _Link();
    final doc = DocumentModel(key, () => link, store);
    await doc.load();
    doc.controller.text = 'unsaved first\nunsaved second\n';
    doc.controller.selection = const CodeLineSelection.collapsed(
      index: 1,
      offset: 3,
    );
    await doc.close();
    Link? current;
    final restored = DocumentModel(key, () => current, store);
    await restored.load();
    expect(restored.text, 'unsaved first\nunsaved second\n');
    expect(restored.baseText, 'original\n');
    expect(restored.controller.selection.extentIndex, 1);
    expect(restored.dirty, isTrue);
    link.etag = 'external';
    current = link;
    await restored.checkOutside();
    expect(restored.outside, 'changed');
    expect(restored.etag, 'v1');
    await expectLater(restored.save(), throwsA(isA<OpError>()));
    expect(restored.dirty, isTrue);
    await restored.close();
  });

  test('a replaced connection overtakes a pending initial read', () async {
    final old = _Link(), next = _Link()..content = 'new connection\n';
    Link current = old;
    final gate = old.readGate = Completer<Object?>();
    final doc = DocumentModel(
      key,
      () => current,
      MemoryDocumentRecoveryStore(),
    );
    final initial = doc.load();
    await Future<void>.delayed(Duration.zero);
    current = next;
    doc.connectionChanged();
    await doc.load();
    gate.complete({'content': 'stale', 'etag': 'stale'});
    await initial;
    expect(doc.text, 'new connection\n');
    await doc.close();
  });

  test(
    'an in-place code line edit is detected without mutable identity caching',
    () async {
      final link = _Link();
      final doc = DocumentModel(key, () => link, MemoryDocumentRecoveryStore());
      await doc.load();
      doc.controller.codeLines.segments.first.codeLines[0] = const CodeLine(
        'in place',
      );
      doc.controller.notifyListeners();
      expect(doc.text, 'in place\n');
      expect(doc.dirty, isTrue);
      await doc.close();
    },
  );

  test('folding and IME-only changes leave versions intact; composed text is recovered', () async {
    final link = _Link()..content = 'void main() {\n  first;\n  second;\n}\n';
    final store = MemoryDocumentRecoveryStore();
    final doc = DocumentModel(key, () => link, store);
    await doc.load();
    final version = doc.version;
    doc.controller.collapseChunk(0, 3);
    expect(doc.version, version);
    expect(doc.text, link.content);
    doc.replaceText('replacement', expectedVersion: doc.version);
    expect(doc.text, 'replacement');
    doc.controller.undo();
    expect(doc.text, link.content);
    expect(doc.controller.codeLines.first.chunks, isNotEmpty);
    doc.controller.expandChunk(0);
    final unfoldedVersion = doc.version;
    doc.controller.notifyListeners();
    expect(doc.version, unfoldedVersion);
    doc.controller.selection = const CodeLineSelection.collapsed(
      index: 1,
      offset: 0,
    );
    doc.controller.edit(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    final composed = doc.version;
    doc.controller.clearComposing();
    expect(doc.version, composed);
    expect(doc.text, contains('中文'));
    await doc.flushRecovery();
    expect((await store.load(key))!.text, doc.text);
    await doc.close();
  });

  test('an unreadable checkpoint is retained and retry restores it before reading disk', () async {
    final store = _UnreadableStore();
    await store.save(
      DocumentRecovery(
        key: key,
        text: 'recovered',
        baseText: 'base',
        version: 4,
        updatedAt: 1,
      ),
    );
    final link = _Link();
    final doc = DocumentModel(key, () => link, store);
    await doc.load();
    expect(doc.phase, DocumentPhase.failed);
    expect(await doc.flushRecovery(), isFalse);
    expect(store.entries[key]!.text, 'recovered');
    store.fail = false;
    expect(await doc.retryRecovery(), isTrue);
    expect(doc.text, 'recovered');
    expect(doc.dirty, isTrue);
    await doc.close();
  });

  test(
    'failed recovery writes remain retryable and never mark the document clean',
    () async {
      final link = _Link(), store = _FailingStore();
      final doc = DocumentModel(key, () => link, store);
      await doc.load();
      doc.controller.text = 'keep me';
      expect(await doc.flushRecovery(), isFalse);
      expect(doc.recoveryError, isNotNull);
      expect(doc.dirty, isTrue);
      store.fail = false;
      expect(await doc.flushRecovery(), isTrue);
      expect((await store.load(key))!.text, 'keep me');
      await doc.close();
    },
  );

  test('a reviewed merge is rejected after further edits; accepted merge is undoable', () async {
    final link = _Link();
    final doc = DocumentModel(key, () => link, MemoryDocumentRecoveryStore());
    await doc.load();
    doc.controller.text = 'mine';
    final before = doc.version;
    doc.controller.text = 'new mine';
    expect(
      () => doc.acceptMerge('merge', 'disk', 'v2', expectedVersion: before),
      throwsStateError,
    );
    doc.acceptMerge('merged', 'disk', 'v2', expectedVersion: doc.version);
    expect(doc.text, 'merged');
    expect(doc.etag, 'v2');
    expect(doc.baseText, 'disk');
    expect(doc.dirty, isTrue);
    doc.controller.undo();
    expect(doc.text, 'new mine');
    expect(doc.etag, 'v2');
    doc.controller.redo();
    expect(doc.text, 'merged');
    await doc.close();
  });

  test('real encrypted checkpoints survive reopening and explicit discard removes them', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-document-test-');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileDocumentRecoveryStore(dir, DpapiSealer());
    final record = DocumentRecovery(
      key: key,
      text: 'sensitive unsaved text',
      baseText: 'base',
      etag: 'tag',
      version: 7,
      updatedAt: 123,
    );
    await store.save(record);
    final files = await dir
        .list()
        .where((e) => e.path.endsWith('.doc'))
        .toList();
    expect(files, hasLength(1));
    expect(
      await File(files.single.path).readAsString().catchError((_) => ''),
      isNot(contains(record.text)),
    );
    final reopened = FileDocumentRecoveryStore(dir, DpapiSealer());
    expect((await reopened.load(key))!.text, record.text);
    expect(await reopened.list('other server'), isEmpty);
    expect(await reopened.list('server'), hasLength(1));
    final damaged = File('${dir.path}/damaged.doc');
    await damaged.writeAsBytes([1, 2, 3], flush: true);
    try {
      await reopened.list('server');
      fail('corruption was hidden');
    } on DocumentRecoveryScanError catch (e) {
      expect(e.recovered.single.text, record.text);
      expect(e.unreadable.map((p) => File(p).uri), [damaged.uri]);
      expect(await damaged.exists(), isTrue);
    }
    await reopened.remove(key);
    expect(await store.load(key), isNull);
  }, skip: !Platform.isWindows);
}
