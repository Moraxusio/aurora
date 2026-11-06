// FFI bindings for src/aurora_tls.h. The library is the package's code asset
// (hook/build.dart), so @Native finds it on every platform the hook builds.
import 'dart:ffi';

final class AtConn extends Opaque {}

const int atOk = 0;
const int atWantIo = 1;
const int atEof = 2;
const int atErrPin = -1;
const int atErrTls = -2;
const int atErrState = -3;
const int atErrNomem = -4;

@Native<Pointer<Char> Function()>(symbol: 'at_version', isLeaf: true)
external Pointer<Char> atVersion();

@Native<Pointer<AtConn> Function(Pointer<Uint8>, Pointer<Char>)>(symbol: 'at_new')
external Pointer<AtConn> atNew(Pointer<Uint8> pin, Pointer<Char> serverName);

@Native<Void Function(Pointer<AtConn>)>(symbol: 'at_free')
external void atFree(Pointer<AtConn> c);

@Native<Int32 Function(Pointer<AtConn>, Pointer<Uint8>, Size)>(symbol: 'at_feed', isLeaf: true)
external int atFeed(Pointer<AtConn> c, Pointer<Uint8> data, int len);

@Native<Int32 Function(Pointer<AtConn>)>(symbol: 'at_handshake', isLeaf: true)
external int atHandshake(Pointer<AtConn> c);

@Native<Int64 Function(Pointer<AtConn>, Pointer<Uint8>, Size)>(symbol: 'at_write', isLeaf: true)
external int atWrite(Pointer<AtConn> c, Pointer<Uint8> data, int len);

@Native<Int64 Function(Pointer<AtConn>, Pointer<Uint8>, Size)>(symbol: 'at_read', isLeaf: true)
external int atRead(Pointer<AtConn> c, Pointer<Uint8> buf, int len);

@Native<Size Function(Pointer<AtConn>)>(symbol: 'at_out_len', isLeaf: true)
external int atOutLen(Pointer<AtConn> c);

@Native<Pointer<Uint8> Function(Pointer<AtConn>)>(symbol: 'at_out_ptr', isLeaf: true)
external Pointer<Uint8> atOutPtr(Pointer<AtConn> c);

@Native<Void Function(Pointer<AtConn>, Size)>(symbol: 'at_consume', isLeaf: true)
external void atConsume(Pointer<AtConn> c, int n);

@Native<Int32 Function(Pointer<AtConn>)>(symbol: 'at_close', isLeaf: true)
external int atClose(Pointer<AtConn> c);

@Native<Pointer<Char> Function(Pointer<AtConn>)>(symbol: 'at_error', isLeaf: true)
external Pointer<Char> atError(Pointer<AtConn> c);

@Native<Int32 Function(Pointer<AtConn>, Pointer<Uint8>)>(symbol: 'at_peer_pin', isLeaf: true)
external int atPeerPin(Pointer<AtConn> c, Pointer<Uint8> out);

@Native<Pointer<Char> Function(Pointer<AtConn>)>(symbol: 'at_cipher', isLeaf: true)
external Pointer<Char> atCipher(Pointer<AtConn> c);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Pointer<Uint8>)>(symbol: 'at_ed25519_verify', isLeaf: true)
external int atEd25519Verify(Pointer<Uint8> msg, int len, Pointer<Uint8> sig, Pointer<Uint8> pub);

final class AtSha256 extends Opaque {}

@Native<Pointer<AtSha256> Function()>(symbol: 'at_sha256_new', isLeaf: true)
external Pointer<AtSha256> atSha256New();

@Native<Void Function(Pointer<AtSha256>, Pointer<Uint8>, Size)>(symbol: 'at_sha256_update', isLeaf: true)
external void atSha256Update(Pointer<AtSha256> h, Pointer<Uint8> data, int len);

@Native<Void Function(Pointer<AtSha256>, Pointer<Uint8>)>(symbol: 'at_sha256_final', isLeaf: true)
external void atSha256Final(Pointer<AtSha256> h, Pointer<Uint8> out);

@Native<Void Function(Pointer<AtSha256>)>(symbol: 'at_sha256_free', isLeaf: true)
external void atSha256Free(Pointer<AtSha256> h);

/// Reads a NUL-terminated UTF-8 string (ASCII in practice).
String cString(Pointer<Char> p) {
  if (p.address == 0) return '';
  final bytes = <int>[];
  final b = p.cast<Uint8>();
  for (var i = 0; i < 4096; i++) {
    final v = b[i];
    if (v == 0) break;
    bytes.add(v);
  }
  return String.fromCharCodes(bytes);
}
