// A periodic job that runs only while the widget is on screen. The side bars
// are kept alive when another one is chosen (kernel/shell.dart), and TickerMode
// is how the shell tells a hidden one: a timer left running there would ask the
// server for something nobody can see. It runs once when the widget becomes
// visible again, so what is shown is current the moment it appears.
import 'dart:async';

import 'package:flutter/widgets.dart';

mixin VisiblePolling<T extends StatefulWidget> on State<T> {
  Timer? _poll;
  bool _wasVisible = true;

  /// How often [poll] runs while visible.
  Duration get pollEvery;

  /// The job. Called when the widget becomes visible and then every [pollEvery].
  void poll();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_wasVisible) poll();
    _wasVisible = visible;
    if (visible) {
      _poll ??= Timer.periodic(pollEvery, (_) {
        if (mounted) poll();
      });
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}