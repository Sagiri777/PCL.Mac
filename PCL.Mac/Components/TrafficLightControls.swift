import AppKit
import OSLog
import SwiftUI

private let windowControlLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.github.pcl-communtiy.PCL-Mac",
    category: "WindowControls"
)

/// 应用内自绘交通灯。
///
/// 系统标题栏仍负责窗口生命周期与拖动，自绘层只把点击转换为当前 NSWindow 的
/// 关闭、最小化和全屏动作，因此位置与显隐不会再被 AppKit 的标题栏布局覆盖。
struct TrafficLightControls: View {
    let visibility: TrafficLightVisibility

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        if visibility != .hidden {
            ZStack {
                // 感应层不能跟随按钮一起设为完全透明，否则 SwiftUI 可能跳过 hover 命中。
                Rectangle()
                    .fill(Color.white.opacity(0.001))

                HStack(spacing: 0) {
                    TrafficLightButton(
                        kind: .close,
                        showsSymbol: isHovered
                    )
                    TrafficLightButton(
                        kind: .minimize,
                        showsSymbol: isHovered
                    )
                    TrafficLightButton(
                        kind: .fullScreen,
                        showsSymbol: isHovered
                    )
                }
                .opacity(controlsAreVisible ? 1 : 0)
                .allowsHitTesting(controlsAreVisible)
            }
            .frame(width: 68, height: 36)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: controlsAreVisible ? 0.14 : 0.10),
                value: controlsAreVisible
            )
            .accessibilityElement(children: .contain)
        }
    }

    private var controlsAreVisible: Bool {
        visibility == .always || isHovered
    }
}

/// 使用原生 NSButton 接收鼠标事件；按钮自身的 `window` 永远是实际宿主窗口，
/// 不依赖 SwiftUI 手势、keyWindow 或全局窗口数组。
private struct TrafficLightButton: NSViewRepresentable {
    let kind: TrafficLightKind
    let showsSymbol: Bool

    func makeNSView(context: Context) -> TrafficLightNSButton {
        TrafficLightNSButton(kind: kind, showsSymbol: showsSymbol)
    }

    func updateNSView(_ nsView: TrafficLightNSButton, context: Context) {
        nsView.showsSymbol = showsSymbol
    }
}

private final class TrafficLightNSButton: NSButton {
    let kind: TrafficLightKind
    var showsSymbol: Bool {
        didSet {
            guard oldValue != showsSymbol else { return }
            needsDisplay = true
        }
    }

    init(kind: TrafficLightKind, showsSymbol: Bool) {
        self.kind = kind
        self.showsSymbol = showsSymbol
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(performWindowAction)
        toolTip = kind.help
        setAccessibilityLabel(kind.help)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 20, height: 20)
    }

    /// 非活动窗口的第一次点击也应直接执行交通灯动作。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = NSRect(
            x: bounds.midX - 6,
            y: bounds.midY - 6,
            width: 12,
            height: 12
        )
        let circle = NSBezierPath(ovalIn: circleRect)
        kind.nsColor.withSystemEffect(isHighlighted ? .pressed : .none).setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.16).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()

        guard showsSymbol,
              let image = NSImage(
                systemSymbolName: kind.symbol,
                accessibilityDescription: nil
              )?.withSymbolConfiguration(
                .init(pointSize: kind.symbolSize, weight: .black)
              ) else {
            return
        }
        image.isTemplate = true
        NSColor.black.withAlphaComponent(0.52).set()
        let imageRect = NSRect(
            x: bounds.midX - image.size.width / 2,
            y: bounds.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        image.draw(in: imageRect)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    @objc private func performWindowAction() {
        guard let window else {
            windowControlLogger.error("No host window for \(self.kind.logName, privacy: .public)")
            NSSound.beep()
            return
        }
        let kind = kind
        windowControlLogger.info(
            "Native traffic light clicked: \(kind.logName, privacy: .public), window=\(window.windowNumber), active=\(NSApp.isActive), miniaturizable=\(window.isMiniaturizable), titled=\(window.styleMask.contains(.titled))"
        )

        // 离开当前 mouseUp/NSButton action 栈后再改变窗口生命周期。
        DispatchQueue.main.async {
            switch kind {
            case .close:
                window.close()
            case .minimize:
                // SwiftUI WindowGroup 可能在应用尚未激活时创建窗口。先让窗口进入
                // 正常 key-window 状态，再使用 AppKit 的显式状态 API。
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.async {
                    window.setIsMiniaturized(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let succeeded = window.isMiniaturized
                        windowControlLogger.log(
                            level: succeeded ? .info : .error,
                            "Minimize result: window=\(window.windowNumber), miniaturized=\(succeeded), visible=\(window.isVisible)"
                        )
                    }
                }
            case .fullScreen:
                if NSEvent.modifierFlags.contains(.option) {
                    window.performZoom(nil)
                } else {
                    window.toggleFullScreen(nil)
                }
            }
        }
    }
}

private enum TrafficLightKind {
    case close
    case minimize
    case fullScreen

    var nsColor: NSColor {
        switch self {
        case .close: NSColor(red: 1.00, green: 0.37, blue: 0.34, alpha: 1)
        case .minimize: NSColor(red: 1.00, green: 0.74, blue: 0.18, alpha: 1)
        case .fullScreen: NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)
        }
    }

    var symbol: String {
        switch self {
        case .close: "xmark"
        case .minimize: "minus"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .close: 6
        case .minimize: 7
        case .fullScreen: 5
        }
    }

    var help: String {
        switch self {
        case .close: "关闭窗口"
        case .minimize: "最小化窗口"
        case .fullScreen: "进入或退出全屏；按住 Option 缩放窗口"
        }
    }

    var logName: String {
        switch self {
        case .close: "close"
        case .minimize: "minimize"
        case .fullScreen: "fullScreen"
        }
    }
}
