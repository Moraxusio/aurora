import 'package:flutter/material.dart';

import '../../theme/ide_theme.dart';
import '../../theme/workbench_tokens.dart';

/// Shared visual vocabulary for conversations, work, history and model settings.
abstract final class AiVisuals {
  static const radius = UiMetrics.surfaceCorners;
  static BoxDecoration surface(Ide ide, {bool selected = false, Color? edge}) =>
      BoxDecoration(
        color: selected ? ide.accentSoft : ide.sideBar,
        borderRadius: radius,
        border: Border.all(
          color:
              edge ??
              (selected ? ide.accent.withValues(alpha: .45) : ide.border),
        ),
      );
}

class AiSectionHeading extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const AiSectionHeading({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: AiVisuals.surface(ide),
            child: Icon(icon, size: 16, color: ide.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ide.text,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: ide.textDim,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

enum AiWorkStatus { running, completed, error, interrupted }

class AiStatusMark extends StatelessWidget {
  final AiWorkStatus status;
  final bool label;
  const AiStatusMark(this.status, {super.key, this.label = true});
  static String text(AiWorkStatus status) => switch (status) {
    AiWorkStatus.running => '运行中',
    AiWorkStatus.completed => '已完成',
    AiWorkStatus.error => '失败',
    AiWorkStatus.interrupted => '未确认',
  };
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final color = switch (status) {
      AiWorkStatus.running => ide.accent,
      AiWorkStatus.completed => ide.ok,
      AiWorkStatus.error => ide.error,
      AiWorkStatus.interrupted => ide.textDim,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          switch (status) {
            AiWorkStatus.running => Icons.pending_outlined,
            AiWorkStatus.completed => Icons.check_circle_outline,
            AiWorkStatus.error => Icons.error_outline,
            AiWorkStatus.interrupted => Icons.pause_circle_outline,
          },
          size: 14,
          color: color,
        ),
        if (label) ...[
          const SizedBox(width: 4),
          Text(text(status), style: TextStyle(fontSize: 11, color: color)),
        ],
      ],
    );
  }
}
