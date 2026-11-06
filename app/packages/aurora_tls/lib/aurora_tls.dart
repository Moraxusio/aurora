/// TLS 1.3 client with certificate pinning (docs/DESIGN.md 5.3), on a
/// bundled BoringSSL built by this package's build hook. Also Ed25519
/// verification and SHA-256 for release signatures (D-3).
library;

export 'src/crypto.dart' show ed25519Verify, sha256, sha256File, Sha256, hexOf;
export 'src/tls_socket.dart' show TlsSocket, TlsException, TlsFailure, tlsLibraryVersion;
