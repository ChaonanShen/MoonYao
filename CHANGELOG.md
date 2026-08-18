# 更新日志

本文件记录 MoonYao Core 的重要变更。

## 未发布

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
