import 'package:aurora/features/git/blame_view.dart';
import 'package:aurora/features/git/git_model.dart';
import 'package:aurora/features/git/merge_view.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

/// The git and file operations, answered as the agent does, with every call
/// recorded.
class GitLink extends FileTreeLink {
  final asked = <(String, Map)>[];
  String file = 'a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> topic\nb\n';
  String etag = 'e1';
  final writes = <(String, String?)>[];
  Object? Function(String op, Map a)? answer;

  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    final a = (args as Map?) ?? const {};
    if (op != 'agent.services' && op != 'fs.roots') asked.add((op, a));
    final custom = answer?.call(op, a);
    if (custom != null) return custom;
    switch (op) {
      case 'fs.read':
        return {'content': file, 'etag': etag, 'size': file.length};
      case 'fs.write':
        if (a['if_match'] != null && a['if_match'] != etag) throw OpError(codeConflict, '文件已被其他程序修改');
        writes.add((a['content'] as String, a['if_match'] as String?));
        file = a['content'] as String;
        etag = 'e${writes.length + 1}';
        return {'etag': etag};
      case 'git.status':
        return {'branch': 'main', 'files': <Object>[], 'remotes': ['origin'], 'stashes': 1};
      case 'git.stash':
        if (a['action'] == 'list') {
          return {'stashes': [{'index': 0, 'ref': 'stash@{0}', 'hash': 'abc', 'message': 'WIP on main', 'time': 1}]};
        }
        return {'ok': true};
      case 'git.tag':
        if (a['action'] == 'list') return {'tags': [{'name': 'v1', 'hash': 'abc1234', 'time': 1, 'subject': 'one'}]};
        return {'ok': true};
      case 'git.branch' || 'git.branches' || 'git.remote' || 'git.log' || 'git.stage':
        return op == 'git.branches' ? {'branches': <Object>[]} : op == 'git.log' ? {'commits': <Object>[]} : {'ok': true};
      case 'git.op':
        return {'ok': true, 'operation': '', 'output': ''};
      case 'git.blame':
        return {
          'commits': [
            {'hash': 'a' * 40, 'short': 'aaaaaaa', 'author': 'Ann', 'time': 1700000000, 'summary': 'first'},
            {'hash': '0' * 40, 'short': '0000000', 'author': 'Not Committed Yet', 'time': 0, 'summary': '', 'uncommitted': true},
          ],
          'lines': [0, 0, 1],
        };
    }
    return super.call(op, args, timeout);
  }
}

void main() {
  late GitLink link;
  late WorkspaceApp app;
  late Workspace ws;
  late GitModel git;
  late InputMode input;
  setUp(() {
    link = GitLink();
    app = WorkspaceApp(wire: link);
    ws = Workspace(app, 'server');
    git = GitModel(ws)..repo = GitRepo('home', '/project', 'project');
    input = InputMode(touch: false);
  });
  tearDown(() {
    git.dispose();
    ws.dispose();
    input.dispose();
    app.dispose();
  });

  Map args(String op) => link.asked.lastWhere((c) => c.$1 == op).$2;

  /// The last call of [op] with this action (a change is followed by a list).
  Map act(String op, String action) => link.asked.lastWhere((c) => c.$1 == op && c.$2['action'] == action).$2;

  Future<void> show(WidgetTester t, Widget w) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: InputMode.scope(mode: input, child: Scaffold(body: SizedBox(width: 900, height: 700, child: w))),
    ));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  group('model sends what the agent expects', () {
    test('stash push, apply, pop, drop', () async {
      await git.stash('push', message: '  wip  ', untracked: true);
      expect(act('git.stash', 'push'), allOf(containsPair('message', 'wip'), containsPair('untracked', true)));
      await git.stash('pop', index: 2);
      expect(act('git.stash', 'pop')['index'], 2);
      expect(args('git.stash')['action'], 'list');
      expect(git.stashes.single.ref, 'stash@{0}', reason: 'the list is read again after a change');
    });

    test('branches: create at a commit, rename, forced delete, upstream', () async {
      await git.branch('rename', 'old', to: 'new');
      expect(args('git.branch'), allOf(containsPair('action', 'rename'), containsPair('branch', 'old'), containsPair('to', 'new')));
      await git.branch('delete', 'x', force: true);
      expect(args('git.branch'), containsPair('force', true));
      await git.branch('delete', 'y');
      expect(args('git.branch').containsKey('force'), isFalse);
      await git.branch('upstream', 'main', to: 'origin/main');
      expect(args('git.branch'), containsPair('to', 'origin/main'));
    });

    test('tags and remotes', () async {
      await git.createTag('v2', rev: 'abc', message: 'two');
      expect(act('git.tag', 'create'), allOf(containsPair('name', 'v2'), containsPair('rev', 'abc'), containsPair('message', 'two')));
      expect(git.tags.single.name, 'v1');
      await git.addRemote('up', 'git@example.invalid:x.git');
      expect(args('git.remote'), allOf(containsPair('action', 'add'), containsPair('url', 'git@example.invalid:x.git')));
    });

    test('operations: rev only when given; conflicts are an outcome', () async {
      await git.op('continue', rev: '');
      expect(args('git.op').containsKey('rev'), isFalse);
      await git.op('reset', rev: 'abc', mode: 'soft');
      expect(args('git.op'), allOf(containsPair('rev', 'abc'), containsPair('mode', 'soft')));
      link.answer = (op, a) => op == 'git.op' ? {'ok': true, 'conflicts': true, 'operation': 'cherry-pick'} : null;
      final r = await git.op('cherry-pick', rev: 'abc');
      expect((r.ok, r.conflicts, r.operation), (true, true, 'cherry-pick'));
      link.answer = (op, a) => op == 'git.op' ? throw OpError(codeConflict, '还有冲突') : null;
      expect((await git.op('continue')).ok, isFalse);
    });

    test('show: a missing version is null, a binary one says why', () async {
      link.answer = (op, a) => op == 'git.show' ? (a['rev'] == ':1' ? {'missing': true, 'text': ''} : {'binary': true, 'text': ''}) : null;
      expect(await git.show('f', ':1'), isNull);
      expect(() => git.show('f', ':2'), throwsA(isA<OpError>()));
    });
  });

  group('merge view', () {
    testWidgets('pick a side, save with the etag, then stage', (t) async {
      await show(t, MergeView(ws: ws, git: git, path: 'src/f.txt'));
      expect(args('fs.read'), containsPair('path', '/project/src/f.txt'));
      expect(find.text('mine'), findsOneWidget);
      expect(find.text('theirs'), findsOneWidget);
      await t.tap(find.text('采用传入'));
      await t.pump();
      expect(find.textContaining('已决定 1 / 1'), findsOneWidget);
      await t.tap(find.text('保存'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(link.writes.single, ('a\ntheirs\nb\n', 'e1'));
      // no conflict left: it offers to stage
      expect(find.text('冲突都已解决'), findsOneWidget);
      await t.tap(find.text('暂存'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(args('git.stage'), containsPair('paths', ['src/f.txt']));
    });

    testWidgets('both sides, and an undecided block is saved unchanged', (t) async {
      link.file = '<<<<<<< HEAD\n1\n=======\n2\n>>>>>>> x\nmid\n<<<<<<< HEAD\n3\n=======\n4\n>>>>>>> x\n';
      await show(t, MergeView(ws: ws, git: git, path: 'g.txt'));
      await t.tap(find.text('两者都要（当前在前）').first);
      await t.pump();
      await t.tap(find.text('保存'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(link.writes.single.$1, '1\n2\nmid\n<<<<<<< HEAD\n3\n=======\n4\n>>>>>>> x\n');
      expect(find.text('冲突都已解决'), findsNothing);
      expect(find.textContaining('已决定 0 / 1'), findsOneWidget);
    });

    testWidgets('a file changed meanwhile is not overwritten', (t) async {
      await show(t, MergeView(ws: ws, git: git, path: 'f.txt'));
      link.etag = 'someone-else';
      await t.tap(find.text('采用当前'));
      await t.pump();
      await t.tap(find.text('保存'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(link.writes, isEmpty);
      expect(find.textContaining('已决定 1 / 1'), findsOneWidget, reason: 'the decision is kept for another try');
    });
  });

  testWidgets('blame shows each commit once, at its first line', (t) async {
    link.file = 'one\ntwo\nthree\n';
    await show(t, BlameView(ws: ws, git: git, path: 'f.txt'));
    expect(args('git.blame'), containsPair('path', 'f.txt'));
    expect(find.text('aaaaaaa'), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget);
    expect(find.text('未提交'), findsOneWidget);
    expect(find.text('three'), findsOneWidget);
  });
}
