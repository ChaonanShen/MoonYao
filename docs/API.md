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
body、SQL、数据库路径、attachment storage key 或本地文件路径。

## Endpoints

| Method | Path | 用途 |
| --- | --- | --- |
| `GET` | `/v1/health` | readiness |
| `GET` | `/v1/agents` | 返回脱敏 Agent metadata |
| `POST` | `/v1/chat/completions` | OpenAI Chat Completions 兼容子集 |
| `POST` | `/v1/chats` | 创建 chat；body 为 `agent_id` 和可选 `title` |
| `GET` | `/v1/chats` | 按 `agent_id`、`limit`、`offset` 分页 |
| `GET` | `/v1/chats/:id` | 读取 chat 和 `active_turn_id` |
| `PATCH` | `/v1/chats/:id` | 修改 `title` |
| `DELETE` | `/v1/chats/:id` | 删除非 active chat 及消息 |
| `GET` | `/v1/chats/:id/messages` | 读取公开 canonical messages；不返回 internal transcript |
| `POST` | `/v1/chats/:id/turns` | 创建 text 或 canonical multimodal turn |
| `GET` | `/v1/turns/:id` | 读取 turn 状态、attempt、deadline、usage 和脱敏错误 |
| `POST` | `/v1/turns/:id/cancel` | 幂等请求取消 active turn |
| `POST` | `/v1/turns/:id/retry` | 从可重试终态创建新 attempt |
| `GET` | `/v1/turns/:id/events` | 以 JSON 或 SSE 重放持久化事件 journal |
| `POST` | `/v1/attachments` | 上传 base64 image 或 UTF-8 text attachment |
| `GET` | `/v1/attachments/:id` | 读取不含 storage key 的 attachment metadata |
| `GET` | `/agent/` | 内置 Web CUI |

`/v1` 与 `/agent` 是保留命名空间，应用 API DSL 不能覆盖。

## OpenAI Chat Completions 兼容子集

`POST /v1/chat/completions` 接受 `model`、`messages` 和可选 `stream`、`temperature`、
`max_tokens`、`user`。`model` 是已配置的 MoonYao Agent ID。接口接受 `system`、`user` 和
`assistant` string messages，但当前一次调用只将最后一个 `user` message 作为新的持久化 turn；
Agent 自己的 prompt 保持有效。这使常见 OpenAI SDK 和前端可以直接发起单轮请求，同时避免
客户端 history 覆盖服务端的 canonical conversation。

每个 completion 调用都会新建一条持久化 chat；需要续接同一会话、附件、取消、retry 或 event
replay 时，应使用 MoonYao 原生的 `/v1/chats/:id/turns` API。暂不支持 OpenAI message content
parts、tool/function calling、`response_format`、`n`、logprobs 或 provider conversation ID。

普通响应使用 OpenAI 的 `chat.completion` shape；`stream: true` 使用 `text/event-stream`，发送
`chat.completion.chunk` data frames 并以 `data: [DONE]` 结束。工具执行对 stream 客户端保持
内部实现细节，不暴露 tool argument 或结果 transcript。

```json
{
  "model": "todo",
  "messages": [
    { "role": "user", "content": "List my open tasks" }
  ],
  "stream": false
}
```

## Turn 输入

兼容 text 请求：

```json
{
  "content": "Summarize the current todos",
  "options": {
    "timeout_ms": 120000,
    "metadata": { "source": "local-cui" }
  }
}
```

canonical multimodal 请求先上传 attachment，再引用服务返回的 opaque ID：

```json
{
  "message": {
    "role": "user",
    "content": [
      { "type": "text", "text": "Describe this image and note" },
      { "type": "image", "attachment_id": "att_...", "detail": "auto" },
      { "type": "file", "attachment_id": "att_...", "filename": "note.md" }
    ]
  }
}
```

`content` 与 `message` 互斥。canonical message 必须为 `user` role；image `detail` 只接受
`auto`、`low`、`high`。attachment 必须已存在、类型匹配且属于本机服务；持久化历史只保存
opaque reference，provider 投影只在执行边界临时展开。

请求头 `Accept: text/event-stream` 返回 SSE，否则等待终态并返回 JSON。客户端可以给创建或
retry 请求提供 `Idempotency-Key`。同一 chat 下，相同 key 和相同 canonical 请求只执行一次；
相同 key 对应不同请求返回 `409 conflict`。CUI 每次发送和 retry 都生成 key，并在 POST
连接尚未获得 turn ID 时复用该 key。

## 生命周期、取消与 retry

turn 状态为 `active`、`completed`、`failed`、`cancelled`、`timed_out` 或 `interrupted`。
同一 chat 同时只允许一个 active turn，不同 chat 可以并发。`options.timeout_ms` 是包含 hooks、
provider、tool loop 和 Process 的 turn 总 deadline。

取消是 cooperative hard cancellation：provider 读取和 retry backoff 可立即中止；同步
Process 不能被底层强制抢占，服务会先发 `turn.cancellation_pending_process`，并丢弃 Process
返回值后终结为 `cancelled`。重复取消不会创建第二个终态。

`failed`、`cancelled`、`timed_out`、`interrupted` 可以 retry，`active` 和 `completed` 不可以。
retry 创建新的 turn ID，保留 root/`retry_of_turn_id` 和递增 `attempt`，并复制原始 canonical
用户输入与 attachment references。retry 可能再次触发 Process side effects，JSON 响应和
CUI 会明确显示 `Retry may repeat Process side effects`。

服务启动时把遗留 active turn 原子恢复为 `interrupted` 并写入唯一 terminal event；调用方可
在确认业务副作用后显式 retry。

## SSE 与断线恢复

事件 journal 与 turn 状态一起持久化。事件 ID 格式为 `<turn_id>:<sequence>`，sequence 从 1
递增。公开事件包括：

- `turn.started`
- `hook.started`、`hook.completed`
- `provider.retrying`
- `message.delta`、`message.completed`
- `tool.started`、`tool.completed`
- `turn.cancellation_pending_process`
- `usage`
- 恰好一个 `turn.completed`、`turn.failed`、`turn.cancelled`、`turn.timed_out` 或
  `turn.interrupted`

内部 tool argument delta 不公开。客户端断开不会取消 Runtime。续传使用：

```http
GET /v1/turns/turn_.../events?after=12
Accept: text/event-stream
```

也可发送 `Last-Event-ID: turn_...:12`。同时发送时，header 与 `after` 必须一致；跨 turn、负数或
非法 cursor 返回结构化 `400`。不请求 SSE 时，该 endpoint 返回最多 1000 个 JSON event。
客户端必须只消费 sequence 大于本地 cursor 的 event。内置 CUI 在 POST 断线后自动用 journal
续传，页面刷新后也会根据 chat 的 `active_turn_id` 恢复，不重复拼接已确认 delta。

## Limits 与安全边界

- HTTP JSON body 最大 15,000,000 bytes；query 最多 100 项；分页 `limit` 为 1–100。
- text/canonical preview 最大 65,536 UTF-8 bytes；metadata JSON 最大 32 KiB。
- canonical content 为 1–16 parts；单 message 最多 8 个 attachment references。
- 单 image 最大 10 MiB；单 UTF-8 text attachment 最大 2 MiB；base64 字段最大
  14,000,000 characters。仅接受 PNG、JPEG、GIF、WebP、plain text、Markdown、JSON、CSV，
  并校验 magic bytes 或 UTF-8/NUL。
- `Idempotency-Key` 为 1–128 个受限 ASCII 字符。
- turn timeout 为 1,000–300,000 ms；单 event payload 最大 256 KiB；event replay 上限 1000。
- history 按完整 turn 裁剪，最多 100 条、256 KiB；单 turn 最多 8 个 LLM round、32 个 tool
  calls、5 分钟默认总预算。
- tool arguments 最大 128 KiB，单个 tool result 最大 256 KiB。

稳定错误 code 包括 `invalid_argument`、`invalid_dsl`、`route_not_found`、
`method_not_allowed`、`record_not_found`、`turn_conflict`、`database_error`、`llm_error`、
`turn_cancelled`、`turn_timed_out` 和 `turn_interrupted`。provider 的 429、5xx、timeout、畸形
JSON/SSE 与连接中断均映射为脱敏错误；retry 只发生在尚未产生可见输出的安全瞬态失败上。
