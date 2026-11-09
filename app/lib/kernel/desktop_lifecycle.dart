import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows-only native tray bridge. No service, watchdog or startup registry
/// changes; Flutter's engine/connections remain in the same user process.
class DesktopLifecycle {
  static const channel = MethodChannel('aurora3/desktop');
  static final visible = ValueNotifier(true);
  static Future<bool> Function()? beforeExit;

  static Future<void> start() async {
    if (!Platform.isWindows) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'visibility' && call.arguments is bool) {
        visible.value = call.arguments as bool;
        return null;
      }
      if (call.method == 'requestExit') return await beforeExit?.call() ?? true;
      throw MissingPluginException();
    });
    try { await channel.invokeMethod<void>('ready'); }
    on MissingPluginException { /* Flutter unit tests and non-native hosts. */ }
  }

  static void stop() {
    if (Platform.isWindows) channel.setMethodCallHandler(null);
    visible.value = true;
  }
}
