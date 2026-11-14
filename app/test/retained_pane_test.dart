import 'package:aurora/kernel/retained_pane.dart';
import 'package:flutter/material.dart';
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
