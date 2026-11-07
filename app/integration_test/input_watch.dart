// Starts app/tool/watchinput.ps1 next to a test that types on the real
// keyboard path, and answers one question per stretch of time: did a person
// type, or did another window take the focus? A typing test on a desktop that
// somebody is also using is only fair about the lines nobody disturbed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'helpers.dart' show sendKeys;

class InputWatch {
  final Process _p;
  final List<({int at, String what})> _events = [];
  String? _error;

  InputWatch._(this._p);

  /// Starts the watcher for this process's window and waits until its hook is in.
  static Future<InputWatch> start() async {
    final script = sendKeys.replaceAll('sendkeys.ps1', 'watchinput.ps1');
    final p = await Process.start('powershell', ['-NoProfile', '-File', script, '-ProcessId', '$pid']);
    final w = InputWatch._(p);
    final ready = Completer<void>();
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final f = line.trim().split(' ');
      switch (f[0]) {
        case 'READY':
          if (!ready.isCompleted) ready.complete();
        case 'HUMAN' when f.length >= 3:
          w._events.add((at: int.parse(f[1]), what: 'a person pressed key ${f[2]}'));
        case 'FOCUS' when f.length >= 3 && f[2] == 'out':
          w._events.add((at: int.parse(f[1]), what: 'another window took the focus'));
        case 'ERROR':
          w._error = line;
      }
    });
    p.stderr.drain<void>();
    await ready.future.timeout(const Duration(seconds: 20), onTimeout: () => throw StateError('the input watcher did not start'));
    if (w._error != null) throw StateError('the input watcher failed: ${w._error}');
    return w;
  }

  /// Now, in the clock the watcher uses (Unix ms).
  static int now() => DateTime.now().millisecondsSinceEpoch;

  /// What disturbed the typing between [from] and [to] (Unix ms); empty if nothing.
  List<String> between(int from, int to) => [for (final e in _events) if (e.at >= from && e.at <= to) e.what];

  /// Everything seen so far.
  int get total => _events.length;

  Future<void> stop() async {
    _p.kill();
  }
}
