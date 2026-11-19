import 'package:aurora/ui/aurora_ui.dart';

import '../../theme/ide_theme.dart';

/// Shared visual vocabulary for conversations, work, history and AI settings.
abstract final class AiVisuals {
  static const radius = UiMetrics.surfaceCorners;
  static const controlRadius = UiMetrics.controlCorners;

  static BoxDecoration surface(
    Ide ide, {
    bool selected = false,
    bool elevated = false,
    Color? edge,
    Color? fill,
  }) => BoxDecoration(
    color: fill ?? (selected ? ide.accentSoft : ide.surface),
    borderRadius: radius,
    border: Border.all(
      color:
          edge ??
          (selected
              ? ide.accent.withValues(alpha: 0.45)
              : ide.border.withValues(alpha: 0.85)),
    ),
    boxShadow: elevated ? ide.float : null,
  );

  static BoxDecoration badge(Ide ide, Color color, {double alpha = 0.12}) =>
      BoxDecoration(
        color: color.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(UiMetrics.controlRadius),
        border: Border.all(color: color.withValues(alpha: alpha * 1.8)),
      );
}

/// Tactile PC desktop pill button with smooth hover & focus transitions.
class AiPillButton extends StatefulWidget {
  final IconData? icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool highlighted;
  final Color? accent;
  final bool compact;
  final Widget? trailing;

  const AiPillButton({
    super.key,
    this.icon,
    required this.label,
    this.tooltip,
    this.onTap,
    this.highlighted = false,
    this.accent,
    this.compact = false,
    this.trailing,
  });

  @override
  State<AiPillButton> createState() => _AiPillButtonState();
}

class _AiPillButtonState extends State<AiPillButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final tone = widget.accent ?? ide.accent;
    final bg = widget.highlighted
        ? tone.withValues(alpha: _hovered ? 0.18 : 0.12)
        : _hovered
        ? ide.hover
        : ide.input.withValues(alpha: 0.65);
    final fg = widget.highlighted ? tone : ide.textDim;
    final border = widget.highlighted
        ? tone.withValues(alpha: _hovered ? 0.55 : 0.35)
        : (_hovered ? ide.borderStrong : ide.border.withValues(alpha: 0.75));

    final child = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(UiMetrics.controlRadius),
        child: AnimatedContainer(
          duration: UiMotion.hover,
          curve: UiMotion.enterCurve,
          height: widget.compact ? 24 : 26,
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 7 : 9,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(UiMetrics.controlRadius),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 13.5, color: fg),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: widget.highlighted
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: widget.highlighted ? tone : ide.text,
                  ),
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 4),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? child
        : Tooltip(message: widget.tooltip!, child: child);
  }
}

/// Crisp segmented selector for PC desktop toolbars and settings.
class AiSegmentedTabs<T> extends StatelessWidget {
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  const AiSegmentedTabs({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ide.input.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(UiMetrics.controlRadius + 2),
        border: Border.all(color: ide.border.withValues(alpha: 0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in items.entries)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(entry.key),
                child: AnimatedContainer(
                  duration: UiMotion.hover,
                  curve: UiMotion.enterCurve,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: entry.key == value ? ide.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(UiMetrics.controlRadius),
                    border: entry.key == value
                        ? Border.all(color: ide.borderStrong.withValues(alpha: 0.6))
                        : null,
                    boxShadow: entry.key == value
                        ? [
                            BoxShadow(
                              color: ide.shadow.withValues(alpha: 0.12),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    entry.value,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: entry.key == value
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: entry.key == value ? ide.text : ide.textDim,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One page selector instead of a wall of icons/chips. Narrow dialogs keep the
/// current location visible and expose every page without horizontal scrolling.
class AiPageNavigation extends StatelessWidget {
  final Map<String, String> pages;
  final String selected, keyPrefix;
  final ValueChanged<String> onSelected;
  const AiPageNavigation({
    super.key,
    required this.pages,
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
  });
  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: const InputDecoration(labelText: '设置页面'),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: ValueKey('$keyPrefix-selector'),
        value: selected,
        isExpanded: true,
        selectedItemBuilder: (_) => [
          for (final page in pages.values)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(page, overflow: TextOverflow.ellipsis),
            ),
        ],
        items: [
          for (final page in pages.entries)
            DropdownMenuItem(
              value: page.key,
              child: Text(page.value, key: ValueKey('$keyPrefix-${page.key}')),
            ),
        ],
        onChanged: (v) {
          if (v != null) onSelected(v);
        },
      ),
    ),
  );
}

class AiSectionHeading extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const AiSectionHeading({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: AiVisuals.badge(ide, ide.accent, alpha: 0.12),
            child: Icon(icon, size: 15, color: ide.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ide.text,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: ide.textDim,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

enum AiWorkStatus { running, completed, stopped, error, interrupted }

class AiStatusMark extends StatelessWidget {
  final AiWorkStatus status;
  final bool label;
  const AiStatusMark(this.status, {super.key, this.label = true});
  static String text(AiWorkStatus status) => switch (status) {
    AiWorkStatus.running => '运行中',
    AiWorkStatus.completed => '已完成',
    AiWorkStatus.stopped => '已停止',
    AiWorkStatus.error => '失败',
    AiWorkStatus.interrupted => '未确认',
  };
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final color = switch (status) {
      AiWorkStatus.running => ide.accent,
      AiWorkStatus.completed => ide.ok,
      AiWorkStatus.stopped => ide.textDim,
      AiWorkStatus.error => ide.error,
      AiWorkStatus.interrupted => ide.warn,
    };
    return Container(
      padding: label
          ? const EdgeInsets.symmetric(horizontal: 7, vertical: 2)
          : EdgeInsets.zero,
      decoration: label ? AiVisuals.badge(ide, color, alpha: 0.10) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            switch (status) {
              AiWorkStatus.running => Icons.bolt_rounded,
              AiWorkStatus.completed => Icons.check_circle_outline_rounded,
              AiWorkStatus.stopped => Icons.stop_circle_outlined,
              AiWorkStatus.error => Icons.error_outline_rounded,
              AiWorkStatus.interrupted => Icons.pause_circle_outline_rounded,
            },
            size: 13,
            color: color,
          ),
          if (label) ...[
            const SizedBox(width: 4),
            Text(
              text(status),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
