//
//  MyButton.swift
//  PCL.Mac
//

import SwiftUI

/// MyButton 内部使用的 ButtonStyle。
///
/// 早期版本为了让按钮按下时缩放，把 .onLongPressGesture(minimumDuration: .infinity)
/// 挂在 Button 外面，让 onPressingChanged 同步一个 @State isPressed。
/// 这种写法在 SwiftUI macOS 上有副作用：LongPress gesture recognizer 会和 Button
/// 内部的 tap recognizer 抢同一个鼠标事件，导致 action 经常不被触发，
/// 表现为 “打开文件夹 / 打开日志 / 下载” 等按钮在实例页/工具箱里点击后没反应。
///
/// ButtonStyle.configuration.isPressed 由 SwiftUI 自己解析按下抬起，本身不会
/// 和 Button 抢手势，是规范写法。这里把视觉缩放放到 ButtonStyle 里，
/// 就把 .onLongPressGesture 完全去掉了。
private struct MyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct MyButton: View {
    let text: String
    var descriptionText: String? = nil
    var foregroundStyle: (any ShapeStyle)? = nil
    let action: () -> Void

    @State private var isHovered = false

    private func getForegroundStyle() -> some ShapeStyle {
        if let foregroundStyle { return AnyShapeStyle(foregroundStyle) }
        return isHovered ? AnyShapeStyle(AppSettings.shared.theme.getTextStyle()) : AnyShapeStyle(Color("TextColor"))
    }

    private func getAccentFill() -> Color {
        isHovered ? AppSettings.shared.theme.getAccentColor().opacity(0.1) : .clear
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(getForegroundStyle(), lineWidth: 1.3)
                RoundedRectangle(cornerRadius: 6)
                    .fill(getAccentFill())
                VStack {
                    Spacer()
                    Text(text)
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(getForegroundStyle())
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity)
                    if let descriptionText {
                        Text(descriptionText)
                            .font(.custom("PCL English", size: 12))
                            .foregroundStyle(Color(hex: 0x9A9A9A))
                    }
                    Spacer()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MyButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

#Preview { MyButton(text: "测试") {}.padding() }
