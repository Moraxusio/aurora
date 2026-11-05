import 'dart:collection';
import 'dart:typed_data';

/// A FIFO of byte chunks. Reading a run that lies inside one chunk returns a
/// view (no copy); a run across chunks is copied once. Chunks handed to [add]
/// must not be modified afterwards.
class ByteQueue {
  final ListQueue<Uint8List> _chunks = ListQueue<Uint8List>();
  int _off = 0; // read offset into the first chunk
  int _len = 0;

  int get length => _len;
  bool get isEmpty => _len == 0;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk);
    _len += chunk.length;
  }

  int byteAt(int i) {
    if (i < 0 || i >= _len) throw RangeError.index(i, this, 'index', null, _len);
    var idx = i + _off;
    final first = _chunks.first;
    if (idx < first.length) return first[idx];
    for (final c in _chunks) {
      if (idx < c.length) return c[idx];
      idx -= c.length;
    }
    throw StateError('ByteQueue length out of sync');
  }

  int peekUint32(int at) =>
      byteAt(at) << 24 | byteAt(at + 1) << 16 | byteAt(at + 2) << 8 | byteAt(at + 3);

  /// The first [n] bytes without consuming them.
  Uint8List peek(int n) {
    _check(n);
    final first = _chunks.first;
    if (_off + n <= first.length) return Uint8List.sublistView(first, _off, _off + n);
    final out = Uint8List(n);
    var got = 0;
    var off = _off;
    for (final c in _chunks) {
      final take = (c.length - off) < (n - got) ? c.length - off : n - got;
      out.setRange(got, got + take, c, off);
      got += take;
      off = 0;
      if (got == n) break;
    }
    return out;
  }

  void skip(int n) {
    _check(n);
    _len -= n;
    while (n > 0) {
      final first = _chunks.first;
      final left = first.length - _off;
      if (n < left) {
        _off += n;
        return;
      }
      n -= left;
      _chunks.removeFirst();
      _off = 0;
    }
  }

  int takeByte() {
    final b = byteAt(0);
    skip(1);
    return b;
  }

  /// Removes and returns the first [n] bytes.
  Uint8List take(int n) {
    if (n == 0) return Uint8List(0);
    final out = peek(n);
    skip(n);
    return out;
  }

  Uint8List takeAll() => take(_len);

  void _check(int n) {
    if (n < 0 || n > _len) throw RangeError.range(n, 0, _len, 'n');
  }
}
