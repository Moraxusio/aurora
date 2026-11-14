import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/gui_workflow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows production-root GUI interaction audit', (t) async {
    // Profile rejects the debug-only client ID -1. Register the test IME so
    // injected text/actions carry the real active client ID on the native engine.
    t.testTextInput.register();
    addTearDown(t.testTextInput.unregister);
    const output = String.fromEnvironment('AURORA_REVIEW_OUT');
    expect(output, isNotEmpty);
    final frame = GlobalKey();
    final result = await exerciseGui(t, frame: frame, capture: () async {
      final boundary = frame.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await File('$output.json').writeAsString(const JsonEncoder.withIndent('  ').convert({
      ...result, 'native_engine': true, 'synthetic_input': true,
      'mode': const bool.fromEnvironment('dart.vm.profile') ? 'profile' : 'debug',
      'physical_width': t.view.physicalSize.width, 'physical_height': t.view.physicalSize.height,
      'device_pixel_ratio': t.view.devicePixelRatio,
    }));
  });
}
