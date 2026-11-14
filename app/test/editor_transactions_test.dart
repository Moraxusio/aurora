import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/editor_grid_geometry.dart';
import 'package:aurora/kernel/tab_drag.dart';
import 'package:aurora/kernel/tab_layout.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';
import 'tab_layout_test.dart' show invariants;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'dragging the sole document onto its own edge cannot make an empty group',
    () {
      final layout = TabLayout()..add('a');
      for (final edge in TabDropEdge.values) {
        expect(layout.drop('a', layout.focused, edge), isFalse);
      }
      expect(layout.groups, hasLength(1));
      invariants(layout, {'a'});
    },
  );
  test(
    'edge drop of another groups last document moves that group atomically',
    () {
      final layout = TabLayout()
        ..add('a')
        ..add('b')
        ..add('c');
      final group = layout.split(
        layout.focused,
        SplitAxis.horizontal,
        tab: 'c',
      )!;
      final source = layout.group(group)!;
      expect(
        layout.drop('c', layout.groups.first.id, TabDropEdge.bottom),
        isTrue,
      );
      expect(layout.groups, hasLength(2));
      expect(layout.owner('c'), same(source));
      expect(layout.groups.every((g) => g.tabs.isNotEmpty), isTrue);
      expect((layout.root as TabSplit).axis, SplitAxis.vertical);
      invariants(layout, {'a', 'b', 'c'});
    },
  );
  test('pane geometry compresses continuously instead of switching every other group off', () {
    final layout = TabLayout()..arrange(EditorArrangement.threeColumns);
    for (final width in [1200.0, 800.0, 790.0, 780.0, 750.0, 700.0, 600.0]) {
      final geometry = EditorGridGeometry(layout, Size(width, 700));
      expect(geometry.groups, hasLength(3));
      final rects = geometry.groups.values.toList();
      for (var i = 0; i < rects.length; i++) {
        expect(rects[i].width, greaterThan(0));
        expect(rects[i].right, lessThanOrEqualTo(width + .001));
        for (final next in rects.skip(i + 1)) {
          expect(rects[i].overlaps(next), isFalse);
        }
      }
    }
  });
  test(
    'drop policy rejects stale structural transactions and task panels',
    () async {
      final app = WorkspaceApp(), ws = Workspace(WorkspaceApp(), 'server');
      EditorTab tab(String id) => EditorTab(
        id: id,
        title: id,
        icon: Icons.description,
        builder: (_) => const SizedBox(),
      );
      ws.openTab(tab('a'));
      ws.openTab(tab('b'));
      final drag = TabDragData(ws, ws.tab('a')!);
      expect(
        TabDropPolicy.resolve(
          drag,
          ws,
          ws.tabLayout.focused,
          const Size(900, 700),
          const Offset(450, 350),
        ),
        isNull,
      );
      expect(
        TabDropPolicy.resolve(
          drag,
          ws,
          ws.tabLayout.focused,
          const Size(900, 700),
          const Offset(890, 350),
        ),
        TabDropEdge.right,
      );
      ws.arrangeEditors(EditorArrangement.rows);
      expect(drag.valid(ws), isFalse);
      ws.openTab(tab('ai:new'));
      expect(ws.tabLayout.owner('ai:new'), isNull);
      expect(TabDragData(ws, ws.tab('ai:new')!).valid(ws), isFalse);
      await ws.flushViews();
      ws.dispose();
      ws.app.dispose();
      app.dispose();
    },
  );
}
