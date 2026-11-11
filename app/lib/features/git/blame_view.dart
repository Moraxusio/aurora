// Blame: the file as committed in the work tree, each line with the commit
// that last changed it. Consecutive lines of one commit show its details once.
// A click on a commit opens what it changed.
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'git_feature.dart' show CommitView;
import 'git_model.dart';

EditorTab blameTab(Workspace ws, GitModel git, String path) {
  final r = git.repo!;
  return EditorTab(
    id: 'blame:${r.root}:${r.repo}:$path',
    title: 'Blame ${path.split('/').last}',
    icon: Icons.person_search_outlined,
    tooltip: path,
    builder: (_) => BlameView(ws: ws, git: git, path: path),
  );
}

class BlameView extends StatefulWidget {
  final Workspace ws;
  final GitModel git;
  final String path;
  const BlameView({super.key, required this.ws, required this.git, required this.path});
  @override
  State<BlameView> createState() => _BlameViewState();
}

class _BlameViewState extends State<BlameView> {
  Blame? _blame;
  List<String>? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // the blame is of the work tree file, so its text is the work tree's
      final repo = widget.git.repo!;
      final abs = repo.repo == '/' || repo.repo.isEmpty ? '/${widget.path}' : '${repo.repo}/${widget.path}';
      final link = widget.ws.link;
      if (link == null) throw OpError(codeUnavailable, '未连接');
      final results = await Future.wait([
        widget.git.blame(widget.path),
        link.call('fs.read', {'root': repo.root, 'path': abs}),
      ]);
      final b = results[0] as Blame?;
      final r = (results[1] as Map).cast<String, dynamic>();
      if (!mounted) return;
      if (b == null) return setState(() => _error = '读取 blame 失败');
      if (r['binary'] == true || r['truncated'] == true) return setState(() => _error = '二进制文件或超过 512 KB 的文件不显示 blame');
      final content = r['content'] as String? ?? '';
      final lines = content.split(RegExp(r'\r?\n'));
      if (content.endsWith('\n')) lines.removeLast();
      setState(() {
        _blame = b;
        _text = lines;
      });
    } on OpError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _openCommit(BlameCommit c) {
    if (c.uncommitted) return;
    final repo = widget.git.repo!;
    final commit = GitCommit.fromJson({'hash': c.hash, 'short': c.short, 'author': c.author, 'subject': c.summary, 'time': c.time});
    widget.ws.openTab(EditorTab(
      id: 'commit:${repo.root}:${repo.repo}:${c.hash}',
      title: '${c.short} ${c.summary}',
      icon: Icons.commit,
      tooltip: '${c.hash}\n${c.author}',
      builder: (_) => CommitView(ws: widget.ws, git: widget.git, commit: commit),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _load);
    final b = _blame, text = _text;
    if (b == null || text == null) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    final mono = TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 12.5, height: 1.45, color: ide.text);
    return ListView.builder(
      itemCount: text.length,
      itemExtent: 19,
      itemBuilder: (_, i) {
        final c = b.at(i);
        final first = i == 0 || b.at(i - 1)?.hash != c?.hash;
        return Row(children: [
          InkWell(
            onTap: c == null || c.uncommitted ? null : () => _openCommit(c),
            child: Container(
              width: 300,
              height: 19,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(color: ide.sideBar, border: Border(top: first ? BorderSide(color: ide.border) : BorderSide.none, right: BorderSide(color: ide.border))),
              child: first && c != null
                  ? Row(children: [
                      SizedBox(width: 60, child: Text(c.uncommitted ? '未提交' : c.short, style: TextStyle(fontSize: 11, color: c.uncommitted ? ide.warn : ide.accent))),
                      SizedBox(width: 90, child: Text(c.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ide.textDim))),
                      Expanded(child: Text(c.uncommitted ? '' : relativeTime(c.time), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ide.textDim))),
                    ])
                  : null,
            ),
          ),
          SizedBox(width: 44, child: Text('${i + 1}', textAlign: TextAlign.right, style: mono.copyWith(color: ide.textDim, fontSize: 11.5))),
          const SizedBox(width: 10),
          Expanded(child: Tooltip(
            message: c == null || c.uncommitted ? '' : '${c.short} ${c.summary}\n${c.author} · ${formatTime(c.time * 1000)}',
            waitDuration: const Duration(milliseconds: 600),
            child: Text(text[i], maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: mono),
          )),
        ]);
      },
    );
  }
}
