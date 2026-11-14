// Windows workbench: continuous surfaces, precise rules, quiet neutral chrome.
// Blue marks focus and actions; content, not decoration, carries the hierarchy.
//
// Colours live in [Ide], a ThemeExtension, so every widget reads one palette;
// the Material theme is built from the same values. Sizes come from [Space]
// and [Radii] so panels, rows and menus line up on one grid.
import 'package:flutter/material.dart';

/// The 4 px spacing grid.
abstract final class Space {
  static const double xs = 4, s = 6, m = 8, l = 12, xl = 16, xxl = 24;

  /// The gap around and between islands.
  static const double gap = 0;
}

abstract final class Radii {
  static const double s = 2, m = 3, l = 4, island = 3, dialog = 6;
}

class Ide extends ThemeExtension<Ide> {
  /// The window behind the islands; the rail, title bar and status bar.
  final Color frame;
  final Color editor, sideBar, activityBar, panel, tabBar, tabActive;

  /// Lines inside an island, and the stronger line of a control.
  final Color border, borderStrong;
  final Color text, textDim, textFaint;
  final Color accent, accentSoft, onAccent;
  final Color selection, hover;

  /// Menus, dialogs, the palette: anything that floats.
  final Color surface;
  final Color input, shadow;
  final Color statusBar, statusText, error, warn, ok, addBg, delBg, addText, delText;

  const Ide({
    required this.frame,
    required this.editor,
    required this.sideBar,
    required this.activityBar,
    required this.panel,
    required this.tabBar,
    required this.tabActive,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.selection,
    required this.hover,
    required this.surface,
    required this.input,
    required this.shadow,
    required this.statusBar,
    required this.statusText,
    required this.error,
    required this.warn,
    required this.ok,
    required this.addBg,
    required this.delBg,
    required this.addText,
    required this.delText,
  });

  static const dark = Ide(
    frame: Color(0xFF181818),
    editor: Color(0xFF1F1F1F),
    sideBar: Color(0xFF181818),
    activityBar: Color(0xFF181818),
    panel: Color(0xFF1F1F1F),
    tabBar: Color(0xFF181818),
    tabActive: Color(0xFF1F1F1F),
    border: Color(0xFF2B2B2B),
    borderStrong: Color(0xFF454545),
    text: Color(0xFFCCCCCC),
    textDim: Color(0xFF9D9D9D),
    textFaint: Color(0xFF858585),
    accent: Color(0xFF3794FF),
    accentSoft: Color(0x243794FF),
    onAccent: Color(0xFFFFFFFF),
    selection: Color(0xFF04395E),
    hover: Color(0xFF2A2D2E),
    surface: Color(0xFF252526),
    input: Color(0xFF313131),
    shadow: Color(0x99000000),
    statusBar: Color(0xFF181818),
    statusText: Color(0xFFACACAC),
    error: Color(0xFFF2616F),
    warn: Color(0xFFE7B04B),
    ok: Color(0xFF52C48A),
    addBg: Color(0xFF1B3327),
    delBg: Color(0xFF3C2127),
    addText: Color(0xFF84D9A6),
    delText: Color(0xFFF59CA4),
  );

  static const light = Ide(
    frame: Color(0xFFF8F8F8),
    editor: Color(0xFFFFFFFF),
    sideBar: Color(0xFFF8F8F8),
    activityBar: Color(0xFFF8F8F8),
    panel: Color(0xFFFFFFFF),
    tabBar: Color(0xFFF8F8F8),
    tabActive: Color(0xFFFFFFFF),
    border: Color(0xFFE5E5E5),
    borderStrong: Color(0xFFCECECE),
    text: Color(0xFF333333),
    textDim: Color(0xFF616161),
    textFaint: Color(0xFF767676),
    accent: Color(0xFF006AB1),
    accentSoft: Color(0x18006AB1),
    onAccent: Color(0xFFFFFFFF),
    selection: Color(0xFFCDE5F8),
    hover: Color(0xFFE8E8E8),
    surface: Color(0xFFFFFFFF),
    input: Color(0xFFFFFFFF),
    shadow: Color(0x2E101828),
    statusBar: Color(0xFFF8F8F8),
    statusText: Color(0xFF5F6670),
    error: Color(0xFFD43447),
    warn: Color(0xFFA66A00),
    ok: Color(0xFF1D8A50),
    addBg: Color(0xFFE2F4E8),
    delBg: Color(0xFFFCE4E6),
    addText: Color(0xFF17673A),
    delText: Color(0xFFB0283A),
  );

  static Ide of(BuildContext context) => Theme.of(context).extension<Ide>()!;

  bool get isDark => editor.computeLuminance() < 0.2;

  /// The interface font: Segoe UI Variable on Windows 11, Segoe UI before it;
  /// Chinese falls back to YaHei UI, other platforms to their own sans.
  static const ui = 'Segoe UI Variable Text';
  static const uiFallback = ['Segoe UI', 'Microsoft YaHei UI', 'PingFang SC', 'Noto Sans CJK SC', 'Roboto'];

  /// Monospace for code, terminal and logs; Chinese falls back to the UI font.
  static const mono = 'Cascadia Mono';
  static const monoFallback = ['Consolas', 'Microsoft YaHei UI', 'Noto Sans Mono CJK SC'];

  /// The soft shadow of anything that floats over the islands.
  List<BoxShadow> get float => [
        BoxShadow(color: shadow, blurRadius: 12, offset: const Offset(0, 4)),
      ];

  @override
  Ide copyWith() => this;

  @override
  Ide lerp(ThemeExtension<Ide>? other, double t) {
    if (other is! Ide) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return Ide(
      frame: l(frame, other.frame),
      editor: l(editor, other.editor),
      sideBar: l(sideBar, other.sideBar),
      activityBar: l(activityBar, other.activityBar),
      panel: l(panel, other.panel),
      tabBar: l(tabBar, other.tabBar),
      tabActive: l(tabActive, other.tabActive),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      text: l(text, other.text),
      textDim: l(textDim, other.textDim),
      textFaint: l(textFaint, other.textFaint),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      onAccent: l(onAccent, other.onAccent),
      selection: l(selection, other.selection),
      hover: l(hover, other.hover),
      surface: l(surface, other.surface),
      input: l(input, other.input),
      shadow: l(shadow, other.shadow),
      statusBar: l(statusBar, other.statusBar),
      statusText: l(statusText, other.statusText),
      error: l(error, other.error),
      warn: l(warn, other.warn),
      ok: l(ok, other.ok),
      addBg: l(addBg, other.addBg),
      delBg: l(delBg, other.delBg),
      addText: l(addText, other.addText),
      delText: l(delText, other.delText),
    );
  }
}

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? Ide.dark : Ide.light;
  final scheme = ColorScheme(
    brightness: b,
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    error: c.error,
    onError: Colors.white,
    surface: c.sideBar,
    onSurface: c.text,
    onSurfaceVariant: c.textDim,
    outline: c.borderStrong,
    outlineVariant: c.border,
    surfaceContainerLowest: c.editor,
    surfaceContainerLow: c.sideBar,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.hover,
    primaryContainer: c.selection,
    onPrimaryContainer: c.text,
    secondaryContainer: c.accentSoft,
    onSecondaryContainer: c.text,
    errorContainer: c.delBg,
    onErrorContainer: c.delText,
    tertiaryContainer: c.addBg,
    onTertiaryContainer: c.addText,
    inverseSurface: c.text,
    onInverseSurface: c.editor,
    shadow: c.shadow,
  );
  const rs = BorderRadius.all(Radius.circular(Radii.s));
  const rm = BorderRadius.all(Radius.circular(Radii.m));
  const rl = BorderRadius.all(Radius.circular(Radii.l));
  final base = ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.frame,
    canvasColor: c.sideBar,
    fontFamily: Ide.ui,
    fontFamilyFallback: Ide.uiFallback,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    hoverColor: c.hover,
    focusColor: c.accentSoft,
    highlightColor: Colors.transparent,
    dividerColor: c.border,
    dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
    extensions: [c],
  );
  final muted = TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.textDim);
  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          bodyLarge: const TextStyle(fontSize: 14, height: 1.45),
          bodyMedium: const TextStyle(fontSize: 13, height: 1.4),
          bodySmall: const TextStyle(fontSize: 12, height: 1.35),
          labelLarge: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          labelMedium: const TextStyle(fontSize: 12),
          labelSmall: const TextStyle(fontSize: 11, letterSpacing: 0.2),
          titleSmall: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          titleMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          titleLarge: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2),
          headlineSmall: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.3),
        )
        .apply(bodyColor: c.text, displayColor: c.text, fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback),
    iconTheme: IconThemeData(color: c.textDim, size: 18),
    appBarTheme: AppBarTheme(
      backgroundColor: c.frame,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 44,
      titleSpacing: 4,
      iconTheme: IconThemeData(color: c.textDim, size: 18),
      titleTextStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.text, fontSize: 14, fontWeight: FontWeight.w600),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: c.surface, border: Border.all(color: c.borderStrong), borderRadius: rm, boxShadow: c.float),
      textStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.text, fontSize: 12),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: c.shadow,
      elevation: 10,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: rl, side: BorderSide(color: c.borderStrong.withValues(alpha: 0.7))),
      textStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.text, fontSize: 13),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: c.shadow,
      elevation: 16,
      barrierColor: Colors.black.withValues(alpha: c.isDark ? 0.5 : 0.28),
      shape: RoundedRectangleBorder(borderRadius: const BorderRadius.all(Radius.circular(Radii.dialog)), side: BorderSide(color: c.borderStrong.withValues(alpha: 0.6))),
      titleTextStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.text, fontSize: 16, fontWeight: FontWeight.w600),
      contentTextStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.textDim, fontSize: 13, height: 1.5),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.borderStrong,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.surface,
      contentTextStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.text, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.only(top: 8, bottom: 40),
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: rl, side: BorderSide(color: c.borderStrong.withValues(alpha: 0.7))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.input,
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(borderRadius: rm, borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(borderRadius: rm, borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(borderRadius: rm, borderSide: BorderSide(color: c.accent, width: 1.4)),
      errorBorder: OutlineInputBorder(borderRadius: rm, borderSide: BorderSide(color: c.error)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: rm, borderSide: BorderSide(color: c.error, width: 1.4)),
      disabledBorder: OutlineInputBorder(borderRadius: rm, borderSide: BorderSide(color: c.border.withValues(alpha: 0.5))),
      labelStyle: muted.copyWith(fontSize: 13),
      floatingLabelStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.accent, fontSize: 13),
      helperStyle: muted.copyWith(fontSize: 11.5),
      hintStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.textFaint, fontSize: 13),
      prefixIconColor: c.textDim,
      suffixIconColor: c.textDim,
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.accent, selectionColor: c.selection, selectionHandleColor: c.accent),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.isDark ? const Color(0xFF0078D4) : c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.hover,
        disabledForegroundColor: c.textFaint,
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: const RoundedRectangleBorder(borderRadius: rm),
        elevation: 0,
        textStyle: const TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.surface,
        foregroundColor: c.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        minimumSize: const Size(64, 32),
        shape: RoundedRectangleBorder(borderRadius: rm, side: BorderSide(color: c.borderStrong)),
        textStyle: const TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, fontSize: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.borderStrong),
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: const RoundedRectangleBorder(borderRadius: rm),
        textStyle: const TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, fontSize: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(48, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: const RoundedRectangleBorder(borderRadius: rm),
        textStyle: const TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.textDim, hoverColor: c.hover, shape: const RoundedRectangleBorder(borderRadius: rm)),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(borderRadius: rs),
      side: BorderSide(color: c.textFaint, width: 1.3),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent),
      checkColor: WidgetStateProperty.all(c.onAccent),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.textFaint)),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onAccent : c.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(activeTrackColor: c.accent, inactiveTrackColor: c.border, thumbColor: c.accent, overlayColor: c.accentSoft, trackHeight: 3),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => c.textDim.withValues(alpha: s.contains(WidgetState.dragged) ? 0.55 : (s.contains(WidgetState.hovered) ? 0.42 : 0.26))),
      radius: const Radius.circular(4),
      thickness: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged) ? 8 : 6),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.border, circularTrackColor: Colors.transparent),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: c.textDim,
      textColor: c.text,
      selectedColor: c.text,
      selectedTileColor: c.selection,
      shape: const RoundedRectangleBorder(borderRadius: rm),
    ),
    cardTheme: CardThemeData(
      color: c.editor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: rl, side: BorderSide(color: c.border)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.input,
      selectedColor: c.accentSoft,
      side: BorderSide(color: c.border),
      shape: const RoundedRectangleBorder(borderRadius: rm),
      labelStyle: TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, color: c.text, fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    badgeTheme: BadgeThemeData(backgroundColor: c.accent, textColor: c.onAccent, smallSize: 7),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: c.borderStrong),
        selectedBackgroundColor: c.accentSoft,
        selectedForegroundColor: c.text,
        foregroundColor: c.textDim,
        shape: const RoundedRectangleBorder(borderRadius: rm),
        textStyle: const TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, fontSize: 13),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.text,
      unselectedLabelColor: c.textDim,
      indicatorColor: c.accent,
      dividerColor: c.border,
      labelStyle: const TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, fontSize: 13, fontWeight: FontWeight.w500),
      unselectedLabelStyle: const TextStyle(fontFamily: Ide.ui, fontFamilyFallback: Ide.uiFallback, fontSize: 13),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(c.surface),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shadowColor: WidgetStateProperty.all(c.shadow),
        elevation: WidgetStateProperty.all(10),
        padding: WidgetStateProperty.all(const EdgeInsets.all(4)),
        shape: WidgetStateProperty.all(const RoundedRectangleBorder(borderRadius: rl)),
        side: WidgetStateProperty.all(BorderSide(color: c.borderStrong.withValues(alpha: 0.7))),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStateProperty.all(c.surface),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shape: WidgetStateProperty.all(const RoundedRectangleBorder(borderRadius: rl)),
        side: WidgetStateProperty.all(BorderSide(color: c.borderStrong.withValues(alpha: 0.7))),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: c.frame, indicatorColor: c.accentSoft, surfaceTintColor: Colors.transparent),
  );
}
