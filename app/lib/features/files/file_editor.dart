// A text file open in an editor tab (re_editor): line numbers, syntax colours,
// find and replace, undo. What keeps it safe:
//  - the text is saved only while the file's etag on the server is still the
//    one it was read with (fs.write if_match), so another program's edit is
//    refused and shown, never overwritten;
//  - a file that is not UTF-8, or too big for one frame, is not opened as
//    text at all, so saving cannot damage bytes the editor never showed;
//  - closing with unsaved changes asks.
import 'dart:async';
import 'dart:math' as math;

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora/ui/aurora_ui.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
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
import '../../kernel/document_model.dart';
import '../../kernel/file_text.dart';
import '../../kernel/input_mode.dart';
import '../../kernel/ai_edits.dart';
import '../ai/ai_edit_review.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'file_icons.dart';
import 'file_kind.dart';
import 'file_preview.dart';
import 'file_viewers.dart';
import 'document_merge.dart';
import 'text_modes.dart';
import '../development/development_feature.dart' show editDevelopmentConfiguration;
import '../development/language_actions.dart';
import '../development/debug_panel.dart';

/// The highlighter language for a file name, or null for plain text.
({String name, CodeHighlightThemeMode mode})? languageFor(String file) {
  final base = file.split('/').last.toLowerCase();
  final dot = base.lastIndexOf('.');
  final ext = dot < 0 ? '' : base.substring(dot + 1);
  CodeHighlightThemeMode m(mode) => CodeHighlightThemeMode(mode: mode);
  if (base == 'dockerfile' || base.startsWith('dockerfile.'))
    return (name: 'dockerfile', mode: m(langDockerfile));
  if (base == 'makefile' || base == 'gnumakefile' || ext == 'mk')
    return (name: 'makefile', mode: m(langMakefile));
  if (base == 'nginx.conf' || (ext == 'conf' && file.contains('nginx')))
    return (name: 'nginx', mode: m(langNginx));
  if (const {
    '.bashrc',
    '.profile',
    '.bash_profile',
    '.zshrc',
    '.bash_aliases',
  }.contains(base))
    return (name: 'bash', mode: m(langBash));
  return switch (ext) {
    'sh' || 'bash' || 'zsh' || 'env' => (name: 'bash', mode: m(langBash)),
    'py' || 'pyw' => (name: 'python', mode: m(langPython)),
    'go' => (name: 'go', mode: m(langGo)),
    'dart' => (name: 'dart', mode: m(langDart)),
    'js' ||
    'mjs' ||
    'cjs' ||
    'jsx' => (name: 'javascript', mode: m(langJavascript)),
    'ts' || 'tsx' => (name: 'typescript', mode: m(langTypescript)),
    'json' || 'jsonc' => (name: 'json', mode: m(langJson)),
    'yml' || 'yaml' => (name: 'yaml', mode: m(langYaml)),
    'md' || 'markdown' => (name: 'markdown', mode: m(langMarkdown)),
    'html' ||
    'htm' ||
    'xml' ||
    'svg' ||
    'xhtml' => (name: 'xml', mode: m(langXml)),
    'css' || 'scss' => (name: 'css', mode: m(langCss)),
    'sql' => (name: 'sql', mode: m(langSql)),
    'ini' ||
    'cfg' ||
    'toml' ||
    'service' ||
    'timer' ||
    'socket' ||
    'desktop' => (name: 'ini', mode: m(langIni)),
    'conf' || 'properties' => (name: 'properties', mode: m(langProperties)),
    'c' || 'h' => (name: 'c', mode: m(langC)),
    'cc' || 'cpp' || 'cxx' || 'hpp' || 'hh' => (name: 'cpp', mode: m(langCpp)),
    'java' => (name: 'java', mode: m(langJava)),
    'rs' => (name: 'rust', mode: m(langRust)),
    'diff' || 'patch' => (name: 'diff', mode: m(langDiff)),
    _ => null,
  };
}

/// Comment syntax for [file] used by Ctrl+/ and Shift+Alt+A.
CodeCommentFormatter commentFormatterFor(String file) {
  final base = file.split('/').last.toLowerCase();
  final dot = base.lastIndexOf('.');
  final ext = dot < 0 ? '' : base.substring(dot + 1);
  if (base == 'dockerfile' ||
      base.startsWith('dockerfile.') ||
      base == 'makefile' ||
      base == 'gnumakefile' ||
      base == 'cmakelists.txt' ||
      base == 'nginx.conf' ||
      base.startsWith('.env') ||
      const {'.bashrc', '.profile', '.bash_profile', '.zshrc', '.bash_aliases', '.gitignore', '.dockerignore'}.contains(base)) {
    return DefaultCodeCommentFormatter(singleLinePrefix: '#');
  }
  return switch (ext) {
    'dart' || 'go' || 'js' || 'mjs' || 'cjs' || 'jsx' || 'ts' || 'tsx' ||
    'c' || 'h' || 'cc' || 'cpp' || 'cxx' || 'hpp' || 'hh' || 'java' ||
    'kt' || 'kts' || 'swift' || 'rs' || 'cs' || 'gradle' || 'proto' ||
    'jsonc' || 'scss' || 'less' => DefaultCodeCommentFormatter(
      singleLinePrefix: '//',
      multiLinePrefix: '/*',
      multiLineSuffix: '*/',
    ),
    'css' => DefaultCodeCommentFormatter(
      multiLinePrefix: '/*',
      multiLineSuffix: '*/',
    ),
    'py' || 'pyw' || 'pyi' || 'sh' || 'bash' || 'zsh' || 'fish' ||
    'yml' || 'yaml' || 'toml' || 'env' || 'conf' || 'properties' ||
    'mk' || 'cmake' || 'rb' || 'r' || 'ps1' || 'psm1' || 'graphql' || 'gql' =>
      DefaultCodeCommentFormatter(singleLinePrefix: '#'),
    'php' => DefaultCodeCommentFormatter(
      singleLinePrefix: '//',
      multiLinePrefix: '/*',
      multiLineSuffix: '*/',
    ),
    'sql' || 'lua' => DefaultCodeCommentFormatter(
      singleLinePrefix: '--',
      multiLinePrefix: '/*',
      multiLineSuffix: '*/',
    ),
    'html' || 'htm' || 'xml' || 'svg' || 'xhtml' || 'md' || 'markdown' || 'vue' || 'svelte' =>
      DefaultCodeCommentFormatter(
        multiLinePrefix: '<!--',
        multiLineSuffix: '-->',
      ),
    'tex' || 'ltx' || 'cls' || 'sty' || 'bib' =>
      DefaultCodeCommentFormatter(singleLinePrefix: '%'),
    'ini' || 'cfg' || 'service' || 'timer' || 'socket' =>
      DefaultCodeCommentFormatter(singleLinePrefix: ';'),
    'bat' || 'cmd' => DefaultCodeCommentFormatter(singleLinePrefix: 'REM'),
    _ => DefaultCodeCommentFormatter(
      singleLinePrefix: '//',
      multiLinePrefix: '/*',
      multiLineSuffix: '*/',
    ),
  };
}

/// The tab for [path] under [root]. The editor's state is reached through a
/// key so closing the tab can ask about unsaved changes.
EditorTab fileEditorTab(
  Workspace ws, {
  required String root,
  required String path,
  int? line,
  int col = 1,
}) {
  path = WorkspacePath.normalize(path);
  final id = 'file:$root:$path';
  final title = path.split('/').last;
  final file = WorkspacePath(root: root, path: path);
  // Not text: a viewer of its own, no editing, nothing to save or discard.
  final kind = kindOf(path);
  if (kind != FileKind.text) {
    final (icon, view) = switch (kind) {
      FileKind.image => (
        Icons.image_outlined,
        ImageViewer(ws: ws, root: root, path: path) as Widget,
      ),
      FileKind.pdf => (
        Icons.picture_as_pdf_outlined,
        PdfFileViewer(ws: ws, root: root, path: path),
      ),
      FileKind.video => (
        Icons.movie_outlined,
        MediaUnsupported(ws: ws, root: root, path: path, kind: kind),
      ),
      _ => (
        Icons.audiotrack_outlined,
        MediaUnsupported(ws: ws, root: root, path: path, kind: kind),
      ),
    };
    return EditorTab(
      id: id,
      title: title,
      icon: icon,
      tooltip: path,
      builder: (_) => view,
      file: file,
    );
  }
  final key = GlobalKey<FileEditorState>();
  final view = FileEditor(
    key: key,
    ws: ws,
    root: root,
    path: path,
    line: line,
    col: col,
  );
  final spec = fileIconSpec(title);
  final tab = EditorTab(
    id: id,
    title: title,
    icon: spec.icon,
    iconColor: spec.darkColor,
    tooltip: path,
    builder: (_) => view,
    file: file,
  );
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
void openFileAt(
  Workspace ws, {
  required String root,
  required String path,
  int? line,
  int col = 1,
  bool preview = false,
}) {
  final t = fileEditorTab(ws, root: root, path: path, line: line, col: col);
  final existing = ws.tab(t.id);
  ws.openTab(t, preview: preview);
  if (existing != null && line != null) existing.reveal?.call(line, col);
}

class FileEditor extends StatefulWidget {
  final Workspace ws;
  final String root;
  final String path;
  final int? line;
  final int col;
  const FileEditor({
    super.key,
    required this.ws,
    required this.root,
    required this.path,
    this.line,
    this.col = 1,
  });

  @override
  State<FileEditor> createState() => FileEditorState();
}

typedef _Phase = DocumentPhase;

/// The line break a file uses: CRLF when its first line ends with one. Saving
/// writes the same one back, so opening and saving a Windows-style file does
/// not change every line.
TextLineBreak lineBreakOf(String text) {
  return documentLineBreak(text);
}

class FileEditorState extends State<FileEditor> {
  late DocumentModel _document;
  CodeLineEditingController get _controller => _document.controller;
  CodeLineEditingController? _listenedController;
  CodeFindController? _findController;
  late final ValueNotifier<bool> _dirtyNotifier = ValueNotifier(dirty);
  final _editorFocus = FocusNode(debugLabel: 'file editor');
  AiProposalOperation? _inlineRequest;
  DateTime? _lastInline;
  Future<void> _completeInline() async {
    if (_inlineRequest != null) {
      _inlineRequest!.cancel();
      return;
    }
    final now = DateTime.now(), link = widget.ws.link;
    if (link == null ||
        _lastInline != null &&
            now.difference(_lastInline!) < const Duration(seconds: 1))
      return;
    final selection = _controller.selection;
    if (!selection.isCollapsed ||
        _controller.isComposing ||
        selection.extentOffset != _controller.extentLine.length) {
      widget.ws.toast('将光标置于行尾后请求 AI 续写');
      return;
    }
    _lastInline = now;
    _document.snippet?.close();
    _document.suggestInline(null);
    final document = _document;
    final snapshot = AiBufferSnapshot(document);
    final op = AiProposalOperation(
      [snapshot],
      inline: true,
      active: () => mounted && identical(link, widget.ws.link),
      resultActive: () =>
          !document.isClosed && identical(document.currentLink(), link),
    );
    setState(() => _inlineRequest = op);
    try {
      final result = await op.run(
        link,
        () => aiProposalArguments(
          widget.ws,
          snapshot,
          'Continue at the caret.',
          inline: true,
        ),
      );
      if (mounted && result.chunks.isNotEmpty) _document.suggestInline(result);
    } on Object catch (e) {
      if (mounted) widget.ws.toast('$e', error: true);
    } finally {
      if (mounted) setState(() => _inlineRequest = null);
    }
  }

  void _acceptInline() {
    final suggestion = _document.inlineSuggestion;
    if (suggestion == null) return;
    try {
      final caret = _controller.selection;
      suggestion.accept(suggestion.pending.toList());
      final inserted = suggestion.chunks.single.replacement;
      final lines = inserted.split(RegExp(r'\r\n|\r|\n'));
      _controller.selection = CodeLineSelection.collapsed(
        index: caret.extentIndex + lines.length - 1,
        offset: lines.length == 1
            ? caret.extentOffset + inserted.length
            : lines.last.length,
      );
      _document.suggestInline(null);
      _editorFocus.requestFocus();
    } on Object catch (e) {
      widget.ws.toast('$e', error: true);
    }
  }

  _Phase get _phase => _document.phase;
  set _phase(_Phase value) => _document.phase = value;
  String get _message => _document.message;
  set _etag(String? value) => _document.etag = value;
  bool _saving = false;
  Timer? _saveIndicator;
  DateTime? _saveStarted;
  final bool _readOnly =
      false; // a later step: open read-only (e.g. a file the user cannot write)
  String? _langName;
  bool _preview = false;
  bool _largePreview = false;

  bool get dirty => !_readOnly && _document.dirty;

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
  (int, int) get cursor =>
      (_controller.selection.extentIndex, _controller.selection.extentOffset);

  @visibleForTesting
  set text(String v) => _controller.text = v;

  /// Word wrap for this file (Alt+Z); null follows the setting.
  bool? _wrap;

  void toggleWrap() => setState(() => _wrap = !(_wrap ?? _settings.wordWrap));

  void _openReplace() {
    final fc = _findController;
    if (fc == null) return;
    fc.replaceMode();
    if (fc.findInputController.text.isEmpty) {
      fc.focusOnFindInput();
    } else {
      fc.focusOnReplaceInput();
    }
  }

  ({String? single, String? multiStart, String? multiEnd}) _commentTokens() {
    final base = widget.path.split('/').last.toLowerCase();
    final dot = base.lastIndexOf('.');
    final ext = dot < 0 ? '' : base.substring(dot + 1);
    if (base == 'dockerfile' ||
        base.startsWith('dockerfile.') ||
        base == 'makefile' ||
        base == 'gnumakefile' ||
        base == 'cmakelists.txt' ||
        base == 'nginx.conf' ||
        base.startsWith('.env') ||
        const {
          '.bashrc',
          '.profile',
          '.bash_profile',
          '.zshrc',
          '.bash_aliases',
          '.gitignore',
          '.dockerignore',
        }.contains(base)) {
      return (single: '#', multiStart: null, multiEnd: null);
    }
    return switch (ext) {
      'dart' || 'go' || 'js' || 'mjs' || 'cjs' || 'jsx' || 'ts' || 'tsx' ||
      'c' || 'h' || 'cc' || 'cpp' || 'cxx' || 'hpp' || 'hh' || 'java' ||
      'kt' || 'kts' || 'swift' || 'rs' || 'cs' || 'gradle' || 'proto' ||
      'jsonc' || 'scss' || 'less' || 'php' => (
        single: '//',
        multiStart: '/*',
        multiEnd: '*/',
      ),
      'css' => (single: null, multiStart: '/*', multiEnd: '*/'),
      'py' || 'pyw' || 'pyi' || 'sh' || 'bash' || 'zsh' || 'fish' ||
      'yml' || 'yaml' || 'toml' || 'env' || 'conf' || 'properties' ||
      'mk' || 'cmake' || 'rb' || 'r' || 'ps1' || 'psm1' || 'graphql' || 'gql' =>
        (single: '#', multiStart: null, multiEnd: null),
      'sql' || 'lua' => (single: '--', multiStart: '/*', multiEnd: '*/'),
      'html' || 'htm' || 'xml' || 'svg' || 'xhtml' || 'md' || 'markdown' ||
      'vue' || 'svelte' => (
        single: null,
        multiStart: '<!--',
        multiEnd: '-->',
      ),
      'tex' || 'ltx' || 'cls' || 'sty' || 'bib' => (
        single: '%',
        multiStart: null,
        multiEnd: null,
      ),
      'ini' || 'cfg' || 'service' || 'timer' || 'socket' => (
        single: ';',
        multiStart: null,
        multiEnd: null,
      ),
      'bat' || 'cmd' => (single: 'REM', multiStart: null, multiEnd: null),
      _ => (single: '//', multiStart: '/*', multiEnd: '*/'),
    };
  }

  void _toggleComment({bool single = true}) {
    if (_phase != _Phase.ready || _readOnly) return;
    final tokens = _commentTokens();
    if (!single || tokens.single == null) {
      final value = commentFormatterFor(widget.path).format(
        _controller.value,
        _controller.options.indent,
        single,
      );
      _controller.runRevocableOp(() {
        _controller.value = value;
      });
      return;
    }
    final prefix = tokens.single!;
    final sel = _controller.selection;
    final lines = _controller.codeLines;
    final start = sel.startIndex.clamp(0, lines.length - 1);
    final end = sel.endIndex.clamp(start, lines.length - 1);
    var hasNonEmpty = false;
    var allCommented = true;
    int? minIndent;
    for (var i = start; i <= end; i++) {
      final t = lines[i].text;
      if (t.trim().isEmpty) continue;
      hasNonEmpty = true;
      final lead = t.length - t.trimLeft().length;
      minIndent = minIndent == null ? lead : math.min(minIndent, lead);
      if (!t.substring(lead).startsWith(prefix)) {
        allCommented = false;
      }
    }
    if (!hasNonEmpty) return;
    final indentCol = minIndent ?? 0;
    final newLines = CodeLines.from(lines);
    var baseDelta = 0, extentDelta = 0;
    for (var i = start; i <= end; i++) {
      final t = lines[i].text;
      if (t.trim().isEmpty) continue;
      if (allCommented) {
        final lead = t.length - t.trimLeft().length;
        final removeLen = t.substring(lead).startsWith('$prefix ')
            ? prefix.length + 1
            : prefix.length;
        newLines[i] = newLines[i].copyWith(
          text: t.substring(0, lead) + t.substring(lead + removeLen),
        );
        if (i == sel.baseIndex && sel.baseOffset > lead) {
          baseDelta = -math.min(removeLen, sel.baseOffset - lead);
        }
        if (i == sel.extentIndex && sel.extentOffset > lead) {
          extentDelta = -math.min(removeLen, sel.extentOffset - lead);
        }
      } else {
        final insertText = '$prefix ';
        newLines[i] = newLines[i].copyWith(
          text: t.substring(0, indentCol) + insertText + t.substring(indentCol),
        );
        if (i == sel.baseIndex && sel.baseOffset >= indentCol) {
          baseDelta = insertText.length;
        }
        if (i == sel.extentIndex && sel.extentOffset >= indentCol) {
          extentDelta = insertText.length;
        }
      }
    }
    _controller.runRevocableOp(() {
      _controller.value = _controller.value.copyWith(
        codeLines: newLines,
        selection: sel.copyWith(
          baseOffset: math.max(0, sel.baseOffset + baseDelta),
          extentOffset: math.max(0, sel.extentOffset + extentDelta),
        ),
      );
    });
  }

  void _duplicateLines({required bool down}) {
    if (_phase != _Phase.ready || _readOnly) return;
    final sel = _controller.selection;
    final start = sel.startIndex;
    final end = sel.endIndex;
    final lines = _controller.codeLines;
    if (start < 0 || end >= lines.length) return;
    _controller.runRevocableOp(() {
      final copied = [for (var i = start; i <= end; i++) CodeLine(lines[i].text)];
      final newLines = lines.sublines(0, end + 1)
        ..addAll(copied);
      if (end + 1 < lines.length) {
        newLines.addFrom(lines, end + 1);
      }
      final shift = down ? copied.length : 0;
      _controller.value = _controller.value.copyWith(
        codeLines: newLines,
        selection: sel.copyWith(
          baseIndex: sel.baseIndex + shift,
          extentIndex: sel.extentIndex + shift,
        ),
      );
      _controller.makeCursorVisible();
    });
  }

  void _insertBlankLine({required bool above}) {
    if (_phase != _Phase.ready || _readOnly) return;
    final lineIdx = _controller.selection.extentIndex;
    final lines = _controller.codeLines;
    if (lineIdx < 0 || lineIdx >= lines.length) return;
    final text = lines[lineIdx].text;
    final indent = RegExp(r'^[ \t]*').firstMatch(text)?.group(0) ?? '';
    _controller.runRevocableOp(() {
      final insertAt = above ? lineIdx : lineIdx + 1;
      final newLines = lines.sublines(0, insertAt)
        ..add(CodeLine(indent));
      if (insertAt < lines.length) {
        newLines.addFrom(lines, insertAt);
      }
      _controller.value = _controller.value.copyWith(
        codeLines: newLines,
        selection: CodeLineSelection.collapsed(
          index: insertAt,
          offset: indent.length,
        ),
      );
      _controller.makeCursorVisible();
    });
  }

  void _indentLines() {
    if (_phase != _Phase.ready || _readOnly) return;
    final sel = _controller.selection;
    final lines = _controller.codeLines;
    final indent = _controller.options.indent;
    _controller.runRevocableOp(() {
      final newLines = CodeLines.from(lines);
      for (var i = sel.startIndex; i <= sel.endIndex; i++) {
        newLines[i] = newLines[i].copyWith(text: '$indent${newLines[i].text}');
      }
      _controller.value = _controller.value.copyWith(
        codeLines: newLines,
        selection: sel.copyWith(
          baseOffset: sel.baseOffset + indent.length,
          extentOffset: sel.extentOffset + indent.length,
        ),
      );
    });
  }

  void _selectCurrentWord() {
    if (_phase != _Phase.ready) return;
    final sel = _controller.selection;
    if (!sel.isCollapsed) return;
    final lineIdx = sel.extentIndex;
    final text = _controller.codeLines[lineIdx].text;
    if (text.isEmpty) return;
    bool isWord(int cu) =>
        (cu >= 48 && cu <= 57) ||
        (cu >= 65 && cu <= 90) ||
        (cu >= 97 && cu <= 122) ||
        cu == 95;
    var pos = sel.extentOffset.clamp(0, text.length);
    if (pos == text.length && pos > 0) pos--;
    if (!isWord(text.codeUnitAt(pos))) {
      if (sel.extentOffset > 0 && isWord(text.codeUnitAt(sel.extentOffset - 1))) {
        pos = sel.extentOffset - 1;
      } else {
        return;
      }
    }
    var start = pos;
    while (start > 0 && isWord(text.codeUnitAt(start - 1))) {
      start--;
    }
    var end = pos + 1;
    while (end < text.length && isWord(text.codeUnitAt(end))) {
      end++;
    }
    _controller.selection = CodeLineSelection(
      baseIndex: lineIdx,
      baseOffset: start,
      extentIndex: lineIdx,
      extentOffset: end,
    );
  }

  /// Ctrl+G: asks for "line" or "line:column" and goes there.
  Future<void> goToLine() async {
    if (_phase != _Phase.ready) return;
    final n = _controller.codeLines.length;
    final cur = _controller.selection.extentIndex + 1;
    final v = await askText(
      context,
      title: '转到行（1–$n）',
      initial: '$cur',
      hint: '行号，或 行:列',
      ok: '转到',
    );
    if (v == null) return;
    final m = RegExp(r'^\s*(\d+)\s*(?::\s*(\d+))?\s*$').firstMatch(v);
    if (m == null) return widget.ws.toast('请输入行号，例如 120 或 120:8', error: true);
    reveal(int.parse(m.group(1)!), int.tryParse(m.group(2) ?? '') ?? 1);
  }

  /// The file mixes line breaks: saving makes them all [_lineBreak]. Said in
  /// the status bar, so it is not a silent change.
  bool get _mixedBreaks => _document.mixedBreaks;
  TextLineBreak get _lineBreak => _document.lineBreak;
  int _indent = 4;

  EditorSettings get _settings {
    final p = widget.ws.app.appearance.value;
    return EditorSettings(
      fontSize: p.editorFont,
      wordWrap: p.wordWrap,
      tabSize: p.tabSize,
    );
  }

  /// The file changed on the server after it was opened here, and the editor
  /// has unsaved text, so it was not reloaded: the banner offers the choice.
  /// "deleted": the file is gone.
  String? get _outside => _document.outside;
  set _outside(String? value) => _document.outside = value;

  /// Loads the file again, keeping the cursor line.
  Future<void> _reload({String? note}) async {
    final line = _controller.selection.extentIndex + 1;
    _pendingLine = line;
    _pendingCol = 1;
    setState(() {
      _outside = null;
      _phase = _Phase.loading;
    });
    await _load(force: true);
    if (note != null && _phase == _Phase.ready) widget.ws.toast(note);
  }

  @override
  void initState() {
    super.initState();
    _indent = _settings.tabSize;
    _document = widget.ws.documents.open(
      widget.root,
      widget.path,
      indent: _indent,
    );
    widget.ws.development;
    _document.retainView();
    _document.addListener(_onDocument);
    _bindController();
    _shownSettings = _settingsKey;
    widget.ws.app.appearance.addListener(_onSettings);
    _load();
  }

  String _shownSettings = '';
  bool _visible = true;
  String get _settingsKey => '${_settings.fontSize}/${_settings.wordWrap}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    // Revealing a retained page already schedules its build. Apply the latest
    // preference then, instead of re-laying out every hidden code buffer.
    if (_visible) _shownSettings = _settingsKey;
  }

  /// Font size and word wrap apply to open editors at once. (A new indent
  /// size applies to files opened after the change.)
  void _onSettings() {
    final k = _settingsKey;
    if (_visible && k != _shownSettings && mounted)
      setState(() => _shownSettings = k);
  }

  @override
  void dispose() {
    _saveIndicator?.cancel();
    _inlineRequest?.cancel();
    _findController?.dispose();
    _dirtyNotifier.dispose();
    _editorFocus.dispose();
    widget.ws.app.appearance.removeListener(_onSettings);
    _listenedController?.removeListener(_onChanged);
    _document.removeListener(_onDocument);
    _document.releaseView();
    super.dispose();
  }

  void _bindController() {
    if (identical(_listenedController, _controller)) return;
    _listenedController?.removeListener(_onChanged);
    _listenedController = _controller;
    _controller.addListener(_onChanged);
    _findController?.dispose();
    _findController = CodeFindController(_controller);
  }

  void _onDocument() {
    if (!mounted) return;
    final controllerChanged = !identical(_listenedController, _controller);
    _bindController();
    _langName = languageFor(widget.path)?.name;
    final signature =
        '${_phase.name}/$_outside/${_document.recovered}/${_document.recoveryError}'
        '/${_document.encoding}/${_document.large}/${_document.languageSyncEligible}/${identityHashCode(_document.snippet)}/${identityHashCode(_document.inlineSuggestion)}';
    if (controllerChanged || signature != _documentUi) {
      _documentUi = signature;
      setState(() {});
    }
    _onChanged();
  }

  String _documentUi = '';

  void _syncDirtyUi(bool nowDirty) {
    if (nowDirty == _dirtyNotifier.value) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dirtyNotifier.value = dirty;
      });
    } else {
      _dirtyNotifier.value = nowDirty;
    }
  }

  void _onChanged() {
    final nowDirty = dirty;
    _syncDirtyUi(nowDirty);
    final t = widget.ws.tab('file:${widget.root}:${widget.path}');
    if (t != null) {
      t.dirty.value = nowDirty;
      t.onStatusTap = goToLine;
      final sel = _controller.selection;
      final eol = switch (_lineBreak) {
        TextLineBreak.crlf => 'CRLF',
        TextLineBreak.cr => 'CR',
        _ => 'LF',
      };
      var selNote = '';
      if (!sel.isCollapsed) {
        final selectedLen = _controller.selectedText.length;
        final lines = (sel.endIndex - sel.startIndex) + 1;
        selNote = lines > 1
            ? ' (已选 $lines 行, $selectedLen 字符)'
            : ' (已选 $selectedLen 字符)';
      }
      t.status.value =
          'Ln ${sel.extentIndex + 1}, Col ${sel.extentOffset + 1}$selNote   空格: $_indent   $eol${_mixedBreaks ? '（混合，保存时统一）' : ''}'
          '${_langName == null ? '' : '   $_langName'}${_readOnly ? '   只读' : ''}';
    }
  }

  Future<void> _load({bool force = false}) async {
    if (_document.recoveryError != null && !force) {
      await _document.retryRecovery();
    } else {
      await _document.load(force: force);
    }
    if (!mounted) return;
    _onDocument();
    final line = _pendingLine ?? widget.line;
    final col = _pendingLine != null ? _pendingCol : widget.col;
    _pendingLine = null;
    if (line != null && line > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => reveal(line, col));
    }
  }

  Future<void> save() async {
    if (_phase != _Phase.ready || _readOnly || _saving) return;
    final link = widget.ws.link;
    if (link == null) return widget.ws.toast('未连接，没有保存', error: true);
    String? conflict;
    _saveStarted = DateTime.now();
    _saveIndicator?.cancel();
    _saveIndicator = Timer(const Duration(milliseconds: 200), () {
      if (mounted && _saving) setState(() {});
    });
    setState(() => _saving = true);
    try {
      await _document.save();
      // A clean dot in the tab is the normal success feedback. Avoid a toast
      // for every Ctrl+S; only slow saves need an explicit confirmation.
      if (_saveStarted != null &&
          DateTime.now().difference(_saveStarted!) >
              const Duration(milliseconds: 600)) {
        widget.ws.toast('已保存 ${widget.path.split('/').last}');
      }
      widget.ws.filesRevision.value++; // the tree's size and time for this file
    } on OpError catch (e) {
      if (e.code == codeConflict) {
        conflict = e.message;
      } else {
        widget.ws.toast(e.message, error: true);
      }
    } finally {
      _saveIndicator?.cancel();
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
    final choice = await showWorkbenchDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('服务器上的文件已被修改'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text('$why\n\n直接保存会覆盖对方的修改。你可以先取消，把自己的修改复制出来，再重新载入。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'cancel'),
            child: Text('取消', style: TextStyle(color: ide.textDim)),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(c, 'merge'),
            child: const Text('比较并合并'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(c, 'reload'),
            child: const Text('放弃我的修改，重新载入'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ide.error),
            onPressed: () => Navigator.pop(c, 'overwrite'),
            child: const Text('覆盖服务器上的文件'),
          ),
        ],
      ),
    );
    if (choice == 'reload') {
      setState(() => _phase = _Phase.loading);
      await _load(force: true);
    } else if (choice == 'overwrite') {
      await _overwrite();
    } else if (choice == 'merge' && mounted) {
      await showDocumentMerge(context, _document);
    }
  }

  /// Reads the file's current etag, then saves against it: an explicit,
  /// confirmed overwrite.
  Future<void> _overwrite() async {
    final link = widget.ws.link;
    if (link == null) return;
    final cur = await widget.ws.guard(
      () => link.call('fs.stat', {'root': widget.root, 'path': widget.path}),
    );
    final etag = ((cur as Map?)?['etag']) as String?;
    if (etag == null) return;
    _etag = etag;
    await save();
  }

  Future<bool> askDiscard() async {
    final ide = Ide.of(context);
    final r = await showWorkbenchDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${widget.path.split('/').last} 有未保存的修改'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'cancel'),
            child: Text('取消', style: TextStyle(color: ide.textDim)),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(c, 'discard'),
            child: const Text('不保存'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (r == 'save') {
      await save();
      return !dirty;
    }
    return r == 'discard';
  }

  Widget _buildEditorToolbar(Ide ide, PreviewKind pk, {required double width}) {
    final wrapOn = !_document.large && (_wrap ?? _settings.wordWrap);
    final hasEncoding =
        _document.currentLink()?.server.caps.contains('fs.text') == true;
    final hasAi = widget.ws.link?.server.caps.contains('ai.propose') == true;
    void toggleSource() => setState(() => _preview = !_preview);
    final previewLabel = _preview
        ? '切回源码编辑'
        : pk == PreviewKind.csv ? '表格预览' : '预览渲染结果';
    final previewIcon = _preview ? Icons.edit_outlined : Icons.visibility_outlined;
    final compact = width < 180;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_readOnly && !compact)
            IconBtn(Icons.lock_outline, '只读', null, size: 15)
          else if (!_readOnly)
            ValueListenableBuilder<bool>(
              valueListenable: _dirtyNotifier,
              builder: (_, dirty, _) => dirty || _saving
                  ? IconBtn(Icons.save_outlined, _saving ? '保存中…' : '保存修改（Ctrl+S）',
                      _saving ? null : save, color: ide.accent, size: 15)
                  : const SizedBox.shrink(),
            ),
          if (pk != PreviewKind.none && !compact)
            IconBtn(previewIcon, previewLabel, toggleSource, size: 15,
                color: _preview ? ide.accent : null),
          if (!compact) IconBtn(Icons.search_rounded, '查找与替换（Ctrl+F）',
              _findController == null ? null : () => _findController!.findMode(),
              size: 15),
          if (_inlineRequest != null && !compact)
            IconBtn(Icons.stop_rounded, '取消 AI 续写', _completeInline,
                color: ide.error, size: 15),
          SizedBox(
            width: InputMode.row(context),
            child: WorkbenchMenuButton<Object>(
              key: const ValueKey('editor-actions-menu'),
              tooltip: '编辑器操作',
              padding: EdgeInsets.zero,
              icon: Icon(Icons.more_horiz, size: 17,
                  color: _document.languageSyncEligible ? ide.textDim : ide.warn),
              onSelected: (action) {
                switch (action) {
                  case 'wrap': toggleWrap();
                  case 'line': goToLine();
                  case 'encoding': chooseTextEncoding(context, _document);
                  case 'language': editDevelopmentConfiguration(context, widget.ws);
                  case 'review': openAiEditReview(widget.ws, _document);
                  case 'complete': _completeInline();
                  case 'preview': toggleSource();
                  case 'find': _findController?.findMode();
                  case final LanguageAction action:
                    runLanguageAction(context, widget.ws, _document, action);
                }
              },
              itemBuilder: (_) {
                final model = widget.ws.development;
                final session = model.sessionFor(_document);
                return [
                  if (compact && pk != PreviewKind.none)
                    PopupMenuItem(value: 'preview', child: MenuLabel(previewLabel, icon: previewIcon)),
                  if (compact && _findController != null)
                    const PopupMenuItem(value: 'find', child: MenuLabel('查找与替换', shortcut: 'Ctrl+F')),
                  CheckedPopupMenuItem(value: 'wrap', checked: wrapOn, enabled: !_document.large,
                    child: MenuLabel(_document.large ? '大文件已关闭自动换行' : '自动换行', shortcut: 'Alt+Z')),
                  const PopupMenuItem(value: 'line',
                    child: MenuLabel('跳转到行', icon: Icons.format_list_numbered, shortcut: 'Ctrl+G')),
                  if (hasEncoding)
                    PopupMenuItem(value: 'encoding', child: MenuLabel(
                      '文本编码 · ${textEncodings[_document.encoding] ?? _document.encoding}', icon: Icons.translate)),
                  if (hasAi) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'review',
                      child: MenuLabel('AI 修改', icon: Icons.auto_fix_high_outlined)),
                    if (_inlineRequest == null)
                      const PopupMenuItem(value: 'complete',
                        child: MenuLabel('AI 续写', icon: Icons.bolt_outlined, shortcut: 'Alt+\\')),
                    if (compact && _inlineRequest != null)
                      const PopupMenuItem(value: 'complete',
                        child: MenuLabel('取消 AI 续写', icon: Icons.stop_rounded)),
                  ],
                  if (model.supported) ...[
                    const PopupMenuDivider(),
                    PopupMenuItem(value: 'language', child: MenuLabel(
                      _document.languageSyncEligible ? '配置语言服务' : '配置语言服务（同步已暂停）', icon: Icons.code)),
                    if (session?.active == true)
                      for (final action in LanguageAction.values)
                        PopupMenuItem(value: action, child: Text(languageActionLabels[action]!)),
                  ],
                ];
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    switch (_phase) {
      case _Phase.loading:
        return const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _Phase.refused:
        if (_largePreview) {
          return LargeTextReader(
            ws: widget.ws,
            document: _document,
            onBack: () => setState(() => _largePreview = false),
          );
        }
        return Column(
          children: [
            Expanded(
              child: EmptyHint(icon: Icons.block, text: _message),
            ),
            if (widget.ws.link?.server.caps.contains('fs.text') == true)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => chooseTextEncoding(context, _document),
                      child: const Text('选择读取编码'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _largePreview = true),
                      child: const Text('大文件阅读模式'),
                    ),
                  ],
                ),
              ),
          ],
        );
      case _Phase.failed:
        return EmptyHint(
          icon: Icons.error_outline,
          text: _message,
          actionLabel: '重试',
          onAction: () {
            setState(() => _phase = _Phase.loading);
            _load();
          },
        );
      case _Phase.ready:
        break;
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lang = _document.large ? null : languageFor(widget.path);
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
      indentGuideColor: ide.border.withValues(alpha: 0.65),
      bracketMatchColor: ide.accent.withValues(alpha: 0.55),
      wordHighlightColor: ide.accent.withValues(alpha: 0.25),
      hintTextColor: ide.textDim,
      codeTheme: lang == null
          ? null
          : CodeHighlightTheme(
              languages: {lang.name: lang.mode},
              theme: dark ? vs2015Theme : githubTheme,
            ),
    );
    final pk = previewOf(widget.path);
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: ide.tabBar,
            border: Border(
              bottom: BorderSide(color: ide.border.withValues(alpha: 0.75)),
            ),
          ),
          child: LayoutBuilder(
            builder: (_, box) {
              final bread = _BreadcrumbBar(
                ws: widget.ws,
                root: widget.root,
                path: widget.path,
                dirtyNotifier: _dirtyNotifier,
                onReload: () => _reload(note: '已重新载入'),
              );
              return Row(
                key: const ValueKey('editor-command-row'),
                children: [
                  Expanded(child: bread),
                  _buildEditorToolbar(ide, pk, width: box.maxWidth),
                ],
              );
            },
          ),
        ),
        if (_document.recovered || _document.recoveryError != null)
          Container(
            color: ide.selection.withValues(alpha: .35),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.restore, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _document.recoveryError ?? '已恢复上次未保存的编辑内容',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (_document.recoveryError != null)
                  TextButton(
                    onPressed: () async {
                      await _document.retryRecovery();
                      if (mounted) setState(() {});
                    },
                    child: const Text('重试'),
                  ),
              ],
            ),
          ),
        if (_outside != null)
          Container(
            key: const ValueKey('outside'),
            color: ide.warn.withValues(alpha: 0.14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Row(
              children: [
                Icon(Icons.warning_amber, size: 15, color: ide.warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _outside == 'deleted'
                        ? '这个文件已在服务器上被删除或移走。编辑器里的内容还在。'
                        : '这个文件在服务器上被别的程序修改了，你这里还有未保存的修改。',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (_outside == 'changed')
                  TextButton(
                    onPressed: () => showDocumentMerge(context, _document),
                    child: const Text('比较并合并'),
                  ),
                if (_outside == 'changed')
                  TextButton(
                    onPressed: () async {
                      if (await confirmDialog(
                        context,
                        title: '放弃你的修改？',
                        body: '载入服务器上的新内容，你未保存的修改会丢失。',
                        ok: '放弃并重新载入',
                        danger: true,
                      )) {
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
                if (_outside == 'changed')
                  TextButton(
                    onPressed: () => setState(() => _outside = null),
                    child: const Text('保留我的修改'),
                  ),
              ],
            ),
          ),
        if (_document.inlineSuggestion case final suggestion?)
          Container(
            color: ide.accentSoft,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 14, color: ide.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: suggestion.chunks.single.replacement,
                    child: Text(
                      'AI 行内续写建议 · Tab 接受 · Esc 拒绝',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: ide.text),
                    ),
                  ),
                ),
                TextButton(onPressed: _acceptInline, child: const Text('接受')),
                TextButton(
                  onPressed: () => _document.suggestInline(null),
                  child: const Text('拒绝'),
                ),
              ],
            ),
          ),
        if (_document.snippet case final snippet?)
          Container(
            color: ide.tabBar,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: ListenableBuilder(
            listenable: snippet,
            builder: (_, _) => Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('片段 · Tab 下一项 · Esc 结束'),
                ),
                if (snippet.current?.choices.isNotEmpty == true)
                  PopupMenuButton<String>(
                    tooltip: '选择片段字段值',
                    onSelected: (value) {
                      snippet.choose(value);
                      _editorFocus.requestFocus();
                    },
                    itemBuilder: (_) => [
                      for (final choice in snippet.current!.choices)
                        PopupMenuItem(
                          value: choice,
                          child: Text(choice.isEmpty ? '（空）' : choice),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('选择字段值…'),
                    ),
                  ),
                IconBtn(Icons.navigate_before, '上一个片段字段', () {
                  snippet.advance(backward: true);
                  _editorFocus.requestFocus();
                }),
                IconBtn(Icons.navigate_next, '下一个片段字段', () {
                  snippet.advance();
                  _editorFocus.requestFocus();
                }),
                IconBtn(Icons.close, '结束片段编辑', snippet.close),
              ],
            ),
            ),
          ),
        // One viewport, two stable layers. An offstage Expanded sibling still
        // consumes half the height and can retain keyboard focus behind preview.
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Offstage(
                key: const ValueKey('editor'),
                offstage: _preview && pk != PreviewKind.none,
                child: TickerMode(
                  enabled: !_preview || pk == PreviewKind.none,
                  child: ExcludeFocus(
                    excluding: _preview && pk != PreviewKind.none,
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.backslash,
                          alt: true,
                        ): _completeInline,
                        if (_document.snippet == null &&
                            _document.inlineSuggestion != null) ...{
                          const SingleActivator(LogicalKeyboardKey.tab):
                              _acceptInline,
                          const SingleActivator(
                            LogicalKeyboardKey.escape,
                          ): () =>
                              _document.suggestInline(null),
                        },
                        if (_document.snippet != null) ...{
                          const SingleActivator(LogicalKeyboardKey.tab): () =>
                              _document.snippet?.advance(),
                          const SingleActivator(
                            LogicalKeyboardKey.tab,
                            shift: true,
                          ): () =>
                              _document.snippet?.advance(backward: true),
                          const SingleActivator(
                            LogicalKeyboardKey.escape,
                          ): () =>
                              _document.snippet?.close(),
                        },
                        const SingleActivator(
                          LogicalKeyboardKey.keyS,
                          control: true,
                        ): save,
                        const SingleActivator(
                          LogicalKeyboardKey.keyG,
                          control: true,
                        ): goToLine,
                        const SingleActivator(
                          LogicalKeyboardKey.keyZ,
                          alt: true,
                        ): toggleWrap,
                        const SingleActivator(
                          LogicalKeyboardKey.keyH,
                          control: true,
                        ): _openReplace,
                        const SingleActivator(
                          LogicalKeyboardKey.slash,
                          control: true,
                        ): () => _toggleComment(single: true),
                        const SingleActivator(
                          LogicalKeyboardKey.keyA,
                          shift: true,
                          alt: true,
                        ): () => _toggleComment(single: false),
                        const SingleActivator(
                          LogicalKeyboardKey.keyD,
                          control: true,
                        ): _selectCurrentWord,
                        const SingleActivator(
                          LogicalKeyboardKey.keyK,
                          control: true,
                          shift: true,
                        ): () {
                          if (!_readOnly) _controller.deleteSelectionLines(true);
                        },
                        const SingleActivator(
                          LogicalKeyboardKey.arrowDown,
                          shift: true,
                          alt: true,
                        ): () => _duplicateLines(down: true),
                        const SingleActivator(
                          LogicalKeyboardKey.arrowUp,
                          shift: true,
                          alt: true,
                        ): () => _duplicateLines(down: false),
                        const SingleActivator(
                          LogicalKeyboardKey.enter,
                          control: true,
                        ): () => _insertBlankLine(above: false),
                        const SingleActivator(
                          LogicalKeyboardKey.enter,
                          control: true,
                          shift: true,
                        ): () => _insertBlankLine(above: true),
                        const SingleActivator(
                          LogicalKeyboardKey.bracketRight,
                          control: true,
                        ): _indentLines,
                        const SingleActivator(
                          LogicalKeyboardKey.bracketLeft,
                          control: true,
                        ): () {
                          if (!_readOnly) _controller.applyOutdent();
                        },
                        const SingleActivator(
                          LogicalKeyboardKey.space,
                          control: true,
                        ): () => runLanguageAction(
                          context,
                          widget.ws,
                          _document,
                          LanguageAction.completion,
                        ),
                        const SingleActivator(LogicalKeyboardKey.f12): () =>
                            runLanguageAction(
                              context,
                              widget.ws,
                              _document,
                              LanguageAction.definition,
                            ),
                        const SingleActivator(
                          LogicalKeyboardKey.f12,
                          shift: true,
                        ): () => runLanguageAction(
                          context,
                          widget.ws,
                          _document,
                          LanguageAction.references,
                        ),
                        const SingleActivator(
                          LogicalKeyboardKey.period,
                          control: true,
                        ): () => runLanguageAction(
                          context,
                          widget.ws,
                          _document,
                          LanguageAction.codeAction,
                        ),
                        const SingleActivator(LogicalKeyboardKey.f2): () =>
                            runLanguageAction(
                              context,
                              widget.ws,
                              _document,
                              LanguageAction.rename,
                            ),
                        const SingleActivator(
                          LogicalKeyboardKey.keyF,
                          alt: true,
                          shift: true,
                        ): () => runLanguageAction(
                          context,
                          widget.ws,
                          _document,
                          LanguageAction.format,
                        ),
                        const SingleActivator(LogicalKeyboardKey.f9): () =>
                            toggleCursorBreakpoint(widget.ws, _document),
                        const SingleActivator(LogicalKeyboardKey.f5): () {
                          if (widget.ws.debugger.stopped) {
                            widget.ws.debugger
                                .control('continue')
                                .catchError(
                                  (Object e) =>
                                      widget.ws.toast('$e', error: true),
                                );
                          } else if (!widget.ws.debugger.active) {
                            startConfiguredDebug(context, widget.ws);
                          }
                        },
                        const SingleActivator(
                          LogicalKeyboardKey.f5,
                          shift: true,
                        ): widget.ws.debugger.stop,
                        const SingleActivator(LogicalKeyboardKey.f10): () =>
                            widget.ws.debugger
                                .control('next')
                                .catchError(
                                  (Object e) =>
                                      widget.ws.toast('$e', error: true),
                                ),
                        const SingleActivator(LogicalKeyboardKey.f11): () =>
                            widget.ws.debugger
                                .control('stepIn')
                                .catchError(
                                  (Object e) =>
                                      widget.ws.toast('$e', error: true),
                                ),
                        const SingleActivator(
                          LogicalKeyboardKey.f11,
                          shift: true,
                        ): () => widget.ws.debugger
                            .control('stepOut')
                            .catchError(
                              (Object e) => widget.ws.toast('$e', error: true),
                            ),
                      },
                      child: CodeEditor(
                        findController: _findController,
                        toolbarController: _EditorContextMenuController(
                          ws: widget.ws,
                          document: _document,
                          readOnly: _readOnly,
                          onToggleComment: () => _toggleComment(single: true),
                          onDuplicateLine: () => _duplicateLines(down: true),
                          onFind: () => _findController?.findMode(),
                          onGoToLine: goToLine,
                          onAiInline: _completeInline,
                        ),
                        commentFormatter: commentFormatterFor(widget.path),
                        shortcutsActivatorsBuilder:
                            const _VsCodeShortcutsActivatorsBuilder(),
                        ghostText: _document
                            .inlineSuggestion
                            ?.chunks
                            .single
                            .replacement,
                        focusNode: _editorFocus,
                        shortcutOverrideActions: {
                          CodeShortcutCommentIntent:
                              CallbackAction<CodeShortcutCommentIntent>(
                                onInvoke: (intent) {
                                  _toggleComment(single: intent.single);
                                  return null;
                                },
                              ),
                          CodeShortcutIndentIntent:
                              CallbackAction<CodeShortcutIndentIntent>(
                                onInvoke: (_) {
                                  final snippet = _document.snippet;
                                  if (snippet != null) {
                                    snippet.advance();
                                  } else if (_document.inlineSuggestion !=
                                      null) {
                                    _acceptInline();
                                  } else {
                                    _controller.applyIndent();
                                  }
                                  return null;
                                },
                              ),
                          CodeShortcutOutdentIntent:
                              CallbackAction<CodeShortcutOutdentIntent>(
                                onInvoke: (_) {
                                  final snippet = _document.snippet;
                                  if (snippet != null) {
                                    snippet.advance(backward: true);
                                  } else {
                                    _controller.applyOutdent();
                                  }
                                  return null;
                                },
                              ),
                          if (_document.snippet != null ||
                              _document.inlineSuggestion != null)
                            CodeShortcutEscIntent:
                                CallbackAction<CodeShortcutEscIntent>(
                                  onInvoke: (_) {
                                    _document.snippet?.close();
                                    _document.suggestInline(null);
                                    return null;
                                  },
                                ),
                        },
                        controller: _controller,
                        style: style,
                        readOnly: _readOnly,
                        wordWrap: _document.large
                            ? false
                            : _wrap ?? _settings.wordWrap,
                        autofocus: true,
                        findBuilder: (context, controller, readOnly) =>
                            _FindPanel(
                              controller: controller,
                              readOnly: readOnly,
                            ),
                        indicatorBuilder:
                            (
                              context,
                              editingController,
                              chunkController,
                              notifier,
                            ) => Row(
                              children: [
                                if (widget.ws.debugger.supported)
                                  BreakpointGutter(
                                    ws: widget.ws,
                                    document: _document,
                                    notifier: notifier,
                                  ),
                                DefaultCodeLineNumber(
                                  controller: editingController,
                                  notifier: notifier,
                                ),
                                DefaultCodeChunkIndicator(
                                  width: 18,
                                  controller: chunkController,
                                  notifier: notifier,
                                ),
                              ],
                            ),
                        chunkAnalyzer: const DefaultCodeChunkAnalyzer(),
                        padding: const EdgeInsets.only(left: 4, right: 12),
                        verticalScrollbarWidth: 10,
                        horizontalScrollbarHeight: 10,
                      ),
                    ),
                  ),
                ),
              ),
              if (_preview && pk != PreviewKind.none)
                Positioned.fill(
                  key: const ValueKey('preview'),
                  child: pk == PreviewKind.markdown
                      ? MarkdownPreview(
                          text: _controller.text,
                          onOpenFile: (target) {
                            final p = target.path.replaceAll('\\', '/');
                            if (p.endsWith('/')) {
                              widget.ws.toast('这是文件夹路径：$p');
                              return;
                            }
                            final resolved = p.startsWith('/')
                                ? WorkspacePath.normalize(p)
                                : WorkspacePath.normalize(
                                    '${widget.path.substring(0, widget.path.lastIndexOf('/') + 1)}$p',
                                  );
                            openFileAt(
                              widget.ws,
                              root: widget.root,
                              path: resolved,
                              line: target.line,
                              col: target.col,
                            );
                          },
                        )
                      : CsvPreview(
                          text: _controller.text,
                          tabSeparated: extOf(widget.path) == 'tsv',
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A compact find and replace bar in the IDE's colours.
class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  final bool readOnly;
  const _FindPanel({required this.controller, required this.readOnly});

  @override
  Size get preferredSize => Size(
    double.infinity,
    controller.value == null ? 0 : (controller.value!.replaceMode ? 78 : 40),
  );

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final ide = Ide.of(context);
    final queryEmpty = controller.findInputController.text.isEmpty;
    final result = queryEmpty
        ? ''
        : v.result == null
        ? '无结果'
        : '${v.result!.index + 1}/${v.result!.matches.length}';
    Widget field(
      TextEditingController c,
      FocusNode? f,
      String hint, {
      List<Widget> tail = const [],
      VoidCallback? onEnter,
      VoidCallback? onShiftEnter,
      VoidCallback? onCtrlAltEnter,
    }) => SizedBox(
      height: 30,
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            controller.close();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            final kb = HardwareKeyboard.instance;
            if ((kb.isControlPressed || kb.isMetaPressed) &&
                kb.isAltPressed &&
                onCtrlAltEnter != null) {
              onCtrlAltEnter();
              return KeyEventResult.handled;
            }
            if (kb.isShiftPressed && onShiftEnter != null) {
              onShiftEnter();
              return KeyEventResult.handled;
            }
            if (onEnter != null) {
              onEnter();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: c,
          focusNode: f,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            suffixIcon: tail.isEmpty
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: tail),
          ),
        ),
      ),
    );
    Widget toggle(String label, String tip, bool on, VoidCallback tap) =>
        Tooltip(
          message: tip,
          child: InkWell(
            onTap: tap,
            borderRadius: BorderRadius.circular(3),
            child: Container(
              width: 26,
              height: 22,
              alignment: Alignment.center,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: on ? ide.selection : null,
                borderRadius: BorderRadius.circular(3),
                border: on ? Border.all(color: ide.accent) : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: on ? ide.text : ide.textDim,
                ),
              ),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: ide.sideBar,
        border: Border(bottom: BorderSide(color: ide.border)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: field(
                  controller.findInputController,
                  controller.findInputFocusNode,
                  '查找（Enter 下一个，Shift+Enter 上一个）',
                  onEnter: controller.nextMatch,
                  onShiftEnter: controller.previousMatch,
                  tail: [
                    toggle(
                      'Aa',
                      '区分大小写',
                      v.option.caseSensitive,
                      controller.toggleCaseSensitive,
                    ),
                    toggle(
                      '.*',
                      '正则表达式',
                      v.option.regex,
                      controller.toggleRegex,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                child: Text(
                  result,
                  style: TextStyle(fontSize: 12, color: ide.textDim),
                ),
              ),
              IconBtn(Icons.keyboard_arrow_up, '上一个（Shift+Enter）', controller.previousMatch),
              IconBtn(Icons.keyboard_arrow_down, '下一个（Enter）', controller.nextMatch),
              if (!readOnly)
                IconBtn(
                  v.replaceMode ? Icons.unfold_less : Icons.find_replace,
                  v.replaceMode ? '收起替换' : '替换',
                  controller.toggleMode,
                ),
              IconBtn(Icons.close, '关闭（Esc）', controller.close),
            ],
          ),
          if (v.replaceMode && !readOnly) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: field(
                    controller.replaceInputController,
                    controller.replaceInputFocusNode,
                    '替换为（Enter 替换，Ctrl+Alt+Enter 全部）',
                    onEnter: controller.replaceMatch,
                    onCtrlAltEnter: controller.replaceAllMatches,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: controller.replaceMatch,
                  child: const Text('替换'),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: controller.replaceAllMatches,
                  child: const Text('全部替换'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BreadcrumbBar extends StatelessWidget {
  final Workspace ws;
  final String root;
  final String path;
  final ValueNotifier<bool> dirtyNotifier;
  final VoidCallback onReload;

  const _BreadcrumbBar({
    required this.ws,
    required this.root,
    required this.path,
    required this.dirtyNotifier,
    required this.onReload,
  });

  String _relativePath() {
    final folders = ws.project?.folders ?? const <WorkspacePath>[];
    final sorted = [...folders]
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final f in sorted) {
      if (f.root == root &&
          (path == f.path ||
              path.startsWith(f.path == '/' ? '/' : '${f.path}/'))) {
        if (f.path == '/') return path.startsWith('/') ? path.substring(1) : path;
        return path.substring(f.path.length + 1);
      }
    }
    return path;
  }

  Future<void> _showFolderMenu(BuildContext ctx, String folderPath) async {
    final link = ws.link;
    if (link == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset(0, box.size.height));
    try {
      final res = await link.call('fs.list', {
        'root': root,
        'path': folderPath,
        'hidden': false,
      }) as Map;
      if (!ctx.mounted) return;
      final raw = (res['entries'] as List? ?? const [])
          .whereType<Map>()
          .toList()
        ..sort((a, b) {
          final ad = a['type'] == 'dir' || a['target'] == 'dir';
          final bd = b['type'] == 'dir' || b['target'] == 'dir';
          if (ad != bd) return ad ? -1 : 1;
          return '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase());
        });
      final items = <MenuItem>[
        for (final e in raw.take(40))
          if (e['type'] != 'dir' && e['target'] != 'dir')
            MenuItem(
              '${e['name']}',
              () => openFileAt(
                ws,
                root: root,
                path: folderPath == '/' ? '/${e['name']}' : '$folderPath/${e['name']}',
              ),
              icon: fileIconSpec('${e['name']}').icon,
            ),
      ];
      if (items.isEmpty) {
        ws.toast('此目录下没有可直接打开的文件');
        return;
      }
      await showMenuAt(ctx, at, items, anchor: ctx);
    } on OpError catch (e) {
      ws.toast(e.message, error: true);
    }
  }

  void _showFileMenu(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final native = ws.entry?.isLocal == true
        ? ws.app.localAgent.nativePath(root, path)
        : path;
    showMenuAt(ctx, at, [
      MenuItem(
        '复制文件路径',
        () => copyText(native, what: '已复制路径'),
        icon: Icons.copy,
      ),
      MenuItem(
        '复制相对路径',
        () => copyText(_relativePath(), what: '已复制相对路径'),
        icon: Icons.content_copy,
      ),
      const MenuItem.separator(),
      MenuItem('重新载入文件内容', onReload, icon: Icons.refresh),
    ], anchor: ctx);
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return const SizedBox.shrink();
    final fullCopy = ws.entry?.isLocal == true
        ? ws.app.localAgent.nativePath(root, path)
        : '$root:$path';

    Widget crumb({
      required String label,
      required Widget? leading,
      required bool current,
      required void Function(BuildContext ctx) onTap,
    }) => Builder(
      builder: (ctx) => InkWell(
        onTap: () => onTap(ctx),
        borderRadius: BorderRadius.circular(Radii.s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 4)],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: current ? FontWeight.w500 : FontWeight.w400,
                  color: current ? ide.text : ide.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Container(
      key: const ValueKey('editor-breadcrumbs'),
      height: 24,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Tooltip(
        message: fullCopy,
        waitDuration: const Duration(milliseconds: 700),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < parts.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 14,
                      color: ide.textFaint,
                    ),
                  ),
                if (i < parts.length - 1)
                  crumb(
                    label: parts[i],
                    leading: null,
                    current: false,
                    onTap: (ctx) => _showFolderMenu(
                      ctx,
                      '/${parts.take(i + 1).join('/')}',
                    ),
                  )
                else
                  ValueListenableBuilder<bool>(
                    valueListenable: dirtyNotifier,
                    builder: (_, isDirty, _) => crumb(
                      label: isDirty ? '${parts[i]} ●' : parts[i],
                      leading: FileIcon(name: parts[i], size: 13),
                      current: true,
                      onTap: _showFileMenu,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorContextMenuController implements SelectionToolbarController {
  final Workspace ws;
  final DocumentModel document;
  final bool readOnly;
  final VoidCallback onToggleComment;
  final VoidCallback onDuplicateLine;
  final VoidCallback onFind;
  final VoidCallback onGoToLine;
  final VoidCallback onAiInline;

  _EditorContextMenuController({
    required this.ws,
    required this.document,
    required this.readOnly,
    required this.onToggleComment,
    required this.onDuplicateLine,
    required this.onFind,
    required this.onGoToLine,
    required this.onAiInline,
  });

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    final at = anchors.primaryAnchor;
    final hasSelection = !controller.selection.isCollapsed;
    final session = ws.development.supported
        ? ws.development.sessionFor(document)
        : null;
    final lspReady = session != null && session.active;
    final hasAi = ws.link?.server.caps.contains('ai.propose') == true;
    final path = document.key.path;
    final fullPath = ws.entry?.isLocal == true
        ? ws.app.localAgent.nativePath(document.key.root, path)
        : path;

    showMenuAt(context, at, [
      if (lspReady) ...[
        MenuItem(
          '转到定义',
          () => runLanguageAction(context, ws, document, LanguageAction.definition),
          icon: Icons.call_made,
          hint: 'F12',
        ),
        MenuItem(
          '查找引用',
          () => runLanguageAction(context, ws, document, LanguageAction.references),
          icon: Icons.manage_search,
          hint: 'Shift+F12',
        ),
        MenuItem(
          '查看类型与文档',
          () => runLanguageAction(context, ws, document, LanguageAction.hover),
          icon: Icons.info_outline,
        ),
        MenuItem(
          '重命名符号…',
          () => runLanguageAction(context, ws, document, LanguageAction.rename),
          icon: Icons.drive_file_rename_outline,
          hint: 'F2',
        ),
        MenuItem(
          '代码操作',
          () => runLanguageAction(context, ws, document, LanguageAction.codeAction),
          icon: Icons.lightbulb_outline,
          hint: 'Ctrl+.',
        ),
        MenuItem(
          '格式化文档',
          () => runLanguageAction(context, ws, document, LanguageAction.format),
          icon: Icons.format_align_left,
          hint: 'Shift+Alt+F',
        ),
        const MenuItem.separator(),
      ],
      if (!readOnly)
        MenuItem(
          '剪切',
          controller.cut,
          icon: Icons.content_cut,
          hint: 'Ctrl+X',
        ),
      MenuItem(
        hasSelection ? '复制' : '复制当前行',
        controller.copy,
        icon: Icons.content_copy_outlined,
        hint: 'Ctrl+C',
      ),
      if (!readOnly)
        MenuItem(
          '粘贴',
          controller.paste,
          icon: Icons.content_paste,
          hint: 'Ctrl+V',
        ),
      MenuItem(
        '全选',
        controller.selectAll,
        icon: Icons.select_all,
        hint: 'Ctrl+A',
      ),
      if (!readOnly) ...[
        const MenuItem.separator(),
        MenuItem(
          '切换行注释',
          onToggleComment,
          icon: Icons.comment_outlined,
          hint: 'Ctrl+/',
        ),
        MenuItem(
          '向下复制行',
          onDuplicateLine,
          icon: Icons.content_copy,
          hint: 'Shift+Alt+↓',
        ),
      ],
      if (hasAi && !readOnly) ...[
        const MenuItem.separator(),
        MenuItem(
          'AI 修改…',
          () => openAiEditReview(ws, document),
          icon: Icons.auto_fix_high_outlined,
        ),
        MenuItem(
          'AI 续写',
          onAiInline,
          icon: Icons.bolt_outlined,
          hint: 'Alt+\\',
        ),
      ],
      const MenuItem.separator(),
      MenuItem('查找与替换', onFind, icon: Icons.search_rounded, hint: 'Ctrl+F'),
      MenuItem('转到行…', onGoToLine, icon: Icons.format_list_numbered_rounded, hint: 'Ctrl+G'),
      MenuItem(
        '复制文件路径',
        () => copyText(fullPath, what: '已复制路径'),
        icon: Icons.copy,
      ),
    ]);
  }
}

class _VsCodeShortcutsActivatorsBuilder
    extends DefaultCodeShortcutsActivatorsBuilder {
  const _VsCodeShortcutsActivatorsBuilder();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    final base = super.build(type);
    if (defaultTargetPlatform == TargetPlatform.macOS) return base;
    return switch (type) {
      CodeShortcutType.newLine => const [
        SingleActivator(LogicalKeyboardKey.enter),
        SingleActivator(LogicalKeyboardKey.enter, shift: true),
        SingleActivator(LogicalKeyboardKey.numpadEnter),
        SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true),
      ],
      CodeShortcutType.redo => const [
        SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
        SingleActivator(LogicalKeyboardKey.keyY, control: true),
      ],
      CodeShortcutType.replace => const [
        SingleActivator(LogicalKeyboardKey.keyF, control: true, alt: true),
        SingleActivator(LogicalKeyboardKey.keyH, control: true),
      ],
      CodeShortcutType.multiLineComment => const [
        SingleActivator(LogicalKeyboardKey.slash, control: true, shift: true),
        SingleActivator(LogicalKeyboardKey.keyA, shift: true, alt: true),
      ],
      // Free Ctrl+D for VS Code "Select Word"; Ctrl+Shift+K deletes the line.
      CodeShortcutType.lineDelete => const [
        SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true),
      ],
      _ => base,
    };
  }
}
