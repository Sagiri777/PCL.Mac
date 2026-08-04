//
//  WindowControlButton.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/17.
//

import SwiftUI

struct WindowControlButton: View {
    static let Close: WindowControlButton = .init(
    Image(systemName: "xmark")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 13)
        .foregroundStyle(.white)
        .bold()
    ) {
        guard let window = WindowControlButton.activeWindow else { return }
        window.close()
    }
    
    static let Miniaturize: WindowControlButton = .init(
    Image(systemName: "minus")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 13)
        .foregroundStyle(.white)
        .bold()
    ) {
        guard let window = WindowControlButton.activeWindow else { return }
        window.miniaturize(nil)
    }
    
    static let Back: WindowControlButton = .init(
        Image("Back")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 18)
            .foregroundStyle(.white)
            .padding(.top, 3)
    ) {
        DataManager.shared.router.goBack()
    }
    
    let action: () -> Void
    private let content: (Bool) -> any View
    @State private var isHovered = false
    
    init(@ViewBuilder _ content: @escaping (Bool) -> some View, action: @escaping () -> Void) {
        self.content = content
        self.action = action
    }
    
    init(_ view: some View, action: @escaping () -> Void) {
        self.content = { isHovered in
            view
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(isHovered ? Color(hex: 0xFFFFFF, alpha: 0.17) : Color.clear)
                        .animation(.easeInOut(duration: 0.2), value: isHovered)
                        .frame(width: 30, height: 30)
                )
                .frame(width: 30, height: 30)
        }
        self.action = action
    }

    var body: some View {
        AnyView(content(isHovered))
            .onHover { hover in
                isHovered = hover
            }
            .onTapGesture(perform: action)
    }

    private static var activeWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
    }
}
