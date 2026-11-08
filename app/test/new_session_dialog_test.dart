// The "走代理" box of the new-session dialog (docs/DESIGN.md D-47, D-48, D-49):
// it can be ticked only when the agent can honour it, and says why when it
// cannot. Widget-level: what the dialog returns is what createSession sends.
import 'dart:io';

import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('with a node chosen the box can be ticked, and the answer carries it', (t) async {
    NewSession? r;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [Ide.dark]),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(onPressed: () async => r = await showDialog<NewSession>(context: ctx, builder: (_) => const NewSessionDialog(initial: 's2', proxy: ProxyOffer.available('HK 01'))), child: const Text('open')),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.textContaining('HK 01'), findsOneWidget, reason: 'it says which node');
    expect(t.widget<CheckboxListTile>(find.byKey(const ValueKey('session-proxy'))).value, isFalse, reason: 'unticked by default (D-47)');
    await t.tap(find.byKey(const ValueKey('session-proxy')));
    await t.pump();
    expect(t.widget<CheckboxListTile>(find.byKey(const ValueKey('session-proxy'))).value, isTrue);
    await t.tap(find.text('创建'));
    await t.pumpAndSettle();
    expect(r!.name, 's2');
    expect(r!.proxy, isTrue);
  });

  testWidgets('left unticked, the session is made without a proxy', (t) async {
    NewSession? r;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [Ide.dark]),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(onPressed: () async => r = await showDialog<NewSession>(context: ctx, builder: (_) => const NewSessionDialog(initial: 's2', proxy: ProxyOffer.available('HK 01'))), child: const Text('open')),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('创建'));
    await t.pumpAndSettle();
    expect(r!.proxy, isFalse);
  });

  for (final reason in ['这台服务器的 agent 没有代理功能', '代理服务是关闭的：在“代理”页打开它', '还没有选节点：在“代理”页选一个']) {
    testWidgets('when it cannot be had the box is disabled and says why: $reason', (t) async {
      NewSession? r;
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [Ide.dark]),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(onPressed: () async => r = await showDialog<NewSession>(context: ctx, builder: (_) => NewSessionDialog(initial: 's2', proxy: ProxyOffer.unavailable(reason))), child: const Text('open')),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text(reason), findsOneWidget);
      expect(t.widget<CheckboxListTile>(find.byKey(const ValueKey('session-proxy'))).onChanged, isNull, reason: 'cannot be ticked');
      await t.tap(find.byKey(const ValueKey('session-proxy')), warnIfMissed: false);
      await t.pump();
      await t.tap(find.text('创建'));
      await t.pumpAndSettle();
      expect(r!.proxy, isFalse, reason: 'a box that cannot be ticked never asks for a proxy');
    });
  }

  testWidgets('cancel returns nothing', (t) async {
    NewSession? r = NewSession('sentinel', true);
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [Ide.dark]),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(onPressed: () async => r = await showDialog<NewSession>(context: ctx, builder: (_) => const NewSessionDialog(initial: 's2', proxy: ProxyOffer.available('x'))), child: const Text('open')),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(r, isNull);
  });

  // What the agent reports decides whether the box is offered (D-49): the
  // dialog never invites a choice the agent would refuse.
  group('proxyOffer reads the agent\'s service list and the server\'s chosen node', () {
    Future<Workspace> workspace(List<Map<String, dynamic>> services, {ProxyChoice? chosen}) async {
      final app = AppState();
      await app.initAt('${Directory.systemTemp.path}${Platform.pathSeparator}aurora3-offer-${DateTime.now().microsecondsSinceEpoch}.bin');
      late ServerEntry e;
      await app.update((p) {
        e = ServerEntry.create('s');
        e.proxy = chosen;
        p.servers.add(e);
      });
      final ws = Workspace(app, e.id)..services = services;
      return ws;
    }

    final choice = ProxyChoice(source: 'src', key: 'k', name: 'HK 01');
    Map<String, dynamic> svc({bool enabled = true, List<String> ops = const ['proxy.status', 'proxy.set', 'proxy.clear', 'proxy.test', 'proxy.check']}) => {'id': 'proxy', 'enabled': enabled, 'available': true, 'ops': ops};

    test('all in place: offered, naming the node', () async {
      final o = proxyOffer(await workspace([svc()], chosen: choice));
      expect(o.available, isTrue);
      expect(o.nodeName, 'HK 01');
    });
    test('the agent has no proxy service', () async {
      final o = proxyOffer(await workspace([{'id': 'terminal', 'enabled': true, 'ops': <String>[]}], chosen: choice));
      expect(o.available, isFalse);
      expect(o.unavailable, contains('没有代理功能'));
    });
    test('the service is switched off', () async {
      final o = proxyOffer(await workspace([svc(enabled: false)], chosen: choice));
      expect(o.available, isFalse);
      expect(o.unavailable, contains('关闭'));
    });
    test('an older agent without proxy.set', () async {
      final o = proxyOffer(await workspace([svc(ops: ['proxy.status'])], chosen: choice));
      expect(o.available, isFalse);
      expect(o.unavailable, contains('版本较旧'));
    });
    test('no node chosen yet', () async {
      final o = proxyOffer(await workspace([svc()]));
      expect(o.available, isFalse);
      expect(o.unavailable, contains('选一个'));
    });
  });}
