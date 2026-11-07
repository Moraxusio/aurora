// One tab of the editor area: a terminal, a file, a diff, a log, the monitor.
// The kernel keeps every open tab's widget alive while another is shown, so a
// terminal keeps its screen and an editor its unsaved text.
import 'package:flutter/material.dart';

class EditorTab {
  /// Unique within a workspace, e.g. "term:main" or "file:home:/etc/hosts".
  final String id;
  final String title;
  final IconData icon;
  final Color? iconColor;

  /// Longer description for the tooltip (a full path).
  final String? tooltip;
  final WidgetBuilder builder;

  /// Unsaved changes: a dot instead of the close button, and a question on close.
  final ValueNotifier<bool> dirty = ValueNotifier(false);

  /// Text for the status bar while this tab is in front ("Ln 3, Col 5").
  final ValueNotifier<String> status = ValueNotifier('');

  /// Asked before the tab closes; false keeps it open.
  Future<bool> Function()? confirmClose;

  EditorTab({required this.id, required this.title, required this.icon, required this.builder, this.iconColor, this.tooltip});

  void dispose() {
    dirty.dispose();
    status.dispose();
  }
}
