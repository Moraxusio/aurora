// The git service's data, as the client keeps it (agent/internal/git): the
// repositories under a root, one repository's status, its branches and log.
// All reads and writes go through the link; nothing here touches the disk.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import '../../kernel/workspace.dart';

class GitRepo {
  final String root;
  final String repo; // path inside the root
  final String name;
  GitRepo(this.root, this.repo, this.name);
}

class GitFile {
  final String path;
  final String? orig;

  /// Index and work-tree state, git's letters: M A D R C U ? and "." for none.
  final String x, y;
  GitFile(this.path, this.orig, this.x, this.y);

  bool get untracked => x == '?';
  bool get conflicted => x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D');
  bool get staged => !untracked && !conflicted && x != '.' && x != ' ';
  bool get unstaged => untracked || (!conflicted && y != '.' && y != ' ');

  /// The letter shown for the staged or unstaged side.
  String letter(bool stagedSide) => untracked ? 'U' : (stagedSide ? x : y);
}

class GitStatus {
  final String branch;
  final String oid;
  final String upstream;
  final int ahead, behind;
  final List<GitFile> files;
  final String operation; // merge | rebase | cherry-pick | revert | ""
  final int stashes;
  final List<String> remotes;
  final bool truncated;
  GitStatus.fromJson(Map<String, dynamic> j)
      : branch = j['branch'] as String? ?? '',
        oid = j['oid'] as String? ?? '',
        upstream = j['upstream'] as String? ?? '',
        ahead = (j['ahead'] as num?)?.toInt() ?? 0,
        behind = (j['behind'] as num?)?.toInt() ?? 0,
        operation = j['operation'] as String? ?? '',
        stashes = (j['stashes'] as num?)?.toInt() ?? 0,
        truncated = j['truncated'] == true,
        remotes = [for (final r in (j['remotes'] as List? ?? const [])) '$r'],
        files = [
          for (final f in (j['files'] as List? ?? const []))
            GitFile((f as Map)['path'] as String, f['orig'] as String?, f['x'] as String? ?? '.', f['y'] as String? ?? '.')
        ];

  bool get detached => branch.startsWith('(');
  List<GitFile> get conflicts => files.where((f) => f.conflicted).toList();
  List<GitFile> get stagedFiles => files.where((f) => f.staged).toList();
  List<GitFile> get changedFiles => files.where((f) => f.unstaged && !f.conflicted).toList();
}

class GitBranch {
  final String name;
  final bool remote, current;
  final String hash, upstream, subject;
  final int ahead, behind;
  GitBranch.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String? ?? '',
        remote = j['remote'] == true,
        current = j['current'] == true,
        hash = j['hash'] as String? ?? '',
        upstream = j['upstream'] as String? ?? '',
        subject = j['subject'] as String? ?? '',
        ahead = (j['ahead'] as num?)?.toInt() ?? 0,
        behind = (j['behind'] as num?)?.toInt() ?? 0;
}

class GitCommit {
  final String hash, short, author, refs, subject;
  final int time;
  GitCommit.fromJson(Map<String, dynamic> j)
      : hash = j['hash'] as String? ?? '',
        short = j['short'] as String? ?? '',
        author = j['author'] as String? ?? '',
        refs = j['refs'] as String? ?? '',
        subject = j['subject'] as String? ?? '',
        time = (j['time'] as num?)?.toInt() ?? 0;
}

/// One repository's state. The view listens; every action re-reads the status.
class GitModel extends ChangeNotifier {
  final Workspace ws;
  GitModel(this.ws);

  List<GitRepo> repos = [];
  GitRepo? repo;
  GitStatus? status;
  List<GitBranch> branches = [];
  List<GitCommit> log = [];
  bool loadingRepos = false;
  bool busy = false;
  String? error;
  String? lastSyncOutput;
  bool _disposed = false;

  Link? get _link => ws.link;

  Map<String, dynamic> _args([Map<String, dynamic> extra = const {}]) => {'root': repo!.root, 'repo': repo!.repo, ...extra};

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Finds repositories under every file root (the agent looks a few levels
  /// down and stops at 30).
  Future<void> findRepos() async {
    final l = _link;
    if (l == null) return;
    loadingRepos = true;
    error = null;
    _notify();
    try {
      final roots = (await l.call('fs.roots') as Map)['roots'] as List;
      final found = <GitRepo>[];
      for (final r in roots) {
        final id = (r as Map)['id'] as String;
        if (r['ok'] == false) continue;
        // a huge root such as / is not walked; its repositories are found
        // from the folder the user opens
        if (r['path'] == '/' || (r['path'] as String?)?.startsWith('/mnt/') == true) continue;
        try {
          final res = await l.call('git.repos', {'root': id, 'path': '/'}) as Map;
          for (final x in res['repos'] as List) {
            final m = (x as Map).cast<String, dynamic>();
            found.add(GitRepo(id, m['repo'] as String, m['name'] as String));
          }
        } on OpError {
          // a root that is not readable has no repositories to show
        }
      }
      repos = found;
      if (repo != null && !repos.any((r) => r.root == repo!.root && r.repo == repo!.repo)) repo = null;
      repo ??= repos.isEmpty ? null : repos.first;
    } on OpError catch (e) {
      error = e.message;
    }
    loadingRepos = false;
    _notify();
    if (repo != null) await refresh();
  }

  /// Opens a repository by path (from the file tree), whether or not it was found.
  Future<void> openRepo(GitRepo r) async {
    if (!repos.any((x) => x.root == r.root && x.repo == r.repo)) repos = [...repos, r];
    repo = r;
    status = null;
    branches = [];
    log = [];
    _notify();
    await refresh();
  }

  Future<void> select(GitRepo r) => openRepo(r);

  Future<void> refresh() async {
    final l = _link;
    if (l == null || repo == null) return;
    try {
      final st = await l.call('git.status', _args()) as Map;
      status = GitStatus.fromJson(st.cast<String, dynamic>());
      error = null;
    } on OpError catch (e) {
      error = e.message;
      status = null;
    }
    _notify();
  }

  Future<void> loadBranches() async {
    final l = _link;
    if (l == null || repo == null) return;
    try {
      final r = await l.call('git.branches', _args()) as Map;
      branches = [for (final b in r['branches'] as List) GitBranch.fromJson((b as Map).cast<String, dynamic>())];
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    }
    _notify();
  }

  Future<void> loadLog({int max = 100}) async {
    final l = _link;
    if (l == null || repo == null) return;
    try {
      final r = await l.call('git.log', _args({'max': max})) as Map;
      log = [for (final c in r['commits'] as List) GitCommit.fromJson((c as Map).cast<String, dynamic>())];
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    }
    _notify();
  }

  /// Runs a repository-changing call, shows an error as a message, and reads
  /// the status again. Returns whether it succeeded.
  Future<bool> act(String op, [Map<String, dynamic> extra = const {}]) async {
    final l = _link;
    if (l == null || repo == null) return false;
    busy = true;
    _notify();
    var ok = false;
    try {
      await l.call(op, _args(extra));
      ok = true;
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    }
    busy = false;
    await refresh();
    return ok;
  }

  Future<void> stage(List<String> paths) => act('git.stage', {'paths': paths});
  Future<void> stageAll() => act('git.stage', {'all': true});
  Future<void> unstage(List<String> paths) => act('git.unstage', {'paths': paths});
  Future<void> unstageAll() => act('git.unstage', {'all': true});
  Future<bool> discard(List<String> paths) => act('git.discard', {'paths': paths});

  Future<bool> commit(String message, {bool amend = false, bool all = false}) async {
    final ok = await act('git.commit', {'message': message, 'amend': amend, 'all': all});
    if (ok) ws.toast(amend ? '已修改上一次提交' : '已提交');
    return ok;
  }

  Future<bool> checkout(String branch, {bool create = false, String? from}) async {
    final ok = await act('git.checkout', {'branch': branch, 'create': create, 'rev': ?from});
    if (ok) await loadBranches();
    return ok;
  }

  /// fetch | pull | push. The agent answers with a reason when it needs the
  /// user to choose (diverged, rejected, dirty); the caller decides.
  Future<({bool ok, String reason, String output})> sync(String action, {String? mode}) async {
    final l = _link;
    if (l == null || repo == null) return (ok: false, reason: 'unavailable', output: '未连接');
    busy = true;
    _notify();
    try {
      final s = await l.open('git.sync', _args({'action': action, 'mode': ?mode}), Priority.bulk);
      final r = (await s.response() as Map).cast<String, dynamic>();
      await s.close();
      lastSyncOutput = r['output'] as String?;
      return (ok: r['ok'] == true, reason: r['reason'] as String? ?? '', output: r['output'] as String? ?? '');
    } on OpError catch (e) {
      return (ok: false, reason: 'error', output: e.message);
    } finally {
      busy = false;
      await refresh();
    }
  }
}
