import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/files/file_tree_row.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/theme/workbench_scale.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';
import 'workbench_visual_test.dart' show VisualWorkbenchLink;

void main() {
  for (final scale in [1.0, 1.25, 1.5]) {
    testWidgets('sidebar follows every pointer pixel including same-frame bursts at $scale zoom', (t) async {
      t.view.physicalSize = const Size(2100, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final features = Features(), input = InputMode(touch: false), shell = GlobalKey();
      final app = WorkspaceApp(wire: VisualWorkbenchLink(features));
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: WorkbenchScale(scale: scale,
        child: InputMode.scope(mode: input, child: Shell(key: shell, app: app, features: features)))));
      await t.pumpAndSettle();
      final ws = (shell.currentState as dynamic).debugWorkspace as Workspace;
      ws.openTab(fileEditorTab(ws, root: 'home', path: '/project/src/main.dart'));
      ws.openTab(EditorTab(id: 'ai:fixture', title: 'AI', icon: Icons.chat, builder: (_) => const Text('retained conversation')));
      await t.pumpAndSettle();
      final treeState = t.state(find.byType(FileEditor));
      var businessNotices = 0;
      void changed() => businessNotices++;
      ws.addListener(changed);
      for (final key in ['sidebar-resize', 'assistant-panel-resize']) {
        final handle = find.byKey(ValueKey(key));
        final start = t.getCenter(handle);
        final gesture = await t.startGesture(start, kind: PointerDeviceKind.mouse);
        await gesture.moveTo(start + const Offset(1, 0));
        await t.pump();
        expect(t.getCenter(handle).dx, closeTo(start.dx + 1, .01), reason: 'no drag slop or double-click delay');
        for (var batch = 1; batch <= 4; batch++) {
          for (var i = 1; i <= 10; i++) {
            await gesture.moveTo(start + Offset(batch * 10.0 + i, 0));
          }
          await t.pump();
          expect(t.getCenter(handle).dx, closeTo(start.dx + batch * 10 + 10, .01), reason: 'events between frames cannot overwrite each other');
        }
        await gesture.moveTo(start - const Offset(30, 0));
        await t.pump();
        expect(t.getCenter(handle).dx, closeTo(start.dx - 30, .01));
        await gesture.moveTo(start + const Offset(1500, 0));
        await t.pump();
        await gesture.moveTo(start + const Offset(15, 0));
        await t.pump();
        expect(t.getCenter(handle).dx, closeTo(start.dx + 15, .01), reason: 'reversing after a size limit must not drift');
        await gesture.up();
        await t.pump();
      }
      expect(businessNotices, 0);
      expect(t.state(find.byType(FileEditor)), same(treeState));
      // The root folder follows the single header directly, without a second
      // toolbar or selected-path strip growing above the tree.
      final header = t.getRect(find.byKey(const ValueKey('project-switcher')));
      final root = t.getRect(find.byType(FileTreeRow).first);
      expect(root.top - header.top, lessThanOrEqualTo(36 * scale));
      expect(t.takeException(), isNull);
      ws.removeListener(changed);
      await ws.flushViews();
      await t.pumpWidget(const SizedBox());
      app.dispose(); input.dispose(); features.dispose();
    });
  }
}
