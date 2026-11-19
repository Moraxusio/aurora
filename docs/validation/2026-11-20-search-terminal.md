# 统一搜索与终端验收

> 类型：验收记录 | 状态：已记录 | 维护：客户端维护者 | 更新：2026-11-20
> 适用：3.25.0-gui-preview13／14 Windows x64 候选

基于 `6a04251721dcd849f491042e5d945fd5aad215c3` 的未提交工作树，Flutter 3.47.9。使用合成项目及服务，不访问用户配置；包内构建信息和逐文件指纹见 `BUILD-INFO.json` 与 `SOURCE-HASHES.json`。

定向源码测试覆盖统一搜索的同一输入、关键词实际到达 agent、跨模式草稿、键盘入口，终端管理按需显示且原会话不重建、本地结束前确认。可通过 `flutter test --no-pub test/workbench_redesign_test.dart test/gui_workflow_test.dart test/gui_routing_test.dart test/terminal_session_list_test.dart` 复验。

preview13 的全量组件检查发现两条旧断言仍依赖重复的终端入口及无确认关闭。本轮修正后重新验证：从窄窗底栏进入已经打开的终端时，返回输出而非把它隐藏；本地终端的测试操作先确认，再检查连接只关闭一次。

## 结果

- preview14 全量客户端测试 **670 项通过、20 项跳过**；GUI contract 通过，静态分析无错误或警告。
- preview13 的 Windows Profile 原生工作流在 80%–150% 缩放验证同一搜索输入框、按需打开会话管理、关闭后恢复输出；终端只建立了一次连接。preview14 窄窗修正另有组件测试。
- preview14 ZIP 为 56,058,610 字节，SHA-256 `a1b0ab8a7db748ddd20166c90a95e7805dfbe72b7b7ca22c26fbcf437f9d751b`。解压核对 654 个文件，验证双 agent 与升级策略签名，并用新解压的 Release 验证独立配置、单实例恢复和退出。既有包未覆盖。
- 本段在打包后补记，随包文档保留构建时快照。

本轮是搜索与终端交互优化，不代表上一版高负载编辑器切换已达到 [16.7 ms 帧预算](2026-11-20-desktop-workbench.md)。
