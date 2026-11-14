import 'package:flutter/material.dart';

import 'retained_pane.dart';

/// IndexedStack lays out every server/sidebar at the current size. Retaining
/// each hidden page's last constraints avoids reflowing terminal and code
/// buffers in the background while the visible workbench is resized.
class RetainedPages extends StatelessWidget {
  final int index;
  final List<Widget> children;
  const RetainedPages({super.key, required this.index, required this.children});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, box) {
      return Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < children.length; i++)
            Positioned.fill(
              key: ValueKey(children[i].key ?? i),
              child: RetainedPane(visible: i == index, child: children[i]),
            ),
        ],
      );
    },
  );
}
