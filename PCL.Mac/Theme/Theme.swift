//
//  Theme.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/30.
//

import SwiftUI
import SwiftyJSON

public class Theme: Codable, Hashable, Equatable {
    public static var pcl: Theme = load(id: "pcl")
    
    public let id: String
    private let accentColor: Color
    private let mainStyle: AnyShapeStyle
    private let backgroundStyle: AnyShapeStyle
    private let textStyle: AnyShapeStyle
    // macOS26 主题：可选的液态玻璃 + 毛玻璃配置。nil 表示该主题不使用玻璃风格。
    private let glass: GlassConfig?

    public func getGlassConfig() -> GlassConfig? { glass }
    
    init(
        id: String,
        accentColor: Color,
        mainStyle: any ShapeStyle, backgroundStyle: any ShapeStyle, textStyle: any ShapeStyle,
        glass: GlassConfig? = nil
    ) {
        self.id = id
        self.accentColor = accentColor
        self.mainStyle = AnyShapeStyle(mainStyle)
        self.backgroundStyle = AnyShapeStyle(backgroundStyle)
        self.textStyle = AnyShapeStyle(textStyle)
        self.glass = glass
    }
    
    /// 获取主渐变色（如标题栏）
    public func getStyle() -> AnyShapeStyle { mainStyle }
    
    /// 获取副渐变色（如背景）
    public func getBackgroundStyle() -> AnyShapeStyle { backgroundStyle }
    
    public func getBaseTextStyle() -> AnyShapeStyle { textStyle }

    /// 走 AppSettings 缓存的 text style。SwiftUI 的 AnyShapeStyle 比较是引用相等的，
    /// 直接缓存同一份引用可以让 SwiftUI 跳过下游 view 的重渲染计算。
    public func getTextStyle() -> AnyShapeStyle {
        if AppSettings.shared.customAccentColorEnabled {
            return AppSettings.shared.cachedTextStyle
        }
        return textStyle
    }

    public var baseAccentColor: Color { accentColor }

    /// 走 AppSettings 缓存的 accent color。Color 是 SwiftUI Equatable，缓存可让
    /// SwiftUI 跳过依赖此颜色的 view 重绘。
    public func getAccentColor() -> Color {
        if AppSettings.shared.customAccentColorEnabled {
            return AppSettings.shared.cachedAccentColor
        }
        return accentColor
    }
    
    public static func load(id: String) -> Theme {
        do {
            let internalURL: URL = SharedConstants.shared.applicationResourcesURL.appending(path: "\(id).json")
            let externalURL: URL = SharedConstants.shared.applicationSupportURL.appending(path: "Themes").appending(path: "\(id).json")
            
            let data = try FileHandle(forReadingFrom: FileManager.default.fileExists(atPath: internalURL.path) ? internalURL : externalURL).readToEnd()!
            let json = try JSON(data: data)
            return ThemeParser.shared.fromJSON(json)
        } catch {
            err("无法加载主题: \(error.localizedDescription)")
            return Theme(id: id, accentColor: Color(hex: 0x000000), mainStyle: Color(hex: 0x000000), backgroundStyle: Color(hex: 0x000000), textStyle: Color(hex: 0x000000))
        }
    }
    
    public required init(from decoder: any Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        let theme: Theme = .load(id: id)
        
        self.id = id
        self.accentColor = theme.accentColor
        self.mainStyle = theme.mainStyle
        self.backgroundStyle = theme.backgroundStyle
        self.textStyle = theme.textStyle
        self.glass = theme.glass
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
    
    public static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// 液态玻璃主题配置。
/// 对应 macOS 26 的 Liquid Glass / 毛玻璃透明质感。
/// `cardBlur`、`panelBlur` 与 `backgroundBlur` 可分别调整（0.0 ~ 1.0）。
public struct GlassConfig: Sendable, Hashable {
    public let enabled: Bool
    /// 卡片毛玻璃模糊强度（0.0 ~ 1.0）。
    public let cardBlur: Double
    /// 侧边栏 / 标题栏毛玻璃模糊强度（0.0 ~ 1.0）。
    public let panelBlur: Double
    /// 背景毛玻璃模糊强度（0.0 ~ 1.0）。
    public let backgroundBlur: Double
    /// 玻璃层染色（叠加在 material 上的半透明色）。nil 表示不额外染色。
    public let tintColor: Color?
    /// 玻璃边框高亮色（液态玻璃边缘高光）。nil 表示用主题强调色。
    public let borderColor: Color?

    public init(enabled: Bool, cardBlur: Double, panelBlur: Double? = nil, backgroundBlur: Double,
                tintColor: Color? = nil, borderColor: Color? = nil) {
        self.enabled = enabled
        self.cardBlur = max(0, min(1, cardBlur))
        self.panelBlur = max(0, min(1, panelBlur ?? ((cardBlur + backgroundBlur) / 2)))
        self.backgroundBlur = max(0, min(1, backgroundBlur))
        self.tintColor = tintColor
        self.borderColor = borderColor
    }
}
