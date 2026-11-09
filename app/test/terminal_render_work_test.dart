import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart';

void main() {
  testWidgets(
    'cell redraws coalesce caret work and do not relayout an unchanged viewport',
    (t) async {
      final term = Terminal();
      final focus = FocusNode();
      final controller = TerminalController();
      var callbacks = 0;
      final object = _Render(term, controller, focus, () => callbacks++);
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Focus(focusNode: focus, child: object),
        ),
      );
      focus.requestFocus();
      await t.pump();
      final render = t.renderObject<_CountingRender>(find.byWidget(object));
      final layouts = render.layouts;
      final prior = callbacks;
      for (var i = 0; i < 100; i++) {
        term.write('\x1b[Hframe $i');
      }
      expect(
        callbacks,
        prior,
        reason: 'no synchronous platform work per network chunk',
      );
      await t.pump();
      expect(
        render.layouts,
        layouts,
        reason: 'cells changed, buffer extent and viewport did not',
      );
      expect(callbacks - prior, 1);
      await t.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      controller.dispose();
    },
  );

  testWidgets('an unmoved caret is not repeatedly sent to Windows text input', (
    t,
  ) async {
    final term = Terminal();
    final focus = FocusNode();
    final calls = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        null,
      ),
    );
    await t.pumpWidget(MaterialApp(home: TerminalView(term, focusNode: focus)));
    focus.requestFocus();
    await t.pump();
    term.write('\x1b[Hsame cursor');
    await t.pump();
    calls.clear();
    for (var i = 0; i < 5; i++) {
      term.write('\x1b[Hsame cursor');
      await t.pump();
    }
    expect(
      calls.where(
        (c) =>
            c == 'TextInput.setCaretRect' ||
            c == 'TextInput.setComposingRect' ||
            c == 'TextInput.setEditableSizeAndTransform',
      ),
      isEmpty,
    );
    term.write('\x1b[2;2H');
    await t.pump();
    expect(calls, contains('TextInput.setCaretRect'));
    await t.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  });
}

class _Render extends LeafRenderObjectWidget {
  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focus;
  final VoidCallback callback;
  const _Render(this.terminal, this.controller, this.focus, this.callback);
  @override
  _CountingRender createRenderObject(BuildContext context) =>
      _CountingRender(terminal, controller, focus, callback);
}

class _CountingRender extends RenderTerminal {
  int layouts = 0;
  _CountingRender(
    Terminal t,
    TerminalController c,
    FocusNode f,
    VoidCallback callback,
  ) : super(
        terminal: t,
        controller: c,
        offset: ViewportOffset.fixed(0),
        padding: EdgeInsets.zero,
        autoResize: true,
        textStyle: const TerminalStyle(fontFamily: 'Ahem'),
        textScaler: TextScaler.noScaling,
        theme: TerminalThemes.defaultTheme,
        focusNode: f,
        cursorType: TerminalCursorType.block,
        alwaysShowCursor: false,
        onEditableRect: (_, _) => callback(),
      );
  @override
  void performLayout() {
    layouts++;
    super.performLayout();
  }
}
