// Reconnect rules (D-24, D-62) with a scripted dialer, then against the real
// Go entry: restart, wrong token, changed certificate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:test/test.dart';

const fast = [Duration(milliseconds: 20), Duration(milliseconds: 40), Duration(milliseconds: 60)];
const pin = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';

/// Fails with the scripted kinds, in order; null means "connect" (the fake
/// can only throw, so the success path is covered by the real-agent tests).
class Script {
  final List<DialFailure> fails;
  final List<String> dialed = [];
  int n = 0;
  Script(this.fails);
  Future<Link> dial(Endpoint ep) async {
    dialed.add('${ep.host}:${ep.port}');
    final k = fails[n < fails.length ? n : fails.length - 1];
    n++;
    throw DialException(k, k.name);
  }
}

class AgentProc {
  final Process p;
  final String addr, pin, token;
  AgentProc(this.p, this.addr, this.pin, this.token);
  static Future<AgentProc> start(String listen, {String? state}) async {
    final p = await Process.start(Platform.environment['AURORA3_TESTPEER']!,
        ['-listen', listen, if (state != null) ...['-state', state]]);
    p.stderr.drain<void>();
    final m = jsonDecode(await p.stdout.transform(utf8.decoder).transform(const LineSplitter()).first) as Map;
    return AgentProc(p, m['addr'] as String, m['pin'] as String, m['token'] as String);
  }

  Future<void> kill() async {
    p.kill(ProcessSignal.sigkill);
    await p.exitCode;
  }
}

void main() {
  test('host:port parsing', () {
    expect(splitHostPort('10.0.0.5:17710'), ('10.0.0.5', 17710));
    expect(splitHostPort('[2001:db8::1]:17710'), ('2001:db8::1', 17710));
    expect(splitHostPort('host'), isNull);
    expect(splitHostPort(':1'), isNull);
    expect(splitHostPort('h:0'), isNull);
    expect(splitHostPort('h:70000'), isNull);
  });

  test('network failures: every address, then 3 retries, then failed', () async {
    final s = Script([DialFailure.network]);
    final c = Connection(const Target(addrs: ['a:1', 'b:2'], pin: pin, token: 't'), dial: s.dial, retryDelays: fast);
    final states = <ConnState>[];
    c.changes.listen((x) => states.add(x.state));
    await expectLater(c.connect(), throwsA(isA<ConnFailure>().having((f) => f.kind, 'kind', DialFailure.network)));
    expect(s.dialed, ['a:1', 'b:2', 'a:1', 'b:2', 'a:1', 'b:2', 'a:1', 'b:2'], reason: '1 try + 3 retries, both addresses');
    expect(states.where((x) => x == ConnState.waiting), hasLength(3));
    expect(states.last, ConnState.failed);
    expect(c.failure!.needsUser, isFalse);
    await c.dispose();
  });

  for (final k in [DialFailure.auth, DialFailure.pinMismatch, DialFailure.version]) {
    test('${k.name}: reported at once, no retry, no other address', () async {
      final s = Script([k]);
      final c = Connection(const Target(addrs: ['a:1', 'b:2'], pin: pin, token: 't'), dial: s.dial, retryDelays: fast);
      await expectLater(c.connect(), throwsA(isA<ConnFailure>().having((f) => f.needsUser, 'needsUser', isTrue)));
      expect(s.dialed, ['a:1']);
      expect(c.status.state, ConnState.failed);
      await c.dispose();
    });
  }

  test('a network failure then a pin mismatch stops at the mismatch', () async {
    final s = Script([DialFailure.network, DialFailure.network, DialFailure.pinMismatch]);
    final c = Connection(const Target(addrs: ['a:1', 'b:2'], pin: pin, token: 't'), dial: s.dial, retryDelays: fast);
    await expectLater(c.connect(), throwsA(isA<ConnFailure>().having((f) => f.kind, 'kind', DialFailure.pinMismatch)));
    expect(s.dialed, ['a:1', 'b:2', 'a:1']);
    await c.dispose();
  });

  test('the last good address is tried first', () async {
    final s = Script([DialFailure.network]);
    final c = Connection(const Target(addrs: ['a:1', 'b:2', 'c:3'], pin: pin, token: 't'),
        dial: s.dial, retryDelays: const [], goodAddr: 'c:3');
    await expectLater(c.connect(), throwsA(isA<ConnFailure>()));
    expect(s.dialed, ['c:3', 'a:1', 'b:2']);
    await c.dispose();
  });

  test('close stops a waiting run', () async {
    final s = Script([DialFailure.network]);
    final c = Connection(const Target(addrs: ['a:1'], pin: pin, token: 't'),
        dial: s.dial, retryDelays: const [Duration(seconds: 30)]);
    final f = c.connect();
    f.ignore();
    await c.changes.firstWhere((x) => x.state == ConnState.waiting);
    await c.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(s.dialed, ['a:1']);
    expect(c.status.state, ConnState.idle);
    await c.dispose();
  });

  test('retryNow skips the wait', () async {
    final s = Script([DialFailure.network]);
    final c = Connection(const Target(addrs: ['a:1'], pin: pin, token: 't'),
        dial: s.dial, retryDelays: const [Duration(seconds: 30), Duration(seconds: 30)]);
    final f = c.connect();
    f.ignore();
    await c.changes.firstWhere((x) => x.state == ConnState.waiting);
    final sw = Stopwatch()..start();
    c.retryNow();
    await c.changes.firstWhere((x) => x.state == ConnState.waiting && x.attempt == 2);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(s.dialed, ['a:1', 'a:1']);
    await c.dispose();
  });

  group('against the Go entry', () {
    final bin = Platform.environment['AURORA3_TESTPEER'];
    final skip = bin == null || bin.isEmpty ? 'AURORA3_TESTPEER not set' : null;

    test('the agent restarts: the link comes back by itself', () async {
      final dir = await Directory.systemTemp.createTemp('aurora3-conn-');
      final ss = await ServerSocket.bind('127.0.0.1', 0);
      final listen = '127.0.0.1:${ss.port}';
      await ss.close();
      try {
        var a = await AgentProc.start(listen, state: dir.path);
        final c = Connection(Target(addrs: ['127.0.0.1:1', a.addr], pin: a.pin, token: a.token),
            retryDelays: const [Duration(milliseconds: 300), Duration(milliseconds: 500), Duration(seconds: 1)]);
        final first = await c.connect();
        expect(c.goodAddr, a.addr);
        expect(await first.call('test.echo', {'text': 'one'}), {'text': 'one'});
        final states = <ConnState>[];
        final sub = c.changes.listen((x) => states.add(x.state));
        await a.kill();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        a = await AgentProc.start(listen, state: dir.path); // same identity and token
        final st = await c.changes.firstWhere((x) => x.state == ConnState.connected).timeout(const Duration(seconds: 10));
        expect(st.link, isNot(same(first)));
        expect(await st.link!.call('test.echo', {'text': 'two'}), {'text': 'two'});
        expect(states, contains(ConnState.connecting));
        await sub.cancel();
        await c.dispose();
        await a.kill();
      } finally {
        await dir.delete(recursive: true);
      }
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('wrong token: auth, no retry', () async {
      final a = await AgentProc.start('127.0.0.1:0');
      final c = Connection(Target(addrs: [a.addr], pin: a.pin, token: 'x' * 64), retryDelays: fast);
      await expectLater(c.connect(), throwsA(isA<ConnFailure>().having((f) => f.kind, 'kind', DialFailure.auth)));
      await c.dispose();
      await a.kill();
    }, skip: skip);

    test('reinstalled agent (new certificate): pinMismatch, no retry', () async {
      final a = await AgentProc.start('127.0.0.1:0');
      final c = Connection(Target(addrs: [a.addr], pin: pin, token: a.token), retryDelays: fast);
      await expectLater(c.connect(), throwsA(isA<ConnFailure>().having((f) => f.kind, 'kind', DialFailure.pinMismatch)));
      await c.dispose();
      await a.kill();
    }, skip: skip);
  });
}
