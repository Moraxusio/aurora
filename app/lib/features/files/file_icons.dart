import 'package:aurora/ui/aurora_ui.dart';

import '../../theme/ide_theme.dart';

class FileIconSpec {
  final IconData icon;
  final Color darkColor;
  final Color lightColor;
  final String? badge;

  const FileIconSpec(
    this.icon,
    this.darkColor, {
    Color? lightColor,
    this.badge,
  }) : lightColor = lightColor ?? darkColor;

  Color colorFor(Ide ide) => ide.isDark ? darkColor : lightColor;
}

FileIconSpec fileIconSpec(String name) {
  final base = name.split('/').last.split(r'\').last;
  final lower = base.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot > 0 && dot < lower.length - 1 ? lower.substring(dot + 1) : '';

  // Exact filenames and special dotfiles first.
  if (lower == 'dockerfile' || lower.startsWith('dockerfile.')) {
    return const FileIconSpec(
      Icons.layers_outlined,
      Color(0xFF4DA6DB),
      lightColor: Color(0xFF1D74AB),
      badge: 'DKR',
    );
  }
  if (lower == 'docker-compose.yml' ||
      lower == 'docker-compose.yaml' ||
      lower == 'compose.yml' ||
      lower == 'compose.yaml') {
    return const FileIconSpec(
      Icons.layers_outlined,
      Color(0xFF38BDF8),
      lightColor: Color(0xFF0284C7),
      badge: 'CMP',
    );
  }
  if (lower == 'makefile' ||
      lower == 'gnumakefile' ||
      lower == 'cmakelists.txt' ||
      ext == 'mk' ||
      ext == 'cmake') {
    return const FileIconSpec(
      Icons.build_outlined,
      Color(0xFFE07A5F),
      lightColor: Color(0xFFC04A2B),
      badge: 'MK',
    );
  }
  if (lower == '.gitignore' ||
      lower == '.gitattributes' ||
      lower == '.gitmodules' ||
      lower == '.gitkeep') {
    return const FileIconSpec(
      Icons.fork_right,
      Color(0xFFF05032),
      lightColor: Color(0xFFD0381C),
    );
  }
  if (lower == '.dockerignore' || lower == '.npmignore') {
    return const FileIconSpec(
      Icons.block_outlined,
      Color(0xFF8B949E),
      lightColor: Color(0xFF57606A),
    );
  }
  if (lower == '.editorconfig' ||
      lower == '.prettierrc' ||
      lower == '.eslintrc' ||
      lower == '.clang-format' ||
      lower == 'analysis_options.yaml') {
    return const FileIconSpec(
      Icons.tune,
      Color(0xFFA78BFA),
      lightColor: Color(0xFF7C3AED),
    );
  }
  if (lower == 'pubspec.yaml' || lower == 'pubspec.yml') {
    return const FileIconSpec(
      Icons.inventory_2_outlined,
      Color(0xFF40B4E5),
      lightColor: Color(0xFF0284C7),
      badge: 'PUB',
    );
  }
  if (lower == 'package.json') {
    return const FileIconSpec(
      Icons.data_object,
      Color(0xFF81C784),
      lightColor: Color(0xFF2E7D32),
      badge: 'NPM',
    );
  }
  if (lower == 'tsconfig.json' || lower.startsWith('tsconfig.')) {
    return const FileIconSpec(
      Icons.data_object,
      Color(0xFF4EA8DE),
      lightColor: Color(0xFF1D6FA5),
      badge: 'TS',
    );
  }
  if (lower == 'cargo.toml') {
    return const FileIconSpec(
      Icons.settings_outlined,
      Color(0xFFDEA584),
      lightColor: Color(0xFFB45309),
      badge: 'RS',
    );
  }
  if (lower == 'go.mod' || lower == 'go.sum') {
    return const FileIconSpec(
      Icons.code,
      Color(0xFF00ADD8),
      lightColor: Color(0xFF0284A8),
      badge: 'GO',
    );
  }
  if (lower == 'pubspec.lock' ||
      lower == 'package-lock.json' ||
      lower == 'yarn.lock' ||
      lower == 'pnpm-lock.yaml' ||
      lower == 'cargo.lock' ||
      lower == 'poetry.lock' ||
      ext == 'lock') {
    return const FileIconSpec(
      Icons.lock_outline,
      Color(0xFFD4A74A),
      lightColor: Color(0xFF9A6F14),
    );
  }
  if (lower == 'license' ||
      lower == 'licence' ||
      lower == 'notice' ||
      lower.startsWith('license.') ||
      lower.startsWith('licence.')) {
    return const FileIconSpec(
      Icons.gavel_outlined,
      Color(0xFFE0B44A),
      lightColor: Color(0xFF9F7514),
    );
  }
  if (lower == 'readme.md' ||
      lower == 'readme' ||
      lower.startsWith('readme.')) {
    return const FileIconSpec(
      Icons.menu_book_outlined,
      Color(0xFF60A5FA),
      lightColor: Color(0xFF2563EB),
      badge: 'MD',
    );
  }
  if (lower == 'changelog.md' || lower == 'changes.md') {
    return const FileIconSpec(
      Icons.history_edu_outlined,
      Color(0xFF60A5FA),
      lightColor: Color(0xFF2563EB),
      badge: 'MD',
    );
  }
  if (lower == '.env' ||
      lower.startsWith('.env.') ||
      ext == 'env' ||
      ext == 'key' ||
      ext == 'pem' ||
      ext == 'crt' ||
      ext == 'cer' ||
      ext == 'p12' ||
      ext == 'pfx' ||
      ext == 'pub') {
    return const FileIconSpec(
      Icons.key_outlined,
      Color(0xFFE5B84B),
      lightColor: Color(0xFF9F710E),
    );
  }
  if (lower == '.bashrc' ||
      lower == '.zshrc' ||
      lower == '.profile' ||
      lower == '.bash_profile' ||
      lower == '.bash_aliases') {
    return const FileIconSpec(
      Icons.terminal,
      Color(0xFF61C78C),
      lightColor: Color(0xFF237A48),
      badge: 'SH',
    );
  }

  return switch (ext) {
    // Languages
    'dart' => const FileIconSpec(
      Icons.code,
      Color(0xFF40C4FF),
      lightColor: Color(0xFF0284C7),
      badge: 'DT',
    ),
    'go' => const FileIconSpec(
      Icons.code,
      Color(0xFF29B6F6),
      lightColor: Color(0xFF0284A8),
      badge: 'GO',
    ),
    'ts' => const FileIconSpec(
      Icons.code,
      Color(0xFF4EA8DE),
      lightColor: Color(0xFF1D6FA5),
      badge: 'TS',
    ),
    'tsx' => const FileIconSpec(
      Icons.code,
      Color(0xFF56CCF2),
      lightColor: Color(0xFF0284C7),
      badge: 'TX',
    ),
    'js' || 'mjs' || 'cjs' => const FileIconSpec(
      Icons.code,
      Color(0xFFF2C94C),
      lightColor: Color(0xFFB38600),
      badge: 'JS',
    ),
    'jsx' => const FileIconSpec(
      Icons.code,
      Color(0xFF61DAFB),
      lightColor: Color(0xFF0284C7),
      badge: 'JX',
    ),
    'py' || 'pyw' || 'pyi' => const FileIconSpec(
      Icons.code,
      Color(0xFF5FA8E8),
      lightColor: Color(0xFF2B6CB0),
      badge: 'PY',
    ),
    'ipynb' => const FileIconSpec(
      Icons.science_outlined,
      Color(0xFFF37626),
      lightColor: Color(0xFFC2510C),
      badge: 'NB',
    ),
    'rs' => const FileIconSpec(
      Icons.data_object,
      Color(0xFFDEA584),
      lightColor: Color(0xFF9C4221),
      badge: 'RS',
    ),
    'c' => const FileIconSpec(
      Icons.data_object,
      Color(0xFF649AD2),
      lightColor: Color(0xFF2B5F9E),
      badge: 'C',
    ),
    'h' => const FileIconSpec(
      Icons.data_object,
      Color(0xFFA78BFA),
      lightColor: Color(0xFF6D28D9),
      badge: 'H',
    ),
    'cpp' || 'cc' || 'cxx' => const FileIconSpec(
      Icons.data_object,
      Color(0xFF659BD3),
      lightColor: Color(0xFF2563EB),
      badge: 'C+',
    ),
    'hpp' || 'hh' || 'hxx' => const FileIconSpec(
      Icons.data_object,
      Color(0xFFC084FC),
      lightColor: Color(0xFF7E22CE),
      badge: 'H+',
    ),
    'cs' => const FileIconSpec(
      Icons.data_object,
      Color(0xFF9B72CF),
      lightColor: Color(0xFF6D28D9),
      badge: 'C#',
    ),
    'java' => const FileIconSpec(
      Icons.coffee_outlined,
      Color(0xFFF89820),
      lightColor: Color(0xFFB45309),
      badge: 'JV',
    ),
    'kt' || 'kts' => const FileIconSpec(
      Icons.code,
      Color(0xFFA97BFF),
      lightColor: Color(0xFF6D28D9),
      badge: 'KT',
    ),
    'swift' => const FileIconSpec(
      Icons.code,
      Color(0xFFF05138),
      lightColor: Color(0xFFC0351D),
      badge: 'SW',
    ),
    'rb' => const FileIconSpec(
      Icons.diamond_outlined,
      Color(0xFFE06C75),
      lightColor: Color(0xFFB91C1C),
      badge: 'RB',
    ),
    'php' => const FileIconSpec(
      Icons.code,
      Color(0xFF8993BE),
      lightColor: Color(0xFF4F46E5),
      badge: 'PHP',
    ),
    'lua' => const FileIconSpec(
      Icons.code,
      Color(0xFF60A5FA),
      lightColor: Color(0xFF1D4ED8),
      badge: 'LUA',
    ),
    'r' => const FileIconSpec(
      Icons.analytics_outlined,
      Color(0xFF569CD6),
      lightColor: Color(0xFF1D4ED8),
      badge: 'R',
    ),
    'gradle' => const FileIconSpec(
      Icons.build_outlined,
      Color(0xFF4FD1C5),
      lightColor: Color(0xFF0F766E),
      badge: 'GR',
    ),

    // Web & Markup
    'html' || 'htm' || 'xhtml' => const FileIconSpec(
      Icons.html_outlined,
      Color(0xFFE44D26),
      lightColor: Color(0xFFC23B18),
      badge: '<>',
    ),
    'css' => const FileIconSpec(
      Icons.css_outlined,
      Color(0xFF42A5F5),
      lightColor: Color(0xFF1D6FA5),
      badge: 'CSS',
    ),
    'scss' || 'sass' || 'less' => const FileIconSpec(
      Icons.style_outlined,
      Color(0xFFCF649A),
      lightColor: Color(0xFFA63A72),
      badge: 'SC',
    ),
    'vue' => const FileIconSpec(
      Icons.code,
      Color(0xFF42B883),
      lightColor: Color(0xFF1E8758),
      badge: 'VUE',
    ),
    'svelte' => const FileIconSpec(
      Icons.code,
      Color(0xFFFF3E00),
      lightColor: Color(0xFFC23000),
      badge: 'SV',
    ),
    'xml' || 'plist' || 'xaml' => const FileIconSpec(
      Icons.code,
      Color(0xFFE08B55),
      lightColor: Color(0xFFB45309),
      badge: 'XML',
    ),
    'svg' => const FileIconSpec(
      Icons.polyline_outlined,
      Color(0xFFFFB13B),
      lightColor: Color(0xFFB4690E),
      badge: 'SVG',
    ),

    // Config & Structured Data
    'json' || 'jsonc' || 'jsonl' || 'geojson' => const FileIconSpec(
      Icons.data_object,
      Color(0xFFE5C07B),
      lightColor: Color(0xFFA1720E),
      badge: '{}',
    ),
    'yml' || 'yaml' => const FileIconSpec(
      Icons.tune,
      Color(0xFFCB6E8A),
      lightColor: Color(0xFF9D3457),
      badge: 'YML',
    ),
    'toml' => const FileIconSpec(
      Icons.tune,
      Color(0xFF9B8BBB),
      lightColor: Color(0xFF6B4FA1),
      badge: 'TML',
    ),
    'ini' || 'cfg' || 'conf' || 'properties' || 'service' || 'timer' || 'socket' =>
      const FileIconSpec(
        Icons.settings_outlined,
        Color(0xFF94A3B8),
        lightColor: Color(0xFF475569),
      ),
    'proto' => const FileIconSpec(
      Icons.hub_outlined,
      Color(0xFF38BDF8),
      lightColor: Color(0xFF0284C7),
      badge: 'PB',
    ),
    'graphql' || 'gql' => const FileIconSpec(
      Icons.hub_outlined,
      Color(0xFFE535AB),
      lightColor: Color(0xFFAF187D),
      badge: 'GQL',
    ),

    // Docs, LaTeX, Office, Data
    'md' || 'markdown' || 'mdx' => const FileIconSpec(
      Icons.description_outlined,
      Color(0xFF60A5FA),
      lightColor: Color(0xFF2563EB),
      badge: 'MD',
    ),
    'tex' || 'ltx' || 'cls' || 'sty' => const FileIconSpec(
      Icons.functions_rounded,
      Color(0xFF3FB984),
      lightColor: Color(0xFF15803D),
      badge: 'TEX',
    ),
    'bib' => const FileIconSpec(
      Icons.menu_book_outlined,
      Color(0xFF4EC9B0),
      lightColor: Color(0xFF0F766E),
      badge: 'BIB',
    ),
    'pdf' => const FileIconSpec(
      Icons.picture_as_pdf_outlined,
      Color(0xFFF2616F),
      lightColor: Color(0xFFCC2838),
      badge: 'PDF',
    ),
    'csv' || 'tsv' => const FileIconSpec(
      Icons.table_chart_outlined,
      Color(0xFF52C48A),
      lightColor: Color(0xFF1D8A50),
      badge: 'CSV',
    ),
    'xls' || 'xlsx' || 'ods' => const FileIconSpec(
      Icons.table_chart_outlined,
      Color(0xFF34A853),
      lightColor: Color(0xFF1E7E34),
      badge: 'XLS',
    ),
    'doc' || 'docx' || 'odt' || 'rtf' => const FileIconSpec(
      Icons.article_outlined,
      Color(0xFF4B8BF4),
      lightColor: Color(0xFF1D5DC4),
      badge: 'DOC',
    ),
    'ppt' || 'pptx' || 'odp' => const FileIconSpec(
      Icons.slideshow_outlined,
      Color(0xFFE67E45),
      lightColor: Color(0xFFC05621),
      badge: 'PPT',
    ),
    'txt' || 'rst' => const FileIconSpec(
      Icons.description_outlined,
      Color(0xFF94A3B8),
      lightColor: Color(0xFF525D6B),
    ),
    'log' => const FileIconSpec(
      Icons.subject,
      Color(0xFF94A3B8),
      lightColor: Color(0xFF525D6B),
    ),
    'diff' || 'patch' => const FileIconSpec(
      Icons.difference_outlined,
      Color(0xFF60A5FA),
      lightColor: Color(0xFF2563EB),
    ),

    // Shell & Scripts
    'sh' || 'bash' || 'zsh' || 'fish' => const FileIconSpec(
      Icons.terminal,
      Color(0xFF61C78C),
      lightColor: Color(0xFF237A48),
      badge: 'SH',
    ),
    'ps1' || 'psm1' => const FileIconSpec(
      Icons.terminal,
      Color(0xFF5391FE),
      lightColor: Color(0xFF1D4ED8),
      badge: 'PS',
    ),
    'bat' || 'cmd' => const FileIconSpec(
      Icons.terminal,
      Color(0xFFA3E635),
      lightColor: Color(0xFF4D7C0F),
      badge: 'CMD',
    ),

    // Database
    'sql' => const FileIconSpec(
      Icons.storage_outlined,
      Color(0xFFE0A94F),
      lightColor: Color(0xFFA16B12),
      badge: 'SQL',
    ),
    'db' || 'sqlite' || 'sqlite3' => const FileIconSpec(
      Icons.storage_outlined,
      Color(0xFF60A5FA),
      lightColor: Color(0xFF2563EB),
    ),

    // Media
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'ico' || 'wbmp' || 'avif' || 'heic' =>
      const FileIconSpec(
        Icons.image_outlined,
        Color(0xFFC084FC),
        lightColor: Color(0xFF7E22CE),
      ),
    'mp4' || 'm4v' || 'mov' || 'webm' || 'mkv' || 'ogv' || 'avi' || 'wmv' || 'flv' || '3gp' =>
      const FileIconSpec(
        Icons.movie_outlined,
        Color(0xFFF472B6),
        lightColor: Color(0xFFBE185D),
      ),
    'mp3' || 'm4a' || 'aac' || 'wav' || 'flac' || 'ogg' || 'oga' || 'opus' || 'wma' =>
      const FileIconSpec(
        Icons.audiotrack_outlined,
        Color(0xFFFB7185),
        lightColor: Color(0xFFBE123C),
      ),

    // Archives & Packages
    'zip' || 'tar' || 'gz' || 'tgz' || 'bz2' || 'xz' || '7z' || 'rar' || 'zst' =>
      const FileIconSpec(
        Icons.inventory_2_outlined,
        Color(0xFFC69F68),
        lightColor: Color(0xFF8C6229),
      ),
    'deb' || 'rpm' || 'apk' || 'dmg' || 'msi' || 'exe' || 'appimage' =>
      const FileIconSpec(
        Icons.apps_outlined,
        Color(0xFF60A5FA),
        lightColor: Color(0xFF2563EB),
      ),
    'dll' || 'so' || 'dylib' || 'wasm' || 'o' || 'a' => const FileIconSpec(
      Icons.memory_outlined,
      Color(0xFF94A3B8),
      lightColor: Color(0xFF475569),
    ),
    'ttf' || 'otf' || 'woff' || 'woff2' => const FileIconSpec(
      Icons.font_download_outlined,
      Color(0xFFE07A5F),
      lightColor: Color(0xFFB44425),
    ),
    _ => const FileIconSpec(
      Icons.insert_drive_file_outlined,
      Color(0xFF9D9D9D),
      lightColor: Color(0xFF616161),
    ),
  };
}

(IconData, Color) fileGlyph(String name, Ide ide) {
  final spec = fileIconSpec(name);
  return (spec.icon, spec.colorFor(ide));
}

(IconData, Color) folderGlyph(
  String name, {
  required bool expanded,
  required bool root,
  required Ide ide,
}) {
  if (root) {
    return (
      expanded ? Icons.folder_open_rounded : Icons.folder_special_rounded,
      ide.accent,
    );
  }
  final lower = name.toLowerCase();
  final icon = expanded ? Icons.folder_open_rounded : Icons.folder_rounded;
  final Color darkColor;
  final Color lightColor;
  switch (lower) {
    case 'src' || 'lib' || 'app' || 'pkg' || 'internal' || 'cmd' || 'core':
      darkColor = const Color(0xFF56A8F5);
      lightColor = const Color(0xFF1D6FA5);
    case 'test' || 'tests' || '__tests__' || 'spec' || 'e2e' || 'integration_test':
      darkColor = const Color(0xFF62C088);
      lightColor = const Color(0xFF1F7A46);
    case 'docs' || 'doc':
      darkColor = const Color(0xFF4CC9F0);
      lightColor = const Color(0xFF0284C7);
    case 'assets' || 'images' || 'img' || 'media' || 'static' || 'public' || 'icons' || 'fonts':
      darkColor = const Color(0xFFC084FC);
      lightColor = const Color(0xFF7E22CE);
    case 'tools' || 'tool' || 'scripts' || 'script' || 'bin' || 'hooks':
      darkColor = const Color(0xFF4EC9B0);
      lightColor = const Color(0xFF0F766E);
    case '.git' || '.github' || '.vscode' || '.idea' || 'config' || 'configs' || 'settings':
      darkColor = const Color(0xFF8E9AAF);
      lightColor = const Color(0xFF475569);
    case 'build' || 'dist' || 'out' || 'target' || 'node_modules' || '.dart_tool' || 'vendor' || '.venv' || 'venv':
      darkColor = const Color(0xFFA08C68);
      lightColor = const Color(0xFF7C6640);
    default:
      darkColor = const Color(0xFFCFAB63);
      lightColor = const Color(0xFFB5852A);
  }
  return (icon, ide.isDark ? darkColor : lightColor);
}

class FileIcon extends StatelessWidget {
  final String name;
  final bool folder;
  final bool expanded;
  final bool root;
  final double size;

  const FileIcon({
    super.key,
    required this.name,
    this.folder = false,
    this.expanded = false,
    this.root = false,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (folder) {
      final (icon, color) = folderGlyph(
        name,
        expanded: expanded,
        root: root,
        ide: ide,
      );
      return Icon(icon, size: size, color: color);
    }
    final spec = fileIconSpec(name);
    final color = spec.colorFor(ide);
    final badge = spec.badge;
    if (badge == null) {
      return Icon(spec.icon, size: size, color: color);
    }
    final fontSize = switch (badge.length) {
      1 => size * 0.56,
      2 => size * 0.45,
      _ => size * 0.35,
    };
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: ide.isDark ? 0.16 : 0.12),
          borderRadius: BorderRadius.circular(size * 0.22),
          border: Border.all(
            color: color.withValues(alpha: ide.isDark ? 0.52 : 0.45),
            width: 0.9,
          ),
        ),
        child: Text(
          badge,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            color: color,
            height: 1.0,
            letterSpacing: badge.length >= 3 ? -0.5 : -0.2,
          ),
        ),
      ),
    );
  }
}
