// The client side of the proxy (docs/DESIGN.md D-83 to D-90) against the real
// agent entry with the real proxy service (agent/cmd/aurora3-testpeer), and a
// subscription served by a local HTTP server, as a provider would. The agent's
// own node is a Trojan server written for this test; it records what it was
// asked for, so "traffic went through the node" is read from the node, not
// guessed from the agent's say-so.
//
// Needs AURORA3_TESTPEER (agent/dist/aurora3-testpeer.exe) and AURORA3_TESTNODE\n// (agent/dist/aurora3-testnode.exe).
import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/proxy/proxy_model.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_sub/aurora_sub.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

const nodePass = 'trojan-node-password-31ac';
const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';

/// The airport's node: agent/cmd/aurora3-testnode, a Trojan server of its own
/// (not the agent's code), which prints a line for every tunnel it opens.
class FakeTrojan {
  final Process proc;
  final int port;
  final List<String> targets = [];
  FakeTrojan(this.proc, this.port);

  static Future<FakeTrojan> start(String pass, {int port = 0}) async {
    final bin = Platform.environment['AURORA3_TESTNODE']!;
    final p = await Process.start(bin, ['-secret', pass, '-port', '$port']);
    final lines = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final first = jsonDecode(await lines.first) as Map<String, dynamic>;
    final f = FakeTrojan(p, first['port'] as int);
    lines.listen((l) {
      if (l.startsWith('target ')) f.targets.add(l.substring(7));
    });
    return f;
  }

  Future<void> close() async {
    proc.stdin.close();
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      proc.kill();
      return -1;
    });
  }
}
class Provider {
  final HttpServer server;
  String body;
  int status = 200;
  Provider(this.server, this.body);
  static Future<Provider> start(String body) async {
    final s = await HttpServer.bind('127.0.0.1', 0);
    final p = Provider(s, body);
    s.listen((req) async {
      req.response.statusCode = p.status;
      if (p.status == 200) req.response.write(p.body);
      await req.response.close();
    });
    return p;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/sub?token=ACCOUNT-KEY-123');
  Future<void> close() => server.close(force: true);
}

String clashFor(int trojanPort, {String name = 'HK 01', String pass = nodePass}) => '''
proxies:
  - {name: "$name", type: trojan, server: 127.0.0.1, port: $trojanPort, password: $pass, sni: node.example, skip-cert-verify: true}
  - name: "Reality (unsupported)"
    type: vless
    server: 127.0.0.1
    port: 1
    uuid: $uuid
    tls: true
    flow: xtls-rprx-vision
    reality-opts: {public-key: AAAA, short-id: bb}
  - {name: "gRPC (unsupported)", type: vless, server: 127.0.0.1, port: 2, uuid: $uuid, tls: true, network: grpc}
  - {name: "Dead node", type: trojan, server: 127.0.0.1, port: 9, password: whatever-pass, sni: x.example, skip-cert-verify: true}
''';

void main() {
  final bin = Platform.environment['AURORA3_TESTPEER'];
  final skip = bin == null || bin.isEmpty || (Platform.environment['AURORA3_TESTNODE'] ?? '').isEmpty ? 'AURORA3_TESTPEER and AURORA3_TESTNODE are not set' : null;

  late Process peer;
  late Link link;
  late AppState app;
  late Directory dir;
  late FakeTrojan node;
  late Provider provider;
  late ProxyModel model;
  late ServerEntry server;

  setUp(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('aurora3-proxy-model-');
    peer = await Process.start(bin!, []);
    final line = await peer.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
    final ep = jsonDecode(line) as Map<String, dynamic>;
    final addr = ep['addr'] as String;
    final i = addr.lastIndexOf(':');
    link = await Link.dial(Endpoint(host: addr.substring(0, i), port: int.parse(addr.substring(i + 1)), pin: ep['pin'] as String, token: ep['token'] as String));
    app = AppState();
    await app.initAt('${dir.path}${Platform.pathSeparator}profile.bin');
    await app.update((p) {
      server = ServerEntry.create('peer');
      p.servers.add(server);
    });
    server = app.profile.servers.single;
    node = await FakeTrojan.start(nodePass);
    provider = await Provider.start(clashFor(node.port));
    model = ProxyModel(app);
  });

  tearDown(() async {
    if (skip != null) return;
    await link.close();
    peer.stdin.close();
    await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      peer.kill();
      return -1;
    });
    await node.close();
    await node2?.close();
    node2 = null;
    await provider.close();
    await dir.delete(recursive: true);
  });

  test('add a subscription, ask the agent what it can use, time a node, choose it, and a session reaches the node', () async {
    final src = await model.addSubscription('我的机场', provider.url.toString());
    expect(src.nodes.length, 4);

    // the agent has the last word on what it can dial
    final nodes = [for (final j in src.nodes) SubNode.fromJson(j)];
    final reasons = await model.check(link, nodes);
    expect(reasons[nodes[0].key], isNull, reason: 'the Trojan node is usable');
    expect(reasons[nodes[1].key], contains('Reality'));
    expect(reasons[nodes[2].key], contains('grpc'));
    final rows = model.rows(app.profile.proxySources.single, reasons);
    expect(rows.where((r) => r.usable).length, 2, reason: 'the Trojan node and the dead one parse fine; the agent finds the dead one at test time');

    // timing is measured by the agent, from its side: the node sees the probe
    await model.test(link, rows[0]);
    expect(rows[0].ms, isNotNull, reason: rows[0].testError);
    expect(node.targets, contains('www.gstatic.com:80'));
    await model.test(link, rows[3]);
    expect(rows[3].ms, isNull);
    expect(rows[3].testError, isNotEmpty);
    expect(rows[3].testError, isNot(contains('whatever-pass')));

    // choosing sends only that node, and the agent starts the local proxy
    await model.choose(app.profile.servers.single, link, rows[0]);
    final st = await link.call('proxy.status') as Map;
    expect(st['running'], true);
    expect((st['node'] as Map)['name'], 'HK 01');
    expect(jsonEncode(st), isNot(contains(nodePass)), reason: 'the node password never comes back');
    final choice = app.profile.servers.single.proxy!;
    expect(choice.name, 'HK 01');
    expect(choice.source, src.id);
  }, skip: skip);

  test('the chosen node is what the agent tests when no node is given', () async {
    // This is the test of the agent's own choice, not of a terminal session:
    // the testpeer has no terminal service, so a session that really starts
    // with the proxy variables is covered by agent/internal/terminal
    // (proxy_test.go) and by the end-to-end run in app/tool/proxy_e2e.ps1.
    final src = await model.addSubscription('x', provider.url.toString());
    final rows = model.rows(src, {});
    await model.choose(app.profile.servers.single, link, rows[0]);
    final r = await link.call('proxy.test', {'target': 'viaagent.example:80'}) as Map;
    expect(r['ok'], true, reason: '${r['error']}');
    expect(node.targets, contains('viaagent.example:80'));
  }, skip: skip);
  test('a refresh that fails keeps the nodes the user had, and says why', () async {
    final src = await model.addSubscription('x', provider.url.toString());
    provider.status = 403;
    final r = await model.refresh(src.id);
    expect(r.error, contains('403'));
    expect(r.error, isNot(contains('ACCOUNT-KEY')));
    final after = app.profile.proxySource(src.id)!;
    expect(after.nodes.length, 4, reason: 'the list was not emptied');
    expect(after.error, contains('403'));
    expect(after.url, contains('ACCOUNT-KEY-123'), reason: 'the address is kept, but only inside the sealed profile');
  }, skip: skip);

  test('the provider renames every node: the server keeps its choice, nothing is re-sent', () async {
    final src = await model.addSubscription('x', provider.url.toString());
    final rows = model.rows(src, {});
    await model.choose(app.profile.servers.single, link, rows[0]);
    provider.body = clashFor(node.port, name: '🇭🇰 香港 01 | 新名字');
    final r = await model.refresh(src.id);
    expect(r.error, isNull);
    expect(r.changedServers, isEmpty, reason: 'only the display name moved');
    expect(r.gone, 0);
    expect(app.profile.servers.single.proxy!.name, '🇭🇰 香港 01 | 新名字', reason: 'the shown name follows the provider');
  }, skip: skip);

  test('the provider rotates the password of the chosen node: it is the same node, the server is told, and then it works', () async {
    final src = await model.addSubscription('x', provider.url.toString());
    final rows = model.rows(src, {});
    await model.choose(app.profile.servers.single, link, rows[0]);

    // The provider changes the password on its side. The server (host and port)
    // is the same, so the choice still points at it; the node now only accepts
    // the new password, so until the agent is told, nothing gets through.
    final port = node.port;
    await node.close();
    node = await FakeTrojan.start('rotated-password-ff00aa11', port: port);
    provider.body = clashFor(port, pass: 'rotated-password-ff00aa11');

    final stale = await link.call('proxy.test', {'target': 'before.example:80'}) as Map;
    expect(stale['ok'], false, reason: 'the agent still has the old password');
    expect(node.targets, isEmpty);

    final r = await model.refresh(src.id);
    expect(r.error, isNull);
    expect(r.gone, 0, reason: 'the node did not disappear');
    expect(r.changedServers, [app.profile.servers.single.id], reason: 'its parameters changed');

    expect(await model.repush(app.profile.servers.single, link), true);
    final fresh = await link.call('proxy.test', {'target': 'after.example:80'}) as Map;
    expect(fresh['ok'], true, reason: '${fresh['error']}');
    expect(node.targets, contains('after.example:80'));
  }, skip: skip);

  test('a node that left the subscription: the server keeps what it has and is not silently switched', () async {
    final src = await model.addSubscription('x', provider.url.toString());
    final rows = model.rows(src, {});
    await model.choose(app.profile.servers.single, link, rows[0]);
    node2 = await FakeTrojan.start(nodePass);
    provider.body = clashFor(node2!.port); // the same name, but at another port: another server
    final r = await model.refresh(src.id);
    expect(r.gone, 1);
    expect(r.changedServers, isEmpty);
    expect(await model.repush(app.profile.servers.single, link), false, reason: 'nothing to push');
    final st = await link.call('proxy.status') as Map;
    expect((st['node'] as Map)['port'], node.port, reason: 'the server still uses the node it was given');
  }, skip: skip);
  test('removing a source forgets the choice that came from it, not the server\'s setting', () async {
    final src = await model.addSubscription('x', provider.url.toString());
    final rows = model.rows(src, {});
    await model.choose(app.profile.servers.single, link, rows[0]);
    await model.remove(src.id);
    expect(app.profile.proxySources, isEmpty);
    expect(app.profile.servers.single.proxy, isNull);
    final st = await link.call('proxy.status') as Map;
    expect((st['node'] as Map)['name'], 'HK 01', reason: 'the agent keeps its node until it is cleared');
    await model.clear(app.profile.servers.single, link);
    expect(((await link.call('proxy.status')) as Map)['node'], isNull);
  }, skip: skip);

  test('pasted links make a source with no address to refresh', () async {
    final src = await model.addPasted('我的 VPS', 'trojan://own-vps-pass@203.0.113.7:443?sni=vps.example#MyVPS');
    expect(src.url, isNull);
    expect(src.nodes.single['name'], 'MyVPS');
    final r = await model.refresh(src.id);
    expect(r.error, 'not a subscription');
  }, skip: skip);

  test('a page that is not a subscription adds nothing', () async {
    provider.body = '<html><body>login required</body></html>';
    await expectLater(model.addSubscription('x', provider.url.toString()), throwsA(isA<FetchError>()));
    expect(app.profile.proxySources, isEmpty);
  }, skip: skip);

  test('what is on disk for the source: the address and passwords are inside the sealed file only', () async {
    await model.addSubscription('x', provider.url.toString());
    final raw = latin1.decode(File(app.storePath!).readAsBytesSync(), allowInvalid: true);
    for (final s in ['ACCOUNT-KEY-123', nodePass, '127.0.0.1:${provider.server.port}']) {
      expect(raw, isNot(contains(s)), reason: s);
    }
  }, skip: skip);

  test('offline subscription changes survive application restart and synchronize on the next connection', () async {
    final src = await model.addSubscription('queue', provider.url.toString());
    await model.choose(app.profile.servers.single,link,model.rows(src,{}).first);
    final id = app.profile.servers.single.id;
    final port = node.port;
    await node.close();
    node = await FakeTrojan.start('queued-rotated-password',port:port);
    provider.body = clashFor(port,pass:'queued-rotated-password');
    final refreshed = await model.refresh(src.id);
    expect(refreshed.changedServers,[id]);
    expect(app.profile.server(id)!.proxy!.pending,true);
    final generation = app.profile.server(id)!.proxy!.revision;

    final reopened = AppState();
    await reopened.initAt(app.storePath!);
    expect(reopened.profile.server(id)!.proxy!.pending,true,reason:'queue is not just in memory');
    await reopened.proxies.connected(id,link);
    expect(reopened.profile.server(id)!.proxy!.pending,false);
    expect(reopened.profile.server(id)!.proxy!.revision,generation);
    final result=await link.call('proxy.test',{'target':'queued-sync.invalid:80'}) as Map;
    expect(result['ok'],true,reason:'${result['error']}');
    expect(node.targets,contains('queued-sync.invalid:80'));
    reopened.dispose();
  },skip:skip);

  test('service-off sync stays queued and a fresh connection retries it', () async {
    final src = await model.addSubscription('queue',provider.url.toString());
    await model.choose(app.profile.servers.single,link,model.rows(src,{}).first);
    final id=app.profile.servers.single.id;
    await app.update((p){p.server(id)!.proxy!.pending=true;p.server(id)!.proxy!.revision++;});
    await link.call('agent.service',{'id':'proxy','enabled':false});
    await expectLater(model.repush(app.profile.server(id)!,link),throwsA(isA<OpError>()));
    expect(app.profile.server(id)!.proxy!.pending,true);
    expect(app.profile.server(id)!.proxy!.syncError,isNotEmpty);
    await link.call('agent.service',{'id':'proxy','enabled':true});
    final fresh=ProxyModel(app);
    await fresh.connected(id,link);
    expect(app.profile.server(id)!.proxy!.pending,false);
    expect(app.profile.server(id)!.proxy!.syncError,isNull);
  },skip:skip);
}

FakeTrojan? node2;
