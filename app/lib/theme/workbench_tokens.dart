import 'package:flutter/material.dart';

/// Geometry and motion are shared by every feature. Colours remain in Ide.
abstract final class UiMetrics {
  static const controlRadius = 4.0, surfaceRadius = 6.0;
  static const menuRow = 32.0, touchRow = 44.0, menuIcon = 16.0;
  static const menuMinWidth = 200.0, menuMaxWidth = 360.0;
  static const screenInset = 8.0, anchorGap = 4.0;
  static const menuPadding = EdgeInsets.all(4);
  static const surfaceBorderOpacity = .75;
  static const menuElevation = 8.0, dialogElevation = 12.0;
  static const surfaceCorners = BorderRadius.all(
    Radius.circular(surfaceRadius),
  );
  static const controlCorners = BorderRadius.all(
    Radius.circular(controlRadius),
  );
}

abstract final class UiMotion {
  static const feedback = Duration(milliseconds: 100);
  static const menuEnter = Duration(milliseconds: 140);
  static const menuExit = Duration(milliseconds: 90);
  static const dialogEnter = Duration(milliseconds: 180);
  static const dialogExit = Duration(milliseconds: 120);
  static const tooltipWait = Duration(milliseconds: 450);
  static const enterCurve = Curves.easeOutCubic;
  static const exitCurve = Curves.easeInCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);

  static AnimationStyle dialog(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: dialogEnter,
          reverseDuration: dialogExit,
          curve: enterCurve,
          reverseCurve: exitCurve,
        );

  static AnimationStyle notification(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: dialogEnter,
          reverseDuration: dialogExit,
        );
}
