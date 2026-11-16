import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';

const textEncodings = <String, String>{
  'utf-8': 'UTF-8',
  'utf-8-bom': 'UTF-8 BOM',
  'utf-16le': 'UTF-16 LE',
  'utf-16le-bom': 'UTF-16 LE BOM',
  'utf-16be': 'UTF-16 BE',
  'utf-16be-bom': 'UTF-16 BE BOM',
  'gb18030': 'GB18030',
  'big5': 'Big5',
  'shift-jis': 'Shift JIS',
  'windows-1252': 'Windows-1252',
};

class FileTextChange {
  final String root, path;
  final String? etag, text;
  final String encoding;
  final int? modeBits;
  const FileTextChange({
    required this.root,
    required this.path,
    required this.etag,
    required this.text,
    this.encoding = 'utf-8',
    this.modeBits,
  });
}

/// Cancellable text transfers share three slots across all workspaces. A queued
/// cancellation completes immediately and a late stream is always reset.
class FileTextOperation {
  static int _running = 0;
  static final List<FileTextOperation> _queue = [];
  Completer<void>? _waiting;
  OpStream? _stream;
  bool _cancelled = false, _used = false, _finished = false;
  final _cancelSignal = Completer<void>();
  final bool Function() active;
  FileTextOperation({required this.active});
  bool get cancelled => _cancelled || _finished || !active();
  void _check() {
    if (cancelled) throw StateError('文本操作已取消或连接已变化');
  }

  void cancel() {
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    _stream?.reset();
    if (_queue.remove(this)) _waiting!.completeError(StateError('文本操作已取消'));
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    if (_used) throw StateError('文本操作只能执行一次');
    _used = true;
    _check();
    if (_running >= 3) {
      if (_queue.length >= 128) throw StateError('文本操作队列已满');
      _waiting = Completer<void>();
      _queue.add(this);
      await _waiting!.future;
    } else {
      _running++;
    }
    try {
      _check();
      return await Future.any<T>([
        action(),
        _cancelSignal.future.then<T>((_) => throw StateError('文本操作已取消')),
      ]);
    } finally {
      _finished = true;
      _stream?.reset();
      _stream = null;
      if (_queue.isEmpty) {
        _running--;
      } else {
        _queue.removeAt(0)._waiting!.complete();
      }
    }
  }

  Future<OpStream> _open(
    Link link,
    String op,
    Map<String, Object?> args,
  ) async {
    final stream = await link
        .open(op, args)
        .then((stream) {
          if (cancelled) stream.reset();
          return stream;
        })
        .timeout(const Duration(seconds: 20));
    if (cancelled) {
      stream.reset();
      _check();
    }
    _stream = stream;
    return stream;
  }

  Future<Map<String, dynamic>> read(
    Link link,
    String root,
    String path, {
    String encoding = 'auto',
    bool window = false,
    int offset = 0,
    int length = 64 * 1024,
    String? etag,
  }) => _run(() async {
    final stream = await _open(link, 'fs.text', {
      'root': root,
      'path': path,
      'encoding': encoding,
      if (window) ...{'window': true, 'offset': offset, 'length': length},
      if (etag != null) 'if_match': etag,
    });
    return _readText(stream, maxBytes: window ? 256 * 1024 : 16 * 1024 * 1024);
  });

  Future<Map<String, dynamic>> _readText(
    OpStream stream, {
    required int maxBytes,
  }) async {
    final metadata = (await stream.response().timeout(
      const Duration(seconds: 20),
    ) as Map).cast<String, dynamic>();
    _check();
    final size = metadata['textBytes'];
    if (size is! int || size < 0 || size > maxBytes)
      throw StateError('文本长度超过传输预算');
    final bytes = BytesBuilder(copy: false);
    var ended = false;
    while (!cancelled) {
      final frame = await stream.read().timeout(const Duration(seconds: 30));
      if (frame == null) break;
      if (frame.type == typeEnd) {
        ended = true;
        break;
      }
      if (frame.type != typeData || bytes.length + frame.payload.length > size)
        throw StateError('文本数据帧长度无效');
      bytes.add(frame.payload);
    }
    _check();
    if (!ended || bytes.length != size) throw StateError('文本传输未完整结束');
    return {
      ...metadata,
      'content': utf8.decode(bytes.takeBytes()),
      'truncated': metadata['large'] == true,
    };
  }

  /// Search and replacement run in the same bounded, linear-time agent matcher.
  /// Unsaved buffers are sent as frames, so previews never use stale disk text.
  Future<Map<String, dynamic>> replace(
    Link link,
    String text,
    Map<String, Object?> options,
  ) => _run(() async {
    final bytes = utf8.encode(text);
    if (bytes.length > 4 * 1024 * 1024) throw StateError('替换输入超过 4 MiB');
    final stream = await _open(link, 'fs.replace.preview', {
      ...options,
      'size': bytes.length,
    });
    final ready = await stream.response().timeout(const Duration(seconds: 20));
    _check();
    if (ready is! Map || ready['ready'] != true) throw StateError('替换预览握手无效');
    await _sendText(stream, bytes);
    _check();
    await stream.sendEnd().timeout(const Duration(seconds: 20));
    _check();
    return _readText(stream, maxBytes: 4 * 1024 * 1024);
  });

  Future<void> _sendText(OpStream stream, Uint8List bytes) async {
    for (var start = 0; start < bytes.length; start += 64 * 1024) {
      _check();
      await stream
          .sendData(
            Uint8List.sublistView(
              bytes,
              start,
              (start + 64 * 1024).clamp(0, bytes.length),
            ),
          )
          .timeout(const Duration(seconds: 30));
    }
  }

  Future<List<Map<String, dynamic>>> commit(
    Link link,
    List<FileTextChange> changes, {
    void Function()? beforeCommit,
    bool resource = false,
  }) => _run(() async {
    if (changes.isEmpty || changes.length > 128)
      throw StateError('批量修改须包含 1–128 个文件');
    final data = <Uint8List>[];
    var total = 0;
    for (final change in changes) {
      if (change.text == null && change.etag == null) {
        throw StateError('删除文件必须提供预期版本');
      }
      final bytes = utf8.encode(change.text ?? '');
      total += bytes.length;
      if (bytes.length > 16 * 1024 * 1024 || total > 32 * 1024 * 1024)
        throw StateError('修改内容超过客户端预算');
      data.add(bytes);
    }
    final stream = await _open(link, resource ? 'fs.refactor' : 'fs.commit', {
      'changes': [
        for (var i = 0; i < changes.length; i++)
          {
            'root': changes[i].root,
            'path': changes[i].path,
            if (changes[i].etag != null) 'if_match': changes[i].etag,
            if (changes[i].etag == null) 'create': true,
            'delete': changes[i].text == null,
            'size': data[i].length,
            'encoding': changes[i].encoding,
            if (changes[i].modeBits != null) 'modeBits': changes[i].modeBits,
          },
      ],
    });
    final ready = await stream.response().timeout(const Duration(seconds: 20));
    _check();
    if (ready is! Map || ready['ready'] != true) throw StateError('文件事务握手无效');
    for (final bytes in data) {
      await _sendText(stream, bytes);
    }
    _check();
    beforeCommit?.call();
    _check();
    await stream.sendEnd().timeout(const Duration(seconds: 20));
    _check();
    final result = await stream.response().timeout(const Duration(seconds: 60));
    _check();
    if (result is! Map || result['files'] is! List)
      throw StateError('文件事务回复无效');
    final files = [
      for (final value in result['files'] as List)
        (value as Map).cast<String, dynamic>(),
    ];
    if (files.length != changes.length) throw StateError('文件事务结果不完整，请核对磁盘版本');
    for (var i = 0; i < files.length; i++) {
      if (files[i]['root'] != changes[i].root ||
          files[i]['path'] != changes[i].path ||
          (files[i]['deleted'] == true) != (changes[i].text == null) ||
          (changes[i].text != null && files[i]['etag'] is! String)) {
        throw StateError('文件事务身份不匹配，请核对磁盘版本');
      }
    }
    return files;
  });
}
