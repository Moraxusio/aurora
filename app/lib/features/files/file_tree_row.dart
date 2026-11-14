import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../../kernel/input_mode.dart';
import '../../kernel/widgets.dart';
import '../../theme/ide_theme.dart';

/// File-specific visual hierarchy; other service lists keep their compact rows.
class FileTreeRow extends StatelessWidget {
  final String name, path;
  final int depth;
  final bool folder, expanded, loading, selected, root, link;
  final String? location, detail;
  final String? modified;
  final bool active, preferModified;
  final VoidCallback? onExpand;

  /// Cut rows are drawn faint until they are pasted or the cut is cancelled.
  final bool dimmed;

  /// Replaces the path in the hover tooltip (size, time, permissions).
  final String? tooltip;
  final VoidCallback onTap;
  final List<MenuItem> Function() menu;
  const FileTreeRow({super.key, required this.name, required this.path, required this.depth,
    required this.folder, required this.expanded, required this.loading, required this.selected,
    required this.root, required this.link, this.location, this.detail, this.modified, this.active = false, this.preferModified = false, this.onExpand, this.dimmed = false, this.tooltip,
    required this.onTap, required this.menu});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final type = fileGlyph(name, ide);
    final height = InputMode.row(context) + 2;
    final row = ContextArea(items: menu, child: Tooltip(message: tooltip ?? location ?? path, waitDuration: const Duration(milliseconds: 700),
      child: Semantics(selected: selected || active, expanded: folder ? expanded : null, child: Material(
        color: selected ? ide.selection : active ? ide.hover : Colors.transparent,
        child: InkWell(onTap: onTap, hoverColor: ide.hover, child: SizedBox(height: height,
          child: LayoutBuilder(builder: (context, box) {
            final indent = math.min(depth * 14.0, math.min(84.0, box.maxWidth * .22));
            final wide = box.maxWidth >= 460;
            final metadata = box.maxWidth >= 300;
            final style = TextStyle(fontSize: 12.5, fontWeight: root || active ? FontWeight.w600 : FontWeight.w400, color: link ? ide.accent : ide.text);
            Widget cell(String? value, double width) => SizedBox(width: width, child: Text(value ?? '', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: ide.textFaint, fontFeatures: const [FontFeature.tabularFigures()])));
            return Stack(children: [
              if (depth > 0) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Guides(indent, ide.border)))),
              if (selected || active) Positioned(left: 0, top: 0, bottom: 0, width: 2, child: ColoredBox(color: selected ? ide.accent : ide.textDim)),
              Padding(padding: EdgeInsets.only(left: 6 + indent, right: 10), child: Row(children: [
                SizedBox(width: 20, child: loading ? const Center(child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)))
                  : folder ? InkWell(onTap: onExpand ?? onTap, child: SizedBox(height: height, child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: ide.textDim))) : null),
                Stack(clipBehavior: Clip.none, children: [
                  Icon(folder ? (expanded ? Icons.folder_open_rounded : Icons.folder_rounded) : type.$1,
                    size: 16, color: folder ? (root ? ide.accent : const Color(0xFFCFAB63)) : type.$2),
                  if (link) Positioned(right: -4, bottom: -3, child: Icon(Icons.link, size: 11, color: ide.accent)),
                ]),
                const SizedBox(width: 7),
                Expanded(child: _FileName(name: name, folder: folder, style: style)),
                if (metadata) ...[const SizedBox(width: 8), cell(!wide && preferModified ? modified : detail, !wide && preferModified ? 102 : 64)],
                if (wide) ...[const SizedBox(width: 14), cell(modified, 102)],
              ])),
            ]);
          }),
        )),
      )),
    ));
    return dimmed ? Opacity(opacity: 0.45, child: row) : row;
  }
}

/// Keep the extension visible when the stem has to be shortened. Short names
/// stay a single Text so accessibility and ordinary row interactions stay simple.
class _FileName extends StatelessWidget {
  final String name;
  final bool folder;
  final TextStyle style;
  const _FileName({required this.name, required this.folder, required this.style});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final dot = name.lastIndexOf('.');
    final painter = TextPainter(text: TextSpan(text: name, style: DefaultTextStyle.of(context).style.merge(style)), textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context), maxLines: 1)..layout();
    final shorten = !folder && dot > 0 && name.length-dot <= 12 && painter.width > box.maxWidth && box.maxWidth >= 70;
    painter.dispose();
    if (!shorten) return Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    return Semantics(label: name, excludeSemantics: true, child: Row(children: [
      Expanded(child: Text(name.substring(0, dot), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
      ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * .45), child: Text(name.substring(dot), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
    ]));
  });
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
  final double indent;
  final Color color;
  const _Guides(this.indent, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.7)..strokeWidth = 1;
    for (var i = 0; i < (indent / 14).ceil(); i++) {
      final x = 15.0 + i * 14;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }
  @override bool shouldRepaint(_Guides old) => old.indent != indent || old.color != color;
}
