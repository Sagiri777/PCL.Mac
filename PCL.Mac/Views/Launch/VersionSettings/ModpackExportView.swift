//
//  ModpackExportView.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 PageInstanceExport.xaml(.vb) 提供的整合包导出 UI。
//  以 sheet 形式从实例设置页弹出，调用 ModpackExporter 落盘。
//

import SwiftUI
import UniformTypeIdentifiers

struct ModpackExportView: View {
    let instance: MinecraftInstance

    @State private var options: ModpackExporter.Options
    @State private var destURL: URL?
    @State private var exporting = false
    @State private var resultMessage: String?
    @State private var hasError = false
    @Environment(\.dismiss) private var dismiss

    init(instance: MinecraftInstance) {
        self.instance = instance
        let name = instance.name
        _options = State(initialValue: ModpackExporter.Options(name: name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导出整合包")
                    .font(.custom("PCL English", size: 22))
                    .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.custom("PCL English", size: 13))
            }

            StaticMyCard(title: "整合包信息") {
                VStack(alignment: .leading, spacing: 8) {
                    labeled("名称") {
                        MyTextField(text: $options.name, placeholder: "整合包名称")
                    }
                    labeled("版本号") {
                        MyTextField(text: $options.version, placeholder: "1.0.0")
                    }
                    labeled("作者") {
                        MyTextField(text: $options.author, placeholder: "(可选)")
                    }
                    labeled("整合包格式") {
                        MyPicker(selected: $options.format,
                                 entries: ModpackExporter.Format.allCases,
                                 textProvider: { $0.displayName })
                    }
                }
                .padding(8)
            }

            StaticMyCard(title: "需要包含的文件") {
                VStack(alignment: .leading, spacing: 6) {
                    toggleRow("Mod 文件夹", $options.includeMods)
                    toggleRow("Config 文件夹", $options.includeConfig)
                    toggleRow("存档", $options.includeSaves)
                    toggleRow("资源包", $options.includeResourcePacks)
                    toggleRow("光影包", $options.includeShaderPacks)
                    toggleRow("整合包配置文件（版本 JSON / Jar）", $options.includeVersionJSON)
                }
                .padding(8)
            }

            StaticMyCard(title: "导出位置") {
                HStack {
                    Text(destURL?.path ?? "未选择")
                        .font(.custom("PCL English", size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                    Spacer()
                    MyButton(text: "选择") {
                        chooseDest()
                    }
                    .frame(width: 90, height: 32)
                }
                .padding(8)
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.custom("PCL English", size: 13))
                    .foregroundStyle(hasError ? Color.red : Color(hex: 0x1F883D))
            }

            HStack {
                Spacer()
                MyButton(text: exporting ? "导出中…" : "开始导出", foregroundStyle: AppSettings.shared.theme.getTextStyle()) {
                    startExport()
                }
                .frame(width: 140, height: 40)
                .disabled(options.name.isEmpty || exporting)
                if hasError {
                    MyButton(text: "完成") { dismiss() }.frame(width: 90, height: 40)
                }
            }
        }
        .padding()
        .frame(width: 560)
        .font(.custom("PCL English", size: 14))
        .onAppear {
            if destURL == nil {
                destURL = FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Downloads")
                    .appending(path: defaultExportName())
            }
        }
    }

    // MARK: - 子组件

    @ViewBuilder
    private func labeled<L: View>(_ title: String, @ViewBuilder _ content: () -> L) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            content()
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Toggle(title, isOn: binding).toggleStyle(.checkbox)
            Spacer()
        }
    }

    // MARK: - 动作

    private func defaultExportName() -> String {
        "\(options.name.isEmpty ? instance.name : options.name).\(options.format.fileExtension)"
    }

    private func chooseDest() {
        let panel = NSSavePanel()
        panel.title = "选择整合包保存位置"
        panel.nameFieldStringValue = defaultExportName()
        let ext = options.format.fileExtension
        if ext == "mrpack" {
            panel.allowedContentTypes = [UTType(filenameExtension: "mrpack") ?? .data]
        } else {
            panel.allowedContentTypes = [.zip]
        }
        if panel.runModal() == .OK, let url = panel.url {
            destURL = url
        }
    }

    private func startExport() {
        guard let dest = destURL, !options.name.isEmpty else { return }
        exporting = true
        resultMessage = nil
        hasError = false
        Task {
            do {
                try await ModpackExporter.export(instance: instance, options: options, to: dest)
                await MainActor.run {
                    exporting = false
                    hasError = false
                    resultMessage = "导出完成：\(dest.lastPathComponent)（\(options.format.displayName)）"
                }
            } catch {
                await MainActor.run {
                    exporting = false
                    hasError = true
                    resultMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
