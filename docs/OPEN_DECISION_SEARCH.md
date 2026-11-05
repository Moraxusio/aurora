# 待决定：`fs.search` / `fs.find` / `fs.logs` 与 git、终端服务的边界

状态：待用户决定。其它实施工作不依赖它。

## 问题

v2 的 `internal/agent/search.go` 和 `search_text.go`（对应 `fs.find`、`fs.search`、`fs.logs`，属于 `files` 服务，D-45）需要两样不属于 `files` 的东西：

1. **git 服务的内部函数**：`search.go:39` 调用 `s.gitFor(abs)` 判断结果是否在 git 仓库里；`gitFor` 定义在 `gitrun.go`（git 服务）。
2. **终端服务的内部函数**：`gitFor` 内部调用 `s.sessionEnvVars()`，它属于终端服务（`tmuxbin.go`）。

D-40 规定服务之间不直接调用对方的内部函数，共享部分放在内核。这两处违反了该规定。

## 两个方案

**方案 1（默认，我的建议）：内核提供中性接口，git 服务实现它。**

- `files` 服务只依赖一个接口，例如 `RepoLocator`，方法为 `RepoOf(path) (root string, ok bool)`。
- `git` 服务实现该接口。`files` 不知道 git 的环境变量或会话变量。
- 搜索结果的行为不变：仍然标注结果是否在仓库内。
- 代价：多一个接口和一次适配，需要为接口本身写测试。

**方案 2：搜索结果不再标注 git 仓库。**

- `files` 完全不依赖 git。
- 代价：搜索结果少一个信息，属于可见的行为变化。

## 需要你决定

1. 选方案 1 还是方案 2？
2. 若选方案 1，接受 `RepoLocator` 接口这种形式吗？

在你决定之前，`internal/files/pending/` 中的两个文件不编译，也不影响其它服务。
