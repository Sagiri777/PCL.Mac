# PCL.Mac 🖥️

<div align="center">
  <img alt="Logo" src="/.github/assets/icon.png" width="180">

  [![Minimum OS Version](https://img.shields.io/badge/macOS-14.0+-81AD18)](https://developer.apple.com/macos/)
  [![Stars](https://img.shields.io/github/stars/PCL-Community/PCL.Mac?style=flat)](https://github.com/PCL-Community/PCL.Mac/stargazers)
  [![Activity](https://img.shields.io/github/commit-activity/y/PCL-Community/PCL.Mac?color=FF6C57)](https://github.com/PCL-Community/PCL.Mac/pulse)
  [![Contributors](https://img.shields.io/github/contributors/PCL-Community/PCL.Mac)](https://github.com/PCL-Community/PCL.Mac/graphs/contributors)
  <br>
  [![](https://hits.zkitefly.eu.org/?tag=https://github.com/PCL-Community/PCL.Mac)](https://hits.zkitefly.eu.org/?tag=https://github.com/PCL-Community/PCL.Mac&web=true)
</div>

## 简介

PCL.Mac 是使用 SwiftUI 框架重构的 [Plain Craft Launcher](https://github.com/Hex-Dragon/PCL2)，支持 macOS 平台。<br>
支持与主线 (PCL) 与[社区版](https://github.com/PCL-Community/PCL2-CE)一样的游戏安装（原版、Forge、Fabric、NeoForge）、Mod 下载与游戏管理。<br>
可运行本启动器的最低系统版本为 `macOS 14.0`。<br>
用户群：`1047463389`

### MacOS26 液态玻璃主题

在「设置 → 个性化」中选择 **MacOS26 液态玻璃**：

- macOS 26 使用系统原生 `Liquid Glass`；macOS 14–15 自动回退为纯 SwiftUI `Material` 毛玻璃。
- 整体背景、侧栏/面板、内容卡片的模糊程度可分别调整，并会自动保存。
- 窗口外缘使用较粗的磨砂玻璃框，可调整框宽、框体磨砂、圆角、表面不透明度、主题染色、边缘高光、投影和交互效果。
- 主题文件位于 `Resources/Themes/macos26.json`，其中可配置三个区域的默认强度与玻璃染色。
- 所有内置和本地主题默认可用，不需要主题激活码。

## 下载

本项目尚处早期开发阶段，可从 [Actions](https://github.com/PCL-Community/PCL.Mac/actions) 下载开发版。

> [!WARNING]
> 由于 App 未签名，直接打开可能会出现“已损坏”等提示。请：
> 1. 打开系统设置。
> 2. 进入「隐私与安全性」。
> 3. 滑到底部，点击「仍然打开」。
> 
> 签名并公证后的版本大概会在 2025 年 12 月发布，到时候就可以开袋即食啦～

## 从源码编译

```shell
git clone https://github.com/PCL-Community/PCL.Mac.git
cd PCL.Mac
xcodebuild -project PCL.Mac.xcodeproj -scheme PCL.Mac -configuration Debug -destination 'platform=macOS' build
```

如需在受限网络环境下解析 Swift Package 依赖，可以先设置代理：

```shell
export HTTP_PROXY=http://127.0.0.1:20122
export HTTPS_PROXY=http://127.0.0.1:20122
```

Microsoft 正版登录需要 OAuth `CLIENT_ID`。源码不会携带个人凭证；可在运行前通过环境变量或 `~/Library/Application Support/PCL.Mac/client_id.txt` 提供。

## 打包正式版

仓库提供 Release 打包脚本，输出 ad-hoc 签名的 `.app` 压缩包到 `dist/`：

```shell
scripts/package_release.sh
```

可选注入公开 OAuth client id 或 CI 更新用 token：

```shell
CLIENT_ID=你的公开客户端ID scripts/package_release.sh
ARTIFACT_PAT=你的GitHubToken scripts/package_release.sh
```

`ARTIFACT_PAT` 不应提交到仓库；脚本只读取环境变量，不会写入源码。

## 协议声明
`PCL.Mac.Core` 使用 MIT License，使用其代码时请遵循 MIT License 的规定，保留原有的版权声明和许可条款。

## 鸣谢

本项目实现参考了 HMCL 等 Minecraft 启动器的实现流程。

- FUNCTY
- [AMagicPear](https://github.com/AMagicPear)
- [Glavo](https://github.com/Glavo)
- [HMCL-Dev](https://github.com/HMCL-Dev)
- [Copilot](https://github.com/copilot)
- [aria2](https://github.com/aria2/aria2)
- NT | Krnl32
- 阿鱼 | 🐟🐟🐟
- [Ciilu](https://github.com/Ciilu)
