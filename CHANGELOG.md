# 更新日志

本文件记录 MoonYao Core 的重要变更。

## 0.1.0 - 2026-08-18

### 变更

- 将项目主目标明确为面向 Yao Agent 公开行为、DSL 和执行模型的 MoonBit clean-room 移植；
  Model、Process、Flow、SQLite 与 HTTP 定位为 Agent 工具的最小支撑基础。

### 新增

- MoonBit Native 工程骨架、可执行程序、单元测试和持续集成。
- Docker 本地 MoonBit Native 开发与测试环境。
- 严格 JSON 应用与 Model DSL 校验。
- SQLite schema 迁移及参数绑定的模型 Find/List/Create/Update/Delete Process。
- `check`、`migrate`、`run` CLI 子命令和 Todo 示例。
- 严格 `$in`、`$res`、`$global` JSON 值绑定与顺序 Flow Process。
- 固定 API DSL、异步 HTTP/1.1 `serve` 命令、请求限制与 Todo CRUD 路由。
- 严格 Connector/Agent/Prompt DSL、OpenAI-compatible 普通及流式 Chat Completions。
- SQLite 持久化 chat/turn/message、崩溃恢复、完整 turn 历史裁剪与 `agent chat` CLI。
- Process-backed Agent tools、受限 JSON Schema、流式 tool-call 聚合、有界执行循环、持久化
  tool transcript，以及可选的 Process-backed before/after hooks。
- 本地单用户 Agent JSON API、实时 SSE turn、持久化 chat 管理，以及无外部前端依赖的内置
  Web CUI；包含 request ID、CSP、安全响应头和断线后继续持久化。
- Conversation chat、message 和 turn 时间字段改用 64 位 Unix milliseconds，避免长时间戳
  截断并保持 API 排序稳定。
- 独立的 `example/todo-agent` 主发布示例，以及覆盖 429、500、timeout、malformed、disconnect、
  20 次顺序 turn 和不同 chat 并发运行的离线验收。
- provider-neutral canonical message 与 image/file attachment 模型；包含受限本地存储、完整性
  摘要、引用持久化、provider-boundary multimodal 投影和旧 text history migration。
- 完整 Context/Create/Next turn lifecycle：有界 context snapshot、严格 hook decisions、状态迁移、
  tool result 汇总和自定义 Next terminal data。
- turn deadline、显式 cancel、provider retry/backoff cancellation、同步 Process cancellation
  pending、终态 CAS 和 completion/cancellation race 防护。
- 持久化 turn event journal、`turn_id:sequence` SSE cursor、JSON/SSE replay、幂等 turn 创建、
  retry root/attempt 和 startup interruption recovery。
- Web CUI active-turn 自动恢复、POST 断线续传、事件去重、cancel/retry controls、幂等提交键和
  desktop/mobile 终态展示。
