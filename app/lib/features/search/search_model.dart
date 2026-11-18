// Text search across the project (fs.search, one call per folder). A newer
// search makes the answers of an older one that are still on the way count
// for nothing, so typing quickly never shows stale results.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import '../../kernel/workspace.dart';
import '../../kernel/document_model.dart';
import '../../kernel/file_text.dart';
import '../../kernel/development/text_edits.dart';
import 'search_scope.dart';

class SearchLine {
  final int line, col; // 1-based; col in UTF-16 units
  final String text;
  final List<(int, int)>
  ranges; // matches inside text, UTF-16 units [start, end)
  SearchLine(this.line, this.col, this.text, this.ranges);

  factory SearchLine.fromJson(Map<String, dynamic> j) => SearchLine(
    (j['line'] as num).toInt(),
    (j['col'] as num?)?.toInt() ?? 1,
    j['text'] as String? ?? '',
    [
      for (final r in (j['ranges'] as List? ?? const []))
        if (r is List && r.length == 2)
          ((r[0] as num).toInt(), (r[1] as num).toInt()),
    ],
  );
}

class SearchFile {
  final SearchFolder folder;
  final String path; // absolute inside the root
  final List<SearchLine> lines;
  SearchFile(this.folder, this.path, this.lines);
}

class SearchOptions {
  final String query;
  final bool regex, matchCase, word;
  final String include, exclude;
  const SearchOptions(
    this.query, {
    this.regex = false,
    this.matchCase = false,
    this.word = false,
    this.include = '',
    this.exclude = '',
  });

  Map<String, dynamic> toArgs() => {
    'query': query,
    'regex': regex,
    'case': matchCase,
    'word': word,
    if (include.trim().isNotEmpty) 'include': include.trim(),
    if (exclude.trim().isNotEmpty) 'exclude': exclude.trim(),
  };
}

class SearchModel extends ChangeNotifier {
  final Workspace ws;
  final Future<List<SearchFolder>> Function(Workspace) folders;
  SearchModel(this.ws, {this.folders = searchFolders}) {
    _link = ws.link;
    _project = ws.projectKey;
    ws.addListener(_workspaceChanged);
  }

  List<SearchFile> results = [];
  int total = 0;
  bool running = false;
  bool replacing = false;
  SearchOptions? _options;
  FileTextOperation? _replacement;
  bool truncated = false;
  bool timedOut = false;
  bool incomplete = false;
  String? error;
  List<String> notes = [];
  int _generation = 0;
  Completer<void> _lifetime = Completer<void>();
  bool _disposed = false;
  OpStream? _stream;
  Link? _link;
  String? _project;
  static const maxResults = 2000;

  void _workspaceChanged() {
    if (identical(_link, ws.link) && _project == ws.projectKey) return;
    _link = ws.link;
    _project = ws.projectKey;
    clear();
  }

  bool _active(int gen, Link link) =>
      !_disposed && gen == _generation && identical(link, ws.link);

  void cancel() {
    _lifetime.complete();
    _lifetime = Completer<void>();
    _generation++;
    _stream?.reset();
    _stream = null;
    _replacement?.cancel();
    _replacement = null;
    replacing = false;
    running = false;
    _options = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    ws.removeListener(_workspaceChanged);
    _disposed = true;
    super.dispose();
  }

  void clear() {
    cancel();
    results = [];
    total = 0;
    running = false;
    truncated = timedOut = incomplete = false;
    error = null;
    notes = [];
    _options = null;
    _notify();
  }

  Future<void> search(SearchOptions o) async {
    cancel();
    final gen = ++_generation;
    if (o.query.isEmpty) return clear();
    final link = ws.link;
    if (link == null) {
      error = '未连接';
      _notify();
      return;
    }
    results = [];
    total = 0;
    truncated = timedOut = incomplete = false;
    error = null;
    notes = [];
    running = true;
    _notify();
    List<SearchFolder> scope;
    try {
      scope = await folders(ws);
    } on Object catch (e) {
      if (!_active(gen, link)) return;
      error = e is OpError ? e.message : '无法获取搜索范围';
      running = false;
      _notify();
      return;
    }
    if (!_active(gen, link)) return;
    if (scope.isEmpty) {
      running = false;
      error = '没有可以搜索的文件夹';
      _notify();
      return;
    }
    for (final f in scope) {
      try {
        final args = {
          'root': f.root,
          'path': f.path,
          ...o.toArgs(),
          'max': maxResults - total,
        };
        final r = (await _request(link, args, gen) as Map)
            .cast<String, dynamic>();
        if (!_active(gen, link)) return;
        for (final x in (r['files'] as List? ?? const [])) {
          final m = (x as Map).cast<String, dynamic>();
          final lines = [
            for (final l in (m['matches'] as List? ?? const []).take(
              maxResults - total,
            ))
              SearchLine.fromJson((l as Map).cast<String, dynamic>()),
          ];
          if (lines.isNotEmpty)
            results.add(SearchFile(f, normalized(m['path'] as String), lines));
          total += lines.length;
        }
        truncated |= r['truncated'] == true;
        timedOut |= r['timed_out'] == true;
        final skipped = (r['skipped_large'] as num?)?.toInt() ?? 0;
        incomplete |= skipped > 0 || r['incomplete'] == true;
        if (skipped > 0) notes.add('${f.label}：跳过了 $skipped 个大于 4 MB 的文件');
        if (r['incomplete'] == true)
          notes.add('${f.label}：有 ${r['errors']} 个文件夹无法读取');
      } on Object catch (e) {
        if (!_active(gen, link)) return;
        incomplete = true;
        if (e is OpError && e.code == codeBadRequest) {
          error = e.message;
          running = false;
          _notify();
          return;
        }
        notes.add('${f.label}：${e is OpError ? e.message : '搜索失败，请重试'}');
      }
      _notify();
      if (total >= maxResults) {
        truncated = true;
        break;
      }
    }
    if (!_active(gen, link)) return;
    running = false;
    _options = o;
    _notify();
  }

  /// The candidate set is the displayed search result, deduplicated across
  /// overlapping folders. Every candidate is re-read through DocumentModel;
  /// open buffers, including unsaved edits, are the authoritative input.
  Future<DocumentEditPlan> previewReplacement(String replacement) async {
    final options = _options, link = ws.link, gen = _generation;
    if (running ||
        replacing ||
        options == null ||
        link == null ||
        error != null) {
      throw StateError('请先完成搜索再生成替换预览');
    }
    if (truncated || timedOut || incomplete) throw StateError('搜索结果不完整，请处理无法读取的目录或缩小搜索范围后再替换');
    if (!link.server.caps.contains('fs.replace.preview') ||
        !link.server.caps.contains('fs.commit')) {
      throw StateError('跨文件替换需要新版 agent 的预览与文件事务服务');
    }
    final paths = {for (final file in results) (file.folder.root, file.path)};
    if (paths.isEmpty || paths.length > 128)
      throw StateError('替换范围须包含 1–128 个文件');
    bool current() => _active(gen, link);
    replacing = true;
    _notify();
    try {
      final edits = <PlannedDocumentEdit>[];
      var budget = 0;
      for (final path in paths) {
        if (!current()) throw StateError('替换预览已取消');
        final doc = ws.documents.open(path.$1, path.$2);
        await doc.load();
        if (!current() ||
            doc.isClosed ||
            doc.phase != DocumentPhase.ready ||
            doc.saving) {
          throw StateError('${path.$2} 当前不可编辑');
        }
        final before = doc.text, version = doc.version, tag = doc.etag;
        budget += before.length;
        if (budget > 8 * 1024 * 1024) throw StateError('替换超过 8 Mi 字符预览预算');
        final operation = _replacement = FileTextOperation(active: current);
        final result = await operation.replace(link, before, {
          ...options.toArgs(),
          'replacement': replacement,
        });
        if (!current() ||
            doc.isClosed ||
            doc.version != version ||
            doc.etag != tag) {
          throw StateError('${path.$2} 已变化，请重新生成替换预览');
        }
        final after = result['content'] as String;
        budget += after.length;
        if (budget > 8 * 1024 * 1024) throw StateError('替换超过 8 Mi 字符预览预算');
        if (before != after)
          edits.add(PlannedDocumentEdit(doc, version, before, after));
      }
      final plan = DocumentEditPlan(
        edits,
        active: current,
        cancelled: _lifetime.future,
      );
      plan.validate();
      return plan;
    } finally {
      if (_generation == gen) {
        _replacement = null;
        replacing = false;
        _notify();
      }
    }
  }

  Future<Object?> _request(
    Link link,
    Map<String, dynamic> args,
    int gen,
  ) async {
    if (!link.server.caps.contains('fs.search.stream')) {
      return link.call('fs.search', args, const Duration(seconds: 40));
    }
    final stream = await link.open('fs.search.stream', args);
    if (!_active(gen, link)) {
      stream.reset();
      throw StateError('搜索已取消');
    }
    _stream = stream;
    try {
      return await stream.response().timeout(const Duration(seconds: 40));
    } finally {
      stream.reset();
      if (identical(_stream, stream)) _stream = null;
    }
  }
}
