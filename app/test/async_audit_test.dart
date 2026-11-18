import 'dart:async';

import 'package:aurora/features/git/git_model.dart';
import 'package:aurora/kernel/file_watch.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _WatchStream extends Fake implements OpStream {
  final ack = Completer<Object?>();
  final events = StreamController<Frame>();
  late final iterator = StreamIterator(events.stream);
  final sent = <Object?>[];
  bool resetCalled = false;

  @override
  Future<Object?> response() => ack.future;
  @override
  Future<void> sendJson(Object? value) async => sent.add(value);
  @override
  Future<Frame?> read() async =>
      await iterator.moveNext() ? iterator.current : null;
  @override
  void reset() {
    if (resetCalled) return;
    resetCalled = true;
    unawaited(events.close());
  }
}

class _WatchLink extends FileTreeLink {
  final stream = _WatchStream();
  int opens = 0;
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    opens++;
    return stream;
  }
}

class _GitLink extends FileTreeLink {
  final held = <String, Completer<Object?>>{};
  final requests = <String>[];
  String label = 'new';
  Map<String, Object?> result(String op, [String? name]) {
    name ??= label;
    return switch (op) {
      'git.status' => {'branch': name, 'files': <Object>[]},
      'git.branches' => {
        'branches': [
          {'name': name},
        ],
      },
      'git.log' => {
        'commits': [
          {'subject': name},
        ],
      },
      'git.stash' => {
        'stashes': [
          {'message': name},
        ],
      },
      'git.tag' => {
        'tags': [
          {'name': name},
        ],
      },
      _ => throw StateError(op),
    };
  }

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    requests.add(op);
    final gate = held.remove(op);
    if (gate != null) return gate.future;
    if (op.startsWith('git.')) return result(op);
    return super.call(op, args, timeout);
  }
}

class _SwitchingApp extends WorkspaceApp {
  Link current;
  _SwitchingApp(this.current);
  @override
  Link? link(String id) => current;
}

void main() {
  test('git mutations reject repeated clicks and always release busy', () async {
    final link = _GitLink();
    final app = _SwitchingApp(link);
    final ws = Workspace(app, 'server');
    final model = GitModel(ws)..repo = GitRepo('home', '/project', 'project');
    addTearDown(() { model.dispose(); ws.dispose(); app.dispose(); });
    final gate = Completer<Object?>();
    link.held['git.stage'] = gate;
    final first = model.act('git.stage');
    expect(model.busy, isTrue);
    expect(await model.act('git.stage'), isFalse);
    expect(link.requests.where((op) => op == 'git.stage'), hasLength(1));
    gate.completeError(StateError('transport failed'));
    expect(await first, isFalse);
    expect(model.busy, isFalse);
    final next = Completer<Object?>()..complete({});
    link.held['git.stage'] = next;
    expect(await model.act('git.stage'), isTrue);
  });

  test('old git write cannot report success or refresh another repository', () async {
    final link = _GitLink();
    final app = _SwitchingApp(link);
    final ws = Workspace(app, 'server');
    final model = GitModel(ws)..repo = GitRepo('home', '/old', 'old');
    addTearDown(() { model.dispose(); ws.dispose(); app.dispose(); });
    final gate = Completer<Object?>();
    link.held['git.commit'] = gate;
    final pending = model.act('git.commit');
    await model.openRepo(GitRepo('home', '/new', 'new'));
    final reads = link.requests.where((op) => op == 'git.status').length;
    gate.complete({});
    expect(await pending, isFalse);
    expect(link.requests.where((op) => op == 'git.status'), hasLength(reads));
    expect(model.busy, isFalse);
  });

  testWidgets('watch reconnect overtakes an old pending handshake', (
    tester,
  ) async {
    final old = _WatchLink(), next = _WatchLink();
    next.stream.ack.complete(null);
    Link link = old;
    final watch = FileWatch(() => link);
    addTearDown(watch.dispose);
    watch.watch('home', '/a.txt', () {});
    await tester.pump(const Duration(milliseconds: 60));
    expect(old.opens, 1);
    link = next;
    watch.relink();
    await tester.pump(const Duration(milliseconds: 60));
    old.stream.ack.complete(null);
    await tester.pump();
    expect(
      next.opens,
      1,
      reason: 'new link must not wait on the dead handshake',
    );
    expect(old.stream.resetCalled, isTrue);
    expect(next.stream.sent, hasLength(1));
  });

  for (final op in [
    'git.status',
    'git.branches',
    'git.log',
    'git.stash',
    'git.tag',
  ]) {
    test(
      '$op cannot publish a reply from the previously selected repository',
      () async {
        final link = _GitLink();
        final app = _SwitchingApp(link);
        final modelWorkspace = Workspace(app, 'server');
        final model = GitModel(modelWorkspace);
        addTearDown(() {
          model.dispose();
          modelWorkspace.dispose();
          app.dispose();
        });
        model.repo = GitRepo('home', '/old', 'old');
        Future<void> load() => switch (op) {
          'git.status' => model.refresh(),
          'git.branches' => model.loadBranches(),
          'git.log' => model.loadLog(),
          'git.stash' => model.loadStashes(),
          _ => model.loadTags(),
        };
        String? shown() => switch (op) {
          'git.status' => model.status?.branch,
          'git.branches' => model.branches.single.name,
          'git.log' => model.log.single.subject,
          'git.stash' => model.stashes.single.message,
          _ => model.tags.single.name,
        };
        final gate = Completer<Object?>();
        link.held[op] = gate;
        final old = load();
        await model.openRepo(GitRepo('home', '/new', 'new'));
        await load();
        gate.complete(link.result(op, 'old'));
        await old;
        expect(shown(), 'new');
      },
    );
  }

  test(
    'git status rejects old connections and out-of-order refreshes',
    () async {
      final oldLink = _GitLink(), newLink = _GitLink();
      final app = _SwitchingApp(oldLink);
      final modelWorkspace = Workspace(app, 'server');
      final model = GitModel(modelWorkspace)
        ..repo = GitRepo('home', '/project', 'project');
      addTearDown(() {
        model.dispose();
        modelWorkspace.dispose();
        app.dispose();
      });
      final oldGate = Completer<Object?>();
      oldLink.held['git.status'] = oldGate;
      final old = model.refresh();
      app.current = newLink;
      await model.refresh();
      oldGate.complete(oldLink.result('git.status', 'old connection'));
      await old;
      expect(model.status?.branch, 'new');
      final slowGate = Completer<Object?>();
      newLink.held['git.status'] = slowGate;
      final slow = model.refresh();
      newLink.label = 'latest';
      await model.refresh();
      slowGate.complete(newLink.result('git.status', 'stale'));
      await slow;
      expect(model.status?.branch, 'latest');
    },
  );
}
