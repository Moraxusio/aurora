/// TLS 1.3 client with certificate pinning (docs/DESIGN.md 5.3), on a
/// bundled BoringSSL built by this package's build hook.
library;

export 'src/tls_socket.dart' show TlsSocket, TlsException, TlsFailure, tlsLibraryVersion;
