//
//  InstanceSettingsView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/31.
//

import SwiftUI

struct InstanceSettingsView: View {
    @State var instance: MinecraftInstance
    @State private var memoryText: String
    @State private var showExportSheet = false

    let qosOptions: [QualityOfService] = [
        .userInteractive,
        .userInitiated,
        .default,
        .utility,
        .background
    ]
    
    init(instance: MinecraftInstance) {
        self.instance = instance
        self.memoryText = String(instance.config.maxMemory)
    }
    
    var body: some View {
        ScrollView {
            StaticMyCard(title: "进程设置") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("游戏内存")
                        MyTextField(text: $memoryText, numberOnly: true)
                            .onChange(of: memoryText) {
                                if let intValue = Int(memoryText) {
                                    instance.config.maxMemory = Int32(intValue)
                                    instance.saveConfig()
                                }
                            }
                        Text("MB")
                    }
                    VStack(spacing: 2) {
                        HStack {
                            Text("进程 QoS")
                            MyPicker(selected: $instance.config.qualityOfService, entries: qosOptions, textProvider: getQualityOfServiceName(_:))
                            .onChange(of: instance.config.qualityOfService) {
                                instance.saveConfig()
                            }
                        }
                        
                        Text("​QoS 是控制进程 CPU 优先级的属性，可调整多任务下的资源分配，保障游戏进程优先运行，推荐默认。")
                            .font(.custom("PCL English", size: 12))
                            .foregroundStyle(Color(hex: 0x8C8C8C))
                            .padding(.top, 2)
                    }
                }
                .padding()
            }
            .padding()

            StaticMyCard(title: "整合包导出") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("将当前实例导出为 Modrinth / CurseForge / HMCL 整合包或纯压缩包，方便分享或在其它机器上导入。")
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                    HStack {
                        MyButton(text: "导出整合包", foregroundStyle: AppSettings.shared.theme.getTextStyle()) {
                            showExportSheet = true
                        }
                        .frame(width: 160, height: 38)
                        Spacer()
                    }
                }
                .padding()
            }
            .padding()
        }
        .font(.custom("PCL English", size: 14))
        .scrollIndicators(.never)
        .sheet(isPresented: $showExportSheet) {
            ModpackExportView(instance: instance)
        }
    }
    
    private func getQualityOfServiceName(_ qos: QualityOfService) -> String {
        switch qos {
        case .userInteractive:
            "用户交互 (最高优先级)"
        case .userInitiated:
            "用户启动 (高优先级)"
        case .utility:
            "实用工具 (低优先级)"
        case .background:
            "后台 (最低优先级)"
        case .default:
            "默认"
        @unknown default:
            "未知"
        }
    }
}
