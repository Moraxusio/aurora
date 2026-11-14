import 'package:flutter/material.dart';

/// IndexedStack lays out every server/sidebar at the current size. Retaining
/// each hidden page's last constraints avoids reflowing terminal and code
/// buffers in the background while the visible workbench is resized.
class RetainedPages extends StatefulWidget {
  final int index;
  final List<Widget> children;
  const RetainedPages({super.key, required this.index, required this.children});
  @override
  State<RetainedPages> createState() => _RetainedPagesState();
}

class _RetainedPagesState extends State<RetainedPages> {
  final _sizes = <Object, Size>{};
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
    final keys = [for (var i = 0; i < widget.children.length; i++) widget.children[i].key ?? i];
    _sizes.removeWhere((key, _) => !keys.contains(key));
    return Stack(fit: StackFit.expand, children: [
      for (var i = 0; i < widget.children.length; i++)
        Positioned.fromRect(key: ValueKey(keys[i]),
          rect: Offset.zero & (i == widget.index ? _sizes[keys[i]] = box.biggest : _sizes.putIfAbsent(keys[i], () => box.biggest)),
          child: Offstage(offstage: i != widget.index,
            child: TickerMode(enabled: i == widget.index,
              child: ExcludeFocus(excluding: i != widget.index, child: widget.children[i])))),
    ]);
  });
}
