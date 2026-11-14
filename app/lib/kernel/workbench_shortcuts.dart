import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The shell owns reserved commands. Native-like editors such as terminals
/// consult these bindings before encoding a key as input for their subprocess.
class WorkbenchShortcuts extends InheritedWidget {
  final Map<ShortcutActivator, VoidCallback> bindings;
  WorkbenchShortcuts({super.key, required this.bindings, required Widget child})
    : super(child: CallbackShortcuts(bindings: bindings, child: child));

  static KeyEventResult handle(BuildContext context, KeyEvent event) {
    final scope = context.getInheritedWidgetOfExactType<WorkbenchShortcuts>();
    if (scope == null) return KeyEventResult.ignored;
    for (final binding in scope.bindings.entries) {
      if (binding.key.accepts(event, HardwareKeyboard.instance)) {
        binding.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  bool updateShouldNotify(WorkbenchShortcuts oldWidget) => bindings != oldWidget.bindings;
}
