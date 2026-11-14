# 服务器与本机 GPU 监控（D-118、D-119）

## 使用与范围

在服务器的「监控」页查看 GPU 区域，每卡展示利用率、显存占用、温度、风扇、功耗；展开「设备详情与进程」可查看：

- UUID、PCI 总线地址、架构、性能状态、驱动版本及驱动支持的 CUDA 版本（不是已安装的 Toolkit）。
- 显存控制器、编解码利用率，空闲/保留显存、显存温度、GPU 降频温度阈值。
- 图形、SM、显存、视频频率，最高频率、当前/最大 PCIe 代际和通道数。
- 计算/持久化/MIG 模式，易失 ECC 纠正/未纠正计数，活动时钟限制原因。
- GPU 进程的 PID、计算/图形类型、程序名、显存及可用的 MIG GPU/计算实例号。

当前支持 **Linux 服务器与 Windows 本机的 NVIDIA GPU**，执行端需要可执行的 `nvidia-smi` 和可用驱动；AMD/Intel 采集尚未接入。Windows 命令隐藏控制台，PATH 找不到时尝试 NVSMI 默认路径。无需 root 或额外客户端依赖。容器/权限/驱动可能限制部分字段；未知值显示 `—`，不会当成 0。进程范围与驱动报告一致，没有进程列表时区分「没有进程」与「驱动未提供数据」。MIG 模式下展示物理卡和驱动报告的进程实例，不构造缺失的实例指标。

需要配套升级客户端和服务器 agent 才能获得全部详情。旧 agent 仍可显示 `sys.metrics.gpus` 基础数据，并提示升级。

## 刷新与失败

- 客户端每 2 秒分别请求系统/进程、GPU。每类最多一个在途请求，网络请求上限 8 秒。
- 隐藏监控页暂停轮询，重新显示立即刷新；切换连接清空原服务器数据并拒绝延迟返回的旧响应。
- 服务端共享单次 GPU 采集，成功缓存 1.5 秒。查询超时 3 秒，stdout 上限 8 MiB；缺少工具/超时退避 60 秒，其余失败退避 15 秒。没有后台定时采集。
- 基础 `sys.metrics` 只触发异步 GPU 刷新并读缓存，不等待外部驱动命令。新 `gpu.info` 等待共享采样，可取消等待。
- 失败保留上次成功值和原采样时间，界面显示错误及「上次成功数据」；恢复成功后自动清除过期标记。GPU 利用率与显存图按 UUID（其次 PCI 地址/编号）保留最近 60 次采样，未知点断线，不表示固定两分钟时长。

## `gpu.info` 协议

属于 `monitor` 服务，无参数。`nvidia-smi` 是可选依赖，不会使 CPU/内存监控不可用。

顶层字段：

| 字段 | 含义 |
|---|---|
| `gpus` | 每卡一项的数组，空列表为 `[]` |
| `ts` | 最近成功采集的 Unix 秒（小数）；从未成功为 0 |
| `status` | `ok`、`empty`、`unavailable`、`error`；非等待缓存首次为 `loading` |
| `error` / `stale` | 可读故障说明 / 是否沿用上次成功采样 |
| `driver` / `cuda` | 驱动版本 / 驱动支持的 CUDA 版本；缺失为空字符串 |

每卡保留原有 `index/name/util/mem_util/mem_used/mem_total/temp/power/power_limit/fan` 字段。新增字段见 `agent/internal/monitor/gpu.go`；内存均为 **MiB**、频率 MHz、功率 W、温度 °C、利用率与风扇为百分比；未知数值为 JSON null。`processes_available` / `clock_reasons_available` 明确区分未知与空列表。

`sys.metrics` 兼容字段为 `gpus` / `gpu_error`，另加 `gpu_status/gpu_ts/gpu_stale`。旧客户端首次请求可能先收到 `loading` 空缓存，后续请求取得数据。

## 验证

- Go 行为测试：混合驱动 XML、多卡、MiB/GiB、PCIe `16x`、N/A/无穷/无效值、进程与 MIG、缺工具、真实子进程超时、有界输出、并发合并、取消、基础监控不被阻塞、失败退避/恢复和可选服务依赖。
- Flutter 回归：GPU 慢响应与基础轮询独立、在途去重、隐藏/恢复、换连接的旧响应、关闭中响应、失败恢复、旧 agent、缺工具/无卡/过期、进程、未知值、窄面板和深浅主题。
- 测试使用合成双卡数据，不读取真实 profile、凭据或连接用户服务器。真实 NVIDIA 服务器、具体驱动和 MIG 部署仍需实机验证。

2026-11-14 结果：Go 7 组测试（含 3 个故障子场景）、Flutter 11 项回归全部通过；Go vet、Flutter 完整静态分析零问题，Linux amd64 agent 编译成功。已检查深浅主题截图；功能仍为本地开发版本，尚未打包发布。

运行：`go test ./internal/monitor`（Linux）；`flutter test test/monitor_gpu_test.dart`（Windows）。设置 `AURORA_GPU_SHOTS` 为输出目录可保存深浅主题截图。
