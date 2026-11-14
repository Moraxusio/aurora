import 'package:aurora/features/ai/ai_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AiTranscriptController controller;
  late List<String> ids;
  late Map<String, int> builds;
  setUp(() {
    controller = AiTranscriptController();
    ids = [for (var i = 0; i < 180; i++) 'm$i'];
    builds = {};
  });
  tearDown(() => controller.dispose());
  Future<void> pump(WidgetTester t, {double width = 520}) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiTranscript(
            controller: controller,
            ids: ids,
            itemBuilder: (_, index) {
              builds.update(ids[index], (n) => n + 1, ifAbsent: () => 1);
              return Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  '${ids[index]}\n${List.generate(12, (i) => 'Paragraph $i: A stable reading anchor must survive wrapping, streaming and viewport resizing.').join('\n\n')}',
                  key: ValueKey('text-${ids[index]}'),
                  style: const TextStyle(fontSize: 15, height: 1.6),
                ),
              );
            },
          ),
        ),
      ),
    );
    await t.pump();
  }

  testWidgets(
    'distant message anchors navigate directly without laying out the whole history',
    (t) async {
      await pump(t);
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 1),
      );
      expect(builds.length, lessThan(10));
      controller.reveal('m3');
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('text-m3')), findsOneWidget);
      expect(controller.followsLatest.value, isFalse);
      expect(builds.length, lessThan(18));
      controller.reveal('m150');
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('text-m150')), findsOneWidget);
      expect(builds.length, lessThan(26));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a short transcript starts at the top instead of reserving an empty page above it',
    (t) async {
      final short = ['one', 'two'];
      t.view.physicalSize = const Size(520, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiTranscript(
              controller: controller,
              ids: short,
              itemBuilder: (_, index) => SizedBox(
                key: ValueKey(short[index]),
                height: 60,
                child: Text(short[index]),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(t.getTopLeft(find.byKey(const ValueKey('one'))).dy, 0);
      expect(controller.offset, 0);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'latest navigation works in one layout even when the origin and metrics are unchanged',
    (t) async {
      await pump(t);
      for (var repeat = 0; repeat < 3; repeat++) {
        controller.reveal('m176');
        await t.pump();
        expect(controller.offset, closeTo(0, .25));
        final extent = controller.position.maxScrollExtent;
        expect(extent, greaterThan(200));
        controller.followLatest();
        await t.pump();
        expect(controller.position.maxScrollExtent, extent);
        expect(controller.offset, closeTo(extent, .25));
      }
      // Normal user scrolling must still leave the tail and must not be undone
      // by an otherwise identical rebuild.
      final tail = controller.offset;
      await t.drag(
        find.byKey(const ValueKey('ai-transcript')),
        const Offset(0, 280),
      );
      await t.pumpAndSettle();
      expect(controller.followsLatest.value, isFalse);
      expect(controller.offset, lessThan(tail - 100));
      final readingOffset = controller.offset;
      await pump(t);
      expect(controller.offset, closeTo(readingOffset, .25));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'resizing preserves the same text character before paint with no delayed oscillation',
    (t) async {
      await pump(t);
      controller.reveal('m80');
      await t.pump();
      await t.pump();
      controller.jumpTo(controller.offset + 410);
      await t.pump();
      final before = controller.debugReadingAnchor!;
      expect(before.$1, 'm80');
      expect(before.$2, isNotNull);
      for (final width in [420.0, 680.0, 390.0, 520.0, 780.0, 420.0]) {
        final anchor = controller.debugReadingAnchor!;
        t.view.physicalSize = Size(width, 800);
        await t.pump();
        final text = anchor.$2!;
        final local = text is RenderEditable
            ? text
                  .getEndpointsForSelection(
                    TextSelection.collapsed(offset: anchor.$3!),
                  )
                  .first
                  .point
            : (text as RenderParagraph).getOffsetForCaret(
                TextPosition(offset: anchor.$3!),
                Rect.zero,
              );
        final y = MatrixUtils.transformPoint(
          text.getTransformTo(RenderAbstractViewport.of(text)),
          local,
        ).dy;
        expect(
          y,
          closeTo(anchor.$4, 1.5),
          reason:
              'reflow must retain the actual reading character at width $width',
        );
        final offset = controller.offset;
        for (var frame = 0; frame < 6; frame++) {
          await t.pump(const Duration(milliseconds: 30));
          expect(controller.offset, closeTo(offset, .1));
        }
        expect(controller.followsLatest.value, isFalse);
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'streaming and viewport height changes do not resume following while reading',
    (t) async {
      await pump(t);
      controller.reveal('m60');
      await t.pump();
      await t.pump();
      controller.jumpTo(controller.offset + 170);
      await t.pump();
      final before = controller.debugReadingAnchor!;
      ids = [...ids, 'new-output'];
      await pump(t);
      expect(controller.debugReadingAnchor!.$1, before.$1);
      expect(controller.followsLatest.value, isFalse);
      t.view.physicalSize = const Size(520, 600);
      await t.pump();
      expect(controller.debugReadingAnchor!.$1, before.$1);
      controller.followLatest();
      await t.pump();
      await t.pump();
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 1),
      );
      expect(find.byKey(const ValueKey('text-new-output')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
}
