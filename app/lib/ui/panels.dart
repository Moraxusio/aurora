import 'aurora_ui.dart';
import '../theme/ide_theme.dart';

/// Actions wrap instead of clipping when a panel is narrow or text is enlarged.
class UiToolbar extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  const UiToolbar({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(Space.m),
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Wrap(
      spacing: Space.m,
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
