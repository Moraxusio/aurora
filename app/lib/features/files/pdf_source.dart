// Reads a remote PDF by byte ranges instead of downloading the whole file.
//
// PDFium asks for the bytes it needs, when it needs them: the end of the file
// first (the cross-reference table), then the pages being looked at. This
// reader answers each request from 512 KiB blocks fetched with fs.download
// (offset + length) and keeps the recent blocks, so a 300 MB scan opens as
// soon as its first page is in, not after the whole file has crossed the
// network. A file up to [pdfPreloadMax] is fetched completely up front
// instead (progress shown), because then every later read is local and
// paging never waits.
//
// Every block answer carries the file's etag. If it changes while the file is
// open, the file was replaced on the server: the reader refuses to mix the old
// and new bytes and says so, rather than showing a page that never existed.
import 'dart:async';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';

import 'remote_bytes.dart';

const pdfChunk = 512 * 1024;
const pdfPreloadMax = 16 * 1024 * 1024;
const pdfMaxFile = 1024 * 1024 * 1024; // beyond this, download instead
const _cachedChunksMin = 64; // 32 MiB of recent blocks when reading on demand

typedef RangeOpener = Future<DownloadStream> Function(String root, String path, int offset, int length);

RangeOpener linkRangeOpener(Link link) => (root, path, offset, length) async {
      final s = await link.open('fs.download', {'root': root, 'path': path, 'offset': offset, 'length': length}, Priority.bulk);
      return _LinkStream(s);
    };

class _LinkStream implements DownloadStream {
  final OpStream s;
  _LinkStream(this.s);
  @override
  Future<Object?> response() => s.response();
  @override
  Future<Frame?> read() => s.read();
  @override
  void reset() => s.reset();
  @override
  Future<void> close() => s.close();
}

/// The file was replaced on the server while it was open.
class RemoteChanged implements Exception {
  @override
  String toString() => '文件在服务器上被改动了，请关闭后重新打开';
}

class RemoteRangeReader {
  final RangeOpener _open;
  final String root, path;
  final int chunk;
  int size = 0;
  String? etag;
  bool _closed = false;
  int _capacity = _cachedChunksMin;
  final _cache = <int, Uint8List>{}; // insertion-ordered: the first key is the least recently used
  final _inflight = <int, Future<Uint8List>>{};
  final _streams = <DownloadStream>{};
  int requests = 0; // fs.download calls made (tests, diagnostics)

  RemoteRangeReader(this._open, this.root, this.path, {this.chunk = pdfChunk});

  int get chunkCount => size == 0 ? 0 : (size + chunk - 1) ~/ chunk;

  /// Every block is held in memory (a small file after [init], or after [preload]).
  bool get complete => size > 0 && _cache.length == chunkCount;

  /// Reads the first block: that gives the file's size and etag.
  Future<void> init() async {
    final first = await _fetch(0);
    _remember(0, first);
  }

  /// The first [n] bytes (already fetched by [init]).
  Uint8List head(int n) {
    final c = _cache[0];
    if (c == null) return Uint8List(0);
    return Uint8List.sublistView(c, 0, n < c.length ? n : c.length);
  }

  /// Fetches every block, a few at a time, so later reads are all local.
  Future<void> preload({void Function(int done, int total)? onProgress}) async {
    final total = chunkCount;
    _capacity = total > _capacity ? total : _capacity;
    var done = _cache.length;
    onProgress?.call(done, total);
    var next = 0;
    Future<void> worker() async {
      while (!_closed) {
        final i = next++;
        if (i >= total) return;
        if (_cache.containsKey(i)) continue;
        await _chunk(i);
        onProgress?.call(++done, total);
      }
    }

    await Future.wait([for (var k = 0; k < 4; k++) worker()]);
    if (_closed) throw OpError(codeUnavailable, '已取消');
  }

  /// Every block joined into one buffer, once [preload] has fetched them all;
  /// the blocks are released afterwards so the bytes are not held twice.
  Uint8List takeAll() {
    if (_cache.length != chunkCount) throw StateError('takeAll before preload finished');
    final out = Uint8List(size);
    for (var i = 0; i < chunkCount; i++) {
      out.setRange(i * chunk, i * chunk + _cache[i]!.length, _cache[i]!);
    }
    _cache.clear();
    return out;
  }

  void _remember(int i, Uint8List data) {
    _cache.remove(i);
    _cache[i] = data;
    while (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first); // the least recently used
    }
  }

  Future<Uint8List> _chunk(int i) {
    final hit = _cache.remove(i);
    if (hit != null) {
      _cache[i] = hit; // now the most recent
      return Future.value(hit);
    }
    // The block body matters: an arrow would return the Future that
    // _inflight.remove gives back, which is this very Future, and wait on itself.
    return _inflight[i] ??= _fetch(i).then((d) {
      _remember(i, d);
      return d;
    }).whenComplete(() {
      _inflight.remove(i);
    });
  }

  Future<Uint8List> _fetch(int i) async {
    if (_closed) throw OpError(codeUnavailable, '已取消');
    final offset = i * chunk;
    final want = i == 0 || size == 0 ? chunk : (size - offset < chunk ? size - offset : chunk);
    requests++;
    final s = await _open(root, path, offset, want);
    _streams.add(s);
    try {
      final meta = (await s.response() as Map).cast<String, dynamic>();
      final total = (meta['size'] as num).toInt();
      final tag = meta['etag'] as String?;
      if (i == 0 && size == 0) {
        size = total;
        etag = tag;
      } else if (total != size || tag != etag) {
        throw RemoteChanged();
      }
      final len = (meta['length'] as num).toInt();
      final out = BytesBuilder(copy: false);
      var ended = false;
      while (true) {
        if (_closed) throw OpError(codeUnavailable, '已取消');
        final f = await s.read();
        if (f == null) break;
        if (f.type == typeData) {
          out.add(f.payload);
        } else if (f.type == typeEnd) {
          ended = true;
          break;
        }
      }
      if (!ended || out.length != len) throw OpError(codeUnavailable, '读取不完整：${out.length} / $len 字节');
      return out.takeBytes();
    } finally {
      _streams.remove(s);
      unawaited(s.close().catchError((_) {}));
    }
  }

  /// The callback PDFium reads through: fills [buf] from [pos], returns how many bytes.
  Future<int> read(Uint8List buf, int pos, int n) async {
    if (pos < 0 || pos >= size) return 0;
    final end = (pos + n) < size ? pos + n : size;
    var at = pos, filled = 0;
    final first = pos ~/ chunk, last = (end - 1) ~/ chunk;
    final blocks = await Future.wait([for (var i = first; i <= last; i++) _chunk(i)]);
    for (var i = first; i <= last; i++) {
      final b = blocks[i - first];
      final from = at - i * chunk;
      final take = (b.length - from) < (end - at) ? b.length - from : end - at;
      if (take <= 0) break;
      buf.setRange(filled, filled + take, b, from);
      filled += take;
      at += take;
    }
    return filled;
  }

  void close() {
    _closed = true;
    for (final s in _streams.toList()) {
      s.reset();
    }
    _cache.clear();
  }
}
