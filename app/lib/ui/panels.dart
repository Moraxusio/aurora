import 'aurora_ui.dart';
import '../theme/ide_theme.dart';
import '../kernel/input_mode.dart';

/// One hierarchy for workbench tools, including narrow and enlarged layouts.
class UiPanelHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> actions;
  const UiPanelHeader({super.key, required this.title, this.subtitle, this.icon, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.m, Space.m),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ide.border))),
      child: LayoutBuilder(builder: (context, box) {
        final heading = Row(children: [
          if (icon != null) ...[Icon(icon, size: 17, color: ide.accent), const SizedBox(width: Space.m)],
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(header: true, child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: ide.text, fontSize: 13, fontWeight: FontWeight.w600))),
            if (subtitle != null) Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: ide.textDim, fontSize: 11.5)),
          ])),
        ]);
        if (actions.isEmpty) return heading;
        if (box.maxWidth < 180 + actions.length * InputMode.row(context)) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            heading, Wrap(alignment: WrapAlignment.end, children: actions),
          ]);
        }
        return Row(children: [Expanded(child: heading), ...actions]);
      }),
    );
  }
}

/// A labelled, keyboard-focusable destination. Labels remain visible even
/// when unselected, so discovering a tool never requires hovering every icon.
class UiNavigationItem extends StatelessWidget {
  final IconData icon;
  final String label, tooltip;
  final bool selected, dim;
  final VoidCallback onTap;
  const UiNavigationItem({super.key, required this.icon, required this.label,
    required this.tooltip, required this.onTap, this.selected = false, this.dim = false});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final color = selected ? ide.accent : dim ? ide.textFaint : ide.textDim;
    return Tooltip(message: tooltip, child: Semantics(button: true, selected: selected,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 2),
        child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(Radii.m),
          focusColor: ide.selection, hoverColor: ide.hover,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52, minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: Space.s),
            decoration: BoxDecoration(color: selected ? ide.accentSoft : null,
              borderRadius: BorderRadius.circular(Radii.m),
              border: Border.all(color: selected ? ide.accent.withValues(alpha: .3) : Colors.transparent)),
            child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: Space.xs),
              Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, height: 1.2, color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
            ]),
          ),
        ),
      ),
    ));
  }
}

/// Actions wrap instead of clipping when a panel is narrow or text is enlarged.
class UiToolbar extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final double spacing;
  const UiToolbar({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(Space.m),
    this.spacing = Space.m,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Wrap(
      spacing: spacing,
      runSpacing: Space.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    ),
  );
}

/// A bounded, scrollable tool panel. Header and body share one scroll surface
/// so even a very short panel still exposes every action.
class UiPanel extends StatelessWidget {
  final String title;
  final String? description;
  final List<Widget> actions, slivers;
  final Widget? notice;
  const UiPanel({
    super.key,
    required this.title,
    this.description,
    this.actions = const [],
    this.slivers = const [],
    this.notice,
  });
  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (description != null)
                Text(
                  description!,
                  style: TextStyle(color: Ide.of(context).textDim),
                ),
              if (actions.isNotEmpty)
                UiToolbar(
                  padding: const EdgeInsets.only(top: Space.m),
                  children: actions,
                ),
              if (notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.m),
                  child: notice,
                ),
            ],
          ),
        ),
      ),
      ...slivers,
    ],
  );
}

class UiVirtualList extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;

  /// Supply a fixed extent (or a representative prototype) for bounded
  /// random-access scrolling; variable-height lists must measure skipped rows.
  final double? itemExtent;
  final Widget? prototypeItem;
  const UiVirtualList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.itemExtent,
    this.prototypeItem,
  }) : assert(itemExtent == null || prototypeItem == null);
  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: controller,
    itemCount: itemCount,
    itemBuilder: itemBuilder,
    padding: padding,
    itemExtent: itemExtent,
    prototypeItem: prototypeItem,
    semanticChildCount: itemCount,
  );
}
