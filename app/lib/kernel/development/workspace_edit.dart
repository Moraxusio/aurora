import '../document_model.dart';
import '../document_recovery.dart';
import 'text_edits.dart';

class _Draft {
  final DocumentModel document;
  final int version;
  final String before;
  final bool existed;
  bool exists;
  String text, encoding;
  int mode;
  int logicalVersion;
  _Draft(this.document)
    : version = document.version,
      logicalVersion = document.version,
      before = document.text,
      text = document.text,
      existed = document.etag != null,
      exists = document.etag != null || document.dirty,
      encoding = document.encoding,
      mode = document.fileMode;
}

/// Interpret documentChanges in protocol order against virtual file states.
/// Nothing is written until the entire, versioned plan has been reviewed.
Future<DocumentEditPlan> prepareWorkspaceEdit({
  required DocumentRegistry documents,
  required String root,
  required String? Function(String) pathFromUri,
  required bool caseSensitive,
  required Map edit,
  required Map<DocumentKey, int> expected,
  required bool Function() active,
  Future<void>? cancelled,
}) async {
  final drafts = <String, _Draft>{}, resources = <String>[];
  String identity(String path) => caseSensitive ? path : path.toLowerCase();
  Future<_Draft> load(Object? uri) async {
    if (uri is! String) throw StateError('WorkspaceEdit 缺少文件 URI');
    final path = pathFromUri(uri);
    if (path == null || path == '/') throw StateError('修改路径超出文件工作根目录');
    final id = identity(path);
    if (drafts[id] case final found?) return found;
    if (drafts.length >= 128) throw StateError('修改超过 128 个文件预算');
    final existing = documents.all
        .where((d) => d.key.root == root && identity(d.key.path) == id)
        .firstOrNull;
    final doc = existing ?? documents.open(root, path);
    await doc.load();
    if (!active() || doc.isClosed || doc.saving) throw StateError('修改预览已过期');
    if (doc.phase != DocumentPhase.ready && doc.diskMissing)
      doc.prepareMissingTarget();
    if (doc.phase != DocumentPhase.ready) throw StateError('$path 不是可编辑的文本文件');
    if (expected[doc.key] != null && expected[doc.key] != doc.version) {
      throw StateError('$path 已变化');
    }
    return drafts[id] = _Draft(doc);
  }

  void budget() {
    if (drafts.values.fold<int>(
          0,
          (n, d) => n + d.before.length + d.text.length,
        ) >
        8 * 1024 * 1024) {
      throw StateError('修改超过 8 Mi 字符预览预算');
    }
  }

  Future<void> textEdit(Object? uri, Object? edits, Object? version) async {
    if (edits is! List) throw StateError('WorkspaceEdit 文本修改格式无效');
    final d = await load(uri);
    if (!d.exists || version != null && version != d.logicalVersion) {
      throw StateError('${d.document.key.path} 不存在或版本已变化');
    }
    d.text = applyTextEdits(d.text, edits);
    budget();
  }

  if (edit['changes'] is Map && edit['documentChanges'] != null) {
    throw StateError('WorkspaceEdit 不能同时包含两种修改列表');
  }
  if (edit['changes'] case final Map changes) {
    for (final entry in changes.entries) {
      await textEdit(entry.key, entry.value, null);
    }
  }
  final sequence = edit['documentChanges'] ?? const [];
  if (sequence is! List || sequence.length > 512)
    throw StateError('WorkspaceEdit 操作列表无效或过长');
  for (final item in sequence) {
    if (item is! Map) throw StateError('WorkspaceEdit 操作格式无效');
    final options = item['options'] is Map ? item['options'] as Map : const {};
    switch (item['kind']) {
      case 'create':
        final target = await load(item['uri']);
        if (target.exists && options['overwrite'] != true) {
          if (options['ignoreIfExists'] == true) continue;
          throw StateError('${target.document.key.path} 已存在');
        }
        target.exists = true;
        target.text = '';
        target.encoding = 'utf-8';
        resources.add('创建 ${target.document.key.path}');
      case 'rename':
        final source = await load(item['oldUri']),
            target = await load(item['newUri']);
        if (identical(source, target))
          throw StateError('移动的源与目标相同（Windows 包含仅大小写变化）');
        if (!source.exists) throw StateError('${source.document.key.path} 不存在');
        if (target.exists && options['overwrite'] != true) {
          if (options['ignoreIfExists'] == true) continue;
          throw StateError('${target.document.key.path} 已存在');
        }
        target.exists = true;
        target.text = source.text;
        target.encoding = source.encoding;
        target.mode = source.mode;
        target.logicalVersion = source.logicalVersion;
        source.exists = false;
        source.text = '';
        resources.add(
          '移动 ${source.document.key.path} → ${target.document.key.path}',
        );
      case 'delete':
        final target = await load(item['uri']);
        if (!target.exists) {
          if (options['ignoreIfNotExists'] == true) continue;
          throw StateError('${target.document.key.path} 不存在');
        }
        target.exists = false;
        target.text = '';
        resources.add('删除 ${target.document.key.path}');
      case null:
        final identifier = item['textDocument'];
        if (identifier is! Map) throw StateError('WorkspaceEdit 缺少文档标识');
        await textEdit(identifier['uri'], item['edits'], identifier['version']);
      default:
        throw StateError('未知的 WorkspaceEdit 资源操作');
    }
    budget();
  }
  final plan = DocumentEditPlan(
    [
      for (final d in drafts.values)
        if ((d.exists || d.existed) &&
            (d.exists != d.existed ||
                d.text != d.before ||
                d.encoding != d.document.encoding))
          PlannedDocumentEdit(
            d.document,
            d.version,
            d.before,
            d.text,
            delete: !d.exists,
            encoding: d.encoding,
            modeBits: resources.isEmpty ? null : d.mode,
          ),
    ],
    active: active,
    cancelled: cancelled,
    resources: List.unmodifiable(resources),
  );
  plan.validate();
  return plan;
}
