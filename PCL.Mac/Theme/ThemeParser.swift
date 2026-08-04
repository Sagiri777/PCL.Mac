//
//  ThemeParser.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 8/5/25.
//

import SwiftUI
import SwiftyJSON

public class ThemeParser {
    public static let shared: ThemeParser = .init()
    /// 可用主题列表。惰性求值：它要扫两个目录并解析每个 json，
    /// 而只有个性化设置页需要它 —— 不该在启动时（AppSettings.init 触发
    /// ThemeParser.shared 那一刻）就付这笔成本。
    public private(set) lazy var themes: [ThemeInfo] = Self.scanThemes()

    /// 重新扫描主题目录。用户往 Themes 目录里放了新主题后可以调用。
    public func reloadThemes() {
        themes = Self.scanThemes()
        Theme.invalidateCache()
    }

    private static func scanThemes() -> [ThemeInfo] {
        var result: [ThemeInfo] = []
        var seenIds: Set<String> = []

        for folder in [SharedConstants.shared.applicationResourcesURL, SharedConstants.shared.applicationSupportURL.appending(path: "Themes")] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for jsonFile in files where jsonFile.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: jsonFile),
                      let json = try? JSON(data: data),
                      let id = json["id"].string,
                      seenIds.insert(id).inserted else { continue }
                result.append(.init(weight: json["__weight"].intValue, id: id, name: json["name"].stringValue))
            }
        }

        return result.sorted { $0.weight > $1.weight }
    }
    
    public func fromJSON(_ json: JSON) -> Theme {
        let id = json["id"].stringValue
        log("正在加载主题 \(id)")
        let images: [NSImage] = json["images"].arrayValue.compactMap { NSImage(data: Data(base64Encoded: $0.stringValue) ?? .init()) }
        let accentColor = parseColor(json["accentColor"])
        let mainStyle = parseStyle(json["mainStyle"], images)
        let backgroundStyle = parseStyle(json["backgroundStyle"], images)
        let textStyle = parseStyle(json["textStyle"].exists() ? json["textStyle"] : json["titleStyle"])
        let glass = parseGlass(json["glass"])

        return Theme(id: id, accentColor: accentColor, mainStyle: mainStyle, backgroundStyle: backgroundStyle, textStyle: textStyle, glass: glass)
    }

    /// 解析液态玻璃配置块（可选）。
    /// example:
    /// "glass": {
    ///   "enabled": true,
    ///   "cardBlur": 0.5,
    ///   "panelBlur": 0.4,
    ///   "backgroundBlur": 0.3,
    ///   "tintColor": "#1370F3",
    ///   "borderColor": "#1370F3"
    /// }
    public func parseGlass(_ json: JSON) -> GlassConfig? {
        guard json.exists() else { return nil }
        let enabled = json["enabled"].bool ?? true
        let cardBlur = json["cardBlur"].doubleValue
        let panelBlur = json["panelBlur"].double
        let backgroundBlur = json["backgroundBlur"].doubleValue
        let tint = json["tintColor"].string.map { parseColorString($0) }
        let border = json["borderColor"].string.map { parseColorString($0) }
        return GlassConfig(enabled: enabled, cardBlur: cardBlur, panelBlur: panelBlur, backgroundBlur: backgroundBlur,
                            tintColor: tint, borderColor: border)
    }

    /// 把 "#RRGGBB" / "#AARRGGBB" / hsl(...) 字符串直接解析为 Color，不走 JSON 节点路径。
    public func parseColorString(_ str: String) -> Color {
        if str.starts(with: "#") {
            let hexStr = String(str.dropFirst())
            if hexStr.count == 6, let rgbInt = UInt(hexStr, radix: 16) {
                return Color(hex: rgbInt)
            } else if hexStr.count == 8, let argbInt = UInt(hexStr, radix: 16) {
                let alpha = Double((argbInt >> 24) & 0xFF) / 255.0
                let rgb = argbInt & 0xFFFFFF
                return Color(hex: rgb, alpha: alpha)
            }
        } else if let match = str.wholeMatch(of: /hsl\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)/),
                  let h = Double(match.1), let s = Double(match.2), let l = Double(match.3) {
            return Color(h2: h, s2: s, l2: l)
        }
        return Color(hex: 0x000000)
    }
    
    public func parseStyle(_ json: JSON, _ images: [NSImage] = []) -> AnyShapeStyle {
        let type = json["type"].stringValue
        
        switch type {
        case "color", "":
            return AnyShapeStyle(parseColor(json))
        case "linearGradient":
            if let gradient = parseGradient(json) { return AnyShapeStyle(gradient) }
        case "imagePaint":
            if let imagePaint = parseImagePaint(json, images) { return AnyShapeStyle(imagePaint) }
        default:
            let _: Any? = nil
        }
        
        return AnyShapeStyle(Color(hex: 0x000000))
    }
    
    public func parseColor(_ json: JSON) -> Color {
        let str: String
        if json.type == .string {
            str = json.stringValue
        } else if json["darkColor"].exists() && !ColorConstants.isLight {
            str = json["darkColor"].stringValue
        } else {
            str = json["color"].stringValue
        }
        
        if str.starts(with: "#") { // RGB / ARGB 格式
            let hexStr = String(str.dropFirst())
            if hexStr.count == 6, let rgbInt = UInt(hexStr, radix: 16) { // RGB
                return Color(hex: rgbInt)
            } else if hexStr.count == 8,
                      let argbInt = UInt(hexStr, radix: 16) { // ARGB
                let alpha = Double((argbInt >> 24) & 0xFF) / 255.0
                let rgb = argbInt & 0xFFFFFF
                return Color(hex: rgb, alpha: alpha)
            }
        } else if let match = str.wholeMatch(of: /hsl\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)/),
                  let h = Double(match.1), let s = Double(match.2), let l = Double(match.3) {
            return Color(h2: h, s2: s, l2: l)
        }
        return Color(hex: 0x000000)
    }
    
    /// 解析渐变
    public func parseGradient(_ json: JSON) -> AnyShapeStyle? {
        if json["type"].stringValue == "linearGradient" {
            guard let startPointArray = json["startPoint"].array,
                  let endPointArray = json["endPoint"].array,
                  let colorsArray = json["colors"].array,
                  startPointArray.count >= 2,
                  endPointArray.count >= 2,
                  !colorsArray.isEmpty else {
                return nil
            }
            
            let startPoint = UnitPoint(x: startPointArray[0].doubleValue, y: startPointArray[1].doubleValue)
            let endPoint = UnitPoint(x: endPointArray[0].doubleValue, y: endPointArray[1].doubleValue)
            
            if colorsArray.allSatisfy({ $0.type == .string }) { // 不带 location 的均匀分布 color
                return AnyShapeStyle(
                    LinearGradient(
                        gradient: Gradient(colors: colorsArray.map(parseColor(_:))),
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                )
            } else if colorsArray.allSatisfy({ $0.type == .dictionary }) { // 带 location 的 Stop
                let stops = colorsArray.compactMap { stop -> Gradient.Stop? in
                    guard let location = stop["location"].double else { return nil }
                    return Gradient.Stop(color: parseColor(stop), location: location)
                }
                guard stops.count == colorsArray.count, !stops.isEmpty else {
                    return nil
                }
                return AnyShapeStyle(
                    LinearGradient(
                        gradient: Gradient(stops: stops),
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                )
            }
        }
        
        return nil
    }
    
    /// 解析图片
    public func parseImagePaint(_ json: JSON, _ images: [NSImage]) -> ImagePaint? {
        let imageIndex = json["image"].intValue
        if imageIndex >= images.count || imageIndex < 0 { return nil }
        return ImagePaint(image: Image(nsImage: images[imageIndex]), scale: 0.5)
    }
    
    private init() {}
}

public struct ThemeInfo: Identifiable, Hashable {
    fileprivate let weight: Int
    public let id: String
    public let name: String
    
    init(weight: Int = 0, id: String, name: String) {
        self.weight = weight
        self.id = id
        self.name = name
    }
}
