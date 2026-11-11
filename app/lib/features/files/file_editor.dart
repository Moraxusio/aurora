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
EditorTab fileEditorTab(Workspace ws, {required String root, required String path, int? line, int col = 1}) {
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
  final view = FileEditor(key: key, ws: ws, root: root, path: path, line: line, col: col);
  final tab = EditorTab(id: id, title: title, icon: Icons.description_outlined, tooltip: path, builder: (_) => view, file: file);
  tab.confirmClose = () async {
    final st = key.currentState;
    if (st == null || !st.dirty) return true;
    return st.askDiscard();
  };
  tab.reveal = (line, col) => key.currentState?.reveal(line, col);
  return tab;
}

/// Opens [root]:[path] and, for a text file, puts the cursor on [line] and
/// [col] (1-based). Works whether or not the file is already open.
void openFileAt(Workspace ws, {required String root, required String path, int? line, int col = 1}) {
  final t = fileEditorTab(ws, root: root, path: path, line: line, col: col);
  final existing = ws.tab(t.id);
  ws.openTab(t);
  if (existing != null && line != null) existing.reveal?.call(line, col);
}
class FileEditor extends StatefulWidget {
  final Workspace ws;
  final String root;
  final String path;
  final int? line;
  final int col;
  const FileEditor({super.key, required this.ws, required this.root, required this.path, this.line, this.col = 1});

  @override
  State<FileEditor> createState() => FileEditorState();
}

enum _Phase { loading, ready, refused, failed }

/// The line break a file uses: CRLF when its first line ends with one. Saving
/// writes the same one back, so opening and saving a Windows-style file does
/// not change every line.
TextLineBreak lineBreakOf(String text) {
  final n = text.indexOf('\n');
  if (n > 0 && text.codeUnitAt(n - 1) == 0x0d) return TextLineBreak.crlf;
  if (n < 0 && text.contains('\r')) return TextLineBreak.cr;
  return TextLineBreak.lf;
}

class FileEditorState extends State<FileEditor> {
  late CodeLineEditingController _controller;
  _Phase _phase = _Phase.loading;
  String _message = '';
  String? _etag;
  String _saved = '';
  bool _saving = false;
  final bool _readOnly = false; // a later step: open read-only (e.g. a file the user cannot write)
  String? _langName;
  bool _preview = false;

  bool get dirty => _phase == _Phase.ready && !_readOnly && _controller.text != _saved;

  int? _pendingLine;
  int _pendingCol = 1;

  /// Puts the cursor at 1-based [line] and [col] and scrolls to it. Before
  /// the text has loaded the position is kept and applied when it arrives.
  void reveal(int line, int col) {
    if (_phase != _Phase.ready) {
      _pendingLine = line;
      _pendingCol = col;
      return;
    }
    if (!mounted || _controller.codeLines.isEmpty) return;
    final i = (line - 1).clamp(0, _controller.codeLines.length - 1);
    final text = _controller.codeLines[i].text;
    final o = (col - 1).clamp(0, text.length);
    _controller.selection = CodeLineSelection.collapsed(index: i, offset: o);
    _controller.makeCursorCenterIfInvisible();
  }

  /// The editor's text (tests).
  @visibleForTesting
  String get text => _controller.text;

  /// The cursor as (0-based line, 0-based column) (tests).
  @visibleForTesting
  (int, int) get cursor => (_controller.selection.extentIndex, _controller.selection.extentOffset);

  @visibleForTesting
  set text(String v) => _controller.text = v;

  /// Word wrap for this file (Alt+Z); null follows the setting.
  bool? _wrap;

  void toggleWrap() => setState(() => _wrap = !(_wrap ?? _settings.wordWrap));

  /// Ctrl+G: asks for "line" or "line:column" and goes there.
  Future<void> goToLine() async {
    if (_phase != _Phase.ready) return;
    final n = _controller.codeLines.length;
    final cur = _controller.selection.extentIndex + 1;
    final v = await askText(context, title: '转到行（1–$n）', initial: '$cur', hint: '行号，或 行:列', ok: '转到');
    if (v == null) return;
    final m = RegExp(r'^\s*(\d+)\s*(?::\s*(\d+))?\s*$').firstMatch(v);
    if (m == null) return widget.ws.toast('请输入行号，例如 120 或 120:8', error: true);
    reveal(int.parse(m.group(1)!), int.tryParse(m.group(2) ?? '') ?? 1);
  }

  /// The file mixes line breaks: saving makes them all [_lineBreak]. Said in
  /// the status bar, so it is not a silent change.
  bool _mixedBreaks = false;
  TextLineBreak _lineBreak = TextLineBreak.lf;
  int _indent = 4;

  EditorSettings get _settings => widget.ws.app.profile.editor;

  /// Replaces the controller when the line break or indent differ: both are
  /// fixed when a controller is made. Only before the text is loaded, so no
  /// undo history or unsaved text is lost.
  void _useLineBreak(TextLineBreak b) {
    final indent = _settings.tabSize;
    if (b == _lineBreak && indent == _indent) return;
    _lineBreak = b;
    _indent = indent;
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _controller = CodeLineEditingController(options: CodeLineOptions(lineBreak: b, indentSize: indent));
    _controller.addListener(_onChanged);
  }

  void Function()? _unwatch;

  /// The file changed on the server after it was opened here, and the editor
  /// has unsaved text, so it was not reloaded: the banner offers the choice.
  /// "deleted": the file is gone.
  String? _outside;
  bool _checking = false;

  /// A notice from fs.watch: compare the file's etag with the one loaded. A
  /// save from this editor changes the etag too, but it updates [_etag] first.
  Future<void> _checkOutside() async {
    if (_phase != _Phase.ready || _saving || _checking || !mounted) return;
    final link = widget.ws.link;
    if (link == null) return;
    _checking = true;
    try {
      final st = (await link.call('fs.stat', {'root': widget.root, 'path': widget.path}) as Map).cast<String, dynamic>();
      final etag = st['etag'] as String?;
      if (!mounted || _saving || etag == null || etag == _etag) return;
      if (!dirty) {
        // nothing to lose: show what is on the server now
        await _reload(note: '${widget.path.split('/').last} 在服务器上被修改，已重新载入');
      } else {
        setState(() => _outside = 'changed');
      }
    } on OpError catch (e) {
      if (mounted && e.code == codeNotFound) setState(() => _outside = 'deleted');
    } finally {
      _checking = false;
    }
  }

  /// Loads the file again, keeping the cursor line.
  Future<void> _reload({String? note}) async {
    final line = _controller.selection.extentIndex + 1;
    _pendingLine = line;
    _pendingCol = 1;
    setState(() {
      _outside = null;
      _phase = _Phase.loading;
    });
    await _load();
    if (note != null && _phase == _Phase.ready) widget.ws.toast(note);
  }

  @override
  void initState() {
    super.initState();
    _indent = _settings.tabSize;
    _controller = CodeLineEditingController(options: CodeLineOptions(indentSize: _indent));
    _controller.addListener(_onChanged);
    _unwatch = widget.ws.watch.watch(widget.root, widget.path, _checkOutside);
    _shownSettings = _settingsKey;
    widget.ws.app.addListener(_onSettings);
    _load();
  }

  String _shownSettings = '';
  String get _settingsKey => '${_settings.fontSize}/${_settings.wordWrap}';

  /// Font size and word wrap apply to open editors at once. (A new indent
  /// size applies to files opened after the change.)
  void _onSettings() {
    final k = _settingsKey;
    if (k != _shownSettings && mounted) setState(() => _shownSettings = k);
  }

  @override
  void dispose() {
    widget.ws.app.removeListener(_onSettings);
    _unwatch?.call();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    final t = widget.ws.tab('file:${widget.root}:${widget.path}');
    if (t != null) {
      t.dirty.value = dirty;
      final sel = _controller.selection;
      final eol = switch (_lineBreak) { TextLineBreak.crlf => 'CRLF', TextLineBreak.cr => 'CR', _ => 'LF' };
      t.status.value = 'Ln ${sel.extentIndex + 1}, Col ${sel.extentOffset + 1}   空格: $_indent   $eol${_mixedBreaks ? '（混合，保存时统一）' : ''}'
          '${_langName == null ? '' : '   $_langName'}${_readOnly ? '   只读' : ''}';
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
      _useLineBreak(lineBreakOf(text));
      _mixedBreaks = _lineBreak == TextLineBreak.crlf ? RegExp(r'(?<!\r)\n').hasMatch(text) : text.contains('\r');
      _controller.text = text;
      // what the controller gives back for this text: the "unsaved" check
      // compares like with like (a file that ends without a newline, or mixes
      // line breaks, is not dirty the moment it opens)
      _saved = _controller.text;
      _controller.clearHistory();
      _langName = languageFor(widget.path)?.name;
      setState(() => _phase = _Phase.ready);
      _onChanged();
      final line = _pendingLine ?? widget.line;
      final col = _pendingLine != null ? _pendingCol : widget.col;
      _pendingLine = null;
      if (line != null && line > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => reveal(line, col));
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
      fontSize: _settings.fontSize,
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
      if (_outside != null)
        Container(
          key: const ValueKey('outside'),
          color: ide.warn.withValues(alpha: 0.14),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Row(children: [
            Icon(Icons.warning_amber, size: 15, color: ide.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _outside == 'deleted' ? '这个文件已在服务器上被删除或移走。编辑器里的内容还在。' : '这个文件在服务器上被别的程序修改了，你这里还有未保存的修改。',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (_outside == 'changed')
              TextButton(
                onPressed: () async {
                  if (await confirmDialog(context, title: '放弃你的修改？', body: '载入服务器上的新内容，你未保存的修改会丢失。', ok: '放弃并重新载入', danger: true)) {
                    await _reload();
                  }
                },
                child: const Text('重新载入'),
              ),
            if (_outside == 'deleted')
              TextButton(
                onPressed: () async {
                  // no etag: the agent writes the file as a new one
                  _etag = null;
                  setState(() => _outside = null);
                  await save();
                },
                child: const Text('重新创建'),
              ),
            if (_outside == 'changed') TextButton(onPressed: () => setState(() => _outside = null), child: const Text('保留我的修改')),
          ]),
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
            const SingleActivator(LogicalKeyboardKey.keyG, control: true): goToLine,
            const SingleActivator(LogicalKeyboardKey.keyZ, alt: true): toggleWrap,
          },
          child: CodeEditor(
            controller: _controller,
            style: style,
            readOnly: _readOnly,
            wordWrap: _wrap ?? _settings.wordWrap,
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
