//
//  LaunchPrecheck.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/20.
//

import Foundation
import AppKit

public enum JavaCheckError: Error {
    case javaNotFound
    case noUsableJava(minVersion: Int)
    case javaNotSupport
    case invalidMemoryConfiguration
    case rosetta
}

public enum AccountCheckError: Error {
    case missingAccount
    case noMicrosoftAccount
}

public class LaunchPrecheck {
    public static func checkJava(_ instance: MinecraftInstance, _ options: LaunchOptions) -> Result<Void, JavaCheckError> {
        log("[launchPrecheck] 正在进行 Java 检查")
        let requiredVersion = instance.requiredJavaVersion
        let installedJava = DataManager.shared.javaVirtualMachines.filter { !$0.isError && $0.version > 0 }
        guard !installedJava.isEmpty else {
            err("[launchPrecheck] 用户未安装 Java")
            return .failure(.javaNotFound)
        }

        if instance.config.maxMemory == 0 {
            return .failure(.invalidMemoryConfiguration)
        }

        guard let suitableJava = MinecraftInstance.findSuitableJava(requiredVersion: requiredVersion) else {
            err("[launchPrecheck] 无可用 Java。最低版本: \(requiredVersion)")
            return .failure(.noUsableJava(minVersion: requiredVersion))
        }

        // 已保存的 Java 可能仍存在，但版本已经不满足新安装的 Minecraft。
        // 只有版本、架构和调用方式都合格时才沿用，否则自动切换到合适项。
        let configuredJava = installedJava.first { $0.executableURL == instance.config.javaURL }
        let shouldReplaceConfiguredJava = configuredJava.map {
            $0.version < requiredVersion || $0.callMethod == .incompatible
        } ?? true
        if shouldReplaceConfiguredJava {
            instance.config.javaURL = suitableJava.executableURL
            instance.saveConfig()
            log("[launchPrecheck] 已为实例切换到 Java \(suitableJava.displayVersion)")
        }

        let javaArchitecture = Architecture.getArchOfFile(instance.config.javaURL!)
        if Architecture.system == .x64 && javaArchitecture == .arm64 {
            err("[launchPrecheck] Java 架构不兼容")
            return .failure(.javaNotSupport)
        } else if Architecture.system == .arm64 && javaArchitecture == .x64 {
            warn("[launchPrecheck] 正在使用 x64 Java")
            return .failure(.rosetta)
        }

        return .success(())
    }

    public static func checkAccount(_ instance: MinecraftInstance, _ options: LaunchOptions) -> Result<Void, AccountCheckError> {
        guard let account = AccountManager.shared.getAccount() else {
            err("无法启动 Minecraft: 未设置账号")
            return .failure(.missingAccount)
        }
        
        options.account = account
        
        if !AppSettings.shared.hasMicrosoftAccount {
            debug("[launchPrecheck] 未登录过正版账号")
            return .failure(.noMicrosoftAccount)
        }
        
        return .success(())
    }
}
