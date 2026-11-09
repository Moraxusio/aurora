import 'dart:io';

import 'package:aurora/kernel/desktop_lifecycle.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('visibility and explicit exit dispatch use the installed Dart guard', () async {
    if (!Platform.isWindows) return;
    const codec = StandardMethodCodec();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DesktopLifecycle.channel, (call) async => null);
    await DesktopLifecycle.start();
    Future<Object?> native(String method, [Object? args]) async {
      Object? result;
      await messenger.handlePlatformMessage('aurora3/desktop', codec.encodeMethodCall(MethodCall(method, args)),
        (reply) => result = reply == null ? null : codec.decodeEnvelope(reply));
      return result;
    }
    await native('visibility', false);
    expect(DesktopLifecycle.visible.value, isFalse);
    var asked = 0;
    DesktopLifecycle.beforeExit = () async { asked++; return false; };
    expect(await native('requestExit'), isFalse);
    expect(asked, 1);
    await native('visibility', true);
    expect(DesktopLifecycle.visible.value, isTrue);
    DesktopLifecycle.beforeExit = () async => true;
    expect(await native('requestExit'), isTrue);
    DesktopLifecycle.beforeExit = null;
    DesktopLifecycle.stop();
    messenger.setMockMethodCallHandler(DesktopLifecycle.channel, null);
  });
}
