# MoonYao Core

MoonYao Core 是一个面向 [Yao Agent](https://yaoapps.com/docs/tutorials/en-us/agent/yao-agent)
公开行为、DSL 和执行模型的 MoonBit Native clean-room 移植。项目采用独立设计与实现，
不复制或逐行翻译 Yao 源码，也不以兼容完整 Yao App Engine 为目标。

第一版聚焦一条边界清晰的 Agent 完整链路：

```text
Agent/Prompt DSL -> SQLite 持久化会话 -> Agent Runtime
                                           |          |
                          Process 工具基础设施       OpenAI-compatible streaming chat
                    (Model / Flow / SQLite / HTTP)
```

Model、Process、Flow、SQLite 和 HTTP 不是独立的通用应用引擎产品线，而是让 Agent 能够
安全调用本地工具、持久化状态并通过 API 交互的最小基础设施。

## 当前状态

仓库当前已完成严格 Agent/Connector/Prompt DSL、SQLite 持久化 chat/turn/message、
OpenAI-compatible 普通及流式 Chat Completions 和 `agent chat` 多轮会话。作为 Agent 工具
基础，仓库也已完成 Model/Process/Flow DSL、SQLite CRUD 和异步 HTTP/1.1 Todo API。

## 支持范围

第一版仅支持 MoonBit Native、SQLite、严格 JSON DSL 和单一 OpenAI-compatible 文本
connector。当前尚未实现 Process tools、hooks、Agent HTTP/SSE、Web CUI、RAG、附件或
multi-agent；也不实现 Yao 的 JavaScript 运行时、插件、完整应用引擎、OpenAPI、认证、
多租户、多数据库、Join 或复杂 Flow 控制。

## 开发环境

项目必须使用支持 Native 目标的 MoonBit 工具链。请按
[MoonBit 官方安装文档](https://docs.moonbitlang.com/en/latest/tutorial/tour.html)
安装。

当前官方 macOS 安装脚本不支持 Darwin x86_64。Intel Mac 用户可使用本仓库提供的
Docker 开发环境，在本机运行 Linux x86_64 MoonBit 工具链：

```bash
docker build --tag moonyao-dev .
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev fmt --check
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev check --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev test --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev build --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev run src/cmd/main
```

Docker 容器是正式的本地开发与测试环境；详细的测试范围、执行方式和缓存策略见
[docs/TESTING.md](docs/TESTING.md)。GitHub Actions 运行相同的四项检查，以防止未在
本地执行的变更进入 `main`。

## 直接构建、测试与运行

在已安装 MoonBit 的环境中，从仓库根目录执行：

```bash
moon fmt --check
moon check --target native
moon test --target native
moon build --target native
moon run src/cmd/main -- bootstrap
```

当前程序会输出：

```text
MoonYao Core bootstrap: Native runtime is ready.
```

## Agent 快速开始

`example/todo` 包含一个 `todo` Agent。Connector 固定放在
`connectors/default.json`，API key 只填写环境变量名，不写入 DSL：

```json
{
  "id": "default",
  "type": "openai_chat",
  "base_url": "https://api.openai.com/v1",
  "api_key_env": "OPENAI_API_KEY",
  "model": "gpt-4o-mini",
  "timeout_ms": 60000
}
```

Agent 位于 `agents/<id>/agent.json`，同目录的 `prompts.json` 只接受 1 至 8 条
`system` 文本消息。首次对话会创建 chat，最终 JSON 行包含后续调用需要的 `chat_id`：

```bash
export OPENAI_API_KEY='...'
moon run src/cmd/main -- migrate ./example/todo
moon run src/cmd/main -- agent chat ./example/todo todo "Help me plan today's tasks"
moon run src/cmd/main -- agent chat ./example/todo todo "Which one should I do first?" --chat <chat-id>
```

命令在 stdout 逐行输出 `turn.started`、`message.delta`、`usage`、
`message.completed` 和最终 `turn.completed` JSON。会话、turn 和最终 assistant 文本保存在
应用 SQLite 数据库中；进程重启后可以继续同一个 chat。历史只回放成功的完整 turn，并按
100 条消息和 256 KiB UTF-8 内容上限从最旧完整 turn 开始裁剪。

当前只支持 `system`/`user`/`assistant` 文本和一个 `default` connector，不支持 tool call、
hook、图片、附件、provider fallback 或供应商 conversation ID。`check` 不读取 API key、
不联网也不访问数据库；key 仅在发起模型请求时读取，Authorization、完整 prompt 和响应
正文不会写入错误信息。

## Todo 工具基础示例

Todo CRUD 用来验证未来 Agent tools 复用的 Model、Process、Flow 和 HTTP 基础设施：

```bash
moon run src/cmd/main -- check ./example/todo
moon run src/cmd/main -- migrate ./example/todo
moon run src/cmd/main -- run ./example/todo models.todo.Create '{"data":{"title":"learn MoonBit"}}'
moon run src/cmd/main -- run ./example/todo models.todo.List '{"where":{"done":false},"limit":20,"offset":0}'
moon run src/cmd/main -- run ./example/todo models.todo.Update '{"id":1,"data":{"done":true}}'
moon run src/cmd/main -- run ./example/todo models.todo.Find '{"id":1}'
moon run src/cmd/main -- run ./example/todo models.todo.Delete '{"id":1}'
moon run src/cmd/main -- run ./example/todo flows.create_todo '{"body":{"title":"learn Flow"}}'
moon run src/cmd/main -- serve ./example/todo
```

服务缺省监听 `127.0.0.1:8080`，可在 `app.json` 通过 `listen` 设置另一个 IP literal 和
端口。启动前必须先运行 `migrate`。例如：

```bash
curl -X POST http://127.0.0.1:8080/todos -H 'Content-Type: application/json' -d '{"title":"HTTP Todo"}'
curl http://127.0.0.1:8080/todos
curl http://127.0.0.1:8080/todos/1
curl -X PATCH http://127.0.0.1:8080/todos/1 -H 'Content-Type: application/json' -d '{"done":true}'
curl -X DELETE http://127.0.0.1:8080/todos/1
```

API 文件位于 `apis/*.json`。支持 GET/POST/PATCH/DELETE、`:param`、query、headers 和
JSON body。当前服务仅适合 loopback 本地开发，没有认证、TLS server、CORS、上传或
静态文件服务；JSON body 上限为 1 MiB，query 最多 100 项。

`check` 只校验 DSL，不创建数据库；`migrate` 幂等创建模型表和内部会话表；`run` 接受一个
Process 名称和一个 JSON 值，成功时输出 JSON，失败时输出结构化 JSON 错误并以非零状态
退出。数据库路径相对于应用目录解析。

当前 CRUD 仅支持字段等值 `where`、非负 `limit`/`offset`，不接受 SQL 或查询 DSL
字符串。模型标识符必须先通过 DSL 校验，所有运行时值均使用 SQLite 参数绑定。SQLite
绑定尚不支持 NULL，因此 `nullable: true` 和 `default: null` 会在迁移阶段以
`invalid_dsl` 拒绝；关系、Join、schema diff 和事务编排不在当前范围内。

## 实现计划

1. 建立 Agent 工具所需的 Process、Model/SQLite、Flow 与 HTTP 基础。（已完成）
2. 实现严格 Agent DSL、单一流式 connector 与持久化多轮会话。（已完成）
3. 实现 Process tools、有限 hooks 与有界 Agent loop。
4. 实现 Agent HTTP/SSE API 与最小本地 Web CUI。
5. 完成 Agent 主链路的离线验收、文档和发布。

每个有效功能均须先建立 GitHub Issue，并通过聚焦的分支与 Pull Request 实现。

## 许可证与来源

MoonYao Core 使用 [Apache License 2.0](LICENSE)，它是 OSI 认可的开源许可证。
所有外部来源、依赖和许可证记录见 [docs/PROVENANCE.md](docs/PROVENANCE.md)。

Yao 当前仓库的许可证在标准 Apache-2.0 之外还有附加条款；该许可证适用于 Yao，
不改变 MoonYao 的许可证。MoonYao 只依据公开文档、接口与可观察行为编写规格并独立实现。
贡献者不得复制 Yao 源码，并应在引入任何外部素材前完成来源与许可证记录。

## 贡献规范

开始任何有效变更前，应先建立包含范围和验收条件的 Issue。使用聚焦分支开发，在 PR
中关联 Issue、补充测试，并在 CI 通过后合并。不得提交本地笔记、凭证、数据库或构建
产物。
