// The window's own caption parts (D-103): the native window has no caption
// (windows/runner/win32_window.cpp), so the app draws the minimize, maximize
// and close buttons, makes its title bars draggable, and gives the top edge
// back its resize handle. Off Windows, or in tests, none of this shows.
import 'package:flutter/material.dart';

import '../theme/ide_theme.dart';
import 'desktop_lifecycle.dart';

abstract final class WindowFrame {
  /// Width of the three window buttons; title bars leave this free.
  static const double buttons = 46.0 * 3;

  /// Height of the window buttons, and of the app's title bars.
  static const double height = 35;

  static bool get on => DesktopLifecycle.frameless.value;
}

/// The app's frame: the window buttons and the top resize edge over [child].
class WindowChrome extends StatelessWidget {
  final Widget child;
  const WindowChrome({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopLifecycle.frameless,
      child: child,
      builder: (context, frameless, child) {
        if (!frameless) return child!;
        return ValueListenableBuilder<bool>(
          valueListenable: DesktopLifecycle.maximized,
          child: child,
          builder: (context, maximized, child) => Stack(children: [
            Positioned.fill(child: child!),
            const Positioned(top: 0, right: 0, child: WindowButtons()),
            if (!maximized) ...[
              const Positioned(top: 0, left: 8, right: WindowFrame.buttons, height: 4, child: _Edge('top', SystemMouseCursors.resizeUpDown)),
              const Positioned(top: 0, left: 0, width: 8, height: 8, child: _Edge('topLeft', SystemMouseCursors.resizeUpLeftDownRight)),
            ],
          ]),
        );
      },
    );
  }
}

class _Edge extends StatelessWidget {
  final String edge;
  final MouseCursor cursor;
  const _Edge(this.edge, this.cursor);
  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => DesktopLifecycle.window('startResize', edge),
        ),
      );
}

/// Drags the window by [child]; a double click maximizes or restores.
/// Children that handle taps (buttons) keep them.
class WindowDragArea extends StatelessWidget {
  final Widget child;
  final bool doubleClick;
  const WindowDragArea({super.key, required this.child, this.doubleClick = true});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopLifecycle.frameless,
      child: child,
      builder: (context, frameless, child) => !frameless
          ? child!
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => DesktopLifecycle.window('startDrag'),
              onDoubleTap: doubleClick ? () => DesktopLifecycle.window('toggleMaximize') : null,
              child: child,
            ),
    );
  }
}

/// Space the window buttons cover at the right end of a title bar.
class WindowButtonsGap extends StatelessWidget {
  const WindowButtonsGap({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: DesktopLifecycle.frameless,
        builder: (_, on, _) => SizedBox(width: on ? WindowFrame.buttons : 0),
      );
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopLifecycle.maximized,
      builder: (context, maximized, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        _WindowButton(_Glyph.minimize, '最小化', () => DesktopLifecycle.window('minimize')),
        _WindowButton(maximized ? _Glyph.restore : _Glyph.maximize, maximized ? '向下还原' : '最大化', () => DesktopLifecycle.window('toggleMaximize')),
        _WindowButton(_Glyph.close, '关闭到托盘', () => DesktopLifecycle.window('close'), close: true),
      ]),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

class _WindowButton extends StatefulWidget {
  final _Glyph glyph;
  final String tip;
  final VoidCallback onTap;
  final bool close;
  const _WindowButton(this.glyph, this.tip, this.onTap, {this.close = false});
  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final red = const Color(0xFFC42B1C);
    final bg = widget.close
        ? (_down ? red.withValues(alpha: 0.8) : (_hover ? red : Colors.transparent))
        : (_down ? ide.borderStrong : (_hover ? ide.hover : Colors.transparent));
    final fg = widget.close && (_hover || _down) ? Colors.white : ide.textDim;
    // No Tooltip: the frame sits above the Navigator and its Overlay.
    return Semantics(
      button: true,
      label: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: Container(
            width: 46,
            height: WindowFrame.height,
            color: bg,
            alignment: Alignment.center,
            child: CustomPaint(size: const Size(10, 10), painter: _GlyphPainter(widget.glyph, fg)),
          ),
        ),
      ),
    );
  }
}

/// The thin Windows 11 caption glyphs.
class _GlyphPainter extends CustomPainter {
  final _Glyph glyph;
  final Color color;
  const _GlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final w = size.width, h = size.height;
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), p);
      case _Glyph.maximize:
        canvas.drawRRect(RRect.fromRectAndRadius(const Offset(0.5, 0.5) & Size(w - 1, h - 1), const Radius.circular(1.5)), p);
      case _Glyph.restore:
        canvas.drawRRect(RRect.fromRectAndRadius(Offset(0.5, 2.5) & Size(w - 3, h - 3), const Radius.circular(1.5)), p);
        final back = Path()
          ..moveTo(2.5, 2.5)
          ..lineTo(2.5, 1.5)
          ..quadraticBezierTo(2.5, 0.5, 3.5, 0.5)
          ..lineTo(w - 1.5, 0.5)
          ..quadraticBezierTo(w - 0.5, 0.5, w - 0.5, 1.5)
          ..lineTo(w - 0.5, h - 4.5)
          ..quadraticBezierTo(w - 0.5, h - 3.5, w - 1.5, h - 3.5)
          ..lineTo(w - 2.5, h - 3.5);
        canvas.drawPath(back, p);
      case _Glyph.close:
        canvas.drawLine(Offset.zero, Offset(w, h), p);
        canvas.drawLine(Offset(w, 0), Offset(0, h), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
