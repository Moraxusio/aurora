import 'dart:async';

import 'package:aurora/features/search/search_model.dart';
import 'package:aurora/features/search/search_scope.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _SearchStream extends Fake implements OpStream {
  final ready = Completer<void>(), result = Completer<Object?>();
  int resets = 0;
  @override
  Future<Object?> response() {
    ready.complete();
    return result.future;
  }

  @override
  void reset() {
    resets++;
    if (!result.isCompleted)
      result.completeError(OpError(codeUnavailable, 'cancelled'));
  }
}

class _SearchLink extends FileTreeLink {
  final streams = <_SearchStream>[];
  @override
  AgentInfo get server => AgentInfo({
    'caps': ['fs.search.stream'],
  });
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    final stream = _SearchStream();
    streams.add(stream);
    return stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final issue in ['incomplete', 'skipped_large']) {
    test('replacement is blocked for $issue search results', () async {
      final link = _SearchLink();
      final connected = WorkspaceApp(wire: link);
      final ws = Workspace(connected, 'server');
      final model = SearchModel(ws, folders: (_) async => [const SearchFolder('home', '/', 'home')]);
      final pending = model.search(const SearchOptions('needle'));
      await Future<void>.delayed(Duration.zero);
      link.streams.single.result.complete({
        'files': [], issue: issue == 'incomplete' ? true : 2, 'errors': 1,
      });
      await pending;
      expect(model.incomplete, isTrue);
      await expectLater(model.previewReplacement('value'), throwsA(isA<StateError>().having((e) => e.message, 'reason', contains('不完整'))));
      model.dispose(); ws.dispose(); connected.dispose();
    });
  }

  test('cancelling a new query cannot reuse the previous replacement options', () async {
    final link = _SearchLink();
    final app = WorkspaceApp(wire: link);
    final space = Workspace(app, 'server');
    final model = SearchModel(space, folders: (_) async => [const SearchFolder('home', '/', 'home')]);
    final first = model.search(const SearchOptions('old'));
    await Future<void>.delayed(Duration.zero);
    link.streams.single.result.complete({'files': []});
    await first;
    final second = model.search(const SearchOptions('new'));
    await Future<void>.delayed(Duration.zero);
    model.cancel();
    await second;
    await expectLater(model.previewReplacement('value'), throwsA(isA<StateError>().having((e) => e.message, 'reason', contains('先完成搜索'))));
    model.dispose(); space.dispose(); app.dispose();
  });
  test('editing a search query resets its backend stream and ignores the old result', () async {
    final link = _SearchLink();
    final connected = WorkspaceApp(wire: link);
    final ws = Workspace(connected, 'server');
    final model = SearchModel(
      ws,
      folders: (_) async => [const SearchFolder('home', '/', 'home')],
    );
    final first = model.search(const SearchOptions('first'));
    await Future<void>.delayed(Duration.zero);
    final old = link.streams.single;
    await old.ready.future;
    model.clear();
    await first;
    expect(old.resets, greaterThan(0));
    expect(model.results, isEmpty);
    final second = model.search(const SearchOptions('second'));
    await Future<void>.delayed(Duration.zero);
    final latest = link.streams.last;
    await latest.ready.future;
    latest.result.complete({
      'files': [
        {
          'path': '/file',
          'matches': [
            {'line': 1, 'text': 'second'},
          ],
        },
      ],
      'total': 1,
    });
    await second;
    expect(model.results.single.lines.single.text, 'second');
    expect(model.running, isFalse);
    expect(latest.resets, 1);
    model.dispose();
    ws.dispose();
    connected.dispose();
  });
}
