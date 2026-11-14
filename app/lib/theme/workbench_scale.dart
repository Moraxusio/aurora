import 'package:flutter/material.dart';

/// Scale the whole logical workbench (including pointer coordinates), rather
/// than enlarging labels inside fixed-height controls. Kept at the same tree
/// location even at 100%, so zoom never recreates editors or their controllers.
class WorkbenchScale extends StatelessWidget {
  final double scale;
  final Widget child;
  const WorkbenchScale({super.key, required this.scale, required this.child});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final size = box.biggest / scale;
    return ClipRect(child: Transform.scale(
      scale: scale, alignment: Alignment.topLeft,
      child: OverflowBox(alignment: Alignment.topLeft,
        minWidth: size.width, maxWidth: size.width,
        minHeight: size.height, maxHeight: size.height,
        child: MediaQuery(data: MediaQuery.of(context).copyWith(size: size), child: child),
      ),
    ));
  });
}
