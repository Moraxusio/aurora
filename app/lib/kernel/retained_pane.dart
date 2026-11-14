import 'package:flutter/widgets.dart';

/// One lifetime/viewport contract for documents, panels, sidebars and servers.
/// Geometry may change; a mounted child's identity never does. A hidden view
/// retains its last constraints AND MediaQuery, rather than reflowing its text
/// on every window resize/zoom. Flutter still owns layout, hits and semantics.
class RetainedPane extends StatefulWidget {
  final bool visible;
  final Widget child;
  final Key? viewportKey;
  const RetainedPane({
    super.key,
    required this.visible,
    required this.child,
    this.viewportKey,
  });

  @override
  State<RetainedPane> createState() => _RetainedPaneState();
}

class _RetainedPaneState extends State<RetainedPane> {
  MediaQueryData? _media;
  Size? _size;

  @override
  Widget build(BuildContext context) {
    final visible = widget.visible && TickerMode.valuesOf(context).enabled;
    final media = MediaQuery.maybeOf(context);
    if (visible || _media == null) _media = media;
    return LayoutBuilder(
      builder: (_, constraints) {
        if (visible || _size == null) _size = constraints.biggest;
        // Offstage keeps the State but removes paint/hits/semantics. ExcludeFocus
        // and TickerMode complete the contract (Offstage alone does neither).
        Widget body = widget.child;
        if (_media != null) body = MediaQuery(data: _media!, child: body);
        return Offstage(
          offstage: !visible,
          child: TickerMode(
            enabled: visible,
            child: ExcludeFocus(
              excluding: !visible,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: _size!.width,
                maxWidth: _size!.width,
                minHeight: _size!.height,
                maxHeight: _size!.height,
                child: ClipRect(
                  key: widget.viewportKey,
                  child: SizedBox.fromSize(
                    size: _size,
                    child: RepaintBoundary(child: body),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
