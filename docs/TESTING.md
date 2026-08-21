# 测试指南

Docker 本地测试和 GitHub Actions 是 MoonYao Core 的两道必要验证。Docker 用于开发者
在提交前使用干净的 Linux x86_64 Native 环境验证；CI 则在 Pull Request 和 `main` 推送
时重复执行同一组检查。

## Docker 本地测试

本机没有可用的 MoonBit Native 工具链、或运行在 Intel Mac 时，使用项目根目录的
`Dockerfile` 创建测试镜像：

```bash
docker build --tag moonyao-dev .
```

随后在仓库根目录执行完整检查：

```bash
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev fmt --check
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev check --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev test --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev build --target native
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev run src/cmd/main -- bootstrap
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev run src/cmd/main -- check ./example/todo-agent
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev run src/cmd/main -- check ./example/todo
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev run src/cmd/main -- migrate ./example/todo
```

Agent 是主要验收路径，测试不需要真实 provider 或 API key。测试套件使用内存 SQLite 和
loopback fake LLM server，覆盖严格的多 Connector/Agent/Prompt DSL、OpenAI-compatible、
Anthropic Messages 和 Gemini GenerateContent 普通与分块 SSE 响应、各协议认证 header 和请求
JSON、HTTP 500、timeout、三轮持久化、active-turn 冲突、启动恢复及
硬删除。canonical message 测试覆盖 text/image/file parts、attachment metadata 与完整性、
provider-boundary 投影、引用持久化和旧 text schema 升级。Process tools 测试覆盖 schema
meta-validation、运行时参数校验、流式 tool arguments 聚合、allowlist、tool transcript、
8-round/32-call 边界、Process 错误和 Create/Next/before/after lifecycle hooks。

控制面测试覆盖 cancel/deadline race、provider read 与 retry backoff cancellation、同步 Process
取消、唯一 terminal event、幂等 request hash、retry root/attempt、canonical retry copy、事件
journal cursor 和启动后 `interrupted` 恢复。Agent 平台测试覆盖严格 request/query/metadata/
attachment limits、脱敏、chat/message 分页、internal transcript 隔离、SSE escaping/公开事件
过滤，以及真实 TCP 上的 JSON turn、POST SSE、journal resume、幂等 replay、长流断开后后台
完成、CUI 静态资源和 CSP/security headers。

fake provider 监听动态 `127.0.0.1:0` 端口，由测试 task group 管理生命周期。覆盖普通文本、
分块文本、三轮 history、tool create、非法参数修复、allowlist、HTTP 429/500、timeout、非法
JSON、缺少 `[DONE]` 的中途断开，以及 tool arguments 分片聚合。matcher 验证 model、messages、
tools、stream 和 Authorization 是否存在，但断言及错误输出不包含 bearer 值。可靠性 smoke
连续完成 20 个 turn，并发运行两个独立 chat runtime，并验证 completion/cancellation race 只
提交一个终态。

Todo CRUD 是 Agent 工具基础设施的回归路径。HTTP 变更还需启动 `serve ./example/todo`，以
真实 TCP 请求覆盖 Create/List/Find/Update/Delete、非法 JSON、错误 Content-Type、未知路由
和 405 `Allow` 响应。

修改 CUI 时还需在浏览器检查桌面与移动视口，验证发送、attachment、取消、retry、断线续传、
刷新 active chat 和各终态的 control enablement，并使用类似
`<img src=x onerror=alert(1)>` 的纯文本 fixture 确认不会生成可执行 DOM。续传检查必须确认
sequence 不重复且 terminal 后历史只出现一次。真实 provider 的手工流式测试需要设置 API
key；自动化测试使用 loopback fake provider，不需要外部网络。

人工验证真实 provider 时，先运行 `migrate`，再设置 DSL 所指向的环境变量并执行
`agent chat`；不得把 key 写进 fixture、命令日志或仓库文件。

0.1.0 发布验收日为 2026-08-19。当前自动离线验收覆盖 118 个测试；当前环境没有提供真实
connector 凭据，因此真实 provider 三轮、工具循环和无效 key 人工检查未执行，不能将其
解读为通过。

提交 MoonBit、配置、文档或 CI 变更前，至少应完成前四项；修改可执行程序或示例时，还应
执行对应的运行验证。测试覆盖 Agent fake-client 主链路、CLI `check` 无文件副作用、
`migrate` 创建/升级会话及模型 schema、`run` JSON/错误路径、有界 tool loop 和内存 SQLite CRUD。Docker 运行
产生的 `_build/` 和示例 `.db` 文件已被 Git 忽略，不能提交。

## Docker 镜像缓存策略

`Dockerfile` 不使用 `COPY` 将项目源码放入镜像；测试时通过 bind mount 将当前工作目录
挂载到 `/workspace`。因此，普通源码、测试和文档改动不会使 Ubuntu、MoonBit 或 C 编译器
层失效，重复执行 `docker build` 会复用这些层。

镜像层按变更频率排列：

1. Ubuntu 24.04 基底；
2. 下载 MoonBit 所需的系统工具；
3. MoonBit 官方安装脚本；
4. 仅 Native 构建需要的 C 工具链；
5. Mooncakes 注册表索引预热；
6. 工作目录和入口点。

修改第六层之后的运行方式不会重新下载 MoonBit；只有修改相应层的 Dockerfile 内容、主动
使用 `--no-cache`，或本地 Docker 清除了缓存时，才会重建前面的层。升级 MoonBit 时应有
意地修改工具链安装层，并在同一 PR 重新执行完整测试。

## CI

`.github/workflows/ci.yml` 在 Pull Request 与 `main` 推送时运行：

```text
moon fmt --check
moon check --target native
moon test --target native
moon build --target native
```

CI 通过是合并条件，但不替代开发者在 Docker 中完成的本地验证。

## Package 验收

以下命令生成并列出 Mooncakes artifact，再从空目录中的解包内容运行离线命令：

```bash
docker run --rm --mount "type=bind,src=$PWD,dst=/workspace" moonyao-dev package --list
MOONYAO_PACKAGE_DIR=$(mktemp -d "$PWD/../moonyao-package.XXXXXX")
unzip _build/publish/ChaonanShen-MoonYao-0.1.0.zip -d "$MOONYAO_PACKAGE_DIR"
docker run --rm --mount "type=bind,src=$MOONYAO_PACKAGE_DIR,dst=/workspace" moonyao-dev check --target native
docker run --rm --mount "type=bind,src=$MOONYAO_PACKAGE_DIR,dst=/workspace" moonyao-dev run src/cmd/main -- check ./example/todo-agent
rm -r "$MOONYAO_PACKAGE_DIR"
```

检查清单不得包含 `.local.*`、`.env`、数据库、WAL/SHM、日志、`_build` 或 `target`。临时目录
和测试数据库在验收后删除；服务测试必须关闭 listener，不得遗留进程或固定端口。
