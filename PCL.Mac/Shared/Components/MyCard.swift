//
//  MyCard.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/18.
//

import SwiftUI

struct BaseCardContainer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // BaseCardContainer 自身不再订阅 AppSettings；玻璃参数通过
    // 独立子 view CardBackgroundView 订阅 GlassSettings，避免拖动玻璃滑块
    // 时整棵界面（包括卡片正文）都重渲染。
    @State private var isHovered: Bool = false
    @State private var isAppeared: Bool = false

    let content: (Binding<Bool>) -> Content
    let index: Int
    let hasAnimation: Bool

    init(index: Int, hasAnimation: Bool, content: @escaping (Binding<Bool>) -> Content) {
        self.index = index
        self.hasAnimation = hasAnimation
        self.content = content
    }

    var body: some View {
        content($isHovered)
            .foregroundStyle(isHovered ? AppSettings.shared.theme.getTextStyle() : .init(Color("TextColor")))
            .padding()
            .background(CardBackgroundView(isHovered: isHovered))
            .padding(.top, -23)
            .opacity(isAppeared ? 1 : 0)
            .offset(y: isAppeared || reduceMotion ? 25 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
            .onHover { hover in
                isHovered = hover
            }
            .onAppear {
                if hasAnimation && !reduceMotion {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                            isAppeared = true
                        }
                    }
                } else {
                    isAppeared = true
                }
            }
    }
}

/// 卡片背景：液态玻璃主题优先；其次按用户"超薄材质"开关；否则使用实色卡片。
/// 独立订阅 GlassSettings/AppSettings（仅关心玻璃/超薄材质 + theme 切换），
/// 使玻璃参数变化时只有这个 view 重渲染。
private struct CardBackgroundView: View {
    @ObservedObject private var glassSettings: GlassSettings = .shared
    @ObservedObject private var appSettings: AppSettings = .shared
    let isHovered: Bool

    var body: some View {
        if let config = glassSettings.appearance.glassConfig {
            LiquidGlassBackground(
                role: .card,
                config: config,
                blurStrength: glassSettings.appearance.cardBlurStrength,
                surfaceOpacity: glassSettings.appearance.surfaceOpacity,
                tintStrength: glassSettings.appearance.tintStrength,
                highlightStrength: glassSettings.appearance.highlightStrength,
                shadowStrength: glassSettings.appearance.shadowStrength,
                interactive: glassSettings.appearance.interactiveEffects,
                shape: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(
                color: isHovered ? glassSettings.accentColor.opacity(0.35) : .clear,
                radius: 5, x: 0, y: 2
            )
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(appSettings.useUltraThinMaterial
                      ? AnyShapeStyle(.ultraThinMaterial)
                      : AnyShapeStyle(Color("MyCardBackgroundColor")))
                .shadow(
                    color: isHovered ? glassSettings.accentColor : .gray,
                    radius: 2, x: 0.5, y: 0.5
                )
        }
    }
}

fileprivate struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MyCard<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var dataManager: DataManager = .shared

    let title: String
    let index: Int
    private let content: Content
    private var hasAnimation: Bool = true
    private var onToggle: ((Bool) -> Void)? = nil
    private var id: String? = nil
    
    @State private var isUnfolded: Bool = false // 带动画
    @State private var showContent: Bool = false // 无动画
    @Binding private var unfoldBinding: Bool // 绑定
    @State private var internalContentHeight: CGFloat = .zero
    @State private var contentHeight: CGFloat = .zero
    @State private var lastClick: Date = Date()

    init(index: Int = 0, title: String, unfoldBinding: Binding<Bool> = .constant(true), @ViewBuilder content: @escaping () -> Content) {
        self.index = index
        self.title = title
        self._unfoldBinding = unfoldBinding
        self.content = content()
    }

    var body: some View {
        BaseCardContainer(index: index, hasAnimation: hasAnimation) { isHovered in
            VStack(spacing: 0) {
                Button {
                    if Date().timeIntervalSince(lastClick) < 0.2 { return }
                    lastClick = Date()
                    toggle()
                } label: {
                    HStack {
                        MaskedTextRectangle(text: title)
                        Spacer()
                        Image("FoldController")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .rotationEffect(.degrees(isUnfolded && !reduceMotion ? 180 : 0), anchor: .center)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(height: 9)
                .accessibilityLabel(title)
                .accessibilityValue(isUnfolded ? "已展开" : "已折叠")
                .accessibilityHint(isUnfolded ? "折叠此区域" : "展开此区域")

                ZStack(alignment: .top) {
                    content
                        .foregroundStyle(Color("TextColor"))
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: ContentHeightKey.self, value: proxy.size.height)
                            }
                        )
                        .opacity(showContent ? 1 : 0)
                }
                .frame(height: contentHeight, alignment: .top)
                .clipped()
                .padding(.top, showContent ? 10 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isUnfolded)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: contentHeight)
            }
            .onPreferenceChange(ContentHeightKey.self) { h in
                if h > 0 { internalContentHeight = h }
            }
        }
        .onAppear {
            loadState()
        }
        .onChange(of: unfoldBinding) {
            if unfoldBinding != isUnfolded {
                toggle()
            }
        }
    }
    
    private func toggle() {
        if !showContent {
            showContent = true
            withAnimation(reduceMotion ? nil : .linear(duration: 0.2)) {
                isUnfolded = true
                onToggle?(true)
                contentHeight = internalContentHeight
            }
            updateState(true)
        } else {
            contentHeight = min(2000, contentHeight)
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85, blendDuration: 0)) {
                isUnfolded = false
                contentHeight = 0
            }
            if reduceMotion {
                showContent = false
                onToggle?(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    showContent = false
                    onToggle?(false)
                }
            }
            updateState(false)
        }
    }
    
    func onToggle(_ callback: @escaping (Bool) -> Void) -> MyCard {
        var copy = self
        copy.onToggle = callback
        return copy
    }
    
    func cardId(_ id: String) -> MyCard {
        var copy = self
        copy.id = id
        copy.loadState()
        return copy
    }
    
    private func loadState() {
        if let id = id, let state = StateManager.shared.cardStates[id] {
            self.isUnfolded = state
            self.showContent = state
            if state {
                onToggle?(true)
                contentHeight = internalContentHeight
            }
        }
    }
    
    private func updateState(_ state: Bool) {
        unfoldBinding = state
        if let id = id {
            StateManager.shared.cardStates[id] = state
        }
    }
    
    func noAnimation() -> MyCard {
        var copy = self
        copy.hasAnimation = false
        return copy
    }
}

struct StaticMyCard<Content: View>: View {
    @ObservedObject private var dataManager: DataManager = .shared

    let index: Int
    let title: String
    let content: () -> Content
    
    private var hasAnimation: Bool = true
    
    init(index: Int = 0, title: String, content: @escaping () -> Content) {
        self.index = index
        self.title = title
        self.content = content
    }

    var body: some View {
        BaseCardContainer(index: index, hasAnimation: hasAnimation) { _ in
            VStack {
                MaskedTextRectangle(text: title)
                content()
                    .foregroundStyle(Color("TextColor"))
            }
        }
    }
    
    func noAnimation() -> StaticMyCard {
        var copy = self
        copy.hasAnimation = false
        return copy
    }
}

struct TitlelessMyCard<Content: View>: View {
    let content: () -> Content
    let index: Int
    
    private var hasAnimation: Bool = true
    
    init(index: Int = 0, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.index = index
    }

    var body: some View {
        BaseCardContainer(index: index, hasAnimation: hasAnimation) { _ in
            VStack {
                content()
                    .foregroundStyle(Color("TextColor"))
            }
        }
    }
    
    func noAnimation() -> TitlelessMyCard {
        var copy = self
        copy.hasAnimation = false
        return copy
    }
}

struct MaskedTextRectangle: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(
                            HStack {
                                Text(text)
                                    .font(.custom("PCL English", size: 14))
                                    .fixedSize()
                                Spacer()
                            }
                        )
                }
            }
            .frame(height: 14)
            Spacer()
        }
    }
}

#Preview {
    SettingsView()
        .padding()
        .background(Color(hex: 0xC7D9F0))
}
