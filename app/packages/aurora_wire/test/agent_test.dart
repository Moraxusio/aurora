// Tests against the real Go entry (agent/cmd/aurora3-testpeer): pinned TLS,
// Hello, hashicorp/yamux and service dispatch. Set AURORA3_TESTPEER to the
// built binary; without it the tests are skipped.
@Tags(['agent'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:test/test.dart';

class Peer {
  final Process p;
  final Endpoint ep;
  Peer(this.p, this.ep);

  static Future<Peer> start({bool testOff = false}) async {
    final bin = Platform.environment['AURORA3_TESTPEER']!;
    final p = await Process.start(bin, [if (testOff) '-test-off']);
    p.stderr.drain<void>();
    final line = await p.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 20));
    final m = jsonDecode(line) as Map<String, dynamic>;
    final addr = m['addr'] as String;
    final i = addr.lastIndexOf(':');
    return Peer(p, Endpoint(host: addr.substring(0, i), port: int.parse(addr.substring(i + 1)), pin: m['pin'] as String, token: m['token'] as String));
  }

  Future<void> stop() async {
    await p.stdin.close();
    await p.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      p.kill();
      return -1;
    });
  }
}

int pattern(int i) => i % 251;

void main() {
  final bin = Platform.environment['AURORA3_TESTPEER'];
  final skip = bin == null || bin.isEmpty ? 'AURORA3_TESTPEER not set' : null;

  late Peer peer;
  setUpAll(() async {
    if (skip == null) peer = await Peer.start();
  });
  tearDownAll(() async {
    if (skip == null) await peer.stop();
  });

  test('hello reports the agent; the token is not in it', () async {
    final l = await Link.dial(peer.ep);
    expect(l.server.version, '3.0.0-testpeer');
    expect(l.server.caps, contains('test.echo'));
    expect(l.server.raw['direct']['token'], isNull);
    expect(l.server.raw['direct']['cert_sha256'], peer.ep.pin);
    await l.close();
  }, skip: skip);

  test('unary call, error code and Chinese text survive', () async {
    final l = await Link.dial(peer.ep);
    expect(await l.call('test.echo', {'text': '你好，Aurora'}), {'text': '你好，Aurora'});
    try {
      await l.call('test.echo', {'text': 'x', 'fail': true});
      fail('no error');
    } on OpError catch (e) {
      expect(e.code, codeConflict);
      expect(e.message, '冲突：x');
    }
    try {
      await l.call('test.nope');
      fail('no error');
    } on OpError catch (e) {
      expect(e.code, codeUnsupported);
    }
    await l.close();
  }, skip: skip);

  test('wrong token: auth failure', () async {
    final ep = Endpoint(host: peer.ep.host, port: peer.ep.port, pin: peer.ep.pin, token: 'f' * 64);
    await expectLater(Link.dial(ep), throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.auth)));
  }, skip: skip);

  test('wrong pin: refused before the token is sent', () async {
    final ep = Endpoint(host: peer.ep.host, port: peer.ep.port, pin: '0' * 64, token: peer.ep.token);
    await expectLater(Link.dial(ep), throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.pinMismatch)));
  }, skip: skip);

  test('nothing listening: network failure', () async {
    final s = await ServerSocket.bind('127.0.0.1', 0);
    final port = s.port;
    await s.close();
    final ep = Endpoint(host: '127.0.0.1', port: port, pin: peer.ep.pin, token: peer.ep.token);
    await expectLater(Link.dial(ep), throwsA(isA<DialException>().having((e) => e.kind, 'kind', DialFailure.network)));
  }, skip: skip);

  test('switch a service off and on over the link', () async {
    final l = await Link.dial(peer.ep);
    await l.call('agent.service', {'id': 'test', 'enabled': false});
    try {
      await l.call('test.echo', {'text': 'x'});
      fail('disabled service answered');
    } on OpError catch (e) {
      expect(e.code, codeUnavailable);
      expect(e.message, contains('服务未启用'));
    }
    await l.call('agent.service', {'id': 'test', 'enabled': true});
    expect(await l.call('test.echo', {'text': 'y'}), {'text': 'y'});
    await l.close();
  }, skip: skip);

  test('stream: pipe echoes data frames', () async {
    final l = await Link.dial(peer.ep);
    final op = await l.open('test.pipe');
    await op.response();
    for (var i = 0; i < 50; i++) {
      await op.sendData(List.filled(1000 + i, i));
      final f = (await op.read())!;
      expect(f.isData, isTrue);
      expect(f.payload.length, 1000 + i);
      expect(f.payload[0], i);
    }
    await op.sendEnd();
    expect((await op.read())!.isEnd, isTrue);
    await l.close();
  }, skip: skip);

  test('download 64 MiB intact (agent to client)', () async {
    final l = await Link.dial(peer.ep);
    const size = 64 << 20;
    final op = await l.open('test.source', {'bytes': size}, Priority.bulk);
    expect(await op.response(), {'bytes': size});
    var got = 0;
    var ok = true;
    while (true) {
      final f = (await op.read())!;
      if (f.isEnd) break;
      final p = f.payload;
      for (var i = 0; i < p.length; i += 4093) {
        if (p[i] != pattern(got + i)) ok = false;
      }
      got += p.length;
    }
    expect(got, size);
    expect(ok, isTrue);
    await l.close();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('upload 64 MiB intact (client to agent)', () async {
    final l = await Link.dial(peer.ep);
    const size = 64 << 20;
    final op = await l.open('test.sink', null, Priority.bulk);
    const chunk = 256 * 1024;
    final buf = Uint8List(chunk);
    for (var off = 0; off < size; off += chunk) {
      for (var i = 0; i < chunk; i++) {
        buf[i] = pattern(off + i);
      }
      await op.sendData(buf);
    }
    await op.sendEnd();
    expect(await op.response(), {'bytes': size, 'ok': true});
    await l.close();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('200 concurrent calls on one link', () async {
    final l = await Link.dial(peer.ep);
    final res = await Future.wait([for (var i = 0; i < 200; i++) l.call('test.echo', {'text': '$i'})]);
    for (var i = 0; i < 200; i++) {
      expect(res[i], {'text': '$i'});
    }
    // A call returns as soon as its Response frame is read; the agent's FIN
    // for that stream may still be on the way. Once it arrives the stream is
    // forgotten.
    final until = DateTime.now().add(const Duration(seconds: 2));
    while (l.session.numStreams > 0 && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(l.session.numStreams, 0, reason: 'finished streams are forgotten');
    await l.close();
  }, skip: skip);

  test('a call stays fast while a download runs', () async {
    final l = await Link.dial(peer.ep);
    final dl = await l.open('test.source', {'bytes': 256 << 20}, Priority.bulk);
    await dl.response();
    var bulkDone = false;
    final drain = () async {
      while (true) {
        final f = await dl.read();
        if (f == null || f.isEnd) break;
      }
      bulkDone = true;
    }();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final times = <int>[];
    for (var i = 0; i < 20 && !bulkDone; i++) {
      final sw = Stopwatch()..start();
      await l.call('test.echo', {'text': 'k'});
      times.add(sw.elapsedMicroseconds);
    }
    dl.reset();
    await drain.catchError((_) {});
    times.sort();
    // printed for the plan's benchmark table
    print('echo during download: n=${times.length} median=${times.isEmpty ? 0 : times[times.length ~/ 2]}us max=${times.isEmpty ? 0 : times.last}us');
    if (times.isNotEmpty) {
      expect(times[times.length ~/ 2], lessThan(200000), reason: 'median call under 200 ms during a bulk transfer');
    }
    await l.close();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('ping and keepalive', () async {
    final l = await Link.dial(peer.ep, config: const YamuxConfig(keepAliveInterval: Duration(milliseconds: 200)));
    final rtt = await l.ping();
    expect(rtt.inMilliseconds, lessThan(1000));
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(l.isClosed, isFalse, reason: 'keepalive pings were answered');
    await l.close();
  }, skip: skip);

  test('the agent going away ends the link with a reason', () async {
    final own = await Peer.start();
    final l = await Link.dial(own.ep);
    final hold = await l.open('test.hold');
    await hold.response();
    final read = hold.read();
    own.p.kill(ProcessSignal.sigkill);
    await expectLater(read, throwsA(isA<OpError>()));
    expect(await l.done.timeout(const Duration(seconds: 10)), isNotEmpty);
    await own.p.exitCode;
  }, skip: skip);

  // The client's side of port forwarding: a local listener, one net.dial
  // stream per connection, bytes both ways, and what happens when the target
  // is not there.
  group('port forward', () {
    late ServerSocket target;
    late Link l;
    setUp(() async {
      // The "service on the server": answers "echo:" + what it received, then
      // closes (so a half-close by the client is what ends the request).
      target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((c) {
        final got = BytesBuilder();
        c.listen(got.add, onDone: () {
          c.add([...utf8.encode('echo:'), ...got.takeBytes()]);
          c.close();
        });
      });
      l = await Link.dial(peer.ep);
    });
    tearDown(() async {
      await l.close();
      await target.close();
    });

    Future<List<int>> ask(int port, List<int> send) async {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
      s.add(send);
      await s.close();
      final out = BytesBuilder();
      await for (final c in s) {
        out.add(c);
      }
      s.destroy();
      return out.takeBytes();
    }

    test('bytes go both ways, in text and in bulk', () async {
      final f = await Forward.start(l, port: target.port);
      expect(f.local, isNot(target.port));
      expect(utf8.decode(await ask(f.local, utf8.encode('你好'))), 'echo:你好');
      // 3 MiB: more than a yamux window, so flow control is exercised
      final big = Uint8List.fromList([for (var i = 0; i < 3 << 20; i++) pattern(i)]);
      final back = await ask(f.local, big);
      expect(back.length, big.length + 5);
      expect(utf8.decode(back.sublist(0, 5)), 'echo:');
      expect(back.sublist(5), big);
      expect(f.bytesOut, greaterThanOrEqualTo(big.length));
      expect(f.bytesIn, greaterThanOrEqualTo(big.length));
      await f.close();
    }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

    test('connections run side by side', () async {
      final f = await Forward.start(l, port: target.port);
      final answers = await Future.wait([for (var i = 0; i < 20; i++) ask(f.local, utf8.encode('n$i'))]);
      for (var i = 0; i < 20; i++) {
        expect(utf8.decode(answers[i]), 'echo:n$i');
      }
      expect(f.total, 20);
      await f.close();
    }, skip: skip);

    test('a port nothing listens on: the connection ends, the reason is kept', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();
      final f = await Forward.start(l, port: deadPort);
      expect(await ask(f.local, utf8.encode('x')), isEmpty);
      expect(f.lastError, contains('连不上'));
      await f.close();
    }, skip: skip);

    test('close stops the listener', () async {
      final f = await Forward.start(l, port: target.port);
      final port = f.local;
      await f.close();
      expect(f.isClosed, isTrue);
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
    }, skip: skip);

    test('a local port in use is reported', () async {
      final f = await Forward.start(l, port: target.port);
      await expectLater(Forward.start(l, port: target.port, local: f.local), throwsA(isA<SocketException>()));
      await f.close();
    }, skip: skip);
  });}
