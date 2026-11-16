import 'dart:async';

import 'package:aurora/features/ai/ai_feature.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_feature_test.dart';
import 'support/workspace_fixture.dart';

class _Link extends FakeAiLink {
  final String label;
  Completer<Object?>? listReply, searchReply;
  _Link(this.label);

  Map<String, Object?> list() => {
    'sessions': [
      {
        'id': label,
        'title': label,
        'root': 'home',
        'workdir': '/project',
        'updated_at': 1700000000000,
      },
    ],
  };
  Map<String, Object?> hits(String query) => {
    'hits': [
      {'session_id': query, 'title': '$query match', 'snippet': query},
    ],
  };
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'ai.sessions') {
      final reply = listReply;
      listReply = null;
      return reply == null ? list() : reply.future;
    }
    if (op == 'ai.search') {
      final reply = searchReply;
      searchReply = null;
      return reply == null
          ? hits((args as Map)['query'] as String)
          : reply.future;
    }
    return super.call(op, args, timeout);
  }
}

class _App extends WorkspaceApp {
  Link current;
  _App(this.current);
  @override
  Link? link(String id) => current;
  void switchLink(Link link) {
    current = link;
    notifyListeners();
  }
}

void main() {
  Future<void> show(WidgetTester t, Workspace ws, InputMode input) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: InputMode.scope(
          mode: input,
          child: Scaffold(body: AiSessionSidebar(ws: ws)),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'history from a replaced connection cannot overwrite the new list',
    (t) async {
      final old = _Link('old session'), next = _Link('new session');
      final gate = old.listReply = Completer<Object?>();
      final app = _App(old), input = InputMode(touch: false);
      final ws = Workspace(app, 'server');
      addTearDown(() {
        ws.dispose();
        input.dispose();
        app.dispose();
      });
      await show(t, ws, input);
      app.switchLink(next);
      await t.pump(const Duration(milliseconds: 100));
      gate.complete(old.list());
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('new session'), findsOneWidget);
      expect(find.text('old session'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('history search invalidates replies when the input changes', (
    t,
  ) async {
    final link = _Link('session'), input = InputMode(touch: false);
    final app = _App(link);
    final target = Workspace(app, 'server');
    addTearDown(() {
      target.dispose();
      input.dispose();
      app.dispose();
    });
    await show(t, target, input);
    final gate = link.searchReply = Completer<Object?>();
    await t.enterText(find.byType(TextField), 'old');
    await t.pump(const Duration(milliseconds: 350));
    await t.enterText(find.byType(TextField), 'new');
    gate.complete(link.hits('old'));
    await t.pump(const Duration(milliseconds: 20));
    expect(find.text('old match'), findsNothing);
    await t.pump(const Duration(milliseconds: 350));
    expect(find.text('new match'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
