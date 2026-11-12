import 'package:flutter/material.dart';

import '../../kernel/input_mode.dart';
import '../../kernel/widgets.dart';
import '../../theme/ide_theme.dart';

/// File-specific visual hierarchy; other service lists keep their compact rows.
class FileTreeRow extends StatelessWidget {
  final String name, path;
  final int depth;
  final bool folder, expanded, loading, selected, root, link;
  final String? location, detail;

  /// Cut rows are drawn faint until they are pasted or the cut is cancelled.
  final bool dimmed;

  /// Replaces the path in the hover tooltip (size, time, permissions).
  final String? tooltip;
  final VoidCallback onTap;
  final List<MenuItem> Function() menu;
  const FileTreeRow({super.key, required this.name, required this.path, required this.depth,
    required this.folder, required this.expanded, required this.loading, required this.selected,
    required this.root, required this.link, this.location, this.detail, this.dimmed = false, this.tooltip,
    required this.onTap, required this.menu});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final type = fileGlyph(name, ide);
    final height = InputMode.row(context) + (root ? 18 : 2);
    final row = ContextArea(items: menu, child: Tooltip(message: tooltip ?? location ?? path, waitDuration: const Duration(milliseconds: 700),
      child: InkWell(onTap: onTap, hoverColor: ide.hover,
        child: Container(height: height, margin: EdgeInsets.only(top: root ? 9 : 0),
          decoration: BoxDecoration(color: selected ? ide.selection : (root ? ide.tabBar.withValues(alpha: 0.7) : null),
            border: Border(left: BorderSide(color: selected ? ide.accent : Colors.transparent, width: 2),
              bottom: BorderSide(color: root ? ide.border : Colors.transparent))),
          child: Stack(children: [
            if (depth > 0) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Guides(depth, ide.border)))),
            Padding(padding: EdgeInsets.only(left: 7 + depth * 18.0, right: 8), child: Row(children: [
              SizedBox(width: 16, child: loading ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                : folder ? Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: ide.textDim) : null),
              const SizedBox(width: 4),
              Stack(clipBehavior: Clip.none, children: [
                Icon(folder ? (expanded ? Icons.folder_open_rounded : Icons.folder_rounded) : type.$1,
                  size: root ? 19 : 16, color: folder ? (root ? ide.accent : const Color(0xFFCFAB63)) : type.$2),
                if (link) Positioned(right: -4, bottom: -3, child: Icon(Icons.link, size: 11, color: ide.accent)),
              ]),
              const SizedBox(width: 7),
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, fontWeight: root ? FontWeight.w600 : FontWeight.w400, color: link ? ide.accent : ide.text)),
                if (root && location != null) Text(location!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: ide.textDim)),
              ])),
              if (detail != null) Padding(padding: const EdgeInsets.only(left: 8), child: Text(detail!, style: TextStyle(fontSize: 10.5, color: ide.textDim, fontFeatures: const [FontFeature.tabularFigures()]))),
            ])),
          ]),
        ),
      ),
    ));
    return dimmed ? Opacity(opacity: 0.45, child: row) : row;
  }
}

(IconData, Color) fileGlyph(String name, Ide ide) {
  final lower = name.toLowerCase(), ext = name.split('.').last.toLowerCase();
  if (lower == 'dockerfile') return (Icons.layers_outlined, const Color(0xFF4DA6DB));
  if (lower.startsWith('.env') || lower.endsWith('.key')) return (Icons.key_outlined, const Color(0xFFC49B45));
  return switch (ext) {
    'dart' || 'go' || 'ts' || 'tsx' => (Icons.code, const Color(0xFF409BB8)),
    'js' || 'jsx' || 'py' => (Icons.code, const Color(0xFFBF9A3B)),
    'rs' || 'c' || 'cpp' || 'h' || 'java' => (Icons.data_object, const Color(0xFFAE7DB6)),
    'json' || 'yml' || 'yaml' || 'toml' || 'ini' || 'conf' => (Icons.tune, const Color(0xFF9B8BBB)),
    'md' || 'txt' || 'rst' => (Icons.description_outlined, ide.textDim),
    'sh' || 'bash' || 'zsh' || 'ps1' => (Icons.terminal, const Color(0xFF61A786)),
    'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' || 'webp' => (Icons.image_outlined, const Color(0xFFB17EA5)),
    'zip' || 'tar' || 'gz' || 'xz' || '7z' => (Icons.inventory_2_outlined, const Color(0xFFB49367)),
    'log' => (Icons.subject, ide.textDim),
    _ => (Icons.insert_drive_file_outlined, ide.textDim),
  };
}

class FileLocation extends StatelessWidget {
  final String root, path;
  const FileLocation({super.key, required this.root, required this.path});
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ide.border))),
      child: Tooltip(message: '$root:$path', child: Text('$root  ›  ${path == '/' ? '/' : path.substring(1).replaceAll('/', '  ›  ')}',
        maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, height: 1.5, color: ide.textDim))));
  }
}

class _Guides extends CustomPainter {
  final int depth;
  final Color color;
  const _Guides(this.depth, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.7)..strokeWidth = 1;
    for (var i = 0; i < depth; i++) {
      final x = 16.0 + i * 18;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }
  @override bool shouldRepaint(_Guides old) => old.depth != depth || old.color != color;
}
