// The card that asks the user before the agent edits a file or runs a command.
// It shows what is about to happen (the patch, or the command and its folder),
// says in Chinese why it is being asked, and says what "allow for this session"
// would cover, so the choice is made on facts and not on a file name.
import 'package:flutter/material.dart';

import '../../kernel/widgets.dart';
import '../../theme/ide_theme.dart';
import '../git/diff_view.dart'
    show DiffLine, DiffLineKind, parseDiff, withoutFileHeader;
import 'ai_models.dart';

/// The patch an edit or write is about to apply, from the question's metadata
/// (the agent puts a FileDiff there: file, additions, deletions, patch).
class PermissionPatch {
  final String file;
  final int additions, deletions;
  final String status;
  final List<DiffLine> lines;
  const PermissionPatch({
    required this.file,
    required this.additions,
    required this.deletions,
    required this.status,
    required this.lines,
  });

  static PermissionPatch? of(AiPermissionQuestion q) {
    final raw = q.metadata['diff'];
    if (raw is! Map) return null;
    final patch = raw['patch'] as String? ?? '';
    if (patch.trim().isEmpty) return null;
    return PermissionPatch(
      file: raw['file'] as String? ?? q.resource,
      additions: (raw['additions'] as num?)?.toInt() ?? 0,
      deletions: (raw['deletions'] as num?)?.toInt() ?? 0,
      status: raw['status'] as String? ?? 'modified',
      lines: withoutFileHeader(parseDiff(patch)),
    );
  }
}

/// A short line saying what is being asked, by action.
String permissionTitle(AiPermissionQuestion q) => switch (q.action) {
  'edit' => '修改文件',
  'write' => '写入文件',
  'shell' => '执行命令',
  'webfetch' => '访问网页',
  'websearch' => '联网搜索',
  'subagent' => '启动子代理',
  'read' => '读取文件',
  'doom_loop' => '重复调用',
  _ => '执行 ${q.tool}',
};

class AiPermissionCard extends StatelessWidget {
  final AiPermissionQuestion question;

  /// The folder a command runs in, shown with it.
  final String workdir;

  /// Compact cards are used by the fixed approval dock above the composer.
  /// The full diff remains available in the transcript history, while the
  /// decision and its scope stay visible without consuming the conversation
  /// viewport.
  final bool compact;
  final bool busy;
  final bool showActions;
  final VoidCallback? onDetails;
  final void Function({required bool allow, bool always}) onDecide;
  const AiPermissionCard({
    super.key,
    required this.question,
    required this.workdir,
    this.compact = false,
    this.busy = false,
    this.showActions = true,
    this.onDetails,
    required this.onDecide,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context), q = question;
    final patch = PermissionPatch.of(q);
    final folder = q.metadata['workdir'] as String? ?? workdir;
    if (compact) return _buildCompact(ide, q, patch, folder);
    return Container(
      key: const ValueKey('ai-permission-card'),
      padding: compact
          ? const EdgeInsets.all(Space.s)
          : const EdgeInsets.all(Space.l),
      decoration: BoxDecoration(
        color: ide.warn.withValues(alpha: ide.isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(Radii.l + 2),
        border: Border.all(color: ide.warn.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: ide.warn),
              const SizedBox(width: Space.s + 2),
              // The title keeps its old wording: "需要授权执行 edit" is what tests and
              // users already know the card by.
              Expanded(
                child: Text(
                  compact ? '需要批准 · ${permissionTitle(q)}' : '需要授权执行 ${q.tool}',
                  style: TextStyle(
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w600,
                    color: ide.text,
                  ),
                ),
              ),
              if (patch != null)
                Text(
                  '+${patch.additions}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: ide.ok,
                  ),
                ),
              if (patch != null) ...[
                const SizedBox(width: 5),
                Text(
                  '-${patch.deletions}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: ide.error,
                  ),
                ),
              ],
            ],
          ),
          if (q.reasonText.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              q.reasonText,
              key: const ValueKey('ai-permission-reason'),
              maxLines: compact ? 1 : null,
              overflow: compact ? TextOverflow.ellipsis : null,
              style: TextStyle(fontSize: 12, color: ide.textDim, height: 1.4),
            ),
          ],
          const SizedBox(height: Space.s),
          if (q.action == 'shell')
            _Box(
              footer: folder.isEmpty ? null : '在 $folder 中运行',
              child: SelectableText('\$ ${q.resource}', style: _mono(ide)),
            )
          else if (patch != null && !compact)
            _PatchBox(
              patch: patch,
              label: patch.status == 'added' ? '新建 ${patch.file}' : patch.file,
            )
          else
            _Box(
              child: compact
                  ? Text(
                      q.resource,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _mono(ide),
                    )
                  : SelectableText(q.resource, style: _mono(ide)),
            ),
          if (compact && patch != null) ...[
            const SizedBox(height: 5),
            Text(
              '改动 ${patch.file} · +${patch.additions} / -${patch.deletions} · 点击对话中的改动卡查看完整 diff',
              style: TextStyle(fontSize: 11, color: ide.textDim),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: Space.m),
          if (!compact)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: ide.textFaint),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      q.alwaysLabel,
                      style: TextStyle(fontSize: 11, color: ide.textDim),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (showActions)
            Wrap(
              spacing: Space.s,
              runSpacing: Space.s,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: const ValueKey('ai-deny'),
                  onPressed: busy ? null : () => onDecide(allow: false),
                  child: Text('拒绝', style: TextStyle(color: ide.error)),
                ),
                Tooltip(
                  message: q.action == 'edit' || q.action == 'write'
                      ? (q.scope.isEmpty
                            ? '之后本会话里 AI 修改任何文件都不再询问；新对话仍会询问'
                            : '之后本会话里 ${q.alwaysLabel}；新对话仍会询问')
                      : q.action == 'shell'
                      ? '之后本会话里同一个命令开头的命令不再询问；新对话仍会询问'
                      : '之后本会话里这类操作不再询问；新对话仍会询问',
                  child: OutlinedButton(
                    key: const ValueKey('ai-approve-always'),
                    onPressed: busy
                        ? null
                        : () => onDecide(allow: true, always: true),
                    child: const Text('始终允许'),
                  ),
                ),
                FilledButton(
                  key: const ValueKey('ai-approve-once'),
                  onPressed: busy ? null : () => onDecide(allow: true),
                  child: Text(busy ? '提交中…' : '允许本次'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildCompact(
    Ide ide,
    AiPermissionQuestion q,
    PermissionPatch? patch,
    String folder,
  ) => Container(
    key: const ValueKey('ai-permission-card'),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.shield_outlined, size: 15, color: ide.warn),
            const SizedBox(width: 5),
            Expanded(
              child: Tooltip(
                message: '${q.resource}\n${q.reasonText}',
                child: Text(
                  '${permissionTitle(q)} · ${q.resource}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ide.text,
                  ),
                ),
              ),
            ),
            if (onDetails != null)
              TextButton(
                key: const ValueKey('ai-permission-details'),
                onPressed: onDetails,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 26),
                ),
                child: const Text('详情', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('ai-deny'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 25),
                padding: const EdgeInsets.symmetric(horizontal: 5),
              ),
              onPressed: busy ? null : () => onDecide(allow: false),
              child: Text(
                '拒绝',
                style: TextStyle(fontSize: 10.5, color: ide.error),
              ),
            ),
            Tooltip(
              message: q.alwaysLabel,
              child: OutlinedButton(
                key: const ValueKey('ai-approve-always'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 25),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                ),
                onPressed: busy
                    ? null
                    : () => onDecide(allow: true, always: true),
                child: const Text('本会话允许', style: TextStyle(fontSize: 10.5)),
              ),
            ),
            const SizedBox(width: 3),
            FilledButton(
              key: const ValueKey('ai-approve-once'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 25),
                padding: const EdgeInsets.symmetric(horizontal: 7),
              ),
              onPressed: busy ? null : () => onDecide(allow: true),
              child: Text(
                busy ? '提交中…' : '允许本次',
                style: const TextStyle(fontSize: 10.5),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

TextStyle _mono(Ide ide) => TextStyle(
  fontFamily: Ide.mono,
  fontFamilyFallback: Ide.monoFallback,
  fontSize: 12,
  color: ide.text,
  height: 1.4,
);

class _Box extends StatelessWidget {
  final Widget child;
  final String? footer;
  const _Box({required this.child, this.footer});
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.s + 2),
      decoration: BoxDecoration(
        color: ide.editor,
        borderRadius: BorderRadius.circular(Radii.m),
        border: Border.all(color: ide.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          if (footer != null) ...[
            const SizedBox(height: 4),
            Text(footer!, style: TextStyle(fontSize: 11, color: ide.textFaint)),
          ],
        ],
      ),
    );
  }
}

/// The changed lines, at most a screenful: the whole patch is in the step card
/// once it is applied. Long lines scroll sideways inside the box.
class _PatchBox extends StatefulWidget {
  final PermissionPatch patch;
  final String label;
  const _PatchBox({required this.patch, required this.label});
  @override
  State<_PatchBox> createState() => _PatchBoxState();
}

class _PatchBoxState extends State<_PatchBox> {
  bool _all = false;
  static const _collapsed = 14;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final lines = widget.patch.lines;
    final shown = _all || lines.length <= _collapsed
        ? lines
        : lines.take(_collapsed).toList();
    return Container(
      key: const ValueKey('ai-permission-patch'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: ide.editor,
        borderRadius: BorderRadius.circular(Radii.m),
        border: Border.all(color: ide.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.s + 2, 6, Space.s, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Ide.mono,
                      fontFamilyFallback: Ide.monoFallback,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ide.text,
                    ),
                  ),
                ),
                IconBtn(
                  Icons.copy_outlined,
                  '复制改动',
                  () => copyText(
                    lines
                        .where((l) => l.kind != DiffLineKind.meta)
                        .map(_plain)
                        .join('\n'),
                    what: '改动已复制',
                  ),
                  size: 14,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: ide.border),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _all ? 360 : 260),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: 0),
                child: SingleChildScrollView(
                  child: IntrinsicWidth(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final l in shown) _Line(l)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (lines.length > _collapsed)
            InkWell(
              onTap: () => setState(() => _all = !_all),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Center(
                  child: Text(
                    _all ? '收起' : '显示全部 ${lines.length} 行',
                    style: TextStyle(fontSize: 11.5, color: ide.accent),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _plain(DiffLine l) => switch (l.kind) {
    DiffLineKind.add => '+${l.text}',
    DiffLineKind.del => '-${l.text}',
    DiffLineKind.hunk => l.text,
    _ => ' ${l.text}',
  };
}

class _Line extends StatelessWidget {
  final DiffLine line;
  const _Line(this.line);
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final (bg, fg, sign) = switch (line.kind) {
      DiffLineKind.add => (ide.addBg, ide.addText, '+'),
      DiffLineKind.del => (ide.delBg, ide.delText, '-'),
      DiffLineKind.hunk => (
        ide.selection.withValues(alpha: 0.35),
        ide.accent,
        ' ',
      ),
      DiffLineKind.meta => (null, ide.textDim, ' '),
      DiffLineKind.context => (null, ide.text, ' '),
    };
    final style = TextStyle(
      fontFamily: Ide.mono,
      fontFamilyFallback: Ide.monoFallback,
      fontSize: 12,
      height: 1.4,
      color: fg,
    );
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 38,
            child: Text(
              '${line.newNo ?? line.oldNo ?? ''}',
              textAlign: TextAlign.right,
              style: style.copyWith(color: ide.textFaint),
            ),
          ),
          SizedBox(
            width: 16,
            child: Text(sign, textAlign: TextAlign.center, style: style),
          ),
          Text(
            line.text.isEmpty ? ' ' : line.text,
            softWrap: false,
            style: style,
          ),
        ],
      ),
    );
  }
}
