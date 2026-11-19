# 桌面工作台精简回归记录

> 类型：验收记录 | 状态：已记录 | 维护：客户端维护者 | 更新：2026-11-20
> 适用：3.25.0 GUI 候选 Windows 桌面客户端验证

## 范围

Windows x64，Flutter 3.47.9、Dart 3.13.7。源码基于 `6a04251721dcd849f491042e5d945fd5aad215c3`，工作树含未提交改动。本轮交互使用合成文件和服务，不接入用户项目或商业模型账号。候选包记录 `SOURCE-HASHES.json` 与 `BUILD-INFO.json`。

## 已验证

- `dart tool/ui_contract.dart`：通过。
- `flutter analyze --no-pub --no-fatal-infos`：无 error、warning；仍有 info 级风格提示。
- `flutter test --no-pub test/contrast_test.dart test/unified_ui_test.dart test/workbench_redesign_test.dart`：60 项通过。覆盖搜索入口与快捷键、缩放和焦点、编辑区折叠后 AI 草稿保留、拖宽右栏后真实中央编辑器重新折行。
- `flutter test --no-pub test/ai_controls_workflow_test.dart --plain-name 'empty chat suggestions'`：通过。示例保留已有草稿且不会发送请求。
- `flutter test --no-pub test/workbench_visual_test.dart`：两项通过，生成深浅色桌面及窄窗截图。见 [回归证据](../performance/20261120-desktop-workbench/README.md)。
- gui-preview11 全量组件回归：666 项通过、20 项跳过。解压后双 agent 与升级策略通过内置公钥验证；真实 Release 启动器验证独立配置、单实例还原及退出。
- gui-preview11 Windows Profile 原生测试完成几何和状态断言，但严格帧预算未通过：编辑器切换 UI p95 为 23.9 ms（目标 16.7 ms），并发持续输出场景也有超预算帧。
- gui-preview12 全量组件回归：667 项通过、20 项跳过；Profile 库 58 项通过。`go test -count=1 ./internal/ai/...` 通过，含允许／拒绝规则仅处理适用审批的测试。

## Windows 原生复验

gui-preview12 使用 Windows Profile 运行 `integration_test/gui_foundation_test.dart`。实测左右栏相邻、有文档时恢复编辑区和原右栏宽度、拖宽右栏时 Markdown 源码重新折行；在 1500×1000 和 1400×850 原生窗口、100% 和 110% 界面缩放下保留未发送草稿。包含搜索窄窗与 1200×800、1000×700、1500×1000 窗口的多视图检查。

严格 16.7 ms 帧预算仍未通过：AI 与终端同时输出时批量切换编辑器的 UI p95 为 **19.4 ms**（49 帧，12 帧超预算）。持续轮询与输出场景为 301 帧，UI／绘制 p95 为 3.1／4.9 ms，未超预算。原始帧数据见 [证据索引](../performance/20261120-desktop-workbench/README.md)。

## 候选包

- `Aurora-3.25.0-gui-preview12.zip`：56,047,463 字节，SHA-256 `6738ed59940b821dc781e3a20958a4fdcba914cfc3a0fbbfcd8c19d446db6fe2`。
- 复核 2,129 个源码输入指纹，以及 ZIP 解压后 649 个文件的字节数与 SHA-256；用内置公钥核对双 agent 和升级策略。客户端 EXE 未做 Authenticode 签名。
- 从新解压目录运行 Release 启动器：独立配置、托盘隐藏后单实例恢复、结束任务退出均通过。包内 Windows agent 另通过独立沙盒的 TLS、文件、ConPTY、代理和 AI 协议测试；模型使用本机合成响应，未调用商业模型。
- 此处记录于打包后，ZIP 内的文档保持构建时快照。

## 未验

合成夹具不等同于用户旧配置、多显示器及原生窗口贴靠。真实商业账号授权、模型识图／PDF 识别质量、长期弱网或慢盘、24 小时泄漏检查未验。
