import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ide_theme.dart';
import '../theme/workbench_tokens.dart';
import 'input_mode.dart';

/// One modal entry point keeps motion, focus traversal and reduced-motion policy
/// consistent. Barrier dismissal and PopScope stay owned by the calling feature.
Future<T?> showWorkbenchDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) async {
  Tooltip.dismissAllToolTips();
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = _WorkbenchDialogRoute<T>(
    context: context,
    builder: builder,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierDismissible: barrierDismissible,
    barrierColor:
        barrierColor ?? DialogTheme.of(context).barrierColor ?? Colors.black54,
    reduced: UiMotion.reduced(context),
  );
  final result = await navigator.push<T>(route);
  await route.completed;
  return result;
}

class _WorkbenchDialogRoute<T> extends DialogRoute<T> {
  final bool reduced;
  _WorkbenchDialogRoute({
    required super.context,
    required super.builder,
    required super.themes,
    required super.barrierDismissible,
    required super.barrierColor,
    required this.reduced,
  }) : super(
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         animationStyle: reduced
             ? AnimationStyle.noAnimation
             : const AnimationStyle(
                 duration: UiMotion.dialogEnter,
                 curve: UiMotion.enterCurve,
                 reverseCurve: UiMotion.exitCurve,
               ),
       );
  // Flutter's DialogRoute currently ignores AnimationStyle.reverseDuration.
  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : UiMotion.dialogExit;
}

/// The same surface for pickers and nonmodal floating panels.
class FloatingSurface extends StatelessWidget {
  final Widget child;
  final BoxConstraints? constraints;
  const FloatingSurface({super.key, required this.child, this.constraints});
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      constraints: constraints,
      decoration: BoxDecoration(
        borderRadius: UiMetrics.surfaceCorners,
        boxShadow: ide.float,
      ),
      child: Material(
        color: ide.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: UiMetrics.surfaceCorners,
          side: BorderSide(
            color: ide.borderStrong.withValues(
              alpha: UiMetrics.surfaceBorderOpacity,
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// A fixed glyph column, flexible title and a separate shortcut column.
class MenuLabel extends StatelessWidget {
  final String label;
  final IconData? icon;
  final String? shortcut;
  final bool danger;
  const MenuLabel(
    this.label, {
    super.key,
    this.icon,
    this.shortcut,
    this.danger = false,
  });
  @override
  Widget build(BuildContext context) => _MenuLabelBody(
    label: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
    icon: icon,
    shortcut: shortcut,
  );
}

class _MenuLabelBody extends StatelessWidget {
  final Widget label;
  final IconData? icon;
  final String? shortcut;
  const _MenuLabelBody({required this.label, this.icon, this.shortcut});
  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color;
    return Row(
      children: [
        SizedBox(
          width: 20,
          child: icon == null
              ? null
              : Icon(icon, size: UiMetrics.menuIcon, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: label),
        if (shortcut != null) ...[
          const SizedBox(width: 20),
          Flexible(
            flex: 2,
            child: Text(
              shortcut!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: color?.withValues(alpha: .75),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Shared button API; feature entries remain ordinary Flutter menu descriptors.
class WorkbenchMenuButton<T> extends StatefulWidget {
  final PopupMenuItemBuilder<T> itemBuilder;
  final ValueChanged<T>? onSelected;
  final VoidCallback? onCanceled;
  final String? tooltip;
  final Widget? child, icon;
  final EdgeInsetsGeometry padding;
  final bool enabled;
  const WorkbenchMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.onCanceled,
    this.tooltip,
    this.child,
    this.icon,
    this.padding = EdgeInsets.zero,
    this.enabled = true,
  });
  @override
  State<WorkbenchMenuButton<T>> createState() => _WorkbenchMenuButtonState<T>();
}

class _WorkbenchMenuButtonState<T> extends State<WorkbenchMenuButton<T>> {
  bool _open = false;
  Future<void> _show() async {
    if (_open || !widget.enabled) return;
    final items = widget.itemBuilder(context);
    if (items.isEmpty) return;
    setState(() => _open = true);
    try {
      final picked = await showWorkbenchMenu<T>(
        context: context,
        items: items,
        anchor: context,
      );
      if (!mounted) return;
      if (picked != null) {
        widget.onSelected?.call(picked);
      } else {
        widget.onCanceled?.call();
      }
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final body =
        widget.child ??
        SizedBox(
          width: InputMode.isTouch(context) ? UiMetrics.touchRow : 28,
          height: InputMode.isTouch(context) ? UiMetrics.touchRow : 28,
          child: Center(
            child: widget.icon ?? const Icon(Icons.more_vert, size: 17),
          ),
        );
    return Tooltip(
      message:
          widget.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
      child: Semantics(
        button: true,
        expanded: _open,
        enabled: widget.enabled,
        child: Material(
          color: _open ? ide.hover : Colors.transparent,
          borderRadius: UiMetrics.controlCorners,
          child: InkWell(
            onTap: widget.enabled ? _show : null,
            borderRadius: UiMetrics.controlCorners,
            child: Padding(padding: widget.padding, child: body),
          ),
        ),
      ),
    );
  }
}

/// Anchors are converted in the navigator overlay's coordinate system, including
/// workbench zoom. A button anchor is remeasured after window size/DPI changes.
Future<T?> showWorkbenchMenu<T>({
  required BuildContext context,
  required List<PopupMenuEntry<T>> items,
  BuildContext? anchor,
  Offset? at,
}) async {
  if (items.isEmpty) return null;
  Tooltip.dismissAllToolTips();
  assert(anchor != null || at != null);
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  var lastPosition = overlay.globalToLocal(at ?? Offset.zero) & Size.zero;
  Rect position() {
    if (anchor != null && anchor.mounted) {
      final box = anchor.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        return lastPosition = Rect.fromPoints(
          overlay.globalToLocal(box.localToGlobal(Offset.zero)),
          overlay.globalToLocal(
            box.localToGlobal(box.size.bottomRight(Offset.zero)),
          ),
        );
      }
    }
    return anchor != null
        ? lastPosition
        : overlay.globalToLocal(at!) & Size.zero;
  }

  final route = _WorkbenchMenuRoute<T>(
    items: items,
    position: position,
    anchored: anchor != null,
    touch: InputMode.isTouch(context),
    reduced: UiMotion.reduced(context),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    label: MaterialLocalizations.of(context).popupMenuLabel,
    dismissLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  );
  final result = await navigator.push<T>(route);
  // A follow-up dialog/menu opens after this surface has actually disappeared.
  await route.completed;
  if (context.mounted) route.onPicked?.call();
  return result;
}

class _WorkbenchMenuRoute<T> extends PopupRoute<T> {
  final List<PopupMenuEntry<T>> items;
  final Rect Function() position;
  final bool anchored, touch, reduced;
  final CapturedThemes themes;
  final String label, dismissLabel;
  VoidCallback? onPicked;
  void select(PopupMenuItem<T> item) {
    if (!isCurrent || !item.enabled) return;
    onPicked = item.onTap;
    navigator!.pop<T>(item.value);
  }

  _WorkbenchMenuRoute({
    required this.items,
    required this.position,
    required this.anchored,
    required this.touch,
    required this.reduced,
    required this.themes,
    required this.label,
    required this.dismissLabel,
  }) : super(
         requestFocus: true,
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
       );
  @override
  Duration get transitionDuration =>
      reduced ? Duration.zero : UiMotion.menuEnter;
  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : UiMotion.menuExit;
  @override
  bool get barrierDismissible => true;
  @override
  Color? get barrierColor => null;
  @override
  String get barrierLabel => dismissLabel;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final first = items.indexWhere(
      (item) => item is PopupMenuItem<T> && item.enabled,
    );
    final checks = items.any((item) => item is CheckedPopupMenuItem<T>);
    final menu = FloatingSurface(
      child: IntrinsicWidth(
        child: SingleChildScrollView(
          padding: UiMetrics.menuPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < items.length; i++)
                if (items[i] is PopupMenuDivider)
                  const Divider(height: 9, indent: 8, endIndent: 8)
                else if (items[i] case final PopupMenuItem<T> item)
                  WorkbenchMenuEntry<T>(
                    item: item,
                    autofocus: i == first,
                    touch: touch,
                    checkColumn: checks,
                  )
                else
                  items[i],
            ],
          ),
        ),
      ),
    );
    return themes.wrap(
      Semantics(
        role: SemanticsRole.menu,
        scopesRoute: true,
        namesRoute: true,
        label: label,
        explicitChildNodes: true,
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
          },
          child: LayoutBuilder(
            builder: (_, _) => CustomSingleChildLayout(
              delegate: _MenuPlacement(
                position(),
                anchored,
                media.padding +
                    EdgeInsets.only(bottom: media.viewInsets.bottom),
                Directionality.of(context),
              ),
              child: _MenuTransition(
                animation: animation,
                reduced: reduced || UiMotion.reduced(context),
                child: menu,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuTransition extends StatefulWidget {
  final Animation<double> animation;
  final bool reduced;
  final Widget child;
  const _MenuTransition({
    required this.animation,
    required this.reduced,
    required this.child,
  });
  @override
  State<_MenuTransition> createState() => _MenuTransitionState();
}

class _MenuTransitionState extends State<_MenuTransition> {
  late CurvedAnimation curve;
  void _attach() => curve = CurvedAnimation(
    parent: widget.animation,
    curve: UiMotion.enterCurve,
    reverseCurve: UiMotion.exitCurve,
  );
  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(_MenuTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      curve.dispose();
      _attach();
    }
  }

  @override
  void dispose() {
    curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.reduced
      ? widget.child
      : AnimatedBuilder(
          animation: curve,
          child: widget.child,
          builder: (_, child) {
            final value = curve.value;
            return Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 3),
                child: child,
              ),
            );
          },
        );
}

/// Shared rendering removes ListTile's extra height/indent from checked entries.
class WorkbenchMenuEntry<T> extends StatelessWidget {
  final PopupMenuItem<T> item;
  final bool autofocus, touch, checkColumn;
  const WorkbenchMenuEntry({
    super.key,
    required this.item,
    required this.autofocus,
    required this.touch,
    required this.checkColumn,
  });
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final checked = item is CheckedPopupMenuItem<T>
        ? (item as CheckedPopupMenuItem<T>).checked
        : null;
    final label = item.child;
    final danger = label is MenuLabel && label.danger;
    final color = !item.enabled
        ? ide.textFaint
        : danger
        ? ide.error
        : ide.text;
    Widget body = label ?? const SizedBox.shrink();
    if (label is MenuLabel) {
      body = _MenuLabelBody(
        label: Text(label.label, maxLines: 2, overflow: TextOverflow.ellipsis),
        icon: checked == true ? Icons.check_rounded : label.icon,
        shortcut: label.shortcut,
      );
    } else if (checkColumn || label is Text) {
      body = _MenuLabelBody(
        label: body,
        icon: checked == true ? Icons.check_rounded : null,
      );
    }
    return Semantics(
      role: checked == null
          ? SemanticsRole.menuItem
          : SemanticsRole.menuItemCheckbox,
      checked: checked,
      enabled: item.enabled,
      button: true,
      child: InkWell(
        autofocus: autofocus,
        canRequestFocus: item.enabled,
        borderRadius: UiMetrics.controlCorners,
        onTap: item.enabled
            ? () {
                (ModalRoute.of(context)! as _WorkbenchMenuRoute<T>).select(
                  item,
                );
              }
            : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: touch ? UiMetrics.touchRow : UiMetrics.menuRow,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: DefaultTextStyle(
              style: TextStyle(
                fontFamily: Ide.ui,
                fontFamilyFallback: Ide.uiFallback,
                fontSize: 13,
                height: 1.35,
                color: color,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              child: IconTheme(
                data: IconThemeData(size: UiMetrics.menuIcon, color: color),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: body,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuPlacement extends SingleChildLayoutDelegate {
  final Rect anchor;
  final bool anchored;
  final EdgeInsets padding;
  final TextDirection direction;
  _MenuPlacement(this.anchor, this.anchored, this.padding, this.direction);
  Rect _usable(Size size) => Rect.fromLTRB(
    UiMetrics.screenInset + padding.left,
    UiMetrics.screenInset + padding.top,
    math.max(
      UiMetrics.screenInset + padding.left,
      size.width - UiMetrics.screenInset - padding.right,
    ),
    math.max(
      UiMetrics.screenInset + padding.top,
      size.height - UiMetrics.screenInset - padding.bottom,
    ),
  );
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final bounds = _usable(constraints.biggest);
    final width = math.min(UiMetrics.menuMaxWidth, bounds.width);
    return BoxConstraints(
      minWidth: math.min(UiMetrics.menuMinWidth, width),
      maxWidth: width,
      maxHeight: bounds.height,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = _usable(size);
    final right =
        anchor.center.dx > size.width / 2 ||
        (anchor.center.dx == size.width / 2 && direction == TextDirection.rtl);
    var x = right ? anchor.right - childSize.width : anchor.left;
    var y = anchored ? anchor.bottom + UiMetrics.anchorGap : anchor.top;
    if (anchored &&
        y + childSize.height > bounds.bottom &&
        anchor.top - UiMetrics.anchorGap - childSize.height >= bounds.top) {
      y = anchor.top - UiMetrics.anchorGap - childSize.height;
    }
    x = x.clamp(
      bounds.left,
      math.max(bounds.left, bounds.right - childSize.width),
    );
    y = y.clamp(
      bounds.top,
      math.max(bounds.top, bounds.bottom - childSize.height),
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuPlacement old) =>
      anchor != old.anchor ||
      padding != old.padding ||
      anchored != old.anchored ||
      direction != old.direction;
}
