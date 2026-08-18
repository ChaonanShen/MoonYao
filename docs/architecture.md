# MoonYao Core v1 架构契约

本文定义 MoonYao Core 第一版的稳定边界。它是后续实现、测试、示例和文档的共同依据；
本版本未明确列出的功能均不在支持范围内。

## 目标与边界

MoonYao Core 是仅面向 MoonBit Native 的轻量声明式应用引擎。第一版必须打通下列
纵向路径：

```text
严格 JSON DSL -> 应用校验/加载 -> SQLite Model Process -> 顺序 Flow -> HTTP/CLI
```

第一版支持 SQLite、严格 JSON、单表 CRUD、等值过滤、顺序 Flow、固定 HTTP 路由和
`check`、`migrate`、`run`、`serve` 四个 CLI 命令。它不支持 JavaScript、插件、认证、
多数据库、模型关联、Join、schema diff、复杂查询、Flow 分支/循环/并行、UI 或 Agent。

## 分层与依赖方向

```text
errors, json, identifiers
          |
          v
    DSL types and loader ----> process registry
          |                         |
          v                         v
 SQLite adapter <----------- model processes
          |                         |
          +----------> binding -> sequential flow
                                      |
                                      v
                             CLI and HTTP adapters
```

- `errors`：公开的 `EngineError`、错误码、诊断路径和外部错误映射。
- `app`：读取应用目录，解析并校验 DSL；`check` 期间不得创建数据库或监听端口。
- `process`：名称到处理器的注册与调用，不知道 HTTP、Flow 或 SQLite 的细节。
- `sqlite`：连接、statement、参数绑定、行读取及资源释放；不含 DSL 知识。
- `model`：从已校验 Model 生成 schema 和五个 CRUD Process。
- `binding`、`flow`：解析 `$in`、`$res`、`$global` 并顺序调用 Process。
- `cli`、`http`：输入/输出适配层；不得包含 SQL、CRUD 或 Flow 的业务逻辑。

依赖只能从右向左指向下层。特别是核心库不得依赖 HTTP 框架，也不得把 SQLite 驱动
错误泄露到 HTTP 层。

## Process 契约

每个 Process 都只有一个 JSON 输入和一个 JSON 输出：

```text
Json -> Result[Json, EngineError]
```

因此不存在位置参数或可变参数。Model Process 的 v1 输入约定如下：

| Process | 输入 |
| --- | --- |
| `models.<id>.Find` | `{ "id": 1 }` |
| `models.<id>.List` | `{ "where": { "done": false }, "limit": 20, "offset": 0 }` |
| `models.<id>.Create` | `{ "data": { "title": "write docs" } }` |
| `models.<id>.Update` | `{ "id": 1, "data": { "done": true } }` |
| `models.<id>.Delete` | `{ "id": 1 }` |

HTTP 和 Flow 都只负责构造上述单个 JSON 值。未知 Process、重复 Process 名和不符合
该输入协议的值必须返回结构化错误。

## DSL 与安全规则

- 输入文件为严格 UTF-8 JSON；不支持 JSONC、YAML 或运行时脚本。
- 模型、字段、表、Flow、节点和全局键的标识符必须匹配
  `[A-Za-z_][A-Za-z0-9_]*`，并在加载时校验唯一性。
- SQL 标识符只能由已经校验的 Model 元数据产生；所有数据值必须使用 SQLite 参数绑定。
- Model 只接受已声明字段。未知字段、非法 `where`、负数分页或大于上限的 `limit`
  都是 `invalid_argument`，不能忽略或截断。
- 首版迁移只创建尚不存在的表和索引；发现不兼容的既有 schema 时失败，不尝试 diff、
  修改或删除。
- HTTP 将限制 body 大小；客户端只得到脱敏错误，永远不包含 SQL、数据库文件路径或
  驱动原始消息。

## 错误和可观察性

错误的机读形式固定为：

```json
{
  "error": {
    "code": "invalid_dsl",
    "message": "column name is invalid",
    "path": "models/todo.json.columns[1].name"
  }
}
```

首版错误码为 `invalid_dsl`、`invalid_argument`、`model_not_found`、
`process_not_found`、`flow_not_found`、`route_not_found`、`record_not_found`、
`database_error` 与 `internal_error`。CLI 在失败时退出码非零；HTTP 的具体状态码由
HTTP 适配层在 P4 定义。

## 技术依赖决策

| 能力 | P0 决策 | 后续门槛 |
| --- | --- | --- |
| JSON | 使用 MoonBit Core 内建 `Json` 和 `@json.parse`，不添加第三方库。 | P1 编写解析、对象访问、错误路径测试。 |
| SQLite | 评估 `moonbit-community/sqlite3` 的固定版本，优先复用其预编译与参数绑定能力。 | 该库当前未公开 `NULL` 的绑定/读取能力；在 P2 之前必须以最小实验确认可扩展方案，或缩小/调整已声明的 nullable 行为。 |
| HTTP | P4 评估 `oboard/mocket` 的固定版本，并将其隔离在 `src/http/`。 | 必须通过 Native 最小路由、JSON body、关闭服务及端到端请求测试，才可作为正式依赖。 |

添加任何依赖前，必须核验源码、许可证、固定版本及目标平台，并在
`docs/PROVENANCE.md` 的同一变更中记录。不得复制 Yao 源码；Yao 仅提供公开概念和
行为参考。
