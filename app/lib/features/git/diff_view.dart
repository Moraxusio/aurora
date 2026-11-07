// A unified diff, drawn with the IDE's red and green: a hunk header, line
// numbers of both sides, and the changed lines. It is read-only; staging and
// discarding happen in the change list.
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'git_model.dart';
import 'text_diff.dart';

enum DiffLineKind { meta, hunk, context, add, del }

class DiffLine {
  final DiffLineKind kind;
  final String text;
  final int? oldNo, newNo;
  DiffLine(this.kind, this.text, {this.oldNo, this.newNo});
}

/// Parses `git diff` output for one file into lines with numbers on both
/// sides. The header lines before the first hunk are kept as "meta".
List<DiffLine> parseDiff(String diff) {
  final out = <DiffLine>[];
  var oldNo = 0, newNo = 0;
  var inHunk = false;
  final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
  for (final line in diff.split('\n')) {
    final h = hunk.firstMatch(line);
    if (h != null) {
      oldNo = int.parse(h.group(1)!);
      newNo = int.parse(h.group(2)!);
      inHunk = true;
      out.add(DiffLine(DiffLineKind.hunk, line));
      continue;
    }
    if (!inHunk) {
      if (line.isNotEmpty) out.add(DiffLine(DiffLineKind.meta, line));
      continue;
    }
    if (line.startsWith('diff --git')) {
      inHunk = false;
      out.add(DiffLine(DiffLineKind.meta, line));
    } else if (line.startsWith('+')) {
      out.add(DiffLine(DiffLineKind.add, line.substring(1), newNo: newNo++));
    } else if (line.startsWith('-')) {
      out.add(DiffLine(DiffLineKind.del, line.substring(1), oldNo: oldNo++));
    } else if (line.startsWith(r'\')) {
      out.add(DiffLine(DiffLineKind.meta, line));
    } else if (line.isNotEmpty || oldNo > 0) {
      out.add(DiffLine(DiffLineKind.context, line.isEmpty ? '' : line.substring(1), oldNo: oldNo++, newNo: newNo++));
    }
  }
  while (out.isNotEmpty && out.last.kind == DiffLineKind.context && out.last.text.isEmpty) {
    out.removeLast();
  }
  return out;
}

/// An added file has no diff: its text is shown as all-added lines.
List<DiffLine> allAdded(String text) {
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return [for (var i = 0; i < lines.length; i++) DiffLine(DiffLineKind.add, lines[i], newNo: i + 1)];
}

final _headerNoise = RegExp(r'^(diff --git |index [0-9a-f]+\.\.[0-9a-f]+|--- |\+\+\+ )');

/// Git prints a file header before the first hunk (diff --git, index, ---,
/// +++). The tab's title already says which file and which side, so these
/// four go; lines that carry information (new file mode, rename from,
/// "Binary files differ") stay.
List<DiffLine> withoutFileHeader(List<DiffLine> lines) => [
      for (final l in lines)
        if (!(l.kind == DiffLineKind.meta && _headerNoise.hasMatch(l.text))) l
    ];

class DiffView extends StatelessWidget {
  final List<DiffLine> lines;
  final String? note;
  const DiffView({super.key, required this.lines, this.note});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (lines.isEmpty) return EmptyHint(icon: Icons.difference_outlined, text: note ?? '没有差异');
    const mono = TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 13, height: 1.4);
    final width = lines.fold<int>(0, (m, l) => l.text.length > m ? l.text.length : m);
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: (width * 8.2 + 120).clamp(MediaQuery.sizeOf(context).width - 40, 100000).toDouble(),
          child: ListView.builder(
            itemCount: lines.length,
            itemExtent: 19,
            itemBuilder: (_, i) {
              final l = lines[i];
              final (bg, fg, sign) = switch (l.kind) {
                DiffLineKind.add => (ide.addBg, ide.addText, '+'),
                DiffLineKind.del => (ide.delBg, ide.delText, '-'),
                DiffLineKind.hunk => (ide.selection.withValues(alpha: 0.35), ide.accent, ' '),
                DiffLineKind.meta => (null, ide.textDim, ' '),
                DiffLineKind.context => (null, ide.text, ' '),
              };
              return Container(
                color: bg,
                child: Row(children: [
                  SizedBox(width: 44, child: Text(l.oldNo?.toString() ?? '', textAlign: TextAlign.right, style: mono.copyWith(color: ide.textDim))),
                  SizedBox(width: 44, child: Text(l.newNo?.toString() ?? '', textAlign: TextAlign.right, style: mono.copyWith(color: ide.textDim))),
                  SizedBox(width: 18, child: Text(sign, textAlign: TextAlign.center, style: mono.copyWith(color: fg))),
                  Expanded(child: Text(l.text, softWrap: false, style: mono.copyWith(color: l.kind == DiffLineKind.context ? ide.text : fg))),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The tab that shows the diff of [path] in the work tree, the index, or a commit.
EditorTab diffTab(Workspace ws, GitModel git, {required String path, required bool staged, String? commit, bool untracked = false}) {
  final repo = git.repo!;
  final side = commit != null ? commit.substring(0, commit.length < 8 ? commit.length : 8) : (staged ? '暂存' : '工作区');
  return EditorTab(
    id: 'diff:${repo.root}:${repo.repo}:$path:${commit ?? (staged ? 'index' : 'work')}',
    title: '${path.split('/').last} ($side)',
    icon: Icons.difference_outlined,
    tooltip: '$path · $side',
    builder: (_) => _DiffLoader(ws: ws, repo: repo, path: path, staged: staged, commit: commit, untracked: untracked),
  );
}

class _DiffLoader extends StatefulWidget {
  final Workspace ws;
  final GitRepo repo;
  final String path;
  final bool staged, untracked;
  final String? commit;
  const _DiffLoader({required this.ws, required this.repo, required this.path, required this.staged, required this.untracked, this.commit});
  @override
  State<_DiffLoader> createState() => _DiffLoaderState();
}

class _DiffLoaderState extends State<_DiffLoader> {
  List<DiffLine>? _lines;
  String? _note;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final link = widget.ws.link;
    if (link == null) return setState(() => _error = '未连接');
    try {
      final base = {'root': widget.repo.root, 'repo': widget.repo.repo};
      List<DiffLine> lines;
      if (widget.commit != null) {
        // The agent has no per-file patch for a commit: read the file as it
        // was before and after, and compare here.
        Future<({String text, bool binary, bool missing})> at(String rev) async {
          final s = (await link.call('git.show', {...base, 'rev': rev, 'path': widget.path}) as Map).cast<String, dynamic>();
          return (text: (s['text'] as String?) ?? '', binary: s['binary'] == true || s['too_big'] == true, missing: s['missing'] == true);
        }

        final before = await at('${widget.commit}^'), after = await at(widget.commit!);
        if (before.binary || after.binary) {
          lines = [];
          _note = '二进制文件，或文件太大，不显示差异';
        } else {
          lines = diffTexts(before.missing ? '' : before.text, after.missing ? '' : after.text);
          if (lines.isEmpty) _note = before.missing && after.missing ? '这次提交里没有这个文件' : '内容没有变化（可能只改了权限）';
        }
      } else {
        final r = (await link.call('git.diff', {...base, 'paths': [widget.path]}) as Map).cast<String, dynamic>();
        if (widget.untracked) {
          final news = (r['untracked'] as List?) ?? const [];
          final hit = news.cast<Map>().where((n) => n['path'] == widget.path).toList();
          if (hit.isEmpty) {
            lines = [];
          } else if (hit.first['binary'] == true) {
            lines = [];
            _note = '二进制文件';
          } else if (hit.first['too_big'] == true) {
            lines = [];
            _note = '文件太大，不显示';
          } else {
            lines = allAdded((hit.first['text'] as String?) ?? '');
          }
        } else {
          lines = withoutFileHeader(parseDiff((widget.staged ? r['staged'] : r['unstaged']) as String? ?? ''));
          if (r['truncated'] == true) _note = '差异太大，只显示了前 4 MB';
        }
      }
      if (mounted) setState(() => _lines = lines);
    } on OpError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return EmptyHint(
        icon: Icons.error_outline,
        text: _error!,
        actionLabel: '重试',
        onAction: () {
          setState(() => _error = null);
          _load();
        },
      );
    }
    if (_lines == null) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    return DiffView(lines: _lines!, note: _note);
  }
}
