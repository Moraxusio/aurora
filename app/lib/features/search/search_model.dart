// Text search across the project (fs.search, one call per folder). A newer
// search makes the answers of an older one that are still on the way count
// for nothing, so typing quickly never shows stale results.
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import '../../kernel/workspace.dart';
import 'search_scope.dart';

class SearchLine {
  final int line, col; // 1-based; col in UTF-16 units
  final String text;
  final List<(int, int)> ranges; // matches inside text, UTF-16 units [start, end)
  SearchLine(this.line, this.col, this.text, this.ranges);

  factory SearchLine.fromJson(Map<String, dynamic> j) => SearchLine(
        (j['line'] as num).toInt(),
        (j['col'] as num?)?.toInt() ?? 1,
        j['text'] as String? ?? '',
        [
          for (final r in (j['ranges'] as List? ?? const []))
            if (r is List && r.length == 2) ((r[0] as num).toInt(), (r[1] as num).toInt()),
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
  const SearchOptions(this.query, {this.regex = false, this.matchCase = false, this.word = false, this.include = '', this.exclude = ''});

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
  SearchModel(this.ws, {this.folders = searchFolders});

  List<SearchFile> results = [];
  int total = 0;
  bool running = false;
  bool truncated = false;
  bool timedOut = false;
  String? error;
  List<String> notes = [];
  int _generation = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void clear() {
    _generation++;
    results = [];
    total = 0;
    running = false;
    truncated = timedOut = false;
    error = null;
    notes = [];
    _notify();
  }

  Future<void> search(SearchOptions o) async {
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
    truncated = timedOut = false;
    error = null;
    notes = [];
    running = true;
    _notify();
    final scope = await folders(ws);
    if (gen != _generation) return;
    if (scope.isEmpty) {
      running = false;
      error = '没有可以搜索的文件夹';
      _notify();
      return;
    }
    for (final f in scope) {
      try {
        final r = (await link.call('fs.search', {'root': f.root, 'path': f.path, ...o.toArgs()}, const Duration(seconds: 40)) as Map).cast<String, dynamic>();
        if (gen != _generation) return;
        for (final x in (r['files'] as List? ?? const [])) {
          final m = (x as Map).cast<String, dynamic>();
          final lines = [for (final l in (m['matches'] as List? ?? const [])) SearchLine.fromJson((l as Map).cast<String, dynamic>())];
          results.add(SearchFile(f, normalized(m['path'] as String), lines));
        }
        total += (r['total'] as num?)?.toInt() ?? 0;
        truncated |= r['truncated'] == true;
        timedOut |= r['timed_out'] == true;
        final skipped = (r['skipped_large'] as num?)?.toInt() ?? 0;
        if (skipped > 0) notes.add('${f.label}：跳过了 $skipped 个大于 4 MB 的文件');
        if (r['incomplete'] == true) notes.add('${f.label}：有 ${r['errors']} 个文件夹无法读取');
      } on OpError catch (e) {
        if (gen != _generation) return;
        if (e.code == codeBadRequest) {
          error = e.message;
          running = false;
          _notify();
          return;
        }
        notes.add('${f.label}：${e.message}');
      }
      _notify();
    }
    if (gen != _generation) return;
    running = false;
    _notify();
  }
}
