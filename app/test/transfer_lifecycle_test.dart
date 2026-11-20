import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/features/files/transfers.dart';
import 'package:aurora/features/files/download_publish.dart';
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

class _UploadStream extends _Stream {
  final dataSent = Completer<void>();
  final resume = Completer<void>();
  int endsSent = 0;

  @override
  Future<void> sendData(List<int> payload) {
    dataSent.complete();
    return resume.future;
  }

  @override
  Future<void> sendEnd() async => endsSent++;
}

class _Link extends Fake implements Link {
  final _Stream stream;
  Completer<OpStream>? gate;
  int opens = 0;
  Object? lastArgs;
  final String agentId;
  _Link(this.stream, {this.agentId = 'fixture'});
  @override
  AgentInfo get server => AgentInfo({
    'id': agentId,
    'direct': {'cert_sha256': 'fixture-pin'},
  });
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    opens++;
    lastArgs = args;
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
  test('download publish never replaces a file at the final path', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-publish-');
    addTearDown(() => dir.delete(recursive: true));
    final part = await File('${dir.path}/待发布.part').writeAsString('download');
    final dest = File('${dir.path}/报告.txt');
    expect(await dest.exists(), isFalse);
    await dest.writeAsString('independent edit');
    await expectLater(publishDownload(part, dest.path), throwsA(isA<FileSystemException>()));
    expect(await dest.readAsString(), 'independent edit');
    expect(await part.readAsString(), 'download');
    await publishDownload(part, '${dir.path}/报告-副本.txt');
    expect(await File('${dir.path}/报告-副本.txt').readAsString(), 'download');
    expect(await part.exists(), isFalse);
  });
  test('upload sends explicit create/version authorization and never retargets a retry', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-upload-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/source').writeAsString('fixture');
    final old = _Link(_Stream()..fail = true);
    final replacement = _Link(_Stream()..fail = true);
    Link current = old;
    final transfers = Transfers();
    addTearDown(transfers.dispose);

    final create = transfers.upload(old, file, 7, 'home', '/new',
      currentLink: () => current);
    await finish(create);
    expect(old.lastArgs, containsPair('create', true));
    final overwrite = transfers.upload(old, file, 7, 'home', '/existing',
      ifMatch: 'reviewed-etag', currentLink: () => current);
    await finish(overwrite);
    expect(old.lastArgs, containsPair('if_match', 'reviewed-etag'));
    expect(old.lastArgs as Map, isNot(contains('create')));
    current = replacement;
    overwrite.retry();
    await finish(overwrite);
    expect(overwrite.error, contains('连接已变化'));
    expect(replacement.opens, 0);
  });

  test('upload checks again before authorizing commit after a local edit', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-upload-edit-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/source').writeAsString('fixture');
    final stream = _UploadStream();
    final transfers = Transfers();
    addTearDown(transfers.dispose);
    var edited = false;
    final task = transfers.upload(_Link(stream), file, 7, 'home', '/existing',
      ifMatch: 'reviewed-etag',
      verifyTarget: () {
        if (edited) throw OpError(codeConflict, '目标有未保存的修改');
      });
    await stream.dataSent.future.timeout(const Duration(seconds: 5));
    edited = true;
    stream.resume.complete();
    await finish(task);
    expect(task.error, contains('未保存'));
    expect(stream.endsSent, 0);
    expect(stream.resets, 1);
  });
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

  test('download retry must not use a differently paired agent', () async {
    final dir = await Directory.systemTemp.createTemp('aurora-download-pairing-');
    addTearDown(() => dir.delete(recursive: true));
    final old = _Link(_Stream()..fail = true);
    final other = _Link(_Stream(), agentId: 'other');
    Link current = old;
    final transfers = Transfers();
    addTearDown(transfers.dispose);
    final task = transfers.download(old, 'home', '/example', '${dir.path}/example', 6,
      currentLink: () => current);
    await finish(task);
    current = other;
    task.retry();
    await finish(task);
    expect(task.error, contains('连接已变化'));
    expect(other.opens, 0);
    expect(await dir.list().isEmpty, isTrue);
  });

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
