import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/theme/workbench_scale.dart';
import 'package:aurora/ui/aurora_ui.dart';
import 'package:aurora/ui/component_gallery.dart';
import 'package:flutter/material.dart' as native;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(
  Widget child,
  InputMode input, {
  Brightness brightness = Brightness.dark,
  double zoom = 1,
  double textScale = 1,
}) => InputMode.scope(
  mode: input,
  child: MaterialApp(
    theme: buildTheme(brightness),
    builder: (context, child) => WorkbenchScale(
      scale: zoom,
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
    home: Scaffold(body: child),
  ),
);

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [360.0, 1280.0]) {
      testWidgets(
        'gallery ${brightness.name} $width keeps input through zoom and lazy rows',
        (t) async {
          t.view.physicalSize = Size(width, 740);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final input = InputMode(touch: width < 500);
          addTearDown(input.dispose);
          await t.pumpWidget(
            host(
              const ComponentGallery(),
              input,
              brightness: brightness,
              textScale: 1.5,
            ),
          );
          await t.pumpAndSettle();
          await t.ensureVisible(find.byType(native.TextField).first);
          await t.pumpAndSettle();
          await t.enterText(find.byType(native.TextField).first, '未提交草稿');
          final controller = t
              .widget<native.TextField>(find.byType(native.TextField).first)
              .controller;
          await t.pumpWidget(
            host(
              const ComponentGallery(),
              input,
              brightness: brightness,
              textScale: 1.5,
              zoom: 1.5,
            ),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(controller!.text, '未提交草稿');
          expect(
            t
                .widget<native.TextField>(find.byType(native.TextField).first)
                .controller,
            same(controller),
          );
          expect(find.byType(TreeRow).evaluate().length, lessThan(60));
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'keyboard focus activates controls and skips disabled and busy buttons',
    (t) async {
      final input = InputMode(touch: false);
      final focus = FocusNode();
      addTearDown(input.dispose);
      addTearDown(focus.dispose);
      final semantics = t.ensureSemantics();
      try {
        var primary = 0, icon = 0;
        await t.pumpWidget(
          host(
            Column(
              children: [
                FilledButton(
                  key: const ValueKey('primary'),
                  focusNode: focus,
                  onPressed: () => primary++,
                  child: const Text('Execute'),
                ),
                const FilledButton(
                  key: ValueKey('disabled'),
                  onPressed: null,
                  child: Text('Disabled'),
                ),
                FilledButton(
                  key: const ValueKey('busy'),
                  busy: true,
                  onPressed: () => fail('busy click'),
                  onLongPress: () => fail('busy long press'),
                  child: const Text('Working'),
                ),
                IconBtn(Icons.refresh, 'Refresh', () => icon++),
                TreeRow(
                  key: const ValueKey('row'),
                  label: 'Selected row',
                  selected: true,
                  onTap: () {},
                ),
              ],
            ),
            input,
          ),
        );
        focus.requestFocus();
        await t.pump(const Duration(milliseconds: 200));
        final button = t.widget<native.FilledButton>(
          find.byKey(const ValueKey('primary')),
        );
        expect(button.style!.side!.resolve({WidgetState.focused})!.width, 2);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(primary, 1);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump(const Duration(milliseconds: 200));
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await t.pump(const Duration(milliseconds: 200));
        expect(icon, 1);
        await t.longPress(find.byKey(const ValueKey('busy')));
        expect(
          t.getSemantics(find.byKey(const ValueKey('disabled'))),
          matchesSemantics(
            label: 'Disabled',
            isButton: true,
            hasEnabledState: true,
          ),
        );
        expect(
          t.getSemantics(find.byKey(const ValueKey('row'))),
          isSemantics(
            label: 'Selected row',
            isSelected: true,
            hasSelectedState: true,
            hasTapAction: true,
          ),
        );
        await t.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'touch hit areas, narrow forms, headers and short empty panels remain usable',
    (t) async {
      final input = InputMode(touch: true);
      addTearDown(input.dispose);
      var invoked = 0;
      await t.pumpWidget(
        host(
          Center(
            child: SizedBox(
              width: 240,
              child: ListView(
                children: [
                  SectionHeader(
                    '窄面板标题',
                    actions: [
                      for (var i = 0; i < 5; i++)
                        IconBtn(Icons.add, 'Action $i', () => invoked++),
                    ],
                  ),
                  FormRow(
                    title: '完整标题',
                    subtitle: '缩放后的多行说明',
                    value: 'a-very-long-fingerprint-without-spaces-0123456789',
                    trailing: OutlinedButton(
                      onPressed: () => invoked++,
                      child: const Text('可执行操作'),
                    ),
                  ),
                  Notice(
                    tone: Tone.error,
                    title: '错误内容',
                    body: '说明内容',
                    action: OutlinedButton(
                      onPressed: () => invoked++,
                      child: const Text('重试操作'),
                    ),
                  ),
                  PickerRow(
                    selected: true,
                    onTap: () => invoked++,
                    child: const Text('选择条目'),
                  ),
                  SmallSwitch(
                    switchKey: const ValueKey('switch'),
                    value: true,
                    onChanged: (_) => invoked++,
                  ),
                ],
              ),
            ),
          ),
          input,
          textScale: 1.75,
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(
        t.getSize(find.byType(native.IconButton).first).height,
        greaterThanOrEqualTo(44),
      );
      await t.ensureVisible(find.byType(PickerRow));
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byType(PickerRow)).height,
        greaterThanOrEqualTo(44),
      );
      await t.tap(find.text('选择条目'));
      expect(invoked, 1);
      expect(
        t.getSize(find.byKey(const ValueKey('switch'))).height,
        greaterThanOrEqualTo(44),
      );
      await t.pumpWidget(
        host(
          Center(
            child: SizedBox(
              width: 240,
              height: 70,
              child: EmptyHint(
                icon: Icons.folder,
                text: '在极矮面板中仍然能滚动到操作',
                actionLabel: '开始',
                onAction: () => invoked++,
              ),
            ),
          ),
          input,
          textScale: 1.75,
        ),
      );
      await t.ensureVisible(find.text('开始'));
      await t.pumpAndSettle();
      await t.tap(find.text('开始'));
      expect(invoked, 2);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('virtual list mounts a bounded window of ten thousand rows', (
    t,
  ) async {
    final input = InputMode(touch: false), scroll = ScrollController();
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    var built = 0, picked = -1;
    await t.pumpWidget(
      host(
        UiVirtualList(
          controller: scroll,
          itemCount: 10000,
          itemExtent: UiMetrics.compactRow,
          itemBuilder: (_, i) {
            built++;
            return TreeRow(label: 'Row $i', onTap: () => picked = i);
          },
        ),
        input,
      ),
    );
    await t.pumpAndSettle();
    expect(built, lessThan(100));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await t.pumpAndSettle();
    await t.tap(find.text('Row 9999'));
    expect(picked, 9999);
    expect(built, lessThan(250));
    expect(find.byType(TreeRow).evaluate().length, lessThan(100));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'dialog actions remain reachable with nested scrolling and enlarged text',
    (t) async {
      t.view.physicalSize = const Size(360, 540);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final input = InputMode(touch: true);
      addTearDown(input.dispose);
      var accepted = false;
      await t.pumpWidget(
        host(
          Builder(
            builder: (context) => FilledButton(
              onPressed: () => showWorkbenchDialog<void>(
                context: context,
                builder: (dialog) => AlertDialog(
                  title: const Text('可滚动对话框'),
                  content: SizedBox(
                    width: 900,
                    height: 560,
                    child: UiVirtualList(
                      itemCount: 10000,
                      itemBuilder: (_, i) => Text('Item $i'),
                    ),
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () {
                        accepted = true;
                        Navigator.pop(dialog);
                      },
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
          input,
          textScale: 1.75,
          zoom: 1.25,
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('完成'));
      await t.pumpAndSettle();
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      expect(accepted, isTrue);
      expect(t.takeException(), isNull);
    },
  );
}
