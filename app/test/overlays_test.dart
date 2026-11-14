import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/theme/workbench_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _open = ValueKey('open-menu');
Finder entry(String text) => find.ancestor(
  of: find.text(text),
  matching: find.byType(WorkbenchMenuEntry<int>),
);

Widget host({
  required Widget child,
  bool reduced = false,
  double scale = 1,
  InputMode? input,
  GlobalKey<NavigatorState>? navigator,
}) => MaterialApp(
  navigatorKey: navigator,
  theme: buildTheme(Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: WorkbenchScale(scale: scale, child: child!),
  ),
  home: Scaffold(
    body: input == null ? child : InputMode.scope(mode: input, child: child),
  ),
);

Widget menu({
  List<PopupMenuEntry<int>>? items,
  ValueChanged<int>? onSelected,
  VoidCallback? onCanceled,
}) => WorkbenchMenuButton<int>(
  key: _open,
  onSelected: onSelected,
  onCanceled: onCanceled,
  itemBuilder: (_) =>
      items ?? const [PopupMenuItem(value: 1, child: Text('Action'))],
  child: const Padding(padding: EdgeInsets.all(8), child: Text('Open')),
);

void main() {
  testWidgets(
    'keyboard skips disabled entries, wraps, activates and restores focus',
    (t) async {
      int? picked;
      var canceled = 0;
      await t.pumpWidget(
        host(
          child: Center(
            child: menu(
              onSelected: (v) => picked = v,
              onCanceled: () => canceled++,
              items: const [
                PopupMenuItem(
                  value: 0,
                  enabled: false,
                  child: Text('Disabled first'),
                ),
                CheckedPopupMenuItem(
                  value: 1,
                  checked: true,
                  child: Text('Checked'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 2,
                  enabled: false,
                  child: Text('Disabled middle'),
                ),
                PopupMenuItem(value: 3, child: Text('Last')),
              ],
            ),
          ),
        ),
      );
      final opener = Focus.of(t.element(find.text('Open')));
      opener.requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(Focus.of(t.element(find.text('Checked'))).hasPrimaryFocus, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(Focus.of(t.element(find.text('Last'))).hasPrimaryFocus, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(Focus.of(t.element(find.text('Checked'))).hasPrimaryFocus, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(picked, 3);
      expect(opener.hasPrimaryFocus, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(canceled, 1);
      expect(opener.hasPrimaryFocus, isTrue);
      expect(t.takeException(), isNull);
    },
  );

  for (final touch in [false, true]) {
    testWidgets(
      'checked and plain rows align, semantics and disabled state ($touch touch)',
      (t) async {
        final input = InputMode(touch: touch);
        addTearDown(input.dispose);
        final semantics = t.ensureSemantics();
        try {
          var picked = 0;
          await t.pumpWidget(
            host(
              input: input,
              child: Center(
                child: menu(
                  onSelected: (_) => picked++,
                  items: const [
                    PopupMenuItem(
                      value: 1,
                      child: MenuLabel('Plain', icon: Icons.folder),
                    ),
                    CheckedPopupMenuItem(
                      value: 2,
                      checked: true,
                      child: Text('Checked'),
                    ),
                    PopupMenuItem(
                      value: 3,
                      enabled: false,
                      child: Text('Disabled'),
                    ),
                  ],
                ),
              ),
            ),
          );
          await t.tap(find.byKey(_open));
          await t.pumpAndSettle();
          expect(t.getSize(entry('Plain')).height, touch ? 44 : 32);
          expect(t.getSize(entry('Checked')).height, touch ? 44 : 32);
          expect(
            t.getTopLeft(find.text('Plain')).dx,
            t.getTopLeft(find.text('Checked')).dx,
          );
          expect(
            t.getSemantics(entry('Checked')),
            matchesSemantics(
              label: 'Checked',
              isButton: true,
              hasCheckedState: true,
              isChecked: true,
              hasEnabledState: true,
              isEnabled: true,
              isFocusable: true,
              hasTapAction: true,
              hasFocusAction: true,
            ),
          );
          await t.tap(entry('Disabled'));
          await t.pumpAndSettle();
          expect(picked, 0);
          expect(find.byType(FloatingSurface), findsOneWidget);
          await t.tapAt(const Offset(5, 5));
          await t.pumpAndSettle();
          expect(find.byType(FloatingSurface), findsNothing);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'selection and item callbacks wait for exit before opening a dialog',
    (t) async {
      final events = <String>[];
      await t.pumpWidget(
        host(
          child: Builder(
            builder: (context) => Center(
              child: menu(
                items: [
                  PopupMenuItem(
                    value: 1,
                    onTap: () => events.add('item'),
                    child: const Text('Action'),
                  ),
                ],
                onSelected: (_) {
                  expect(find.byType(FloatingSurface), findsNothing);
                  events.add('selected');
                  showWorkbenchDialog<void>(
                    context: context,
                    builder: (_) =>
                        const AlertDialog(title: Text('Next dialog')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(_open));
      await t.pumpAndSettle();
      await t.tap(entry('Action'));
      // A second pointer release during exit must not act on the page below.
      await t.tapAt(t.getCenter(entry('Action')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 45));
      expect(events, isEmpty);
      expect(find.text('Next dialog'), findsNothing);
      await t.pumpAndSettle();
      expect(events, ['item', 'selected']);
      expect(find.text('Next dialog'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'whole menu fades without reflow and an interrupted entrance stays continuous',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(
        host(
          navigator: nav,
          child: Center(child: menu()),
        ),
      );
      await t.tap(find.byKey(_open));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      final surface = find.byType(FloatingSurface);
      final opacity = find.ancestor(
        of: surface,
        matching: find.byType(Opacity),
      );
      final before = t.widget<Opacity>(opacity).opacity;
      final size = t.getSize(surface);
      expect(before, inExclusiveRange(0, 1));
      nav.currentState!.pop();
      await t.pump();
      expect(t.widget<Opacity>(opacity).opacity, closeTo(before, .001));
      expect(t.getSize(surface), size);
      await t.pumpAndSettle();
      expect(surface, findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  for (final scale in [.85, 1.5]) {
    testWidgets(
      'button flips above the bottom edge and tracks resize at $scale zoom',
      (t) async {
        t.view.physicalSize = const Size(800, 600);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          host(
            scale: scale,
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(padding: const EdgeInsets.all(20), child: menu()),
            ),
          ),
        );
        await t.tap(find.byKey(_open));
        await t.pumpAndSettle();
        void check() {
          final button = t.getRect(find.byKey(_open)),
              surface = t.getRect(find.byType(FloatingSurface));
          expect(surface.bottom, closeTo(button.top - 4 * scale, .01));
          expect(surface.right, closeTo(button.right, .01));
          expect(surface.left, greaterThanOrEqualTo(8 * scale));
        }

        check();
        t.view.physicalSize = const Size(560, 400);
        await t.pumpAndSettle();
        check();
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'long titles and hints fit a narrow window and scroll to keyboard selection',
    (t) async {
      t.view.physicalSize = const Size(240, 240);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      int? picked;
      await t.pumpWidget(
        host(
          child: menu(
            onSelected: (v) => picked = v,
            items: [
              for (var i = 0; i < 12; i++)
                PopupMenuItem(
                  value: i,
                  child: MenuLabel(
                    'A very long title for action $i',
                    shortcut: 'Ctrl+Shift+Alt+Enter',
                  ),
                ),
            ],
          ),
        ),
      );
      await t.tap(find.byKey(_open));
      await t.pumpAndSettle();
      final surface = t.getRect(find.byType(FloatingSurface));
      expect(surface.left, greaterThanOrEqualTo(8));
      expect(surface.right, lessThanOrEqualTo(232));
      expect(surface.bottom, lessThanOrEqualTo(232));
      for (var i = 0; i < 11; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
      }
      expect(
        find.text('A very long title for action 11').hitTestable(),
        findsOneWidget,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(picked, 11);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'removed anchor keeps last placement and discards stale callbacks',
    (t) async {
      var visible = true, picked = false;
      late StateSetter update;
      await t.pumpWidget(
        host(
          child: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return Center(
                child: visible
                    ? menu(onSelected: (_) => picked = true)
                    : const SizedBox(),
              );
            },
          ),
        ),
      );
      await t.tap(find.byKey(_open));
      await t.pumpAndSettle();
      final before = t.getRect(find.byType(FloatingSurface));
      update(() => visible = false);
      await t.pumpAndSettle();
      expect(t.getRect(find.byType(FloatingSurface)), before);
      await t.tap(entry('Action'));
      await t.pumpAndSettle();
      expect(picked, isFalse);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion is immediate and guarded dialogs keep drafts and focus',
    (t) async {
      final controller = TextEditingController(text: 'unsaved draft');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      late BuildContext caller;
      await t.pumpWidget(
        host(
          reduced: true,
          child: Builder(
            builder: (context) {
              caller = context;
              return Column(
                children: [
                  TextField(controller: controller, focusNode: focus),
                  menu(),
                ],
              );
            },
          ),
        ),
      );
      await t.tap(find.byKey(_open));
      await t.pump();
      await t.pump();
      final route = ModalRoute.of(t.element(entry('Action')))!;
      expect(route.animation!.value, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      focus.requestFocus();
      await t.pump();
      var allowClose = false, completed = false;
      late StateSetter update;
      final result = showWorkbenchDialog<String>(
        context: caller,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return PopScope(
              canPop: allowClose,
              child: AlertDialog(
                title: const Text('Saving'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'saved'),
                    child: const Text('Done'),
                  ),
                ],
              ),
            );
          },
        ),
      );
      result.then((_) => completed = true);
      await t.pump();
      await t.pump();
      expect(
        ModalRoute.of(t.element(find.text('Saving')))!.animation!.value,
        1,
      );
      await t.tapAt(const Offset(2, 2));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(completed, isFalse);
      expect(find.text('Saving'), findsOneWidget);
      update(() => allowClose = true);
      await t.pump();
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      expect(await result, 'saved');
      expect(controller.text, 'unsaved draft');
      expect(focus.hasFocus, isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
