//
//  MyPicker.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/27.
//

import SwiftUI

struct MyPicker<Entry: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var overlayManager: OverlayManager = .shared
    @Binding private var selected: Entry
    @State private var isHovered: Bool = false
    @State private var showMenu: Bool = false
    @State private var overlayId: UUID? = nil
    @FocusState private var isFocused: Bool
    
    private let entries: [Entry]
    private let getText: (Entry) -> String
    
    init(selected: Binding<Entry>, entries: [Entry], textProvider: @escaping (Entry) -> String) {
        self._selected = selected
        self.entries = entries
        self.getText = textProvider
    }
    
    var body: some View {
        MyGeometryReader { geo in
            Button {
                toggleMenu(geometry: geo)
            } label: {
                ZStack(alignment: .leading) {
                    HStack {
                        Text(getText(selected))
                            .font(.system(size: 14))
                            .foregroundStyle(Color("TextColor"))
                            .padding(.leading, 5)
                            .lineLimit(1)
                        Spacer()
                        Image("FoldController")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .rotationEffect(.degrees(showMenu && !reduceMotion ? 180 : 0), anchor: .center)
                            .foregroundStyle(AppSettings.shared.theme.getAccentColor().opacity(isHovered ? 1.0 : 0.5))
                            .padding(.trailing, 5)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: showMenu)

                    RoundedRectangle(cornerRadius: 4)
                        .stroke(AppSettings.shared.theme.getAccentColor().opacity(isHovered ? 1.0 : 0.5), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("当前选择：\(getText(selected))")
            .accessibilityHint("按下以显示选项")
            .focused($isFocused)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: self.isHovered)
            .frame(height: 27)
            .contentShape(Rectangle())
            .onChange(of: isFocused) {
                if isFocused == false, let overlayId = overlayId {
                    overlayManager.removeOverlay(with: overlayId)
                }
            }
            .onHover { hover in
                self.isHovered = hover
            }
        }
        .onDisappear {
            if let overlayId = overlayId {
                overlayManager.removeOverlay(with: overlayId)
                self.overlayId = nil
            }
        }
    }

    private func toggleMenu(geometry: GeometryProxy?) {
        if let overlayId {
            overlayManager.removeOverlay(with: overlayId)
            self.overlayId = nil
        } else if let geometry {
            let frame = geometry.frame(in: .global)
            overlayId = overlayManager.addOverlay(
                view: PickerMenu(entries: entries, onSelect: { value in
                    selected = value
                    if let currentOverlayId = self.overlayId {
                        overlayManager.removeOverlay(with: currentOverlayId)
                        self.overlayId = nil
                    }
                }, getText: getText)
                    .frame(width: geometry.size.width)
                    .foregroundStyle(AppSettings.shared.theme.getAccentColor()),
                at: CGPoint(x: frame.minX, y: frame.maxY + 1)
            )
        }
    }
}

fileprivate struct PickerMenu<Entry: Hashable>: View {
    let entries: [Entry]
    let onSelect: (Entry) -> Void
    let getText: (Entry) -> String
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(entries, id: \.self) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        MyListItem {
                            HStack {
                                Text(getText(entry))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color("TextColor"))
                                    .padding(.leading, 5)
                                Spacer()
                            }
                            .frame(height: 27)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(getText(entry))
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color("MyCardBackgroundColor"))
                    .shadow(color: Color("TextColor").opacity(0.2), radius: 4)
            }
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.primary, lineWidth: 1.5)
            }
        }
    }
}
