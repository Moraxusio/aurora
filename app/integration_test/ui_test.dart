// UI against a real aurora3-agent (agent/tools/ui-agent.sh, started by
// app/tool/ui_test.ps1). The profile is a temporary file sealed with the
// real DPAPI, and the server entry is written directly (the SSH install is
// covered by agent/tools/install-e2e.ps1). Each page is opened and must
// show the agent's data: monitor, files, services, terminal.
//   flutter test integration_test/ui_test.dart -d windows
//     --dart-define=AURORA3_UI_ADDR=.. AURORA3_UI_PIN=.. AURORA3_UI_TOKEN=..
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:aurora/main.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView;

const addr = String.fromEnvironment('AURORA3_UI_ADDR');
const pin = String.fromEnvironment('AURORA3_UI_PIN');
const token = String.fromEnvironment('AURORA3_UI_TOKEN');

Future<void> settle(WidgetTester t, {Duration upTo = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(upTo);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> waitFor(WidgetTester t, Finder f, {Duration upTo = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(upTo);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('not found within $upTo: $f');
}

/// Switches tab and waits for the tab animation, so taps land on the new tab.
Future<void> tab(WidgetTester t, String name) async {
  await t.tap(find.descendant(of: find.byType(TabBar), matching: find.text(name)));
  await settle(t, upTo: const Duration(milliseconds: 600));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pages show a real agent', (t) async {
    // No filter for text input errors: "view ID is null" from the engine was
    // the bug that kept typed characters out of the terminal.
    expect(addr, isNotEmpty, reason: 'run through app/tool/ui_test.ps1');
    final ep = {'addr': addr, 'pin': pin, 'token': token};
    final dir = await Directory.systemTemp.createTemp('aurora3-ui-');
    addTearDown(() => dir.delete(recursive: true));
    final store = await ProfileStore.open('${dir.path}\\profile.bin', DpapiSealer());
    await store.update((p) {
      final s = ServerEntry.create('wsl-ui', ssh: SshLogin(host: '127.0.0.1', user: 'root'));
      s.direct = DirectParams(port: 17791, addrs: [ep['addr'] as String], pin: ep['pin'] as String, token: ep['token'] as String);
      p.servers.add(s);
      p.selected = s.id;
    });
    await store.close();
    final app = AppState();
    await app.initAt('${dir.path}\\profile.bin');
    await t.pumpWidget(AuroraApp(app: app));

    // Connected, with the agent's version in the header.
    await waitFor(t, find.textContaining('已连接'));
    expect(find.textContaining('agent 3.0.1'), findsOneWidget);

    // Terminal: no session yet; create one through the dialog.
    await waitFor(t, find.text('新建会话'));
    await t.tap(find.widgetWithText(FilledButton, '新建会话'));
    await settle(t, upTo: const Duration(milliseconds: 500));
    await t.tap(find.widgetWithText(FilledButton, '新建'));
    await waitFor(t, find.widgetWithText(ChoiceChip, 'main'));

    // The terminal's size reached tmux: the shell sees the view's columns,
    // not the 80 it attached with.
    final term = find.byType(TerminalView);
    await waitFor(t, term);
    final view = t.widget<TerminalView>(term);
    final cols = view.terminal.viewWidth;
    expect(cols, greaterThan(80), reason: 'the test window is wider than 80 columns');
    // tmux had the real size from the start: the date at the right end of
    // its status line sits in the last columns of the view, not at 80.
    await waitFor(t, find.byWidgetPredicate((_) => _screen(view.terminal).contains('\$')));
    final status = view.terminal.buffer.lines[0];
    var last = 0;
    for (var x = 0; x < status.length; x++) {
      if (status.getCodePoint(x) > 32) last = x;
    }
    expect(last, greaterThan(cols - 4), reason: 'status line ends at column $last of $cols');
    // The shell's output split in the typed command, so only the answer
    // matches. Asked again until it shows: the first prompt may still be
    // drawing when the keys arrive.
    var seen = '';
    for (var i = 0; i < 30 && !seen.contains('COL=$cols='); i++) {
      if (i % 10 == 0) view.terminal.textInput('echo CO""L=\$(tput cols)=\r');
      await settle(t, upTo: const Duration(milliseconds: 300));
      seen = _screen(view.terminal);
    }
    expect(seen, contains('COL=$cols='), reason: 'view is $cols columns; screen:\n${seen.trimRight()}');

    // Typing on the real keyboard path: Windows key messages into this
    // window, through the engine's text input to the terminal. ASCII comes
    // as key presses, the Chinese as Unicode packets, as an IME sends them.
    await typeKeys(t, r'echo TYPED-中文-$((6*7))' '\n');
    await waitFor(t, find.byWidgetPredicate((_) => _screen(view.terminal).contains('TYPED-中文-42')),
        upTo: const Duration(seconds: 10));

    // Files: the root and the test folder.
    await tab(t, '文件');
    await waitFor(t, find.widgetWithText(ListTile, 'docs'));
    await t.tap(find.widgetWithText(ListTile, 'docs'));
    await waitFor(t, find.text('readme.txt'));

    // Switching away and back keeps the folder (and the terminal).
    await tab(t, '终端');
    expect(identical(t.widget<TerminalView>(term).terminal, view.terminal), isTrue, reason: 'terminal kept');
    await tab(t, '文件');
    expect(find.text('readme.txt'), findsOneWidget, reason: 'still in docs');
    await t.tap(find.byTooltip('上一级'));
    await waitFor(t, find.widgetWithText(ListTile, 'docs'));

    // Monitor: CPU and memory cards fill in after two samples.
    await tab(t, '监控');
    await waitFor(t, find.textContaining(' %'), upTo: const Duration(seconds: 10));
    expect(find.text('内存'), findsWidgets); // the card and the process table column
    await waitFor(t, find.text('进程（按 CPU 排序）'));

    // Services: the switches the agent reports.
    await tab(t, '服务');
    await waitFor(t, find.widgetWithText(SwitchListTile, '终端'));
    expect(find.widgetWithText(SwitchListTile, '文件'), findsOneWidget);

    // Overview shows the pin.
    await tab(t, '概览');
    await waitFor(t, find.text(ep['pin'] as String));

    // Screenshots for review, when asked for (AURORA3_UI_SHOTS=dir).
    const shots = String.fromEnvironment('AURORA3_UI_SHOTS');
    if (shots.isNotEmpty) {
      for (final name in ['终端', '文件', '监控', '服务', '概览']) {
        await tab(t, name);
        await settle(t, upTo: const Duration(seconds: 3));
        await shot(t, '$shots\\$name.png');
      }
      // The add-server page, as a user opens it.
      await t.tap(find.text('添加服务器'));
      await settle(t, upTo: const Duration(seconds: 1));
      await shot(t, '$shots\\添加服务器.png');
      await t.tap(find.byType(BackButton));
      await settle(t, upTo: const Duration(milliseconds: 600));
    }

    await app.disconnect(app.profile.servers.first.id);
    await settle(t, upTo: const Duration(milliseconds: 300));
  });
}

const sendKeys = String.fromEnvironment('AURORA3_UI_SENDKEYS');

/// Types [text] into this process's window with app/tool/sendkeys.ps1,
/// pumping frames meanwhile so the app handles the keys as they come.
Future<void> typeKeys(WidgetTester t, String text) async {
  expect(sendKeys, isNotEmpty, reason: 'run through app/tool/ui_test.ps1');
  final p = await Process.start('powershell', ['-NoProfile', '-File', sendKeys, '-ProcessId', '$pid', '-Base64', base64.encode(utf8.encode(text))]);
  final err = StringBuffer();
  p.stderr.transform(utf8.decoder).listen(err.write);
  p.stdout.drain<void>();
  int? code;
  unawaited(p.exitCode.then((c) => code = c));
  while (code == null) {
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(code, 0, reason: 'sendkeys: $err');
}

/// The terminal's whole buffer as text.
String _screen(Terminal term) {
  final b = term.buffer;
  final out = StringBuffer();
  for (var i = 0; i < b.lines.length; i++) {
    out.writeln(b.lines[i].toString());
  }
  return out.toString();
}

/// Writes the window's current frame as a PNG. The root layer is in physical
/// pixels (the view's transform scales by the device pixel ratio), so the
/// logical size is scaled back and the image taken at ratio 1: the whole
/// window, at its real resolution.
Future<void> shot(WidgetTester t, String path) async {
  final ro = t.binding.renderViews.first;
  final layer = ro.debugLayer as OffsetLayer;
  final physical = ro.flutterView.physicalSize;
  final img = await layer.toImage(Offset.zero & physical);
  final png = await img.toByteData(format: ImageByteFormat.png);
  await File(path).writeAsBytes(png!.buffer.asUint8List());
}
