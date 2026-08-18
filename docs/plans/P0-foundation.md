# P0：规格固化与 Native 基础设施验证

关联 Issue：[\#6](https://github.com/ChaonanShen/MoonYao/issues/6)。

## 目的

在写入任何引擎业务代码前，使第一版范围、模块边界、Process 输入输出和后续依赖决策
可审阅、可测试、可追踪。P0 不实现 SQLite CRUD、Flow 或 HTTP 服务。

## 前置条件

- 工作树干净，使用分支 `feat/6-foundation-plan`。
- GitHub 已创建 Issue \#6，记录范围、验收和许可证影响。
- Docker 可用，作为没有本地 MoonBit Native 工具链时的标准运行环境。

## 计划步骤

1. 建立 `docs/architecture.md`，固定 v1 范围、依赖方向、错误模型、安全约束和单
   JSON Process 协议；删除“多位置参数 Process”这一歧义。
2. 在本文件中记录 P0 的工作边界、依赖选择准则、自动验证与人工验证。建立后续 P1--P5
   的关卡，但不提前实现它们。
3. 验证 Docker 镜像能提供 MoonBit Native 工具链，并在挂载的当前工作树依次运行
   `fmt --check`、`check --target native`、`test --target native`、`build --target native`
   与 bootstrap 程序。
4. 完成技术选择的静态探针：
   - JSON：核验 MoonBit Core 内建 `Json` 可解析、遍历对象并输出 JSON，且不需要外部依赖。
   - SQLite：核验候选库的 Native 目标、参数绑定、内存数据库、资源释放、许可证和
     `NULL` 能力；把任何不足作为 P2 的阻塞条件，而不是隐含在实现里。
   - HTTP：核验候选框架的 Native 支持、许可证与依赖规模；只在 P4 以实际最小服务决定采用。
5. 检查文档链接和工作树，执行完整 Docker 验证，记录工具链版本和结果。

## 不变量

- 本阶段不添加运行时第三方依赖，也不把探针代码留在生产包中。
- 不创建 SQLite 数据库、构建产物或本地说明文件并提交。
- 不复制或翻译 Yao 的源码；外部信息只用于公开 API 和许可证判断。
- 每项未来依赖都要在引入的同一 PR 更新来源记录。

## 完成条件

- [x] `docs/architecture.md` 已定义可执行的 v1 合同。
- [x] 技术决策、未解决风险和 P2/P4 的准入条件已记录。
- [x] Docker 中的格式、检查、测试、构建和运行均通过。
- [x] `git status --short` 只包含本阶段的受控文档改动。
- [x] P1 的详细实施计划可以在不重新讨论架构边界的前提下编写。

## 自动验证

```bash
docker build --tag moonyao-dev .
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev fmt --check
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev check --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev test --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev build --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev run src/cmd/main
```

## 人工验证

P0 的人工验证只验证开发环境，不验证引擎功能。执行最后一条命令后，预期精确输出：

```text
MoonYao Core bootstrap: Native runtime is ready.
```

SQLite、Flow 和 HTTP 尚未实现，任何声称这些功能已可手工验证的结果都应视为不通过。

## 执行记录（2026-08-18）

- Docker 镜像 `moonyao-dev` 已成功构建；容器内工具链为 Moon `0.1.20260814`、
  moonc `0.10.8`。
- `moon fmt --check`、`moon check --target native`、`moon test --target native`、
  `moon build --target native` 均以退出码 `0` 完成。
- 测试结果为 `1 passed, 0 failed`；运行命令输出预期 bootstrap 文本。
- JSON 使用 Core 内建能力，无外部依赖。SQLite 候选库已经确认具备 Native、内存数据库、
  预编译和位置参数绑定，但 `NULL` 的公开支持不足仍是 P2 开始前必须解决的风险。
- HTTP 候选框架只在 P4 通过最小实际服务探针后才可引入；P0 未添加任何运行时依赖。

## 后续关卡

| 阶段 | 开始条件 | 完成后的新增人工验证 |
| --- | --- | --- |
| P1 | P0 完成；JSON 行为确认。 | `moonyao check` 能区分合法与非法 DSL，且无副作用。 |
| P2 | SQLite 的 `NULL`/布尔映射方案以最小实验通过。 | `migrate`、`run` 与 `sqlite3` 可验证真实 CRUD。 |
| P3 | P2 的 Process 输入输出稳定。 | `run flows.<id>` 可验证节点绑定与错误中止。 |
| P4 | P3 的 Flow 运行时稳定，HTTP 依赖最小服务探针通过。 | `curl` 可完成 Todo HTTP CRUD。 |
| P5 | P4 的黑盒端到端测试通过。 | 从干净 checkout 按 README 完成完整演示与发布复验。 |
