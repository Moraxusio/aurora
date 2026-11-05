// Throughput of the TLS engine against aurora3-tlspeer -mode source, with the
// time split between the engine (feed + decrypt, in native code) and the rest
// (socket events and Dart), so the slow stage is visible.
//   dart run bin/speed.dart <aurora3-tlspeer>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_tls/aurora_tls.dart';

Uint8List hexBytes(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

Future<void> main(List<String> args) async {
  final p = await Process.start(args[0], ['-mode', 'source']);
  p.stderr.drain<void>();
  final m = jsonDecode(await p.stdout.transform(utf8.decoder).transform(const LineSplitter()).first) as Map;
  final a = m['addr'] as String;
  final i = a.lastIndexOf(':');
  const size = 512 << 20;
  for (var round = 0; round < 3; round++) {
    final s = await TlsSocket.connect(a.substring(0, i), int.parse(a.substring(i + 1)), hexBytes(m['pin'] as String));
    final sw = Stopwatch()..start();
    var got = 0, chunks = 0;
    await for (final c in s.input) {
      got += c.length;
      chunks++;
      if (got >= size) break;
    }
    final us = sw.elapsedMicroseconds;
    print('round $round: ${(got / us).toStringAsFixed(0)} MB/s  socket reads ${s.socketReads} '
        '(avg ${(got / s.socketReads).toStringAsFixed(0)} B)  chunks $chunks  '
        'engine ${(s.engineMicros / 1000).toStringAsFixed(0)} ms of ${(us / 1000).toStringAsFixed(0)} ms');
    s.destroy();
  }
  p.kill();
}
