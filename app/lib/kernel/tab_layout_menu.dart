import 'package:flutter/material.dart';
import 'overlays.dart';

import '../theme/ide_theme.dart';
import 'tab_layout.dart';
import 'workspace.dart';

String arrangementLabel(EditorArrangement a) => switch (a) {
  EditorArrangement.single => '单页',
  EditorArrangement.columns => '左右分屏',
  EditorArrangement.rows => '上下分屏',
  EditorArrangement.threeColumns => '三列',
  EditorArrangement.grid => '四宫格',
};
String placementLabel(TabPlacement p) => switch (p) {
  TabPlacement.top => '顶部',
  TabPlacement.bottom => '底部',
  TabPlacement.left => '左侧',
  TabPlacement.right => '右侧',
  TabPlacement.wrap => '多行',
};

class TabLayoutMenu extends StatelessWidget {
  final Workspace ws;
  const TabLayoutMenu({super.key, required this.ws});
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '布局',
    padding: EdgeInsets.zero,
    iconSize: 17,
    onPressed: () => showTabLayoutDialog(context, ws),
    icon: const Icon(Icons.space_dashboard_outlined),
  );
}

Future<void> showTabLayoutDialog(
  BuildContext context,
  Workspace ws,
) => showWorkbenchDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: Listenable.merge([ws, ws.geometryRevision]),
    builder: (context, _) {
      final ide = Ide.of(context);
      return AlertDialog(
        title: const Text('布局'),
        content: SizedBox(
          width: 370,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('分屏', style: TextStyle(fontSize: 12, color: ide.textDim)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final a in EditorArrangement.values)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(7),
                            onTap: () {
                              ws.arrangeEditors(a);
                              Navigator.pop(context);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Column(
                                children: [
                                  CustomPaint(
                                    size: const Size(34, 25),
                                    painter: _LayoutGlyph(a, ide.textDim),
                                  ),
                                  const SizedBox(height: 9),
                                  Text(
                                    arrangementLabel(a),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: ide.text,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Divider(color: ide.border),
                const SizedBox(height: 12),
                Text('标签栏', style: TextStyle(fontSize: 12, color: ide.textDim)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in TabPlacement.values)
                      ChoiceChip(
                        label: Text(placementLabel(p)),
                        selected: ws.tabLayout.placement == p,
                        onSelected: (_) {
                          ws.setTabPlacement(p);
                          Navigator.pop(context);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: Text(
                    '标签宽度',
                    style: TextStyle(fontSize: 12, color: ide.textDim),
                  ),
                  children: [
                    // Keep the value-indicator portal in this scroll subtree.
                    Overlay.wrap(alwaysSizeToContent: true, clipBehavior: Clip.none, child: Slider(
                      value: ws.tabLayout.tabWidth,
                      min: 100,
                      max: 260,
                      divisions: 32,
                      label: '${ws.tabLayout.tabWidth.round()} px',
                      semanticFormatterCallback: (value) => '${value.round()} px',
                      onChanged: ws.setTabWidth,
                    )),
                    Row(
                      children: [
                        Text(
                          '${ws.tabLayout.tabWidth.round()} px',
                          style: TextStyle(fontSize: 11, color: ide.textFaint),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            ws.setSideWidth(300);
                            ws.setTabsWidth(180);
                            ws.setTabWidth(160);
                          },
                          child: const Text('恢复默认宽度'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      );
    },
  ),
);

class _LayoutGlyph extends CustomPainter {
  final EditorArrangement arrangement;
  final Color color;
  const _LayoutGlyph(this.arrangement, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(1),
        const Radius.circular(3),
      ),
      paint,
    );
    if (arrangement == EditorArrangement.columns ||
        arrangement == EditorArrangement.grid) {
      canvas.drawLine(
        Offset(size.width / 2, 1),
        Offset(size.width / 2, size.height - 1),
        paint,
      );
    }
    if (arrangement == EditorArrangement.rows ||
        arrangement == EditorArrangement.grid) {
      canvas.drawLine(
        Offset(1, size.height / 2),
        Offset(size.width - 1, size.height / 2),
        paint,
      );
    }
    if (arrangement == EditorArrangement.threeColumns) {
      for (final fraction in [1 / 3, 2 / 3]) {
        canvas.drawLine(
          Offset(size.width * fraction, 1),
          Offset(size.width * fraction, size.height - 1),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LayoutGlyph old) =>
      old.arrangement != arrangement || old.color != color;
}
