// Renders the window to PNG files for a look at the design (D-103). Runs only
// when AURORA_SHOTS names an output folder, and needs the Windows fonts:
//   AURORA_SHOTS=C:\build\shots flutter test test/ui_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

final _out = Platform.environment['AURORA_SHOTS'];
final _shot = GlobalKey();

const _code = '''// The agent's entry point.
package main

import (
	"context"
	"log"
	"os/signal"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx); err != nil {
		log.Fatal(err)
	}
}
''';

/// Every feature's service on, with every operation it asks for.
class ShotLink extends FileTreeLink {
  final Features features;
  ShotLink(this.features);

  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    switch (op) {
      case 'agent.services':
        final ops = <String, Set<String>>{};
        for (final f in features.all) {
          ops.putIfAbsent(f.service, () => {}).addAll(f.ops);
        }
        return {
          'services': [
            for (final e in ops.entries) {'id': e.key, 'enabled': true, 'available': true, 'ops': e.value.toList()},
          ],
        };
      case 'fs.read':
        return {'content': _code, 'etag': 'e1', 'size': _code.length};
      case 'session.list':
        return {'sessions': <Object>[]};
    }
    try {
      return await super.call(op, args ?? const {}, timeout);
    } on OpError {
      rethrow;
    } on Object {
      throw OpError(codeNotFound, 'not in the fixture');
    }
  }
}

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    final file = File(f);
    if (file.existsSync()) l.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await l.load();
}

void main() {
  setUpAll(() async {
    if (_out == null) return;
    const w = r'C:\Windows\Fonts\';
    await _font(Ide.ui, ['${w}SegUIVar.ttf']);
    await _font('Segoe UI', ['${w}segoeui.ttf', '${w}segoeuib.ttf', '${w}seguisb.ttf']);
    await _font('Microsoft YaHei UI', ['${w}msyh.ttc', '${w}msyhbd.ttc']);
    await _font('Cascadia Mono', ['${w}CascadiaMono.ttf']);
    await _font('MaterialIcons', [r'C:\dev\VPS\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf']);
    Directory(_out!).createSync(recursive: true);
  });

  Future<void> snap(WidgetTester t, String name) async {
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 120));
    }
    final b = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
    await t.runAsync(() async {
      final img = await b.toImage(pixelRatio: t.view.devicePixelRatio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<(Features, WorkspaceApp, InputMode)> open(WidgetTester t, Size size, Brightness b, {bool touch = false}) async {
    t.view.devicePixelRatio = 1.5;
    t.view.physicalSize = size * 1.5;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final features = Features();
    final app = WorkspaceApp(wire: ShotLink(features));
    app.data.servers.single.name = 'tokyo-dev';
    app.data.servers.single.selectedWorkspace = 'a';
    final input = InputMode(touch: touch);
    await t.pumpWidget(RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        home: InputMode.scope(mode: input, child: Shell(app: app, features: features)),
      ),
    ));
    await t.runAsync(() => precacheImage(const AssetImage('assets/branding/aurora3-256.png'), t.element(find.byType(Shell))));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    return (features, app, input);
  }

  Future<void> close(WidgetTester t, (Features, WorkspaceApp, InputMode) s) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
    s.$1.dispose();
    s.$3.dispose();
    s.$2.dispose();
  }

  Future<void> files(WidgetTester t, Features f) async {
    await t.tap(find.byTooltip(f.byId('files')!.title).first);
    await t.pump(const Duration(milliseconds: 300));
  }

  for (final b in Brightness.values) {
    final tag = b == Brightness.dark ? 'dark' : 'light';
    testWidgets('wide $tag', (t) async {
      final s = await open(t, const Size(1440, 900), b);
      await snap(t, '$tag-1-welcome');
      await files(t, s.$1);
      await snap(t, '$tag-2-files');
      for (final name in ['src', 'main.dart', 'README.md']) {
        final row = find.text(name);
        if (row.evaluate().isEmpty) continue;
        await t.tap(row.first);
        await t.pump(const Duration(milliseconds: 300));
      }
      await snap(t, '$tag-3-editor');
      await t.tap(find.byTooltip('命令面板（Ctrl+Shift+P）').first);
      await snap(t, '$tag-4-palette');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byTooltip('切换服务器').first);
      await snap(t, '$tag-5-servers');
      await close(t, s);
    }, skip: _out == null);
  }

  testWidgets('medium dark', (t) async {
    final s = await open(t, const Size(820, 700), Brightness.dark);
    await snap(t, 'dark-6-medium');
    await files(t, s.$1);
    await snap(t, 'dark-7-medium-drawer');
    await close(t, s);
  }, skip: _out == null);

  testWidgets('phone dark', (t) async {
    final s = await open(t, const Size(400, 820), Brightness.dark, touch: true);
    await snap(t, 'dark-8-phone');
    await close(t, s);
  }, skip: _out == null);

  testWidgets('no server', (t) async {
    t.view.devicePixelRatio = 1.5;
    t.view.physicalSize = const Size(1200, 760) * 1.5;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final features = Features();
    final app = WorkspaceApp()..data.servers.clear();
    final input = InputMode(touch: false);
    await t.pumpWidget(RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark),
        home: InputMode.scope(mode: input, child: Shell(app: app, features: features)),
      ),
    ));
    await t.runAsync(() => precacheImage(const AssetImage('assets/branding/aurora3-256.png'), t.element(find.byType(Shell))));
    await snap(t, 'dark-9-empty');
    await close(t, (features, app, input));
  }, skip: _out == null);
}
