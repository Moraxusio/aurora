// One retained task. Documents belong to editors; terminals to the bottom panel.
// The kernel keeps every open tab's widget alive while another is shown, so a
// terminal keeps its screen and an editor its unsaved text.
import 'package:flutter/material.dart';
import 'package:aurora_profile/aurora_profile.dart';

enum TabArea { editor, terminal, assistant }

class EditorTab {
  /// Unique within a workspace, e.g. "term:main" or "file:home:/etc/hosts".
  final String id;
  String title;
  final IconData icon;
  final Color? iconColor;

  /// Longer description for the tooltip (a full path).
  final String? tooltip;
  final WidgetBuilder builder;
  final WorkspacePath? file;
  final TabArea area;
  /// Canonical runtime identity once a draft becomes a saved AI conversation.
  /// Does not replace the host key or enter profile snapshots.
  String? taskKey;
  bool get isTerminal => area == TabArea.terminal;
  bool get isAssistant => area == TabArea.assistant;
  bool get isEditor => area == TabArea.editor;
  // File buffers are unique per server/path. Membership, rather than copying
  // editors, gives each project its own tab list without divergent dirty text.
  final Set<String> projects = {};

  /// Unsaved changes: a dot instead of the close button, and a question on close.
  final ValueNotifier<bool> dirty = ValueNotifier(false);

  /// Text for the status bar while this tab is in front ("Ln 3, Col 5").
  final ValueNotifier<String> status = ValueNotifier('');

  /// Asked before the tab closes; false keeps it open.
  Future<bool> Function()? confirmClose;

  /// Moves the cursor to a 1-based line and column (a search result, Ctrl+G).
  /// Set by editors; the tab may already be open when it is called.
  void Function(int line, int col)? reveal;

  EditorTab({required this.id, required this.title, required this.icon, required this.builder, this.iconColor, this.tooltip, this.file, this.taskKey, TabArea? area})
    : area = area ?? (id.startsWith('term:') ? TabArea.terminal : id.startsWith('ai:') ? TabArea.assistant : TabArea.editor);

  void dispose() {
    dirty.dispose();
    status.dispose();
  }
}
