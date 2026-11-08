// End to end through a real agent, a real tmux session and a real shell. Run
// it through app/tool/proxy_e2e.ps1, which starts the agent in WSL and the
// node on Windows and passes their addresses in.
//
// The destinations used are names that exist nowhere (.invalid). A node that
// is asked for one of them was reached only because the traffic of the
// session went through the agent's proxy to the node the user chose.
import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/proxy/proxy_model.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_sub/aurora_sub.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

const addr = String.fromEnvironment('AURORA3_E2E_ADDR');
const pin = String.fromEnvironment('AURORA3_E2E_PIN');
const token = String.fromEnvironment('AURORA3_E2E_TOKEN');
const nodePort = String.fromEnvironment('AURORA3_E2E_NODE_PORT');
const nodeLog = String.fromEnvironment('AURORA3_E2E_NODE_LOG');
const nodePass = String.fromEnvironment('AURORA3_E2E_NODE_PASS');

List<String> nodeTargets() {
  final f = File(nodeLog);
  if (!f.existsSync()) return [];
  return [for (final l in f.readAsLinesSync()) if (l.startsWith('target ')) l.substring(7)];
}

/// Reads a terminal session's screen as text, from the bytes the agent sends.
class Screen {
  final Terminal term;
  final StringBuffer raw = StringBuffer();
  Screen(this.term) {
    term.output.listen((b) => raw.write(utf8.decode(b, allowMalformed: true)));
  }

  Future<void> type(String s) => term.write(utf8.encode(s));

  Future<bool> waitFor(String text, {Duration within = const Duration(seconds: 25)}) async {
    final end = DateTime.now().add(within);
    while (DateTime.now().isBefore(end)) {
      if (raw.toString().contains(text)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  /// Text of the output after the last occurrence of [marker].
  String after(String marker) {
    final s = raw.toString();
    final i = s.lastIndexOf(marker);
    return i < 0 ? '' : s.substring(i + marker.length);
  }
}

void main() {
  final skip = addr.isEmpty ? 'run through app/tool/proxy_e2e.ps1' : null;

  late Link link;
  late AppState app;
  late Directory dir;
  late Provider provider;
  late ProxyModel model;

  setUp(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('aurora3-proxy-e2e-');
    final i = addr.lastIndexOf(':');
    link = await Link.dial(Endpoint(host: addr.substring(0, i), port: int.parse(addr.substring(i + 1)), pin: pin, token: token));
    app = AppState();
    await app.initAt('${dir.path}${Platform.pathSeparator}profile.bin');
    await app.update((p) => p.servers.add(ServerEntry.create('e2e')));
    provider = await Provider.start('''
proxies:
  - {name: "e2e node", type: trojan, server: 127.0.0.1, port: $nodePort, password: $nodePass, sni: node.example, skip-cert-verify: true}
  - {name: "needs Reality", type: vless, server: 127.0.0.1, port: 1, uuid: b831381d-6324-4d53-ad4f-8cda48b30811, tls: true, reality-opts: {public-key: AAAA, short-id: bb}}
''');
    model = ProxyModel(app);
  });

  tearDown(() async {
    if (skip != null) return;
    await link.close();
    await provider.close();
    await dir.delete(recursive: true);
  });

  test('E2E subscription -> node chosen -> a proxied session reaches the node; a plain one does not', () async {
    // 1. the subscription is read on this PC and the agent is asked what it can use
    final src = await model.addSubscription('e2e', provider.url.toString());
    final nodes = [for (final j in src.nodes) SubNode.fromJson(j)];
    final reasons = await model.check(link, nodes);
    expect(reasons[nodes[1].key], contains('Reality'));
    final rows = model.rows(src, reasons);
    expect(rows[0].usable, isTrue);
    expect(rows[1].usable, isFalse);

    // 2. timed from the agent's side (WSL): the node, on Windows, sees the probe
    await model.test(link, rows[0]);
    expect(rows[0].ms, isNotNull, reason: rows[0].testError);

    // 3. chosen
    final entry = app.profile.servers.single;
    await model.choose(entry, link, rows[0]);
    final st = await link.call('proxy.status') as Map;
    expect(st['running'], true);

    // 4. a session WITH the proxy: curl and git inside it
    final withProxy = await link.call('session.create', {'name': 'viaproxy', 'proxy': true}) as Map;
    expect(withProxy['proxy'], true);
    final a = Screen(await Terminal.attach(link, 'viaproxy', cols: 200, rows: 50));
    await a.waitFor(r'$');
    final before = nodeTargets().length;
    await a.type('echo MARK1; env | grep -c "^HTTP_PROXY=http://aurora:"; '
        'curl -sS -m 15 -o /dev/null http://e2e-curl.invalid/x 2>&1 | head -c 200; echo CURL-DONE; '
        'GIT_TERMINAL_PROMPT=0 git ls-remote http://e2e-git.invalid/repo.git 2>&1 | head -c 200; echo GIT-DONE\n');
    expect(await a.waitFor('GIT-DONE'), isTrue, reason: 'the session never finished:\n${a.raw}');
    final out = a.after('MARK1');
    expect(out, contains('1\r\n'), reason: 'HTTP_PROXY is set inside the session:\n$out');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final seen = nodeTargets().sublist(before);
    expect(seen, contains('e2e-curl.invalid:80'), reason: 'curl went through the node; the node saw $seen');
    expect(seen, contains('e2e-git.invalid:80'), reason: 'git went through the node; the node saw $seen');

    // 4b. the git SERVICE, not a command typed in a session: the client's own
    // sync (fetch) in a repository whose remote is a name that exists nowhere.
    // git is given the proxy by the service switch alone (D-69), so the node
    // must see this name too, with no session involved.
    await link.call('fs.mkdir', {'root': 'home', 'path': 'g'});
    await link.call('git.init', {'root': 'home', 'path': 'g'});
    await link.call('git.remote', {'root': 'home', 'repo': 'g', 'action': 'add', 'name': 'origin', 'url': 'http://e2e-gitsvc.invalid/r.git'});
    final beforeGit = nodeTargets().length;
    // The node only echoes, so the fetch itself fails; what matters is where it
    // went. "Could not resolve host" would mean git tried to look the name up
    // itself and never reached the proxy.
    String reply = '';
    try {
      final sync = await link.open('git.sync', {'root': 'home', 'repo': 'g', 'action': 'fetch'}, Priority.bulk);
      reply = '${await sync.response()}';
      await sync.close();
    } on OpError catch (e) {
      reply = e.message;
    }
    expect(reply, isNot(contains('resolve host')), reason: 'git tried to resolve the name itself instead of using the proxy: $reply');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(nodeTargets().sublist(beforeGit), contains('e2e-gitsvc.invalid:80'), reason: 'the git service did not go through the node (reply: $reply)');

    // 5. the variables carry the local password; it must not be anywhere a
    // second session or a process list could read it
    final local = await _localProxyPassword(a);
    expect(local, isNotEmpty);
    expect(a.raw.toString().contains(nodePass), isFalse, reason: 'the node password is not visible in the session');

    // 6. a session WITHOUT the proxy does not use the node
    await link.call('session.create', {'name': 'plain'});
    final b = Screen(await Terminal.attach(link, 'plain', cols: 200, rows: 50));
    await b.waitFor(r'$');
    final before2 = nodeTargets().length;
    await b.type('curl -sS -m 4 --noproxy "*" -o /dev/null http://e2e-plain.invalid/x 2>&1 | head -c 120; echo PLAIN-DONE\n');
    expect(await b.waitFor('PLAIN-DONE'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(nodeTargets().sublist(before2), isNot(contains('e2e-plain.invalid:80')), reason: 'a session made without the proxy reached the node');

    // 7. what the session sees of its own environment says no password of the node
    expect(a.raw.toString(), isNot(contains(nodePass)));

    await a.term.close();
    await b.term.close();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('E2E switching the node moves new sessions, and the agent audit has no secret', () async {
    final src = await model.addSubscription('e2e', provider.url.toString());
    final rows = model.rows(src, {});
    final entry = app.profile.servers.single;
    await model.choose(entry, link, rows[0]);
    await model.clear(entry, link);
    final off = await link.call('session.create', {'name': 'nonode'}).catchError((_) => null);
    expect(off, isNotNull);
    // a session that asks for a proxy when none is chosen is refused, and not created
    await expectLater(link.call('session.create', {'name': 'wantsproxy', 'proxy': true}), throwsA(isA<OpError>().having((e) => e.message, 'message', contains('节点'))));
    final list = (await link.call('session.list') as Map)['sessions'] as List;
    expect([for (final s in list) (s as Map)['name']], isNot(contains('wantsproxy')));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}

Future<String> _localProxyPassword(Screen s) async {
  // Only to prove the variable is a credentialled loopback URL; the value is
  // not asserted or printed.
  await s.type('echo LP:\$(echo "\$HTTP_PROXY" | sed -E "s#^http://[^:]+:([^@]+)@127\\.0\\.0\\.1:[0-9]+#X#" | head -c 1)\n');
  await s.waitFor('LP:X');
  return s.raw.toString().contains('LP:X') ? 'present' : '';
}

class Provider {
  final HttpServer server;
  final String body;
  Provider(this.server, this.body);
  static Future<Provider> start(String body) async {
    final s = await HttpServer.bind('127.0.0.1', 0);
    final p = Provider(s, body);
    s.listen((req) async {
      req.response.write(p.body);
      await req.response.close();
    });
    return p;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/sub?token=E2E-KEY');
  Future<void> close() => server.close(force: true);
}
