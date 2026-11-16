import 'package:aurora/features/files/document_merge.dart';
import 'package:aurora/kernel/document_model.dart';
import 'package:aurora/kernel/document_recovery.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Link extends Fake implements Link {
  @override
  AgentInfo get server => AgentInfo({'caps': <String>[]});
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async => {'content': 'disk version', 'etag': 'disk-etag'};
}

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'merge fits $width at enlarged text scale and remains undoable',
      (t) async {
        t.view.physicalSize = Size(width, 740);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final input = InputMode(touch: width < 500);
        final link = _Link();
        final doc = DocumentModel(
          DocumentKey('server', 'home', '/file'),
          () => link,
          MemoryDocumentRecoveryStore(),
        );
        await doc.load();
        doc.replaceText('my edit', expectedVersion: doc.version);
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.dark),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: InputMode.scope(
              mode: input,
              child: Builder(
                builder: (c) => Scaffold(
                  body: TextButton(
                    onPressed: () => showDocumentMerge(c, doc),
                    child: const Text('compare'),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('compare'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.enterText(
          find.byKey(const ValueKey('document-merge-result')),
          'merged',
        );
        await t.tap(find.text('接受合并到编辑器'));
        await t.pumpAndSettle();
        expect(doc.text, 'merged');
        expect(doc.dirty, isTrue);
        doc.controller.undo();
        expect(doc.text, 'my edit');
        await doc.close();
        await t.pumpWidget(const SizedBox());
        input.dispose();
      },
    );
  }
}
