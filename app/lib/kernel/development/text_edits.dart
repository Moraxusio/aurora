import '../document_model.dart';
import '../file_text.dart';

/// LSP positions are UTF-16, matching Dart string offsets. CRLF is a single
/// line separator and neither its CR nor half of a surrogate pair is editable.
int positionOffset(String text, Map position) {
  final line = position['line'], character = position['character'];
  if (line is! int || character is! int || line < 0 || character < 0) {
    throw StateError('无效的文本位置');
  }
  var start = 0;
  for (var i = 0; i < line; i++) {
    final newline = text.indexOf('\n', start);
    if (newline < 0) throw StateError('文本位置超出行数');
    start = newline + 1;
  }
  var end = text.indexOf('\n', start);
  if (end < 0) end = text.length;
  if (end > start && text.codeUnitAt(end - 1) == 13) end--;
  if (character > end - start) throw StateError('文本位置超出列数');
  final offset = start + character;
  if (offset > 0 &&
      offset < text.length &&
      text.codeUnitAt(offset - 1) >= 0xD800 &&
      text.codeUnitAt(offset - 1) <= 0xDBFF &&
      text.codeUnitAt(offset) >= 0xDC00 &&
      text.codeUnitAt(offset) <= 0xDFFF) {
    throw StateError('文本位置拆分了 Unicode 字符');
  }
  return offset;
}

String applyTextEdits(String before, List<dynamic> edits) {
  final ranges = <({int start, int end, int index, String text})>[];
  for (var i = 0; i < edits.length; i++) {
    final edit = edits[i];
    if (edit is! Map || edit['range'] is! Map || edit['newText'] is! String) {
      throw StateError('无效的文本修改');
    }
    final range = edit['range'] as Map;
    if (range['start'] is! Map || range['end'] is! Map)
      throw StateError('无效的文本范围');
    final start = positionOffset(before, range['start'] as Map);
    final end = positionOffset(before, range['end'] as Map);
    if (end < start) throw StateError('文本修改范围倒置');
    ranges.add((
      start: start,
      end: end,
      text: edit['newText'] as String,
      index: i,
    ));
  }
  ranges.sort((a, b) {
    final order = a.start.compareTo(b.start);
    return order == 0 ? a.index.compareTo(b.index) : order;
  });
  final result = StringBuffer();
  var offset = 0;
  for (final edit in ranges) {
    if (edit.start < offset) throw StateError('文本修改存在重叠');
    result
      ..write(before.substring(offset, edit.start))
      ..write(edit.text);
    offset = edit.end;
  }
  result.write(before.substring(offset));
  if (result.length > 4 * 1024 * 1024) throw StateError('编辑结果超过文档预算');
  return result.toString();
}

class PlannedDocumentEdit {
  final DocumentModel document;
  final int version;
  final String before, after;
  final String encoding;
  final String beforeEncoding, beforeDisk;
  final String? commitText;
  final int beforeMode;
  final int? modeBits;
  final bool delete;
  final String? etag;
  PlannedDocumentEdit(
    this.document,
    this.version,
    this.before,
    this.after, {
    this.delete = false,
    String? encoding,
    String? commitText,
    this.modeBits,
  }) : encoding = encoding ?? document.encoding,
       beforeEncoding = document.encoding,
       beforeDisk = document.baseText,
       beforeMode = document.fileMode,
       commitText = delete ? null : commitText ?? after,
       etag = document.etag;
}

/// Validate the whole batch before the first in-memory mutation. Each document
/// receives one genuine editor undo step. Batch save uses the same file
/// transaction as regular saves, with a final buffer check before the end frame.
class DocumentEditPlan {
  final List<PlannedDocumentEdit> edits;
  final bool Function() active;
  final Future<void>? cancelled;
  final List<String> resources;
  bool applied = false, committing = false, saved = false, undone = false;
  DocumentEditPlan? _undo;
  bool get requiresSave => resources.isNotEmpty;
  bool get canUndo => saved && !undone && _undo != null;
  DocumentEditPlan(
    this.edits, {
    required this.active,
    this.cancelled,
    this.resources = const [],
  });
  void validate({bool saving = false}) {
    if (applied || !active()) throw StateError('修改预览已过期');
    final seen = <DocumentModel>{};
    for (final edit in edits) {
      if (!seen.add(edit.document)) throw StateError('修改预览包含重复文档');
      if (edit.document.isClosed ||
          (!saving && edit.document.saving) ||
          edit.document.phase != DocumentPhase.ready ||
          edit.document.version != edit.version ||
          edit.document.etag != edit.etag ||
          edit.document.encoding != edit.beforeEncoding) {
        throw StateError('${edit.document.key.path} 已变化，请重新生成修改');
      }
    }
  }

  void apply() {
    if (requiresSave) throw StateError('资源重构必须通过整批事务保存');
    if (committing) throw StateError('整批修改正在保存');
    validate();
    _apply();
  }

  void _apply() {
    for (final edit in edits) {
      if (edit.delete) continue;
      if (edit.document.encoding != edit.encoding) {
        edit.document.setSaveEncoding(edit.encoding);
      }
      if (edit.document.text != edit.after) {
        edit.document.replaceText(
          edit.after,
          expectedVersion: edit.document.version,
        );
      }
      edit.document.markPendingCreation();
    }
    applied = true;
  }

  Future<void> applyAndSave({FileTextOperation? operation}) async {
    if (committing) throw StateError('整批修改正在保存');
    validate();
    if (edits.isEmpty) return;
    final link = edits.first.document.currentLink();
    if (link == null ||
        !link.server.caps.contains('fs.commit') ||
        (requiresSave && !link.server.caps.contains('fs.refactor')) ||
        edits.any((e) => !identical(link, e.document.currentLink()))) {
      throw StateError('整批保存需要同一连接上的文件事务服务');
    }
    final transfer =
        operation ??
        FileTextOperation(
          active: () =>
              active() &&
              edits.every(
                (e) =>
                    !e.document.isClosed &&
                    identical(link, e.document.currentLink()),
              ),
        );
    final guards = <DocumentSaveGuard>[];
    final submittedVersions = <int>[];
    committing = true;
    try {
      for (final edit in edits) {
        guards.add(edit.document.beginSave(transfer));
      }
      final files = await transfer.commit(
        link,
        [
          for (final e in edits)
            FileTextChange(
              root: e.document.key.root,
              path: e.document.key.path,
              etag: e.etag,
              text: e.commitText,
              encoding: e.encoding,
              modeBits: e.modeBits,
            ),
        ],
        resource: requiresSave,
        beforeCommit: () {
          validate(saving: true);
          _apply();
          submittedVersions.addAll(edits.map((e) => e.document.version));
        },
      );
      for (var i = 0; i < edits.length; i++) {
        if (edits[i].delete) {
          guards[i].acknowledgeDeleted();
          continue;
        }
        guards[i].acknowledge(
          edits[i].commitText!,
          edits[i].encoding,
          submittedVersions[i],
          files[i],
        );
      }
      saved = true;
      if (requiresSave) {
        _undo = DocumentEditPlan(
          [
            for (var i = 0; i < edits.length; i++)
              PlannedDocumentEdit(
                edits[i].document,
                submittedVersions[i],
                edits[i].document.text,
                edits[i].before,
                delete: edits[i].etag == null,
                encoding: edits[i].beforeEncoding,
                commitText: edits[i].beforeDisk,
                modeBits: edits[i].beforeMode,
              ),
          ],
          active: () => edits.every(
            (e) =>
                !e.document.isClosed &&
                identical(link, e.document.currentLink()),
          ),
          resources: const ['撤销上一次资源重构'],
        );
      }
      await Future.wait(edits.map((e) => e.document.flushRecovery()));
    } finally {
      for (final guard in guards) {
        guard.finish();
      }
      committing = false;
    }
  }

  Future<void> undo({FileTextOperation? operation}) async {
    if (!canUndo || committing) throw StateError('当前没有可撤销的资源事务');
    await _undo!.applyAndSave(operation: operation);
    undone = true;
  }
}
