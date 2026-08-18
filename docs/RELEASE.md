# 0.1.0 发布说明

MoonYao 0.1.0 是第一个 Agent-first release，主链路为：

```text
Todo Agent JSON -> persistent chat -> LLM -> Process tools -> SSE/Web CUI
```

主要功能、公开限制和升级说明见 [README](../README.md)，HTTP/SSE 契约见
[API reference](API.md)，依赖及许可证见 [PROVENANCE](PROVENANCE.md)。

## 已知限制

只支持 MoonBit Native、SQLite、单一 OpenAI-compatible connector 和可信 loopback 本地单用户
环境。没有认证、TLS、CORS、多租户、provider fallback、RAG、附件、多 Agent 或外部 MCP。
同步 Process timeout 不能强制抢占，tool side effect 没有通用事务回滚。

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
