//
//  LocalStorage.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/19.
//

import SwiftUI

public enum ColorSchemeOption: Codable {
    case light, dark, system
    func getLabel() -> String {
        switch self {
        case .light:
            "浅色模式"
        case .dark:
            "深色模式"
        case .system:
            "跟随系统"
        }
    }
}

public enum WindowControlButtonStyle: Codable {
    case pcl, macOS
    func getLabel() -> String {
        switch self {
        case .pcl:
            "PCL"
        case .macOS:
            "macOS"
        }
    }
}

public enum TrafficLightPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight
    public var id: String { rawValue }
    func getLabel() -> String { self == .topLeft ? "顶部左侧" : "顶部右侧" }
}

public enum TrafficLightVisibility: String, Codable, CaseIterable, Identifiable {
    case always, hover, hidden
    public var id: String { rawValue }
    func getLabel() -> String {
        switch self {
        case .always: "常态显示"
        case .hover: "鼠标靠近时呼出"
        case .hidden: "始终隐藏"
        }
    }
}

public enum DownloadSourceOption: Codable {
    case official, mirror, both
}

public class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    /// AppStorage 不会自动向本 ObservableObject 发布；所有需要立即重绘/重配窗口的设置通过此版本号统一广播。
    @Published public private(set) var appearanceRevision: UInt = 0
    
    /// 是否显示首次启动介绍。
    @AppStorage("showPclMacPopup") public var showPclMacPopup: Bool = true

    /// 首页与调试信息显示设置。
    @AppStorage("showAnnouncements") public var showAnnouncements: Bool = true
    @AppStorage("useCustomAnnouncementSource") public var useCustomAnnouncementSource: Bool = false
    @AppStorage("customAnnouncementSource") public var customAnnouncementSource: String = ""
    @AppStorage("showDevelopmentWarning") public var showDevelopmentWarning: Bool = true
    @AppStorage("showDevelopmentLogs") public var showDevelopmentLogs: Bool = false
    @AppStorage("showCurrentRoute") public var showCurrentRoute: Bool = false
    
    /// 用户添加的 Java 路径
    @CodableAppStorage("userAddedJvmPaths") public var userAddedJvmPaths: [URL] = []
    
    @Published public var theme: Theme!
    
    /// 主题 ID (文件名)
    @CodableAppStorage("themeId") public var themeId: String = "pcl" {
        didSet {
            if themeId != self.theme?.id {
                self.theme = .load(id: themeId)
                DataManager.shared.objectWillChange.send()
                refreshDerivedStyles()
                GlassSettings.shared.reloadThemeDerived()
            }
        }
    }
    
    /// 启动时若为空自动设置为第一个版本
    @AppStorage("defaultInstance") public var defaultInstance: String?
    
    /// 配色方案
    @CodableAppStorage("colorScheme") public var colorScheme: ColorSchemeOption = .light
    
    /// 最后一次获取到的 VersionManifest，断网时使用
    @CodableAppStorage("lastVersionManifest") public var lastVersionManifest: VersionManifest? = nil
    
    /// 当前 MinecraftDirectory
    @CodableAppStorage("currentMinecraftDirectory") public var currentMinecraftDirectory: MinecraftDirectory? = .default
    
    /// 所有 MinecraftDirectory
    @CodableAppStorage("minecraftDirectories") public var minecraftDirectories: [MinecraftDirectory] = [.default]
    
    /// 窗口按钮样式
    @CodableAppStorage("windowControlButtonStyle") public var windowControlButtonStyle: WindowControlButtonStyle = .pcl
    
    /// 是否登录过一次微软账号
    @AppStorage("hasMicrosoftAccount") public var hasMicrosoftAccount: Bool = false
    
    /// 累计启动次数
    @AppStorage("launchCount") public var launchCount: Int = 0
    
    /// 启动器是否全屏
    @AppStorage("fullScreen") public var fullScreen: Bool = false
    
    /// 下载自定义文件时的保存 URL
    @AppStorage("customFilesSaveURL") public var customFilesSaveURL: URL = URL(fileURLWithUserPath: "~/Downloads")
    
    /// 是否启用超薄材质
    @CodableAppStorage("useUltraThinMaterial") public var useUltraThinMaterial: Bool = false
    
    /// MacOS26 液态玻璃各区域的模糊倍率（0.0 ~ 1.0）。1.0 = 使用主题预设。
    @AppStorage("glassBackgroundBlurStrength") public var glassBackgroundBlurStrength: Double = 1.0
    @AppStorage("glassPanelBlurStrength") public var glassPanelBlurStrength: Double = 1.0
    @AppStorage("glassCardBlurStrength") public var glassCardBlurStrength: Double = 1.0

    /// MacOS26 窗框与表面细节。数值设置为倍率/强度，方便实时预览并持久化。
    @AppStorage("glassFrameWidth") public var glassFrameWidth: Double = 14.0
    @AppStorage("glassFrameBlurStrength") public var glassFrameBlurStrength: Double = 0.78
    @AppStorage("glassSurfaceOpacity") public var glassSurfaceOpacity: Double = 0.70
    @AppStorage("glassTintStrength") public var glassTintStrength: Double = 0.22
    @AppStorage("glassHighlightStrength") public var glassHighlightStrength: Double = 0.62
    @AppStorage("glassShadowStrength") public var glassShadowStrength: Double = 0.55
    @AppStorage("glassCornerRadius") public var glassCornerRadius: Double = 22.0
    /// 磨砂窗框内侧描边线围成矩形的圆角。
    @AppStorage("glassInnerCornerRadius") public var glassInnerBorderCornerRadius: Double = 10.0
    /// 右侧内容背景自身的圆角。
    @AppStorage("glassContentCornerRadius") public var glassContentCornerRadius: Double = 14.0
    @AppStorage("glassInteractiveEffects") public var glassInteractiveEffects: Bool = true

    /// 自定义主题色与 MacOS26 交通灯。
    @AppStorage("customAccentColorEnabled") public var customAccentColorEnabled: Bool = false
    @AppStorage("customAccentRed") public var customAccentRed: Double = 0.039
    @AppStorage("customAccentGreen") public var customAccentGreen: Double = 0.518
    @AppStorage("customAccentBlue") public var customAccentBlue: Double = 1.0
    @CodableAppStorage("trafficLightPosition") public var trafficLightPosition: TrafficLightPosition = .topLeft
    @CodableAppStorage("trafficLightVisibility") public var trafficLightVisibility: TrafficLightVisibility = .always

    /// 走 cachedAccentColor，避免每次调用都构造新 Color 实例。
    /// cachedAccentColor 在 customAccentXxx/theme 变化时刷新。
    public var effectiveAccentColor: Color { cachedAccentColor }

    /// 让自定义颜色不仅覆盖 accentColor，也覆盖旧主题用作选中态的 textStyle。
    public var effectiveThemeStyle: AnyShapeStyle {
        customAccentColorEnabled ? AnyShapeStyle(effectiveAccentColor) : (theme?.getBaseTextStyle() ?? AnyShapeStyle(effectiveAccentColor))
    }

    /// 缓存的派生 text style：调用 Theme.getTextStyle() 的 view 大量复用，
    /// 缓存为同一份 AnyShapeStyle 避免每次 body 重新分配 + 让 SwiftUI 看到相同的引用。
    @Published public private(set) var cachedTextStyle: AnyShapeStyle = AnyShapeStyle(Color("TextColor"))

    /// 缓存的派生 accent color：同上，避免重复 Color 构造。
    @Published public private(set) var cachedAccentColor: Color = .accentColor

    /// 主题/自定义颜色变化时刷新缓存值。仅刷新本 ObservableObject 的派生字段；
    /// 玻璃参数仍走 GlassSettings.shared。
    /// AnyShapeStyle 不可比较，因此本方法不查重，调用方按需调用（避免在快速连续事件中频繁 publish）。
    public func refreshDerivedStyles() {
        if customAccentColorEnabled {
            let c = Color(.sRGB, red: customAccentRed, green: customAccentGreen, blue: customAccentBlue)
            cachedTextStyle = AnyShapeStyle(c)
            cachedAccentColor = c
        } else if let theme = theme {
            cachedTextStyle = theme.getBaseTextStyle()
            cachedAccentColor = theme.baseAccentColor
        }
    }

    /// 仅发布 SwiftUI 外观变化，不重建页面。
    /// 现在改为只刷新 GlassSettings 子集，避免拖动玻璃滑块时全应用重渲染。
    /// 同时刷新 GlassSettings 缓存的派生 accentColor（自定义主题色变化时）。
    public func refreshVisuals() {
        GlassSettings.shared.reloadThemeDerived()
    }

    /// 主题色或主题本身发生变化时，同时更新正文选中态样式和 Glass 派生色。
    /// 玻璃滑块只调用 refreshVisuals，避免拖动时触发整棵页面重算。
    public func refreshThemeAppearance() {
        refreshDerivedStyles()
        GlassSettings.shared.reloadThemeDerived()
    }

    /// 仅发布窗口配置变化。避免同时再发一次 objectWillChange，造成整棵界面重复计算。
    public func refreshWindowConfiguration() {
        appearanceRevision &+= 1
    }

    /// 文件下载源
    @CodableAppStorage("fileDownloadSource") public var fileDownloadSource: DownloadSourceOption = .both
    
    /// 版本列表源
    @CodableAppStorage("versionManifestSource") public var versionManifestSource: DownloadSourceOption = .both

    /// 无障碍辅助：仅在 CurseForge 官方网页队列中，让嵌入式浏览器自动打开已验证文件的官方下载页。
    /// 默认关闭，下载结果仍会经过 SHA-1 校验后才写入实例。
    @AppStorage("accessibilityBrowserAutomationDownloadEnabled") public var accessibilityBrowserAutomationDownloadEnabled: Bool = false

    /// 头像源 fallback 列表（按优先级排序）。
    /// 占位符：`{uuid}` = 去掉短横线的小写 UUID，`{username}` = 账号 username。
    /// 支持两种响应：
    /// - Minecraft skin texture (32x32 / 64x64)：裁剪头部显示
    /// - 预渲染头像 (任意正方形 >=16)：整图直接显示
    /// - JSON (uapis.cn 类型)：解析 `skin_url` 后再请求 PNG
    @CodableAppStorage("avatarSources") public var avatarSources: [String] = [
        "https://uapis.cn/api/v1/game/minecraft/userinfo?username={username}",
        "https://mc-heads.net/avatar/{uuid}",
        "https://minotar.net/helm/{uuid}",
        "https://crafatar.com/skins/{uuid}"
    ]

    /// 头像缓存 TTL（天）。超过此天数后下次刷新头像会重新拉取。
    @AppStorage("avatarCacheDays") public var avatarCacheDays: Int = 7

    /// HTTP/HTTPS 代理总开关 + 主机/端口
    @AppStorage("proxyEnabled") public var proxyEnabled: Bool = false
    @AppStorage("proxyHost") public var proxyHost: String = ""
    @AppStorage("proxyPort") public var proxyPort: Int = 0

    // MARK: 代理覆盖范围（每个请求类别独立开关）
    /// 头像/CDN 请求（mc-heads/crafatar/textures.minecraft.net/uapis.cn）
    @AppStorage("proxyForAvatar") public var proxyForAvatar: Bool = true
    /// 微软 OAuth 登录（login.live.com / login.microsoftonline.com）
    @AppStorage("proxyForMicrosoftLogin") public var proxyForMicrosoftLogin: Bool = true
    /// 微软 Minecraft 服务（user.auth.xboxlive.com / xsts.auth.xboxlive.com / api.minecraftservices.com）
    @AppStorage("proxyForMinecraftAPI") public var proxyForMinecraftAPI: Bool = true
    /// 游戏下载 / 版本列表 / mod 搜索
    @AppStorage("proxyForGameDownload") public var proxyForGameDownload: Bool = false
    /// 公告（自定义公告源 / PCL 服务器配置）
    @AppStorage("proxyForAnnouncement") public var proxyForAnnouncement: Bool = false
    /// 其他（默认兜底）
    @AppStorage("proxyForOther") public var proxyForOther: Bool = false
    
    public func updateColorScheme() {
        if colorScheme != .system {
            NSApp.appearance = colorScheme == .light ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
        } else {
            NSApp.appearance = nil
        }
        ColorConstants.colorScheme = colorScheme
        self.theme = .load(id: themeId)
        DataManager.shared.objectWillChange.send()
        refreshDerivedStyles()
        GlassSettings.shared.reloadThemeDerived()
    }
    
    private init() {
        // ⚠️ 不要在 init 里触发 GlassSettings.shared —— 那会形成 dispatch_once 递归锁，
        // 启动时会被 libdispatch SIGTRAP 杀掉。先把自身的基础同步做完，
        // 由 AppDelegate.applicationWillFinishLaunching 在 _ = AppSettings.shared 之后
        // 显式调用 GlassSettings.shared.reloadThemeDerived() 来补玻璃参数。
        if colorScheme != .system {
            NSApp.appearance = colorScheme == .light ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
        } else {
            NSApp.appearance = nil
        }
        ColorConstants.colorScheme = colorScheme
        self.theme = .load(id: themeId)
        DataManager.shared.objectWillChange.send()
        
        if currentMinecraftDirectory == nil {
            currentMinecraftDirectory = .default
        }
        
        if let directory = currentMinecraftDirectory {
            if !minecraftDirectories.contains(where: { $0.rootURL == directory.rootURL }) {
                minecraftDirectories.append(directory)
            }
            
            if defaultInstance == nil {
                directory.loadInnerInstances { instances in
                    self.defaultInstance = instances.first?.name
                }
            }
        }
        log("已加载启动器设置")
        refreshDerivedStyles()
    }
    
    public func removeDirectory(url: URL) {
        if currentMinecraftDirectory?.rootURL == url || currentMinecraftDirectory == nil {
            currentMinecraftDirectory = .default
            if case .versionList = DataManager.shared.router.getLast() {
                DataManager.shared.router.removeLast()
                DataManager.shared.router.append(.versionList(directory: .default))
            }
        }
        minecraftDirectories.removeAll(where: { $0.rootURL == url })
        
        if minecraftDirectories.isEmpty {
            minecraftDirectories.append(currentMinecraftDirectory ?? .default)
        }
        
        DataManager.shared.objectWillChange.send()
    }
}
