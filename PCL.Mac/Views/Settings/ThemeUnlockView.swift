//
//  ThemeUnlockView.swift
//  PCL.Mac
//
//  兼容旧工程引用。主题现已全部开放，本页面不再提供激活码输入。
//

import SwiftUI

struct ThemeUnlockView: View {
    var body: some View {
        ContentUnavailableView(
            "所有主题均已开放",
            systemImage: "paintpalette.fill",
            description: Text("无需激活码，可直接在“设置 → 个性化”中选择任意主题。")
        )
    }
}
