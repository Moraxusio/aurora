// The rendered view next to the editor for Markdown and CSV/TSV files. It
// draws the editor's current text, so it follows unsaved edits and never reads
// the file again.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../kernel/widgets.dart';
import '../../theme/ide_theme.dart';
import 'csv_parse.dart';

class MarkdownPreview extends StatelessWidget {
  final String text;
  const MarkdownPreview({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final base = Theme.of(context);
    final style = MarkdownStyleSheet.fromTheme(base).copyWith(
      p: TextStyle(color: ide.text, fontSize: 14, height: 1.6),
      code: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 13, backgroundColor: ide.hover, color: ide.text),
      codeblockDecoration: BoxDecoration(color: ide.sideBar, borderRadius: BorderRadius.circular(4)),
      blockquoteDecoration: BoxDecoration(color: ide.hover.withValues(alpha: 0.4), border: Border(left: BorderSide(color: ide.accent, width: 3))),
      a: TextStyle(color: ide.accent),
      tableBorder: TableBorder.all(color: ide.textDim.withValues(alpha: 0.4)),
    );
    return ColoredBox(
      color: ide.editor,
      child: Markdown(
        data: text,
        selectable: true,
        padding: const EdgeInsets.all(20),
        styleSheet: style,
        // Opening a file must not send a request: pictures are not fetched,
        // they show their description.
        imageBuilder: (uri, title, alt) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('[图片未加载${alt == null || alt.isEmpty ? '' : '：$alt'}]', style: TextStyle(color: ide.textDim, fontStyle: FontStyle.italic)),
        ),
        // Links are not followed; the address is copied so the user decides.
        onTapLink: (text, href, title) {
          if (href == null) return;
          Clipboard.setData(ClipboardData(text: href));
          Toast.show('链接已复制（不会自动打开）');
        },
      ),
    );
  }
}

class CsvPreview extends StatelessWidget {
  final String text;
  final bool tabSeparated;
  const CsvPreview({super.key, required this.text, required this.tabSeparated});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final t = parseCsv(text, delimiter: tabSeparated ? '\t' : null);
    if (t.rows.isEmpty) return const EmptyHint(icon: Icons.table_chart_outlined, text: '空文件');
    final head = t.rows.first;
    final body = t.rows.skip(1).toList();
    final cols = t.columns;
    List<String> pad(List<String> r) => r.length >= cols ? r : [...r, ...List.filled(cols - r.length, '')];
    Widget cell(String s, {bool header = false, int? n}) => Container(
          width: 160,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(color: header ? ide.sideBar : null, border: Border(right: BorderSide(color: ide.hover), bottom: BorderSide(color: ide.hover))),
          child: Text(s, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: header ? ide.text : ide.text, fontSize: 12.5, fontWeight: header ? FontWeight.w600 : FontWeight.normal)),
        );
    return ColoredBox(
      color: ide.editor,
      child: Column(children: [
        Container(
          height: 26,
          color: ide.tabBar,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('${body.length} 行 · $cols 列${t.truncated ? '（只显示前 ${t.rows.length} 行）' : ''}', style: TextStyle(color: ide.textDim, fontSize: 12)),
        ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: cols * 160.0,
                child: Column(children: [
                  Row(children: [for (final h in pad(head)) cell(h, header: true)]),
                  Expanded(
                    child: ListView.builder(
                      itemCount: body.length,
                      itemExtent: 52,
                      itemBuilder: (_, i) => Row(children: [for (final c in pad(body[i])) cell(c)]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
