import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/ui/infinite_scroll_view.dart';

/// Handles scrolling gestures in the alternate screen buffer. In alternate
/// screen buffer, the terminal don't have a scrollback buffer, instead, the
/// scroll gestures are converted to escape sequences based on the current
/// report mode declared by the application.
class TerminalScrollGestureHandler extends StatefulWidget {
  const TerminalScrollGestureHandler({
    super.key,
    required this.terminal,
    required this.getCellOffset,
    required this.getLineHeight,
    this.simulateScroll = true,
    required this.child,
  });

  final Terminal terminal;

  /// Returns the cell offset for the pixel offset.
  final CellOffset Function(Offset) getCellOffset;

  /// Returns the pixel height of lines in the terminal.
  final double Function() getLineHeight;

  /// Whether to simulate scroll events in the terminal when the application
  /// doesn't declare it supports mouse wheel events. true by default as it
  /// is the default behavior of most terminals.
  final bool simulateScroll;

  final Widget child;

  @override
  State<TerminalScrollGestureHandler> createState() =>
      _TerminalScrollGestureHandlerState();
}

class _TerminalScrollGestureHandlerState
    extends State<TerminalScrollGestureHandler> {
  /// Whether the application is in alternate screen buffer. If false, then this
  /// widget does nothing.
  var isAltBuffer = false;

  double _lastScrollPixels = 0;
  double _scrollRemainder = 0;

  void _resetScroll() {
    _lastScrollPixels = 0;
    _scrollRemainder = 0;
  }

  /// This variable tracks the last offset where the scroll gesture started.
  /// Used to calculate the cell offset of the terminal mouse event.
  var lastPointerPosition = Offset.zero;

  @override
  void initState() {
    widget.terminal.addListener(_onTerminalUpdated);
    isAltBuffer = widget.terminal.isUsingAltBuffer;
    super.initState();
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalUpdated);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalScrollGestureHandler oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdated);
      widget.terminal.addListener(_onTerminalUpdated);
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      _resetScroll();
    }
    super.didUpdateWidget(oldWidget);
  }

  void _onTerminalUpdated() {
    if (isAltBuffer != widget.terminal.isUsingAltBuffer) {
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      // Aurora patch: the alternate Scrollable is recreated on a buffer
      // change. Its position starts at zero, so the previous program's line
      // counter must not turn the first notch into dozens of reverse reports.
      _resetScroll();
      setState(() {});
    }
  }

  /// Send a single scroll event to the terminal. If [simulateScroll] is true,
  /// then if the application doesn't recognize mouse wheel events, this method
  /// will simulate scroll events by sending up/down arrow keys.
  void _sendScrollEvent(bool up) {
    final position = widget.getCellOffset(lastPointerPosition);

    final handled = widget.terminal.mouseInput(
      up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
      TerminalMouseButtonState.down,
      position,
    );

    if (!handled && widget.simulateScroll) {
      widget.terminal.keyInput(
        up ? TerminalKey.arrowUp : TerminalKey.arrowDown,
      );
    }
  }

  void _onScroll(double offset) {
    final pixels = offset - _lastScrollPixels;
    _lastScrollPixels = offset;
    final height = widget.getLineHeight();
    if (!height.isFinite || height <= 0 || !pixels.isFinite || pixels == 0)
      return;
    // Convert only new pixels, not the lifetime absolute offset: changing the
    // font/scale must not reinterpret all previous input at a new line height.
    // Preserve sub-line trackpad deltas but start a reversal immediately.
    if (_scrollRemainder.sign != pixels.sign) _scrollRemainder = 0;
    _scrollRemainder += pixels;
    final lines = (_scrollRemainder / height).truncate();
    _scrollRemainder -= lines * height;
    for (var i = 0; i < lines.abs(); i++) {
      _sendScrollEvent(lines < 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isAltBuffer) {
      return widget.child;
    }

    return Listener(
      onPointerSignal: (event) {
        lastPointerPosition = event.localPosition;
      },
      onPointerDown: (event) {
        lastPointerPosition = event.localPosition;
      },
      child: InfiniteScrollView(
        key: ObjectKey(widget.terminal),
        onScroll: _onScroll,
        child: widget.child,
      ),
    );
  }
}
