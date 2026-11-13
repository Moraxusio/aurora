import 'dart:math';

import 'package:aurora/kernel/tab_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void invariants(TabLayout layout, Set<String> expected) {
  expect(layout.groups.length, inInclusiveRange(1, TabLayout.maxGroups));
  expect(layout.ordered.toSet(), expected);
  expect(
    layout.ordered.length,
    expected.length,
    reason: 'never duplicate or lose a live document',
  );
  expect(layout.groups.map((g) => g.id).toSet().length, layout.groups.length);
  expect(layout.groups.map((g) => g.id), contains(layout.focused));
  for (final g in layout.groups) {
    expect(
      g.active == null ? g.tabs.isEmpty : g.tabs.contains(g.active),
      isTrue,
    );
    var normalSeen = false;
    for (final id in g.tabs) {
      if (!layout.pinned.contains(id)) normalSeen = true;
      if (normalSeen) expect(layout.pinned.contains(id), isFalse);
    }
  }
  final leaves = <String>[];
  void visit(TabNode node) {
    if (node is TabLeaf) {
      leaves.add(node.group);
      return;
    }
    final s = node as TabSplit;
    expect(s.ratio.isFinite, isTrue);
    expect(s.ratio, inInclusiveRange(.15, .85));
    visit(s.first);
    visit(s.second);
  }

  visit(layout.root);
  expect(leaves.toSet(), layout.groups.map((g) => g.id).toSet());
  expect(leaves.length, layout.groups.length);
}

void main() {
  test(
    'presets retain order, active document and pin state without duplication',
    () {
      final layout = TabLayout();
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) {
        layout.add(id);
      }
      layout.togglePin('b');
      for (final preset in EditorArrangement.values) {
        layout.arrange(preset);
        expect(layout.current.active, 'f');
        expect(layout.pinned, {'b'});
        invariants(layout, {'a', 'b', 'c', 'd', 'e', 'f'});
      }
    },
  );
  test('single document can create an empty split, merge never closes it', () {
    final l = TabLayout()..add('shell');
    final group = l.split(l.current.id, SplitAxis.vertical, tab: 'shell')!;
    expect(l.groups.first.tabs, isEmpty);
    expect(l.current.id, group);
    l.mergeGroup(group);
    invariants(l, {'shell'});
  });
  test('reordering uses insertion slots and keeps fixed tabs at the front', () {
    final l = TabLayout();
    for (final id in ['a', 'b', 'c']) {
      l.add(id);
    }
    l.move('a', l.current.id, index: 3);
    expect(l.ordered, ['b', 'c', 'a']);
    l.togglePin('a');
    l.move('c', l.current.id, index: 0);
    expect(l.ordered, ['a', 'c', 'b']);
    l.move('a', l.current.id, index: 3);
    expect(l.ordered, ['a', 'c', 'b']);
  });
  test('moving last document merges source without changing target focus', () {
    final l = TabLayout()
      ..add('a')
      ..add('b');
    l.arrange(EditorArrangement.columns);
    final destination = l.groups.first.id;
    l.move('b', destination);
    expect(l.groups, hasLength(1));
    expect(l.current.active, 'b');
    invariants(l, {'a', 'b'});
  });
  test('profile snapshot filters runtime-only tasks, restores ratios and positions', () {
    final l = TabLayout()
      ..add('file:a')
      ..add('term:live')
      ..add('file:b');
    l.arrange(EditorArrangement.rows);
    l.placement = TabPlacement.right;
    l.tabsWidth = 240;
    l.togglePin('file:b');
    l.resizeSplit((l.root as TabSplit).id, .65);
    final snapshot = l.toJson(allowed: {'file:a', 'file:b'});
    expect(snapshot.toString(), isNot(contains('term:live')));
    final back = TabLayout.fromJson(snapshot, ['file:a', 'file:b']);
    expect(back.placement, TabPlacement.right);
    expect(back.tabsWidth, 240);
    expect((back.root as TabSplit).ratio, .65);
    expect(back.current.active, 'file:b');
    invariants(back, {'file:a', 'file:b'});
  });
  test('malformed view falls back safely and clamps nonfinite dimensions', () {
    final l = TabLayout.fromJson(
      {
        'groups': List.filled(100, {}),
        'side_width': double.infinity,
        'tabs_width': -400,
        'tab_width': 10000,
        'placement': 'unknown',
      },
      ['a'],
    );
    expect(l.sideWidth, 300);
    expect(l.tabsWidth, 120);
    expect(l.tabWidth, 260);
    expect(l.placement, TabPlacement.top);
    invariants(l, {'a'});
  });
  test('randomized split, move, pin, remove and snapshot operations preserve invariants', () {
    final random = Random(81), ids = <String>{};
    var l = TabLayout();
    for (var i = 0; i < 1200; i++) {
      final id = 't${random.nextInt(25)}';
      switch (random.nextInt(7)) {
        case 0:
          ids.add(id);
          l.add(id);
        case 1:
          l.remove(id);
          ids.remove(id);
        case 2:
          l.togglePin(id);
        case 3:
          l.arrange(EditorArrangement.values[random.nextInt(5)]);
        case 4:
          l.move(
            id,
            l.groups[random.nextInt(l.groups.length)].id,
            index: random.nextInt(30),
          );
        case 5:
          l.split(
            l.current.id,
            random.nextBool() ? SplitAxis.horizontal : SplitAxis.vertical,
            tab: ids.contains(id) ? id : null,
          );
        case 6:
          l = TabLayout.fromJson(l.toJson(), ids);
      }
      invariants(l, ids);
    }
  });
}
