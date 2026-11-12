import 'dart:async';
import 'dart:typed_data';

import 'package:aurora/features/files/pdf_source.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/range_server.dart';

void main() {
  test('init fetches only the first block and learns the size', () async {
    final srv = Server(seq(100));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    expect(r.size, 100);
    expect(r.etag, 'e1');
    expect(r.chunkCount, 10);
    expect(srv.requests, [(0, 10)]);
    expect(r.head(4), [0, 1, 2, 3]);
  });

  test('a read across blocks fetches each missing block once, and a repeat is served from memory', () async {
    final srv = Server(seq(100));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    srv.requests.clear();
    final buf = Uint8List(25);
    expect(await r.read(buf, 5, 25), 25);
    expect(buf, seq(100).sublist(5, 30));
    expect(srv.requests.toSet(), {(10, 10), (20, 10)}, reason: 'block 0 was already there');
    srv.requests.clear();
    expect(await r.read(Uint8List(25), 5, 25), 25);
    expect(srv.requests, isEmpty);
  });

  test('reads past the end are clamped; the last short block is asked for with its real length', () async {
    final srv = Server(seq(95));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    final buf = Uint8List(30);
    expect(await r.read(buf, 90, 30), 5);
    expect(buf.sublist(0, 5), seq(95).sublist(90));
    expect(srv.requests.last, (90, 5));
    expect(await r.read(Uint8List(4), 95, 4), 0);
    expect(await r.read(Uint8List(4), 500, 4), 0);
  });

  test('two reads of the same missing block share one request', () async {
    final srv = Server(seq(100));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    srv.requests.clear();
    final gate = srv.hold = Completer<void>();
    final a = r.read(Uint8List(5), 50, 5);
    final b = r.read(Uint8List(5), 52, 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete(); // the first request took the hold; the second read joined it
    expect(await a, 5);
    expect(await b, 5);
    expect(srv.requests, [(50, 10)]);
  });

  test('a file replaced on the server is refused, never mixed', () async {
    final srv = Server(seq(100));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    srv.etag = 'e2';
    await expectLater(r.read(Uint8List(5), 50, 5), throwsA(isA<RemoteChanged>()));
    srv.etag = 'e1';
    srv.bytes = seq(120); // same etag, different size: also a change
    await expectLater(r.read(Uint8List(5), 60, 5), throwsA(isA<RemoteChanged>()));
  });

  test('a stream that ends early is an error, not a short page', () async {
    final srv = Server(seq(100));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    srv.dropEnd = true;
    await expectLater(r.read(Uint8List(5), 50, 5), throwsA(isA<OpError>()));
  });

  test('preload fetches every block, reports progress, and then nothing more is requested', () async {
    final srv = Server(seq(100));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    final seen = <int>[];
    await r.preload(onProgress: (d, t) => seen.add(d));
    expect(seen.last, 10);
    expect(srv.requests.length, 10, reason: 'each block exactly once, block 0 not again');
    srv.requests.clear();
    final buf = Uint8List(100);
    expect(await r.read(buf, 0, 100), 100);
    expect(buf, seq(100));
    expect(srv.requests, isEmpty);
  });

  test('on demand, old blocks are dropped (bounded memory) and fetched again if needed', () async {
    final srv = Server(seq(400));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 4); // 100 blocks, more than the cache keeps
    await r.init();
    for (var i = 0; i < 100; i++) {
      await r.read(Uint8List(4), i * 4, 4);
    }
    srv.requests.clear();
    await r.read(Uint8List(4), 0, 4);
    expect(srv.requests, [(0, 4)], reason: 'block 0 fell out of the cache');
    srv.requests.clear();
    await r.read(Uint8List(4), 396, 4);
    expect(srv.requests, isEmpty, reason: 'the newest block is still there');
  });

  test('close cancels a request in flight', () async {
    final srv = Server(seq(100));
    final r = RemoteRangeReader(srv.open, 'home', '/a.pdf', chunk: 10);
    await r.init();
    final gate = srv.hold = Completer<void>();
    final pending = r.read(Uint8List(5), 50, 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    r.close();
    gate.complete();
    await expectLater(pending, throwsA(isA<OpError>()));
    await expectLater(r.read(Uint8List(5), 60, 5), throwsA(isA<OpError>()), reason: 'a closed reader fetches nothing');
  });
}
