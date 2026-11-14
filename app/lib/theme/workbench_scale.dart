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
    final media = MediaQuery.of(context);
    // The viewport owns hit testing; its child owns the unscaled layout size.
    // Transform + OverflowBox paints outside the latter's hit-test bounds when
    // zooming out, leaving the visible right/bottom of the app unclickable.
    // FittedBox shares one transform for painting, hits, semantics and overlays.
    return FittedBox(
      fit: BoxFit.fill, alignment: Alignment.topLeft, clipBehavior: Clip.hardEdge,
      child: SizedBox(width: size.width, height: size.height,
        child: MediaQuery(data: media.copyWith(
          size: size,
          devicePixelRatio: media.devicePixelRatio * scale,
          padding: media.padding / scale,
          viewPadding: media.viewPadding / scale,
          viewInsets: media.viewInsets / scale,
          systemGestureInsets: media.systemGestureInsets / scale,
        ), child: child),
      ),
    );
  });
}
