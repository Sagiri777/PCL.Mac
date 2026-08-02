//
//  MySearchBox.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/29.
//

import SwiftUI

struct MySearchBox: View {
    @Binding private var query: String
    @FocusState private var isFocused: Bool
    @State private var isClearHovered: Bool = false
    private let placeholder: String
    private let onSubmit: (String) -> Void
    /// 是否出现时自动获得焦点。搜索页进来直接能打字。
    private let autoFocus: Bool

    init(query: Binding<String>, placeholder: String, autoFocus: Bool = false, onSubmit: @escaping (String) -> Void) {
        self._query = query
        self.placeholder = placeholder
        self.autoFocus = autoFocus
        self.onSubmit = onSubmit
    }

    var body: some View {
        TitlelessMyCard {
            HStack {
                Image("SearchIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16)
                    .foregroundStyle(isFocused
                                     ? AnyShapeStyle(AppSettings.shared.theme.getTextStyle())
                                     : AnyShapeStyle(Color(hex: 0x8C8C8C)))
                TextField(text: $query) {
                    Text(placeholder)
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                }
                .focused($isFocused)
                .font(.custom("PCL English", size: 16))
                .textFieldStyle(.plain)
                .onChange(of: query) {
                    if query.count > 50 {
                        query = String(query.prefix(50))
                    }
                }
                .onSubmit {
                    isFocused = false
                    onSubmit(query)
                }
                // Esc 清空并退出编辑，符合 macOS 搜索框的常规行为。
                .onExitCommand {
                    if query.isEmpty {
                        isFocused = false
                    } else {
                        clear()
                    }
                }
                Spacer()
                if !query.isEmpty {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color(hex: 0x8C8C8C).opacity(isClearHovered ? 1 : 0.65))
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("清空（Esc）")
                    .accessibilityLabel("清空搜索")
                    .onHover { isClearHovered = $0 }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .frame(height: 40)
        .padding(.bottom, -7)
        // 让 ⌘F 把焦点移到搜索框。
        .background {
            Button("") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            guard autoFocus else { return }
            // 直接在 onAppear 里设焦点会被随后的布局吞掉，推一帧。
            DispatchQueue.main.async { isFocused = true }
        }
    }

    private func clear() {
        query.removeAll()
        onSubmit(query)
    }
}

#Preview {
    MySearchBox(query: .constant("a"), placeholder: "搜索 Mod 在输入框中按下 Enter 以进行搜索") { query in
        print(query)
    }
    .padding()
}
