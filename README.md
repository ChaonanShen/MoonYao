# MoonYao Core

MoonYao Core 是一个使用 MoonBit Native 实现的声明式轻量应用引擎，参考
[Yao App Engine](https://github.com/YaoApp/yao) 的公开概念和使用体验。项目采用
独立的 clean-room 设计与实现，不复制或逐行翻译 Yao 源码。

第一版只做一条边界清晰的完整链路：

```text
JSON DSL -> 应用加载 -> SQLite CRUD / Process -> 顺序 Flow -> HTTP API
```

## 当前状态

仓库当前完成 M1 基础骨架：MoonBit Native 模块、最小可执行程序、单元测试及 GitHub
Actions 持续集成。SQLite、JSON DSL、Process 调度、Flow、HTTP 和面向用户的 CLI
子命令尚未实现。

## 支持范围

第一版仅支持 MoonBit Native、SQLite 和严格 JSON DSL，用于声明模型、顺序 Flow 与
固定 HTTP 路由。不实现 Yao 的 JavaScript 运行时、插件、Agent、UI、OpenAPI、认证、
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

Docker 容器是本地开发与测试环境；GitHub Actions 运行相同的四项检查，以防止未在
本地执行的变更进入 `main`。

## 直接构建、测试与运行

在已安装 MoonBit 的环境中，从仓库根目录执行：

```bash
moon fmt --check
moon check --target native
moon test --target native
moon build --target native
moon run src/cmd/main
```

当前程序会输出：

```text
MoonYao Core bootstrap: Native runtime is ready.
```

## 实现计划

1. 定义结构化错误和单一 JSON 值的 Process 协议。
2. 在无副作用条件下加载并校验 Model DSL。
3. 实现 SQLite Schema 创建及全部使用参数绑定的 CRUD Process。
4. 实现输入/结果绑定与顺序 Flow。
5. 实现 HTTP 路由、CLI 子命令与 Todo 端到端示例。

每个有效功能均须先建立 GitHub Issue，并通过聚焦的分支与 Pull Request 实现。

## 许可证与来源

MoonYao Core 使用 [Apache License 2.0](LICENSE)，它是 OSI 认可的开源许可证。
所有外部来源、依赖和许可证记录见 [docs/PROVENANCE.md](docs/PROVENANCE.md)。

Yao 当前仓库的许可证在标准 Apache-2.0 之外还有附加条款；该许可证适用于 Yao，
不改变 MoonYao 的许可证。贡献者不得复制 Yao 源码，并应在引入任何外部素材前完成
来源与许可证记录。

## 贡献规范

开始任何有效变更前，应先建立包含范围和验收条件的 Issue。使用聚焦分支开发，在 PR
中关联 Issue、补充测试，并在 CI 通过后合并。不得提交本地笔记、凭证、数据库或构建
产物。
