import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora_sub/aurora_sub.dart';
import 'package:test/test.dart';

const body = 'proxies:\n  - {name: a, type: trojan, server: x.example.com, port: 443, password: pw}\n';

/// A server that answers each path as a provider might.
Future<HttpServer> serve() async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  s.listen((req) async {
    final r = req.response;
    switch (req.uri.path) {
      case '/ok':
        r.headers.set('user-agent-seen', req.headers.value('user-agent') ?? '');
        r.write(body);
      case '/redirect':
        r.statusCode = 302;
        r.headers.set('location', '/ok');
      case '/b64':
        r.write(base64.encode(utf8.encode('trojan://pw@x.example.com:443#n')));
      case '/forbidden':
        r.statusCode = 403;
      case '/gone':
        r.statusCode = 404;
      case '/busy':
        r.statusCode = 429;
      case '/boom':
        r.statusCode = 502;
      case '/huge':
        r.add(List.filled(maxSubscriptionBytes + 1024, 0x61));
      case '/cut':
        // promises 1000 bytes, sends 3, and hangs up: written on the raw socket,
        // since HttpResponse will not send a short body
        final raw = await r.detachSocket(writeHeaders: false);
        raw.write('HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nabc');
        await raw.flush();
        raw.destroy();
        return;
      case '/loop':
        r.statusCode = 302;
        r.headers.set('location', '/loop');
      case '/to-file':
        r.statusCode = 302;
        r.headers.set('location', 'file:///etc/passwd');
      case '/slow':
        await Future<void>.delayed(const Duration(seconds: 5));
        r.write(body);
      case '/echo-ua':
        r.write(req.headers.value('user-agent') ?? '');
    }
    await r.close();
  });
  return s;
}

void main() {
  late HttpServer s;
  late String base;
  setUp(() async {
    s = await serve();
    base = 'http://127.0.0.1:${s.port}';
  });
  tearDown(() => s.close(force: true));

  test('fetches the body, and follows a redirect', () async {
    expect(await fetchSubscription(Uri.parse('$base/ok')), body);
    expect(await fetchSubscription(Uri.parse('$base/redirect')), body);
  });

  test('says it is Clash Meta, because providers choose the format from that', () async {
    final ua = await fetchSubscription(Uri.parse('$base/echo-ua'));
    expect(ua.toLowerCase(), contains('clash'));
  });

  test('what comes back reads as a subscription', () async {
    final r = parseSubscription(await fetchSubscription(Uri.parse('$base/b64')));
    expect(r.nodes.single.name, 'n');
  });

  test('a refusal says what it probably means', () async {
    Future<String> msg(String path) async {
      try {
        await fetchSubscription(Uri.parse('$base/$path'));
      } on FetchError catch (e) {
        return e.message;
      }
      return 'no error';
    }

    expect(await msg('forbidden'), contains('403'));
    expect(await msg('gone'), contains('404'));
    expect(await msg('busy'), contains('429'));
    expect(await msg('boom'), contains('502'));
  });

  test('a page that is far too large is refused, not read to the end', () async {
    await expectLater(fetchSubscription(Uri.parse('$base/huge')), throwsA(isA<FetchError>().having((e) => e.message, 'message', contains('太大'))));
  });

  test('a slow server is given up on at the timeout', () async {
    final sw = Stopwatch()..start();
    await expectLater(fetchSubscription(Uri.parse('$base/slow'), timeout: const Duration(milliseconds: 800)), throwsA(isA<FetchError>().having((e) => e.message, 'message', contains('超时'))));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('a server that hangs up mid-answer: dart:io puts the address in its message, ours does not', () async {
    // dart:io's own text: "Connection closed while receiving data, uri = http://127.0.0.1:PORT/cut?token=KEY"
    const key = 'TOKEN-cut-secret';
    try {
      await fetchSubscription(Uri.parse('$base/cut?token=$key'));
      fail('no error');
    } on FetchError catch (e) {
      expect(e.message, isNot(contains(key)));
      expect(e.message, isNot(contains('127.0.0.1')));
      expect(e.message, isNot(contains('uri')));
    }
  });

  test('a redirect to a file:// address, and a redirect loop, both end in a plain message', () async {
    await expectLater(fetchSubscription(Uri.parse('$base/to-file?token=K')), throwsA(isA<FetchError>().having((e) => e.message, 'message', isNot(contains('passwd')))));
    final sw = Stopwatch()..start();
    await expectLater(fetchSubscription(Uri.parse('$base/loop?token=K'), timeout: const Duration(seconds: 3)), throwsA(isA<FetchError>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
  });

  test('only http and https', () async {
    for (final u in ['file:///etc/passwd', 'ftp://x.example.com/a', 'javascript:alert(1)']) {
      await expectLater(fetchSubscription(Uri.parse(u)), throwsA(isA<FetchError>()), reason: u);
    }
  });

  test('no error message repeats the URL, which holds the account key', () async {
    const key = 'TOKEN-abc123-secret';
    final dead = await HttpServer.bind('127.0.0.1', 0);
    final deadPort = dead.port;
    await dead.close(force: true);
    final urls = [
      '$base/forbidden?token=$key',
      '$base/gone?token=$key',
      'http://127.0.0.1:$deadPort/sub?token=$key', // nothing listening
      'http://no-such-host.invalid/sub?token=$key',
      'ftp://x.example.com/$key',
    ];
    for (final u in urls) {
      try {
        await fetchSubscription(Uri.parse(u), timeout: const Duration(seconds: 4));
        fail('expected an error for $u');
      } on FetchError catch (e) {
        // neither the key nor the host it was addressed to; the hint that the
        // address must start with http:// is a rule, not an echo of the input
        expect(e.message, isNot(contains(key)), reason: u);
        expect(e.message, isNot(contains('no-such-host')), reason: u);
        expect(e.message, isNot(contains('127.0.0.1')), reason: u);
        expect(e.message, isNot(contains('x.example.com')), reason: u);
        expect(e.message, isNotEmpty);
      }
    }
  });
}