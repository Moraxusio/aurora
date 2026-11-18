// Search across files (service "files", fs.search), in the side bar like an
// IDE: the query with case / whole word / regex toggles, include and exclude
// globs, results grouped by file with the match highlighted. A click opens
// the file at the match. Ctrl+Shift+F opens it from anywhere.
//
// Quick open (Ctrl+P, fs.find) lives in quick_open.dart and is a command of
// this feature, so both disappear together when the files service is off.
import 'dart:async';

import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/feature.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../files/file_editor.dart';
import '../development/language_actions.dart';
import 'quick_open.dart';
import 'search_model.dart';
import 'search_scope.dart';

class SearchFeature extends Feature {
  const SearchFeature();

  @override
  String get id => 'search';
  @override
  String get title => '搜索';
  @override
  IconData get icon => Icons.search;
  @override
  String get service => 'files';
  @override
  List<String> get ops => const ['fs.search', 'fs.find', 'fs.read'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(
    title: '搜索',
    body: SearchPanel(ws: ws),
  );

  @override
  List<Command> commands(Workspace ws) => [
    Command(
      id: 'search.quickOpen',
      title: '按文件名打开…',
      group: '文件',
      icon: Icons.find_in_page_outlined,
      shortcut: 'Ctrl+P',
      run: () => showQuickOpen(ws),
    ),
    Command(
      id: 'search.find',
      title: '在文件中搜索',
      group: '搜索',
      icon: Icons.search,
      shortcut: 'Ctrl+Shift+F',
      run: () => ws.focusSearch.value++,
    ),
  ];
}

class SearchPanel extends StatefulWidget {
  final Workspace ws;
  final SearchModel? model; // tests
  const SearchPanel({super.key, required this.ws, this.model});
  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  late final SearchModel _m = widget.model ?? SearchModel(widget.ws);
  final _query = TextEditingController();
  final _include = TextEditingController();
  final _exclude = TextEditingController();
  final _replacement = TextEditingController();
  final _focus = FocusNode();
  bool _regex = false,
      _case = false,
      _word = false,
      _globs = false,
      _replace = false;
  final Set<SearchFile> _collapsed = {};
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _m.addListener(_tick);
    for (final c in [_query, _include, _exclude]) {
      c.addListener(_changed);
    }
    widget.ws.focusSearch.addListener(_focusQuery);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusQuery());
  }

  void _focusQuery() {
    if (!mounted) return;
    _focus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.ws.focusSearch.removeListener(_focusQuery);
    _m.removeListener(_tick);
    if (widget.model == null) _m.dispose();
    _query.dispose();
    _include.dispose();
    _exclude.dispose();
    _replacement.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  String _last = '';

  // Searching as you type, after a pause: a server search reads files, so not
  // on every key press.
  void _changed() {
    final key =
        '${_query.text}\u0000${_include.text}\u0000${_exclude.text}\u0000$_regex$_case$_word';
    if (key == _last) return;
    _last = key;
    _debounce?.cancel();
    _m.clear();
    _debounce = Timer(const Duration(milliseconds: 400), _run);
  }

  void _run() {
    _debounce?.cancel();
    _collapsed.clear();
    _m.search(
      SearchOptions(
        _query.text,
        regex: _regex,
        matchCase: _case,
        word: _word,
        include: _include.text,
        exclude: _exclude.text,
      ),
    );
  }

  void _toggle(void Function() f) {
    setState(f);
    _changed();
  }

  Future<void> _previewReplacement() async {
    try {
      final plan = await _m.previewReplacement(_replacement.text);
      if (!mounted) return;
      if (plan.edits.isEmpty) {
        widget.ws.toast('当前文件内容没有需要替换的匹配');
        return;
      }
      final accepted = await reviewDocumentEdits(
        context,
        plan,
        allowSave: true,
        detail: '替换当前搜索结果中的 ${plan.edits.length} 个文件；保存将包含这些文件已有的未保存编辑。',
      );
      if (!accepted) return;
      if (!plan.applied) plan.apply();
      for (final edit in plan.edits) {
        openFileAt(
          widget.ws,
          root: edit.document.key.root,
          path: edit.document.key.path,
        );
      }
    } on Object catch (e) {
      if (mounted) widget.ws.toast('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    Widget toggle(String label, String tip, bool on, VoidCallback tap) =>
        Tooltip(
          message: tip,
          child: Semantics(toggled: on, child: TextButton(
            onPressed: tap,
            style: TextButton.styleFrom(backgroundColor: on ? ide.accentSoft : null,
              foregroundColor: on ? ide.accent : ide.textDim),
            child: Text(label),
          )),
        );
    Widget field(
      TextEditingController c,
      String hint, {
      FocusNode? focus,
      List<Widget> tail = const [],
    }) => TextField(
        controller: c,
        focusNode: focus,
        style: const TextStyle(fontSize: 13),
        onSubmitted: (_) => _run(),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          suffixIcon: tail.isEmpty
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: tail),
        ),
    );
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(padding: const EdgeInsets.only(bottom: Space.m),
                child: Text('范围：${widget.ws.project?.name ?? '全部文件根'}',
                  style: TextStyle(color: ide.textDim, fontSize: 11.5))),
              if (_m.running || _m.replacing)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      _m.cancel();
                      setState(() {});
                    },
                    icon: const Icon(Icons.stop, size: 14),
                    label: Text(_m.replacing ? '停止替换预览' : '停止搜索'),
                  ),
                ),
              field(
                _query,
                '搜索',
                focus: _focus,
                tail: [IconBtn(Icons.search, '立即搜索 / 重新搜索', _m.running ? null : _run)],
              ),
              Wrap(spacing: Space.xs, children: [
                  toggle(
                    'Aa',
                    '区分大小写',
                    _case,
                    () => _toggle(() => _case = !_case),
                  ),
                  toggle(
                    'ab',
                    '全字匹配',
                    _word,
                    () => _toggle(() => _word = !_word),
                  ),
                  toggle(
                    '.*',
                    '正则表达式',
                    _regex,
                    () => _toggle(() => _regex = !_regex),
                  ),
              ]),
              Wrap(
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _replace = !_replace),
                    child: Text(_replace ? '隐藏替换' : '跨文件替换…'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _globs = !_globs),
                    child: Text(
                      _globs ? '隐藏文件筛选' : '文件筛选…',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (_replace) ...[
                field(
                  _replacement,
                  _regex ? r'替换为（$1、${name}、$$）' : '替换为（可留空）',
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _m.running || _m.replacing || _m.results.isEmpty || _m.incomplete || _m.timedOut || _m.truncated
                        ? null
                        : _previewReplacement,
                    icon: const Icon(Icons.find_replace, size: 16),
                    label: const Text('预览替换结果'),
                  ),
                ),
              ],
              if (_globs) ...[
                field(_include, '包含的文件，如 *.go, src/**'),
                const SizedBox(height: 4),
                field(_exclude, '排除的文件，如 *_test.go, vendor/'),
                const SizedBox(height: 4),
              ],
            ],
          ),
        ),
        _summary(ide),
        const Divider(),
        ])),
        _results(ide),
      ],
    );
  }

  Widget _summary(Ide ide) {
    final files = _m.results.length;
    String text;
    if (_m.error != null) {
      text = _m.error!;
    } else if (_m.running && files == 0) {
      text = '正在搜索…';
    } else if (_query.text.isEmpty) {
      text = '输入关键词搜索文件内容';
    } else if (files == 0) {
      text = '没有结果';
    } else {
      text = '${_m.total} 个结果，$files 个文件${_m.running ? '，继续搜索…' : ''}';
      if (_m.timedOut) {
        text += '（搜索超时，结果不完整）';
      } else if (_m.truncated) {
        text += '（结果太多，只显示一部分）';
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty)
            Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: _m.error != null ? ide.error : ide.textDim,
              ),
            ),
          for (final n in _m.notes)
            Text(n, style: TextStyle(fontSize: 11, color: ide.warn)),
        ],
      ),
    );
  }

  Widget _results(Ide ide) {
    final rows = <(SearchFile, SearchLine?)>[];
    for (final f in _m.results) {
      rows.add((f, null));
      if (!_collapsed.contains(f)) {
        rows.addAll(f.lines.map((l) => (f, l)));
      }
    }
    return SliverList.builder(
      itemCount: rows.length,
      itemBuilder: (_, index) {
        final (f, l) = rows[index];
        if (l != null) {
          return _LineRow(
            file: f,
            line: l,
            onTap: () => openFileAt(
              widget.ws,
              root: f.folder.root,
              path: f.path,
              line: l.line,
              col: l.col,
            ),
          );
        }
        final open = !_collapsed.contains(f);
        final name = f.path.split('/').last;
        final dir = displayPath(
          f.folder,
          f.path.substring(0, f.path.length - name.length),
        );
        return TreeRow(
          leading: Icon(
            open ? Icons.expand_more : Icons.chevron_right,
            size: 16,
            color: ide.textDim,
          ),
          label: name,
          detail: dir,
          trailing: Text(
            '${f.lines.length}',
            style: TextStyle(fontSize: 11, color: ide.textDim),
          ),
          onTap: () =>
              setState(() => open ? _collapsed.add(f) : _collapsed.remove(f)),
          menu: () => [
            MenuItem(
              '打开文件',
              () => openFileAt(widget.ws, root: f.folder.root, path: f.path),
              icon: Icons.edit_note,
            ),
            MenuItem(
              '复制路径',
              () => copyText(f.path, what: '已复制路径'),
              icon: Icons.copy,
            ),
          ],
        );
      },
    );
  }
}

class _LineRow extends StatelessWidget {
  final SearchFile file;
  final SearchLine line;
  final VoidCallback onTap;
  const _LineRow({required this.file, required this.line, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final t = line.text;
    final spans = <TextSpan>[];
    var at = 0;
    for (final (s0, e0) in line.ranges) {
      final s = s0.clamp(at, t.length), e = e0.clamp(s, t.length);
      if (s > at) spans.add(TextSpan(text: t.substring(at, s)));
      if (e > s)
        spans.add(
          TextSpan(
            text: t.substring(s, e),
            style: TextStyle(
              backgroundColor: ide.accent.withValues(alpha: 0.3),
              color: ide.text,
            ),
          ),
        );
      at = e;
    }
    if (at < t.length) spans.add(TextSpan(text: t.substring(at)));
    return InkWell(
      onTap: onTap,
      hoverColor: ide.hover,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 3, 8, 3),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              child: Text(
                '${line.line}',
                style: TextStyle(fontSize: 11, color: ide.textDim),
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(children: spans),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: Ide.mono,
                  fontFamilyFallback: Ide.monoFallback,
                  fontSize: 12.5,
                  color: ide.textDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
