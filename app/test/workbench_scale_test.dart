import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/theme/workbench_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('zoom keeps the full painted viewport clickable, including its right and bottom edges', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final zoom = ValueNotifier(1.0);
    final taps = <String>[];
    const targets = {
      'top-left': Alignment.topLeft, 'top-right': Alignment.topRight,
      'center': Alignment.center,
      'bottom-left': Alignment.bottomLeft, 'bottom-right': Alignment.bottomRight,
    };
    await t.pumpWidget(MaterialApp(
      builder: (_, child) => ValueListenableBuilder<double>(valueListenable: zoom, child: child,
        builder: (_, scale, child) => WorkbenchScale(scale: scale, child: child!)),
      home: Scaffold(body: Stack(children: [for (final target in targets.entries)
        Align(alignment: target.value, child: SizedBox(width: 100, height: 40,
          child: TextButton(key: ValueKey(target.key), onPressed: () => taps.add(target.key), child: Text(target.key)))),
      ])),
    ));
    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      t.view.devicePixelRatio = dpr;
      t.view.physicalSize = const Size(1200, 800) * dpr;
      for (final scale in [for (var percent = 80; percent <= 150; percent += 5) percent / 100, .85, 1.0]) {
        zoom.value = scale;
        await t.pump();
        taps.clear();
        for (final key in targets.keys) {
          // Pointer events at painted positions, never invoke callbacks directly.
          await t.tapAt(t.getCenter(find.byKey(ValueKey(key))));
          await t.pump();
        }
        expect(taps, targets.keys.toList(), reason: 'all visible regions must receive clicks at $scale zoom / DPR $dpr');
        expect(t.takeException(), isNull);
      }
    }
    await t.pumpWidget(const SizedBox());
    zoom.dispose();
  });

  for (final scale in [.85, 1.25]) {
    testWidgets('context menu uses overlay coordinates at $scale zoom', (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var picked = false;
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark),
        builder: (_, child) => WorkbenchScale(scale: scale, child: child!),
        home: Scaffold(body: ContextArea(items: () => [MenuItem('run action', () => picked = true)],
          child: const SizedBox.expand())),
      ));
      const point = Offset(450, 250);
      await t.tapAt(point, buttons: 2);
      await t.pumpAndSettle();
      final menu = find.byType(WorkbenchMenuEntry<int>);
      expect(menu, findsOneWidget);
      expect(t.getTopLeft(find.byType(FloatingSurface)).dx, closeTo(point.dx, .01), reason: 'screen position must be converted into the scaled overlay');
      await t.tapAt(t.getCenter(menu));
      await t.pumpAndSettle();
      expect(picked, isTrue);
      await t.pumpWidget(const SizedBox());
    });
  }
}
