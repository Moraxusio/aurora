// Shared by the integration tests that type on the real Windows keyboard path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Path of app/tool/sendkeys.ps1 (--dart-define=AURORA3_UI_SENDKEYS=..).
const sendKeys = String.fromEnvironment('AURORA3_UI_SENDKEYS');

/// Whether the last [typeKeys] was refused because another window had the focus.
bool lastTypeRefused = false;

/// Types [text] into this process's window with app/tool/sendkeys.ps1,
/// pumping frames meanwhile so the app handles the keys as they come.
/// [gapMs] is the pause between two key events.
Future<void> typeKeys(WidgetTester t, String text, {int gapMs = 15}) async {
  expect(sendKeys, isNotEmpty, reason: 'run through app/tool/ui_test.ps1');
  final p = await Process.start(
      'powershell', ['-NoProfile', '-File', sendKeys, '-ProcessId', '$pid', '-Base64', base64.encode(utf8.encode(text)), '-GapMs', '$gapMs']);
  final err = StringBuffer();
  p.stderr.transform(utf8.decoder).listen(err.write);
  p.stdout.drain<void>();
  int? code;
  unawaited(p.exitCode.then((c) => code = c));
  while (code == null) {
    await t.pump(const Duration(milliseconds: 50));
  }
  lastTypeRefused = code != 0 && err.toString().contains('lost the focus');
  if (!lastTypeRefused) expect(code, 0, reason: 'sendkeys: $err');
}

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
    await activityIcon(t, tooltip);
    await settle(t, upTo: const Duration(milliseconds: 500));
  }
  expect(shown, findsOneWidget, reason: 'the $tooltip side bar is shown');
}

/// Terminals have their own bottom panel, not a feature side bar.
Future<void> terminalPanel(WidgetTester t) async {
  final shown = find.byKey(const ValueKey('terminal-panel-header'));
  if (shown.evaluate().isEmpty) await activityIcon(t, '终端');
  await waitFor(t, shown);
}

/// Low-frequency tools live in the overflow rather than permanent rail icons.
Future<void> activityIcon(WidgetTester t, String tooltip) async {
  final direct = find.byTooltip(tooltip);
  if (direct.evaluate().isNotEmpty) { await click(t, direct.first); return; }
  await click(t, find.byTooltip('更多工具'));
  await t.pump(const Duration(milliseconds: 250));
  await click(t, find.text(tooltip).last);
}

Future<void> openOverview(WidgetTester t) async {
  await click(t, find.byTooltip('设置与连接'));
  await t.pump(const Duration(milliseconds: 250));
  await click(t, find.text('连接与服务'));
  await t.pump(const Duration(milliseconds: 250));
}
