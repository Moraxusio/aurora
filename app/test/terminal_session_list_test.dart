import 'dart:async';

import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

class _Link extends FileTreeLink {
  int kills = 0;
  bool failKill = false;
  Completer<Object?>? listing, ending;
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'session.list') {
      return listing?.future ??
          Future.value({
            'sessions': [
              {'name': 'main'},
            ],
          });
    }
    if (op == 'session.kill') {
      kills++;
      if (failKill) throw OpError(codeUnavailable, 'Synthetic kill refused');
      return ending?.future ?? Future.value({'killed': true});
    }
    return super.call(op, args, timeout);
  }
}

class _App extends WorkspaceApp {
  Link? current;
  _App(this.current);
  @override
  Link? link(String id) => current;
}

void main() {
  late _Link link;
  late _App app;
  late Workspace ws;
  late InputMode input;
  setUp(() {
    link = _Link();
    app = _App(link);
    ws = Workspace(app, 'server');
    input = InputMode(touch: false);
  });
  tearDown(() async {
    await ws.flushViews();
    ws.dispose();
    app.dispose();
    input.dispose();
  });
  EditorTab terminal() => EditorTab(
    id: 'term:main',
    title: 'main',
    icon: Icons.terminal,
    builder: (_) => const SizedBox(),
  );
  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(body: SessionList(ws: ws)),
        ),
      ),
    );
    await t.pump();
  }

  Future<void> ask(WidgetTester t) async {
    await t.tap(find.byTooltip('结束会话'));
    await t.pumpAndSettle();
  }

  testWidgets('failed session kill keeps the live terminal view', (t) async {
    final tab = terminal();
    ws.openTab(tab);
    link.failKill = true;
    await pump(t);
    await ask(t);
    await t.tap(find.text('结束'));
    await t.pumpAndSettle();
    expect(link.kills, 1);
    expect(ws.tab(tab.id), same(tab));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'confirmation from an old connection cannot kill on its replacement',
    (t) async {
      final tab = terminal();
      ws.openTab(tab);
      await pump(t);
      await ask(t);
      final replacement = _Link();
      app.current = replacement;
      await t.tap(find.text('结束'));
      await t.pumpAndSettle();
      expect(link.kills, 0);
      expect(replacement.kills, 0);
      expect(ws.tab(tab.id), same(tab));
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late session lists cannot remove a reopened terminal instance', (
    t,
  ) async {
    final old = terminal();
    ws.openTab(old);
    link.listing = Completer<Object?>();
    await pump(t);
    ws.dropTabs((tab) => identical(tab, old));
    final replacement = terminal();
    ws.openTab(replacement);
    link.listing!.complete({'sessions': <Object>[]});
    await t.pumpAndSettle();
    expect(ws.tab(replacement.id), same(replacement));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a kill reply after reconnect cannot mutate the current workspace',
    (t) async {
      final tab = terminal();
      ws.openTab(tab);
      link.ending = Completer<Object?>();
      await pump(t);
      await ask(t);
      await t.tap(find.text('结束'));
      await t.pumpAndSettle();
      expect(link.kills, 1);
      app.current = _Link();
      link.ending!.complete({'killed': true});
      await t.pumpAndSettle();
      expect(ws.tab(tab.id), same(tab));
      await t.pumpWidget(const SizedBox());
    },
  );
}
