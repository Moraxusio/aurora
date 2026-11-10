// Reads a whole remote file into memory over fs.download, for the viewers
// that need all the bytes (images, PDF). The agent announces the size before
// sending, so a file over [maxBytes] is refused before any data is fetched,
// and a short stream is an error rather than a silently cut-off picture.
import 'dart:async';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';

/// The file is bigger than the viewer is willing to hold in memory.
class RemoteTooLarge implements Exception {
  final int size;
  final int limit;
  RemoteTooLarge(this.size, this.limit);
  @override
  String toString() => '文件太大（$size 字节，上限 $limit 字节）';
}

/// The part of a download stream this reader needs (OpStream in production,
/// a scripted stream in tests).
abstract interface class DownloadStream {
  Future<Object?> response();
  Future<Frame?> read();
  void reset();
  Future<void> close();
}

class _OpDownload implements DownloadStream {
  final OpStream s;
  _OpDownload(this.s);
  @override
  Future<Object?> response() => s.response();
  @override
  Future<Frame?> read() => s.read();
  @override
  void reset() => s.reset();
  @override
  Future<void> close() => s.close();
}

typedef DownloadOpener = Future<DownloadStream> Function(String root, String path);

/// Lets the viewer stop a read that is still running (the tab was closed).
class ReadCancel {
  bool cancelled = false;
  DownloadStream? _s;
  void cancel() {
    cancelled = true;
    _s?.reset();
  }
}

class RemoteBytes {
  final Uint8List bytes;
  final int size;
  final String? etag;
  RemoteBytes(this.bytes, this.size, this.etag);
}

Future<RemoteBytes> readRemoteBytes(
  Link link,
  String root,
  String path, {
  required int maxBytes,
  void Function(int done, int total)? onProgress,
  ReadCancel? cancel,
  DownloadOpener? opener,
}) async {
  final s = opener != null
      ? await opener(root, path)
      : _OpDownload(await link.open('fs.download', {'root': root, 'path': path}, Priority.bulk));
  cancel?._s = s;
  try {
    final meta = (await s.response() as Map).cast<String, dynamic>();
    final total = (meta['length'] as num).toInt();
    if (total > maxBytes) {
      s.reset();
      throw RemoteTooLarge(total, maxBytes);
    }
    final out = BytesBuilder(copy: false);
    var ended = false;
    while (true) {
      if (cancel?.cancelled ?? false) throw OpError(codeUnavailable, '已取消');
      final f = await s.read();
      if (f == null) break;
      if (f.type == typeData) {
        out.add(f.payload);
        onProgress?.call(out.length, total);
      } else if (f.type == typeEnd) {
        ended = true;
        break;
      }
    }
    if (cancel?.cancelled ?? false) throw OpError(codeUnavailable, '已取消');
    if (!ended || out.length != total) {
      throw OpError(codeUnavailable, '读取不完整：${out.length} / $total 字节');
    }
    return RemoteBytes(out.takeBytes(), (meta['size'] as num?)?.toInt() ?? total, meta['etag'] as String?);
  } finally {
    unawaited(s.close().catchError((_) {}));
  }
}
