# Agent HTTP 与 SSE API

本文记录 MoonYao 0.1.0 的本地 Agent 平台契约。服务默认监听 `127.0.0.1:8080`，没有认证、
TLS、CORS 或租户隔离，不得直接暴露到公网。

## JSON envelope

成功响应使用 `{"data":...}`；分页列表同时返回
`{"meta":{"limit":20,"offset":0,"total":1}}`。错误使用：

```json
{"error":{"code":"invalid_argument","message":"...","path":"..."}}
```

响应包含 `X-Request-Id`。错误不会包含 API key、Authorization、system prompt、完整 provider
body、SQL 或数据库路径。

## Endpoints

| Method | Path | 用途 |
| --- | --- | --- |
| `GET` | `/v1/health` | readiness |
| `GET` | `/v1/agents` | 返回脱敏 Agent metadata |
| `POST` | `/v1/chats` | 创建 chat；body 为 `agent_id` 和可选 `title` |
| `GET` | `/v1/chats` | 按 `agent_id`、`limit`、`offset` 分页 |
| `GET` | `/v1/chats/:id` | 读取 chat |
| `PATCH` | `/v1/chats/:id` | 修改 `title` |
| `DELETE` | `/v1/chats/:id` | 删除非 active chat 及消息 |
| `GET` | `/v1/chats/:id/messages` | 读取公开文本消息 |
| `POST` | `/v1/chats/:id/turns` | 执行 turn；body 为 `content` |
| `GET` | `/agent/` | 内置 Web CUI |

`POST /turns` 默认返回一次性 JSON。请求头 `Accept: text/event-stream` 时返回 SSE。`/v1` 与
`/agent` 是保留命名空间，应用 API DSL 不能覆盖。

## SSE events

公开事件按发生顺序发送：`turn.started`、零个或多个 `message.delta`、`tool.started`、
`tool.completed`、`hook.started`、`hook.completed`、`usage`、`message.completed`，最后恰好一个
`turn.completed` 或 `turn.failed`。内部 tool arguments delta 不公开。客户端断开不会取消
Runtime；应重新读取 chat/messages 获取最终状态。

## Limits 与状态

- JSON body 最大 1 MiB，query 最多 100 项；分页参数必须是非负整数。
- 当前用户输入和 history 各受 256 KiB/100 消息边界约束，只按完整 turn 裁剪。
- 单 turn 最多 8 个 LLM round、32 个 tool calls、5 分钟总预算。
- tool arguments 最大 128 KiB，单个 tool result 最大 256 KiB。
- 同一 chat 只允许一个 active turn；不同 chat 可以独立运行。
- tool name 必须在 Agent allowlist 中，参数必须通过受限 object JSON Schema。

稳定错误 code 包括 `invalid_argument`、`invalid_dsl`、`route_not_found`、
`method_not_allowed`、`record_not_found`、`conflict`、`database_error` 和 `llm_error`。provider 的
429、5xx、timeout、畸形 JSON/SSE 与连接中断均映射为脱敏的 `llm_error`/HTTP 502。
