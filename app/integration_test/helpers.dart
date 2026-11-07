// Shared by the integration tests that type on the real Windows keyboard path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
