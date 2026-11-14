import 'dart:async';

import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';

/// Transactional in-memory profile and synthetic link; never opens the user's
/// store, SSH keys, subscriptions, or a remote server.
class WorkspaceApp extends AppState {
  Profile data;
  final Link? wire;
  int viewWrites = 0, notifications = 0;
  bool failViews = false, failChanges = false;
  Completer<void>? saveBarrier;
  final List<Map<String, WorkspaceView>> snapshots = [];

  WorkspaceApp({Profile? profile, this.wire})
    : data = profile ?? Profile(servers: [ServerEntry(id: 'server', name: 'fixture', workspaces: [
        ProjectWorkspace(id: 'a', name: 'Alpha', folders: [ref('/project')]),
        ProjectWorkspace(id: 'b', name: 'Beta', folders: [ref('/project'), ref('/other')]),
      ])], selected: 'server');

  @override bool get ready => true;
  @override Profile get profile => data.copy();
  @override ServerEntry? server(String id) {
    final value = data.server(id);
    return value == null ? null : ServerEntry.fromJson(value.toJson());
  }
  @override List<ServerEntry> get servers => data.copy().servers;
  @override String? get selected => data.selected;
  @override Link? link(String id) => wire;
  @override ConnStatus status(String id) => ConnStatus(wire == null ? ConnState.idle : ConnState.connected);
  @override Future<void> connect(String id) async {}
  @override Future<void> update(FutureOr<void> Function(Profile) fn) async {
    final next = data.copy();
    final result = fn(next);
    if (result is Future<void>) await result;
    if (failChanges) throw StateError('synthetic write failure');
    data = next;
    appearance.reload();
    notifications++;
    notifyListeners();
  }
  @override Future<void> saveWorkspaceViews(String id, Map<String, WorkspaceView> views) async {
    viewWrites++;
    snapshots.add({for (final item in views.entries) item.key: WorkspaceView.fromJson(item.value.toJson())});
    final barrier = saveBarrier;
    saveBarrier = null;
    if (barrier != null) await barrier.future;
    if (failViews) throw StateError('synthetic view write failure');
    final next = data.copy();
    final entry = next.server(id)!;
    for (final item in views.entries) {
      final copy = WorkspaceView.fromJson(item.value.toJson());
      if (item.key.isEmpty) { entry.browserView = copy; }
      else { entry.workspace(item.key)?.view = copy; }
    }
    data = next;
  }
}

WorkspacePath ref(String path, [String root = 'home']) => WorkspacePath(root: root, path: path);

class FileTreeLink implements Link {
  final calls = <String>[];
  final Map<String, List<Map<String, Object?>>> directories = {
    '/': [dir('project'), dir('other')],
    '/project': [dir('src'), file('README.md')],
    '/project/src': [dir('nested'), file('main.dart')],
    '/project/src/nested': [file('deep.txt')],
    '/other': [file('notes.txt')],
  };
  final Map<String, Completer<Object?>> delayed = {};
  final Set<String> denied = {};
  int reads = 0;
  @override AgentInfo get server => AgentInfo({'version': '3.3.1', 'arch': 'amd64', 'caps': <String>[]});
  @override bool get isClosed => false;
  @override Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    if (op == 'agent.services') { return {'services': [for (final id in ['terminal', 'files', 'monitor'])
      {'id': id, 'enabled': true, 'available': true, 'ops': <String>[]}]}; }
    if (op == 'fs.roots') return {'roots': [{'id': 'home', 'label': 'Home', 'path': '/fixture/home', 'ok': true}]};
    final path = (args as Map)['path'] as String;
    calls.add('$op:$path');
    final delayedCall = delayed.remove('$op:$path');
    if (delayedCall != null) return delayedCall.future;
    if (denied.contains(path)) throw OpError(codeNotFound, 'fixture folder not found');
    if (op == 'fs.list') return {'entries': directories[path] ?? <Object>[]};
    if (op == 'fs.read') { reads++; return {'content': 'synthetic original\n', 'etag': 'fixture-etag'}; }
    throw OpError(codeNotFound, 'synthetic operation refused');
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  static Map<String, Object?> dir(String name) => {'name': name, 'type': 'dir'};
  static Map<String, Object?> file(String name) => {'name': name, 'type': 'file', 'size': 42};
}
