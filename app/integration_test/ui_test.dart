// The whole client against a real aurora3-agent (agent/tools/ui-agent.sh,
// started by app/tool/ui_test.ps1): normal user, /tmp, a git repository with
// a modified and an untracked file, and a TCP service to forward. The profile
// is a temporary file sealed with the real DPAPI; the server entry is written
// directly (the SSH install is covered by agent/tools/install-e2e.ps1).
// Every feature is used through the window the way a person would:
//   terminal   typing on the real Windows input path, Chinese included
//   files      the tree, the editor, saving, and a save refused after
//              another program changed the file
//   git        changes, a diff, staging, committing, history
//   systemd    the unit list
//   net        a forward opened from the list, with bytes through it
//   layout     wide, medium and narrow windows
//   flutter test integration_test/ui_test.dart -d windows
//     --dart-define=AURORA3_UI_ADDR=.. AURORA3_UI_PIN=.. AURORA3_UI_TOKEN=..
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/main.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView;

import 'helpers.dart';
import 'input_watch.dart';

const addr = String.fromEnvironment('AURORA3_UI_ADDR');
const pin = String.fromEnvironment('AURORA3_UI_PIN');
const token = String.fromEnvironment('AURORA3_UI_TOKEN');
const shots = String.fromEnvironment('AURORA3_UI_SHOTS');
const typingLines = int.fromEnvironment('AURORA3_UI_TYPING_LINES', defaultValue: 6);
const stopAfterTyping = bool.fromEnvironment('AURORA3_UI_STOP_AFTER_TYPING');
/// For checking the watcher itself: at this line a window of another program takes the focus (-1: never).
const disturbAtLine = int.fromEnvironment('AURORA3_UI_DISTURB_AT_LINE', defaultValue: -1);

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

Future<void> waitUntil(WidgetTester t, bool Function() ok, String what, {Duration upTo = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(upTo);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (ok()) return;
  }
  throw TestFailure('did not happen within $upTo: $what');
}

/// A mouse click on the first match. flutter_test's own tap is a touch, which
/// would switch the window to touch mode (bigger rows, the key bar).
Future<void> click(WidgetTester t, Finder f) async {
  final at = t.getCenter(f.first);
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: at);
  await g.down(at);
  await t.pump();
  await g.up();
  await g.removePointer();
  await t.pump();
}

/// Shows a feature's side bar. A click on the icon of the feature that is
/// already open hides the side bar (as in an IDE), so the icon is tapped only
/// when the side bar does not already show [title].
Future<void> activity(WidgetTester t, String tooltip, {required String title}) async {
  final shown = find.text(title.toUpperCase());
  if (shown.evaluate().isEmpty) {
    await click(t, find.byTooltip(tooltip).first);
    await settle(t, upTo: const Duration(milliseconds: 500));
  }
  expect(shown, findsOneWidget, reason: 'the $tooltip side bar is shown');
}

/// A window of another program comes to the front for a moment, as a window
/// the user clicked would (app/tool/focus_thief.ps1, a real window).
Future<void> _stealFocus(WidgetTester t) async {
  final script = sendKeys.replaceAll('sendkeys.ps1', 'focus_thief.ps1');
  final p = await Process.start('powershell', ['-NoProfile', '-File', script, '-Seconds', '2']);
  p.stdout.drain<void>();
  p.stderr.drain<void>();
  for (var i = 0; i < 35; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  p.kill();
}

String _screen(Terminal term) {
  final b = term.buffer;
  final out = StringBuffer();
  for (var i = 0; i < b.lines.length; i++) {
    out.writeln(b.lines[i].toString());
  }
  return out.toString();
}

/// The whole window's current frame as a PNG (physical pixels).
Future<void> shot(WidgetTester t, String name) async {
  if (shots.isEmpty) return;
  final ro = t.binding.renderViews.first;
  final layer = ro.debugLayer as OffsetLayer;
  final img = await layer.toImage(Offset.zero & ro.flutterView.physicalSize);
  final png = await img.toByteData(format: ImageByteFormat.png);
  await File('$shots\\$name.png').writeAsBytes(png!.buffer.asUint8List());
}

/// Runs a command in WSL as the normal user (the same machine the agent is on).
Future<String> wsl(String script) async {
  final r = await Process.run('wsl', ['-d', 'Ubuntu-24.04', '--', 'sh', '-c', script]);
  return '${r.stdout}${r.stderr}'.trim();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every feature, through the window', (t) async {
    // No filter for text input errors: "view ID is null" from the engine was
    // the bug that kept typed characters out of the terminal.
    expect(addr, isNotEmpty, reason: 'run through app/tool/ui_test.ps1');
    t.view.physicalSize = const Size(1700, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    final dir = await Directory.systemTemp.createTemp('aurora3-ui-');
    addTearDown(() => dir.delete(recursive: true));
    final store = await ProfileStore.open('${dir.path}\\profile.bin', DpapiSealer());
    await store.update((p) {
      final s = ServerEntry.create('wsl-ui', ssh: SshLogin(host: '127.0.0.1', user: 'root'));
      s.direct = DirectParams(port: 17791, addrs: [addr], pin: pin, token: token);
      p.servers.add(s);
      p.selected = s.id;
    });
    await store.close();
    final app = AppState();
    await app.initAt('${dir.path}\\profile.bin');
    await t.pumpWidget(AuroraApp(app: app));

    // ---- connection ----
    await waitFor(t, find.textContaining('127.0.0.1:17791'), upTo: const Duration(seconds: 20)); // status bar
    expect(find.textContaining('wsl-ui'), findsWidgets);
    await shot(t, '01-welcome');

    // ---- terminal ----
    await activity(t, '终端', title: '终端会话');
    await waitFor(t, find.text('新建会话'));
    await click(t, find.widgetWithText(OutlinedButton, '新建会话'));
    await settle(t, upTo: const Duration(milliseconds: 600));
    await click(t, find.widgetWithText(FilledButton, '创建'));
    await waitFor(t, find.byType(TerminalView));
    final view = t.widget<TerminalView>(find.byType(TerminalView));
    final cols = view.terminal.viewWidth;
    expect(cols, greaterThan(80), reason: 'the terminal uses the whole editor area, not 80 columns');
    await waitUntil(t, () => _screen(view.terminal).contains('\$'), 'the shell prompt');
    // typing on the real keyboard path: ASCII as key presses, Chinese as
    // Unicode packets as an IME sends them
    // Typing on the real keyboard path: Windows key messages into this
    // window, through the engine's text input to the terminal. ASCII comes as
    // key presses, the Chinese as Unicode packets, as an IME sends them. Six
    // lines, each checked as typed (nothing in front of it) and as run.
    String tail() => _screen(view.terminal).trimRight().split('\n').reversed.take(8).toList().reversed.join('\n');
    // What xterm hands over for each line, recorded in front of the session's
    // own handler: a character missing here was lost before the connection (the
    // window, the engine, xterm); one that is here but not on the screen was
    // lost after it (the stream, the agent, tmux).
    final emitted = StringBuffer();
    final handler = view.terminal.onOutput;
    view.terminal.onOutput = (d) {
      emitted.write(d);
      handler?.call(d);
    };
    // A person may be using this desktop while the test types: a key they press
    // lands in the window under test, and a window of theirs may take the
    // focus. input_watch.dart reports both, so a line that was disturbed is
    // counted apart from one nobody touched.
    final watch = await InputWatch.start();
    addTearDown(watch.stop);
    final failures = <String>[];
    var disturbed = 0, lostBeforeSend = 0, lostAfterSend = 0;
    for (var i = 0; i < typingLines; i++) {
      emitted.clear();
      final want = 'echo TYPED$i-中文-\$(((6+$i)*7))';
      final from = InputWatch.now();
      if (disturbAtLine == i) await _stealFocus(t);
      await typeKeys(t, '$want\n');
      final typed = RegExp(r'~\$ ?echo TYPED' '$i-中文-\\\$\\(\\(\\(6\\+$i\\)\\*7\\)\\)');
      final result = 'TYPED$i-中文-${(6 + i) * 7}';
      try {
        await waitUntil(t, () => _screen(view.terminal).contains(result), 'line $i run by the shell', upTo: const Duration(seconds: 5));
      } on TestFailure {
        // fall through: the check below records what was on screen
      }
      final why = [...watch.between(from, InputWatch.now()), if (lastTypeRefused) 'the typing tool stopped: another window had the focus'];
      if (why.isNotEmpty) disturbed++;
      if (!typed.hasMatch(_screen(view.terminal)) || !_screen(view.terminal).contains(result)) {
        if (why.isNotEmpty) continue; // somebody else's key or window: not the program's fault
        final sent = emitted.toString();
        final before = sent != '$want\r';
        before ? lostBeforeSend++ : lostAfterSend++;
        failures.add('line $i (nobody touched the keyboard or the window): ${before ? "xterm did not emit the line as typed" : "xterm emitted it whole, the shell did not get it"}\n'
            '  typed:   ${want.replaceAll('\r', r'\r')}\\n\n'
            '  emitted: ${sent.replaceAll('\r', r'\r')}\n'
            'screen tail:\n${tail()}');
      }
    }
    // ignore: avoid_print
    print('TYPING: $typingLines lines, $disturbed disturbed by a person or another window, ${failures.length} wrong without a disturbance');
    expect(failures, isEmpty,
        reason: '${failures.length} of $typingLines lines went wrong with nobody else on the keyboard ($lostBeforeSend lost before the connection, $lostAfterSend after):\n${failures.join('\n------\n')}');
    if (stopAfterTyping) return;
    await shot(t, '02-terminal');

    // ---- files: tree, editor, save ----
    await activity(t, '文件', title: '文件');
    await waitFor(t, find.text('docs'));
    await click(t, find.text('docs'));
    await settle(t, upTo: const Duration(milliseconds: 800));
    await shot(t, '03a-files-after-docs');
    await waitFor(t, find.textContaining('readme.txt'));
    await click(t, find.textContaining('readme.txt').first);
    await waitFor(t, find.byType(FileEditor));
    final editor = t.state<FileEditorState>(find.byType(FileEditor));
    await waitUntil(t, () => editor.text.contains('hello from the ui agent'), 'file content in the editor');
    expect(editor.dirty, isFalse);
    editor.text = 'edited in the editor\n';
    await t.pump();
    expect(editor.dirty, isTrue, reason: 'the tab shows unsaved changes');
    await editor.save();
    await settle(t, upTo: const Duration(milliseconds: 500));
    expect(editor.dirty, isFalse);
    expect(await wsl('cat /tmp/aurora3-ui-agent/home/docs/readme.txt'), 'edited in the editor');
    await settle(t, upTo: const Duration(milliseconds: 800));
    expect(find.textContaining('21 B'), findsOneWidget, reason: 'the tree shows the size after the save ("edited in the editor\\n" is 21 bytes), not the old 24');
    // another program changes the file; saving over it is refused, and the
    // other program's text survives
    await wsl("printf 'changed elsewhere, and longer\\n' > /tmp/aurora3-ui-agent/home/docs/readme.txt");
    editor.text = 'mine\n';
    await t.pump();
    unawaited(editor.save());
    await waitFor(t, find.text('服务器上的文件已被修改'));
    await settle(t, upTo: const Duration(milliseconds: 600)); // the dialog fades in
    await shot(t, '03-save-conflict');
    await click(t, find.text('取消'));
    await settle(t, upTo: const Duration(milliseconds: 400));
    expect(await wsl('cat /tmp/aurora3-ui-agent/home/docs/readme.txt'), 'changed elsewhere, and longer', reason: 'the refused save did not overwrite');
    expect(editor.dirty, isTrue, reason: 'my text is still in the editor');

    // ---- git ----
    await activity(t, '源代码管理', title: '源代码管理');
    await waitFor(t, find.text('new.txt'));
    expect(find.text('a.txt'), findsOneWidget, reason: 'the modified file is listed');
    await click(t, find.text('a.txt'));
    await waitFor(t, find.text('TWO')); // the diff tab shows the added line
    expect(find.text('two'), findsWidgets, reason: 'and the removed one');
    await shot(t, '04-git-diff');
    // stage the untracked file and commit
    await click(t, find.byTooltip('暂存').last);
    await settle(t, upTo: const Duration(seconds: 1));
    await waitFor(t, find.textContaining('暂存的更改  1'));
    await t.enterText(find.widgetWithText(TextField, '提交说明（提交到 main）'), 'add new file');
    await click(t, find.textContaining('提交 1 个文件'));
    await waitFor(t, find.textContaining('暂存的更改  0'));
    expect(await wsl('cd /tmp/aurora3-ui-agent/home/proj && git log --format=%s -1'), 'add new file');
    // history lists it
    await click(t, find.text('历史'));
    await waitFor(t, find.textContaining('add new file'));

    // ---- systemd ----
    await activity(t, '系统服务', title: '系统服务');
    await waitFor(t, find.textContaining('个服务'), upTo: const Duration(seconds: 20));
    await shot(t, '05-systemd');

    // ---- port forward ----
    await activity(t, '端口转发', title: '端口转发');
    // the row is "17792" plus a grey note in one text, so match by what it contains
    await waitFor(t, find.textContaining('17792'), upTo: const Duration(seconds: 20));
    await click(t, find.textContaining('17792'));
    await waitFor(t, find.textContaining('→  17792'));
    final local = RegExp(r'127\.0\.0\.1:(\d+)\s+→\s+17792').firstMatch(find.textContaining('→  17792').evaluate().map((e) => (e.widget as Text).textSpan!.toPlainText()).first)!.group(1)!;
    final reply = await () async {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, int.parse(local));
      final out = <int>[];
      final done = Completer<void>();
      s.listen(out.addAll, onDone: done.complete);
      await Future.any([done.future, Future<void>.delayed(const Duration(seconds: 8))]);
      s.destroy();
      return utf8.decode(out);
    }();
    expect(reply, contains('ui-port-banner'), reason: 'bytes came through the forward');
    await shot(t, '06-forward');

    // ---- layouts ----
    t.view.physicalSize = const Size(760, 900);
    await t.pump();
    await settle(t, upTo: const Duration(milliseconds: 500));
    await shot(t, '07-medium');
    t.view.physicalSize = const Size(420, 860);
    await t.pump();
    await settle(t, upTo: const Duration(milliseconds: 500));
    await shot(t, '08-narrow');
    expect(tester(t), isNull);

    await app.disconnect(app.profile.servers.first.id);
    await settle(t, upTo: const Duration(milliseconds: 300));
  });
}

Object? tester(WidgetTester t) => t.takeException();
