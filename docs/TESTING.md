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
```

提交 MoonBit、配置、文档或 CI 变更前，至少应完成前四项；修改可执行程序或示例时，还应
执行最后一项运行验证。Docker 运行产生的 `_build/` 目录已被 Git 忽略，不能提交。

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
