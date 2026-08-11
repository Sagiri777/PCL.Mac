//
//  JavaEntityComponent.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/19.
//

import SwiftUI

struct JavaListItemView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var dataManager: DataManager = .shared
    
    let jvm: JavaVirtualMachine
    private var instance: MinecraftInstance? = nil
    private var javaPath: URL? {
        guard let directory = AppSettings.shared.currentMinecraftDirectory,
              let defaultInstance = AppSettings.shared.defaultInstance,
              let instance = MinecraftInstance.create(directory, directory.versionsURL.appending(path: defaultInstance)) else {
            return nil
        }
        
        return instance.config.javaURL
    }
    
    init(jvm: JavaVirtualMachine) {
        self.jvm = jvm
        guard let directory = AppSettings.shared.currentMinecraftDirectory,
              let defaultInstance = AppSettings.shared.defaultInstance,
              let instance = MinecraftInstance.create(directory, directory.versionsURL.appending(path: defaultInstance)) else {
            return
        }
        self.instance = instance
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: selectJava) {
                MyListItem(isSelected: javaPath == jvm.executableURL) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(jvm.getTypeLabel()) \(jvm.displayVersion)")
                                .font(.system(size: 16))
                                .padding(.leading, 2)
                            HStack {
                                if let implementor = jvm.implementor {
                                    MyTag(label: implementor, backgroundColor: Color("TagColor"), fontSize: 12)
                                }
                                MyTag(label: String(describing: jvm.arch), backgroundColor: Color("TagColor"), fontSize: 12)
                                MyTag(label: jvm.callMethod.getDisplayName(), backgroundColor: Color("TagColor"), fontSize: 12)
                            }
                            .foregroundStyle(Color(hex: 0x8C8C8C))
                            Text(jvm.executableURL.path)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Color(hex: 0x8C8C8C))
                        }
                        Spacer()
                        if jvm.isAddedByUser { Color.clear.frame(width: 38) }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "使用 Java \(jvm.getTypeLabel()) \(jvm.displayVersion)，\(jvm.arch)"))

            if jvm.isAddedByUser {
                Button {
                    AppSettings.shared.userAddedJvmPaths.removeAll { $0 == jvm.executableURL }
                    Task { await JavaSearch.searchAndSet() }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("移除这个手动添加的 Java")
                .accessibilityLabel("移除 Java \(jvm.displayVersion)")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: javaPath)
    }

    private func selectJava() {
        instance?.config.javaURL = jvm.executableURL
        instance?.saveConfig()
        dataManager.objectWillChange.send()
    }
}


#Preview {
    SettingsView()
}
