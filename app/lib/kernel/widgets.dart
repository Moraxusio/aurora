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
      margin: EdgeInsets.fromLTRB(side, 0, side, narrow ? 100 : 40),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      duration: Duration(seconds: error ? 8 : 3),
      content: Builder(builder: (context) {
        final ide = Ide.of(context);
        return Row(children: [
          Icon(error ? Icons.error_rounded : Icons.check_circle_rounded, size: 18, color: error ? ide.error : ide.ok),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(msg, style: TextStyle(color: ide.text, fontSize: 13))),
        ]);
      }),
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
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              SizedBox(width: 22, child: items[i].icon == null ? null : Icon(items[i].icon, size: 16, color: items[i].danger ? ide.error : ide.textDim)),
              const SizedBox(width: 6),
              Expanded(child: Text(items[i].label, style: TextStyle(fontSize: 13, color: items[i].danger ? ide.error : ide.text))),
              if (items[i].hint != null) ...[const SizedBox(width: 16), Text(items[i].hint!, style: TextStyle(color: ide.textFaint, fontSize: 11.5))],
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
      decoration: selected ? BoxDecoration(color: ide.selection, borderRadius: BorderRadius.circular(Radii.m)) : null,
      padding: EdgeInsets.only(left: 6.0 + depth * 14, right: 4, top: subtitle == null ? 0 : 3, bottom: subtitle == null ? 0 : 3),
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
    row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        borderRadius: BorderRadius.circular(Radii.m),
        hoverColor: selected ? Colors.transparent : ide.hover,
        child: row,
      ),
    );
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
        borderRadius: BorderRadius.circular(Radii.m),
        child: SizedBox(
          width: box,
          height: box,
          child: Icon(icon, size: size, color: onPressed == null ? ide.textFaint.withValues(alpha: 0.6) : (color ?? ide.textDim)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, 2, Space.xs, 0),
      child: InkWell(
        onTap: onTap,
        hoverColor: onTap == null ? Colors.transparent : ide.hover,
        borderRadius: BorderRadius.circular(Radii.m),
        child: Container(
          height: InputMode.isTouch(context) ? 44 : 28,
          padding: EdgeInsets.only(left: expanded == null ? 8 : 2),
          child: Row(children: [
            if (expanded != null)
              AnimatedRotation(
                turns: expanded! ? 0.25 : 0,
                duration: const Duration(milliseconds: 120),
                child: Icon(Icons.chevron_right_rounded, size: 16, color: ide.textFaint),
              ),
            const SizedBox(width: 3),
            Expanded(child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ide.textDim, letterSpacing: 0.2), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ...actions,
          ]),
        ),
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
        padding: const EdgeInsets.all(Space.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: ide.hover, borderRadius: BorderRadius.circular(Radii.island)),
              child: Icon(icon, size: 22, color: ide.textDim),
            ),
            const SizedBox(height: Space.l),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: ide.textDim, fontSize: 12.5, height: 1.5)),
            if (actionLabel != null) ...[
              const SizedBox(height: Space.l),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Opens a floating picker (the command palette, quick open) near the top of
/// the window.
Future<T?> showPicker<T>(BuildContext context, {required WidgetBuilder builder, double maxWidth = 620, double maxHeight = 460}) {
  final dark = Ide.of(context).isDark;
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: dark ? 0.38 : 0.14),
    builder: (c) {
      final ide = Ide.of(c);
      return Align(
        alignment: const Alignment(0, -0.62),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xl),
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: ide.surface,
              borderRadius: BorderRadius.circular(Radii.dialog),
              border: Border.all(color: ide.borderStrong.withValues(alpha: 0.7)),
              boxShadow: ide.float,
            ),
            child: Material(type: MaterialType.transparency, child: builder(c)),
          ),
        ),
      );
    },
  );
}

/// The search line at the top of a picker: no box, a larger font.
class PickerField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final IconData icon;
  final ValueChanged<String>? onSubmitted;
  const PickerField({super.key, required this.controller, required this.hint, required this.icon, this.focusNode, this.onSubmitted});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    const none = InputBorder.none;
    return SizedBox(
      height: 50,
      child: Row(children: [
        const SizedBox(width: Space.xl),
        Icon(icon, size: 18, color: ide.textDim),
        const SizedBox(width: Space.l),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            style: TextStyle(fontSize: 14.5, color: ide.text),
            decoration: InputDecoration(hintText: hint, filled: false, isCollapsed: true, border: none, enabledBorder: none, focusedBorder: none),
            onSubmitted: onSubmitted,
          ),
        ),
        const SizedBox(width: Space.xl),
      ]),
    );
  }
}

/// One row of a picker, [height] high; the chosen one is highlighted.
class PickerRow extends StatelessWidget {
  static const double height = 34;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  const PickerRow({super.key, required this.selected, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.s),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.m),
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: Space.m + 2),
          decoration: selected ? BoxDecoration(color: ide.selection, borderRadius: BorderRadius.circular(Radii.m)) : null,
          child: child,
        ),
      ),
    );
  }
}

/// Keeps row [index] of a list of [PickerRow]s in view.
void revealPickerRow(ScrollController c, int index, {double pad = Space.s}) {
  if (!c.hasClients) return;
  final p = c.position;
  final top = pad + index * PickerRow.height;
  if (top < p.pixels) {
    c.jumpTo((top - pad).clamp(0, p.maxScrollExtent));
  } else if (top + PickerRow.height > p.pixels + p.viewportDimension) {
    c.jumpTo((top + PickerRow.height + pad - p.viewportDimension).clamp(0, p.maxScrollExtent));
  }
}

/// A keyboard shortcut drawn as key caps: "Ctrl+Shift+P".
class KeyCaps extends StatelessWidget {
  final String keys;
  const KeyCaps(this.keys, {super.key});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final k in keys.split('+'))
        Container(
          margin: const EdgeInsets.only(left: 3),
          padding: const EdgeInsets.symmetric(horizontal: 5),
          constraints: const BoxConstraints(minWidth: 18),
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ide.input,
            borderRadius: BorderRadius.circular(Radii.s),
            border: Border.all(color: ide.border),
            boxShadow: [BoxShadow(color: ide.borderStrong, offset: const Offset(0, 1))],
          ),
          child: Text(k, style: TextStyle(fontSize: 10.5, color: ide.textDim, height: 1.1, fontWeight: FontWeight.w500)),
        ),
    ]);
  }
}

/// A page of settings-style panels (the overview, the settings page): a
/// title, then [children] up to [maxWidth] wide.
class FormPage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> children;
  final double maxWidth;
  const FormPage({super.key, required this.title, this.subtitle, this.leading, required this.children, this.maxWidth = 760});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xxl + 4, Space.xxl, Space.xxl * 2), children: [
          Row(children: [
            if (leading != null) ...[leading!, const SizedBox(width: Space.l + 2)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: TextStyle(color: ide.textDim, fontSize: 12.5)),
                ],
              ]),
            ),
          ]),
          const SizedBox(height: Space.xl),
          ...children,
        ]),
      ),
    );
  }
}

/// A titled group of [FormRow]s in one rounded panel.
class FormSection extends StatelessWidget {
  final String title;
  final String? note;
  final List<Widget> children;
  final bool danger;
  const FormSection({super.key, required this.title, this.note, required this.children, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Divider(height: 1, indent: Space.l + 2, endIndent: Space.l + 2, color: ide.border));
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(top: Space.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: Space.m),
          child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: danger ? ide.error : ide.text)),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: Space.m + 2, right: Space.xl),
            child: Text(note!, style: TextStyle(fontSize: 12, color: ide.textFaint, height: 1.5)),
          ),
        Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ide.sideBar,
            borderRadius: BorderRadius.circular(Radii.island),
            border: Border.all(color: danger ? ide.error.withValues(alpha: 0.35) : ide.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ),
      ]),
    );
  }
}

/// One row of a [FormSection]: a title, an optional line under it, and a
/// control (or a value) on the right.
class FormRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final IconData? icon;
  final VoidCallback? onTap;

  /// The value is text that can be selected (a fingerprint, an address).
  final String? value;
  const FormRow({super.key, required this.title, this.subtitle, this.subtitleColor, this.trailing, this.icon, this.onTap, this.value});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.l + 2, vertical: Space.m + 3),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 17, color: ide.textDim), const SizedBox(width: Space.l)],
        Expanded(
          flex: value == null ? 1 : 0,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: value == null ? 0 : 120),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 13, color: value == null ? ide.text : ide.textDim)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: TextStyle(fontSize: 12, color: subtitleColor ?? ide.textFaint, height: 1.4)),
              ],
            ]),
          ),
        ),
        if (value != null) ...[
          const SizedBox(width: Space.xl),
          Expanded(child: SelectableText(value!, textAlign: TextAlign.right, style: TextStyle(fontSize: 12.5, color: ide.text))),
        ],
        if (trailing != null) ...[const SizedBox(width: Space.l), trailing!],
      ]),
    );
    if (onTap != null) row = InkWell(onTap: onTap, child: row);
    return row;
  }
}

/// A switch sized for dense rows.
class SmallSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;
  const SmallSwitch({super.key, required this.value, required this.onChanged, this.switchKey});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 24,
        child: FittedBox(fit: BoxFit.contain, child: Switch(key: switchKey, value: value, onChanged: onChanged)),
      );
}

enum Tone { info, ok, warn, error }

/// A tinted banner: an icon, a title, and an optional body or action.
class Notice extends StatelessWidget {
  final Tone tone;
  final String title;
  final String? body;
  final Widget? action;
  final IconData? icon;
  const Notice({super.key, required this.tone, required this.title, this.body, this.action, this.icon});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final (color, glyph) = switch (tone) {
      Tone.info => (ide.accent, Icons.info_outline_rounded),
      Tone.ok => (ide.ok, Icons.check_circle_outline_rounded),
      Tone.warn => (ide.warn, Icons.warning_amber_rounded),
      Tone.error => (ide.error, Icons.error_outline_rounded),
    };
    return Container(
      padding: const EdgeInsets.all(Space.l),
      decoration: BoxDecoration(
        color: color.withValues(alpha: ide.isDark ? 0.1 : 0.07),
        borderRadius: BorderRadius.circular(Radii.l + 2),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon ?? glyph, size: 18, color: color)),
        const SizedBox(width: Space.m + 2),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.text)),
            if (body != null && body!.isNotEmpty) ...[
              const SizedBox(height: 3),
              SelectableText(body!, style: TextStyle(fontSize: 12.5, color: ide.textDim, height: 1.5)),
            ],
          ]),
        ),
        if (action != null) ...[const SizedBox(width: Space.m), action!],
      ]),
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
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text('取消', style: TextStyle(color: ide.text))),
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
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: ide.text))),
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
