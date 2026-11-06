// Ed25519 verification and SHA-256 from the bundled BoringSSL, for release
// signatures (D-3) and file hashes. Native, so hashing a 7 MB agent takes
// milliseconds.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// True when [sig] (64 bytes) is a valid Ed25519 signature of [msg] by [pub]
/// (32 bytes). Wrong lengths are false, not errors.
bool ed25519Verify(Uint8List msg, Uint8List sig, Uint8List pub) {
  if (sig.length != 64 || pub.length != 32) return false;
  return using((a) {
    final m = a<Uint8>(msg.isEmpty ? 1 : msg.length);
    final s = a<Uint8>(64);
    final p = a<Uint8>(32);
    m.asTypedList(msg.length).setAll(0, msg);
    s.asTypedList(64).setAll(0, sig);
    p.asTypedList(32).setAll(0, pub);
    return atEd25519Verify(m, msg.length, s, p) == 1;
  });
}

/// SHA-256 of [data].
Uint8List sha256(Uint8List data) {
  final h = Sha256();
  h.add(data);
  return h.close();
}

/// Lower-case hex SHA-256 of the file at [path], read in 1 MiB pieces.
Future<String> sha256File(String path) async {
  final h = Sha256();
  try {
    await for (final chunk in File(path).openRead()) {
      h.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    }
  } catch (_) {
    h.dispose();
    rethrow;
  }
  return hexOf(h.close());
}

/// Incremental SHA-256. [close] returns the digest and frees the context;
/// [dispose] frees it without one.
class Sha256 {
  Pointer<AtSha256> _h;
  final Pointer<Uint8> _buf;
  static const int _bufCap = 1 << 20;

  Sha256()
      : _h = atSha256New(),
        _buf = malloc<Uint8>(_bufCap) {
    if (_h.address == 0) {
      malloc.free(_buf);
      throw StateError('SHA-256 context: out of memory');
    }
  }

  void add(Uint8List data) {
    if (_h.address == 0) throw StateError('Sha256 already closed');
    for (var off = 0; off < data.length; off += _bufCap) {
      final end = off + _bufCap < data.length ? off + _bufCap : data.length;
      _buf.asTypedList(end - off).setAll(0, Uint8List.sublistView(data, off, end));
      atSha256Update(_h, _buf, end - off);
    }
  }

  Uint8List close() {
    if (_h.address == 0) throw StateError('Sha256 already closed');
    final out = malloc<Uint8>(32);
    try {
      atSha256Final(_h, out);
      _h = nullptr;
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      malloc.free(out);
      malloc.free(_buf);
    }
  }

  void dispose() {
    if (_h.address == 0) return;
    atSha256Free(_h);
    _h = nullptr;
    malloc.free(_buf);
  }
}

String hexOf(List<int> b) {
  const d = '0123456789abcdef';
  final s = StringBuffer();
  for (final x in b) {
    s
      ..write(d[x >> 4])
      ..write(d[x & 15]);
  }
  return s.toString();
}
