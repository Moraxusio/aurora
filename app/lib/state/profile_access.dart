import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';

/// Shared, widget-free access used by durable background work.
abstract interface class ProfileAccess {
  Profile get profile;
  Future<void> update(FutureOr<void> Function(Profile) change);
  Link? link(String id);
}
