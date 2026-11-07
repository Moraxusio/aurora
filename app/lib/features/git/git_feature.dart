// The source control view (service "git"): the repository, its changes
// (staged and not), a commit box, push/pull/fetch, branches and history.
// A click on a changed file opens its diff in an editor tab. Anything that
// loses work (discard) asks first; a pull or push that needs a decision
// (diverged history, rejected push) puts the choice to the user.
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../files/file_editor.dart';
import 'diff_view.dart';
import 'git_model.dart';

class GitFeature extends Feature {
  const GitFeature();

  @override
  String get id => 'git';
  @override
  String get title => '源代码管理';
  @override
  IconData get icon => Icons.fork_right;
  @override
  String get service => 'git';
  @override
  List<String> get ops => const ['git.repos', 'git.status', 'git.stage', 'git.unstage', 'git.commit', 'git.diff', 'git.branches', 'git.checkout', 'git.log', 'git.sync'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(title: '源代码管理', body: GitPanel(ws: ws));

  @override
  List<Command> commands(Workspace ws) => const [];
}

class GitPanel extends StatefulWidget {
  final Workspace ws;
  const GitPanel({super.key, required this.ws});
  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  late final GitModel _git = GitModel(widget.ws);
  final _message = TextEditingController();
  bool _changesOpen = true, _stagedOpen = true, _historyOpen = false, _branchesOpen = false;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _git.addListener(_tick);
    _git.findRepos();
  }

  @override
  void dispose() {
    _git.removeListener(_tick);
    _git.dispose();
    _message.dispose();
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _commit({bool amend = false}) async {
    final st = _git.status;
    if (st == null) return;
    final msg = _message.text.trim();
    if (msg.isEmpty && !amend) return ws.toast('先写提交说明', error: true);
    // Nothing staged: offer to commit all tracked changes, as an IDE does.
    var all = false;
    if (st.stagedFiles.isEmpty && !amend) {
      if (st.changedFiles.isEmpty) return ws.toast('没有可提交的改动', error: true);
      all = await confirmDialog(context, title: '没有暂存的改动', body: '提交所有已修改的文件（不含新文件）？', ok: '全部提交');
      if (!all) return;
    }
    if (await _git.commit(msg, amend: amend, all: all)) {
      _message.clear();
      if (_historyOpen) _git.loadLog();
    }
  }

  Future<void> _sync(String action) async {
    var r = await _git.sync(action);
    if (r.ok) {
      ws.toast(switch (action) { 'fetch' => '已获取', 'pull' => '已拉取', _ => '已推送' });
      return;
    }
    if (!mounted) return;
    switch (r.reason) {
      case 'diverged':
        final how = await _choose('本地和远程各有不同的提交', '拉取需要选择怎样合并两边的历史。', {'merge': '合并（merge）', 'rebase': '变基（rebase）'});
        if (how == null) return;
        r = await _git.sync('pull', mode: how);
        if (r.ok) return ws.toast('已拉取');
      case 'rejected':
        return ws.toast('推送被拒绝：远程有你没有的提交。先拉取，再推送。', error: true);
      case 'dirty':
        return ws.toast('有未提交的改动会被覆盖。先提交或还原这些改动。', error: true);
      case 'conflicts':
        ws.toast('合并出现冲突，请解决冲突后提交', error: true);
        return;
    }
    ws.toast(r.output.trim().isEmpty ? '操作失败' : r.output.trim(), error: true);
  }

  Future<String?> _choose(String title, String body, Map<String, String> options) {
    final ide = Ide.of(context);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text('取消', style: TextStyle(color: ide.textDim))),
          for (final e in options.entries) OutlinedButton(onPressed: () => Navigator.pop(c, e.key), child: Text(e.value)),
        ],
      ),
    );
  }

  void _openDiff(GitFile f, {required bool staged}) {
    ws.openTab(diffTab(ws, _git, path: f.path, staged: staged, untracked: f.untracked));
  }

  void _openFile(GitFile f) {
    ws.openTab(fileEditorTab(ws, root: _git.repo!.root, path: _join(_git.repo!.repo, f.path)));
  }

  static String _join(String a, String b) => a == '/' || a.isEmpty ? '/$b' : '$a/$b';

  Future<void> _discard(List<GitFile> files) async {
    final names = files.length == 1 ? files.first.path : '${files.length} 个文件';
    final untracked = files.where((f) => f.untracked).length;
    final ok = await confirmDialog(context,
        title: '还原 $names？', body: '${untracked > 0 ? '新文件会被删除，' : ''}对文件的修改会丢失，不能恢复。', ok: '还原', danger: true);
    if (ok) await _git.discard([for (final f in files) f.path]);
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_git.loadingRepos && _git.repos.isEmpty) {
      return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_git.repo == null) {
      return EmptyHint(
        icon: Icons.fork_right,
        text: _git.error ?? '在主目录下没有找到 git 仓库。\n在终端里 git clone 一个，或到文件树里对仓库文件夹选“作为仓库打开”。',
        actionLabel: '重新查找',
        onAction: _git.findRepos,
      );
    }
    final st = _git.status;
    return Column(children: [
      _repoBar(ide, st),
      const Divider(),
      if (_git.error != null)
        Padding(padding: const EdgeInsets.all(10), child: Text(_git.error!, style: TextStyle(color: ide.error, fontSize: 12)))
      else if (st == null)
        const Expanded(child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
      else
        Expanded(child: _body(ide, st)),
    ]);
  }

  Widget _repoBar(Ide ide, GitStatus? st) {
    return Container(
      height: 34,
      color: ide.sideBar,
      padding: const EdgeInsets.only(left: 8, right: 2),
      child: Row(children: [
        Expanded(
          child: PopupMenuButton<GitRepo>(
            tooltip: '切换仓库',
            enabled: _git.repos.length > 1,
            onSelected: _git.select,
            itemBuilder: (_) => [for (final r in _git.repos) PopupMenuItem(value: r, height: 30, child: Text('${r.name}  ${r.repo}', style: const TextStyle(fontSize: 13)))],
            child: Row(children: [
              Icon(Icons.folder_special_outlined, size: 15, color: ide.textDim),
              const SizedBox(width: 6),
              Flexible(child: Text(_git.repo!.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (_git.repos.length > 1) Icon(Icons.arrow_drop_down, size: 18, color: ide.textDim),
            ]),
          ),
        ),
        if (st != null) ...[
          IconBtn(Icons.cloud_download_outlined, '获取（fetch）', _git.busy ? null : () => _sync('fetch')),
          IconBtn(Icons.arrow_downward, st.behind > 0 ? '拉取（落后 ${st.behind}）' : '拉取（pull）', _git.busy ? null : () => _sync('pull'), color: st.behind > 0 ? ide.accent : null),
          IconBtn(Icons.arrow_upward, st.ahead > 0 ? '推送（领先 ${st.ahead}）' : '推送（push）', _git.busy ? null : () => _sync('push'), color: st.ahead > 0 ? ide.accent : null),
        ],
        IconBtn(Icons.refresh, '刷新', () {
          _git.refresh();
          if (_historyOpen) _git.loadLog();
          if (_branchesOpen) _git.loadBranches();
        }),
      ]),
    );
  }

  Widget _body(Ide ide, GitStatus st) {
    final conflicts = st.conflicts, staged = st.stagedFiles, changed = st.changedFiles;
    return ListView(children: [
      _branchLine(ide, st),
      if (st.operation.isNotEmpty) _operationBanner(ide, st),
      _commitBox(ide, st),
      if (conflicts.isNotEmpty) ...[
        SectionHeader('冲突  ${conflicts.length}', expanded: true),
        for (final f in conflicts) _fileRow(f, staged: false, conflict: true),
      ],
      SectionHeader('暂存的更改  ${staged.length}', expanded: _stagedOpen, onTap: () => setState(() => _stagedOpen = !_stagedOpen), actions: [
        if (staged.isNotEmpty) IconBtn(Icons.remove, '全部取消暂存', _git.unstageAll),
      ]),
      if (_stagedOpen) ...[for (final f in staged) _fileRow(f, staged: true)],
      SectionHeader('更改  ${changed.length}', expanded: _changesOpen, onTap: () => setState(() => _changesOpen = !_changesOpen), actions: [
        if (changed.isNotEmpty) IconBtn(Icons.undo, '全部还原', () => _discard(changed), color: ide.error),
        if (changed.isNotEmpty) IconBtn(Icons.add, '全部暂存', _git.stageAll),
      ]),
      if (_changesOpen) ...[
        for (final f in changed) _fileRow(f, staged: false),
        if (changed.isEmpty && staged.isEmpty && conflicts.isEmpty)
          Padding(padding: const EdgeInsets.all(14), child: Text('没有改动', style: TextStyle(color: ide.textDim))),
      ],
      if (st.truncated) Padding(padding: const EdgeInsets.all(10), child: Text('改动太多，只显示前 5000 个', style: TextStyle(color: ide.warn, fontSize: 12))),
      SectionHeader('分支', expanded: _branchesOpen, onTap: () {
        setState(() => _branchesOpen = !_branchesOpen);
        if (_branchesOpen) _git.loadBranches();
      }, actions: [
        IconBtn(Icons.add, '新建分支', _newBranch),
      ]),
      if (_branchesOpen) ..._branchRows(ide),
      SectionHeader('历史', expanded: _historyOpen, onTap: () {
        setState(() => _historyOpen = !_historyOpen);
        if (_historyOpen) _git.loadLog();
      }),
      if (_historyOpen) ..._historyRows(ide),
    ]);
  }

  Widget _branchLine(Ide ide, GitStatus st) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 4),
      child: Row(children: [
        Icon(Icons.fork_right, size: 14, color: ide.accent),
        const SizedBox(width: 6),
        Flexible(child: Text(st.detached ? '分离的 HEAD ${st.oid.length >= 7 ? st.oid.substring(0, 7) : st.oid}' : st.branch, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (st.upstream.isNotEmpty) ...[
          const SizedBox(width: 8),
          Text('${st.ahead > 0 ? '↑${st.ahead} ' : ''}${st.behind > 0 ? '↓${st.behind}' : ''}${st.ahead == 0 && st.behind == 0 ? '已同步' : ''}', style: TextStyle(color: ide.textDim, fontSize: 11)),
        ] else if (!st.detached)
          Text('  无上游', style: TextStyle(color: ide.textDim, fontSize: 11)),
        if (st.stashes > 0) Text('   暂存区 ${st.stashes}', style: TextStyle(color: ide.textDim, fontSize: 11)),
      ]),
    );
  }

  Widget _operationBanner(Ide ide, GitStatus st) {
    final name = switch (st.operation) { 'merge' => '合并', 'rebase' => '变基', 'cherry-pick' => '挑选提交', 'revert' => '撤销提交', _ => st.operation };
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: ide.warn.withValues(alpha: 0.12), border: Border.all(color: ide.warn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(4)),
      child: Row(children: [
        Icon(Icons.warning_amber, size: 16, color: ide.warn),
        const SizedBox(width: 8),
        Expanded(child: Text('$name 进行中${st.conflicts.isNotEmpty ? '，还有 ${st.conflicts.length} 个冲突' : ''}', style: const TextStyle(fontSize: 12))),
        TextButton(
          onPressed: () async {
            if (await confirmDialog(context, title: '放弃$name？', body: '回到$name之前的状态。', ok: '放弃', danger: true)) {
              await _git.act('git.op', {'action': 'abort'});
            }
          },
          child: const Text('放弃'),
        ),
        if (st.conflicts.isEmpty) TextButton(onPressed: () => _git.act('git.op', {'action': 'continue'}), child: const Text('继续')),
      ]),
    );
  }

  Widget _commitBox(Ide ide, GitStatus st) {
    final canCommit = !_git.busy && (st.stagedFiles.isNotEmpty || st.changedFiles.isNotEmpty);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _message,
          minLines: 2,
          maxLines: 5,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(hintText: st.detached ? '提交说明' : '提交说明（提交到 ${st.branch}）'),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: canCommit ? _commit : null,
              icon: const Icon(Icons.check, size: 16),
              label: Text(st.stagedFiles.isEmpty ? '提交全部更改' : '提交 ${st.stagedFiles.length} 个文件'),
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: Icon(Icons.more_vert, size: 18, color: ide.textDim),
            onSelected: (v) {
              if (v == 'amend') _commit(amend: true);
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'amend', height: 32, child: Text('修改上一次提交（amend）'))],
          ),
        ]),
      ]),
    );
  }

  Widget _fileRow(GitFile f, {required bool staged, bool conflict = false}) {
    final ide = Ide.of(context);
    final letter = conflict ? '!' : f.letter(staged);
    final color = switch (letter) {
      'A' || 'U' => ide.ok,
      'D' => ide.error,
      '!' => ide.error,
      'R' || 'C' => ide.accent,
      _ => ide.warn,
    };
    final name = f.path.split('/').last;
    final dir = f.path.contains('/') ? f.path.substring(0, f.path.lastIndexOf('/')) : null;
    return TreeRow(
      depth: 1,
      label: name,
      detail: dir,
      labelColor: letter == 'D' ? ide.textDim : null,
      onTap: conflict ? () => _openFile(f) : () => _openDiff(f, staged: staged),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!conflict) ...[
          if (staged)
            IconBtn(Icons.remove, '取消暂存', () => _git.unstage([f.path]))
          else ...[
            IconBtn(Icons.undo, '还原', () => _discard([f]), color: ide.error),
            IconBtn(Icons.add, '暂存', () => _git.stage([f.path])),
          ],
        ] else
          IconBtn(Icons.add, '标记为已解决（暂存）', () => _git.stage([f.path])),
        SizedBox(width: 16, child: Text(letter, textAlign: TextAlign.center, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12))),
      ]),
      menu: () => [
        if (!conflict) MenuItem('查看差异', () => _openDiff(f, staged: staged), icon: Icons.difference_outlined),
        if (f.letter(staged) != 'D') MenuItem('打开文件', () => _openFile(f), icon: Icons.edit_note),
        const MenuItem.separator(),
        if (staged) MenuItem('取消暂存', () => _git.unstage([f.path]), icon: Icons.remove) else MenuItem('暂存', () => _git.stage([f.path]), icon: Icons.add),
        if (!staged && !conflict) MenuItem('还原…', () => _discard([f]), icon: Icons.undo, danger: true),
        const MenuItem.separator(),
        MenuItem('复制路径', () => copyText(f.path, what: '已复制路径'), icon: Icons.copy),
      ],
    );
  }

  Future<void> _newBranch() async {
    final name = await askText(context, title: '新建分支', hint: '分支名', ok: '创建并切换');
    if (name == null || name.isEmpty) return;
    if (await _git.checkout(name, create: true)) ws.toast('已切换到新分支 $name');
  }

  List<Widget> _branchRows(Ide ide) {
    if (_git.branches.isEmpty) return [Padding(padding: const EdgeInsets.all(12), child: Text('没有分支', style: TextStyle(color: ide.textDim)))];
    final local = _git.branches.where((b) => !b.remote).toList(), remote = _git.branches.where((b) => b.remote && !b.name.endsWith('/HEAD')).toList();
    Widget row(GitBranch b) => TreeRow(
          depth: 1,
          selected: b.current,
          leading: Icon(b.current ? Icons.check : Icons.fork_right, size: 14, color: b.current ? ide.accent : ide.textDim),
          label: b.name,
          detail: b.subject,
          trailing: b.ahead + b.behind > 0 ? Text('${b.ahead > 0 ? '↑${b.ahead}' : ''}${b.behind > 0 ? '↓${b.behind}' : ''}', style: TextStyle(color: ide.textDim, fontSize: 11)) : null,
          onDoubleTap: b.current ? null : () => _switchTo(b),
          onTap: b.current ? null : () => _switchTo(b),
          menu: () => [
            if (!b.current) MenuItem('切换到这个分支', () => _switchTo(b), icon: Icons.swap_horiz),
            MenuItem('复制分支名', () => copyText(b.name), icon: Icons.copy),
          ],
        );
    return [for (final b in local) row(b), if (remote.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(10, 6, 0, 2), child: Text('远程', style: TextStyle(color: ide.textDim, fontSize: 11))), for (final b in remote) row(b)];
  }

  Future<void> _switchTo(GitBranch b) async {
    final st = _git.status;
    if (st != null && (st.stagedFiles.isNotEmpty || st.changedFiles.isNotEmpty)) {
      final ok = await confirmDialog(context, title: '有未提交的改动', body: '切换分支时，没有冲突的改动会带过去；有冲突 git 会拒绝切换。继续？', ok: '切换');
      if (!ok) return;
    }
    // a remote branch becomes a local one that tracks it
    final remote = b.remote;
    final local = remote ? b.name.substring(b.name.indexOf('/') + 1) : b.name;
    final exists = _git.branches.any((x) => !x.remote && x.name == local);
    if (await _git.checkout(local, create: remote && !exists, from: remote && !exists ? b.name : null)) ws.toast('已切换到 $local');
  }

  List<Widget> _historyRows(Ide ide) {
    if (_git.log.isEmpty) return [Padding(padding: const EdgeInsets.all(12), child: Text('没有提交', style: TextStyle(color: ide.textDim)))];
    return [
      for (final c in _git.log)
        TreeRow(
          depth: 1,
          leading: Icon(Icons.commit, size: 14, color: ide.textDim),
          label: c.subject,
          detail: '${c.short}  ${c.author}  ${relativeTime(c.time)}',
          onTap: () => _openCommit(c),
          menu: () => [
            MenuItem('查看这次提交改了什么', () => _openCommit(c), icon: Icons.difference_outlined),
            MenuItem('复制提交号', () => copyText(c.hash, what: '已复制提交号'), icon: Icons.copy),
          ],
        ),
    ];
  }

  void _openCommit(GitCommit c) {
    ws.openTab(EditorTab(
      id: 'commit:${_git.repo!.root}:${_git.repo!.repo}:${c.hash}',
      title: '${c.short} ${c.subject}',
      icon: Icons.commit,
      tooltip: '${c.hash}\n${c.author}',
      builder: (_) => CommitView(ws: ws, git: _git, commit: c),
    ));
  }
}

/// The files one commit changed; a click shows the file's diff for that commit.
class CommitView extends StatefulWidget {
  final Workspace ws;
  final GitModel git;
  final GitCommit commit;
  const CommitView({super.key, required this.ws, required this.git, required this.commit});
  @override
  State<CommitView> createState() => _CommitViewState();
}

class _CommitViewState extends State<CommitView> {
  String _message = '';
  List<GitFile>? _files;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final link = widget.ws.link;
    final repo = widget.git.repo;
    if (link == null || repo == null) return setState(() => _error = '未连接');
    try {
      final r = (await link.call('git.commitFiles', {'root': repo.root, 'repo': repo.repo, 'rev': widget.commit.hash}) as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _message = (r['message'] as String?) ?? widget.commit.subject;
        _files = [for (final f in (r['files'] as List? ?? const [])) GitFile((f as Map)['path'] as String, f['orig'] as String?, f['x'] as String? ?? 'M', '.')];
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline, text: _error!);
    if (_files == null) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    final c = widget.commit;
    return ListView(padding: const EdgeInsets.all(14), children: [
      SelectableText(_message, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      SelectableText('${c.hash}\n${c.author} · ${formatTime(c.time * 1000)}', style: TextStyle(color: ide.textDim, fontSize: 12)),
      const SizedBox(height: 14),
      Text('改动的文件  ${_files!.length}', style: TextStyle(color: ide.textDim, fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      for (final f in _files!)
        TreeRow(
          label: f.path,
          detail: f.orig == null ? null : '← ${f.orig}',
          trailing: Text(f.x, style: TextStyle(color: switch (f.x) { 'A' => ide.ok, 'D' => ide.error, _ => ide.warn }, fontWeight: FontWeight.w700, fontSize: 12)),
          onTap: () => widget.ws.openTab(diffTab(widget.ws, widget.git, path: f.path, staged: false, commit: c.hash)),
        ),
    ]);
  }
}
