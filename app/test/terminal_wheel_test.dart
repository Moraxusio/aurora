// What the terminal view sends for a mouse wheel, by what the program in the
// terminal asked for. The three cases a wheel meets:
//   - a plain shell (normal screen): the view scrolls its own history; nothing
//     is sent;
//   - a full-screen program that asked for mouse events (opencode, vim with
//     mouse=a, htop): the wheel is sent as that program's mouse report;
//   - a full-screen program that did not (less, man, git log): the wheel is
//     sent as arrow keys, which is what every terminal does so that these
//     programs can be scrolled at all.
import 'package:aurora/features/terminal/terminal_colors.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/infinite_scroll_view.dart';

Future<(Terminal, StringBuffer)> _show(WidgetTester t) async {
  t.view.physicalSize = const Size(900, 600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  final term = Terminal(maxLines: 1000);
  final sent = StringBuffer();
  term.onOutput = sent.write;
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: TerminalView(
          term,
          theme: terminalTheme(Ide.light),
          textStyle: const TerminalStyle(fontSize: 14, fontFamily: 'Ahem'),
        ),
      ),
    ),
  );
  await t.pump();
  return (term, sent);
}

/// Notches of a mouse wheel at the middle of the view, as the platform sends
/// them: a pointer scroll signal of 120 logical pixels per notch (positive
/// dy is down).
Future<void> wheel(WidgetTester t, {required bool up, int notches = 1}) async {
  final at = t.getCenter(find.byType(TerminalView));
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: at);
  await t.pump();
  for (var i = 0; i < notches; i++) {
    await t.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: at,
        scrollDelta: Offset(0, up ? -120 : 120),
      ),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
  await g.removePointer();
  await t.pump();
}

void main() {
  testWidgets('a replacement scroll position still reports wheel changes', (
    t,
  ) async {
    final offsets = <double>[];
    Widget view(ScrollPhysics physics) => MaterialApp(
      home: ScrollConfiguration(
        behavior: _Physics(physics),
        child: InfiniteScrollView(
          onScroll: offsets.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await t.pumpWidget(view(const ClampingScrollPhysics()));
    final state = t.state<ScrollableState>(find.byType(Scrollable));
    final old = state.position;
    old.jumpTo(48);
    expect(offsets.last, 48);
    await t.pumpWidget(view(const BouncingScrollPhysics()));
    expect(identical(state.position, old), isFalse);
    offsets.clear();
    state.position.jumpTo(96);
    expect(offsets, [96]);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(); // disposing the old position must have no leftover listener
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'leaving and reentering the alternate screen does not replay old wheel input',
    (t) async {
      final (term, sent) = await _show(t);
      const enter = '\x1b[?1049h\x1b[?1000h\x1b[?1006h';
      term.write(enter);
      await t.pump();
      await wheel(t, up: false);
      final first = RegExp(r'\x1b\[<65;\d+;\d+M')
          .allMatches(sent.toString())
          .length;
      expect(first, greaterThan(0));
      await wheel(t, up: false, notches: 12);
      term.write('\x1b[?1049l');
      await t.pump();
      term.write(enter);
      await t.pump();
      sent.clear();
      await wheel(t, up: false);
      expect(
        sent.toString(),
        isNot(contains('\x1b[<64;')),
        reason: 'a downward notch must not replay an upward correction',
      );
      expect(
        RegExp(r'\x1b\[<65;\d+;\d+M').allMatches(sent.toString()).length,
        first,
      );
    },
  );

  testWidgets(
    'wheel reports use terminal-local coordinates when the terminal is offset',
    (t) async {
      final (term, sent) = await _show(t);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(left: 240, top: 96),
              child: TerminalView(
                term,
                textStyle: const TerminalStyle(
                  fontSize: 14,
                  fontFamily: 'Ahem',
                ),
              ),
            ),
          ),
        ),
      );
      term.write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');
      await t.pump();
      final state = t.state<TerminalViewState>(find.byType(TerminalView));
      final render = state.renderTerminal;
      final at = render.localToGlobal(
        Offset(render.cellSize.width * 4.5, render.lineHeight * 2.5),
      );
      final cell = render.getCellOffset(render.globalToLocal(at));
      await t.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: at,
          scrollDelta: const Offset(0, 120),
        ),
      );
      await t.pump();
      final reports = RegExp(r'\x1b\[<65;(\d+);(\d+)M')
          .allMatches(sent.toString())
          .toList();
      expect(reports, isNotEmpty);
      for (final r in reports) {
        expect(r.group(1), '${cell.x + 1}');
        expect(r.group(2), '${cell.y + 1}');
      }
    },
  );

  testWidgets(
    'trackpad fractions accumulate without a font change replaying old pixels',
    (t) async {
      final (term, sent) = await _show(t);
      term.write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');
      await t.pump();
      final position = t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(300);
      sent.clear();
      final state = t.state<TerminalViewState>(find.byType(TerminalView));
      state.renderTerminal.textStyle = const TerminalStyle(
        fontSize: 20,
        fontFamily: 'Ahem',
      );
      await t.pump();
      position.jumpTo(303);
      expect(
        sent.toString(),
        isEmpty,
        reason: 'only the three new pixels count after font size changes',
      );
      position.jumpTo(330);
      expect(sent.toString(), contains('\x1b[<65;'));
      expect(sent.toString(), isNot(contains('\x1b[<64;')));
    },
  );

  testWidgets(
    'a program that asked for the mouse gets the wheel as a mouse report',
    (t) async {
      final (term, sent) = await _show(t);
      term.write(
        '\x1b[?1049h\x1b[?1000h\x1b[?1006h',
      ); // alternate screen, mouse reporting, SGR format
      await t.pump();
      await wheel(t, up: true, notches: 3);
      expect(
        sent.toString(),
        contains('\x1b[<64;'),
        reason:
            'wheel up is button 64 in an SGR report; sent: ${sent.toString().replaceAll('\x1b', r'\e')}',
      );
      sent.clear();
      await wheel(t, up: false, notches: 3);
      expect(
        sent.toString(),
        contains('\x1b[<65;'),
        reason:
            'wheel down is button 65; sent: ${sent.toString().replaceAll('\x1b', r'\e')}',
      );
    },
  );

  testWidgets(
    'a full-screen program without the mouse gets arrow keys, one per notch of the wheel at least',
    (t) async {
      final (term, sent) = await _show(t);
      term.write('\x1b[?1049h'); // alternate screen only (less, man)
      await t.pump();
      await wheel(t, up: false, notches: 4);
      final downs =
          '\x1b[B'.allMatches(sent.toString()).length +
          '\x1bOB'.allMatches(sent.toString()).length;
      expect(
        downs,
        greaterThanOrEqualTo(4),
        reason:
            'four notches down must send at least four Down keys; sent: ${sent.toString().replaceAll('\x1b', r'\e')}',
      );
      sent.clear();
      await wheel(t, up: true, notches: 4);
      final ups =
          '\x1b[A'.allMatches(sent.toString()).length +
          '\x1bOA'.allMatches(sent.toString()).length;
      expect(
        ups,
        greaterThanOrEqualTo(4),
        reason:
            'four notches up must send at least four Up keys; sent: ${sent.toString().replaceAll('\x1b', r'\e')}',
      );
    },
  );

  testWidgets(
    'on the normal screen the wheel scrolls the view\'s own history and sends nothing',
    (t) async {
      final (term, sent) = await _show(t);
      term.write('${List.generate(200, (i) => 'line $i').join('\r\n')}\r\n');
      await t.pump();
      await wheel(t, up: true, notches: 5);
      expect(
        sent.toString(),
        isEmpty,
        reason:
            'nothing goes to the program; sent: ${sent.toString().replaceAll('\x1b', r'\e')}',
      );
      final pos = (t.state<ScrollableState>(find.byType(Scrollable).first))
          .position;
      expect(
        pos.pixels,
        lessThan(pos.maxScrollExtent),
        reason: 'the view moved up from the bottom',
      );
    },
  );
}

class _Physics extends ScrollBehavior {
  final ScrollPhysics physics;
  const _Physics(this.physics);
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => physics;
  @override
  bool shouldNotify(covariant _Physics oldDelegate) =>
      physics != oldDelegate.physics;
}
