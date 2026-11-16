# Aurora 仓库开发约定

- 当前文档入口是 `docs/README.md`；文档组织与更新遵循 `docs/standards/documentation.md`。
- `docs/archive` 是历史材料，不能据此覆盖当前实现或宣称当前验收通过。旧 D-* 引用只用于追溯。
- 功能改变同时更新对应指南／参考；测试结果进入带日期的 `docs/validation`，原始日志进入证据目录。不要继续扩写旧的总计划／总设计流水账。
- 新 Markdown 使用规范要求的类型、状态、维护角色、更新日期和适用范围；移动文件同时修复链接、脚本和源码引用。
- 客户端 GUI 还须遵循 `app/AGENTS.md`，通过统一 GUI 入口接入。
- 检查入口：`powershell -NoProfile -File tools/check.ps1`；文档单独检查：`powershell -NoProfile -File tools/check-docs.ps1`。
- 打包使用新的版本／候选后缀和输出目录，保留已有交付。记录脏工作树、源码指纹、签名验证及实际运行范围。
