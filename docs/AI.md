# AI 工作台与 ChatGPT 订阅

设备码授权和上下文元数据需要客户端及 agent 3.12.0 以上；3.11.0 不包含这些功能。

## 查看提供商、模型和上下文

- 工作台上方显示本步/最近一步实际发送的提供商配置与模型 ID；下方另列下一次调用的选择。运行中切换模型不会改写旧回答的身份。
- 每条回答保留当时的提供商和模型。旧会话没有这些信息时显示“未知提供商”，不会用当前设置猜测。
- 上下文显示活动历史的 **估算 tokens / 输入预算、百分比和占用条**；悬停说明中可查看上次调用的精确输入 tokens。缓存命中已经包含在输入中，不重复相加。
- “累计用量”是所有调用消耗，**不是上下文长度**。压缩与回退后活动上下文重新估算；未发送的输入、附件不在这个统计里。
- 模型目录返回的上下文按模型保存。AI 设置可手动覆盖输入窗口，留空或 0 使用目录/默认预算；此手动覆盖对该提供商配置生效，换模型时应检查并清除旧值。
- 默认预算不保证等于上游的真实最大窗口；网关也可能把模型 ID 映射到别的模型，Aurora 无法认证网关内部实际使用的模型。

## 使用 device 模式连接 OpenAI / ChatGPT

1. 连接服务器并启用 `ai` 服务，打开 AI 设置。
2. 添加“OpenAI / ChatGPT 订阅（设备码）”预设，或将登录方式改成“ChatGPT 订阅 · Device 设备码”。
3. 如果服务器不能直连 OpenAI，启用“代理出口”；授权与模型调用均从服务器发出。
4. 点“使用设备码登录”，自行在浏览器打开 `https://auth.openai.com/codex/device`，输入对话框中的设备码并批准。账号需要启用设备码登录，并有相应订阅/模型资格。
5. 授权成功后登录凭据立即加密保存；选模型后点“保存并启用”。订阅模型列表只是内置建议，不是账号可用性查询，也可以手动输入模型 ID。

仅授权自己刚刚发起的登录，不要把设备码交给他人。最长等待 15 分钟；取消、返回或到期会停止后续轮询，在途响应也不会继续应用。

**注意：登录和退出立即保存，不受设置窗口底部“取消”影响。** 退出只清除本机令牌；如需撤销账号端授权，请到 OpenAI 的账号设置处理。

## 凭据与实现范围

- API Key、OAuth access/refresh 都只保存在客户端加密 `profile.bin`（Windows DPAPI / Android Keystore 保护的加密配置）。
- run/models/compact 仅经固定指纹 TLS 发送 access；refresh 只在专用刷新 RPC 中短暂经过 agent 内存。它们不进入 agent 会话文件、广播事件或审计记录。
- 客户端在发送、取模型、压缩前检查到期并合并并发刷新；先成功保存新令牌，再使用它。保存失败保留输入，不继续发送。
- 订阅固定连接官方 ChatGPT/Codex，忽略自定义地址与 headers，拒绝重定向；不会把订阅令牌交给普通 API 网关。
- 长任务超过 access 有效期时会报错；回到客户端重新发送即可触发刷新，必要时重新登录。agent 不保存 refresh 来无限续跑。
- 复用 OpenCode MIT 的 headless device 流、token 交换/刷新、account 路由、Codex HTTP SSE 与默认订阅输入预算；标题、压缩和子智能体共用这一路径。尚未移植 WebSocket、zstd、browser callback 或 token-sharing。
- 当前自动化验证使用本地 HTTP 桩和合成令牌；**真实订阅账号授权和对话尚未验证**。

参考：OpenCode [`openai.ts`](https://github.com/anomalyco/opencode/blob/3d308eae2e68dc39dfc12aba9dd408f9ce1cc0a1/packages/core/src/plugin/provider/openai.ts)、[`openai-context-caps.ts`](https://github.com/anomalyco/opencode/blob/3d308eae2e68dc39dfc12aba9dd408f9ce1cc0a1/packages/core/src/plugin/provider/openai-context-caps.ts) 与 [MIT 许可证](../agent/internal/ai/THIRD_PARTY_OPENCODE_LICENSE)。
