//
//  MainView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/18.
//

import SwiftUI

fileprivate struct LeftTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var dataManager: DataManager = .shared
    @ObservedObject private var accountManager: AccountManager = .shared

    @State private var instance: MinecraftInstance?
    /// 启动流程进行中。用于禁用按钮并给出反馈 —— 之前连点几次“启动游戏”
    /// 会并发跑多份前置检查和资源校验。
    @State private var isLaunching: Bool = false


    private var accountView: some View {
        Button {
            dataManager.router.append(.accountManagement)
        } label: {
            MyListItem {
                VStack {
                    if let account = accountManager.getAccount() {
                        MinecraftAvatar(account: account, src: account.uuid.uuidString)
                        Text(account.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color("TextColor"))
                    } else {
                        Image("Missingno")
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 58)
                            .padding(6)
                        Text("无账号")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color("TextColor"))
                    }
                    Text("账号管理")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                        .padding(.top, 2)
                }
                .padding(4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accountManager.getAccount().map { "账号 \($0.name)" } ?? "未选择账号")
        .accessibilityHint("打开账号管理")
    }
    
    var body: some View {
        VStack {
            Spacer()
            accountView
            Spacer()
            if let instance = self.instance {
                MyButton(
                    text: isLaunching ? "正在启动……" : "启动游戏",
                    descriptionText: instance.name,
                    foregroundStyle: AppSettings.shared.theme.getTextStyle()
                ) {
                    launch(instance)
                }
                .frame(height: 55)
                .padding()
                .padding(.bottom, -27)
                .disabled(isLaunching)
                .opacity(isLaunching ? 0.7 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isLaunching)
            } else {
                MyButton(text: "下载游戏", descriptionText: "未找到可用的游戏版本") {
                    dataManager.router.setRoot(.download)
                }
                .frame(height: 55)
                .padding()
                .padding(.bottom, -27)
            }
            HStack(spacing: 12) {
                MyButton(text: "版本选择") {
                    dataManager.router.append(.versionSelect)
                }
                .keyboardShortcut("l", modifiers: .command)
                if instance != nil {
                    MyButton(text: "版本设置") {
                        if let instance = self.instance {
                            dataManager.router.append(.versionSettings(instance: instance))
                        }
                    }
                }
            }
            .frame(height: 32)
            .padding()
            .padding(.bottom, 4)
        }
        .frame(width: 300)
        .foregroundStyle(Color(hex: 0x343D4A))
        .task(id: AppSettings.shared.defaultInstance) {
            // MinecraftInstance.create 要读配置、解析清单（可能沿 inheritsFrom 递归），
            // 放到后台，避免侧栏出现时卡一下主线程。
            let directory = AppSettings.shared.currentMinecraftDirectory
            let name = AppSettings.shared.defaultInstance
            guard let directory, let name else {
                self.instance = nil
                return
            }
            let resolved = await Task.detached(priority: .userInitiated) {
                MinecraftInstance.create(directory, directory.versionsURL.appending(path: name))
            }.value
            self.instance = resolved
        }
    }

    /// 启动游戏。isLaunching 期间禁止重复触发。
    private func launch(_ instance: MinecraftInstance) {
        guard !isLaunching else { return }
        isLaunching = true
        let launchOptions: LaunchOptions = .init()

        Task {
            defer { isLaunching = false }
            guard await launchPrecheck(launchOptions) else { return }
            debug("正在启动游戏")
            await instance.launch(launchOptions)
        }
    }
    
    private func launchPrecheck(_ launchOptions: LaunchOptions) async -> Bool {
        // MARK: - Java 检查
        if case .failure(let error) = LaunchPrecheck.checkJava(instance!, launchOptions) {
            switch error {
            case .javaNotFound:
                PopupManager.shared.show(.init(.error, "错误", "你还没有安装 Java\n如果你安装过 Java 并且没有在 Java 管理中看到，请点击“手动添加 Java”", [.init(label: "安装 Java", style: .normal), .close])) { button in
                    if button == 0 {
                        dataManager.router.path = [.settings, .javaSettings, .javaDownload]
                    }
                }
                return false
            case .noUsableJava(let minVersion):
                PopupManager.shared.show(.init(.error, "错误", "当前没有满足条件的 Java 版本\n你需要安装 \(minVersion) 及以上版本的 Java！", [.init(label: "安装 Java", style: .normal), .close])) { button in
                    if button == 0 {
                        dataManager.router.path = [.settings, .javaSettings, .javaDownload]
                    }
                }
                return false
            case .javaNotSupport:
                PopupManager.shared.show(.init(.error, "错误", "你安装 / 选择了一个 ARM64 架构的 Java，但你的电脑不支持。\n请进入 设置 > Java 管理，安装 / 选择一个 x64 架构的 Java。", [.init(label: "安装 Java", style: .normal), .close])) { button in
                    if button == 0 {
                        dataManager.router.path = [.settings, .javaSettings, .javaDownload]
                    }
                }
                return false
            case .invalidMemoryConfiguration:
                PopupManager.shared.show(.init(.error, "错误", "无效的内存配置：0MB。\n请在 版本设置 > 设置 中调整游戏内存配置", [.ok]))
            case .rosetta:
                if await PopupManager.shared.showAsync(.init(.normal, "警告", "你安装 / 选择了一个 x64 架构的 Java，需要通过转译运行，这将会损耗大部分性能。\n你可以进入 设置 > Java 管理，安装 / 选择一个 ARM64 架构的 Java。", [.init(label: "继续启动", style: .normal), .close]))
                == 1 {
                    return false
                }
            }
        }

        guard await nativeCompatibilityPrecheck(instance!) else { return false }
        
        if case .failure(let error) = LaunchPrecheck.checkAccount(instance!, launchOptions) {
            switch error {
            case .missingAccount:
                PopupManager.shared.show(.init(.error, "错误", "请先创建一个账号并选择再启动游戏！", [.ok]))
            case .noMicrosoftAccount:
                if Locale.current.region?.identifier == "CN" {
                    if [3, 8, 15, 30, 50, 70, 90, 110, 130, 180, 220, 280, 330, 380, 450, 550, 660, 750, 880, 950, 1100, 1300, 1500, 1700, 1900].contains(AppSettings.shared.launchCount) {
                        let button = await PopupManager.shared.showAsync(.init(.normal, "考虑一下正版？", "你已经启动了 \(AppSettings.shared.launchCount) 次 Minecraft 啦！\n如果觉得 Minecraft 还不错，可以购买正版支持一下，毕竟开发游戏也真的很不容易……不要一直白嫖啦。\n在登录一次正版账号后，就不会再出现这个提示了！", [.init(label: "支持正版游戏！", style: .normal), .init(label: "下次一定", style: .normal)]))
                        if button == 0 {
                            NSWorkspace.shared.open(URL(string: "https://www.xbox.com/zh-cn/games/store/minecraft-java-bedrock-edition-for-pc/9nxp44l49shj")!)
                            return false
                        }
                    }
                } else {
                    let button = await PopupManager.shared.showAsync(.init(.normal, "正版验证", "你必须先登录正版账号才能启动游戏！", [.init(label: "购买正版", style: .normal), .init(label: "试玩", style: .normal), .init(label: "返回", style: .normal)]))
                    if button == 0 {
                        NSWorkspace.shared.open(URL(string: "https://www.xbox.com/zh-cn/games/store/minecraft-java-bedrock-edition-for-pc/9nxp44l49shj")!)
                        return false
                    } else if button == 1 {
                        launchOptions.isDemo = true
                    }
                }
            }
        }
            
        return true
    }

    private func nativeCompatibilityPrecheck(_ instance: MinecraftInstance) async -> Bool {
        let configuredJava: URL? = instance.config.javaURL
        let javaArchitecture = configuredJava.map { Architecture.getArchOfFile($0) } ?? .system
        let targetArchitecture: Architecture = switch javaArchitecture {
        case .unknown, .fatFile: .system
        default: javaArchitecture
        }
        do {
            let scanned = try await NativeCompatibilityService.shared.analyze(
                instance: instance,
                targetArchitecture: targetArchitecture
            )
            let pendingDisableIDs = Set(scanned.issues.filter {
                $0.autoFixEligible && $0.action == .disableMod && !$0.isApplied
            }.map(\.id))
            let pendingOfficialArtifactIDs = Set(scanned.issues.filter {
                $0.autoFixEligible && $0.action == .installOfficialArtifact && !$0.isApplied
            }.map(\.id))
            let report = try await NativeCompatibilityService.shared.applyTrustedFixes(report: scanned)
            let newlyDisabled = report.issues.filter {
                pendingDisableIDs.contains($0.id) && $0.isApplied
            }

            if !newlyDisabled.isEmpty {
                let names = newlyDisabled.prefix(8).map { "• \($0.modName)" }.joined(separator: "\n")
                let overflow = newlyDisabled.count > 8 ? "\n以及另外 \(newlyDisabled.count - 8) 个" : ""
                _ = await PopupManager.shared.showAsync(.init(
                    .normal,
                    "已隔离 Windows-only Mod",
                    "这些 Mod 已改名为 .jar.disabled，不会在 macOS 中加载：\n\n\(names)\(overflow)\n\n可在版本设置的 Mod 页面查看原因或恢复。",
                    [.ok]
                ))
            }

            let newlyCompleted = report.issues.filter {
                pendingOfficialArtifactIDs.contains($0.id) && $0.isApplied
            }
            if !newlyCompleted.isEmpty {
                let names = newlyCompleted.prefix(8).map { "• \($0.modName)" }.joined(separator: "\n")
                let overflow = newlyCompleted.count > 8 ? "\n以及另外 \(newlyCompleted.count - 8) 个" : ""
                _ = await PopupManager.shared.showAsync(.init(
                    .normal,
                    "已补全官方 Mac 组件",
                    "已按同一 Mod、同一版本及精确 SHA-256 安装官方原生依赖：\n\n\(names)\(overflow)",
                    [.ok]
                ))
            }

            let unresolved = report.unacknowledgedIssues
            guard !unresolved.isEmpty else { return true }
            let names = unresolved.prefix(6).map { "• \($0.modName)：\($0.reason)" }.joined(separator: "\n")
            let overflow = unresolved.count > 6 ? "\n以及另外 \(unresolved.count - 6) 个" : ""
            let button = await PopupManager.shared.showAsync(.init(
                .normal,
                "发现待确认的原生组件",
                "以下项目可能影响 Mac 启动，但证据不足，因此没有自动停用：\n\n\(names)\(overflow)",
                [
                    .init(label: "仍然启动", style: .normal),
                    .init(label: "返回检查", style: .accent)
                ]
            ))
            if button == 0 {
                try await NativeCompatibilityService.shared.acknowledge(
                    issueIDs: unresolved.map(\.id),
                    instance: instance
                )
                return true
            }
            return false
        } catch {
            // A diagnostic failure must not masquerade as a game failure. Keep
            // the launch available and retry next time, while leaving evidence
            // in the launcher log.
            warn("启动前 Mac 原生兼容性检查失败：\(error.localizedDescription)")
            hint("Mac 原生兼容性检查暂未完成，已保留启动", .critical)
            return true
        }
    }
}

struct LaunchView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    @ObservedObject private var announcementManager: AnnouncementManager = .shared
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ScrollView {
            if AppSettings.shared.showAnnouncements,
               let announcement = announcementManager.latest {
                announcement.createView(showHistoryButton: true) {
                    DataManager.shared.router.append(.announcementHistory)
                }
                    .padding()
            }
            
            if SharedConstants.shared.isDevelopment && AppSettings.shared.showDevelopmentWarning {
                StaticMyCard(index: 0, title: "警告") {
                    VStack(spacing: 4) {
                        Text("你正在使用本地开发版本的 PCL.Mac Liquid Glass Edition！")
                            .font(.custom("PCL English", size: 14))
                        HStack(spacing: 4) {
                            Text("如果遇到问题请")
                                .font(.custom("PCL English", size: 14))
                            Button {
                                    NSWorkspace.shared.open(SharedConstants.shared.projectURL)
                            } label: {
                                Text("点击此处反馈")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                            .accessibilityLabel("打开项目反馈页面")
                        }
                    }
                    .foregroundStyle(Color("TextColor"))
                }
                .padding()
                
            }

            if SharedConstants.shared.isDevelopment && AppSettings.shared.showDevelopmentLogs {
                StaticMyCard(index: 1, title: "日志") {
                    VStack {
                        // 自适应：ScrollView 默认纵向滚；高度封顶避免撑爆主界面；
                        // 单 log 行 → 走单行 truncate，让 log row 自然适配卡片宽度，
                        // 不再被 .fixedSize 反向撑出卡片边界（之前 [.h, .v] 路线穿透父约束的 chain）。
                        // 长 log 全内容请走下方"打开日志"在 Finder 里看。
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(LogStore.shared.logLines) { logLine in
                                    logLineView(logLine.string)
                                        .foregroundStyle(Color("TextColor"))
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 8)
                        }
                        .scrollIndicators(.never)
                        .frame(maxHeight: 240)
                        .padding(.top, 5)
                        
                        MyButton(text: "打开日志") {
                            NSWorkspace.shared.activateFileViewerSelecting([SharedConstants.shared.logURL])
                        }
                        .frame(height: 40)
                    }
                }
                .padding()
                .padding(.bottom, 20)
            }
            Spacer()
        }
        .scrollIndicators(.never)
        .onAppear {
            dataManager.leftTab(310) {
                LeftTab()
            }
        }
    }
    
    /// 日志等级标签的正则。编译一次复用 —— 原来每渲染一行日志都新建一个
    /// NSRegularExpression，日志卡最多 200 行，等于每帧编译 200 次正则。
    private static let logLevelRegex = try? NSRegularExpression(pattern: #"\[(INFO|WARN|ERROR|DEBUG)\]"#)

    @ViewBuilder
    func logLineView(_ line: String) -> some View {
        let nsLine = line as NSString
        if let match = LaunchView.logLevelRegex?
            .firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
           let levelRange = Range(match.range(at: 1), in: line),
           let tagRange = Range(match.range(at: 0), in: line)
        {
            let level = String(line[levelRange])
            let tag = String(line[tagRange])
            let rest = String(line[tagRange.upperBound...])
            let color: Color = {
                switch level {
                    case "INFO": return .green
                    case "WARN": return .yellow
                    case "ERROR": return .red
                    case "DEBUG": return .blue
                    default: return .primary
                }
            }()

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tag)
                    .font(.custom("PCL English", size: 14))
                    .foregroundColor(color)
                    .lineLimit(1)
                // 单行 + truncate：让 log row 自动适配卡片宽，不论 log 多长都不会反向撑出卡片。
                // 完整长 log 走下方"打开日志"按钮看完整文件。
                Text(rest)
                    .font(.custom("PCL English", size: 14))
                    .foregroundStyle(Color("TextColor"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack {
                Text(line)
                    .font(.custom("PCL English", size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
