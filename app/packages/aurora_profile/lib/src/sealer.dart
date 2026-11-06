// A sealer encrypts the profile at rest with a key the platform keeps for the
// current user (D-72). There is deliberately no plaintext sealer in lib/: a
// platform without a keystore refuses to store anything.
import 'dart:io';
import 'dart:typed_data';

import 'dpapi.dart';

/// Encrypts and authenticates data for the current user on this device.
abstract interface class Sealer {
  /// Stable identifier written into the profile file, e.g. "dpapi". A file
  /// sealed by another sealer is refused instead of misread.
  String get id;

  /// Encrypts [plain]. Throws [SealerException] on failure.
  Uint8List seal(Uint8List plain);

  /// Decrypts and verifies [sealed]. Throws [SealerException] when it was
  /// sealed for another user or device, or was modified.
  Uint8List unseal(Uint8List sealed);
}

class SealerException implements Exception {
  final String message;
  SealerException(this.message);
  @override
  String toString() => message;
}

/// The platform keystore cannot be used, so nothing may be stored (D-72).
class SealerUnavailable implements Exception {
  final String message;
  SealerUnavailable(this.message);
  @override
  String toString() => message;
}

/// The sealer for this platform. Throws [SealerUnavailable] where the
/// keystore is missing or not supported yet; callers then refuse to save.
Sealer platformSealer() {
  if (Platform.isWindows) return DpapiSealer();
  throw SealerUnavailable('此平台（${Platform.operatingSystem}）还不支持安全保存凭据，未保存任何内容');
}
