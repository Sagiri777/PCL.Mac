//
//  MyList.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/19.
//

import SwiftUI

struct MyList<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var router = DataManager.shared.router
    
    let content: (AppRoute, Bool) -> Content
    @Binding var cases: [AppRoute]
    let animationIndex: Int
    let height: CGFloat
    @State private var hovering: AppRoute? = nil
    @State private var appeared: Set<AppRoute> = []
    
    /// 停在容器根路由时要自动进入的默认子页面。
    ///
    /// 不在 init 里直接改 router：在 View 初始化过程中发布状态变更会额外触发一轮
    /// 渲染，也容易引出 "Modifying state during view update"。改为记下来，
    /// 等 onAppear 再跳。
    private let root: AppRoute?

    init(root: AppRoute? = nil, cases: Binding<[AppRoute]>, animationIndex: Int = 0, height: CGFloat = 32, @ViewBuilder content: @escaping (AppRoute, Bool) -> Content) {
        self._cases = cases
        self.content = content
        self.animationIndex = animationIndex
        self.height = height
        self.root = root
    }

    var body: some View {
        // 用 ScrollView + LazyVStack 替代 VStack：长 sidebar 嵌套时只渲染可见项，
        // 避免一次性实例化所有 RouteView（每个都订阅 DataManager）。
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(cases.indices, id: \.self) { index in
                    let item = cases[index]
                    RouteView(content: content, item: item, height: height)
                        .offset(x: reduceMotion || appeared.contains(item) ? 0 : -DataManager.shared.leftTabWidth / 2)
                        .opacity(reduceMotion || appeared.contains(item) ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.65)
                                .delay(Double(index + animationIndex) * 0.038),
                            value: appeared.contains(item)
                        )
                        .onAppear {
                            // 入场动画用 .delay 修饰器排队，不再为每一行派发一个
                            // asyncAfter（那些 block 在快速切页时会堆积并互相打断）。
                            _ = appeared.insert(item)
                        }
                }
            }
        }
        .onAppear(perform: enterDefaultRouteIfNeeded)
    }

    /// 如果当前正停在容器根路由上，进入列表里的第一项。
    private func enterDefaultRouteIfNeeded() {
        guard let root, let first = cases.first else { return }
        guard router.getLast() == root else { return }
        router.append(first)
    }
}

fileprivate struct RouteView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var router = DataManager.shared.router
    
    @State private var isHovered: Bool = false
    @State private var indicatorHeight: CGFloat
    
    let content: (AppRoute, Bool) -> Content
    let item: AppRoute
    let height: CGFloat
    
    init(content: @escaping (AppRoute, Bool) -> Content, item: AppRoute, height: CGFloat) {
        self.content = content
        self.item = item
        self.height = height
        self.indicatorHeight = height - 8
    }
    
    var body: some View {
        Button(action: selectRoute) {
            HStack {
                Group {
                    if router.getLast().isSame(item) {
                        RoundedRectangle(cornerRadius: 5)
                            .foregroundStyle(AnyShapeStyle(AppSettings.shared.theme.getTextStyle()))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 4, height: indicatorHeight)

                content(item, router.getLast().isSame(item))
                    .frame(height: height)
                    .padding(.leading, 5)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: router.getLast())
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .background(isHovered ? AppSettings.shared.theme.getAccentColor().opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func selectRoute() {
        if router.getLast().isSame(item) { return }
        router.removeLast()
        router.append(item)
        indicatorHeight = 10
        withAnimation(reduceMotion ? nil : .spring(duration: 0.2)) {
            indicatorHeight = height - 8
        }
    }
}
