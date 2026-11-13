import 'dart:async';

import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_wire/aurora_wire.dart';

import 'support/workspace_fixture.dart';

EditorTab fileTab(String path) => EditorTab(id: 'file:home:$path', title: path, icon: Icons.description,
  file: ref(path), builder: (_) => const SizedBox());

class _SlowServices extends FileTreeLink {
  final ready = Completer<Object?>();
  @override Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) => op == 'agent.services' ? ready.future : super.call(op, args, timeout);
}
class _ReconnectApp extends WorkspaceApp {
  Link? current;
  _ReconnectApp(this.current);
  @override Link? link(String id) => current;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkspaceApp app;
  late Workspace ws;
  setUp(() { app = WorkspaceApp(); ws = Workspace(app, 'server'); });
  tearDown(() async { await ws.flushViews(); ws.dispose(); app.dispose(); });

  test('projects share one dirty buffer and prompt only on its last membership', () async {
    await ws.selectProject('a');
    final shared = fileTab('/project/main.dart')..dirty.value = true;
    var prompts = 0;
    shared.confirmClose = () async { prompts++; return false; };
    ws.openTab(shared);
    await ws.selectProject('b');
    expect(ws.visibleTabs, isEmpty);
    ws.openTab(fileTab('/project/main.dart'));
    expect(ws.tabs, [same(shared)]);
    expect(shared.projects, {'a', 'b'});
    expect(await ws.closeTab(shared.id), isTrue);
    expect(prompts, 0);
    expect(shared.dirty.value, isTrue);
    await ws.selectProject('a');
    expect(await ws.closeTab(shared.id), isFalse);
    expect(prompts, 1);
    expect(ws.active, same(shared));
  });

  test('switching keeps service tabs, restores active files independently', () async {
    ws.openTab(EditorTab(id: 'term:one', title: 'terminal', icon: Icons.terminal, builder: (_) => const SizedBox()));
    await ws.selectProject('a');
    ws.openTab(fileTab('/project/a.dart'));
    await ws.selectProject('b');
    ws.openTab(fileTab('/other/b.txt'));
    await ws.selectProject('a');
    expect(ws.activeId, 'file:home:/project/a.dart');
    expect(ws.visibleTabs.map((t) => t.id), ['term:one', 'file:home:/project/a.dart']);
    expect(ws.tabs, hasLength(3));
  });

  test('restore never overwrites a newly opened file or saves unsaved text', () async {
    final saved = ref('/project/saved.dart');
    app.data.servers.single.workspace('a')!.view..files = [saved]..activeFile = saved;
    await ws.selectProject('a');
    final opened = fileTab('/project/new.dart')..dirty.value = true;
    ws.openTab(opened);
    ws.restoreFiles((p) => fileTab(p.path));
    expect(ws.active, same(opened));
    expect(ws.visibleTabs, hasLength(2));
    expect(await ws.flushViews(), isTrue);
    final json = app.data.toJson().toString();
    expect(json, isNot(contains('dirty')));
    expect(app.data.servers.single.workspace('a')!.view.files, containsAll([saved, opened.file]));
  });

  test('saved active file is restored after a rapid visit before restoration', () async {
    final saved = ref('/project/saved.dart');
    app.data.servers.single.workspace('a')!.view..files = [saved]..activeFile = saved;
    await ws.selectProject('a');
    await ws.selectProject('b');
    await ws.selectProject('a');
    ws.restoreFiles((p) => fileTab(p.path));
    expect(ws.active?.file, saved);
  });

  test('view writes are coalesced and newer changes survive in-flight I/O', () async {
    await ws.selectProject('a');
    final notifications = app.notifications;
    ws.rememberExpanded([ref('/project')]);
    app.saveBarrier = Completer<void>();
    final barrier = app.saveBarrier!;
    final first = ws.flushViews();
    final second = ws.flushViews();
    expect(second, isA<Future<bool>>());
    ws.openTab(fileTab('/project/new.dart'));
    ws.rememberExpanded([]);
    barrier.complete();
    expect(await first, isTrue);
    final view = app.data.servers.single.workspace('a')!.view;
    expect(view.files, [ref('/project/new.dart')]);
    expect(view.expanded, isEmpty);
    expect(view.treeSet, isTrue);
    expect(app.snapshots.last['a']!.treeSet, isTrue);
    expect(app.notifications, notifications, reason: 'view writes must not notify the entire app');
  });

  test('failed view writes block switching and retry the newest snapshot', () async {
    await ws.selectProject('a');
    ws.openTab(fileTab('/project/one.dart'));
    app.failViews = true;
    await ws.selectProject('b');
    expect(ws.projectKey, 'a');
    expect(ws.viewSaveError, isNotNull);
    ws.openTab(fileTab('/project/two.dart'));
    app.failViews = false;
    await ws.selectProject('b');
    expect(ws.projectKey, 'b');
    expect(app.data.servers.single.workspace('a')!.view.files, hasLength(2));
    expect(ws.viewSaveError, isNull);
  });

  test('rapid project changes serialize, and duplicate folders are ignored', () async {
    await Future.wait([ws.selectProject('a'), ws.selectProject('b'), ws.selectProject(null)]);
    expect(ws.projectKey, '');
    await ws.selectProject('a');
    await ws.addFolder(ref('/project/'));
    expect(ws.project!.folders, hasLength(1));
    await ws.addFolder(ref('/project/src'));
    expect(ws.project!.folders, hasLength(2), reason: 'overlapping views are allowed, not new permissions');
    await ws.renameProject('   ');
    expect(ws.project!.name, 'Alpha');
  });

  test('deleting a project moves dirty buffers AND unrestored references to browser', () async {
    final saved = ref('/project/previous.dart');
    app.data.servers.single.workspace('a')!.view.files = [saved];
    await ws.selectProject('a');
    final dirty = fileTab('/project/current.dart')..dirty.value = true;
    ws.openTab(dirty);
    await ws.deleteProject();
    expect(ws.projectKey, '');
    expect(ws.tabs, contains(same(dirty)));
    expect(dirty.projects, {''});
    expect(dirty.dirty.value, isTrue);
    await ws.flushViews();
    expect(app.data.servers.single.browserView.files, containsAll([saved, dirty.file]));
    ws.restoreFiles((p) => fileTab(p.path));
    expect(ws.visibleTabs, hasLength(2));
    expect(app.data.servers.single.workspace('a'), isNull);
  });

  test('failed project deletion cannot mutate memberships or lose dirty tabs', () async {
    await ws.selectProject('a');
    final dirty = fileTab('/project/current.dart')..dirty.value = true;
    ws.openTab(dirty);
    app.failChanges = true;
    await ws.deleteProject();
    expect(ws.projectKey, 'a');
    expect(dirty.projects, {'a'});
    expect(dirty.dirty.value, isTrue);
  });

  test('async close is applied to the project that requested it', () async {
    await ws.selectProject('a');
    final tab = fileTab('/project/current.dart');
    final consent = Completer<bool>();
    tab.confirmClose = () => consent.future;
    ws.openTab(tab);
    final close = ws.closeTab(tab.id);
    await ws.selectProject('b');
    ws.openTab(fileTab('/other/new.txt'));
    consent.complete(true);
    expect(await close, isTrue);
    expect(ws.projectKey, 'b');
    expect(ws.activeId, 'file:home:/other/new.txt');
    await ws.flushViews();
    expect(app.data.servers.single.workspace('a')!.view.files, isEmpty);
    expect(app.data.servers.single.workspace('b')!.view.files, [ref('/other/new.txt')]);
  });

  test('concurrent close asks once and settles both callers without disposal races', () async {
    final current = fileTab('/project/close.dart');
    final consent = Completer<bool>();
    var asks = 0;
    current.confirmClose = () { asks++; return consent.future; };
    ws.openTab(current);
    final one = ws.closeTab(current.id), two = ws.closeTab(current.id);
    consent.complete(true);
    expect(await one, isTrue);
    expect(await two, isTrue);
    expect(asks, 1);
    expect(ws.tabs, isEmpty);
  });
  test('runtime-only tab activation does not repeatedly write an unchanged file-only view', () async {
    ws.openTab(EditorTab(id: 'term:one', title: 'one', icon: Icons.terminal, builder: (_) => const SizedBox()));
    ws.activate('term:one');
    await ws.flushViews();
    expect(app.viewWrites, 0);
    ws.setSideWidth(410);
    await ws.flushViews();
    expect(app.viewWrites, 1);
    ws.activate('term:one');
    await ws.flushViews();
    expect(app.viewWrites, 1);
  });

  test('groups, width and pins survive project switching and encrypted-view round trip', () async {
    await ws.selectProject('a');
    ws.restoreFiles((f) => fileTab(f.path));
    ws.openTab(fileTab('/project/a.dart'));
    ws.openTab(fileTab('/project/b.dart'));
    ws.arrangeEditors(EditorArrangement.rows);
    ws.setTabPlacement(TabPlacement.left);
    ws.setTabsWidth(250); ws.setSideWidth(420);
    ws.pinTab('file:home:/project/b.dart');
    await ws.selectProject('b');
    expect(ws.tabLayout.groups, hasLength(1));
    expect(ws.tabLayout.sideWidth, 300);
    await ws.selectProject('a');
    expect(ws.tabLayout.groups, hasLength(2));
    expect(ws.tabLayout.tabsWidth, 250);
    expect(ws.tabLayout.sideWidth, 420);
    await ws.flushViews();
    final other = Workspace(app, 'server');
    other.restoreFiles((f) => fileTab(f.path));
    expect(other.tabLayout.groups, hasLength(2));
    expect(other.tabLayout.placement, TabPlacement.left);
    expect(other.tabLayout.pinned, contains('file:home:/project/b.dart'));
    expect(other.focusedId, ws.focusedId);
    await other.flushViews(); other.dispose();
  });

  test('bulk close protects pinned tabs and stops after cancelling dirty prompt', () async {
    for (final name in ['a', 'b', 'c']) { ws.openTab(fileTab('/project/$name')); }
    final first = ws.tabs.first, second = ws.tabs[1];
    ws.pinTab(first.id);
    second.confirmClose = () async => false;
    await ws.closeTabs(ws.visibleTabs.map((t) => t.id));
    expect(ws.tabs, hasLength(3));
    expect(await ws.closeTab(first.id), isTrue, reason: 'explicitly closing a pinned tab is still allowed');
  });

  test('bulk close cannot continue into a different project after confirmation', () async {
    await ws.selectProject('a');
    ws.openTab(fileTab('/project/a')); ws.openTab(fileTab('/project/b'));
    final consent = Completer<bool>();
    ws.tabs.first.confirmClose = () => consent.future;
    final close = ws.closeTabs(ws.visibleTabs.map((t) => t.id));
    await ws.selectProject('b');
    ws.openTab(fileTab('/project/b'));
    consent.complete(true);
    await close;
    expect(ws.visibleTabs.single.id, 'file:home:/project/b');
  });
  test('late service reply from the old link cannot replace the reconnected capabilities', () async {
    final old = _SlowServices(), fresh = _SlowServices();
    final raceApp = _ReconnectApp(old);
    final workspace = Workspace(raceApp, 'server');
    raceApp.current = fresh;
    await raceApp.update((p) {});
    fresh.ready.complete({'services': [{'id': 'fresh', 'enabled': true}]});
    await Future<void>.delayed(Duration.zero);
    old.ready.complete({'services': [{'id': 'stale', 'enabled': true}]});
    await Future<void>.delayed(Duration.zero);
    expect(workspace.serviceInfo('fresh'), isNotNull);
    expect(workspace.serviceInfo('stale'), isNull);
    workspace.dispose(); raceApp.dispose();
  });
  test('bulk close stops even if a project is switched away and back while confirming', () async {
    await ws.selectProject('a');
    ws.openTab(fileTab('/project/a')); ws.openTab(fileTab('/project/b'));
    final consent = Completer<bool>();
    ws.tabs.first.confirmClose = () => consent.future;
    final close = ws.closeTabs(ws.visibleTabs.map((t) => t.id));
    await ws.selectProject('b');
    await ws.selectProject('a');
    consent.complete(true);
    await close;
    expect(ws.visibleTabs.single.id, 'file:home:/project/b');
  });
  test('bulk close does not close a replacement tab with the same ID', () async {
    ws.openTab(fileTab('/project/a')); ws.openTab(fileTab('/project/b'));
    final consent = Completer<bool>();
    ws.tabs.first.confirmClose = () => consent.future;
    final close = ws.closeTabs(ws.visibleTabs.map((t) => t.id));
    ws.dropTabs((t) => t.id == 'file:home:/project/b');
    final replacement = fileTab('/project/b');
    ws.openTab(replacement);
    consent.complete(true);
    await close;
    expect(ws.tabs, [replacement]);
  });
}
