import 'package:aurora/ui/aurora_ui.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';

import '../../kernel/input_mode.dart';
import '../../theme/ide_theme.dart';
import 'file_icons.dart';

export 'file_icons.dart' show FileIcon, FileIconSpec, fileGlyph, fileIconSpec, folderGlyph;

/// File-specific visual hierarchy; other service lists keep their compact rows.
class FileTreeRow extends StatefulWidget {
  final String name, path;
  final int depth;
  final bool folder, expanded, loading, selected, root, link;
  final String? location, detail;
  final String? modified;
  final bool active, preferModified, dragOver;
  final VoidCallback? onExpand;

  /// Cut rows are drawn faint until they are pasted or the cut is cancelled.
  final bool dimmed;

  /// Replaces the path in the hover tooltip (size, time, permissions).
  final String? tooltip;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final List<MenuItem> Function() menu;
  const FileTreeRow({super.key, required this.name, required this.path, required this.depth,
    required this.folder, required this.expanded, required this.loading, required this.selected,
    required this.root, required this.link, this.location, this.detail, this.modified, this.active = false, this.preferModified = false, this.dragOver = false, this.onExpand, this.dimmed = false, this.tooltip,
    required this.onTap, this.onDoubleTap, required this.menu});

  @override
  State<FileTreeRow> createState() => _FileTreeRowState();

  Widget _build(BuildContext context, VoidCallback tap) {
    final ide = Ide.of(context);
    final height = InputMode.row(context) + 2;
    final row = ContextArea(items: menu, child: Tooltip(message: tooltip ?? location ?? path, waitDuration: const Duration(milliseconds: 700),
      child: Semantics(selected: selected || active, expanded: folder ? expanded : null, child: Material(
        color: dragOver ? ide.accentSoft : selected ? ide.selection : active ? ide.hover : Colors.transparent,
        child: InkWell(onTap: tap, hoverColor: ide.hover, child: SizedBox(height: height,
          child: LayoutBuilder(builder: (context, box) {
            final indent = math.min(depth * 14.0, math.min(84.0, box.maxWidth * .22));
            final wide = box.maxWidth >= 460;
            final metadata = box.maxWidth >= 300;
            final style = TextStyle(fontSize: 12.5, fontWeight: root || active ? FontWeight.w600 : FontWeight.w400, color: link ? ide.accent : ide.text);
            Widget cell(String? value, double width) => SizedBox(width: width, child: Text(value ?? '', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: ide.textFaint, fontFeatures: const [FontFeature.tabularFigures()])));
            return Stack(children: [
              if (depth > 0) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Guides(indent, ide.border)))),
              if (selected || active || dragOver) Positioned(left: 0, top: 0, bottom: 0, width: 2, child: ColoredBox(color: selected || dragOver ? ide.accent : ide.textDim)),
              Padding(padding: EdgeInsets.only(left: 6 + indent, right: 10), child: Row(children: [
                SizedBox(width: 20, child: loading ? const Center(child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)))
                  : folder ? InkWell(onTap: onExpand ?? onTap, child: SizedBox(height: height, child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: ide.textDim))) : null),
                Stack(clipBehavior: Clip.none, children: [
                  FileIcon(name: name, folder: folder, expanded: expanded, root: root, size: 16),
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

class _FileTreeRowState extends State<FileTreeRow> {
  static int _pointerSequence = 0;
  PointerDownEvent? _press, _lastClick;
  int _pressSequence = 0, _clickSequence = -1;
  Timer? _doubleClickWindow;

  void _tap() {
    final press = _press, previous = _lastClick;
    _press = null;
    final second = widget.onDoubleTap != null && press != null && previous != null &&
        _pressSequence == _clickSequence + 1 &&
        press.kind == previous.kind &&
        (press.position - previous.position).distance <= kDoubleTapSlop;
    _doubleClickWindow?.cancel();
    _lastClick = second ? null : press;
    _clickSequence = _pressSequence;
    if (widget.onDoubleTap != null && _lastClick != null) {
      _doubleClickWindow = Timer(kDoubleTapTimeout, () => _lastClick = null);
    }
    (second ? widget.onDoubleTap! : widget.onTap)();
  }

  @override
  void dispose() {
    _doubleClickWindow?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      _pressSequence = ++_pointerSequence;
      _press = event.buttons == kPrimaryButton ? event : null;
    },
    onPointerCancel: (_) => _press = null,
    child: widget._build(context, _tap),
  );
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
