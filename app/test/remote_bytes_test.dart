import 'dart:async';

import 'package:aurora/features/files/remote_bytes.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_download.dart';

class _NoLink implements Link {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<RemoteBytes> read(FakeDownload d, {int max = 1000, ReadCancel? cancel, void Function(int, int)? progress}) =>
      readRemoteBytes(_NoLink(), 'home', '/a.png', maxBytes: max, cancel: cancel, onProgress: progress, opener: (_, _) async => d);

  test('joins the chunks and reports progress', () async {
    final d = FakeDownload({'length': 6, 'size': 6, 'etag': 'e1'}, [data([1, 2]), data([3, 4, 5]), data([6]), end()]);
    final seen = <int>[];
    final r = await read(d, progress: (done, total) => seen.add(done));
    expect(r.bytes, [1, 2, 3, 4, 5, 6]);
    expect(r.etag, 'e1');
    expect(seen, [2, 5, 6]);
    expect(d.closed, isTrue);
  });

  test('a file over the limit is refused before any data is read', () async {
    final d = FakeDownload({'length': 5000, 'size': 5000}, [data([1])]);
    await expectLater(read(d, max: 1000), throwsA(isA<RemoteTooLarge>().having((e) => e.size, 'size', 5000)));
    expect(d.wasReset, isTrue);
    expect(d.reads, 0);
  });

  test('a stream that ends short is an error, not a cut-off file', () async {
    final d = FakeDownload({'length': 10, 'size': 10}, [data([1, 2, 3]), end()]);
    await expectLater(read(d), throwsA(isA<OpError>()));
  });

  test('a stream that drops without the end frame is an error', () async {
    final d = FakeDownload({'length': 3, 'size': 3}, [data([1, 2, 3])]);
    await expectLater(read(d), throwsA(isA<OpError>()));
  });

  test('cancelling stops the read and resets the stream', () async {
    final gate = Completer<void>();
    final d = FakeDownload({'length': 4, 'size': 4}, [data([1, 2]), data([3, 4]), end()], gate: gate);
    final c = ReadCancel();
    final f = read(d, cancel: c);
    await Future<void>.delayed(Duration.zero);
    c.cancel();
    gate.complete();
    await expectLater(f, throwsA(isA<OpError>()));
    expect(d.wasReset, isTrue);
  });
}
