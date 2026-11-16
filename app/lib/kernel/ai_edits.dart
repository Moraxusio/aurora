import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';
import 'package:re_editor/re_editor.dart';

import 'development/text_edits.dart';
import 'document_model.dart';
import 'file_text.dart';

class AiBufferSnapshot {
  final DocumentModel document;
  final String text;
  final int version;
  final String? etag;
  final String encoding;
  final CodeLineSelection selection;
  AiBufferSnapshot(this.document)
    : text = document.text,
      version = document.version,
      etag = document.etag,
      encoding = document.encoding,
      selection = document.controller.unfoldLineSelection;
  bool get current =>
      !document.isClosed &&
      document.phase == DocumentPhase.ready &&
      document.version == version &&
      document.etag == etag &&
      document.encoding == encoding;
  Map<String, Object?> toJson() => {
    'path': document.key.path,
    'text': text,
    'version': version,
    'etag': etag ?? '',
  };
  int get caret => positionOffset(text, {
    'line': selection.extentIndex,
    'character': selection.extentOffset,
  });
  String get selectedText {
    final base = positionOffset(text, {
      'line': selection.baseIndex,
      'character': selection.baseOffset,
    });
    final end = caret;
    return text.substring(base < end ? base : end, base < end ? end : base);
  }
}

class AiEditChunk {
  final AiBufferSnapshot snapshot;
  final int start, end;
  final String replacement;
  bool accepted = false, rejected = false;
  AiEditChunk(this.snapshot, this.start, this.end, this.replacement);
  String get before => snapshot.text.substring(start, end);
}

class AiEditSet extends ChangeNotifier {
  final String id;
  final List<AiBufferSnapshot> snapshots;
  final List<AiEditChunk> chunks;
  final Map usage;
  final int elapsedMs;
  final bool Function() active;
  final Map<DocumentModel, int> _versions;
  final List<({List<AiEditChunk> chunks, Set<DocumentModel> changed})>
  _history = [];
  final List<String> validationTasks = [];
  final Map<String, Map<DocumentModel, (int, String?)>> validationVersions = {};
  bool validationCurrent(String id) =>
      validationVersions[id]?.entries.every(
        (e) =>
            !e.key.isClosed &&
            !e.key.dirty &&
            (e.key.version, e.key.etag) == e.value,
      ) ==
      true;
  final bool inline;
  bool saving = false, _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  AiEditSet(
    this.id,
    this.snapshots,
    this.chunks, {
    required this.active,
    this.usage = const {},
    this.elapsedMs = 0,
    this.inline = false,
  }) : _versions = {for (final s in snapshots) s.document: s.version};

  factory AiEditSet.fromResponse(
    List<AiBufferSnapshot> snapshots,
    Map response, {
    required bool Function() active,
    bool inline = false,
  }) {
    final proposal = response['proposal'];
    if (proposal is! Map || response['id'] is! String)
      throw StateError('AI 修改回复无效');
    final chunks = <AiEditChunk>[];
    if (inline) {
      final value = proposal['completion'];
      if (snapshots.length != 1 || value is! String || value.length > 4096) {
        throw StateError('行内续写回复无效');
      }
      if (value.isNotEmpty) {
        final s = snapshots.single;
        chunks.add(
          AiEditChunk(
            s,
            s.caret,
            s.caret,
            value.replaceAll(RegExp(r'\r\n|\r|\n'), s.document.lineBreak.value),
          ),
        );
      }
    } else {
      final list = proposal['changes'] ?? const [];
      if (list is! List || list.length > 64) throw StateError('AI 修改块超过预算');
      var size = 0;
      for (final item in list) {
        if (item is! Map || item['old'] is! String || item['new'] is! String)
          throw StateError('AI 修改块格式无效');
        final s = snapshots
            .where((s) => s.document.key.path == item['path'])
            .firstOrNull;
        final old = item['old'] as String, replacement = item['new'] as String;
        if (s == null || old.isEmpty || old == replacement)
          throw StateError('AI 修改没有引用有效缓冲');
        final start = s.text.indexOf(old);
        if (start < 0 || s.text.indexOf(old, start + 1) >= 0)
          throw StateError('AI 修改未唯一匹配缓冲');
        final end = start + old.length;
        bool boundary(int offset) =>
            offset <= 0 ||
            offset >= s.text.length ||
            !(s.text.codeUnitAt(offset - 1) == 13 &&
                    s.text.codeUnitAt(offset) == 10 ||
                s.text.codeUnitAt(offset - 1) >= 0xD800 &&
                    s.text.codeUnitAt(offset - 1) <= 0xDBFF &&
                    s.text.codeUnitAt(offset) >= 0xDC00 &&
                    s.text.codeUnitAt(offset) <= 0xDFFF);
        if (!boundary(start) || !boundary(end)) {
          throw StateError('AI 修改切断了换行或 Unicode 字符');
        }
        final normalized = replacement.replaceAll(
          RegExp(r'\r\n|\r|\n'),
          s.document.lineBreak.value,
        );
        if (old == normalized) continue;
        if (chunks.any(
          (c) => identical(c.snapshot, s) && c.start < end && start < c.end,
        )) {
          throw StateError('AI 修改块重叠');
        }
        size += old.length + replacement.length;
        if (size > 256 * 1024) throw StateError('AI 修改超过预览预算');
        chunks.add(AiEditChunk(s, start, end, normalized));
      }
    }
    return AiEditSet(
      response['id'] as String,
      snapshots,
      chunks,
      active: active,
      inline: inline,
      usage: response['usage'] as Map? ?? {},
      elapsedMs: response['elapsedMs'] as int? ?? 0,
    );
  }

  bool get canUndo => _history.isNotEmpty && !saving;
  Iterable<AiEditChunk> get pending =>
      chunks.where((c) => !c.accepted && !c.rejected);
  void validate(Iterable<DocumentModel> documents) {
    if (_disposed || !active() || saving) throw StateError('AI 修改请求已过期');
    for (final doc in documents) {
      if (doc.isClosed || doc.saving || doc.version != _versions[doc]) {
        throw StateError('${doc.key.path} 已变化，请重新生成 AI 修改');
      }
    }
  }

  String _compose(AiBufferSnapshot s, Set<AiEditChunk> extra) {
    final selected =
        chunks
            .where(
              (c) =>
                  identical(c.snapshot, s) && (c.accepted || extra.contains(c)),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final text = StringBuffer();
    var offset = 0;
    for (final c in selected) {
      text
        ..write(s.text.substring(offset, c.start))
        ..write(c.replacement);
      offset = c.end;
    }
    return (text..write(s.text.substring(offset))).toString();
  }

  void accept(Iterable<AiEditChunk> selected) {
    final choices = selected.toSet();
    if (choices.isEmpty) return;
    if (choices.any((c) => !chunks.contains(c) || c.accepted || c.rejected))
      throw StateError('修改块已处理');
    final documents = choices.map((c) => c.snapshot.document).toSet();
    validate(documents);
    final plan = DocumentEditPlan([
      for (final s in snapshots.where((s) => documents.contains(s.document)))
        PlannedDocumentEdit(
          s.document,
          s.document.version,
          s.document.text,
          _compose(s, choices),
        ),
    ], active: active);
    plan.apply();
    for (final c in choices) {
      c.accepted = true;
    }
    for (final doc in documents) {
      _versions[doc] = doc.version;
    }
    _history.add((
      chunks: choices.toList(),
      changed: {
        for (final edit in plan.edits)
          if (edit.before != edit.after) edit.document,
      },
    ));
    _notify();
  }

  void reject(AiEditChunk chunk) {
    if (!chunks.contains(chunk) || chunk.accepted || chunk.rejected) return;
    chunk.rejected = true;
    _notify();
  }

  void undo() {
    if (!canUndo) return;
    final last = _history.last,
        documents = last.chunks.map((c) => c.snapshot.document).toSet();
    validate(documents);
    if (last.changed.any((d) => !d.controller.canUndo)) {
      throw StateError('编辑器撤销记录已变化');
    }
    for (final doc in last.changed) {
      doc.controller.undo();
      _versions[doc] = doc.version;
    }
    for (final c in last.chunks) {
      c.accepted = false;
    }
    _history.removeLast();
    _notify();
  }

  Future<void> save({FileTextOperation? operation}) async {
    final docs = chunks
        .where((c) => c.accepted)
        .map((c) => c.snapshot.document)
        .toSet();
    validate(docs);
    if (docs.isEmpty) throw StateError('请先接受修改块');
    final plan = DocumentEditPlan([
      for (final doc in docs)
        PlannedDocumentEdit(doc, doc.version, doc.text, doc.text),
    ], active: active);
    saving = true;
    _notify();
    try {
      await plan.applyAndSave(operation: operation);
    } finally {
      saving = false;
      _notify();
    }
  }

  bool get acceptedBuffersClean =>
      chunks.where((c) => c.accepted).every((c) => !c.snapshot.document.dirty);
}

/// One request owns its stream and source versions; cancellation is immediate
/// even during provider preparation / a late transport handshake.
class AiProposalOperation {
  final List<AiBufferSnapshot> snapshots;
  final bool Function() active;
  final bool inline;
  final bool Function()? resultActive;
  final _cancelled = Completer<void>();
  OpStream? _stream;
  bool _used = false, _finished = false;
  AiProposalOperation(
    this.snapshots, {
    required this.active,
    this.inline = false,
    this.resultActive,
  });
  bool get current =>
      !_finished &&
      !_cancelled.isCompleted &&
      active() &&
      snapshots.every((s) => s.current) &&
      (!inline ||
          snapshots.length == 1 &&
              snapshots.single.document.controller.unfoldLineSelection ==
                  snapshots.single.selection);
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    _stream?.reset();
  }

  Future<AiEditSet> run(
    Link link,
    FutureOr<Map<String, Object?>> Function() prepare,
  ) async {
    if (_used) throw StateError('AI 编辑请求只能执行一次');
    _used = true;
    void changed() {
      if (!current) cancel();
    }

    for (final s in snapshots) {
      s.document.addListener(changed);
      if (inline) s.document.controller.addListener(changed);
    }
    try {
      return await Future.any([
        (() async {
          if (!current) throw StateError('AI 编辑范围已过期');
          final args = await Future.sync(prepare)
              .timeout(const Duration(seconds: 30));
          return _run(link, args);
        })(),
        _cancelled.future.then<AiEditSet>(
          (_) => throw StateError('AI 编辑请求已取消或缓冲已变化'),
        ),
      ]);
    } finally {
      _finished = true;
      _stream?.reset();
      for (final s in snapshots) {
        s.document.removeListener(changed);
        if (inline && !s.document.isClosed)
          s.document.controller.removeListener(changed);
      }
    }
  }

  Future<AiEditSet> _run(Link link, Map<String, Object?> args) async {
    if (!current || snapshots.isEmpty || snapshots.length > 16)
      throw StateError('AI 编辑范围已过期或超出预算');
    final request = {
      ...args,
      'mode': inline ? 'complete' : 'edit',
      'documents': [for (final s in snapshots) s.toJson()],
    };
    if (utf8.encode(jsonEncode(request)).length > 768 * 1024)
      throw StateError('AI 编辑上下文超过 768 KiB，请减少文件');
    final stream = await link
        .open('ai.propose', request)
        .then((stream) {
          if (!current) stream.reset();
          return stream;
        })
        .timeout(const Duration(seconds: 20));
    if (!current) throw StateError('AI 编辑请求已取消');
    _stream = stream;
    final ready = await stream.response().timeout(const Duration(seconds: 20));
    if (!current || ready is! Map || ready['ready'] != true)
      throw StateError('AI 编辑握手无效');
    final response = await stream.response().timeout(
      const Duration(seconds: 95),
    );
    if (!current || response is! Map) throw StateError('AI 编辑结果已过期');
    return AiEditSet.fromResponse(
      snapshots,
      response,
      active: resultActive ?? active,
      inline: inline,
    );
  }
}
