import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/monitor_workflow.dart';

void main() {
  for (final size in [
    const Size(1800, 1100),
    const Size(1200, 800),
    const Size(900, 700),
  ]) {
    for (final theme in ['dark', 'light']) {
      for (final dpr in [1.0, 1.5]) {
        testWidgets(
          'production monitor GPU expansion, refresh and zoom at $size / $theme / $dpr DPR',
          (t) async {
            t.view.physicalSize = size * dpr;
            t.view.devicePixelRatio = dpr;
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            final semantics = t.ensureSemantics();
            try {
              await exerciseMonitor(t, theme: theme);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }
}
