//
//  PersonalizationView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/21.
//

import SwiftUI

struct PersonalizationView: View {
    @ObservedObject private var settings: AppSettings = .shared
    @State private var selectedTheme: ThemeInfo = .init(id: "pcl", name: "PCL")
    @State private var themes: [ThemeInfo] = []
    @State private var visualRefreshTask: Task<Void, Never>?
    
    var body: some View {
        ScrollView {
            StaticMyCard(title: "基础") {
                VStack(spacing: 15) {
                    ZStack(alignment: .topLeading) {
                        Spacer()
                        MyComboBox(
                            options: themes,
                            selection: $selectedTheme,
                            label: { $0.name }) { content in
                                HStack(spacing: 120) {
                                    content
                                }
                            }
                            .onChange(of: selectedTheme) {
                                settings.themeId = selectedTheme.id
                            }
                            .padding()
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(settings.theme.getAccentColor(), style: .init(lineWidth: 1))
                    }
                    
                    OptionStack("自定义主题色") {
                        HStack(spacing: 12) {
                            Toggle("", isOn: $settings.customAccentColorEnabled)
                                .onChange(of: settings.customAccentColorEnabled) { settings.refreshThemeAppearance() }
                            ColorPicker("", selection: customAccentBinding, supportsOpacity: false)
                                .labelsHidden()
                                .disabled(!settings.customAccentColorEnabled)
                            Button("恢复主题默认") {
                                settings.customAccentColorEnabled = false
                                settings.refreshThemeAppearance()
                            }
                        }
                    }

                    OptionStack("配色方案") {
                        MyComboBox(
                            options: [ColorSchemeOption.light, ColorSchemeOption.dark, ColorSchemeOption.system],
                            selection: $settings.colorScheme,
                            label: { $0.getLabel() }
                        ) { content in
                            HStack(spacing: 40) {
                                content
                            }
                        }
                        .onChange(of: settings.colorScheme) {
                            settings.updateColorScheme()
                        }
                    }
                }
                .padding()
            }
            .padding()
            
            StaticMyCard(index: 1, title: "其它") {
                VStack {
                    OptionStack(settings.glassEnabled ? "交通灯样式" : "窗口按钮样式") {
                        MyComboBox(
                            options: [WindowControlButtonStyle.pcl, WindowControlButtonStyle.macOS],
                            selection: windowConfig($settings.windowControlButtonStyle),
                            label: { $0.getLabel() }
                        ) { content in
                            HStack(spacing: 120) {
                                content
                            }
                        }
                    }
                    .padding()
                    if settings.glassEnabled {
                        Text(settings.windowControlButtonStyle == .macOS
                             ? "macOS 样式：使用应用内交通灯，位置与呼出模式可即时调整。"
                             : "PCL 样式：隐藏系统交通灯，使用右上角自绘窗口按钮。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    OptionStack("超薄材质") {
                        Toggle("", isOn: $settings.useUltraThinMaterial)
                            .disabled(settings.glassEnabled)
                    }
                    .padding()

                    if settings.glassEnabled {
                        Divider().padding(.horizontal)
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Label("MacOS26 液态玻璃", systemImage: "circle.hexagongrid.fill")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("窗口框架与玻璃表面实时预览")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            GlassSettingsSection(title: "区域模糊", systemImage: "drop.halffull") {
                                GlassValueSlider(title: "整体背景", value: visual($settings.glassBackgroundBlurStrength), range: 0...1, step: 0.05, format: .percent)
                                GlassValueSlider(title: "侧栏与面板", value: visual($settings.glassPanelBlurStrength), range: 0...1, step: 0.05, format: .percent)
                                GlassValueSlider(title: "内容卡片", value: visual($settings.glassCardBlurStrength), range: 0...1, step: 0.05, format: .percent)
                            }

                            GlassSettingsSection(title: "磨砂玻璃窗框", systemImage: "macwindow") {
                                GlassValueSlider(title: "窗框宽度", value: windowConfig($settings.glassFrameWidth), range: 6...28, step: 1, format: .points)
                                GlassValueSlider(title: "窗框磨砂", value: visual($settings.glassFrameBlurStrength), range: 0...1, step: 0.05, format: .percent)
                                GlassValueSlider(title: "外框圆角", value: visual($settings.glassCornerRadius), range: 12...36, step: 1, format: .points)
                                GlassValueSlider(title: "内侧描边圆角", value: visual($settings.glassInnerBorderCornerRadius), range: 0...32, step: 1, format: .points)
                                GlassValueSlider(title: "右侧背景圆角", value: visual($settings.glassContentCornerRadius), range: 4...32, step: 1, format: .points)
                            }

                            if settings.windowControlButtonStyle == .macOS {
                                GlassSettingsSection(title: "交通灯", systemImage: "lightspectrum.horizontal") {
                                    OptionStack("显示位置") {
                                        MyComboBox(options: TrafficLightPosition.allCases, selection: windowConfig($settings.trafficLightPosition), label: { $0.getLabel() }) { $0 }
                                    }
                                    OptionStack("显示模式") {
                                        MyComboBox(options: TrafficLightVisibility.allCases, selection: windowConfig($settings.trafficLightVisibility), label: { $0.getLabel() }) { $0 }
                                    }
                                }
                            }

                            GlassSettingsSection(title: "玻璃外观", systemImage: "slider.horizontal.3") {
                                GlassValueSlider(title: "表面不透明度", value: visual($settings.glassSurfaceOpacity), range: 0.15...1, step: 0.05, format: .percent)
                                GlassValueSlider(title: "主题染色", value: visual($settings.glassTintStrength), range: 0...1, step: 0.05, format: .percent)
                                GlassValueSlider(title: "边缘高光", value: visual($settings.glassHighlightStrength), range: 0...1, step: 0.05, format: .percent)
                                GlassValueSlider(title: "投影强度", value: visual($settings.glassShadowStrength), range: 0...1, step: 0.05, format: .percent)
                                Toggle("启用交互式液态玻璃", isOn: visual($settings.glassInteractiveEffects))
                                    .toggleStyle(.switch)
                            }

                            HStack {
                                Text("窗框会透出桌面和后方窗口；降低不透明度可增强透视感。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("恢复推荐值", action: resetGlassSettings)
                            }
                        }
                        .padding()
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.never)
        .font(.custom("PCL English", size: 14))
        .foregroundStyle(.text)
        .onAppear {
            self.themes = ThemeParser.shared.themes
            self.selectedTheme = ThemeParser.shared.themes.find { $0.id == settings.themeId } ?? selectedTheme
        }
    }

    private func visual<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                scheduleVisualRefresh()
            }
        )
    }

    private func scheduleVisualRefresh(updateThemeStyle: Bool = false) {
        visualRefreshTask?.cancel()
        visualRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            if updateThemeStyle {
                settings.refreshThemeAppearance()
            } else {
                settings.refreshVisuals()
            }
        }
    }

    private func windowConfig<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                settings.refreshWindowConfiguration()
            }
        )
    }

    private var customAccentBinding: Binding<Color> {
        Binding(
            get: {
                Color(.sRGB, red: settings.customAccentRed, green: settings.customAccentGreen, blue: settings.customAccentBlue)
            },
            set: { color in
                if let components = NSColor(color).usingColorSpace(.sRGB) {
                    settings.customAccentRed = Double(components.redComponent)
                    settings.customAccentGreen = Double(components.greenComponent)
                    settings.customAccentBlue = Double(components.blueComponent)
                    settings.customAccentColorEnabled = true
                    scheduleVisualRefresh(updateThemeStyle: true)
                }
            }
        )
    }

    private func resetGlassSettings() {
        settings.glassBackgroundBlurStrength = 1
        settings.glassPanelBlurStrength = 1
        settings.glassCardBlurStrength = 1
        settings.glassFrameWidth = 14
        settings.glassFrameBlurStrength = 0.78
        settings.glassSurfaceOpacity = 0.70
        settings.glassTintStrength = 0.22
        settings.glassHighlightStrength = 0.62
        settings.glassShadowStrength = 0.55
        settings.glassCornerRadius = 22
        settings.glassInnerBorderCornerRadius = 10
        settings.glassContentCornerRadius = 14
        settings.trafficLightPosition = .topLeft
        settings.trafficLightVisibility = .always
        settings.glassInteractiveEffects = true
        settings.refreshVisuals()
        settings.refreshWindowConfiguration()
    }
}


private struct GlassSettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(spacing: 10) { content() }
                .padding(.top, 4)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
        }
    }
}

private enum GlassValueFormat { case percent, points }

private struct GlassValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: GlassValueFormat

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 105, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(valueText)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var valueText: String {
        switch format {
        case .percent: "\(Int((value * 100).rounded()))%"
        case .points: "\(Int(value.rounded())) pt"
        }
    }
}

struct OptionStack<Content: View>: View {
    private let label: String
    private let content: () -> Content
    
    init(_ label: String, @ViewBuilder _ content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }
    
    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.custom("PCL English", size: 14))
                .foregroundStyle(Color("TextColor"))
                .frame(width: 120, alignment: .leading)
            
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
