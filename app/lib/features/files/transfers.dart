// Uploads and downloads of one server. They belong to the workspace, not to
// the file tree widget: closing the side bar or switching to another view
// must not stop a transfer or lose its progress. Transfers run on the bulk
// priority, so the terminal stays responsive (DESIGN 5.3).
import 'dart:async';
import 'dart:io';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import 'download_publish.dart';

class Transfer extends ChangeNotifier {
  final bool upload;
  final String name;
  int total;
  int done = 0;
  bool finished = false;
  bool cancelled = false;
  bool queued = false;
  String? error;
  final Stopwatch sw = Stopwatch()..start();
  OpStream? _stream;
  Future<void> Function(Transfer)? _retry;
  bool _running = false, _disposed = false;
  Timer? _progressTimer;

  Transfer(this.upload, this.name, this.total);

  double? get fraction =>
      total <= 0 ? null : (done / total).clamp(0, 1).toDouble();

  /// Bytes per second since the start.
  double get rate {
    final s = sw.elapsedMicroseconds / 1e6;
    return s < 0.2 ? 0 : done / s;
  }

  void _progress(int n) {
    done += n;
    if (_disposed || finished) return;
    _progressTimer ??= Timer(const Duration(milliseconds: 50), () {
      _progressTimer = null;
      if (!_disposed && !finished) notifyListeners();
    });
  }

  void _end([String? err]) {
    _progressTimer?.cancel();
    _progressTimer = null;
    if (finished) return;
    finished = true;
    error = cancelled ? null : err;
    sw.stop();
    if (!_disposed) notifyListeners();
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

  void retry() {
    if (_running || !finished || error == null || _disposed) return;
    done = 0;
    error = null;
    cancelled = false;
    finished = false;
    queued = false;
    sw
      ..reset()
      ..start();
    notifyListeners();
    final run = _retry;
    if (run != null) unawaited(run(this));
  }

  @override
  void dispose() {
    cancel();
    _disposed = true;
    _retry = null;
    super.dispose();
  }
}

class Transfers extends ChangeNotifier {
  final List<Transfer> list = [];
  final int maxConcurrent;
  final Future<void> Function(RandomAccessFile, List<int>) writeChunk;
  int _running = 0;
  bool _disposed = false;
  final List<Completer<void>> _waiting = [];

  Transfers({this.maxConcurrent = 3, this.writeChunk = _writeChunk})
    : assert(maxConcurrent > 0);

  static Future<void> _writeChunk(
    RandomAccessFile file,
    List<int> bytes,
  ) async {
    await file.writeFrom(bytes);
  }

  int get active => list.where((t) => !t.finished).length;

  int get failed => list.where((t) => t.finished && t.error != null).length;

  double? get aggregateFraction {
    final known = list.where((t) => t.total > 0 && !t.cancelled).toList();
    if (known.isEmpty) return null;
    return known.fold<double>(0, (sum, t) => sum + t.done) /
        known.fold<int>(0, (sum, t) => sum + t.total);
  }

  void clearFinished() {
    for (final t in list.where((t) => t.finished).toList()) {
      t.removeListener(notifyListeners);
      t.dispose();
      list.remove(t);
    }
    notifyListeners();
  }

  void remove(Transfer t) {
    list.remove(t);
    t.removeListener(notifyListeners);
    t.dispose();
    notifyListeners();
  }

  Transfer _add(Transfer t) {
    if (_disposed) throw StateError('传输管理器已关闭');
    list.add(t);
    t.addListener(notifyListeners);
    notifyListeners();
    return t;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in list) {
      t.removeListener(notifyListeners);
      t.dispose();
    }
    list.clear();
    for (final waiter in _waiting) {
      waiter.complete();
    }
    _waiting.clear();
    super.dispose();
  }

  Future<void> _run(
    Transfer t,
    Future<void> Function() action,
    VoidCallback? onDone,
  ) async {
    t._running = true;
    var acquired = false;
    String? error;
    var success = false;
    try {
      if (_running >= maxConcurrent) {
        t.queued = true;
        notifyListeners();
        final wait = Completer<void>();
        _waiting.add(wait);
        await wait.future;
      } else {
        _running++;
      }
      acquired = !_disposed;
      t.queued = false;
      if (_disposed || t.cancelled) return;
      t.sw..reset()..start();
      await action();
      if (!t.cancelled) success = true;
    } on Object catch (e) {
      error = e is OpError ? e.message : '$e';
    } finally {
      t._stream?.reset();
      t._stream = null;
      t._running = false;
      if (acquired) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete();
        } else {
          _running--;
        }
      }
      t._end(error);
    }
    if (success && !_disposed) onDone?.call();
  }

  Link _connection(Transfer t, Link? Function() source, [Link? expected]) {
    if (_disposed || t.cancelled) throw StateError('传输已取消');
    final link = source();
    if (link == null || (expected != null && !identical(expected, link))) {
      throw OpError(codeUnavailable, '连接已变化，请重试传输');
    }
    return link;
  }

  /// Sends [local] to [root]:[path]. [onDone] runs after a successful upload.
  Transfer upload(
    Link link,
    File local,
    int size,
    String root,
    String path, {
    String? ifMatch,
    VoidCallback? verifyTarget,
    VoidCallback? onDone,
    Link? Function()? currentLink,
  }) {
    final t = _add(Transfer(true, path.split('/').last, size));
    final source = currentLink ?? () => link;
    t._retry = (same) =>
        _run(same, () => _runUpload(same, source, link, local, root, path, ifMatch, verifyTarget), onDone);
    unawaited(t._retry!(t));
    return t;
  }

  Future<void> _runUpload(
    Transfer t,
    Link? Function() source,
    Link expected,
    File local,
    String root,
    String path,
    String? ifMatch,
    VoidCallback? verifyTarget,
  ) async {
    final link = _connection(t, source, expected);
    t.total = await local.length();
    _connection(t, source, link);
    verifyTarget?.call();
    final s = await link.open('fs.upload', {
      'root': root,
      'path': path,
      'size': t.total,
      if (ifMatch == null) 'create': true else 'if_match': ifMatch,
    }, Priority.bulk);
    t._stream = s;
    _connection(t, source, link);
    await s.response();
    _connection(t, source, link);
    await for (final chunk in local.openRead()) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      for (var off = 0; off < bytes.length; off += dataChunk) {
        _connection(t, source, link);
        final end = off + dataChunk < bytes.length
            ? off + dataChunk
            : bytes.length;
        await s.sendData(Uint8List.sublistView(bytes, off, end));
        t._progress(end - off);
      }
    }
    _connection(t, source, link);
    verifyTarget?.call();
    await s.sendEnd();
    await s.response();
    _connection(t, source, link);
    await s.close();
  }

  /// Downloads [root]:[path] into [where] (a file path that does not exist yet).
  Transfer download(
    Link link,
    String root,
    String path,
    String where,
    int size, {
    VoidCallback? onDone,
    Link? Function()? currentLink,
  }) {
    final t = _add(Transfer(false, path.split('/').last, size));
    Link? source() {
      final current = currentLink == null ? link : currentLink();
      if (current == null || identical(current, link)) return current;
      // Retry after a reconnect only when authenticated agent identity matches.
      final original = link.server;
      final next = current.server;
      final pin = (original.raw['direct'] as Map?)?['cert_sha256'];
      if (original.id.isEmpty || original.id != next.id || pin is! String ||
          pin.isEmpty || (next.raw['direct'] as Map?)?['cert_sha256'] != pin) {
        return null;
      }
      return current;
    }
    t._retry = (same) =>
        _run(same, () => _runDownload(same, source, root, path, where), onDone);
    unawaited(t._retry!(t));
    return t;
  }

  Future<void> _runDownload(
    Transfer t,
    Link? Function() source,
    String root,
    String path,
    String where,
  ) async {
    Directory? scratch;
    RandomAccessFile? out;
    try {
      final link = _connection(t, source);
      final s = await link.open('fs.download', {
        'root': root,
        'path': path,
      }, Priority.bulk);
      t._stream = s;
      _connection(t, source, link);
      final meta = await s.response() as Map;
      _connection(t, source, link);
      t.total = (meta['length'] as num).toInt();
      if (t.total < 0) throw StateError('下载大小无效');
      scratch = await Directory(File(where).parent.path)
          .createTemp('.aurora-download-');
      final tmp = File('${scratch.path}/content.part');
      out = await tmp.open(mode: FileMode.writeOnly);
      var ended = false;
      while (true) {
        _connection(t, source, link);
        final f = await s.read();
        if (f == null) break;
        _connection(t, source, link);
        if (f.type == typeData) {
          if (t.done + f.payload.length > t.total) {
            throw StateError('下载数据超过声明大小');
          }
          // Await disk completion before consuming another transport frame.
          await writeChunk(out, f.payload);
          t._progress(f.payload.length);
        } else if (f.type == typeEnd) {
          ended = true;
          break;
        } else {
          throw StateError('下载帧类型无效');
        }
      }
      await out.flush();
      await out.close();
      out = null;
      _connection(t, source, link);
      if (!ended || t.done != t.total) {
        throw StateError('下载不完整：${t.done} / ${t.total} 字节');
      }
      _connection(t, source, link);
      await publishDownload(tmp, where);
    } finally {
      try {
        await out?.close();
        if (scratch != null) await scratch.delete(recursive: true);
      } on Object {
        // best effort: the part file is only a temporary name
      }
    }
  }
}
