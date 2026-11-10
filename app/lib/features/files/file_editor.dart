// A text file open in an editor tab (re_editor): line numbers, syntax colours,
// find and replace, undo. What keeps it safe:
//  - the text is saved only while the file's etag on the server is still the
//    one it was read with (fs.write if_match), so another program's edit is
//    refused and shown, never overwritten;
//  - a file that is not UTF-8, or too big for one frame, is not opened as
//    text at all, so saving cannot damage bytes the editor never showed;
//  - closing with unsaved changes asks.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:re_highlight/styles/vs2015.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'file_kind.dart';
import 'file_preview.dart';
import 'file_viewers.dart';

/// The highlighter language for a file name, or null for plain text.
({String name, CodeHighlightThemeMode mode})? languageFor(String file) {
  final base = file.split('/').last.toLowerCase();
  final dot = base.lastIndexOf('.');
  final ext = dot < 0 ? '' : base.substring(dot + 1);
  CodeHighlightThemeMode m(mode) => CodeHighlightThemeMode(mode: mode);
  if (base == 'dockerfile' || base.startsWith('dockerfile.')) return (name: 'dockerfile', mode: m(langDockerfile));
  if (base == 'makefile' || base == 'gnumakefile' || ext == 'mk') return (name: 'makefile', mode: m(langMakefile));
  if (base == 'nginx.conf' || (ext == 'conf' && file.contains('nginx'))) return (name: 'nginx', mode: m(langNginx));
  if (const {'.bashrc', '.profile', '.bash_profile', '.zshrc', '.bash_aliases'}.contains(base)) return (name: 'bash', mode: m(langBash));
  return switch (ext) {
    'sh' || 'bash' || 'zsh' || 'env' => (name: 'bash', mode: m(langBash)),
    'py' || 'pyw' => (name: 'python', mode: m(langPython)),
    'go' => (name: 'go', mode: m(langGo)),
    'js' || 'mjs' || 'cjs' || 'jsx' => (name: 'javascript', mode: m(langJavascript)),
    'ts' || 'tsx' => (name: 'typescript', mode: m(langTypescript)),
    'json' || 'jsonc' => (name: 'json', mode: m(langJson)),
    'yml' || 'yaml' => (name: 'yaml', mode: m(langYaml)),
    'md' || 'markdown' => (name: 'markdown', mode: m(langMarkdown)),
    'html' || 'htm' || 'xml' || 'svg' || 'xhtml' => (name: 'xml', mode: m(langXml)),
    'css' || 'scss' => (name: 'css', mode: m(langCss)),
    'sql' => (name: 'sql', mode: m(langSql)),
    'ini' || 'cfg' || 'toml' || 'service' || 'timer' || 'socket' || 'desktop' => (name: 'ini', mode: m(langIni)),
    'conf' || 'properties' => (name: 'properties', mode: m(langProperties)),
    'c' || 'h' => (name: 'c', mode: m(langC)),
    'cc' || 'cpp' || 'cxx' || 'hpp' || 'hh' => (name: 'cpp', mode: m(langCpp)),
    'java' => (name: 'java', mode: m(langJava)),
    'rs' => (name: 'rust', mode: m(langRust)),
    'diff' || 'patch' => (name: 'diff', mode: m(langDiff)),
    _ => null,
  };
}

/// The tab for [path] under [root]. The editor's state is reached through a
/// key so closing the tab can ask about unsaved changes.
EditorTab fileEditorTab(Workspace ws, {required String root, required String path, int? line}) {
  path = WorkspacePath.normalize(path);
  final id = 'file:$root:$path';
  final title = path.split('/').last;
  final file = WorkspacePath(root: root, path: path);
  // Not text: a viewer of its own, no editing, nothing to save or discard.
  final kind = kindOf(path);
  if (kind != FileKind.text) {
    final (icon, view) = switch (kind) {
      FileKind.image => (Icons.image_outlined, ImageViewer(ws: ws, root: root, path: path) as Widget),
      FileKind.pdf => (Icons.picture_as_pdf_outlined, PdfFileViewer(ws: ws, root: root, path: path)),
      FileKind.video => (Icons.movie_outlined, MediaUnsupported(ws: ws, root: root, path: path, kind: kind)),
      _ => (Icons.audiotrack_outlined, MediaUnsupported(ws: ws, root: root, path: path, kind: kind)),
    };
    return EditorTab(id: id, title: title, icon: icon, tooltip: path, builder: (_) => view, file: file);
  }
  final key = GlobalKey<FileEditorState>();
  final view = FileEditor(key: key, ws: ws, root: root, path: path, line: line);
  final tab = EditorTab(id: id, title: title, icon: Icons.description_outlined, tooltip: path, builder: (_) => view, file: file);
  tab.confirmClose = () async {
    final st = key.currentState;
    if (st == null || !st.dirty) return true;
    return st.askDiscard();
  };
  return tab;
}
class FileEditor extends StatefulWidget {
  final Workspace ws;
  final String root;
  final String path;
  final int? line;
  const FileEditor({super.key, required this.ws, required this.root, required this.path, this.line});

  @override
  State<FileEditor> createState() => FileEditorState();
}

enum _Phase { loading, ready, refused, failed }

class FileEditorState extends State<FileEditor> {
  final _controller = CodeLineEditingController();
  _Phase _phase = _Phase.loading;
  String _message = '';
  String? _etag;
  String _saved = '';
  bool _saving = false;
  final bool _readOnly = false; // a later step: open read-only (e.g. a file the user cannot write)
  String? _langName;
  bool _preview = false;

  bool get dirty => _phase == _Phase.ready && !_readOnly && _controller.text != _saved;

  /// The editor's text (tests).
  @visibleForTesting
  String get text => _controller.text;

  @visibleForTesting
  set text(String v) => _controller.text = v;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    final t = widget.ws.tab('file:${widget.root}:${widget.path}');
    if (t != null) {
      t.dirty.value = dirty;
      final sel = _controller.selection;
      t.status.value = 'Ln ${sel.extentIndex + 1}, Col ${sel.extentOffset + 1}${_langName == null ? '' : '   $_langName'}${_readOnly ? '   只读' : ''}';
    }
  }

  Future<void> _load() async {
    final link = widget.ws.link;
    if (link == null) {
      setState(() {
        _phase = _Phase.failed;
        _message = '未连接';
      });
      return;
    }
    try {
      final r = (await link.call('fs.read', {'root': widget.root, 'path': widget.path}) as Map).cast<String, dynamic>();
      if (!mounted) return;
      if (r['binary'] == true) {
        return setState(() {
          _phase = _Phase.refused;
          _message = '这个文件不是 UTF-8 文本（二进制，或 GBK 等其它编码），不能在这里编辑。\n用 Aurora 下载后，在本机用合适的工具打开。';
        });
      }
      if (r['truncated'] == true) {
        return setState(() {
          _phase = _Phase.refused;
          _message = '文件有 ${formatSize((r['size'] as num?) ?? 0)}，超过在线编辑的上限（512 KB）。\n要看日志的末尾，请用终端的 tail，或到“日志”里查看。';
        });
      }
      final text = r['content'] as String? ?? '';
      _etag = r['etag'] as String?;
      _saved = text;
      _controller.text = text;
      _controller.clearHistory();
      _langName = languageFor(widget.path)?.name;
      setState(() => _phase = _Phase.ready);
      _onChanged();
      final line = widget.line;
      if (line != null && line > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _controller.selection = CodeLineSelection.collapsed(index: (line - 1).clamp(0, _controller.codeLines.length - 1), offset: 0);
        });
      }
    } on OpError catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _message = e.message;
        });
      }
    }
  }

  Future<void> save() async {
    if (_phase != _Phase.ready || _readOnly || _saving) return;
    final link = widget.ws.link;
    if (link == null) return widget.ws.toast('未连接，没有保存', error: true);
    final text = _controller.text;
    String? conflict;
    setState(() => _saving = true);
    try {
      final r = (await link.call('fs.write', {'root': widget.root, 'path': widget.path, 'content': text, 'if_match': _etag}) as Map).cast<String, dynamic>();
      _etag = r['etag'] as String? ?? _etag;
      _saved = text;
      widget.ws.toast('已保存 ${widget.path.split('/').last}');
      widget.ws.filesRevision.value++; // the tree's size and time for this file
    } on OpError catch (e) {
      if (e.code == codeConflict) {
        conflict = e.message;
      } else {
        widget.ws.toast(e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
      _onChanged();
    }
    // Asked after _saving is cleared: "overwrite" saves again, and a save that
    // starts while one is still marked as running does nothing.
    if (conflict != null && mounted) await _conflict(conflict);
  }

  /// The file changed on the server after it was opened. Nothing is lost:
  /// the editor keeps the user's text; the user decides.
  Future<void> _conflict(String why) async {
    final ide = Ide.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('服务器上的文件已被修改'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text('$why\n\n直接保存会覆盖对方的修改。你可以先取消，把自己的修改复制出来，再重新载入。'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: Text('取消', style: TextStyle(color: ide.textDim))),
          OutlinedButton(onPressed: () => Navigator.pop(c, 'reload'), child: const Text('放弃我的修改，重新载入')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: ide.error), onPressed: () => Navigator.pop(c, 'overwrite'), child: const Text('覆盖服务器上的文件')),
        ],
      ),
    );
    if (choice == 'reload') {
      setState(() => _phase = _Phase.loading);
      await _load();
    } else if (choice == 'overwrite') {
      await _overwrite();
    }
  }

  /// Reads the file's current etag, then saves against it: an explicit,
  /// confirmed overwrite.
  Future<void> _overwrite() async {
    final link = widget.ws.link;
    if (link == null) return;
    final cur = await widget.ws.guard(() => link.call('fs.stat', {'root': widget.root, 'path': widget.path}));
    final etag = ((cur as Map?)?['etag']) as String?;
    if (etag == null) return;
    _etag = etag;
    await save();
  }

  Future<bool> askDiscard() async {
    final ide = Ide.of(context);
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${widget.path.split('/').last} 有未保存的修改'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: Text('取消', style: TextStyle(color: ide.textDim))),
          OutlinedButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('不保存')),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('保存')),
        ],
      ),
    );
    if (r == 'save') {
      await save();
      return !dirty;
    }
    return r == 'discard';
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
      case _Phase.refused:
        return EmptyHint(icon: Icons.block, text: _message);
      case _Phase.failed:
        return EmptyHint(icon: Icons.error_outline, text: _message, actionLabel: '重试', onAction: () {
          setState(() => _phase = _Phase.loading);
          _load();
        });
      case _Phase.ready:
        break;
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lang = languageFor(widget.path);
    final style = CodeEditorStyle(
      fontFamily: Ide.mono,
      fontFamilyFallback: Ide.monoFallback,
      fontSize: 13.5,
      fontHeight: 1.45,
      textColor: ide.text,
      backgroundColor: ide.editor,
      selectionColor: ide.selection,
      cursorColor: ide.text,
      cursorLineColor: ide.hover.withValues(alpha: 0.5),
      hintTextColor: ide.textDim,
      codeTheme: lang == null
          ? null
          : CodeHighlightTheme(
              languages: {lang.name: lang.mode},
              theme: dark ? vs2015Theme : githubTheme,
            ),
    );
    final pk = previewOf(widget.path);
    return Column(children: [
      if (pk != PreviewKind.none)
        Container(
          height: 28,
          color: ide.tabBar,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() => _preview = !_preview),
              icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined, size: 15),
              label: Text(_preview ? '编辑' : (pk == PreviewKind.markdown ? '预览' : '表格')),
            ),
          ]),
        ),
      if (_readOnly || _saving)
        Container(
          height: 24,
          color: ide.tabBar,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          child: Text(_saving ? '正在保存…' : '只读', style: TextStyle(color: ide.textDim, fontSize: 12)),
        ),
      // Keys: without them the Column matches this new child to the editor's
      // slot and rebuilds the editor (scroll position, cursor and focus lost).
      if (_preview && pk != PreviewKind.none)
        Expanded(
          key: const ValueKey('preview'),
          child: pk == PreviewKind.markdown
              ? MarkdownPreview(text: _controller.text)
              : CsvPreview(text: _controller.text, tabSeparated: extOf(widget.path) == 'tsv'),
        ),
      Expanded(
        key: const ValueKey('editor'),
        // kept alive while the preview shows: unsaved text and undo survive
        child: Offstage(
          offstage: _preview && pk != PreviewKind.none,
          child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyS, control: true): save,
          },
          child: CodeEditor(
            controller: _controller,
            style: style,
            readOnly: _readOnly,
            wordWrap: false,
            autofocus: true,
            findBuilder: (context, controller, readOnly) => _FindPanel(controller: controller, readOnly: readOnly),
            indicatorBuilder: (context, editingController, chunkController, notifier) => Row(children: [
              DefaultCodeLineNumber(controller: editingController, notifier: notifier),
              DefaultCodeChunkIndicator(width: 18, controller: chunkController, notifier: notifier),
            ]),
            chunkAnalyzer: const DefaultCodeChunkAnalyzer(),
            padding: const EdgeInsets.only(left: 4, right: 12),
            verticalScrollbarWidth: 10,
            horizontalScrollbarHeight: 10,
          ),
        ),
      ),
      ),
    ]);
  }
}

/// A compact find and replace bar in the IDE's colours.
class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  final bool readOnly;
  const _FindPanel({required this.controller, required this.readOnly});

  @override
  Size get preferredSize => Size(double.infinity, controller.value == null ? 0 : (controller.value!.replaceMode ? 72 : 38));

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final ide = Ide.of(context);
    final result = v.result == null ? '无结果' : '${v.result!.index + 1}/${v.result!.matches.length}';
    Widget field(TextEditingController c, FocusNode? f, String hint, {List<Widget> tail = const []}) => SizedBox(
          height: 30,
          child: TextField(
            controller: c,
            focusNode: f,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              suffixIcon: tail.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: tail),
            ),
          ),
        );
    Widget toggle(String label, bool on, VoidCallback tap) => InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(3),
          child: Container(
            width: 26,
            height: 22,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(color: on ? ide.selection : null, borderRadius: BorderRadius.circular(3), border: on ? Border.all(color: ide.accent) : null),
            child: Text(label, style: TextStyle(fontSize: 11, color: on ? ide.text : ide.textDim)),
          ),
        );
    return Container(
      color: ide.sideBar,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: field(controller.findInputController, controller.findInputFocusNode, '查找', tail: [
              toggle('Aa', v.option.caseSensitive, controller.toggleCaseSensitive),
              toggle('.*', v.option.regex, controller.toggleRegex),
            ]),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 56, child: Text(result, style: TextStyle(fontSize: 12, color: ide.textDim))),
          IconBtn(Icons.keyboard_arrow_up, '上一个', controller.previousMatch),
          IconBtn(Icons.keyboard_arrow_down, '下一个', controller.nextMatch),
          if (!readOnly) IconBtn(v.replaceMode ? Icons.unfold_less : Icons.find_replace, '替换', controller.replaceMode),
          IconBtn(Icons.close, '关闭', controller.close),
        ]),
        if (v.replaceMode && !readOnly) ...[
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: field(controller.replaceInputController, null, '替换为')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: controller.replaceMatch, child: const Text('替换')),
            const SizedBox(width: 6),
            OutlinedButton(onPressed: controller.replaceAllMatches, child: const Text('全部替换')),
          ]),
        ],
      ]),
    );
  }
}
