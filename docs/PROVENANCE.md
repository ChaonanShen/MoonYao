# 来源与许可证记录

本文件记录 MoonYao Core 参考、使用或依赖的外部来源。引入新依赖、复制外部素材或以
新的外部行为作为实现依据时，必须在同一个 Pull Request 更新本记录。

| 条目 | 来源及固定版本/提交 | 许可证 | 在 MoonYao 中的用途 |
| --- | --- | --- | --- |
| Yao App Engine | [YaoApp/yao](https://github.com/YaoApp/yao)，提交 [`1eb2bb1ec89540bd50345b2b456eeb087bc21de0`](https://github.com/YaoApp/yao/tree/1eb2bb1ec89540bd50345b2b456eeb087bc21de0) | 修改版 Apache-2.0；附加商业、品牌和验证要求，详见[上游 LICENSE](https://github.com/YaoApp/yao/blob/main/LICENSE) | 仅作为公开概念和行为参考。MoonYao 独立设计与实现，不复制或翻译任何上游源码文件。 |
| MoonBit 工具链与核心库 | [moonbitlang/moon](https://github.com/moonbitlang/moon)、[moonbitlang/core](https://github.com/moonbitlang/core) | 工具链：AGPL-3.0；Core：Apache-2.0 | MoonBit 提供的构建工具与标准库；不随本仓库分发。 |
| `moonbitlang/x@0.4.50` | [moonbitlang/x](https://github.com/moonbitlang/x)，版本 `0.4.50` | Apache-2.0 | 仅使用 Native `fs` 包读取应用 DSL 文件和目录；不复制其源码。 |
| `moonbit-community/sqlite3@0.1.6` | [moonbit-community/sqlite3.mbt](https://github.com/moonbit-community/sqlite3.mbt)，版本 `0.1.6` | Apache-2.0 | Native SQLite 绑定；用于 P2 的参数绑定、内存数据库和 schema/CRUD 实现。 |
| `actions/checkout@v5` | [actions/checkout](https://github.com/actions/checkout) | MIT | 在 GitHub Actions 中检出仓库源码。 |
| `hustcer/setup-moonbit@v1.22` | [hustcer/setup-moonbit](https://github.com/hustcer/setup-moonbit/tree/v1.22) | MIT | 在 GitHub Actions 中安装 MoonBit 工具链。 |
| Ubuntu 24.04 容器基底 | [ubuntu:24.04](https://hub.docker.com/_/ubuntu) | Ubuntu 许可证 | 为 Intel Mac 提供本地 Linux x86_64 MoonBit 开发与测试环境。 |

## 规则

- 不得添加来源不明的代码、测试、文档、图片或数据。所有外部素材都必须记录 URL、版本
  或提交、许可证、用途和修改内容。
- 不得复制 Yao 实现文件。需要兼容的公开行为，应先写成规格，再以 MoonBit 独立实现。
- 不能仅依赖仓库页面显示的许可证标识；引入外部代码前须核验上游许可证全文及其适用
  范围。
