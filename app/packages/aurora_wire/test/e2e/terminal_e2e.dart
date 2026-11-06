// Terminal over the real link to a real aurora3-agent (agent/tools/
// terminal-e2e.sh starts it): create a session, attach, type, resize,
// detach and attach again, switch the service off (D-51), session.kill
// while off (D-52), and a large burst of output.
//   terminal_e2e HOST:PORT PIN TOKEN
import 'dart:convert';
import 'dart:io';

import 'package:aurora_wire/aurora_wire.dart';

var fails = 0;
void check(bool ok, String what) {
  stdout.writeln('${ok ? '  ok  ' : '  FAIL'} $what');
  if (!ok) fails++;
}

late Link link;

/// Waits until the session's screen (session.capture) contains [want]. The
/// stream itself is tmux's redraw output, not plain text. Output must also
/// be arriving on the terminal stream.
Future<String> collectUntil(Terminal t, String want, {Duration timeout = const Duration(seconds: 10), int history = 0}) async {
  var bytes = 0;
  final sub = t.output.listen((b) => bytes += b.length);
  final end = DateTime.now().add(timeout);
  var text = '';
  while (DateTime.now().isBefore(end) && t.isOpen) {
    text = ((await link.call('session.capture', {'name': t.session, 'history': history})) as Map)['text'] as String;
    if (text.contains(want) && bytes > 0) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await sub.cancel();
  return text;
}

Future<void> main(List<String> a) async {
  final i = a[0].lastIndexOf(':');
  final ep = Endpoint(host: a[0].substring(0, i), port: int.parse(a[0].substring(i + 1)), pin: a[1], token: a[2]);
  link = await Link.dial(ep);
  check(link.server.caps.contains('terminal') && link.server.caps.contains('session.kill'), 'agent reports terminal and session.kill');

  await link.call('session.create', {'name': 'e2e'});
  final list = await link.call('session.list') as Map;
  check((list['sessions'] as List).any((s) => s['name'] == 'e2e'), 'session listed');
  check((list['tmux'] as Map)['bundled'] == true, 'bundled tmux in use (${(list['tmux'] as Map)['version']})');

  var t = await Terminal.attach(link, 'e2e', cols: 100, rows: 30);
  await t.write(utf8.encode('echo HEL""LO-你好\r'));
  check((await collectUntil(t, 'HELLO-你好')).contains('HELLO-你好'), 'typed command echoes, UTF-8 intact');
  final rtt = await t.ping();
  check(rtt.inMilliseconds < 500, 'terminal ping ${rtt.inMicroseconds} µs');

  // A burst of 300000 lines (about 2 MB) scrolls through; the terminal keeps
  // up and answers a ping right after.
  var got = 0;
  final count = t.output.listen((b) => got += b.length);
  final sw = Stopwatch()..start();
  await t.write(utf8.encode('seq 1 300000; echo DO""NE\r'));
  final big = await collectUntil(t, 'DONE', timeout: const Duration(seconds: 60), history: 20);
  await count.cancel();
  check(big.contains('DONE') && big.contains('300000'), 'burst of 300000 lines: ${sw.elapsedMilliseconds} ms, $got bytes on the stream');
  final rtt2 = await t.ping();
  check(rtt2.inMilliseconds < 500, 'ping right after the burst ${rtt2.inMicroseconds} µs');

  // Detach and attach again: the same session, still running.
  await t.write(utf8.encode('export MARK=kept42\r'));
  await collectUntil(t, 'kept42', timeout: const Duration(seconds: 3));
  await t.close();
  t = await Terminal.attach(link, 'e2e', cols: 100, rows: 30);
  await t.write(utf8.encode('echo M=\$MARK=\r'));
  check((await collectUntil(t, 'M=kept42=')).contains('M=kept42='), 'detach and attach again: same shell');

  // Switching terminal off disconnects the window, keeps the session.
  await link.call('agent.service', {'id': 'terminal', 'enabled': false});
  final why = await t.done.timeout(const Duration(seconds: 5), onTimeout: () => TerminalEnd.lost);
  check(why == TerminalEnd.closed && t.endReason.contains('关闭'), 'service off: window closed with a reason ($why "${t.endReason}")');
  try {
    await Terminal.attach(link, 'e2e');
    check(false, 'attach refused while off');
  } on OpError catch (e) {
    check(e.code == codeUnavailable, 'attach refused while off (${e.code})');
  }
  try {
    await link.call('session.create', {'name': 'e2e2'});
    check(false, 'create refused while off');
  } on OpError catch (e) {
    check(e.code == codeUnavailable, 'create refused while off');
  }
  // session.kill still works (D-52).
  final k = await link.call('session.kill', {'name': 'e2e'}) as Map;
  check(k['name'] == 'e2e', 'session.kill works while off');
  await link.call('agent.service', {'id': 'terminal', 'enabled': true});
  final after = await link.call('session.list') as Map;
  check((after['sessions'] as List).isEmpty, 'no session left');
  try {
    await Terminal.attach(link, 'e2e');
    check(false, 'attach to a killed session');
  } on OpError catch (e) {
    check(e.code == codeNotFound, 'attach to a killed session: not_found');
  }

  // The shell exiting ends the session: exit.
  await link.call('session.create', {'name': 'e2e3'});
  t = await Terminal.attach(link, 'e2e3');
  await t.write(utf8.encode('exit\r'));
  check(await t.done.timeout(const Duration(seconds: 10), onTimeout: () => TerminalEnd.lost) == TerminalEnd.exit, 'shell exit ends the session');

  await link.close();
  stdout.writeln('failures: $fails');
  exit(fails == 0 ? 0 : 1);
}
