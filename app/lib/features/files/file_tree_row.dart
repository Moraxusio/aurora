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
  static double heightOf(BuildContext context) => math.max(
    InputMode.row(context) + 2,
    MediaQuery.textScalerOf(context).scale(12.5) * 1.3 + 8,
  );
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
    final height = heightOf(context);
    final row = ContextArea(items: menu, child: Tooltip(message: tooltip ?? location ?? path, waitDuration: const Duration(milliseconds: 700),
      // Hover still shows the path; touch long-press belongs to the menu.
      triggerMode: TooltipTriggerMode.manual,
      child: Semantics(selected: selected, expanded: folder ? expanded : null,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Material(
        shape: RoundedRectangleBorder(
          borderRadius: UiMetrics.controlCorners,
          side: dragOver || selected
              ? BorderSide(color: ide.accent.withValues(alpha: dragOver ? .85 : .32))
              : BorderSide.none,
        ),
        color: dragOver ? ide.accentSoft : selected ? ide.selection : active ? ide.hover : Colors.transparent,
        child: InkWell(onTap: tap, borderRadius: UiMetrics.controlCorners, hoverColor: ide.hover, child: SizedBox(height: height - 2,
          child: LayoutBuilder(builder: (context, box) {
            final indent = math.min(depth * 14.0, math.min(84.0, box.maxWidth * .22));
             final wide = box.maxWidth >= _wide;
             final metadata = box.maxWidth >= _details && !InputMode.isTouch(context);
             final style = TextStyle(fontSize: 12.5, fontWeight: root || active ? FontWeight.w600 : FontWeight.w400, color: link ? ide.accent : ide.text);
             return Padding(padding: EdgeInsets.only(left: 6 + indent, right: 10), child: Row(children: [
                SizedBox(width: 20, child: loading ? const Center(child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)))
                  : folder ? InkWell(onTap: onExpand ?? onTap, child: SizedBox(height: height, child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: ide.textDim))) : null),
                Stack(clipBehavior: Clip.none, children: [
                  FileIcon(name: name, folder: folder, expanded: expanded, root: root, size: 16),
                  if (link) Positioned(right: -4, bottom: -3, child: Icon(Icons.link, size: 11, color: ide.accent)),
                ]),
                 const SizedBox(width: 7),
                 Expanded(child: _FileName(name: name, folder: folder, style: style)),
                 if (metadata) ..._detailCells(context, wide: wide, preferModified: preferModified, size: detail, modified: modified),
               ]));
           }),
         )),
       ))),
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

const _details = 330.0, _wide = 450.0;

List<Widget> _detailCells(BuildContext context, {
  required bool wide,
  required bool preferModified,
  required String? size,
  required String? modified,
}) {
  final ide = Ide.of(context);
  Widget cell(String? value, double width) => SizedBox(
    width: width,
    child: Text(
      value ?? '',
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        color: ide.textDim,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
  final dateOnly = !wide && preferModified;
  return [
    const SizedBox(width: 8),
    cell(dateOnly ? modified : size, dateOnly ? 108 : 68),
    if (wide) ...[const SizedBox(width: 14), cell(modified, 108)],
  ];
}

/// Explorer's details header has the same responsive columns as the rows.
class FileTreeHead extends StatelessWidget {
  final String sort;
  final bool descending;
  final ValueChanged<String> onSort;
  const FileTreeHead({super.key, required this.sort, required this.descending, required this.onSort});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final width = box.maxWidth - 8;
    if (width < _details || InputMode.isTouch(context)) return const SizedBox.shrink();
    final ide = Ide.of(context);
    final wide = width >= _wide;
    Widget column(String id, String title, {double? width}) {
      final selected = id == sort;
      final tip = selected
          ? '$title · ${descending ? '降序' : '升序'}，点击改变顺序'
          : '按$title排序';
      return SizedBox(
        width: width,
        child: Tooltip(
          message: tip,
          child: Semantics(
            header: true,
            selected: selected,
            button: true,
            child: InkWell(
              borderRadius: UiMetrics.controlCorners,
              onTap: () => onSort(id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(
                  mainAxisAlignment: width == null ? MainAxisAlignment.start : MainAxisAlignment.end,
                  children: [
                    Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: selected ? ide.text : ide.textDim))),
                    if (selected) Icon(descending ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                      size: 11, color: ide.textDim),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ide.border))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 0, 14, 0),
        child: Row(children: [
          Expanded(child: column('name', '名称')),
          const SizedBox(width: 8),
          if (!wide && sort == 'mtime')
            column('mtime', '修改日期', width: 108)
          else
            column('size', '大小', width: 68),
          if (wide) ...[
            const SizedBox(width: 14),
            column('mtime', '修改日期', width: 108),
          ],
        ]),
      ),
    );
  });
}
