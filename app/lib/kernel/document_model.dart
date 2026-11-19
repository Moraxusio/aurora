import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';
import 'package:re_editor/re_editor.dart';

import 'document_recovery.dart';
import 'file_watch.dart';
import 'file_text.dart';
import 'snippets.dart';
import 'ai_edits.dart';

enum DocumentPhase { loading, ready, refused, failed }

TextLineBreak documentLineBreak(String text) {
  final n = text.indexOf('\n');
  if (n > 0 && text.codeUnitAt(n - 1) == 13) return TextLineBreak.crlf;
  if (n < 0 && text.contains('\r')) return TextLineBreak.cr;
  return TextLineBreak.lf;
}

/// Authoritative editable buffer and save point, owned by a workspace.
/// Widget recreation, project changes and reconnects do not replace this model.
class DocumentModel extends ChangeNotifier {
  final DocumentKey key;
  final Link? Function() currentLink;
  final DocumentRecoveryStore recovery;
  final int indent;
  late CodeLineEditingController controller;
  DocumentPhase phase = DocumentPhase.loading;
  String message = '';
  String? etag, outside, recoveryError;
  String encoding = 'utf-8', savedEncoding = 'utf-8';
  String _readEncoding = 'auto';
  int fileSize = 0, _characterCount = 0;
  bool get large => _characterCount > 512 * 1024;
  int _languageBudgetVersion = -1;
  bool _languageBudgetOK = true;
  bool get languageSyncEligible {
    if (large) return false;
    if (_languageBudgetVersion != version) {
      _languageBudgetVersion = version;
      // JSON quoting and UTF-8 expansion count toward the protocol frame.
      // Leave space for the URI and protocol metadata.
      _languageBudgetOK =
          utf8.encode(jsonEncode(text)).length < maxFrame - 16 * 1024;
    }
    return _languageBudgetOK;
  }

  FileTextOperation? _readOperation, _writeOperation;
  DocumentSaveGuard? _saveGuard;
  SnippetSession? snippet;
  AiEditSet? inlineSuggestion;
  void suggestInline(AiEditSet? value) {
    if (_closed) return;
    inlineSuggestion = value;
    _notify();
  }

  bool _diskMissing = false;
  bool get diskMissing => _diskMissing;
  int fileMode = 420;
  bool recovered = false, mixedBreaks = false, saving = false;
  TextLineBreak lineBreak = TextLineBreak.lf;
  int version = 0, savedVersion = 0;
  bool _dirty = false, _muting = false, _closed = false, _disposed = false;
  bool _recoveryBlocked = false;
  int _generation = 0, _views = 0;
  List<String> _lines = [''], _savedLines = [''];
  String? _text;
  Future<void>? _loading;
  Future<void>? _restoring;
  Future<bool>? _flushing;
  bool _pendingRecovery = false;
  Timer? _recoveryTimer;
  VoidCallback? unwatch;
  @visibleForTesting
  int textMaterializations = 0;

  DocumentModel(this.key, this.currentLink, this.recovery, {this.indent = 4}) {
    controller = _newController();
  }
  CodeLineEditingController _newController() => CodeLineEditingController(
    options: CodeLineOptions(lineBreak: lineBreak, indentSize: indent),
  )..addListener(_changed);
  bool get dirty => _dirty;
  String get text {
    if (_text == null) {
      textMaterializations++;
      _text = _lines.join(lineBreak.value);
    }
    return _text!;
  }

  String get baseText => _savedLines.join(lineBreak.value);
  List<String> get lineSnapshot => List.unmodifiable(_lines);
  bool get isClosed => _closed;
  String get selectedText => controller.selectedText;

  // Snapshot line strings, never mutable CodeLines identity. Cursor/IME-only
  // notifications do not join the document, increment versions or save journals.
  Iterable<String> _flatten(Iterable<CodeLine> lines) sync* {
    for (final line in lines) {
      yield line.text;
      yield* _flatten(line.chunks);
    }
  }

  Iterable<String> get _currentLines sync* {
    for (final segment in controller.codeLines.segments) {
      yield* _flatten(segment.codeLines);
    }
  }

  bool _sameLines() {
    var i = 0;
    for (final line in _currentLines) {
      if (i >= _lines.length || line != _lines[i++]) return false;
    }
    return i == _lines.length;
  }

  void _changed() {
    final suggestion = inlineSuggestion;
    if (suggestion != null &&
        (controller.unfoldLineSelection !=
                suggestion.snapshots.single.selection ||
            !suggestion.snapshots.single.current ||
            controller.isComposing ||
            !_sameLines())) {
      inlineSuggestion = null;
      scheduleMicrotask(_notify);
    }
    if (_muting || _closed || _sameLines()) return;
    _lines = _currentLines.toList(growable: false);
    _characterCount = _lines.fold(0, (sum, line) => sum + line.length + 1);
    _text = null;
    version++;
    _dirty =
        _diskMissing ||
        encoding != savedEncoding ||
        !listEquals(_lines, _savedLines);
    _queueRecovery();
    notifyListeners();
  }

  void retainView() => _views++;
  void releaseView() {
    _views--;
    if (_closed && _views == 0) _disposeController();
  }

  Future<void> load({bool force = false}) {
    if (_closed || saving || (!force && phase == DocumentPhase.ready))
      return Future.value();
    if (_loading != null) return _loading!;
    late final Future<void> tracked;
    tracked = _load(force).whenComplete(() {
      if (identical(_loading, tracked)) _loading = null;
    });
    return _loading = tracked;
  }

  Future<void> _restoreRecovery() => _restoring ??= () async {
    try {
      final found = await recovery.load(key);
      if (_closed) return;
      _recoveryBlocked = false;
      recoveryError = null;
      if (found != null) {
        encoding = found.encoding;
        savedEncoding = found.savedEncoding;
        _readEncoding = savedEncoding;
        _install(found.text, saved: found.baseText, tag: found.etag);
        _diskMissing = found.etag == null;
        _dirty = _dirty || _diskMissing;
        version = found.version + 1;
        recovered = true;
        final line = found.line.clamp(0, controller.codeLines.length - 1);
        controller.selection = CodeLineSelection.collapsed(
          index: line,
          offset: found.column.clamp(0, controller.codeLines[line].length),
        );
      }
    } on Object {
      recoveryError = '恢复记录无法读取，原记录已保留';
      _recoveryBlocked = true;
    }
  }();
  Future<void> _load(bool force) async {
    final generation = ++_generation;
    await _restoreRecovery();
    if (_closed || generation != _generation) return;
    if (_recoveryBlocked) {
      phase = DocumentPhase.failed;
      message = recoveryError!;
      _notify();
      return;
    }
    final link = currentLink();
    final readVersion = version;
    if (link == null) {
      if (phase != DocumentPhase.ready) {
        phase = DocumentPhase.failed;
        message = '未连接';
      }
      _notify();
      return;
    }
    try {
      final result = await readDisk();
      if (_closed ||
          generation != _generation ||
          !identical(link, currentLink()))
        return;
      if (dirty && (!force || version != readVersion)) {
        phase = DocumentPhase.ready;
        outside = result['etag'] == etag ? null : 'changed';
        _notify();
        return;
      }
      if (result['binary'] == true || result['truncated'] == true) {
        fileSize = (result['size'] as num?)?.toInt() ?? 0;
        phase = DocumentPhase.refused;
        message = result['binary'] == true
            ? '文件不是 UTF-8 文本，请选择正确编码后打开。'
            : '文件超过在线编辑上限，可使用大文件阅读模式。';
      } else {
        final value = result['content'] as String? ?? '';
        encoding = savedEncoding = result['encoding'] as String? ?? 'utf-8';
        fileSize = (result['size'] as num?)?.toInt() ?? value.length;
        fileMode = (result['modeBits'] as int?) ?? fileMode;
        _install(value, saved: value, tag: result['etag'] as String?);
        _diskMissing = false;
        // Opening an ordinary clean file does not need a journal write.
        // Forced reloads or recovered entries still clear the old checkpoint.
        final clearRecovery = force || recovered;
        recovered = false;
        outside = null;
        if (clearRecovery) _queueRecovery();
      }
    } on Object catch (e) {
      if (_closed ||
          generation != _generation ||
          !identical(link, currentLink()))
        return;
      if (phase == DocumentPhase.ready) {
        if (e is OpError && e.code == codeNotFound) outside = 'deleted';
      } else {
        _diskMissing = e is OpError && e.code == codeNotFound;
        phase = DocumentPhase.failed;
        message = e is OpError ? e.message : '读取文件失败，请重试';
      }
    }
    _notify();
  }

  void connectionChanged() {
    if (_closed) return;
    _generation++;
    _readOperation?.cancel();
    _writeOperation?.cancel();
    _loading = null;
    if (phase == DocumentPhase.ready) {
      unawaited(checkOutside());
    } else {
      unawaited(load());
    }
  }

  void _install(String value, {required String saved, String? tag}) {
    inlineSuggestion = null;
    snippet?.close();
    _muting = true;
    final nextBreak = documentLineBreak(value);
    if (nextBreak != lineBreak) {
      controller.removeListener(_changed);
      controller.dispose();
      lineBreak = nextBreak;
      controller = _newController();
    }
    controller.text = value;
    controller.clearHistory();
    _lines = _currentLines.toList(growable: false);
    _characterCount = _lines.fold(0, (sum, line) => sum + line.length + 1);
    _savedLines = saved.split(RegExp(r'\r\n|\n|\r'));
    _text = null;
    _dirty = encoding != savedEncoding || !listEquals(_lines, _savedLines);
    mixedBreaks = lineBreak == TextLineBreak.crlf
        ? RegExp(r'(?<!\r)\n').hasMatch(value)
        : lineBreak == TextLineBreak.lf && value.contains('\r');
    etag = tag;
    version++;
    savedVersion = _dirty ? -1 : version;
    phase = DocumentPhase.ready;
    _muting = false;
  }

  Future<void> checkOutside() async {
    if (_closed || phase != DocumentPhase.ready || saving) return;
    final link = currentLink(), generation = _generation;
    if (link == null) return;
    try {
      final info = await link.call('fs.stat', {
        'root': key.root,
        'path': key.path,
      }) as Map;
      if (_closed ||
          generation != _generation ||
          !identical(link, currentLink()) ||
          saving)
        return;
      if (info['etag'] == null || info['etag'] == etag) return;
      if (dirty) {
        outside = 'changed';
        _notify();
      } else {
        await load(force: true);
      }
    } on OpError catch (e) {
      if (!_closed &&
          generation == _generation &&
          identical(link, currentLink()) &&
          !saving &&
          e.code == codeNotFound) {
        outside = 'deleted';
        _notify();
      }
    }
  }

  Future<void> save() async {
    if (_closed || phase != DocumentPhase.ready || saving) return;
    final link = currentLink();
    if (link == null) throw OpError(codeUnavailable, '未连接，没有保存');
    final submitted = text,
        submittedVersion = version,
        submittedEncoding = encoding;
    final operation = FileTextOperation(
      active: () => !_closed && identical(link, currentLink()),
    );
    final guard = beginSave(operation);
    try {
      late final Map result;
      if (link.server.caps.contains('fs.commit')) {
        result = (await operation.commit(link, [
          FileTextChange(
            root: key.root,
            path: key.path,
            etag: etag,
            text: submitted,
            encoding: submittedEncoding,
          ),
        ])).single;
      } else {
        if (submittedEncoding != 'utf-8')
          throw StateError('此 agent 不支持编码保存，请升级 agent');
        result = await link.call('fs.write', {
          'root': key.root,
          'path': key.path,
          'content': submitted,
          if (etag != null) 'if_match': etag,
          if (etag == null) 'create': true,
        }) as Map;
      }
      if (!identical(link, currentLink())) {
        throw OpError(codeUnavailable, '连接已变化，请核对文件后重试保存');
      }
      guard.acknowledge(submitted, submittedEncoding, submittedVersion, result);
      await flushRecovery();
    } finally {
      guard.finish();
    }
  }

  /// A save lease blocks competing saves/reloads, but never blocks typing.
  /// Invalidating pending reads also prevents a pre-commit watcher response
  /// from reloading text and clearing undo after a transaction is acknowledged.
  DocumentSaveGuard beginSave(FileTextOperation operation) {
    if (_closed || saving || phase != DocumentPhase.ready) {
      throw StateError('${key.path} 当前不能保存');
    }
    _generation++;
    _readOperation?.cancel();
    _loading = null;
    _writeOperation = operation;
    saving = true;
    final guard = _saveGuard = DocumentSaveGuard._(this);
    _notify();
    return guard;
  }

  Future<Map> readDisk() async {
    final link = currentLink();
    if (link == null) throw StateError('未连接');
    if (!link.server.caps.contains('fs.text')) {
      if (_readEncoding != 'auto' && _readEncoding != 'utf-8')
        throw StateError('此 agent 不支持编码读取，请升级 agent');
      return await link.call('fs.read', {'root': key.root, 'path': key.path})
          as Map;
    }
    _readOperation?.cancel();
    final operation = FileTextOperation(
      active: () => !_closed && identical(link, currentLink()),
    );
    _readOperation = operation;
    try {
      return await operation.read(
        link,
        key.root,
        key.path,
        encoding: _readEncoding,
      );
    } finally {
      if (identical(_readOperation, operation)) _readOperation = null;
    }
  }

  Future<void> reopenEncoding(String value) async {
    if (dirty || saving) throw StateError('请先保存当前修改，再重新选择读取编码');
    if (value != 'auto' && !textEncodings.containsKey(value))
      throw StateError('不支持的编码');
    _readEncoding = value;
    await load(force: true);
  }

  void setSaveEncoding(String value) {
    if (phase != DocumentPhase.ready ||
        !textEncodings.containsKey(value) ||
        value == encoding)
      return;
    encoding = value;
    version++;
    _dirty = encoding != savedEncoding || !listEquals(_lines, _savedLines);
    _queueRecovery();
    _notify();
  }

  /// Version checked edit entry for LSP, AI proposals and refactoring.
  void replaceText(String value, {required int expectedVersion}) {
    if (_closed || phase != DocumentPhase.ready || version != expectedVersion) {
      throw StateError('文档版本已变化，请重新生成修改');
    }
    // re_editor's text setter is one runRevocableOp. It replaces folded chunks
    // too, while retaining the previous text, folds and selection for undo.
    controller.text = value;
  }

  void startSnippet(SnippetExpansion expansion, int start) {
    snippet?.close();
    if (_closed || phase != DocumentPhase.ready) return;
    if (start < 0 ||
        start + expansion.text.length > text.length ||
        text.substring(start, start + expansion.text.length) !=
            expansion.text) {
      throw StateError('片段内容与编辑缓冲不匹配');
    }
    late final SnippetSession session;
    session = SnippetSession(
      controller,
      expansion,
      start,
      version: () => version,
      onClosed: () {
        if (identical(snippet, session)) snippet = null;
        _notify();
      },
    );
    snippet = session;
    session.selectFirst();
    _notify();
  }

  /// A missing target is editable only after the agent positively reported
  /// NOT_FOUND. Failed reads, offline state and damaged recovery are not creates.
  void prepareMissingTarget() {
    if (_closed || saving || !_diskMissing || dirty || recoveryError != null) {
      throw StateError('文件目标无法作为新文件使用');
    }
    if (phase == DocumentPhase.ready) return;
    _install('', saved: '');
    _diskMissing = true;
    _notify();
  }

  void markPendingCreation() {
    if (!_diskMissing || _closed) return;
    _dirty = true;
    _queueRecovery();
    _notify();
  }

  /// Accept a reviewed merge against the exact disk snapshot that was shown.
  /// The subsequent save still uses its etag, detecting another external edit.
  void acceptMerge(
    String value,
    String disk,
    String diskEtag, {
    required int expectedVersion,
  }) {
    replaceText(value, expectedVersion: expectedVersion);
    _savedLines = disk.split(RegExp(r'\r\n|\n|\r'));
    etag = diskEtag;
    _dirty = encoding != savedEncoding || !listEquals(_lines, _savedLines);
    savedVersion = _dirty ? -1 : version;
    outside = null;
    _queueRecovery();
    _notify();
  }

  void _queueRecovery() {
    if (_closed) return;
    _pendingRecovery = true;
    _recoveryTimer?.cancel();
    if (!dirty) {
      unawaited(flushRecovery());
      return;
    }
    _recoveryTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(flushRecovery()),
    );
  }

  Future<bool> flushRecovery() {
    _recoveryTimer?.cancel();
    if (_recoveryBlocked) return Future.value(false);
    if (dirty) _pendingRecovery = true;
    if (_flushing != null) return _flushing!;
    return _flushing = _flush().whenComplete(() => _flushing = null);
  }

  Future<bool> retryRecovery() async {
    if (_recoveryBlocked) {
      _restoring = null;
      await load();
      return !_recoveryBlocked;
    }
    return flushRecovery();
  }

  Future<bool> _flush() async {
    while (_pendingRecovery) {
      _pendingRecovery = false;
      final snapshot = dirty
          ? DocumentRecovery(
              key: key,
              text: text,
              baseText: baseText,
              encoding: encoding,
              savedEncoding: savedEncoding,
              etag: etag,
              version: version,
              line: controller.selection.extentIndex,
              column: controller.selection.extentOffset,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            )
          : null;
      try {
        if (snapshot == null) {
          await recovery.remove(key);
        } else {
          await recovery.save(snapshot);
        }
        recoveryError = null;
      } on Object {
        _pendingRecovery = true;
        recoveryError = '未保存正文暂时无法写入恢复记录，请检查磁盘后重试';
        _notify();
        return false;
      }
    }
    return true;
  }

  void _notify() {
    if (!_closed && !_disposed) notifyListeners();
  }

  Future<void> close({bool discard = false}) async {
    final closingVersion = version;
    _recoveryTimer?.cancel();
    if (discard) {
      if (_flushing != null) await _flushing;
      await recovery.remove(key);
      if (closingVersion != version) {
        _queueRecovery();
        await flushRecovery();
        throw StateError('关闭期间文档已变化，请重新确认');
      }
      _pendingRecovery = false;
    } else {
      if (!await flushRecovery()) return;
    }
    _retire();
  }

  void _retire() {
    _recoveryTimer?.cancel();
    _closed = true;
    snippet?.close();
    _readOperation?.cancel();
    _writeOperation?.cancel();
    unwatch?.call();
    _generation++;
    if (_views == 0) _disposeController();
  }

  void _disposeController() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }
}

class DocumentSaveGuard {
  final DocumentModel document;
  bool _finished = false;
  DocumentSaveGuard._(this.document);

  void acknowledge(String submitted, String encoding, int version, Map result) {
    final doc = document;
    if (_finished || doc.isClosed || !identical(doc._saveGuard, this)) return;
    doc.etag = result['etag'] as String? ?? doc.etag;
    doc._diskMissing = false;
    doc.fileMode = result['modeBits'] as int? ?? doc.fileMode;
    doc._savedLines = submitted.split(RegExp(r'\r\n|\n|\r'));
    doc.savedEncoding = doc._readEncoding = encoding;
    doc.savedVersion = version;
    doc.fileSize = (result['size'] as num?)?.toInt() ?? doc.fileSize;
    doc._dirty =
        doc.encoding != doc.savedEncoding ||
        !listEquals(doc._lines, doc._savedLines);
    doc.outside = null;
    doc.recovered = false;
    doc._queueRecovery();
  }

  void acknowledgeDeleted() {
    final doc = document;
    if (_finished || doc.isClosed || !identical(doc._saveGuard, this)) return;
    doc.etag = null;
    doc._diskMissing = true;
    doc.outside = 'deleted';
    doc._savedLines = [''];
    doc._dirty = true;
    doc._queueRecovery();
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    final doc = document;
    if (!identical(doc._saveGuard, this)) return;
    doc._saveGuard = null;
    doc._writeOperation = null;
    doc.saving = false;
    doc._notify();
  }
}

class DocumentRegistry extends ChangeNotifier {
  final String server;
  final Link? Function() link;
  final DocumentRecoveryStore recovery;
  final FileWatch watch;
  final Map<DocumentKey, DocumentModel> _documents = {};
  Link? _lastLink;
  DocumentRegistry(this.server, this.link, this.recovery, this.watch);
  Iterable<DocumentModel> get all => _documents.values;
  void relink() {
    final current = link();
    if (identical(current, _lastLink)) return;
    _lastLink = current;
    for (final model in all) {
      model.connectionChanged();
    }
  }

  DocumentModel? find(String root, String path) =>
      _documents[DocumentKey(server, root, path)];
  DocumentModel open(String root, String path, {int indent = 4}) {
    final key = DocumentKey(server, root, path);
    final existing = _documents[key];
    if (existing != null) return existing;
    final model = () {
      final model = DocumentModel(key, link, recovery, indent: indent);
      model.unwatch = watch.watch(
        root,
        path,
        () => unawaited(model.checkOutside()),
      );
      return model;
    }();
    _documents[key] = model;
    notifyListeners();
    return model;
  }

  Future<bool> flush() async {
    final results = await Future.wait(all.map((d) => d.flushRecovery()));
    return results.every((ok) => ok);
  }

  Future<void> close(String root, String path) async {
    final key = DocumentKey(server, root, path);
    final model = _documents[key];
    if (model == null) return;
    await model.close(discard: true);
    _documents.remove(key);
    notifyListeners();
  }

  /// A replaced preview is not an explicit discard. Do not touch its journal;
  /// a recovery read may still be in flight when the preview is replaced.
  bool releaseCleanPreview(String root, String path) {
    final key = DocumentKey(server, root, path);
    final model = _documents[key];
    if (model == null) return true;
    if (model.dirty || model.saving || model._pendingRecovery ||
        model._flushing != null || model._views > 1) {
      return false;
    }
    _documents.remove(key);
    model._retire();
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    for (final model in all) {
      unawaited(model.close());
    }
    _documents.clear();
    super.dispose();
  }
}
