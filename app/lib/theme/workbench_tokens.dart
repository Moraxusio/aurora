import 'package:flutter/material.dart';

/// Geometry and motion are shared by every feature. Colours remain in Ide.
abstract final class UiMetrics {
  static const compactRow = 28.0, controlHeight = 32.0;
  static const labelGap = 6.0, dialogInset = 14.0;
  static const controlRadius = 6.0, surfaceRadius = 10.0, pillRadius = 999.0;
  static const menuRow = 32.0, touchRow = 44.0, menuIcon = 16.0;
  static const menuMinWidth = 208.0, menuMaxWidth = 360.0;
  static const screenInset = 8.0, anchorGap = 4.0;
  static const menuPadding = EdgeInsets.all(5);
  static const surfaceBorderOpacity = .72;
  static const menuElevation = 10.0, dialogElevation = 16.0;
  static const surfaceCorners = BorderRadius.all(
    Radius.circular(surfaceRadius),
  );
  static const controlCorners = BorderRadius.all(
    Radius.circular(controlRadius),
  );
}

abstract final class UiMotion {
  static const hover = Duration(milliseconds: 110);
  static const feedback = Duration(milliseconds: 120);
  static const expand = Duration(milliseconds: 180);
  static const menuEnter = Duration(milliseconds: 150);
  static const menuExit = Duration(milliseconds: 100);
  static const dialogEnter = Duration(milliseconds: 200);
  static const dialogExit = Duration(milliseconds: 130);
  static const tooltipWait = Duration(milliseconds: 420);
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
