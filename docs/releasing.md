# PCL.Mac 构建与发版

本文档说明普通提交构建、正式版发布和预发布版本发布流程。

## 普通推送构建

普通 commit 推送到 `main` 后，`Build macOS App` 工作流会自动运行，并分别构建：

- `PCL.Mac-arm64`：Apple Silicon（M 系列芯片）。
- `PCL.Mac-x86_64`：Intel Mac。

两个 ZIP 会作为 GitHub Actions Artifact 保存，但不会创建版本标签或 GitHub Release。

## 提交信息规范

自动 Release Notes 会统计上一个版本标签之后、`bump_version` 提交之前的全部 commit，并根据 Conventional Commits 前缀分类。

支持的主要类型：

- `feat:`：新功能。
- `fix:`：问题修复。
- `perf:`：性能优化。
- `refactor:`：代码重构。
- `docs:`：文档。
- `build:` / `ci:`：构建与 CI。
- `chore:`：工程维护。
- `test:`：测试。
- `style:`：代码样式。
- `feat!:`、`fix!:` 或正文包含 `BREAKING CHANGE:`：破坏性变更。

可以使用作用域，例如：

```text
feat(download): 支持新的下载源
fix(login): 修复 Microsoft 登录回调
perf(core): 减少实例扫描耗时
```

无法识别类型的 commit 会归入“其他改动”。

## 发布正式版

确保需要发布的代码已经全部进入 `main`，然后创建一条以 `bump_version` 开头的空 commit：

```shell
git switch main
git pull --ff-only
git commit --allow-empty -m "bump_version 1.1.0"
git push
```

也可以在版本前添加 `v`，或在关键字后使用冒号：

```text
bump_version v1.1.0
bump_version: 1.1.0
```

工作流会自动执行以下操作：

1. 校验版本格式，并确认目标标签不存在。
2. 从上一个版本标签开始统计 commit，生成分类 Release Notes。
3. 分别构建 arm64 与 x86_64 Release 包。
4. 创建目标标签，例如 `v1.1.0`。
5. 创建 GitHub Release，并上传两个架构的 ZIP。
6. 将正式版标记为 Latest Release。

发布包名称如下：

```text
PCL.Mac-v1.1.0-arm64.zip
PCL.Mac-v1.1.0-x86_64.zip
```

## 发布预构建版本

预构建版本使用 SemVer 后缀。推荐按稳定程度使用 `alpha`、`beta`、`rc`：

```text
1.2.0-alpha.1
1.2.0-beta.1
1.2.0-rc.1
```

例如发布第一个 Beta：

```shell
git switch main
git pull --ff-only
git commit --allow-empty -m "bump_version 1.2.0-beta.1"
git push
```

工作流将创建：

```text
标签：v1.2.0-beta.1
Apple Silicon：PCL.Mac-v1.2.0-beta.1-arm64.zip
Intel Mac：PCL.Mac-v1.2.0-beta.1-x86_64.zip
```

GitHub Release 会被标记为 Prerelease，不会替代当前的 Latest Release。应用包内部的 `CFBundleShortVersionString` 使用符合 Apple 要求的基础数字版本 `1.2.0`，完整的预发布版本保留在标签、Release 标题和文件名中。

发布后续预构建版本时递增序号：

```shell
git commit --allow-empty -m "bump_version 1.2.0-beta.2"
git push
```

从 Beta 进入候选正式版：

```shell
git commit --allow-empty -m "bump_version 1.2.0-rc.1"
git push
```

确认预构建版本稳定后发布正式版：

```shell
git commit --allow-empty -m "bump_version 1.2.0"
git push
```

正式版会创建 `v1.2.0` 标签，并成为新的 Latest Release。

## 注意事项

- `bump_version` 必须是本次 push 的最后一条 commit。
- 每个版本只能发布一次；目标标签已存在时工作流会终止。
- 不要修改或复用已经公开的版本标签。
- `bump_version` commit 只用于触发发布，不会出现在自动生成的改动分类中。
- 构建或发布失败时，应修复原因后在 GitHub Actions 中重新运行原工作流；不要直接复用相同版本创建另一条触发 commit。
