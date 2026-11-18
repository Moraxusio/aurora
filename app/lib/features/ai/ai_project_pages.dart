part of 'ai_extensions.dart';

const _projectSections = <String, String>{
  'budget': '运行预算',
  'agents': '代理协作',
  'tools': '工具执行',
  'snapshots': '快照与回退',
  'instructions': '项目指令',
  'skills': '技能',
  'mcp': 'MCP 服务',
  'prices': '模型价格',
  'advanced': '高级 JSON',
};

extension _ProjectPages on _AiExtensionsViewState {
  Map<String, dynamic>? get _draft {
    try {
      final value = jsonDecode(_editor.text);
      return value is Map ? value.cast<String, dynamic>() : null;
    } on Object {
      return null;
    }
  }

  bool get _modern => (_data?['budget_version'] as num? ?? 1) >= 2;
  bool get _controls => (_data?['controls_version'] as num? ?? 0) >= 1;

  void _edit(void Function(Map<String, dynamic>) update) {
    final config = _draft;
    if (config == null) return;
    update(config);
    _change(() {
      _editor.text = const JsonEncoder.withIndent('  ').convert(config);
      _error = null;
    });
  }

  void _switchPage(String page) {
    if (_page == page) return;
    if (_page != 'advanced' && !(_form.currentState?.validate() ?? true))
      return;
    if (_draft == null && page != 'advanced') {
      _change(() => _error = 'JSON 尚未有效，请修正后再切换到表单。');
      return;
    }
    _change(() {
      _page = page;
      _formEpoch++;
    });
  }

  Widget _info(String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Notice(tone: Tone.info, title: title, body: body),
  );

  Widget _projectPages() {
    final config = _draft;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 740;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              Container(
                width: 186,
                decoration: BoxDecoration(
                  color: Ide.of(context).sideBar,
                  border: Border(
                    right: BorderSide(color: Ide.of(context).border),
                  ),
                ),
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '项目策略',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    for (final page in _projectSections.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: TextButton(
                          key: ValueKey('ai-project-nav-${page.key}'),
                          style: TextButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            backgroundColor: _page == page.key
                                ? Ide.of(context).accentSoft
                                : null,
                          ),
                          onPressed: () => _switchPage(page.key),
                          child: Text(page.value),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('ai-extensions-scroll'),
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'AI 项目配置',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            '${widget.root}:${widget.workdir}  ·  .aurora/ai.json',
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${_data?['source'] == 'default' || _data?['etag'] == '' ? '当前使用内置默认值' : '已读取项目配置'} · ${_dirty ? '有未保存修改' : '已保存'}',
                            key: const ValueKey('ai-project-source'),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '作用于此工作目录。发送时读取并固定策略；补充指令沿用当前任务，排队消息使用发送时的策略与独立预算。',
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton(
                                key: const ValueKey('ai-project-save'),
                                onPressed: _busy || _data == null
                                    ? null
                                    : () => _load(save: true),
                                child: Text(_busy ? '处理中…' : '保存 AI 配置'),
                              ),
                              OutlinedButton(
                                onPressed: _busy ? null : _reload,
                                child: const Text('重新读取'),
                              ),
                            ],
                          ),
                          if (_busy) const LinearProgressIndicator(),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: SelectableText(
                                _error!,
                                style: TextStyle(color: Ide.of(context).error),
                              ),
                            ),
                          const SizedBox(height: 16),
                          if (!wide)
                            AiPageNavigation(
                              pages: _projectSections,
                              selected: _page,
                              onSelected: _switchPage,
                              keyPrefix: 'ai-project-nav',
                            ),
                          const Divider(height: 28),
                          if (_page == 'advanced') ...[
                            _info(
                              '完整配置草稿',
                              '表单与 JSON 共用同一份草稿。未知字段在客户端编辑时保留；保存时以 agent 支持的配置为准。',
                            ),
                            SizedBox(
                              height: 380,
                              child: TextField(
                                key: const ValueKey('ai-project-json'),
                                controller: _editor,
                                expands: true,
                                minLines: null,
                                maxLines: null,
                                onChanged: (_) => _change(() {}),
                                style: const TextStyle(
                                  fontFamily: Ide.mono,
                                  fontSize: 12,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'AI 扩展配置 JSON',
                                  alignLabelWithHint: true,
                                ),
                              ),
                            ),
                          ] else if (config != null)
                            KeyedSubtree(
                              key: ValueKey('$_page-$_formEpoch'),
                              child: switch (_page) {
                                'budget' => _budgetPage(config),
                                'agents' => _agentsPage(config),
                                'tools' => _toolsPage(config),
                                'snapshots' => _snapshotPage(config),
                                'instructions' => _instructionPage(config),
                                'skills' => _skillPage(config),
                                'mcp' => _mcpPage(config),
                                'prices' => _pricesPage(config),
                                _ => const SizedBox(),
                              },
                            )
                          else if (!_busy)
                            const Text('连接 agent 并重新读取配置后即可编辑。'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _number(
    Map config,
    String group,
    String name,
    String label,
    String help,
    num fallback,
    num max, {
    num min = 0,
    bool decimal = false,
  }) {
    final value = (config[group] as Map?)?[name] ?? fallback;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: TextFormField(
        key: ValueKey('ai-$group-$name'),
        initialValue: '$value',
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        decoration: InputDecoration(
          labelText: label,
          helperText: help,
          helperMaxLines: 4,
        ),
        validator: (text) {
          final n = decimal
              ? double.tryParse(text ?? '')
              : int.tryParse(text ?? '');
          return n == null || !n.isFinite || n < min || n > max
              ? '请输入 $min–$max ${decimal ? '之间的数值' : '之间的整数'}'
              : null;
        },
        onChanged: (text) => _edit((c) {
          final values = Map<String, dynamic>.from(c[group] as Map? ?? {});
          values[name] =
              (decimal ? double.tryParse(text) : int.tryParse(text)) ?? text;
          c[group] = values;
        }),
      ),
    );
  }

  Widget _budgetPage(Map config) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _info(
        '一次运行，不是整个会话',
        '每条独立任务使用一份预算，排队任务开始时重新计时；补充指令沿用当前任务预算。重复上下文、子代理、标题与摘要也计入。上下文窗口另行限制。',
      ),
      if (_controls)
        SwitchListTile(
          key: const ValueKey('ai-budget-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('默认启用运行预算'),
          subtitle: const Text('关闭后保留下方限额与用量统计；可在输入框的“本次发送”中单独开启。'),
          value: config['budgetEnabled'] != false,
          onChanged: (v) => _edit((c) => c['budgetEnabled'] = v),
        ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: () => _edit((c) {
              c['budget'] =
                  _data?['defaults']?['budget'] ??
                  {
                    'steps': 60,
                    'seconds': 900,
                    'tokens': 500000,
                    'cost': 0,
                    'outputBytes': 2097152,
                  };
              _formEpoch++;
            }),
            child: const Text('使用默认预算'),
          ),
          if (_modern)
            OutlinedButton(
              onPressed: () => _edit((c) {
                c['budget'] = {
                  'steps': 200,
                  'seconds': 7200,
                  'tokens': 5000000,
                  'cost': 0,
                  'outputBytes': 8388608,
                };
                _formEpoch++;
              }),
              child: const Text('长任务预设'),
            ),
        ],
      ),
      const SizedBox(height: 20),
      _number(
        config,
        'budget',
        'tokens',
        '累计 Token 上限',
        _modern
            ? '0 = 不限制。默认 500000；每一步重新发送的上下文都会累计。'
            : '当前 agent 支持 1024–2000000；升级 agent 后可选择不限。',
        500000,
        _modern ? 1000000000 : 2000000,
        min: _modern ? 0 : 1024,
      ),
      _number(
        config,
        'budget',
        'steps',
        '模型步骤上限',
        '一次模型调用算一步，含子任务；标题与摘要不占步骤。${_modern ? '0 = 不限制。' : ''}',
        60,
        _modern ? 10000 : 60,
        min: _modern ? 0 : 1,
      ),
      _number(
        config,
        'budget',
        'seconds',
        '运行时间上限（秒）',
        '包括模型、工具执行与等待授权。${_modern ? '0 = 不限制；900 秒 = 15 分钟。' : ''}',
        900,
        _modern ? 604800 : 3600,
        min: _modern ? 0 : 10,
      ),
      _number(
        config,
        'budget',
        'outputBytes',
        '模型流式输出上限（字节）',
        '正文、思考与工具参数的合计；2097152 = 2 MiB。${_modern ? '0 = 不限制。' : ''}',
        2097152,
        _modern ? 1073741824 : 8388608,
        min: _modern ? 0 : 4096,
      ),
      _number(
        config,
        'budget',
        'cost',
        '金额上限（USD）',
        '0 = 不限制。启用后，所有使用到的模型都须在「模型价格」中配置单价。金额为本地估算，不是账单。',
        0,
        _modern ? 1000000 : 10000,
        decimal: true,
      ),
      if (_modern) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动生成会话标题'),
          subtitle: const Text('首条消息后请求模型生成；关闭后使用消息摘要命名。'),
          value: config['autoTitle'] != false,
          onChanged: (v) => _edit((c) => c['autoTitle'] = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动压缩上下文'),
          subtitle: const Text('接近上下文上限或上游报告溢出时生成摘要，也消耗本次预算；可随时手动压缩。'),
          value: config['autoCompact'] != false,
          onChanged: (v) => _edit((c) => c['autoCompact'] = v),
        ),
      ],
    ],
  );

  Widget _snapshotPage(Map config) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _info(
        '回退文件的覆盖范围',
        '只捕获会话工作目录内的文件。Git 项目使用真实索引与忽略规则；包含已跟踪文件，以及未忽略且不超过 2 MiB 的新文件。依赖／构建目录、符号链接和 Git 元数据不进入新文件快照。快照保存在 agent 的独立对象库。',
      ),
      if (!_modern) const Text('升级当前 agent 后，可调整快照策略和检查范围。'),
      if (_modern) ...[
        SwitchListTile(
          key: const ValueKey('ai-snapshots-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('启用文件快照'),
          subtitle: const Text('关闭后仍可回退对话；后续修改不再生成文件恢复点。已有快照保留。'),
          value: config['snapshots'] != false,
          onChanged: (v) => _edit((c) => c['snapshots'] = v),
        ),
        const SizedBox(height: 16),
        _number(
          config,
          'snapshot',
          'maxFiles',
          '有效文件数量上限',
          '0 = 默认 200000。先应用范围与忽略规则，再计算数量。',
          200000,
          2000000,
        ),
        _number(
          config,
          'snapshot',
          'maxFileBytes',
          '已跟踪单文件上限（字节）',
          '0 = 默认 8 MiB；最高 64 MiB。过大的新文件跳过，不阻断整个快照。',
          8388608,
          67108864,
        ),
        _number(
          config,
          'snapshot',
          'maxTreeBytes',
          '单次内容上限（字节）',
          '0 = 默认 128 MiB。只统计实际捕获内容。',
          134217728,
          1073741824,
        ),
        _number(
          config,
          'snapshot',
          'maxStoreBytes',
          '对象库空间上限（字节）',
          '0 = 默认 512 MiB。相同内容由 Git 去重；可清理未引用快照。',
          536870912,
          17179869184,
        ),
        _number(
          config,
          'snapshot',
          'timeoutSeconds',
          '快照超时（秒）',
          '0 = 默认 60 秒；最高 600 秒。',
          60,
          600,
        ),
        _lines(
          '快照额外忽略规则',
          ((config['snapshot'] as Map?)?['ignore'] as List? ?? []).join('\n'),
          '每行一个相对于会话目录的 Git glob，例如 **/coverage/**、downloads/**。也适用于已跟踪文件。',
          (v) => _edit(
            (c) => c['snapshot'] = {
              ...?c['snapshot'] as Map?,
              'ignore': _lineList(v),
            },
          ),
        ),
      ],
      const SizedBox(height: 12),
      if (widget.ws.link?.server.caps.contains('ai.snapshots.inspect') == true)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy || _dirty ? null : _inspectSnapshots,
            child: const Text('检查快照范围'),
          ),
        ),
      if (widget.ws.link?.server.caps.contains('ai.snapshots.prune') == true)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy ? null : _prune,
            child: const Text('清理未引用快照'),
          ),
        ),
      if (_storageResult != null) Text(_storageResult!),
    ],
  );

  Widget _agentsPage(Map config) {
    final policy = config['subagents'] as Map? ?? {};
    void change(String key, dynamic value) => _edit((c) {
      c['subagents'] = {...?c['subagents'] as Map?, key: value};
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _info(
          '主代理负责协作',
          '主代理可一次提交多个独立子任务。子代理共用工作目录与主任务预算，始终不能继续派生；重新打开子会话也遵守这一限制。',
        ),
        if (!_controls)
          const Text('更新 agent 后可使用代理协作策略。')
        else ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许子代理'),
            value: policy['enabled'] != false,
            onChanged: (v) => change('enabled', v),
          ),
          const SizedBox(height: 16),
          _number(
            config,
            'subagents',
            'maxParallel',
            '同时运行的子代理数',
            '1 = 顺序执行；仅独立子代理调用并发，主代理的其它工具保持顺序。',
            1,
            16,
            min: 1,
          ),
          _number(
            config,
            'subagents',
            'maxTotal',
            '单条任务的子代理总量',
            '0 = 不限；排队的下一条任务重新计数。',
            32,
            1000,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('子代理仅允许只读探索'),
            subtitle: const Text('开启后拒绝通用执行子代理；规划模式本身只允许只读探索。'),
            value: policy['readOnly'] == true,
            onChanged: (v) => change('readOnly', v),
          ),
        ],
      ],
    );
  }

  Widget _toolsPage(Map config) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _info('工具执行边界', '模型能使用哪些工具在全局／逐模型设置中控制。这里管理调用次数、重复检测与命令超时；执行仍受权限规则约束。'),
      if (!_controls)
        const Text('更新 agent 后可使用工具执行策略。')
      else ...[
        _number(
          config,
          'tools',
          'maxCallsPerStep',
          '每步最多执行的工具调用',
          '模型同一步超出的调用会收到明确拒绝结果。',
          64,
          64,
          min: 1,
        ),
        _number(
          config,
          'tools',
          'repeatLimit',
          '连续重复调用的确认阈值',
          '相同工具与参数连续出现达到此次数时询问；0 = 关闭重复检测。',
          3,
          20,
        ),
        _number(
          config,
          'tools',
          'shellDefaultSeconds',
          'Shell 默认超时（秒）',
          '模型未指定超时时使用。不得高于最大超时。',
          120,
          600,
          min: 1,
        ),
        _number(
          config,
          'tools',
          'shellMaxSeconds',
          'Shell 最大超时（秒）',
          '模型请求超过此值时按此值执行；超时会终止命令。',
          600,
          600,
          min: 1,
        ),
      ],
    ],
  );

  List<String> _lineList(String v) =>
      v.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  Widget _lines(
    String label,
    String initial,
    String help,
    ValueChanged<String> change,
  ) => TextFormField(
    initialValue: initial,
    minLines: 2,
    maxLines: 6,
    decoration: InputDecoration(
      labelText: label,
      helperText: help,
      helperMaxLines: 4,
    ),
    onChanged: change,
  );

  Widget _instructionPage(Map config) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _info(
        '指令来源可查看',
        '按 agent 用户 → 根目录 → 项目目录加载；每层优先 AGENTS.md，其次 CLAUDE.md、.cursorrules。额外文件按下方顺序追加。读取更深目录时补充该目录规则。',
      ),
      _lines(
        '额外指令文件',
        (config['instructions'] as List? ?? []).join('\n'),
        '每行一个项目内相对路径，例如 docs/coding.md。文件正文在编辑器中维护。',
        (v) => _edit((c) => c['instructions'] = _lineList(v)),
      ),
      const SizedBox(height: 20),
      const SectionHeader('已保存配置的生效指令'),
      for (final source in _data?['instructions'] as List? ?? [])
        ExpansionTile(
          title: Text('${source['path']}'),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText('${source['text']}'),
            ),
          ],
        ),
    ],
  );

  Widget _skillPage(Map config) {
    final disabled = (config['disabledSkills'] as List? ?? [])
        .map((x) => '$x')
        .toSet();
    final skills =
        _data?['available_skills'] as List? ?? _data?['skills'] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _info(
          '按需加载的技能',
          '模型先看到技能名称和说明，调用 skill 时才读取正文。开关控制此项目可用的技能；模型的「项目技能」工具开关仍单独生效。',
        ),
        for (final skill in skills)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${skill['name']}'),
            subtitle: Text('${skill['description']}\n${skill['path']}'),
            value: !disabled.contains(skill['name']),
            onChanged: (v) => _edit((c) {
              if (v) {
                disabled.remove(skill['name']);
              } else {
                disabled.add('${skill['name']}');
              }
              c['disabledSkills'] = disabled.toList();
            }),
          ),
        if (skills.isEmpty)
          const Text('暂无技能。在 .aurora/skills/<名称>/SKILL.md 添加后重新读取。'),
        const SizedBox(height: 16),
        for (final name in disabled.where(
          (n) => !skills.any((s) => s['name'] == n),
        ))
          ListTile(
            title: Text('$name · 当前未发现'),
            trailing: IconBtn(
              Icons.close,
              '取消停用 $name',
              () => _edit((c) {
                disabled.remove(name);
                c['disabledSkills'] = disabled.toList();
              }),
            ),
          ),
      ],
    );
  }

  Widget _mcpPage(Map config) {
    final servers = config['mcp'] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _info(
          '连接外部工具',
          '支持 stdio 命令与 Streamable HTTP。程序在当前 agent 机器运行；每次运行建立连接，结束后释放。最多 4 个服务。环境变量与请求头保存在项目文件中。',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: servers.length >= 4 ? null : () => _editMcp(),
            icon: const Icon(Icons.add),
            label: const Text('添加 MCP 服务'),
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < servers.length; i++)
          _serverCard(servers[i] as Map, i),
      ],
    );
  }

  Widget _serverCard(Map server, int index) {
    final id = '${server['id']}';
    final result = _probes[id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(id),
          subtitle: Text(
            server['url'] != null
                ? 'HTTP · ${server['url']}'
                : 'stdio · ${(server['command'] as List? ?? []).join(' ')}',
          ),
          value: server['disabled'] != true,
          onChanged: (v) =>
              _edit((c) => (c['mcp'] as List)[index]['disabled'] = !v),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _editMcp(index),
              child: const Text('编辑'),
            ),
            TextButton(
              onPressed: () => _edit((c) => (c['mcp'] as List).removeAt(index)),
              child: const Text('移除'),
            ),
            TextButton(
              onPressed:
                  _busy ||
                      _dirty ||
                      _probing.contains(id) ||
                      server['disabled'] == true
                  ? null
                  : () => _probe(id),
              child: Text(_probing.contains(id) ? '检测中…' : '检测连接与目录'),
            ),
          ],
        ),
        if (_dirty) const Text('保存配置后可检测连接。', style: TextStyle(fontSize: 12)),
        if (result is Map)
          ExpansionTile(
            title: Text(
              '${(result['tools'] as List? ?? []).length} 工具 · ${(result['resources'] as List? ?? []).length} 资源 · ${(result['prompts'] as List? ?? []).length} 提示词',
            ),
            children: [
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(result),
              ),
            ],
          )
        else if (result != null)
          SelectableText(
            '$result',
            style: TextStyle(color: Ide.of(context).error),
          ),
        const Divider(),
      ],
    );
  }

  Future<void> _editMcp([int? index]) async {
    final servers = _draft?['mcp'] as List? ?? [];
    final server = index == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(servers[index] as Map);
    final result = await showWorkbenchDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _McpEditor(
        value: server,
        ids: [
          for (var i = 0; i < servers.length; i++)
            if (i != index) '${servers[i]['id']}',
        ],
      ),
    );
    if (!mounted || result == null) return;
    _edit((c) {
      final rows = List<dynamic>.from(c['mcp'] as List? ?? []);
      if (index == null) {
        rows.add(result);
      } else {
        rows[index] = result;
      }
      c['mcp'] = rows;
    });
  }

  Widget _pricesPage(Map config) {
    final prices = config['prices'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _info(
          '每百万 Token 的 USD 单价',
          '输入单价只用于未缓存输入；缓存读取、写入分别计价。没有价格时显示“金额未完整计价”。这些价格用于预算预留与统计，不代表提供商实际账单。',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => _editPrice(),
            icon: const Icon(Icons.add),
            label: const Text('添加模型价格'),
          ),
        ),
        const SizedBox(height: 12),
        for (final entry in prices.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${entry.key}'),
            subtitle: Text(
              '输入 ${entry.value['input']} · 输出 ${entry.value['output']}\n缓存读 ${entry.value['cacheRead']} · 缓存写 ${entry.value['cacheWrite']}',
            ),
            onTap: () => _editPrice('${entry.key}'),
            trailing: IconBtn(
              Icons.close,
              '移除 ${entry.key}',
              () => _edit((c) => (c['prices'] as Map).remove(entry.key)),
            ),
          ),
      ],
    );
  }

  Future<void> _editPrice([String? model]) async {
    final prices = _draft?['prices'] as Map? ?? {};
    final result = await showWorkbenchDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PriceEditor(
        model: model,
        value: prices[model] as Map? ?? {},
        models: prices.keys.map((e) => '$e').toList(),
      ),
    );
    if (!mounted || result == null) return;
    _edit((c) {
      final rows = Map<String, dynamic>.from(c['prices'] as Map? ?? {});
      if (model != null) rows.remove(model);
      rows[result['model'] as String] = result['price'];
      c['prices'] = rows;
    });
  }
}

class _McpEditor extends StatefulWidget {
  final Map<String, dynamic> value;
  final List<String> ids;
  const _McpEditor({required this.value, required this.ids});
  @override
  State<_McpEditor> createState() => _McpEditorState();
}

class _McpEditorState extends State<_McpEditor> {
  final _form = GlobalKey<FormState>();
  late final _id = TextEditingController(
    text: widget.value['id'] as String? ?? '',
  );
  late final _url = TextEditingController(
    text: widget.value['url'] as String? ?? '',
  );
  late final _command = TextEditingController(
    text: (widget.value['command'] as List? ?? []).join('\n'),
  );
  late final _env = TextEditingController(
    text: (widget.value['env'] as Map? ?? {}).entries
        .map((e) => '${e.key}=${e.value}')
        .join('\n'),
  );
  late final _headers = TextEditingController(
    text: (widget.value['headers'] as Map? ?? {}).entries
        .map((e) => '${e.key}=${e.value}')
        .join('\n'),
  );
  late bool _http = widget.value['url'] != null;
  @override
  void dispose() {
    for (final c in [_id, _url, _command, _env, _headers]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _pairs(String text) => {
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty && line.contains('='))
        line.substring(0, line.indexOf('=')).trim(): line.substring(
          line.indexOf('=') + 1,
        ),
  };
  String? _validatePairs(String? text) {
    final seen = <String>{};
    for (final line
        in (text ?? '').split('\n').where((e) => e.trim().isNotEmpty)) {
      final at = line.indexOf('=');
      if (at <= 0 || !seen.add(line.substring(0, at).trim()))
        return '每行填写不重复的 名称=值';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('MCP 服务'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _id,
                decoration: const InputDecoration(labelText: '服务标识'),
                validator: (v) =>
                    !RegExp(r'^[a-zA-Z0-9_.-]{1,48}$').hasMatch(v ?? '') ||
                        widget.ids.contains(v)
                    ? '使用 1–48 位字母、数字、点、下划线或短横线，且不可重复'
                    : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<bool>(
                initialValue: _http,
                decoration: const InputDecoration(labelText: '连接方式'),
                items: const [
                  DropdownMenuItem(value: false, child: Text('stdio · 启动本地程序')),
                  DropdownMenuItem(value: true, child: Text('Streamable HTTP')),
                ],
                onChanged: (v) => setState(() => _http = v!),
              ),
              const SizedBox(height: 16),
              if (_http)
                TextFormField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: '服务 URL',
                    hintText: 'https://example.com/mcp',
                  ),
                  validator: (v) {
                    final uri = Uri.tryParse(v ?? '');
                    return uri == null ||
                            !['http', 'https'].contains(uri.scheme) ||
                            uri.host.isEmpty ||
                            uri.userInfo.isNotEmpty ||
                            uri.hasFragment
                        ? '填写有效的 HTTP(S) URL'
                        : null;
                  },
                )
              else
                TextFormField(
                  controller: _command,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: '程序与参数（每行一项）',
                    hintText: 'npx\n-y\n@vendor/mcp-server',
                    helperText: '首行是可执行程序；后续每行是一个完整参数，不加 Shell 引号。',
                    helperMaxLines: 3,
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty ? '请输入程序' : null,
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _http ? _headers : _env,
                key: ValueKey(_http),
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: _http ? 'HTTP 请求头' : '环境变量',
                  helperText: '每行 名称=值；保存在项目 .aurora/ai.json。',
                  helperMaxLines: 3,
                ),
                validator: _validatePairs,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          final result = Map<String, dynamic>.from(widget.value)
            ..remove('url')
            ..remove('command')
            ..remove('env')
            ..remove('headers');
          result['id'] = _id.text.trim();
          if (_http) {
            result['url'] = _url.text.trim();
            result['headers'] = _pairs(_headers.text);
          } else {
            result['command'] = _command.text
                .split('\n')
                .where((e) => e.isNotEmpty)
                .toList();
            result['env'] = _pairs(_env.text);
          }
          Navigator.pop(context, result);
        },
        child: const Text('应用到草稿'),
      ),
    ],
  );
}

class _PriceEditor extends StatefulWidget {
  final String? model;
  final Map value;
  final List<String> models;
  const _PriceEditor({this.model, required this.value, required this.models});
  @override
  State<_PriceEditor> createState() => _PriceEditorState();
}

class _PriceEditorState extends State<_PriceEditor> {
  final _form = GlobalKey<FormState>();
  late String _model = widget.model ?? '';
  late final _values = Map<String, dynamic>.from(widget.value);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('模型价格 · USD / 百万 tokens'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: _model,
                decoration: const InputDecoration(labelText: '精确模型 ID'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ||
                        v != widget.model && widget.models.contains(v)
                    ? '填写不重复的模型 ID'
                    : null,
                onChanged: (v) => _model = v.trim(),
              ),
              for (final entry in {
                'input': '未缓存输入',
                'output': '输出',
                'cacheRead': '缓存读取',
                'cacheWrite': '缓存写入',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextFormField(
                    initialValue: '${_values[entry.key] ?? 0}',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(labelText: entry.value),
                    validator: (v) {
                      final n = double.tryParse(v ?? '');
                      return n == null || !n.isFinite || n < 0 || n > 100000
                          ? '输入 0–100000 的单价'
                          : null;
                    },
                    onSaved: (v) => _values[entry.key] = double.parse(v!),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          _form.currentState!.save();
          Navigator.pop(context, {'model': _model, 'price': _values});
        },
        child: const Text('应用到草稿'),
      ),
    ],
  );
}
