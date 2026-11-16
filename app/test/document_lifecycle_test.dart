import 'dart:io';

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/kernel/desktop_lifecycle.dart';
import 'package:aurora/kernel/document_recovery.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'support/workspace_fixture.dart';

class _Store extends MemoryDocumentRecoveryStore {
  bool fail = false;
  @override
  Future<void> save(DocumentRecovery recovery) async {
    if (fail) throw const FileSystemException('disk full');
    await super.save(recovery);
  }
}

class _App extends WorkspaceApp {
  final DocumentRecoveryStore recovery;
  _App(this.recovery);
  @override
  DocumentRecoveryStore get documentRecovery => recovery;
}

void main() {
  testWidgets(
    'recreating an editor preserves the controller, selection and undo history',
    (t) async {
      final app = WorkspaceApp(wire: FileTreeLink());
      final ws = Workspace(app, 'server');
      final input = InputMode(touch: false);
      Future<void> mount() async {
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: InputMode.scope(
              mode: input,
              child: Scaffold(
                body: FileEditor(
                  ws: ws,
                  root: 'home',
                  path: '/project/main.dart',
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      await mount();
      final doc = ws.documents.find('home', '/project/main.dart')!;
      final controller = doc.controller;
      doc.replaceText('unsaved text', expectedVersion: doc.version);
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 5,
      );
      await t.pumpWidget(const SizedBox());
      await mount();
      expect(doc.controller, same(controller));
      expect(doc.text, 'unsaved text');
      expect(controller.selection.extentOffset, 5);
      controller.undo();
      expect(doc.text, 'synthetic original\n');
      controller.redo();
      expect(doc.text, 'unsaved text');
      await ws.documents.flush();
      await t.pumpWidget(const SizedBox());
      ws.dispose();
      await t.pumpAndSettle();
      app.dispose();
      input.dispose();
    },
  );

  testWidgets(
    'offline shell opens orphan recovery and hot exit retries a failed checkpoint',
    (t) async {
      final store = _Store();
      final key = DocumentKey('server', 'home', '/project/recovered.dart');
      await store.save(
        DocumentRecovery(
          key: key,
          text: 'unsaved from last launch',
          baseText: 'original',
          etag: 'old',
          version: 9,
          line: 0,
          column: 7,
          updatedAt: 1,
        ),
      );
      final app = _App(store);
      final input = InputMode(touch: false);
      final features = Features();
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: InputMode.scope(
            mode: input,
            child: Shell(app: app, features: features),
          ),
        ),
      );
      await t.pumpAndSettle();
      final ws =
          (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;
      final doc = ws.documents.find('home', '/project/recovered.dart')!;
      expect(doc.text, 'unsaved from last launch');
      expect(doc.controller.selection.extentOffset, 7);
      expect(find.text('已恢复上次未保存的编辑内容'), findsOneWidget);
      doc.replaceText('new offline edit', expectedVersion: doc.version);
      store.fail = true;
      expect(await DesktopLifecycle.beforeExit!(), isFalse);
      expect(doc.text, 'new offline edit');
      expect(doc.dirty, isTrue);
      store.fail = false;
      expect(await DesktopLifecycle.beforeExit!(), isTrue);
      expect(store.entries[key]!.text, 'new offline edit');
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      features.dispose();
      input.dispose();
      app.dispose();
    },
  );
}
