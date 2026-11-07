// The client's look: an IDE's, flat and dense (docs/DESIGN.md D-79). Colours
// live in [Ide], a ThemeExtension, so every widget reads one palette; the
// Material theme is built from the same values.
import 'package:flutter/material.dart';

class Ide extends ThemeExtension<Ide> {
  final Color editor, sideBar, activityBar, panel, tabBar, tabActive, border, text, textDim, accent, selection, hover;
  final Color statusBar, statusText, error, warn, ok, addBg, delBg, addText, delText;

  const Ide({
    required this.editor,
    required this.sideBar,
    required this.activityBar,
    required this.panel,
    required this.tabBar,
    required this.tabActive,
    required this.border,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.selection,
    required this.hover,
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
    editor: Color(0xFF1E1F22),
    sideBar: Color(0xFF2B2D30),
    activityBar: Color(0xFF2B2D30),
    panel: Color(0xFF1E1F22),
    tabBar: Color(0xFF2B2D30),
    tabActive: Color(0xFF1E1F22),
    border: Color(0xFF393B40),
    text: Color(0xFFDFE1E5),
    textDim: Color(0xFF9DA0A8),
    accent: Color(0xFF548AF7),
    selection: Color(0xFF2E436E),
    hover: Color(0xFF393B40),
    statusBar: Color(0xFF2B2D30),
    statusText: Color(0xFF9DA0A8),
    error: Color(0xFFF75464),
    warn: Color(0xFFF2C55C),
    ok: Color(0xFF5FB865),
    addBg: Color(0xFF1F3A2A),
    delBg: Color(0xFF4A2327),
    addText: Color(0xFF8FD694),
    delText: Color(0xFFF59AA2),
  );

  static const light = Ide(
    editor: Color(0xFFFFFFFF),
    sideBar: Color(0xFFF7F8FA),
    activityBar: Color(0xFFF2F3F5),
    panel: Color(0xFFFFFFFF),
    tabBar: Color(0xFFF7F8FA),
    tabActive: Color(0xFFFFFFFF),
    border: Color(0xFFD3D5DB),
    text: Color(0xFF1E1F22),
    textDim: Color(0xFF6C707E),
    accent: Color(0xFF3574F0),
    selection: Color(0xFFD4E2FF),
    hover: Color(0xFFE6E8EC),
    statusBar: Color(0xFFF2F3F5),
    statusText: Color(0xFF6C707E),
    error: Color(0xFFDB3B4B),
    warn: Color(0xFFA46704),
    ok: Color(0xFF208A3C),
    addBg: Color(0xFFE3F5E6),
    delBg: Color(0xFFFCE3E5),
    addText: Color(0xFF1B6E32),
    delText: Color(0xFFB02A37),
  );

  static Ide of(BuildContext context) => Theme.of(context).extension<Ide>()!;

  /// Monospace for code, terminal and logs; Chinese falls back to the UI font.
  static const mono = 'Cascadia Mono';
  static const monoFallback = ['Consolas', 'Microsoft YaHei UI', 'Noto Sans Mono CJK SC'];

  @override
  Ide copyWith() => this;

  @override
  Ide lerp(ThemeExtension<Ide>? other, double t) => t < 0.5 ? this : (other as Ide? ?? this);
}

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? Ide.dark : Ide.light;
  final scheme = ColorScheme(
    brightness: b,
    primary: c.accent,
    onPrimary: Colors.white,
    secondary: c.accent,
    onSecondary: Colors.white,
    error: c.error,
    onError: Colors.white,
    surface: c.sideBar,
    onSurface: c.text,
    onSurfaceVariant: c.textDim,
    outline: c.border,
    outlineVariant: c.border,
    surfaceContainerLowest: c.editor,
    surfaceContainerLow: c.sideBar,
    surfaceContainer: c.sideBar,
    surfaceContainerHigh: c.tabBar,
    surfaceContainerHighest: c.hover,
    primaryContainer: c.selection,
    onPrimaryContainer: c.text,
    errorContainer: c.delBg,
    onErrorContainer: c.delText,
    tertiaryContainer: c.addBg,
    onTertiaryContainer: c.addText,
    inverseSurface: c.text,
    onInverseSurface: c.editor,
  );
  const r4 = BorderRadius.all(Radius.circular(4));
  final base = ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.editor,
    canvasColor: c.sideBar,
    fontFamily: 'Microsoft YaHei UI',
    fontFamilyFallback: const ['Segoe UI', 'Noto Sans CJK SC'],
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    hoverColor: c.hover,
    highlightColor: Colors.transparent,
    dividerColor: c.border,
    dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
    extensions: [c],
  );
  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          bodyLarge: const TextStyle(fontSize: 14),
          bodyMedium: const TextStyle(fontSize: 13),
          bodySmall: const TextStyle(fontSize: 12),
          labelLarge: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          labelMedium: const TextStyle(fontSize: 12),
          labelSmall: const TextStyle(fontSize: 11),
          titleSmall: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          titleMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          titleLarge: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        )
        .apply(bodyColor: c.text, displayColor: c.text),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(color: c.tabBar, border: Border.all(color: c.border), borderRadius: r4),
      textStyle: TextStyle(color: c.text, fontSize: 12),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.sideBar,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: r4, side: BorderSide(color: c.border)),
      textStyle: TextStyle(color: c.text, fontSize: 13),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.sideBar,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: const BorderRadius.all(Radius.circular(6)), side: BorderSide(color: c.border)),
      titleTextStyle: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w600, fontFamily: 'Microsoft YaHei UI'),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.tabBar,
      contentTextStyle: TextStyle(color: c.text, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: r4, side: BorderSide(color: c.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.editor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(borderRadius: r4, borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(borderRadius: r4, borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(borderRadius: r4, borderSide: BorderSide(color: c.accent)),
      errorBorder: OutlineInputBorder(borderRadius: r4, borderSide: BorderSide(color: c.error)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: r4, borderSide: BorderSide(color: c.error)),
      labelStyle: TextStyle(color: c.textDim, fontSize: 13),
      helperStyle: TextStyle(color: c.textDim, fontSize: 11),
      hintStyle: TextStyle(color: c.textDim, fontSize: 13),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: const RoundedRectangleBorder(borderRadius: r4),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.border),
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: const RoundedRectangleBorder(borderRadius: r4),
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(48, 32),
        shape: const RoundedRectangleBorder(borderRadius: r4),
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.textDim, shape: const RoundedRectangleBorder(borderRadius: r4)),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      side: BorderSide(color: c.textDim, width: 1.2),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : c.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.border),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(c.textDim.withValues(alpha: 0.35)),
      radius: const Radius.circular(3),
      thickness: WidgetStateProperty.all(8),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.border),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: c.textDim,
      textColor: c.text,
      selectedColor: c.text,
      selectedTileColor: c.selection,
      shape: const RoundedRectangleBorder(),
    ),
    cardTheme: CardThemeData(
      color: c.sideBar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: const BorderRadius.all(Radius.circular(6)), side: BorderSide(color: c.border)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: c.border),
        shape: const RoundedRectangleBorder(borderRadius: r4),
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(c.sideBar),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
      ),
    ),
  );
}
