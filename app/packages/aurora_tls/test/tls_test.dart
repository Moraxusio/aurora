// Tests against Go's crypto/tls (agent/cmd/aurora3-tlspeer): pinned
// handshake, data both ways, wrong pin, peer close. Set AURORA3_TLSPEER to
// the built binary; without it the tests are skipped.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_tls/aurora_tls.dart';
import 'package:test/test.dart';

Uint8List hexBytes(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

class Peer {
  final Process p;
  final String host;
  final int port;
  final Uint8List pin;
  Peer(this.p, this.host, this.port, this.pin);

  static Future<Peer> start(String mode) async {
    final p = await Process.start(Platform.environment['AURORA3_TLSPEER']!, ['-mode', mode]);
    p.stderr.drain<void>();
    final m = jsonDecode(await p.stdout.transform(utf8.decoder).transform(const LineSplitter()).first) as Map;
    final a = m['addr'] as String;
    final i = a.lastIndexOf(':');
    return Peer(p, a.substring(0, i), int.parse(a.substring(i + 1)), hexBytes(m['pin'] as String));
  }

  Future<void> stop() async {
    p.kill();
    await p.exitCode;
  }
}

/// Collects a stream's bytes; [take] waits for the next n of them.
class Collector {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _have = Uint8List(0);
  Completer<void>? _wait;
  Collector(Stream<Uint8List> s) {
    s.listen((c) {
      _buf
        ..add(_have)
        ..add(c);
      _have = _buf.takeBytes();
      _wait?.complete();
      _wait = null;
    });
  }

  Future<Uint8List> take(int n) async {
    while (_have.length < n) {
      _wait = Completer<void>();
      await _wait!.future;
    }
    final out = Uint8List.fromList(Uint8List.sublistView(_have, 0, n));
    _have = Uint8List.sublistView(_have, n);
    return out;
  }
}

void main() {
  final bin = Platform.environment['AURORA3_TLSPEER'];
  final skip = bin == null || bin.isEmpty ? 'AURORA3_TLSPEER not set' : null;

  test('library version', () {
    expect(tlsLibraryVersion(), startsWith('BoringSSL 0.2026'));
  });

  test('handshake with the pin, echo both ways', () async {
    final peer = await Peer.start('echo');
    final s = await TlsSocket.connect(peer.host, peer.port, peer.pin);
    expect(s.cipher, contains('AES'));
    final col = Collector(s.input);
    for (final size in [1, 100, 16384, 16385, 100000, 1 << 20]) {
      final data = Uint8List(size);
      for (var i = 0; i < size; i++) {
        data[i] = (i * 7 + size) & 255;
      }
      final back = col.take(size);
      await s.write(data);
      await s.flush();
      expect(await back.timeout(const Duration(seconds: 10)), data, reason: '$size bytes');
    }
    await s.close();
    await peer.stop();
  }, skip: skip);

  test('wrong pin fails with pinMismatch', () async {
    final peer = await Peer.start('echo');
    final bad = Uint8List(32)..fillRange(0, 32, 0xab);
    await expectLater(TlsSocket.connect(peer.host, peer.port, bad),
        throwsA(isA<TlsException>().having((e) => e.kind, 'kind', TlsFailure.pinMismatch)));
    await peer.stop();
  }, skip: skip);

  test('nothing listening fails with network', () async {
    final ss = await ServerSocket.bind('127.0.0.1', 0);
    final port = ss.port;
    await ss.close();
    await expectLater(TlsSocket.connect('127.0.0.1', port, Uint8List(32)),
        throwsA(isA<TlsException>().having((e) => e.kind, 'kind', TlsFailure.network)));
  }, skip: skip);

  test('64 MiB from the server arrives intact', () async {
    final peer = await Peer.start('source');
    final s = await TlsSocket.connect(peer.host, peer.port, peer.pin);
    var got = 0;
    var ok = true;
    final sw = Stopwatch()..start();
    await for (final c in s.input) {
      for (var i = 0; i < c.length; i += 997) {
        if (c[i] != (got + i) % 251) ok = false;
      }
      got += c.length;
      if (got >= 64 << 20) break;
    }
    print('source: ${(got / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s, cipher ${s.cipher}');
    expect(got, greaterThanOrEqualTo(64 << 20));
    expect(ok, isTrue);
    s.destroy();
    await peer.stop();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('the server closing cleanly ends the input stream', () async {
    final peer = await Peer.start('hello-close');
    final s = await TlsSocket.connect(peer.host, peer.port, peer.pin);
    final all = <int>[];
    await for (final c in s.input) {
      all.addAll(c);
    }
    expect(utf8.decode(all), 'hello');
    await peer.stop();
  }, skip: skip);
}
