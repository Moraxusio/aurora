import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/gui_workflow.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('AURORA_GUI_TRACE')) {
    final previous = <int, String>{};
    binding.addPersistentFrameCallback((_) {
      final owner = binding.renderViews.firstOrNull?.owner?.semanticsOwner;
      if (owner == null) return;
      for (var id = 0; id < 2000; id++) {
        final node = owner.getSemanticsNode(id);
        if (node == null && !previous.containsKey(id)) continue;
        final data = node?.getSemanticsData();
        final value = jsonEncode({
          'id': id, 'parent': node?.parent?.id, 'label': data?.label,
          'value': data?.value, 'tooltip': data?.tooltip,
          'linkParent': node?.traversalParentIdentifier == null ? null : identityHashCode(node!.traversalParentIdentifier),
          'linkChild': node?.traversalChildIdentifier == null ? null : identityHashCode(node!.traversalChildIdentifier),
        });
        if (previous[id] != value) debugPrint('GUI_NODE $value');
        if (node == null) { previous.remove(id); } else { previous[id] = value; }
      }
    });
  }
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
