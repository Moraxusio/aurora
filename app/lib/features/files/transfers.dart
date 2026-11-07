// Uploads and downloads of one server. They belong to the workspace, not to
// the file tree widget: closing the side bar or switching to another view
// must not stop a transfer or lose its progress. Transfers run on the bulk
// priority, so the terminal stays responsive (DESIGN 5.3).
import 'dart:async';
import 'dart:io';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

class Transfer extends ChangeNotifier {
  final bool upload;
  final String name;
  int total;
  int done = 0;
  bool finished = false;
  bool cancelled = false;
  String? error;
  final Stopwatch sw = Stopwatch()..start();
  OpStream? _stream;

  Transfer(this.upload, this.name, this.total);

  double? get fraction => total <= 0 ? null : (done / total).clamp(0, 1).toDouble();

  /// Bytes per second since the start.
  double get rate {
    final s = sw.elapsedMicroseconds / 1e6;
    return s < 0.2 ? 0 : done / s;
  }

  void _progress(int n) {
    done += n;
    notifyListeners();
  }

  void _end([String? err]) {
    if (finished) return;
    finished = true;
    error = cancelled ? null : err;
    sw.stop();
    notifyListeners();
  }

  /// Stops the transfer now; a partial download is deleted, a partial upload
  /// never replaces the file (the agent writes to a temporary name and
  /// renames only on a complete stream).
  void cancel() {
    if (finished) return;
    cancelled = true;
    _stream?.reset();
    _end();
  }
}

class Transfers extends ChangeNotifier {
  final List<Transfer> list = [];

  int get active => list.where((t) => !t.finished).length;

  void clearFinished() {
    list.removeWhere((t) => t.finished);
    notifyListeners();
  }

  void remove(Transfer t) {
    list.remove(t);
    notifyListeners();
  }

  Transfer _add(Transfer t) {
    list.add(t);
    t.addListener(notifyListeners);
    notifyListeners();
    return t;
  }

  /// Sends [local] to [root]:[path]. [onDone] runs after a successful upload.
  Transfer upload(Link link, File local, int size, String root, String path, {VoidCallback? onDone}) {
    final t = _add(Transfer(true, path.split('/').last, size));
    unawaited(_runUpload(t, link, local, root, path, onDone));
    return t;
  }

  Future<void> _runUpload(Transfer t, Link link, File local, String root, String path, VoidCallback? onDone) async {
    try {
      final s = await link.open('fs.upload', {'root': root, 'path': path, 'size': t.total}, Priority.bulk);
      t._stream = s;
      await s.response();
      await for (final chunk in local.openRead()) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        for (var off = 0; off < bytes.length; off += dataChunk) {
          if (t.cancelled) return;
          final end = off + dataChunk < bytes.length ? off + dataChunk : bytes.length;
          await s.sendData(Uint8List.sublistView(bytes, off, end));
          t._progress(end - off);
        }
      }
      if (t.cancelled) return;
      await s.sendEnd();
      await s.response();
      await s.close();
      t._end();
      onDone?.call();
    } on Object catch (e) {
      t._end(e is OpError ? e.message : '$e');
    }
  }

  /// Downloads [root]:[path] into [where] (a file path that does not exist yet).
  Transfer download(Link link, String root, String path, String where, int size, {VoidCallback? onDone}) {
    final t = _add(Transfer(false, path.split('/').last, size));
    unawaited(_runDownload(t, link, root, path, where, onDone));
    return t;
  }

  Future<void> _runDownload(Transfer t, Link link, String root, String path, String where, VoidCallback? onDone) async {
    final tmp = File('$where.aurora3-part');
    IOSink? out;
    try {
      final s = await link.open('fs.download', {'root': root, 'path': path}, Priority.bulk);
      t._stream = s;
      final meta = await s.response() as Map;
      t.total = (meta['length'] as num).toInt();
      out = tmp.openWrite();
      var ended = false;
      while (true) {
        final f = await s.read();
        if (f == null) break;
        if (f.type == typeData) {
          out.add(f.payload);
          t._progress(f.payload.length);
        } else if (f.type == typeEnd) {
          ended = true;
          break;
        }
      }
      await out.close();
      out = null;
      if (t.cancelled) throw StateError('cancelled');
      if (!ended || t.done != t.total) throw StateError('下载不完整：${t.done} / ${t.total} 字节');
      await tmp.rename(where);
      t._end();
      onDone?.call();
    } on Object catch (e) {
      try {
        await out?.close();
        if (await tmp.exists()) await tmp.delete();
      } on Object {
        // best effort: the part file is only a temporary name
      }
      t._end(e is OpError ? e.message : '$e');
    }
  }
}
