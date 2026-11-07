// Touch or pointer, decided by the last input, not by the device: a laptop
// with a touch screen is both. Rows are 28 px with a mouse and 44 px under a
// finger, and every menu has both a right-click and a long-press way in.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class InputMode extends ChangeNotifier {
  bool _touch;
  InputMode({bool? touch}) : _touch = touch ?? (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  bool get touch => _touch;

  void _set(bool v) {
    if (v == _touch) return;
    _touch = v;
    notifyListeners();
  }

  /// Feeds the mode from a pointer-down event.
  void onPointer(PointerEvent e) {
    switch (e.kind) {
      case PointerDeviceKind.touch:
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
        _set(true);
      case PointerDeviceKind.mouse:
      case PointerDeviceKind.trackpad:
        _set(false);
      case PointerDeviceKind.unknown:
        break;
    }
  }

  /// Whether the current mode is touch; widgets that call this rebuild when it changes.
  static bool isTouch(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Scope>()!.touch;

  /// Row height for lists and trees.
  static double row(BuildContext context) => isTouch(context) ? 44 : 28;

  static Widget scope({required InputMode mode, required Widget child}) => ListenableBuilder(
        listenable: mode,
        builder: (_, _) => _Scope(touch: mode.touch, child: child),
      );
}

class _Scope extends InheritedWidget {
  final bool touch;
  const _Scope({required this.touch, required super.child});
  @override
  bool updateShouldNotify(_Scope old) => old.touch != touch;
}
