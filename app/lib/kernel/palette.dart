// The command palette (Ctrl+Shift+P): every command of every available
// feature, plus the shell's own, filtered as you type. Arrow keys and Enter
// work; so does a tap.
import 'package:aurora/ui/aurora_ui.dart';
import 'feature.dart';

/// The commands run most recently, newest first. Kept for the life of the
/// process: the palette opens on what was used last instead of an arbitrary
/// first entry.
class RecentCommands {
  static final List<String> _ids = [];
  static const _max = 12;

  static List<String> get ids => List.unmodifiable(_ids);

  static void used(String id) {
    _ids.remove(id);
    _ids.insert(0, id);
    if (_ids.length > _max) _ids.removeRange(_max, _ids.length);
  }

  static void clear() => _ids.clear();
}

/// Commands that are for fixing the app, not for working in it: they come last
/// so a bare Enter never runs one by accident.
const _tailIds = {'diagnostics.copyGui'};

/// The order the palette shows. With nothing typed: what was used last, then the
/// rest in their own order, diagnostics at the end. With a query: every command
/// whose letters appear in order in "group title", a whole-text hit first, then
/// the earliest match.
List<Command> rankCommands(
  List<Command> commands,
  String query, {
  List<String>? recent,
}) {
  final list = commands.where((c) => c.enabled?.call() ?? true).toList();
  final q = query.trim().toLowerCase();
  if (q.isEmpty) {
    final order = recent ?? RecentCommands.ids;
    int rank(Command c) {
      if (_tailIds.contains(c.id)) return 1 << 20;
      final i = order.indexOf(c.id);
      return i < 0 ? 1 << 10 : i;
    }

    // a stable sort: commands of equal rank keep the order they came in
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final r = rank(a.$2).compareTo(rank(b.$2));
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }
  final scored = <(int, int, Command)>[];
  for (var n = 0; n < list.length; n++) {
    final c = list[n];
    final hay = '${c.group} ${c.title}'.toLowerCase();
    var at = -1, first = -1, ok = true;
    for (final ch in q.split('')) {
      if (ch == ' ') continue;
      at = hay.indexOf(ch, at + 1);
      if (at < 0) {
        ok = false;
        break;
      }
      first = first < 0 ? at : first;
    }
    if (ok) {
      final tail = _tailIds.contains(c.id) ? 1000 : 0;
      scored.add((first + (hay.contains(q) ? -100 : 0) + tail, n, c));
    }
  }
  scored.sort(
    (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
  );
  return [for (final s in scored) s.$3];
}

/// The icon of a command: its own, else one for its group, else a quiet dot.
/// Never a chevron: that reads as "expands".
IconData commandIcon(Command c) => c.icon ?? groupIcon(c.group);

IconData groupIcon(String group) => switch (group) {
  '服务器' => Icons.dns_outlined,
  '视图' => Icons.visibility_outlined,
  '外观' => Icons.palette_outlined,
  '终端' => Icons.terminal,
  '文件' => Icons.folder_outlined,
  '搜索' => Icons.search,
  'Git' => Icons.fork_right,
  'AI 助手' => Icons.auto_awesome_outlined,
  '诊断' => Icons.bug_report_outlined,
  '设置' => Icons.settings_outlined,
  '标签与布局' => Icons.view_quilt_outlined,
  '本机' => Icons.computer_outlined,
  '监控' => Icons.monitor_heart_outlined,
  '代理' => Icons.alt_route,
  _ => Icons.circle_outlined,
};
