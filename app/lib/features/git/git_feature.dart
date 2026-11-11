// The source control view (service "git"): the repository, its changes
// (staged and not), a commit box, push/pull/fetch, branches and history.
// A click on a changed file opens its diff in an editor tab. Anything that
// loses work (discard) asks first; a pull or push that needs a decision
// (diverged history, rejected push) puts the choice to the user.
import 'package:aurora_profile/aurora_profile.dart' show WorkspacePath;
import 'package:aurora_wire/aurora_wire.dart' show OpError, codeConflict;
import 'package:flutter/material.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../files/file_editor.dart';
import 'blame_view.dart';
import 'diff_view.dart';
import 'git_model.dart';
import 'merge_view.dart';

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
  // The core; the rest (stash, tags, blame, merge…) is offered only when the
  // agent reports it (ws.hasOp), so an older agent keeps the basic view.
  List<String> get ops => const ['git.repos', 'git.status', 'git.stage', 'git.unstage', 'git.commit', 'git.diff', 'git.branches', 'git.checkout', 'git.log', 'git.sync'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(title: '源代码管理', body: GitPanel(ws: ws));

  @override
  List<Command> commands(Workspace ws) => [
        if (ws.hasOp('git.blame'))
          Command(
            id: 'git.blameActive',
            title: '逐行追溯当前文件（blame）',
            group: 'Git',
            icon: Icons.person_search_outlined,
            enabled: () => ws.active?.file != null,
            run: () => blameActiveFile(ws),
          ),
      ];
}

/// Opens blame for the file in front. Its repository is the one git.repos
/// reports for the file's folder whose path is the longest prefix of the file.
Future<void> blameActiveFile(Workspace ws) async {
  final f = ws.active?.file;
  final link = ws.link;
  if (f == null || link == null) return;
  final i = f.path.lastIndexOf('/');
  final dir = i <= 0 ? '/' : f.path.substring(0, i);
  try {
    final r = (await link.call('git.repos', {'root': f.root, 'path': dir}) as Map).cast<String, dynamic>();
    String? best;
    for (final x in (r['repos'] as List? ?? const [])) {
      final repo = WorkspacePath.normalize((x as Map)['repo'] as String? ?? '');
      final inside = repo == '/' || f.path.startsWith('$repo/');
      if (inside && (best == null || repo.length > best.length)) best = repo;
    }
    if (best == null) return ws.toast('这个文件不在 git 仓库里', error: true);
    final model = GitModel(ws)..repo = GitRepo(f.root, best, best.split('/').last);
    final rel = best == '/' ? f.path.substring(1) : f.path.substring(best.length + 1);
    ws.openTab(blameTab(ws, model, rel));
  } on OpError catch (e) {
    ws.toast(e.message, error: true);
  }
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
  bool _stashOpen = false, _tagsOpen = false, _remotesOpen = false;

  bool _has(String op) => ws.hasOp(op);

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

  void _openMerge(GitFile f) => ws.openTab(mergeTab(ws, _git, f.path));

  void _openBlame(String path) => ws.openTab(blameTab(ws, _git, path));

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
      if (_has('git.stash')) ...[
        SectionHeader('储藏  ${st.stashes}', expanded: _stashOpen, onTap: () {
          setState(() => _stashOpen = !_stashOpen);
          if (_stashOpen) _git.loadStashes();
        }, actions: [
          IconBtn(Icons.archive_outlined, '储藏改动（stash）', _git.busy ? null : _stashPush),
        ]),
        if (_stashOpen) ..._stashRows(ide),
      ],
      if (_has('git.tag')) ...[
        SectionHeader('标签', expanded: _tagsOpen, onTap: () {
          setState(() => _tagsOpen = !_tagsOpen);
          if (_tagsOpen) _git.loadTags();
        }, actions: [
          IconBtn(Icons.add, '在 HEAD 上打标签', () => _newTag(null)),
        ]),
        if (_tagsOpen) ..._tagRows(ide),
      ],
      if (_has('git.remote')) ...[
        SectionHeader('远程仓库  ${st.remotes.length}', expanded: _remotesOpen, onTap: () => setState(() => _remotesOpen = !_remotesOpen), actions: [
          IconBtn(Icons.add, '添加远程仓库', _addRemote),
        ]),
        if (_remotesOpen) ..._remoteRows(ide, st),
      ],
    ]);
  }

  // ---- stash ----

  Future<void> _stashPush() async {
    final st = _git.status;
    if (st == null) return;
    if (st.stagedFiles.isEmpty && st.changedFiles.isEmpty) return ws.toast('没有可以储藏的改动', error: true);
    final msg = TextEditingController();
    var untracked = st.changedFiles.any((f) => f.untracked);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('储藏改动'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: msg, autofocus: true, decoration: const InputDecoration(hintText: '说明（可选）')),
            CheckboxListTile(
              value: untracked,
              contentPadding: EdgeInsets.zero,
              title: const Text('包括新文件（未跟踪）', style: TextStyle(fontSize: 13)),
              onChanged: (v) => set(() => untracked = v ?? false),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('储藏')),
          ],
        ),
      ),
    );
    final text = msg.text;
    msg.dispose();
    if (ok != true) return;
    final r = await _git.stash('push', message: text, untracked: untracked);
    if (r.ok) {
      ws.toast('已储藏，工作区已恢复干净');
      setState(() => _stashOpen = true);
    }
  }

  Future<void> _stashApply(GitStash s, {required bool pop}) async {
    final r = await _git.stash(pop ? 'pop' : 'apply', index: s.index);
    if (!r.ok) return;
    if (r.conflicts) {
      ws.toast('恢复储藏时出现冲突，请在“冲突”里解决；储藏没有删除', error: true);
    } else {
      ws.toast(pop ? '已恢复并删除储藏' : '已恢复储藏（储藏仍保留）');
    }
  }

  List<Widget> _stashRows(Ide ide) {
    if (_git.stashes.isEmpty) return [Padding(padding: const EdgeInsets.all(12), child: Text('没有储藏', style: TextStyle(color: ide.textDim)))];
    return [
      for (final s in _git.stashes)
        TreeRow(
          depth: 1,
          leading: Icon(Icons.inventory_2_outlined, size: 14, color: ide.textDim),
          label: s.message,
          detail: '${s.ref}  ${relativeTime(s.time)}',
          onTap: () => _stashApply(s, pop: false),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconBtn(Icons.unarchive_outlined, '恢复并删除（pop）', _git.busy ? null : () => _stashApply(s, pop: true)),
          ]),
          menu: () => [
            MenuItem('恢复（保留储藏）', () => _stashApply(s, pop: false), icon: Icons.restore),
            MenuItem('恢复并删除', () => _stashApply(s, pop: true), icon: Icons.unarchive_outlined),
            const MenuItem.separator(),
            MenuItem('删除…', () async {
              if (await confirmDialog(context, title: '删除 ${s.ref}？', body: '“${s.message}”里的改动会丢失，不能恢复。', ok: '删除', danger: true)) {
                final r = await _git.stash('drop', index: s.index);
                if (r.ok) ws.toast('已删除 ${s.ref}');
              }
            }, icon: Icons.delete_outline, danger: true),
          ],
        ),
    ];
  }

  // ---- tags ----

  Future<void> _newTag(GitCommit? at) async {
    final name = TextEditingController(), msg = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(at == null ? '在 HEAD 上打标签' : '在 ${at.short} 上打标签'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(hintText: '标签名，如 v1.2.0')),
          const SizedBox(height: 8),
          TextField(controller: msg, decoration: const InputDecoration(hintText: '说明（可选；填写后为附注标签）')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('创建')),
        ],
      ),
    );
    final n = name.text.trim(), m = msg.text.trim();
    name.dispose();
    msg.dispose();
    if (ok != true || n.isEmpty) return;
    if (await _git.createTag(n, rev: at?.hash, message: m.isEmpty ? null : m)) {
      ws.toast('已创建标签 $n。推送标签：在终端里 git push origin $n');
      setState(() => _tagsOpen = true);
    }
  }

  List<Widget> _tagRows(Ide ide) {
    if (_git.tags.isEmpty) return [Padding(padding: const EdgeInsets.all(12), child: Text('没有标签', style: TextStyle(color: ide.textDim)))];
    return [
      for (final t in _git.tags)
        TreeRow(
          depth: 1,
          leading: Icon(Icons.sell_outlined, size: 14, color: ide.textDim),
          label: t.name,
          detail: '${t.hash}  ${t.subject}',
          menu: () => [
            MenuItem('复制标签名', () => copyText(t.name), icon: Icons.copy),
            MenuItem('切换到这个标签（分离 HEAD）', () => _checkoutRev(t.name), icon: Icons.swap_horiz),
            const MenuItem.separator(),
            MenuItem('删除本地标签…', () async {
              if (await confirmDialog(context, title: '删除标签 ${t.name}？', body: '只删除本地的标签，远程的不受影响。', ok: '删除', danger: true)) {
                if (await _git.deleteTag(t.name)) ws.toast('已删除标签 ${t.name}');
              }
            }, icon: Icons.delete_outline, danger: true),
          ],
        ),
    ];
  }

  Future<void> _checkoutRev(String rev) async {
    if (await _git.checkout(rev)) ws.toast('已切换到 $rev（分离的 HEAD）');
  }

  // ---- remotes ----

  Future<void> _addRemote() async {
    final name = TextEditingController(text: (_git.status?.remotes.isEmpty ?? true) ? 'origin' : ''), url = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('添加远程仓库'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(hintText: '名称，如 origin')),
          const SizedBox(height: 8),
          TextField(controller: url, autofocus: true, decoration: const InputDecoration(hintText: '地址，如 git@github.com:user/repo.git')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('添加')),
        ],
      ),
    );
    final n = name.text.trim(), u = url.text.trim();
    name.dispose();
    url.dispose();
    if (ok != true || n.isEmpty || u.isEmpty) return;
    if (await _git.addRemote(n, u)) ws.toast('已添加远程仓库 $n');
  }

  List<Widget> _remoteRows(Ide ide, GitStatus st) {
    if (st.remotes.isEmpty) return [Padding(padding: const EdgeInsets.all(12), child: Text('没有远程仓库', style: TextStyle(color: ide.textDim)))];
    return [
      for (final r in st.remotes)
        TreeRow(
          depth: 1,
          leading: Icon(Icons.cloud_outlined, size: 14, color: ide.textDim),
          label: r,
          menu: () => [
            MenuItem('删除…', () async {
              if (await confirmDialog(context, title: '删除远程仓库 $r？', body: '只删除本地的配置和远程分支的记录，远程仓库本身不受影响。', ok: '删除', danger: true)) {
                if (await _git.removeRemote(r)) ws.toast('已删除远程仓库 $r');
              }
            }, icon: Icons.delete_outline, danger: true),
          ],
        ),
    ];
  }

  // ---- merge, rebase, cherry-pick, revert, reset ----

  /// Runs a git.op and tells the user what happened; conflicts open the list.
  Future<void> _runOp(String action, String rev, {String? mode, required String done}) async {
    final r = await _git.op(action, rev: rev, mode: mode);
    if (!r.ok) return;
    if (r.conflicts) {
      ws.toast('出现冲突：在“冲突”里逐个解决，然后点“继续”；或点“放弃”回到之前的状态', error: true);
    } else {
      ws.toast(done);
    }
  }

  Future<void> _merge(GitBranch b) async {
    final cur = _git.status?.branch ?? '';
    final how = await _choose('把 ${b.name} 合并到 $cur', '选择合并方式。', {
      '': '合并（需要时建合并提交）',
      'no-ff': '总是建合并提交',
      'ff-only': '只快进',
      'squash': '压缩成一次改动（不提交）',
    });
    if (how == null) return;
    await _runOp('merge', b.name, mode: how.isEmpty ? null : how, done: how == 'squash' ? '已压缩合并，改动已暂存，写说明后提交' : '已合并 ${b.name}');
  }

  Future<void> _rebase(GitBranch b) async {
    final cur = _git.status?.branch ?? '';
    if (!await confirmDialog(context, title: '把 $cur 变基到 ${b.name}？', body: '$cur 上独有的提交会在 ${b.name} 之后重新应用，提交号会改变。已推送的分支变基后需要强制推送。', ok: '变基')) return;
    await _runOp('rebase', b.name, done: '已变基到 ${b.name}');
  }

  Future<void> _renameBranch(GitBranch b) async {
    final to = await askText(context, title: '重命名分支 ${b.name}', initial: b.name, ok: '重命名');
    if (to == null || to.trim().isEmpty || to.trim() == b.name) return;
    if (await _git.branch('rename', b.name, to: to.trim())) ws.toast('已重命名为 ${to.trim()}');
  }

  Future<void> _deleteBranch(GitBranch b) async {
    if (!await confirmDialog(context, title: '删除分支 ${b.name}？', body: '只删除本地分支。', ok: '删除', danger: true)) return;
    final l = ws.link;
    if (l == null || _git.repo == null) return;
    try {
      await l.call('git.branch', {'root': _git.repo!.root, 'repo': _git.repo!.repo, 'action': 'delete', 'branch': b.name});
      ws.toast('已删除分支 ${b.name}');
    } on OpError catch (e) {
      if (!mounted) return;
      // not merged: say what is lost and ask again
      if (e.code == codeConflict && await confirmDialog(context, title: '分支没有合并', body: '${e.message}\n\n仍然删除？', ok: '强制删除', danger: true)) {
        if (await _git.branch('delete', b.name, force: true)) ws.toast('已删除分支 ${b.name}');
      } else if (e.code != codeConflict) {
        ws.toast(e.message, error: true);
      }
    }
    await _git.loadBranches();
  }

  Future<void> _setUpstream(GitBranch b) async {
    final remotes = _git.branches.where((x) => x.remote).map((x) => x.name).toList();
    if (remotes.isEmpty) return ws.toast('没有远程分支，先获取（fetch）', error: true);
    final to = await _choose('设置 ${b.name} 的上游', '拉取和推送默认使用上游分支。', {for (final r in remotes.take(12)) r: r});
    if (to == null) return;
    if (await _git.branch('upstream', b.name, to: to)) ws.toast('${b.name} 的上游已设为 $to');
  }

  Future<void> _branchAt(GitCommit c) async {
    final name = await askText(context, title: '从 ${c.short} 新建分支', hint: '分支名', ok: '创建并切换');
    if (name == null || name.trim().isEmpty) return;
    if (await _git.checkout(name.trim(), create: true, from: c.hash)) ws.toast('已切换到新分支 ${name.trim()}');
  }

  Future<void> _reset(GitCommit c) async {
    final how = await _choose('把当前分支重置到 ${c.short}', '之后的提交会从分支上去掉（仍可通过 reflog 找回）。', {
      'soft': '软重置：改动保留并暂存',
      'mixed': '混合重置：改动保留，不暂存',
      'hard': '硬重置：丢弃所有改动',
    });
    if (how == null || !mounted) return;
    if (how == 'hard' && !await confirmDialog(context, title: '丢弃所有未提交的改动？', body: '硬重置会丢弃工作区和暂存区的全部改动，不能恢复。', ok: '硬重置', danger: true)) return;
    await _runOp('reset', c.hash, mode: how, done: '已重置到 ${c.short}');
  }

  Widget _branchLine(Ide ide, GitStatus st) {
    Widget pill(Widget child, {String? tip}) {
      final w = Container(
        margin: const EdgeInsets.only(left: 5),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: ide.hover, borderRadius: BorderRadius.circular(Radii.s)),
        child: DefaultTextStyle.merge(style: TextStyle(color: ide.textDim, fontSize: 11, fontWeight: FontWeight.w500), child: child),
      );
      return tip == null ? w : Tooltip(message: tip, child: w);
    }

    Widget count(IconData i, int n) => Row(mainAxisSize: MainAxisSize.min, children: [Icon(i, size: 11, color: ide.accent), const SizedBox(width: 2), Text('$n')]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l + 2, Space.s, Space.m, Space.xs),
      child: Row(children: [
        Icon(Icons.fork_right_rounded, size: 15, color: ide.accent),
        const SizedBox(width: 6),
        Flexible(child: Text(st.detached ? '分离的 HEAD ${st.oid.length >= 7 ? st.oid.substring(0, 7) : st.oid}' : st.branch, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: ide.text))),
        if (st.upstream.isNotEmpty) ...[
          if (st.ahead > 0) pill(count(Icons.arrow_upward_rounded, st.ahead), tip: '领先 ${st.upstream} ${st.ahead} 个提交'),
          if (st.behind > 0) pill(count(Icons.arrow_downward_rounded, st.behind), tip: '落后 ${st.upstream} ${st.behind} 个提交'),
          if (st.ahead == 0 && st.behind == 0) pill(const Text('已同步'), tip: '与 ${st.upstream} 一致'),
        ] else if (!st.detached)
          pill(const Text('无上游')),
        if (st.stashes > 0) pill(Text('储藏 ${st.stashes}'), tip: '${st.stashes} 个储藏（stash）'),
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
              await _runOp('abort', '', done: '已放弃$name');
            }
          },
          child: const Text('放弃'),
        ),
        if (st.operation != 'merge')
          TextButton(
            onPressed: () async {
              if (await confirmDialog(context, title: '跳过当前提交？', body: '这一个提交的改动不会被应用。', ok: '跳过')) {
                await _runOp('skip', '', done: '已跳过');
              }
            },
            child: const Text('跳过'),
          ),
        if (st.conflicts.isEmpty) TextButton(onPressed: () => _runOp('continue', '', done: '$name 已完成'), child: const Text('继续')),
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
      onTap: conflict ? () => _openMerge(f) : () => _openDiff(f, staged: staged),
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
        if (conflict) MenuItem('合并冲突…', () => _openMerge(f), icon: Icons.merge_type),
        if (!conflict) MenuItem('查看差异', () => _openDiff(f, staged: staged), icon: Icons.difference_outlined),
        if (f.letter(staged) != 'D') MenuItem('打开文件', () => _openFile(f), icon: Icons.edit_note),
        if (!f.untracked && _has('git.blame') && f.letter(staged) != 'D') MenuItem('逐行追溯（blame）', () => _openBlame(f.path), icon: Icons.person_search_outlined),
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
          trailing: b.ahead + b.behind > 0
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  if (b.ahead > 0) ...[Icon(Icons.arrow_upward_rounded, size: 11, color: ide.textDim), Text('${b.ahead} ', style: TextStyle(color: ide.textDim, fontSize: 11))],
                  if (b.behind > 0) ...[Icon(Icons.arrow_downward_rounded, size: 11, color: ide.textDim), Text('${b.behind}', style: TextStyle(color: ide.textDim, fontSize: 11))],
                ])
              : null,
          onDoubleTap: b.current ? null : () => _switchTo(b),
          onTap: b.current ? null : () => _switchTo(b),
          menu: () => [
            if (!b.current) MenuItem('切换到这个分支', () => _switchTo(b), icon: Icons.swap_horiz),
            if (!b.current && _has('git.op') && !(_git.status?.detached ?? true)) ...[
              MenuItem('合并到当前分支…', () => _merge(b), icon: Icons.merge_type),
              MenuItem('把当前分支变基到这里…', () => _rebase(b), icon: Icons.low_priority),
            ],
            if (!b.remote && _has('git.branch')) ...[
              const MenuItem.separator(),
              MenuItem('重命名…', () => _renameBranch(b), icon: Icons.drive_file_rename_outline),
              MenuItem('设置上游…', () => _setUpstream(b), icon: Icons.cloud_sync_outlined),
              if (!b.current) MenuItem('删除…', () => _deleteBranch(b), icon: Icons.delete_outline, danger: true),
            ],
            const MenuItem.separator(),
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
            const MenuItem.separator(),
            MenuItem('从这里新建分支…', () => _branchAt(c), icon: Icons.fork_right),
            if (_has('git.tag')) MenuItem('在这里打标签…', () => _newTag(c), icon: Icons.sell_outlined),
            if (_has('git.op')) ...[
              const MenuItem.separator(),
              MenuItem('拣选到当前分支（cherry-pick）', () async {
                if (await confirmDialog(context, title: '拣选 ${c.short}？', body: '把“${c.subject}”的改动作为新提交应用到当前分支。', ok: '拣选')) {
                  await _runOp('cherry-pick', c.hash, done: '已拣选 ${c.short}');
                }
              }, icon: Icons.call_split),
              MenuItem('撤销这次提交（revert）', () async {
                if (await confirmDialog(context, title: '撤销 ${c.short}？', body: '新建一次提交，反向应用“${c.subject}”的改动。原提交保留在历史里。', ok: '撤销')) {
                  await _runOp('revert', c.hash, done: '已撤销 ${c.short}');
                }
              }, icon: Icons.undo),
              MenuItem('把当前分支重置到这里…', () => _reset(c), icon: Icons.restart_alt, danger: true),
            ],
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
