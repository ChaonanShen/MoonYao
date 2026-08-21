# 0.1.0 发布说明

MoonYao 0.1.0 是第一个 Agent-first release，主链路为：

```text
Todo Agent JSON -> persistent chat -> LLM -> Process tools -> SSE/Web CUI
```

主要功能、公开限制和升级说明见 [README](../README.md)，HTTP/SSE 契约见
[API reference](API.md)，依赖及许可证见 [PROVENANCE](PROVENANCE.md)。

## 已知限制

只支持 MoonBit Native、SQLite，以及由 Agent 显式选择的 OpenAI-compatible、Anthropic
Messages 或 Gemini GenerateContent connector 和可信 loopback 本地单用户环境。没有认证、
TLS、CORS、多租户、provider fallback/路由、RAG、多 Agent 或外部 MCP。
attachment 只支持受限 image 和 UTF-8 text 类型。同步 Process timeout/cancel 不能强制抢占，
retry 可能重复 Process side effect，且 tool side effect 没有通用事务回滚。

## 升级、备份与回滚

`migrate` 会把 conversation schema 顺序升级到 v6，包括 canonical messages、attachment
references、lifecycle snapshots、cancel/deadline fields、idempotency/retry columns 和持久化
event journal。migration 在事务中执行且可重复调用，但 schema 只向前升级，不提供自动
downgrade。

升级前停止 `serve`，并备份两项：应用配置的 SQLite 文件（例如
`example/todo-agent/todo-agent.db`）和应用目录下的整个 `data/attachments/`。如果数据库使用
WAL，必须在服务停止并完成 checkpoint 后复制数据库，或使用 SQLite online backup；不要只在
服务运行时复制主 `.db` 而遗漏 WAL。数据库与 attachment 目录必须作为同一个一致性备份保留。

```bash
cp example/todo-agent/todo-agent.db /safe/backup/todo-agent.db
cp -R example/todo-agent/data/attachments /safe/backup/attachments
moon run src/cmd/main -- migrate ./example/todo-agent
```

升级后先运行 `check` 和测试，再启动服务。需要回滚旧二进制时，先停止新服务，再同时恢复
升级前数据库和 attachment 目录；旧二进制不能安全读取已升级 schema。不要尝试手工删除
`_moonyao_migrations`、event rows 或新增 columns。任何升级失败都应保留现场副本，并从一致性
备份恢复后排查。

## 可复现验证

```bash
moon fmt --check
moon check --target native
moon test --target native
moon build --target native
moon run src/cmd/main -- check ./example/todo-agent
moon run src/cmd/main -- check ./example/todo
moon package --list
```

0.1.0 使用 Moon `0.1.20260814`、Moonc `v0.10.8+8606a5800` 验收。默认测试完全离线，fake
provider 只监听动态 loopback 端口。真实 connector 需要验收者自行提供环境变量；2026-08-18
的发布环境没有提供凭据，因此未执行真实 provider 人工验收。

## 发布

Mooncakes 发布目标为 `ChaonanShen/MoonYao@0.1.0`。维护者登录后从干净的 tag checkout
执行：

```bash
moon package --list
moon publish --dry-run
moon publish
```

发布前核对 package list 不含 `.local.*`、数据库、日志、凭据、`_build` 或 `target`。随后创建
annotated tag `v0.1.0` 和同名 GitHub Release。任何失败必须修复源文件并重新运行完整门槛，
不得手工修改 artifact。
