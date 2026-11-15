import 'package:aurora/kernel/retained_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

class _Document extends StatefulWidget {
  final ValueNotifier<int> builds;
  const _Document(this.builds);
  @override
  State<_Document> createState() => _DocumentState();
}

class _DocumentState extends State<_Document> {
  final controller = TextEditingController(text: 'unsaved');
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.builds.value++;
    final size = MediaQuery.sizeOf(context);
    return Column(
      children: [
        Text('${size.width}'),
        TextField(controller: controller),
      ],
    );
  }
}

void main() {
  for (final ancestorHidden in [false, true]) {
    testWidgets(
      'a tooltip follows its retained pane offstage without losing its child (ancestor: $ancestorHidden)',
      (t) async {
        final visible = ValueNotifier(true), builds = ValueNotifier(0);
        final semantics = t.ensureSemantics();
        List<String> nativeLabels() {
          final labels = <String>[];
          void collect(SemanticsNode node) {
            labels.add(node.getSemanticsData().label);
            node.visitChildren((child) {
              collect(child);
              return true;
            });
          }

          collect(
            t
                .binding
                .renderViews
                .first
                .owner!
                .semanticsOwner!
                .rootSemanticsNode!,
          );
          return labels;
        }

        const tooltipKey = ValueKey('pane-tooltip');
        final doc = Tooltip(
          key: tooltipKey,
          message: 'retained document help',
          child: _Document(builds),
        );
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: visible,
                builder: (_, shown, _) => Offstage(
                  offstage: ancestorHidden && !shown,
                  child: TickerMode(
                    enabled: !ancestorHidden || shown,
                    child: RetainedPane(
                      visible: ancestorHidden || shown,
                      child: doc,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final original = t.state<_DocumentState>(find.byType(_Document));
        t.state<TooltipState>(find.byKey(tooltipKey)).ensureTooltipVisible();
        await t.pumpAndSettle();
        expect(find.text('retained document help'), findsOneWidget);
        expect(nativeLabels(), contains('retained document help'));
        Tooltip.dismissAllToolTips();
        visible.value = false;
        await t.pumpAndSettle();
        expect(
          find.text('retained document help'),
          findsNothing,
          reason: 'a paused tooltip must not remain in the root overlay with an offstage semantics parent',
        );
        expect(find.bySemanticsLabel('retained document help'), findsNothing);
        expect(
          nativeLabels(),
          isNot(contains('retained document help')),
          reason: 'the native semantics tree must not retain a floating child whose pane is hidden',
        );
        visible.value = true;
        await t.pumpAndSettle();
        expect(t.state(find.byType(_Document)), same(original));
        expect(original.controller.text, 'unsaved');
        await t.pumpWidget(const SizedBox());
        semantics.dispose();
        visible.dispose();
        builds.dispose();
      },
    );
    testWidgets(
      'retained panes freeze hidden metrics and restore the same editor (ancestor: $ancestorHidden)',
      (t) async {
        final visible = ValueNotifier(true),
            builds = ValueNotifier(0),
            size = ValueNotifier(const Size(900, 700));
        final doc = _Document(builds);
        final semantics = t.ensureSemantics();
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: Listenable.merge([visible, size]),
                builder: (_, _) => MediaQuery(
                  data: MediaQueryData(size: size.value),
                  child: Offstage(
                    offstage: ancestorHidden && !visible.value,
                    child: TickerMode(
                      enabled: !ancestorHidden || visible.value,
                      child: RetainedPane(
                        visible: ancestorHidden || visible.value,
                        child: doc,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final original = t.state<_DocumentState>(find.byType(_Document));
        await t.tap(find.byType(TextField));
        await t.enterText(find.byType(TextField), 'draft with undo');
        visible.value = false;
        await t.pumpAndSettle();
        expect(find.byType(TextField).hitTestable(), findsNothing);
        final hiddenBuilds = builds.value;
        for (var i = 0; i < 24; i++) {
          size.value = Size(1000 + i.toDouble(), 800);
          await t.pump();
        }
        expect(
          builds.value,
          hiddenBuilds,
          reason: 'window metrics must not reflow hidden documents',
        );
        visible.value = true;
        await t.pumpAndSettle();
        expect(t.state(find.byType(_Document)), same(original));
        expect(original.controller.text, 'draft with undo');
        expect(find.text('1023.0'), findsOneWidget);
        expect(t.takeException(), isNull);
        semantics.dispose();
        await t.pumpWidget(const SizedBox());
        visible.dispose();
        builds.dispose();
        size.dispose();
      },
    );
  }
}
