//
//  HintOverlay.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/26.
//

import SwiftUI

struct HintOverlay: View {
    @ObservedObject private var hintManager: HintManager = .default
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(hintManager.hints.suffix(10)) { hint in
                HintComponent(hint: hint)
            }
        }
    }
}

fileprivate struct HintComponent: View {
    let hint: Hint

    // 用 fixed width 缓存 + GeometryReader 测一次替代原本 background 内嵌套 GeometryReader：
    // 1. onAppear 时一次性测量并保存，hasAnimatedIn 防止后续 layout 重复触发滑入动画；
    // 2. 内容变化时通过 GeometryReader.onChange 更新 width，使背景框跟随文本长度。
    @State private var offsetX: CGFloat = 0
    @State private var hasAnimatedIn: Bool = false
    @State private var width: CGFloat = 0

    var body: some View {
        HStack {
            Text(hint.text)
                .font(.custom("PCL English", size: 14))
                .foregroundStyle(Color(hex: 0xECEFF1))
                // 长 hint 走 wrap：默认 allow multiline，避免 .fixedSize 把后端观察的 HintComponent
                // 撑成横向 1000+pt 把整个 overlay 区也撑出去（参见 LaunchView 日志卡那次越界复盘）。
                // HintOverlay 之前已经用 GeometryReader.onPreferenceChange 自动跟宽。
                .lineLimit(3)
        }
        .padding(4)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: HintWidthKey.self, value: proxy.size.width)
            }
        )
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(getBackgroundColor())
                .frame(width: width + 20)
                .offset(x: -20)
        )
        .transition(
            .asymmetric(
                insertion: .identity,
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        )
        .onPreferenceChange(HintWidthKey.self) { newWidth in
            // 文本长度变化时同步更新背景框宽度。
            if abs(width - newWidth) > 0.5 { width = newWidth }
        }
        .onAppear {
            // 一次性滑入动画。后续 hint 增删不会重新触发，避免 GeometryReader 反复 layout。
            guard !hasAnimatedIn else { return }
            offsetX = -max(width, 200)
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0)) {
                    offsetX = 0
                    hasAnimatedIn = true
                }
            }
        }
        .offset(x: offsetX)
    }

    private func getBackgroundColor() -> Color {
        switch hint.type {
        case .info: Color(hex: 0x0A8EFC)
        case .finish: Color(hex: 0x1DA01D)
        case .critical: Color(hex: 0xFF2B00)
        }
    }
}

private struct HintWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
