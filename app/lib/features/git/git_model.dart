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

class GitStash {
  final int index;
  final String ref, hash, message;
  final int time;
  GitStash.fromJson(Map<String, dynamic> j)
      : index = (j['index'] as num?)?.toInt() ?? 0,
        ref = j['ref'] as String? ?? '',
        hash = j['hash'] as String? ?? '',
        message = j['message'] as String? ?? '',
        time = (j['time'] as num?)?.toInt() ?? 0;
}

class GitTag {
  final String name, hash, subject;
  final int time;
  GitTag.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String? ?? '',
        hash = j['hash'] as String? ?? '',
        subject = j['subject'] as String? ?? '',
        time = (j['time'] as num?)?.toInt() ?? 0;
}

/// One line's commit, from git.blame.
class BlameCommit {
  final String hash, short, author, summary;
  final int time;
  final bool uncommitted;
  BlameCommit.fromJson(Map<String, dynamic> j)
      : hash = j['hash'] as String? ?? '',
        short = j['short'] as String? ?? '',
        author = j['author'] as String? ?? '',
        summary = j['summary'] as String? ?? '',
        time = (j['time'] as num?)?.toInt() ?? 0,
        uncommitted = j['uncommitted'] == true;
}

class Blame {
  final List<BlameCommit> commits;

  /// For each line of the file (0-based), the index into [commits].
  final List<int> lines;
  Blame(this.commits, this.lines);
  factory Blame.fromJson(Map<String, dynamic> j) => Blame(
        [for (final c in (j['commits'] as List? ?? const [])) BlameCommit.fromJson((c as Map).cast<String, dynamic>())],
        [for (final l in (j['lines'] as List? ?? const [])) (l as num).toInt()],
      );

  BlameCommit? at(int line) => line >= 0 && line < lines.length && lines[line] >= 0 && lines[line] < commits.length ? commits[lines[line]] : null;
}

/// What an operation that may stop on conflicts answered.
class GitOpResult {
  final bool ok, conflicts;
  final String operation, output;
  const GitOpResult(this.ok, {this.conflicts = false, this.operation = '', this.output = ''});
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
  int _readSequence = 0, _findSequence = 0;
  final _readVersions = <String, int>{};
  OpStream? _syncStream;

  Link? get _link => ws.link;

  Map<String, dynamic> _args([Map<String, dynamic> extra = const {}]) => {'root': repo!.root, 'repo': repo!.repo, ...extra};

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncStream?.reset();
    super.dispose();
  }

  /// Finds repositories under every file root (the agent looks a few levels
  /// down and stops at 30).
  Future<void> findRepos() async {
    final l = _link;
    if (l == null || _disposed) return;
    final sequence = ++_findSequence;
    bool current() => !_disposed && sequence == _findSequence && identical(l, _link);
    loadingRepos = true;
    error = null;
    _notify();
    try {
      final roots = (await l.call('fs.roots') as Map)['roots'] as List;
      if (!current()) return;
      final found = <GitRepo>[];
      for (final r in roots) {
        final id = (r as Map)['id'] as String;
        if (r['ok'] == false) continue;
        // a huge root such as / is not walked; its repositories are found
        // from the folder the user opens
        if (r['path'] == '/' || (r['path'] as String?)?.startsWith('/mnt/') == true) continue;
        try {
          final res = await l.call('git.repos', {'root': id, 'path': '/'}) as Map;
          if (!current()) return;
          for (final x in res['repos'] as List) {
            final m = (x as Map).cast<String, dynamic>();
            found.add(GitRepo(id, m['repo'] as String, m['name'] as String));
          }
        } on OpError {
          // a root that is not readable has no repositories to show
        }
      }
      if (!current()) return;
      repos = found;
      if (repo == null || !repos.any((r) => r.root == repo!.root && r.repo == repo!.repo)) {
        _setRepo(repos.isEmpty ? null : repos.first);
      }
    } on Object catch (e) {
      if (!current()) return;
      error = e is OpError ? e.message : '$e';
    }
    if (!current()) return;
    loadingRepos = false;
    _notify();
    if (repo != null) await refresh();
  }

  /// Opens a repository by path (from the file tree), whether or not it was found.
  Future<void> openRepo(GitRepo r) async {
    _findSequence++;
    loadingRepos = false;
    if (!repos.any((x) => x.root == r.root && x.repo == r.repo)) repos = [...repos, r];
    _setRepo(r);
    _notify();
    await refresh();
  }

  void _setRepo(GitRepo? r) {
    repo = r;
    _readVersions.clear();
    status = null;
    branches = [];
    log = [];
    stashes = [];
    tags = [];
    error = null;
    lastSyncOutput = null;
  }

  Future<void> select(GitRepo r) => openRepo(r);

  Future<void> _readState(String op, Map<String, dynamic> extra, void Function(Map<String, dynamic>) apply, {bool isStatus = false}) async {
    final l = _link;
    final target = repo;
    if (l == null || target == null || _disposed) return;
    final sequence = ++_readSequence;
    _readVersions[op] = sequence;
    bool current() => !_disposed && identical(l, _link) && identical(target, repo) && _readVersions[op] == sequence;
    try {
      final result = await l.call(op, {'root': target.root, 'repo': target.repo, ...extra}) as Map;
      if (!current()) return;
      apply(result.cast<String, dynamic>());
    } on Object catch (e) {
      if (!current()) return;
      if (isStatus) {
        error = e is OpError ? e.message : '$e';
        status = null;
      } else {
        ws.toast(e is OpError ? e.message : '$e', error: true);
      }
    }
    if (current()) _notify();
  }

  Future<void> refresh() => _readState('git.status', const {}, (r) {
    status = GitStatus.fromJson(r);
    error = null;
  }, isStatus: true);

  Future<void> loadBranches() => _readState('git.branches', const {}, (r) {
    branches = [for (final b in r['branches'] as List) GitBranch.fromJson((b as Map).cast<String, dynamic>())];
  });

  Future<void> loadLog({int max = 100}) => _readState('git.log', {'max': max}, (r) {
    log = [for (final c in r['commits'] as List) GitCommit.fromJson((c as Map).cast<String, dynamic>())];
  });

  /// Runs a repository-changing call, shows an error as a message, and reads
  /// the status again. Returns whether it succeeded.
  Future<bool> act(String op, [Map<String, dynamic> extra = const {}, bool throwConflict = false]) async {
    final l = _link, target = repo;
    if (l == null || target == null || busy || _disposed) return false;
    bool current() => !_disposed && identical(l, _link) && identical(target, repo);
    busy = true;
    _notify();
    var ok = false;
    try {
      await l.call(op, {'root': target.root, 'repo': target.repo, ...extra});
      ok = true;
    } on Object catch (e) {
      if (current() && throwConflict && e is OpError && e.code == codeConflict) rethrow;
      if (current()) ws.toast(e is OpError ? e.message : '$e', error: true);
    } finally {
      if (current()) await refresh();
      busy = false;
      _notify();
    }
    return ok && current();
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

  // ---- branches ----

  /// create (at [rev], default HEAD) | rename (to [to]) | delete ([force]) |
  /// upstream (set [to] as the branch's upstream).
  Future<bool> branch(String action, String name, {String? to, String? rev, bool force = false, bool throwConflict = false}) async {
    final ok = await act('git.branch', {'action': action, 'branch': name, 'to': ?to, 'rev': ?rev, if (force) 'force': true}, throwConflict);
    if (ok) await loadBranches();
    return ok;
  }

  // ---- stash ----

  List<GitStash> stashes = [];

  Future<void> loadStashes() => _readState('git.stash', {'action': 'list'}, (r) {
    stashes = [for (final s in r['stashes'] as List) GitStash.fromJson((s as Map).cast<String, dynamic>())];
  });

  /// push ([message], [untracked], [stagedOnly]) | apply | pop | drop of
  /// stash@{[index]}. apply and pop may stop on conflicts.
  Future<GitOpResult> stash(String action, {int index = 0, String? message, bool untracked = false, bool stagedOnly = false}) async {
    final r = await _op('git.stash', {
      'action': action,
      'index': index,
      if (message != null && message.trim().isNotEmpty) 'message': message.trim(),
      if (untracked) 'untracked': true,
      if (stagedOnly) 'mode': 'staged',
    });
    if (r.ok) await loadStashes();
    return r;
  }

  // ---- tags ----

  List<GitTag> tags = [];

  Future<void> loadTags() => _readState('git.tag', {'action': 'list'}, (r) {
    tags = [for (final t in r['tags'] as List) GitTag.fromJson((t as Map).cast<String, dynamic>())];
  });

  /// [message] makes an annotated tag. [rev] defaults to HEAD.
  Future<bool> createTag(String name, {String? rev, String? message}) async {
    final ok = await act('git.tag', {'action': 'create', 'name': name, 'rev': ?rev, 'message': ?message});
    if (ok) await loadTags();
    return ok;
  }

  Future<bool> deleteTag(String name) async {
    final ok = await act('git.tag', {'action': 'delete', 'name': name});
    if (ok) await loadTags();
    return ok;
  }

  // ---- remotes ----

  Future<bool> addRemote(String name, String url) => act('git.remote', {'action': 'add', 'name': name, 'url': url});
  Future<bool> removeRemote(String name) => act('git.remote', {'action': 'remove', 'name': name});

  // ---- merge, rebase, cherry-pick, revert, reset ----

  /// git.op: merge ([mode] ff-only | no-ff | squash) / rebase / cherry-pick /
  /// revert / reset ([mode] soft | mixed | hard) of [rev]; or continue / abort
  /// / skip of the operation in progress. Conflicts are an outcome.
  Future<GitOpResult> op(String action, {String? rev, String? mode}) =>
      _op('git.op', {'action': action, if (rev != null && rev.isNotEmpty) 'rev': rev, 'mode': ?mode});

  Future<GitOpResult> _op(String name, Map<String, dynamic> extra) async {
    final l = _link, target = repo;
    if (l == null || target == null || busy || _disposed) return const GitOpResult(false, output: '未连接或正在执行其它 Git 操作');
    bool current() => !_disposed && identical(l, _link) && identical(target, repo);
    busy = true;
    _notify();
    GitOpResult result;
    try {
      final r = (await l.call(name, {'root': target.root, 'repo': target.repo, ...extra}) as Map).cast<String, dynamic>();
      result = GitOpResult(true,
          conflicts: r['conflicts'] == true, operation: r['operation'] as String? ?? '', output: r['output'] as String? ?? '');
    } on Object catch (e) {
      final message = e is OpError ? e.message : '$e';
      if (current()) ws.toast(message, error: true);
      result = GitOpResult(false, output: message);
    } finally {
      if (current()) await refresh();
      if (current() && log.isNotEmpty) await loadLog();
      busy = false;
      _notify();
    }
    return current() ? result : const GitOpResult(false, output: '仓库或连接已变化，请在原仓库核对操作结果');
  }

  // ---- blame and conflicts ----

  /// git.blame of [path] (inside the repository).
  Future<Blame?> blame(String path) async {
    final l = _link;
    if (l == null || repo == null) return null;
    try {
      return Blame.fromJson((await l.call('git.blame', _args({'path': path})) as Map).cast<String, dynamic>());
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
      return null;
    }
  }

  /// One version of a file: a revision, or a conflict stage (":1" base, ":2"
  /// ours, ":3" theirs). Null when that version does not exist; throws
  /// [OpError] for a binary or too big file, with the reason.
  Future<String?> show(String path, String rev) async {
    final l = _link;
    if (l == null || repo == null) throw OpError(codeUnavailable, '未连接');
    final r = (await l.call('git.show', _args({'path': path, 'rev': rev})) as Map).cast<String, dynamic>();
    if (r['missing'] == true) return null;
    if (r['binary'] == true) throw OpError(codeUnsupported, '二进制文件不能在这里合并');
    if (r['too_big'] == true) throw OpError(codeUnsupported, '文件太大，不能在这里合并');
    return r['text'] as String? ?? '';
  }

  /// fetch | pull | push. The agent answers with a reason when it needs the
  /// user to choose (diverged, rejected, dirty); the caller decides.
  Future<({bool ok, String reason, String output})> sync(String action, {String? mode}) async {
    final l = _link, target = repo;
    if (l == null || target == null || busy || _disposed) return (ok: false, reason: 'unavailable', output: '未连接或正在执行其它 Git 操作');
    bool current() => !_disposed && identical(l, _link) && identical(target, repo);
    busy = true;
    _notify();
    OpStream? stream;
    ({bool ok, String reason, String output}) result;
    try {
      stream = await l.open('git.sync', {'root': target.root, 'repo': target.repo, 'action': action, 'mode': ?mode}, Priority.bulk);
      if (!current()) return (ok: false, reason: 'stale', output: '仓库或连接已变化');
      _syncStream = stream;
      final r = (await stream.response().timeout(const Duration(minutes: 5)) as Map).cast<String, dynamic>();
      result = (ok: r['ok'] == true, reason: r['reason'] as String? ?? '', output: r['output'] as String? ?? '');
    } on Object catch (e) {
      result = (ok: false, reason: 'error', output: e is OpError ? e.message : '$e');
    } finally {
      stream?.reset();
      if (identical(_syncStream, stream)) _syncStream = null;
      if (current()) await refresh();
      busy = false;
      _notify();
    }
    if (!current()) return (ok: false, reason: 'stale', output: '仓库或连接已变化，请在原仓库核对同步结果');
    lastSyncOutput = result.output;
    _notify();
    return result;
  }
}
