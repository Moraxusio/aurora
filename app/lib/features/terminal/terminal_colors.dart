// The terminal's colours: the 16 ANSI colours, the cursor and the selection,
// one set per brightness. Two things the first version got wrong:
//  - the 16 colours were chosen for a dark background only, so on the light
//    theme yellow (E5E510) was close to invisible on white;
//  - the cursor and the selection were opaque, so both hid the text under them.
// The cursor stays opaque (the view draws the character on it again, see
// third_party/xterm/AURORA.md); the selection is translucent, like upstream's.
//
// One TerminalTheme per brightness, built once: a new theme object makes the
// view clear its glyph cache, and the view is rebuilt whenever anything in the
// workspace changes.
import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../../theme/ide_theme.dart';

final Map<int, TerminalTheme> _themes = {};

/// The terminal theme that goes with [ide].
TerminalTheme terminalTheme(Ide ide) => _themes[ide.panel.toARGB32()] ??= _build(ide);

/// Whether [ide] is a dark theme (its panel colour is dark).
bool isDark(Ide ide) => ide.panel.computeLuminance() < 0.5;

class _Ansi {
  final Color black, red, green, yellow, blue, magenta, cyan, white;
  final Color brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite;
  const _Ansi(this.black, this.red, this.green, this.yellow, this.blue, this.magenta, this.cyan, this.white, this.brightBlack, this.brightRed,
      this.brightGreen, this.brightYellow, this.brightBlue, this.brightMagenta, this.brightCyan, this.brightWhite);
}

// For a dark background.
const _darkAnsi = _Ansi(
  Color(0xFF000000), Color(0xFFCD3131), Color(0xFF0DBC79), Color(0xFFE5E510), Color(0xFF2472C8), Color(0xFFBC3FBC), Color(0xFF11A8CD), Color(0xFFE5E5E5),
  Color(0xFF8A8D96), Color(0xFFF14C4C), Color(0xFF23D18B), Color(0xFFF5F543), Color(0xFF3B8EEA), Color(0xFFD670D6), Color(0xFF29B8DB), Color(0xFFFFFFFF),
);

// For a white background: darker, so text in each colour is readable. "white"
// is the dark grey that a light terminal uses for it; "bright white" stays pale,
// it is what programs use as a background.
const _lightAnsi = _Ansi(
  Color(0xFF000000), Color(0xFFC62828), Color(0xFF1B7F2A), Color(0xFF8A6D00), Color(0xFF1F5FC8), Color(0xFF9B2FAE), Color(0xFF007C8C), Color(0xFF555555),
  Color(0xFF6B6F76), Color(0xFFD32F2F), Color(0xFF2A7D38), Color(0xFF8F7000), Color(0xFF2F6FD8), Color(0xFFA93CBB), Color(0xFF0B7F90), Color(0xFFA5A5A5),
);

TerminalTheme _build(Ide ide) {
  final a = isDark(ide) ? _darkAnsi : _lightAnsi;
  return TerminalTheme(
    cursor: ide.accent,
    selection: ide.accent.withValues(alpha: 0.35),
    foreground: ide.text,
    background: ide.panel,
    black: a.black,
    red: a.red,
    green: a.green,
    yellow: a.yellow,
    blue: a.blue,
    magenta: a.magenta,
    cyan: a.cyan,
    white: a.white,
    brightBlack: a.brightBlack,
    brightRed: a.brightRed,
    brightGreen: a.brightGreen,
    brightYellow: a.brightYellow,
    brightBlue: a.brightBlue,
    brightMagenta: a.brightMagenta,
    brightCyan: a.brightCyan,
    brightWhite: a.brightWhite,
    searchHitBackground: const Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: const Color(0xFF31FF26),
    searchHitForeground: const Color(0xFF000000),
  );
}
