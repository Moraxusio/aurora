import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows-only native tray bridge. No service, watchdog or startup registry
/// changes; Flutter's engine/connections remain in the same user process.
/// It also drives the window, which has no caption of its own: the app draws
/// the title bar and its buttons (kernel/window_frame.dart, D-103).
class DesktopLifecycle {
  static const channel = MethodChannel('aurora3/desktop');
  static final visible = ValueNotifier(true);

  /// The native window has no caption: the app draws the window buttons.
  static final frameless = ValueNotifier(false);
  static final maximized = ValueNotifier(false);
  static Future<bool> Function()? beforeExit;

  static Future<void> start() async {
    if (!Platform.isWindows) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'visibility' && call.arguments is bool) {
        visible.value = call.arguments as bool;
        return null;
      }
      if (call.method == 'maximized' && call.arguments is bool) {
        maximized.value = call.arguments as bool;
        return null;
      }
      if (call.method == 'requestExit') return await beforeExit?.call() ?? true;
      throw MissingPluginException();
    });
    try {
      final r = await channel.invokeMethod<Object?>('ready');
      if (r is Map) {
        frameless.value = r['frameless'] == true;
        maximized.value = r['maximized'] == true;
      }
    } on MissingPluginException { /* Flutter unit tests and non-native hosts. */ }
  }

  static void stop() {
    if (Platform.isWindows) channel.setMethodCallHandler(null);
    visible.value = true;
  }

  /// Asks the window to do [method]; nothing without the native host.
  static Future<void> window(String method, [Object? args]) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // tests
    }
  }
}
