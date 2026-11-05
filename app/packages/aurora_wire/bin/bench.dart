// Benchmark of the Dart client against the real Go entry
// (agent/cmd/aurora3-testpeer). Same items as agent/cmd/aurora3-bench, so the
// two clients can be compared (docs/DESIGN.md 5.3).
//
//   dart run bin/bench.dart <testpeer binary>         start a local peer
//   dart run bin/bench.dart host:port pin token       use a running peer
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';

Future<void> main(List<String> args) async {
  Process? peer;
  Endpoint ep;
  if (args.length == 1) {
    peer = await Process.start(args[0], const []);
    peer.stderr.drain<void>();
    final line = await peer.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
    final m = jsonDecode(line) as Map<String, dynamic>;
    final a = m['addr'] as String;
    final i = a.lastIndexOf(':');
    ep = Endpoint(host: a.substring(0, i), port: int.parse(a.substring(i + 1)), pin: m['pin'] as String, token: m['token'] as String);
  } else if (args.length == 3) {
    final i = args[0].lastIndexOf(':');
    ep = Endpoint(host: args[0].substring(0, i), port: int.parse(args[0].substring(i + 1)), pin: args[1], token: args[2]);
  } else {
    stderr.writeln('usage: bench.dart <testpeer> | host:port pin token');
    exit(2);
  }
  try {
    await run(ep);
  } finally {
    await peer?.stdin.close();
    await peer?.exitCode;
  }
}

String mbps(int bytes, Duration d) => (bytes / d.inMicroseconds).toStringAsFixed(1); // MB/s = bytes/us

String pct(List<int> us, double q) {
  final s = [...us]..sort();
  return (s[((s.length - 1) * q).round()] / 1000).toStringAsFixed(2);
}

Future<void> run(Endpoint ep) async {
  final sw = Stopwatch()..start();
  final l = await Link.dial(ep, client: 'bench');
  print('dial (tcp+tls+hello)      ${(sw.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms');

  // warm up
  for (var i = 0; i < 50; i++) {
    await l.call('test.echo', {'text': 'w'});
  }

  // Idle round trips: one unary call at a time.
  final rtt = <int>[];
  for (var i = 0; i < 500; i++) {
    final t = Stopwatch()..start();
    await l.call('test.echo', {'text': 'x'});
    rtt.add(t.elapsedMicroseconds);
  }
  print('unary call, idle          p50 ${pct(rtt, .5)} ms  p99 ${pct(rtt, .99)} ms');

  final pings = <int>[];
  for (var i = 0; i < 200; i++) {
    pings.add((await l.ping()).inMicroseconds);
  }
  print('yamux ping, idle          p50 ${pct(pings, .5)} ms  p99 ${pct(pings, .99)} ms');

  // Calls per second with 64 in flight.
  sw.reset();
  var n = 0;
  final until = DateTime.now().add(const Duration(seconds: 2));
  await Future.wait([
    for (var w = 0; w < 64; w++)
      () async {
        while (DateTime.now().isBefore(until)) {
          await l.call('test.echo', {'text': 'c'});
          n++;
        }
      }()
  ]);
  print('unary calls, 64 parallel  ${(n / sw.elapsedMicroseconds * 1e6).toStringAsFixed(0)} /s');

  // One download stream.
  const size = 512 << 20;
  sw.reset();
  await download(l, size);
  final d1 = sw.elapsed;
  print('download, 1 stream        ${mbps(size, d1)} MB/s');

  // Four download streams at once.
  sw.reset();
  await Future.wait([for (var i = 0; i < 4; i++) download(l, size ~/ 4)]);
  print('download, 4 streams       ${mbps(size, sw.elapsed)} MB/s (total)');

  // One upload stream.
  sw.reset();
  await upload(l, size);
  print('upload, 1 stream          ${mbps(size, sw.elapsed)} MB/s');

  // Interactive latency while a download runs.
  final dl = await l.open('test.source', {'bytes': 4 << 30}, Priority.bulk);
  await dl.response();
  var bulk = 0;
  final drain = () async {
    try {
      while (true) {
        final f = await dl.read();
        if (f == null || f.isEnd) break;
        bulk += f.payload.length;
      }
    } catch (_) {}
  }();
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final pipe = await l.open('test.pipe');
  await pipe.response();
  final keys = <int>[];
  final busy = Stopwatch()..start();
  final b0 = bulk;
  for (var i = 0; i < 200; i++) {
    final t = Stopwatch()..start();
    await pipe.sendData(const [0x61]);
    await pipe.read();
    keys.add(t.elapsedMicroseconds);
  }
  final during = mbps(bulk - b0, busy.elapsed);
  dl.reset();
  await drain;
  await pipe.sendEnd();
  print('key echo during download  p50 ${pct(keys, .5)} ms  p99 ${pct(keys, .99)} ms  (download ran at $during MB/s)');
  print('socket writes ${l.session.socketWrites}, bytes out ${l.session.bytesOut}');
  await l.close();
}

Future<void> download(Link l, int size) async {
  final op = await l.open('test.source', {'bytes': size}, Priority.bulk);
  await op.response();
  var got = 0;
  while (true) {
    final f = (await op.read())!;
    if (f.isEnd) break;
    got += f.payload.length;
  }
  if (got != size) throw StateError('download: $got of $size');
}

Future<void> upload(Link l, int size) async {
  final op = await l.open('test.sink', null, Priority.bulk);
  final frame = encodeFrame(typeData, Uint8List(dataChunk));
  // pattern check is off for speed: fill with the pattern of offset 0 only
  for (var off = 0; off < size; off += dataChunk) {
    await op.send(frame);
  }
  await op.sendEnd();
  final r = await op.response() as Map;
  if (r['bytes'] != size) throw StateError('upload: ${r['bytes']} of $size');
}
