# AI IDE 与统一 GUI 实施验收

> 类型：验收记录 | 状态：已记录 | 维护：项目维护者 | 更新：2026-11-16
> 适用：3.22.0 打包前源码；测试范围与未验项目见正文

日期：2026-11-16。基线：`f2873316253e80b9c217dea88eb8048c8dddb10f`。工作目录：`C:\build\aurora`。

## 交付范围

本轮在工作树中完成 A–D 的源码实现与接入：

- **可靠性**：工作区文档模型、版本／保存点、逐文档加密恢复、离线恢复、冲突审阅、共享文件提交锁、可恢复多文件事务、下载磁盘背压、取消／重连代次与 Windows 原生监听。
- **IDE**：LSP 同步、Problems、补全／hover／导航／格式化／重命名／代码操作、有序文件资源修改与 snippet；任务／测试、问题匹配、持久化结果；DAP 调试与断点；编码转换、大文件阅读和跨文件替换。
- **AI**：未保存缓冲／选区／诊断上下文、逐块接受／拒绝／撤销、整批保存与验证、手动行内续写；分层指令／技能、MCP、共享运行预算与成本；会话增量日志／索引／懒加载、有界快照与引用保护。
- **统一 GUI**：`package:aurora/ui/aurora_ui.dart`，所有功能页与工作台共用基础／组合控件；设置中的组件展示；导入／浮层 contract、开发约定和统一检查入口。

配置与操作见 [开发工具](../guides/development-tools.md)，组件使用见 [Aurora GUI](../development/gui.md)，阶段历史见 [实施记录](2026-11-16-implementation-log.md)。审计报告中的原始缺口和旧测量是实施前历史。

## 自动化检查

| 检查 | 结果／证据 |
|---|---|
| Flutter 全量 | **602 通过、20 条件跳过、0 失败**；`flutter-delivery-all.txt` |
| 完整 Dart analyze | **0 error、0 warning、202 info**；196 项花括号风格、5 项 null-aware elements、1 项字符串插值风格 |
| GUI contract | **129 个 Dart 源文件通过**；已接入 Windows／GUI preview／Android 打包及原生审计 |
| Windows 原生 Profile | **541 帧、4 个场景全部满足预算**；CPU 采样关闭，源码／测试／脚本 **1201 文件指纹一致**；`native-final.json` |
| `aurora_profile` | **57 通过** |
| `aurora_wire` | **23 通过、21 条件跳过** |
| `aurora_install` | **7 通过、21 条件跳过** |
| `aurora_sub` | **39 通过** |
| Windows Go | 全模块 test／vet／build 通过；含真实 Dart LSP／DAP。最终 AI 包 32.532s，测试夹具清理补充后 AI 全包复验 28.703s |
| Linux Go | Ubuntu-24.04 WSL 全模块运行时 test／vet／build 通过；最终 AI 16.327s、files 0.793s、filetxn 0.690s |
| Linux race | 五包首轮均通过；存储边界修改后的 AI／files／filetxn 再次通过：41.638／5.586／1.504s；未改动的 MCP／devtools 为 1.215／2.157s |
| PowerShell 语法 | `tools` 与 `app/tool` 共 **19 个脚本通过** |
| 格式／差异 | **74 个变更 Go 文件** gofmt 通过，**47 个自有新 Dart 文件及 3 个最后修改文件** format 通过；`git diff --check` 通过 |

日志目录：`C:\Users\finwe\AppData\Local\Temp\opencode\aurora-implementation-20261116`，最终检查原始日志归档到 [`performance/20261116-implementation`](../performance/20261116-implementation)。全量与定向回归存在重叠，不能将各阶段数字直接相加。Vendored `re_editor` 保留上游格式，未进行全库格式重写。

条件跳过来自未配置的代理、Go testpeer/testnode、升级／签名安装专用夹具及截图输出开关；这不是失败，但也不是已完成这些环境下的验收。真实 Dart LSP／DAP 已在 Windows Go 检查中通过独立的实际子进程桥执行，历史上还连续 5 轮停在 `main:3` 用户断点。

### 关键故障与交互覆盖

- 文档：真实 undo/redo、IME、折叠、保存中输入、视图重建、断线恢复、坏记录保护、恢复冲突及热退出失败。
- 事务：三个替换点实际进程退出、启动回滚、外部修改、取消、提交标记写入／删除／同步失败、已提交日志清理失败、上传与普通保存竞争。
- 传输：逐帧写盘、3 流并发、队列中取消、移除／销毁、迟到握手、新连接重试、声明包长超额在额外写盘前停止。
- LSP：全量／增量／None 同步、UTF-16／CRLF／Unicode URI、版本化审阅、重连失效、有序资源操作、snippet 镜像／IME／真实撤销；正文在排队或握手时超额不再发送，缩小后重新 didOpen。
- 任务／调试：Go JSON／TAP、agent RE2 命名捕获、重复问题去重／路径约束／500 项预算、加密历史、前置任务失败、断点随正文与撤销移动、条件／命中次数／日志断点、分页变量／监视／求值和只读虚拟源。
- AI／扩展：三种兼容模型协议、唯一匹配／重叠拒绝、版本变化／取消、逐块接受／拒绝／撤销、草稿保留；真实 stdio MCP 进程与 HTTP session／SSE、分页循环及超额响应；辅助请求共享输出／token／时间／金额预算。
- 存储：小增量不重写正文、周期检查点、CRC／序号损坏、断尾证据、跨会话并发／同会话顺序、启动懒加载／缓存／搜索取消、坏会话和孤立日志引用保护、外部会话变化拒绝回退。
- GUI：明暗、360／1280 宽、文字与工作台缩放、键盘／焦点／语义、忙碌与禁用、触控目标、窄表单／区段换行、极矮空状态、嵌套滚动对话框、万行随机跳转构建上限。

### 验收过程中修复的缺陷

1. 统一按钮依赖工作台 ThemeExtension，导致独立登录／审阅 MaterialApp 失败；改用 Material 配色，8 项失败修复后全量通过。
2. 仅使用 builder 的可变行高列表远距离跳转会构建全部中间行；为统一列表提供固定行高／prototype，并改造组件目录。
3. LSP 排队与迟到握手未再次核验文档预算；加入发送前核验及关闭／重新打开回归。
4. 任务问题匹配曾在客户端重复编译 agent 的 RE2 表达式；客户端现在只消费 agent 结构化结果。
5. 会话派生索引缺少内容校验、正文读取会重复落盘索引；加入 CRC32，读取不再 fsync，外部变化拒绝发布。
6. 会话 64 MiB 与事务 32 MiB 上限不一致；统一单文件 64 MiB、整批前后版本合计 256 MiB，并在删除大量子会话前预检数量及体积。共享恢复故障 gate 支持并发读取，失败的启动恢复也阻止后续写入。
7. 切换活动编辑器会让整个 AI 页面重建，仅为了更新附件菜单；现打开菜单时读取当前文件，切换不再失效会话正文。新增两个回归在修改前真实失败，修复后覆盖正文不重建、草稿保留，以及新文档的未保存正文／选区附件；AI／工作台／统一组件定向 **50 项通过**。

加强恢复 gate 后，Linux 的“StateDir 为普通文件”故障夹具曾将故障留给后续测试；现测试结束修复路径并显式恢复，保留生产阻断行为。Windows AI、Linux 全模块和受影响 race 均已复验通过。

## 当前源码性能

### 实际落盘

会话基准与审计基线使用同一夹具：100／1000 条历史消息，每条含工具调用和约 4 KiB 输出，实际 fsync／原子替换，Windows amd64、Go 1.26.0、`-benchtime=500ms -count=3 -benchmem`。

| 历史消息数 | 初始审计基线 | 首轮紧凑 JSON | 当前增量存储 | 当前每次分配 |
|---|---:|---:|---:|---:|
| 100 | 7.944 ms | 4.541 ms | **6.189 ms** | **0.090 MB** |
| 1000 | 43.289 ms | 15.308 ms | **7.668 ms** | **0.836 MB** |

三次中位数。1000 条历史相对初始基线约快 5.65 倍，相对首轮紧凑 JSON 约快 2 倍。100 条的小会话本轮比首轮慢约 36%，新路径包含增量日志与派生索引落盘，不能将结果概括为所有规模都更快。初始基线分配为 3.138／31.888 MB，首轮为 0.647／6.924 MB。

原始结果：[`session-final-benchmark.txt`](../performance/20261116-implementation/session-final-benchmark.txt)；审计基线为 `docs/performance/20261116-audit-go-before.txt` 与 `docs/performance/20261116-audit-go-after.txt`。该基准循环保存相同会话，代表无正文变化的持久化开销及周期检查点，不代表每次新增完整大消息的耗时。多会话回归证明一个会话被阻塞时其它会话可继续落盘，但尚未给出多会话 admission/get 的长期 p95。

### Windows 原生 Profile

首轮原生验收的编辑器切换 build p95 为 27.615 ms，超过 16.667 ms 预算。VM CPU 诊断取得 525 个样本，主要开销位于组件更新、布局和语义树；随后消除了切换文件触发的 AI 整页重建。

诊断运行使用 `-Baseline -TraceCPU`，不计为帧预算通过。优化前同一版生产源码在这次诊断中的切换 p95 已降至 13.401 ms，说明运行间存在明显波动，不能将首轮与最终差值全部归因于这次优化。原始样本压缩归档为 `performance/20261116-implementation/native-editor-cpu.json.gz`。

优化后的预算开启／CPU 采样关闭复验已通过，仍使用 **16.667 ms p95** 和 **100 ms build 最大值**阈值：

| 场景 | 帧数 | build p95 | raster p95 |
|---|---:|---:|---:|
| 监控＋AI 流＋终端输出＋拖动侧栏 | 133 | 8.530 ms | 5.209 ms |
| 12 个保活编辑器切换，AI／终端并发更新 | 49 | 12.080 ms | 4.899 ms |
| 展开监控详情、滚动与刷新 | 58 | 1.725 ms | 4.394 ms |
| 30 秒并发轮询与流输出 | 301 | 3.429 ms | 4.441 ms |

合计 **541 帧**。拖动场景有 1 帧超出 16.667 ms，build 最大值 60.279 ms、raster 最大值 21.662 ms；其余三个场景没有超预算帧。因此结论是通过既定 p95／最大 build 预算，并非每帧都小于 16.667 ms。

未保存正文、编辑控制器、AI 草稿与阅读锚点全部保留；终端和 AI 各连接一次；并发期间 GPU 轮询 22 次；原生窗口 1200×800、1000×700、1500×1000 尺寸验证通过。日志未见 AXTree 拒绝、未处理异常或布局溢出。已审阅明色并发工作台及暗色 85%／150% 截图，未见操作区重叠或异常裁切。

原始结果、日志、源码指纹与截图归档为 `performance/20261116-implementation/native-final*`。原生指纹同时覆盖生产源码、测试夹具、集成用例及验收脚本，交付前再次核验 **1201 个文件一致**；结果 JSON 明确记录预算开启、CPU 采样关闭。旧审计的 571 帧不计入本轮结果。

## 能力边界

- **外部适配器**：LSP／DAP 命令在文件所在 agent 执行，需要对应 SDK／适配器。实际协议验收使用 Dart；未宣称兼容所有语言／调试器。
- **文本**：完整读取上限 4 MiB；大文件为 UTF-8 只读字节窗口。超过 512 Ki 字符或 JSON 帧预算暂停 LSP。旧编码需明确选择，不能表示的字符拒绝保存。
- **重构／snippet**：资源操作限普通文本文件；Windows 仅大小写重命名、snippet 正则转换明确拒绝。
- **AI 编辑**：待审建议及验证版本关联仅在内存中；已接受未保存正文由文档恢复保护。行内续写由 `Alt+\` 手动触发。
- **MCP**：工具、资源及提示词已接入；resource templates、OAuth、跨运行持久连接未实现。请求期连接结束／取消即回收。
- **存储／事务**：会话上限 64 MiB；底层事务最多 512 个文件、前后版本总计 256 MiB。每会话通常三个文件，大量子会话删除可能需要先删除部分子会话，超额保持原记录。8 会话／约 64 MiB 是空闲缓存的磁盘体积预算，不是进程 RSS 上限。
- **账号验收**：缺少真实模型账号，设备授权、订阅资格、真实识图及固定代码任务的真实成功率未完成；协议夹具通过不代表账号授权或模型质量已通过。
- **长期性能**：本轮的故障注入与短时原生压力不替代弱网／慢盘长期压力及 24 小时泄漏验收；尚无这几项结果。没有据此宣称整体 IDE 提升百分比。
- **平台**：本轮客户端为 Windows 原生验收；Linux 执行 agent 测试，Android 未构建发行包。

## 复验入口

```powershell
# 仓库根目录；PATH 中准备 Go、Flutter、Dart、NASM
powershell -File tools/check.ps1
powershell -File tools/check.ps1 -Native -NativeOut <新的隔离目录>

# 仅 GUI 规则与组件
cd app
dart tool/ui_contract.dart
flutter test --no-pub test/unified_ui_test.dart test/overlays_test.dart
```

Windows 使用 Go 1.26.0，`GOTOOLCHAIN=local`、`GOPROXY=off`、`CGO_ENABLED=0`；实际 Dart 适配器测试通过 `AURORA_TEST_DART` 指定 SDK。Linux 使用 SHA-256 已核验的官方 Go 1.26.0 工具链在 Ubuntu-24.04 WSL 执行；race 使用 `CGO_ENABLED=1`。

## 工作树与现有交付

所有实现、测试、文档与验收证据留在当前工作树，尚未提交／推送／发布或部署。

现有正式包与验收包（交付前 SHA-256 复核一致）：

- `C:\dev\VPS\release3\Aurora-3.21.4.zip`：`087348a08f4f0af051a89b81dde7d5eb86a2136045d6199ebdb5c8ec2aa95ae1`
- `C:\dev\VPS\preview3\Aurora-3.21.4-harness-preview1.zip`：`78ca0c41012e5647cfd5080a47ba8b9f0f74a979f3c99eeaf6f747af2a19fb7d`

源码改造不代表这两个既有包已包含新功能。OpenCode 兼容协议和 `User-Agent`、`originator`、`x-opencode-client` 标识继续保留。
