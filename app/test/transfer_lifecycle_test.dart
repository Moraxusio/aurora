import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/features/files/transfers.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

class _Stream extends Fake implements OpStream {
  int reads = 0, resets = 0;
  bool fail = false;
  Completer<Object?>? metadata;
  final resetDone = Completer<void>();
  @override
  Future<Object?> response() async {
    if (fail) throw OpError(codeUnavailable, 'old connection');
    return metadata == null ? {'length': 6} : metadata!.future;
  }

  @override
  Future<Frame?> read() async => reads++ < 2
      ? Frame(typeData, Uint8List.fromList([1, 2, 3]))
      : Frame(typeEnd, Uint8List(0));
  @override
  void reset() {
    resets++;
    if (!resetDone.isCompleted) resetDone.complete();
  }
}

class _Link extends Fake implements Link {
  final _Stream stream;
  Completer<OpStream>? gate;
  int opens = 0;
  _Link(this.stream);
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    opens++;
    return gate?.future ?? stream;
  }
}

Future<void> finish(Transfer t) async {
  if (t.finished) return;
  final done = Completer<void>();
  void changed() {
    if (t.finished && !done.isCompleted) done.complete();
  }

  t.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    t.removeListener(changed);
  }
}

void main() {
  test(
    'queue admits three streams and removed transfers cannot publish or notify',
    () async {
      final dir = await Directory.systemTemp.createTemp('aurora-transfer-');
      addTearDown(() => dir.delete(recursive: true));
      final links = List.generate(
        8,
        (_) => _Link(_Stream()..metadata = Completer<Object?>()),
      );
      final transfers = Transfers();
      addTearDown(transfers.dispose);
      var completed = 0;
      final tasks = [
        for (var i = 0; i < links.length; i++)
          transfers.download(
            links[i],
            'home',
            '/file$i',
            '${dir.path}/file$i',
            6,
            onDone: () => completed++,
          ),
      ];
      expect(links.map((l) => l.opens), [1, 1, 1, 0, 0, 0, 0, 0]);
      transfers.remove(tasks[0]);
      transfers.remove(tasks[3]);
      for (final link in links) {
        link.stream.metadata!.complete({'length': 6});
      }
      await Future.wait([for (final task in tasks) finish(task)]);
      expect(completed, 6);
      expect(links[3].opens, 0);
      expect(await File('${dir.path}/file0').exists(), isFalse);
      expect(await File('${dir.path}/file3').exists(), isFalse);
      expect(await dir.list().length, 6);
      expect(transfers.active, 0);
    },
  );

  test(
    'oversized download stops before extra disk write and deletes partial data',
    () async {
      final dir = await Directory.systemTemp.createTemp('aurora-transfer-');
      addTearDown(() => dir.delete(recursive: true));
      final stream = _Stream()
        ..metadata = (Completer<Object?>()..complete({'length': 4}));
      final transfers = Transfers();
      addTearDown(transfers.dispose);
      final task = transfers.download(
        _Link(stream),
        'home',
        '/bad',
        '${dir.path}/bad',
        4,
      );
      await finish(task);
      expect(task.error, contains('超过声明大小'));
      expect(task.done, 3);
      expect(stream.reads, 2);
      expect(await dir.list().isEmpty, isTrue);
    },
  );

  test('download awaits disk writes before reading another frame and resets its stream', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-transfer-');
    addTearDown(() => dir.delete(recursive: true));
    final stream = _Stream();
    final actual = _Link(stream);
    final writing = Completer<void>(), release = Completer<void>();
    var writes = 0;
    final transfers = Transfers(
      writeChunk: (file, bytes) async {
        if (writes++ == 0) {
          writing.complete();
          await release.future;
        }
        await file.writeFrom(bytes);
      },
    );
    addTearDown(transfers.dispose);
    final target = '${dir.path}/download';
    final t = transfers.download(actual, 'home', '/file', target, 6);
    await writing.future;
    expect(stream.reads, 1);
    expect(t.done, 0);
    release.complete();
    await finish(t);
    expect(t.error, isNull);
    expect(await File(target).readAsBytes(), [1, 2, 3, 1, 2, 3]);
    expect(stream.resets, 1);
  });

  test(
    'retry obtains the replacement connection and cleans failed attempts',
    () async {
      final dir = await Directory.systemTemp.createTemp('aurora-transfer-');
      addTearDown(() => dir.delete(recursive: true));
      final old = _Link(_Stream()..fail = true), next = _Link(_Stream());
      Link current = old;
      final transfers = Transfers();
      addTearDown(transfers.dispose);
      final t = transfers.download(
        old,
        'home',
        '/file',
        '${dir.path}/download',
        6,
        currentLink: () => current,
      );
      await finish(t);
      expect(t.error, isNotNull);
      expect(old.stream.resets, 1);
      current = next;
      t.retry();
      await finish(t);
      expect(t.error, isNull);
      expect(next.opens, 1);
      expect(old.opens, 1);
      expect(await dir.list().length, 1);
    },
  );

  test('cancelling before open resolves resets the late stream without creating a file', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-transfer-');
    addTearDown(() => dir.delete(recursive: true));
    final stream = _Stream();
    final link = _Link(stream)..gate = Completer<OpStream>();
    final transfers = Transfers();
    addTearDown(transfers.dispose);
    final t = transfers.download(
      link,
      'home',
      '/file',
      '${dir.path}/download',
      6,
    );
    t.cancel();
    link.gate!.complete(stream);
    await stream.resetDone.future;
    expect(await dir.list().isEmpty, isTrue);
    expect(t.cancelled, isTrue);
  });

  test('disk failure preserves an existing target and cleans the private partial directory', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-transfer-');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/download');
    await target.writeAsString('keep existing');
    final stream = _Stream();
    final transfers = Transfers(
      writeChunk: (_, _) async => throw const FileSystemException('disk full'),
    );
    addTearDown(transfers.dispose);
    final t = transfers.download(
      _Link(stream),
      'home',
      '/file',
      target.path,
      6,
    );
    await finish(t);
    expect(t.error, contains('disk full'));
    expect(await target.readAsString(), 'keep existing');
    expect(await dir.list().length, 1);
    expect(stream.resets, 1);
  });
}
