# 来源与许可证记录

本文件记录 MoonYao Core 参考、使用或依赖的外部来源。引入新依赖、复制外部素材或以
新的外部行为作为实现依据时，必须在同一个变更中更新本记录。

| 条目 | 来源及固定版本/提交 | 许可证 | 在 MoonYao 中的用途 |
| --- | --- | --- | --- |
| Yao Agent / Yao App Engine | [YaoApp/yao](https://github.com/YaoApp/yao)，提交 [`1eb2bb1ec89540bd50345b2b456eeb087bc21de0`](https://github.com/YaoApp/yao/tree/1eb2bb1ec89540bd50345b2b456eeb087bc21de0)；[Yao Agent 公开文档](https://yaoapps.com/docs/tutorials/en-us/agent/yao-agent) | 修改版 Apache-2.0；附加商业、品牌和验证要求，详见[上游 LICENSE](https://github.com/YaoApp/yao/blob/main/LICENSE) | 作为 Agent package/prompt/connector、conversation、streaming、Process tools 与执行模型的公开规格和可观察行为参考。MoonYao 在 MoonBit 中独立设计实现；不复制、翻译或改写上游源码。Model、Process、Flow 与 HTTP 只实现 Agent 工具所需的最小子集，不移植完整应用引擎。 |
| MoonBit 工具链与核心库 | [moonbitlang/moon](https://github.com/moonbitlang/moon) `0.1.20260814` (`a2de5b2`)、`moonc v0.10.8+8606a5800`；[moonbitlang/core](https://github.com/moonbitlang/core)，随该工具链解析的版本 | 工具链：AGPL-3.0；Core：Apache-2.0 | MoonBit 提供的构建工具与标准库；不随本仓库分发。Docker 与 0.1.0 发布验收使用这些精确工具链版本。 |
| `moonbitlang/x@0.4.50` | [moonbitlang/x](https://github.com/moonbitlang/x)，版本 `0.4.50` | Apache-2.0 | 仅使用 Native `fs` 包读取应用 DSL 文件和目录；不复制其源码。 |
| `moonbit-community/sqlite3@0.1.6` | [moonbit-community/sqlite3.mbt](https://github.com/moonbit-community/sqlite3.mbt)，版本 `0.1.6` | Apache-2.0 | Native SQLite 绑定；用于 P2 的参数绑定、内存数据库和 schema/CRUD 实现。 |
| `moonbitlang/async@0.20.6` | [moonbitlang/async](https://github.com/moonbitlang/async)，版本 `0.20.6` | Apache-2.0 | Native async runtime、TCP、HTTP/1.1 server，以及 OpenAI-compatible HTTPS client、timeout 和增量 SSE 读取；不复制其源码。 |
| MoonBit Core `encoding` / `crypto` | 随上述 `moonbitlang/core` 工具链版本提供 | Apache-2.0 | 严格 UTF-8/base64 处理、attachment SHA-256 完整性摘要，以及 canonical idempotency request hash；不引入额外运行时依赖。 |
| Anthropic Messages API | [Messages API](https://platform.claude.com/docs/en/api/messages) 与 [Streaming Messages](https://platform.claude.com/docs/en/build-with-claude/streaming)，访问于 2026-08-21 | Anthropic 文档条款 | 仅作为 Messages 请求/响应、tool use、usage 与 SSE 事件的公开协议依据；实现未引入 Anthropic SDK 或复制示例代码。 |
| Gemini GenerateContent API | [Google AI GenerateContent reference](https://ai.google.dev/api/generate-content)，访问于 2026-08-21 | 文档 CC BY 4.0；示例代码 Apache-2.0 | 仅作为 `generateContent`/`streamGenerateContent`、function calling、usage、SSE 与认证 header 的公开协议依据；实现未引入 Google SDK 或复制示例代码。 |
| `actions/checkout@v5` | [actions/checkout](https://github.com/actions/checkout) | MIT | 在 GitHub Actions 中检出仓库源码。 |
| `hustcer/setup-moonbit@v1.22` | [hustcer/setup-moonbit](https://github.com/hustcer/setup-moonbit/tree/v1.22) | MIT | 在 GitHub Actions 中安装 MoonBit 工具链。 |
| Ubuntu 24.04 容器基底 | [ubuntu:24.04](https://hub.docker.com/_/ubuntu) | Ubuntu 许可证 | 为 Intel Mac 提供本地 Linux x86_64 MoonBit 开发与测试环境。 |

## 规则

- 不得添加来源不明的代码、测试、文档、图片或数据。所有外部素材都必须记录 URL、版本
  或提交、许可证、用途和修改内容。
- 不得复制 Yao 实现文件。需要兼容的公开行为，应先写成规格，再以 MoonBit 独立实现。
- Yao Agent 的移植边界以公开文档、公开接口和可重复观察到的行为为准；未公开实现细节不作为
  兼容承诺，也不得通过源码翻译引入。
- Multimodal canonical messages、Context/Create/Next lifecycle、cancel/deadline、retry、event
  journal 和 CUI reconnect 均为 MoonBit 独立设计实现；只参考公开概念和可观察契约，没有复制
  或翻译上游实现文件。
- Anthropic 与 Gemini adapter 只在 provider boundary 投影 MoonYao canonical messages；不会把
  供应商 conversation ID、自动 fallback、SDK 状态或未公开行为引入核心运行时。
- 不能仅依赖仓库页面显示的许可证标识；引入外部代码前须核验上游许可证全文及其适用
  范围。
