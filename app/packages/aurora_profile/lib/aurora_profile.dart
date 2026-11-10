/// What the Aurora client remembers, sealed at rest by the platform keystore
/// (docs/DESIGN.md D-1, D-2, D-6, D-22, D-72).
library;

export 'src/android_sealer.dart' show AndroidSealer;
export 'src/dpapi.dart' show DpapiSealer;
export 'src/profile.dart';
export 'src/sealer.dart';
export 'src/store.dart';
