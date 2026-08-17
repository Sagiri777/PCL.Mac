# PCL.Mac Glass Edition

高度可定制液态玻璃主题的第三方 macOS 版 Plain Craft Launcher 构建。

本仓库是基于 PCL.Mac 相关开源仓库的独立仓库，用于保存当前可构建版本与公开 release。它不是 PCL 官方仓库，也不代表原作者或上游社区发布。

本项目名称为 `PCL.Mac Glass Edition`，核心特点是拥有高度可定制的液态玻璃主题，包括玻璃强度、边框、染色、圆角、投影和不同区域的视觉参数调整。

## 当前版本

- Release: `v2.2.0`
- 上游同步基线: `PCL 2.13.1.1`（2026-08-17）
- 系统要求: macOS 14.0+
- 构建产物: 分别面向 Apple Silicon（arm64）与 Intel Mac（x86_64）的 ad-hoc 签名 `.app` 压缩包

## 项目特点

- 高度可定制的液态玻璃主题。
- 可分别调整窗口、侧栏、面板与内容区域的玻璃观感。
- 保留 PCL.Mac 的实例、下载、整合包导入与 Mod 管理能力。

## 主要改动

- 支持拖入 `.mrpack` / 整合包 `.zip` 后创建实例。
- 支持从资源下载页导入整合包。
- 改进批量下载：并发下载、候选源切换、SHA1 校验与失败重试。
- 支持默认关闭的无障碍浏览器自动化下载：开启后可为受限 CurseForge 队列自动打开已验证文件的官方下载页，仍需通过 SHA-1 校验后才会归位。
- 导入整合包后自动刷新实例列表。
- 支持 Modrinth、CurseForge、HMCL 与普通 `.minecraft/versions/...` 压缩包的基础识别/导入流程。
- 跟进 PCL 2.13.1.1：实例概览可直接打开截图文件夹；整合包导出可独立控制光影设置文件，并只包含已导出光影包对应的设置。
- 修正隔离实例导出范围：Mod、配置、存档、资源包与光影包均从当前实例目录收集，不会误打包共享目录中的其它内容。

## v2.0.3—v2.2.0 路线图成果

- `v2.0.3`：Microsoft/Yggdrasil 凭据迁移到 macOS Keychain；登录失败不再带假令牌启动；Java 安装增加校验、原子替换、回滚和重试；CI 默认运行确定性测试。
- `v2.1`：实例诊断中心、脱敏报告导出、配置/Mod/资源包快照与事务恢复；常用交互补齐键盘、VoiceOver、减少动态效果和减少透明度支持。
- `v2.2`：Modrinth SHA-1 模组识别与更新中心，支持渠道约束、递归必需依赖、更新前快照和失败回滚；联机中心支持服务器收藏、状态/延迟查询、实例绑定与直达启动。
- 安全加固：移除全局 ATS 明文网络放行和内置 GitHub PAT，更新检查只打开本仓库的公开 Release 页面，不再由运行中的应用覆盖自身。

## 下载

请到本仓库的 [Releases](https://github.com/Sagiri777/PCL.Mac/releases) 页面下载。

> 注意：当前包未经过 Apple Developer ID 签名和公证。首次启动时 macOS 可能提示无法验证开发者，可在「系统设置 -> 隐私与安全性」中手动允许打开。

## 从源码编译

```shell
git clone https://github.com/Sagiri777/PCL.Mac.git
cd PCL.Mac
xcodebuild -project PCL.Mac.xcodeproj -scheme PCL-Mac -configuration Debug -destination 'platform=macOS' build
```

如需通过本地代理访问 GitHub / Swift Package 依赖：

```shell
export http_proxy="http://127.0.0.1:20122"
export https_proxy="http://127.0.0.1:20122"
```

Microsoft 正版登录需要 OAuth `CLIENT_ID`。源码不会携带个人凭证；可在运行前通过环境变量或 `~/Library/Application Support/PCL.Mac/client_id.txt` 提供。

## 打包

```shell
scripts/package_release.sh
```

脚本会分别生成 `PCL.Mac-<版本>-arm64.zip` 与 `PCL.Mac-<版本>-x86_64.zip`，用户可根据 Mac 处理器架构选择对应安装包。

可选注入公开 OAuth client id：

```shell
CLIENT_ID=你的公开客户端ID scripts/package_release.sh
```

`Secrets.xcconfig`、构建目录和 release 压缩包已在 `.gitignore` 中排除。

## 协议与声明

本仓库包含或参考 Plain Craft Launcher / PCL.Mac 相关实现。请阅读并遵守 [LICENSE](LICENSE) 与 [PCL.Mac.Core/LICENSE](PCL.Mac.Core/LICENSE)。

本项目不应与 Plain Craft Launcher 官方、PCL-Community 或其他上游项目混淆。

## 参考与致谢

- [Hex-Dragon/PCL2](https://github.com/Hex-Dragon/PCL2)
- [PCL-Community/PCL.Mac](https://github.com/PCL-Community/PCL.Mac)
- [PCL-Community/PCL2-CE](https://github.com/PCL-Community/PCL2-CE)
- [CylorineStudio/PCL.Mac.Refactor](https://github.com/CylorineStudio/PCL.Mac.Refactor)
- [HMCL-Dev/HMCL](https://github.com/HMCL-dev/HMCL)
- [aria2](https://github.com/aria2/aria2)
- [SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON)
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
- [TOMLKit](https://github.com/LebJe/TOMLKit)
