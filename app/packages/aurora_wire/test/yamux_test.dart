import 'dart:async';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora_wire/src/yamux.dart' show headerSize, typeDataFrame, flagSyn;
import 'package:test/test.dart';

/// One end of an in-memory byte pipe. Writes reach the other end in a later
/// microtask, in order; [delay] simulates latency.
class PipeEnd implements Transport {
  late PipeEnd peer;
  void Function(Uint8List)? _onData;
  void Function()? _onDone;
  final List<Uint8List> _early = [];
  bool closed = false;
  final Duration delay;
  int writes = 0;
  PipeEnd(this.delay);

  @override
  void listen(void Function(Uint8List) onData, void Function(Object) onError, void Function() onDone) {
    _onData = onData;
    _onDone = onDone;
    for (final b in _early) {
      onData(b);
    }
    _early.clear();
  }

  void _deliver(Uint8List b) {
    if (closed) return;
    final f = _onData;
    if (f == null) {
      _early.add(b);
    } else {
      f(b);
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (closed) throw StateError('closed');
    writes++;
    final copy = Uint8List.fromList(bytes);
    if (delay == Duration.zero) {
      scheduleMicrotask(() => peer._deliver(copy));
    } else {
      Timer(delay, () => peer._deliver(copy));
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    scheduleMicrotask(() {
      if (!peer.closed) {
        peer.closed = true;
        peer._onDone?.call();
      }
    });
  }
}

(PipeEnd, PipeEnd) pipe([Duration delay = Duration.zero]) {
  final a = PipeEnd(delay), b = PipeEnd(delay);
  a.peer = b;
  b.peer = a;
  return (a, b);
}

const noKeepAlive = YamuxConfig(keepAliveInterval: null);

Future<Uint8List> readAll(YamuxStream st) async {
  final out = BytesBuilder(copy: false);
  while (true) {
    final c = await st.next();
    if (c == null) return out.takeBytes();
    out.add(c);
  }
}

void main() {
  test('open, send both ways, close both ways', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: noKeepAlive);
    final srv = Session.server(b, config: noKeepAlive);
    final accepted = srv.accepted.first;
    final c = await cli.open();
    expect(c.id, 1, reason: 'client streams are odd');
    await c.write([1, 2, 3]);
    final s = await accepted;
    expect(s.id, 1);
    expect(await s.readExactly(3), [1, 2, 3]);
    await s.write([4, 5]);
    await s.close();
    expect(await readAll(c), [4, 5]);
    await c.close();
    expect(await s.next(), isNull);
    await c.established;
    await cli.close();
    await srv.done;
  });

  test('a large transfer respects the window and arrives intact', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: noKeepAlive);
    final srv = Session.server(b, config: noKeepAlive);
    final accepted = srv.accepted.first;
    const size = 20 * 1024 * 1024;
    final data = Uint8List(size);
    for (var i = 0; i < size; i++) {
      data[i] = i % 251;
    }
    final c = await cli.open(priority: Priority.bulk);
    final w = c.write(data).then((_) => c.close());
    final s = await accepted;
    var got = 0;
    var ok = true;
    while (true) {
      final chunk = await s.next();
      if (chunk == null) break;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != (got + i) % 251) ok = false;
      }
      got += chunk.length;
      // The sender may never be more than one window ahead.
      expect(s.buffered, lessThanOrEqualTo(4 * 1024 * 1024));
    }
    await w;
    expect(got, size);
    expect(ok, isTrue);
    await cli.close();
  });

  test('writes in one turn share a socket write', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: noKeepAlive);
    Session.server(b, config: noKeepAlive);
    final streams = [for (var i = 0; i < 20; i++) await cli.open()];
    await Future<void>.delayed(Duration.zero);
    final before = a.writes;
    await Future.wait([for (final st in streams) st.write([1, 2, 3])]);
    expect(a.writes - before, lessThanOrEqualTo(2), reason: '20 small frames, one turn');
    await cli.close();
  });

  test('interactive frames overtake a bulk transfer', () async {
    final (a, b) = pipe(const Duration(milliseconds: 1));
    final cli = Session.client(a, config: noKeepAlive);
    final srv = Session.server(b, config: noKeepAlive);
    final order = <int>[];
    srv.accepted.listen((s) async {
      try {
        while (await s.next(64 * 1024) != null) {
          order.add(s.id);
        }
      } on SessionClosed {
        // the test closes the session while the bulk stream is still running
      }
    });
    final bulk = await cli.open(priority: Priority.bulk);
    final key = await cli.open(priority: Priority.interactive);
    unawaited(bulk.write(Uint8List(3 * 1024 * 1024)));
    await key.write([42]);
    await key.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final firstKey = order.indexOf(key.id);
    expect(firstKey, isNonNegative, reason: 'the key frame must arrive');
    final bulkBefore = order.sublist(0, firstKey).where((id) => id == bulk.id).length;
    // The key frame must not wait behind the whole 3 MiB: at most one batch
    // of bulk data (256 KiB in 64 KiB frames) goes first.
    expect(bulkBefore, lessThanOrEqualTo(8));
    await cli.close();
  });

  test('ping measures a round trip', () async {
    final (a, b) = pipe(const Duration(milliseconds: 5));
    final cli = Session.client(a, config: noKeepAlive);
    Session.server(b, config: noKeepAlive);
    final rtt = await cli.ping();
    expect(rtt.inMilliseconds, greaterThanOrEqualTo(9));
    await cli.close();
  });

  test('reset fails the other side', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: noKeepAlive);
    final srv = Session.server(b, config: noKeepAlive);
    final accepted = srv.accepted.first;
    final c = await cli.open();
    await c.write([1]);
    final s = await accepted;
    await s.readExactly(1);
    c.reset();
    await expectLater(s.next(), throwsA(isA<StreamReset>()));
    await expectLater(c.write([2]), throwsA(isA<StreamReset>()));
    await cli.close();
  });

  test('the peer closing ends the session and fails waiting reads', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: noKeepAlive);
    final srv = Session.server(b, config: noKeepAlive);
    final c = await cli.open();
    await c.write([1]);
    final read = c.next();
    await b.close();
    await expectLater(read, throwsA(isA<SessionClosed>()));
    expect(await cli.done, isNotEmpty);
    expect(srv.isClosed || b.closed, isTrue);
  });

  test('a bad header ends the session with a protocol error', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: noKeepAlive);
    final bad = Uint8List(headerSize);
    bad[0] = 9; // version
    await b.write(bad);
    expect(await cli.done, contains('协议错误'));
  });

  test('data beyond the window is a protocol error', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: const YamuxConfig(keepAliveInterval: null, maxStreamWindow: 256 * 1024));
    // A peer that opens stream 2 and sends 300 KiB at once, ignoring the
    // 256 KiB window.
    final hdr = ByteData(headerSize)
      ..setUint8(1, typeDataFrame)
      ..setUint16(2, flagSyn)
      ..setUint32(4, 2)
      ..setUint32(8, 300 * 1024);
    final frame = BytesBuilder()
      ..add(hdr.buffer.asUint8List())
      ..add(Uint8List(300 * 1024));
    await b.write(frame.takeBytes());
    expect(await cli.done, contains('receive window exceeded'));
  });

  test('frames split at any byte boundary still parse', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: noKeepAlive);
    final srv = Session.server(b, config: noKeepAlive);
    final accepted = srv.accepted.first;
    final c = await cli.open();
    // Encode three operation frames, write them one byte at a time.
    final bytes = BytesBuilder()
      ..add(encodeJson({'op': 'x'}))
      ..add(encodeFrame(typeData, [1, 2, 3, 4]))
      ..add(encodeFrame(typeEnd, const []));
    final all = bytes.takeBytes();
    for (final byte in all) {
      await c.write([byte]);
    }
    await c.close();
    final s = await accepted;
    final r = FrameReader(s);
    expect((await r.read())!.json(), {'op': 'x'});
    expect((await r.read())!.payload, [1, 2, 3, 4]);
    expect((await r.read())!.isEnd, isTrue);
    expect(await r.read(), isNull);
    await cli.close();
  });

  test('opens wait when the peer backlog is full', () async {
    final (a, b) = pipe();
    final cli = Session.client(a, config: const YamuxConfig(keepAliveInterval: null, acceptBacklog: 4));
    // A server that never answers: streams stay unacknowledged.
    b.listen((_) {}, (_) {}, () {});
    for (var i = 0; i < 4; i++) {
      await cli.open();
    }
    var fifth = false;
    unawaited(cli.open().then((_) => fifth = true, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fifth, isFalse, reason: 'the 5th open must wait for an ACK');
    await cli.close();
  });
}
