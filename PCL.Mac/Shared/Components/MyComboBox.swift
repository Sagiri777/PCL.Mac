//
//  MyCompoBox.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/21.
//

import SwiftUI

struct MyComboBox<Option: Hashable, Content: View>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    let content: (ForEach<[Option], Option, AnyView>) -> Content

    var body: some View {
        content(
            ForEach(options, id: \.self) { option in
                AnyView(MyComboBoxItemView(selection: $selection, value: option, text: label(option)))
            }
        )
    }
}

struct MyComboBoxItemView<Option: Hashable>: View {
    @ObservedObject private var dataManager: DataManager = .shared
    
    @Binding var selection: Option
    let value: Option
    let text: String
    
    @State private var outerLength: CGFloat = 20
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(lineWidth: 1).frame(width: outerLength)
                    if selection == value { Circle().frame(width: 10) }
                }
                .foregroundStyle(selection == value ? AppSettings.shared.theme.getTextStyle() : AnyShapeStyle(.primary))
                .frame(width: 20, height: 20)
                Text(text).font(.custom("PCL English", size: 14))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .foregroundStyle(isHovered ? AppSettings.shared.theme.getTextStyle() : AnyShapeStyle(Color("TextColor")))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func select() {
        guard selection != value else { return }
        selection = value
        withAnimation(.spring(duration: 0.15)) { outerLength = 10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { outerLength = 20 }
        }
    }
}

#Preview {
    MyComboBoxItemView(selection: .constant(1), value: 2, text: "")
        .padding()
}
