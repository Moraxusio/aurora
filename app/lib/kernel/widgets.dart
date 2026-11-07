// Small parts every feature uses, so lists, menus and dialogs look and behave
// the same: IDE rows, icon buttons, section headers, context menus that open
// on right-click and on long-press, confirm and text dialogs, toasts.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ide_theme.dart';
import 'input_mode.dart';

/// Messages at the bottom of the window. The key goes to MaterialApp.
class Toast {
  static final key = GlobalKey<ScaffoldMessengerState>();

  static void show(String msg, {bool error = false}) {
    final m = key.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    // Sized from the window: 480 wide at most, and lifted above the status bar
    // (in the narrow layout also above the bottom bar) so it covers neither.
    final view = View.of(m.context);
    final w = view.physicalSize.width / view.devicePixelRatio;
    final narrow = w < 600;
    final side = narrow ? 12.0 : (w - 480) / 2;
    m.showSnackBar(SnackBar(
      margin: EdgeInsets.fromLTRB(side, 0, side, narrow ? 100 : 36),
      duration: Duration(seconds: error ? 8 : 3),
      content: Row(children: [
        Icon(error ? Icons.error_outline : Icons.check_circle_outline, size: 18, color: error ? Colors.redAccent : Colors.greenAccent),
        const SizedBox(width: 10),
        Expanded(child: SelectableText(msg)),
      ]),
    ));
  }
}

class MenuItem {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool danger;
  final String? hint;

  /// A divider instead of an item.
  final bool separator;
  const MenuItem(this.label, this.onTap, {this.icon, this.danger = false, this.hint}) : separator = false;
  const MenuItem.separator()
      : label = '',
        icon = null,
        onTap = null,
        danger = false,
        hint = null,
        separator = true;
}

/// Opens a menu at [at] (global position).
Future<void> showMenuAt(BuildContext context, Offset at, List<MenuItem> items) async {
  final ide = Ide.of(context);
  final box = Overlay.of(context).context.findRenderObject() as RenderBox;
  final picked = await showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & box.size),
    items: [
      for (var i = 0; i < items.length; i++)
        if (items[i].separator)
          const PopupMenuDivider(height: 8)
        else
          PopupMenuItem<int>(
            value: i,
            enabled: items[i].onTap != null,
            height: InputMode.isTouch(context) ? 44 : 30,
            child: Row(children: [
              SizedBox(width: 22, child: items[i].icon == null ? null : Icon(items[i].icon, size: 16, color: items[i].danger ? ide.error : ide.textDim)),
              const SizedBox(width: 6),
              Expanded(child: Text(items[i].label, style: TextStyle(color: items[i].danger ? ide.error : null))),
              if (items[i].hint != null) Text(items[i].hint!, style: TextStyle(color: ide.textDim, fontSize: 11)),
            ]),
          ),
    ],
  );
  if (picked != null) items[picked].onTap?.call();
}

/// Right-click and long-press open the same menu.
class ContextArea extends StatelessWidget {
  final Widget child;
  final List<MenuItem> Function() items;
  const ContextArea({super.key, required this.child, required this.items});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) => showMenuAt(context, d.globalPosition, items()),
      onLongPressStart: (d) => showMenuAt(context, d.globalPosition, items()),
      child: child,
    );
  }
}

/// A 28 px (44 px with touch) list row: indent, leading, label, trailing.
class TreeRow extends StatelessWidget {
  final int depth;
  final Widget? leading;
  final String label;
  final String? detail;

  /// A second, smaller line under the label (a forward's traffic, a note).
  final String? subtitle;
  final Widget? trailing;
  final bool selected;
  final Color? labelColor;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final List<MenuItem> Function()? menu;
  const TreeRow({
    super.key,
    required this.label,
    this.depth = 0,
    this.leading,
    this.detail,
    this.subtitle,
    this.trailing,
    this.selected = false,
    this.labelColor,
    this.onTap,
    this.onDoubleTap,
    this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final title = Text.rich(
      TextSpan(children: [
        TextSpan(text: label, style: TextStyle(color: labelColor)),
        if (detail != null) TextSpan(text: '  $detail', style: TextStyle(color: ide.textDim, fontSize: 12)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    Widget row = Container(
      constraints: BoxConstraints(minHeight: InputMode.row(context) + (subtitle == null ? 0 : 14)),
      color: selected ? ide.selection : null,
      padding: EdgeInsets.only(left: 8.0 + depth * 14, right: 6, top: subtitle == null ? 0 : 3, bottom: subtitle == null ? 0 : 3),
      child: Row(children: [
        if (leading != null) ...[SizedBox(width: 18, child: Center(child: leading)), const SizedBox(width: 6)],
        Expanded(
          child: subtitle == null
              ? title
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  title,
                  const SizedBox(height: 1),
                  Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: ide.textDim, fontSize: 12)),
                ]),
        ),
        ?trailing,
      ]),
    );
    row = InkWell(onTap: onTap, onDoubleTap: onDoubleTap, hoverColor: selected ? Colors.transparent : ide.hover, child: row);
    if (menu != null) row = ContextArea(items: menu!, child: row);
    return row;
  }
}

/// A flat icon button that stays 28 px with a mouse and 44 px under a finger.
class IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;
  const IconBtn(this.icon, this.tooltip, this.onPressed, {super.key, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    final box = InputMode.isTouch(context) ? 44.0 : 28.0;
    final ide = Ide.of(context);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: box / 2,
        hoverColor: ide.hover,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: box,
          height: box,
          child: Icon(icon, size: size, color: onPressed == null ? ide.textDim.withValues(alpha: 0.4) : (color ?? ide.textDim)),
        ),
      ),
    );
  }
}

/// A side bar section title with actions on the right.
class SectionHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final bool? expanded;
  const SectionHeader(this.title, {super.key, this.actions = const [], this.onTap, this.expanded});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return InkWell(
      onTap: onTap,
      hoverColor: ide.hover,
      child: Container(
        height: InputMode.isTouch(context) ? 44 : 26,
        padding: const EdgeInsets.only(left: 6),
        color: ide.tabBar,
        child: Row(children: [
          if (expanded != null) Icon(expanded! ? Icons.expand_more : Icons.chevron_right, size: 16, color: ide.textDim),
          const SizedBox(width: 2),
          Expanded(child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.textDim, letterSpacing: 0.3), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ...actions,
        ]),
      ),
    );
  }
}

/// An icon, a sentence and an optional button, centred.
class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyHint({super.key, required this.icon, required this.text, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 30, color: ide.textDim),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: ide.textDim)),
          if (actionLabel != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ]),
      ),
    );
  }
}

/// A dot in the state's colour.
class StatusDot extends StatelessWidget {
  final Color color;
  final double size;
  const StatusDot(this.color, {super.key, this.size = 8});
  @override
  Widget build(BuildContext context) => Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

Future<bool> confirmDialog(BuildContext context, {required String title, String? body, String ok = '确定', bool danger = false}) async {
  final ide = Ide.of(context);
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Text(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text('取消', style: TextStyle(color: ide.textDim))),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: ide.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

Future<String?> askText(BuildContext context, {required String title, String initial = '', String? hint, String ok = '确定', bool obscure = false}) {
  final c = TextEditingController(text: initial);
  c.selection = TextSelection(baseOffset: 0, extentOffset: initial.contains('.') && initial.lastIndexOf('.') > 0 ? initial.lastIndexOf('.') : initial.length);
  final ide = Ide.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 380, child: TextField(controller: c, autofocus: true, obscureText: obscure, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(ctx, v.trim()))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: ide.textDim))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(ok)),
      ],
    ),
  );
}

/// Copies text and says so.
void copyText(String text, {String what = '已复制'}) {
  Clipboard.setData(ClipboardData(text: text));
  Toast.show(what);
}

String formatSize(num n) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = n.toDouble(), i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '${n.toInt()} B' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${u[i]}';
}

String formatTime(num ms) {
  if (ms == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String relativeTime(num seconds) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000));
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  if (d.inDays < 365) return '${d.inDays ~/ 30} 个月前';
  return '${d.inDays ~/ 365} 年前';
}

/// The mouse buttons a pointer event used (for hit tests in custom widgets).
bool isSecondary(PointerEvent e) => e.buttons == kSecondaryMouseButton;
