# 开发工具、编码与批量修改

> 类型：使用指南 | 状态：生效 | 维护：IDE 维护者 | 更新：2026-11-16
> 适用：3.22.0 客户端及同版本 agent

开发配置放在项目文件夹的 `.aurora/development.json`。工作台 **开发与问题 → 设置** 可以编辑配置；多文件夹项目在没有活动文件时先选择文件夹。配置按内容版本保存，另一客户端修改后需要重新读取。

## 配置示例：Dart

命令在**文件所在的 agent 机器**执行。请在该机器安装相应 SDK／语言服务器／调试适配器；`command` 是可执行文件和参数组成的数组，带空格的路径作为单个数组元素。

```json
{
  "version": 1,
  "languageServers": [
    {
      "id": "dart",
      "label": "Dart language server",
      "command": ["dart", "language-server", "--protocol=lsp"],
      "languages": ["dart"],
      "settings": {}
    }
  ],
  "tasks": [
    {
      "id": "analyze",
      "label": "静态检查",
      "command": ["dart", "analyze"],
      "group": "lint",
      "timeoutSeconds": 120
    },
    {
      "id": "test",
      "label": "项目测试",
      "command": ["dart", "test", "--reporter=expanded"],
      "group": "test",
      "dependsOn": ["analyze"],
      "timeoutSeconds": 300
    }
  ],
  "debug": [
    {
      "id": "dart-main",
      "label": "调试 main.dart",
      "command": ["dart", "debug_adapter"],
      "request": "launch",
      "preLaunchTask": "analyze",
      "arguments": {
        "program": "${workspaceFolder}/main.dart",
        "cwd": "${workspaceFolder}",
        "console": "debugConsole"
      }
    }
  ]
}
```

将 `main.dart` 改为项目实际入口。`env` 可提供环境变量，`cwd` 为项目内的相对工作目录。调试 `arguments` 中的 `${workspaceFolder}` 展开为 agent 的本机路径；`request` 可使用 `launch` 或适配器支持的 `attach`。调试适配器使用自己的参数格式。

配置最多包含 16 个语言服务器、128 个任务和 32 个调试配置；配置文件上限 256 KiB。agent 共享 8 个开发进程配额。取消任务、停止调试或关闭协议连接会回收对应进程树。

## 语言服务

打开文档后按文件语言自动选择配置。支持诊断、补全、类型／文档、定义、引用、格式化、符号重命名及代码操作：

| 操作 | 编辑器快捷键 |
|---|---|
| 补全 | `Ctrl+Space` |
| 定义 | `F12` |
| 重命名 | `F2` |
| 格式化 | `Alt+Shift+F` |

代码修改先显示差异预览。**接受全部修改**写入编辑缓冲，每个文档一个真实撤销步骤；**接受并整批保存**使用文件事务。预览后改动正文或编码会使旧预览失效。

Problems 与语言服务器列表按需构建行。重连后重新建立文档同步；失效的服务端修改审阅随旧连接结束。超过 512 Ki 字符或编码后的 JSON 超过协议帧预算的文档暂停语言同步。

LSP 文件资源创建／移动／删除按服务端操作顺序预览并整批保存，支持覆盖与忽略选项、新父目录和整批撤销。资源操作限普通文本文件；Windows 仅大小写重命名会明确拒绝。

snippet 支持编号字段、默认值、变量、选择项和镜像。`Tab`／`Shift+Tab` 移动字段，`Esc` 退出；镜像与当前输入合并为一次撤销，IME 组合输入结束后才同步。正则转换片段会明确提示暂不支持。

## 任务与测试

在 **任务与测试** 页选择运行任务或测试。可以取消、重新运行、查看退出码、定位编译问题；每个工作区最多同时运行 4 组任务。

- 默认问题格式：`file:line:column: message`，列可省略。
- `problemPattern` 可配置命名捕获组 `file`、`line`、`column`、`message`、`severity`，在 agent 使用 RE2 执行；表达式上限 4096 字节／32 捕获组，每行上限 16 KiB。
- `testFormat: "go-json"` 对接 `go test -json ./...`；`testFormat: "tap"` 对接 TAP。
- 其它测试命令保留日志与退出码。
- 每组保留最近 128 Ki 字符输出、最多 500 个问题和 500 个测试结果；历史保留 12 组。历史与断点独立加密存储，重启后的未完成任务标为已中断。

Go 任务例子：

```json
{
  "id": "go-test",
  "command": ["go", "test", "-json", "./..."],
  "group": "test",
  "testFormat": "go-json",
  "timeoutSeconds": 300
}
```

## 调试

编辑器行号左侧或 `F9` 切换断点；断点列表的编辑按钮可设置条件、命中次数和日志消息。表达式语法由适配器解释，未支持的条件能力会在断点旁显示原因。断点跟随插入／删除行和撤销移动，并合并保存与协议更新。

| 操作 | 快捷键 |
|---|---|
| 启动／继续 | `F5` |
| 停止 | `Shift+F5` |
| 单步跳过 | `F10` |
| 单步进入／跳出 | `F11` / `Shift+F11` |

暂停后可选线程／栈帧、分页读取变量、监视表达式和控制台求值。工作根目录内的源文件打开为正常编辑器；虚拟／外部源由适配器提供只读快照，适配器不提供内容时显示读取失败。

## 编码与大文件

编辑器编码按钮支持重新按指定编码读取，或更改下一次保存的编码：

- UTF-8、UTF-8 BOM；
- UTF-16 LE／BE，分别支持 BOM；
- GB18030、Big5、Shift JIS、Windows-1252。

自动读取识别 UTF BOM，其余按 UTF-8 读取；旧编码需明确选择。解码要求无损往返，保存无法表示的字符时拒绝写入。恢复记录分别保留缓冲编码与磁盘编码；转换保存后，后续读取使用实际保存的编码。

完整读取的源文件上限 4 MiB。较大的 UTF-8 文件可以进入只读字节窗口模式，每次读取 64 KiB，支持上一段／下一段、文件开头／末尾及字节跳转；窗口保持 Unicode 边界并固定文件版本。超过 512 Ki 字符的可编辑文档关闭高亮和自动换行。

## 跨文件替换

1. 在搜索页设置查询、大小写／全字／正则和文件筛选。
2. 展开 **跨文件替换**，输入替换文本，选择 **预览替换结果**。
3. 检查各文件差异，接受到缓冲或接受并整批保存。

候选文件是**当前列出的搜索结果**；重叠项目文件夹会去重。预览使用这些文件当前的编辑缓冲，整批保存也包含已有未保存编辑。结果截断／超时后需要缩小范围。

正则与搜索共用 agent 上的 Go RE2 匹配器，逐行匹配并保留 CRLF。正则替换支持 `$1`、`${name}`、`$$`；普通文本替换按字面插入。每个输入／输出上限 4 MiB、每文件最多 20,000 次替换，预览最多 128 个文件和 8 Mi 字符。

批量提交接收内容时不占用共享文件提交锁；发送结束帧前复核缓冲版本，agent 在提交时复核全部磁盘版本并写入可恢复事务。等待回执期间继续输入的内容仍保持 dirty。取消或回执失败时已接受的缓冲修改保留，可撤销并重新核对磁盘版本。

底层恢复事务最多 512 个文件、单文件 64 MiB，前后版本合计 256 MiB；文本编辑／替换仍受上述更小的输入与文件数量预算约束。超限在提交前拒绝整批修改。

## AI 编辑、扩展与预算

编辑器中的 AI 修改建议使用当前未保存缓冲、选区与诊断。审阅页可选择文档、逐块接受／拒绝、撤销、整批保存和运行验证任务。`Alt+\` 在行尾请求行内续写，`Tab` 接受，`Esc` 拒绝。

3.25 候选的运行预算入口在对话执行策略。项目指令、技能和 MCP 仍通过 agent 工作目录内的 `.aurora/ai.json` 配置，可用普通编辑器编辑；不再有独立的项目策略页。参见 [AI 配置指南](ai.md)。

```json
{
  "version": 1,
  "instructions": ["docs/project-rules.md"],
  "disabledSkills": [],
  "mcp": [{"id": "local-tools", "command": ["my-mcp-server", "--stdio"]}],
  "budgetEnabled": true,
  "budget": {"steps": 60, "seconds": 900, "tokens": 500000, "outputBytes": 2097152, "cost": 0},
  "subagents": {"enabled": true, "maxParallel": 2, "maxTotal": 32, "readOnly": false},
  "tools": {"maxCallsPerStep": 64, "repeatLimit": 3, "shellDefaultSeconds": 120, "shellMaxSeconds": 600},
  "prices": {}
}
```

HTTP MCP 改用 `{"id":"remote-tools","url":"https://example.com/mcp","headers":{}}`；同一服务只能配置一种传输。服务可设 `disabled: true`。MCP 连接限单次运行，结束或取消时释放；支持工具、资源及提示词，调用遵循现有权限规则。

指令按 `StateDir/ai/AGENTS.md` → 根目录 → 项目应用，各层优先 `AGENTS.md`、`CLAUDE.md`、`.cursorrules`；读取更深文件时附加子目录指令。技能来自 `StateDir/ai/skills` 和各层 `.opencode/skills`、`.agents/skills`、`.aurora/skills` 下的 `<name>/SKILL.md`。

`prices` 以模型 ID 为键，`input`／`output`／`cacheRead`／`cacheWrite` 均为 USD／百万 tokens；启用金额预算时必须配置当前模型价格。令牌、输出、时间和金额预算由主／子任务及辅助请求共享。

`budgetEnabled: false` 关闭运行限额并保留统计。`subagents` 管理允许、并发、总量及只读；`tools` 管理单步调用上限、重复确认及 Shell 超时。字段范围、对话策略与排队语义见 [代理协作与工具控制](ai.md#代理协作与工具控制)。

## 会话存储与已知边界

会话使用 JSON 检查点、带 CRC32 的增量 journal 和派生索引；启动按索引列出会话，打开时才读取正文。正文上限 64 MiB，损坏记录原样保留并在会话列表显示错误；存在未知引用时暂停附件及快照清理。

删除主会话同时删除其子会话，整批原子提交。每会话通常有检查点、日志和索引三个文件；超过 512 个文件或合计 256 MiB 时，先删除部分子会话再重试，超限不会部分删除。

AI 待审建议和验证任务的版本关联目前保留在内存；已接受的未保存正文由文档恢复机制保护。MCP 当前支持工具、资源和提示词，尚不支持 resource templates、OAuth 授权或跨运行持久连接。真实外部服务与模型账号验收范围见 [实施验收](../validation/2026-11-16-implementation.md)。
