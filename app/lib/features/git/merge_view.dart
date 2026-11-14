// A conflicted file, block by block: each conflict shows both sides (and the
// common base when git wrote it) with buttons to keep ours, theirs, both, or
// the base. The file is written only when the user saves, with the etag it was
// read with, so an edit made meanwhile elsewhere is not overwritten. When no
// conflict is left the file can be staged, which tells git it is resolved.
// Anything else (an edit by hand) is done in the normal editor.
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../files/file_editor.dart';
import 'conflicts.dart';
import 'git_model.dart';

EditorTab mergeTab(Workspace ws, GitModel git, String path) {
  final r = git.repo!;
  final key = GlobalKey<MergeViewState>();
  final tab = EditorTab(
    id: 'merge:${r.root}:${r.repo}:$path',
    title: '合并 ${path.split('/').last}',
    icon: Icons.merge_type,
    tooltip: path,
    builder: (_) => MergeView(key: key, ws: ws, git: git, path: path),
  );
  tab.confirmClose = () async => key.currentState?.confirmClose() ?? true;
  return tab;
}

class MergeView extends StatefulWidget {
  final Workspace ws;
  final GitModel git;
  final String path; // inside the repository
  const MergeView({super.key, required this.ws, required this.git, required this.path});
  @override
  State<MergeView> createState() => MergeViewState();
}

class MergeViewState extends State<MergeView> {
  ConflictFile? _file;
  String? _etag;
  String? _error;
  bool _saving = false;
  bool _changed = false;

  String get _root => widget.git.repo!.root;
  String get _abs {
    final repo = widget.git.repo!.repo;
    return repo == '/' || repo.isEmpty ? '/${widget.path}' : '$repo/${widget.path}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final link = widget.ws.link;
    if (link == null) return setState(() => _error = '未连接');
    try {
      final r = (await link.call('fs.read', {'root': _root, 'path': _abs}) as Map).cast<String, dynamic>();
      if (!mounted) return;
      if (r['binary'] == true || r['truncated'] == true) {
        return setState(() => _error = '这个文件是二进制或超过 512 KB，不能在这里合并。可以在终端里用 git checkout --ours / --theirs 选一边。');
      }
      final f = parseConflicts(r['content'] as String? ?? '');
      setState(() {
        _file = f;
        _etag = r['etag'] as String?;
        _error = null;
        _changed = false;
      });
      _status();
    } on OpError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _status() {
    final f = _file;
    final t = widget.ws.tab('merge:${widget.git.repo!.root}:${widget.git.repo!.repo}:${widget.path}');
    if (t == null || f == null) return;
    t.dirty.value = _changed;
    t.status.value = f.conflicts.isEmpty ? '没有冲突标记' : '还有 ${f.unresolved} / ${f.conflicts.length} 处冲突';
  }

  void _resolve(Conflict c, List<String>? lines) {
    setState(() {
      c.resolution = lines;
      _changed = true;
    });
    _status();
  }

  Future<bool> _save() async {
    final f = _file;
    final link = widget.ws.link;
    if (f == null || link == null || _saving) return false;
    setState(() => _saving = true);
    try {
      final r = (await link.call('fs.write', {'root': _root, 'path': _abs, 'content': f.join(), 'if_match': _etag}) as Map).cast<String, dynamic>();
      _etag = r['etag'] as String? ?? _etag;
      // what is on disk now: resolved blocks are text, the rest still conflicts
      final again = parseConflicts(f.join());
      if (!mounted) return true;
      setState(() {
        _file = again;
        _changed = false;
      });
      _status();
      widget.ws.filesRevision.value++;
      if (again.conflicts.isEmpty) {
        final stage = await confirmDialog(context, title: '冲突都已解决', body: '暂存 ${widget.path}，把它标记为已解决？', ok: '暂存');
        if (stage) await widget.git.stage([widget.path]);
      } else {
        widget.ws.toast('已保存，还有 ${again.conflicts.length} 处冲突');
      }
      return true;
    } on OpError catch (e) {
      widget.ws.toast(e.code == codeConflict ? '文件在别处被修改了，请重新载入后再合并' : e.message, error: true);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> confirmClose() async {
    if (!_changed) return true;
    final r = await showWorkbenchDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${widget.path.split('/').last} 的合并还没有保存'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('取消')),
          OutlinedButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('不保存')),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('保存')),
        ],
      ),
    );
    if (r == 'save') return _save();
    return r == 'discard';
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _load);
    final f = _file;
    if (f == null) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    final mono = TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 12.5, height: 1.4, color: ide.text);
    Widget lines(List<String> l, {Color? bg}) => Container(
          width: double.infinity,
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: SelectableText(l.isEmpty ? '（空）' : l.join('\n'), style: l.isEmpty ? mono.copyWith(color: ide.textDim) : mono),
        );
    final blocks = <Widget>[];
    var n = 0;
    for (final p in f.pieces) {
      if (p.lines != null) {
        // plain text between conflicts: a few lines of context, the rest folded
        final l = p.lines!;
        if (l.length <= 6) {
          blocks.add(lines(l));
        } else {
          blocks.add(lines(l.sublist(0, 3)));
          blocks.add(Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('… ${l.length - 6} 行没有冲突 …', style: TextStyle(color: ide.textDim, fontSize: 11))));
          blocks.add(lines(l.sublist(l.length - 3)));
        }
        continue;
      }
      final c = p.conflict!;
      n++;
      blocks.add(_ConflictBlock(
        index: n,
        conflict: c,
        lines: lines,
        onResolve: (r) => _resolve(c, r),
      ));
    }
    return Column(children: [
      Container(
        height: 34,
        color: ide.tabBar,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Expanded(
            child: Text(
              f.conflicts.isEmpty ? '${widget.path}：没有冲突标记' : '${widget.path}：已决定 ${f.conflicts.length - f.unresolved} / ${f.conflicts.length} 处',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          TextButton(onPressed: () => openFileAt(widget.ws, root: _root, path: _abs), child: const Text('在编辑器中打开')),
          const SizedBox(width: 6),
          FilledButton(onPressed: _changed && !_saving ? _save : null, child: Text(_saving ? '正在保存…' : '保存')),
          if (f.conflicts.isEmpty) ...[
            const SizedBox(width: 6),
            OutlinedButton(onPressed: () => widget.git.stage([widget.path]), child: const Text('暂存（标记为已解决）')),
          ],
        ]),
      ),
      Expanded(child: ListView(padding: const EdgeInsets.only(bottom: 20), children: blocks)),
    ]);
  }
}

class _ConflictBlock extends StatelessWidget {
  final int index;
  final Conflict conflict;
  final Widget Function(List<String> l, {Color? bg}) lines;
  final void Function(List<String>? r) onResolve;
  const _ConflictBlock({required this.index, required this.conflict, required this.lines, required this.onResolve});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final c = conflict;
    final oursBg = ide.ok.withValues(alpha: 0.10), theirsBg = ide.accent.withValues(alpha: 0.12);
    Widget head(String t, Color color) => Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Text(t, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        );
    Widget pick(String label, List<String> r) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: OutlinedButton(onPressed: () => onResolve(r), style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact), child: Text(label, style: const TextStyle(fontSize: 12))),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      decoration: BoxDecoration(border: Border.all(color: c.resolved ? ide.border : ide.warn.withValues(alpha: 0.7)), borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: ide.sideBar,
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          child: Row(children: [
            Icon(c.resolved ? Icons.check_circle_outline : Icons.warning_amber, size: 15, color: c.resolved ? ide.ok : ide.warn),
            const SizedBox(width: 6),
            Text('冲突 $index${c.resolved ? '（已决定）' : ''}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (c.resolved) TextButton(onPressed: () => onResolve(null), child: const Text('撤销决定', style: TextStyle(fontSize: 12))),
          ]),
        ),
        if (c.resolved) ...[
          head('结果', ide.textDim),
          lines(c.resolution!),
        ] else ...[
          head('当前（${c.oursLabel.isEmpty ? 'ours' : c.oursLabel}）', ide.ok),
          lines(c.ours, bg: oursBg),
          if (c.hasBase) ...[head('共同祖先', ide.textDim), lines(c.base)],
          head('传入（${c.theirsLabel.isEmpty ? 'theirs' : c.theirsLabel}）', ide.accent),
          lines(c.theirs, bg: theirsBg),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Wrap(runSpacing: 6, children: [
              pick('采用当前', c.ours),
              pick('采用传入', c.theirs),
              pick('两者都要（当前在前）', [...c.ours, ...c.theirs]),
              pick('两者都要（传入在前）', [...c.theirs, ...c.ours]),
              if (c.hasBase) pick('采用共同祖先', c.base),
            ]),
          ),
        ],
      ]),
    );
  }
}
