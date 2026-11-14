import 'package:aurora/kernel/desktop_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gui_workflow.dart';

void main() {
  testWidgets('production GUI workflow across live zoom, menus, panels and retained state', (t) async {
    final semantics = t.ensureSemantics();
    t.view.physicalSize = const Size(1800, 1100); t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize); addTearDown(t.view.resetDevicePixelRatio);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DesktopLifecycle.channel, (call) async => call.method == 'ready' ? {'frameless': true, 'maximized': false} : null);
    addTearDown(() { messenger.setMockMethodCallHandler(DesktopLifecycle.channel, null); DesktopLifecycle.frameless.value = false; });
    try {
      final result = await exerciseGui(t);
      expect(result['terminal_attaches'], 1);
    } finally { semantics.dispose(); }
  });
}
