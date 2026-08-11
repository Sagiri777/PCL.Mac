import Foundation

enum InstanceDiagnosticSeverity: Int, Codable, Comparable, CaseIterable {
    case healthy = 0
    case information = 1
    case warning = 2
    case critical = 3

    static func < (lhs: InstanceDiagnosticSeverity, rhs: InstanceDiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .healthy: "正常"
        case .information: "提示"
        case .warning: "注意"
        case .critical: "需要处理"
        }
    }
}

enum InstanceDiagnosticAction: String, Codable {
    case installJava
    case manageMods
    case manageAccounts
    case openInstanceFolder

    var label: String {
        switch self {
        case .installJava: "安装 Java"
        case .manageMods: "管理 Mod"
        case .manageAccounts: "管理账号"
        case .openInstanceFolder: "打开实例目录"
        }
    }
}

struct InstanceDiagnosticItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let summary: String
    let detail: String?
    let severity: InstanceDiagnosticSeverity
    let action: InstanceDiagnosticAction?
}

struct InstanceDiagnosticReport: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let instanceName: String
    let minecraftVersion: String
    let loader: String
    let generatedAt: Date
    let appVersion: String
    let systemArchitecture: String
    let items: [InstanceDiagnosticItem]

    init(instance: MinecraftInstance, items: [InstanceDiagnosticItem], generatedAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        instanceName = instance.name
        minecraftVersion = instance.version?.displayName ?? "未知"
        loader = instance.clientBrand?.getName() ?? "未知"
        self.generatedAt = generatedAt
        appVersion = SharedConstants.shared.version
        systemArchitecture = String(describing: Architecture.system)
        self.items = items.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var highestSeverity: InstanceDiagnosticSeverity {
        items.map(\.severity).max() ?? .healthy
    }

    var problemCount: Int {
        items.filter { $0.severity >= .warning }.count
    }

    var markdown: String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "# PCL.Mac 实例诊断报告",
            "",
            "- 实例：\(instanceName)",
            "- Minecraft：\(minecraftVersion)",
            "- Loader：\(loader)",
            "- PCL.Mac：\(appVersion)",
            "- 系统架构：\(systemArchitecture)",
            "- 生成时间：\(formatter.string(from: generatedAt))",
            "- 结论：\(highestSeverity.label)，\(problemCount) 项需要处理",
            "",
            "> 报告不包含账号令牌、用户名、主目录绝对路径或完整游戏日志。",
            ""
        ]
        for item in items {
            lines.append("## [\(item.severity.label)] \(item.title)")
            lines.append("")
            lines.append(item.summary)
            if let detail = item.detail, !detail.isEmpty {
                lines.append("")
                lines.append(detail)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func write(to destination: URL) throws {
        try Data(markdown.utf8).write(to: destination, options: .atomic)
    }
}

enum InstanceDiagnosticsService {
    static func run(for instance: MinecraftInstance) async -> InstanceDiagnosticReport {
        var items: [InstanceDiagnosticItem] = []
        items.append(contentsOf: checkCoreFiles(instance))
        items.append(checkJava(instance))
        items.append(checkMemory(instance))
        items.append(checkAccount())
        items.append(checkDiskSpace(instance))
        items.append(contentsOf: checkMods(instance))
        if let nativeReport = await NativeCompatibilityService.shared.lastReport(instance: instance) {
            items.append(checkNativeCompatibility(nativeReport))
        }
        if let crash = checkLatestCrash(instance) {
            items.append(crash)
        }
        return InstanceDiagnosticReport(instance: instance, items: items)
    }

    private static func checkCoreFiles(_ instance: MinecraftInstance) -> [InstanceDiagnosticItem] {
        let fileManager = FileManager.default
        let manifestURL = instance.runningDirectory.appending(path: "\(instance.name).json")
        let clientURL = instance.runningDirectory.appending(path: "\(instance.name).jar")
        var result: [InstanceDiagnosticItem] = []

        result.append(.init(
            id: "manifest",
            title: "版本清单",
            summary: fileManager.fileExists(atPath: manifestURL.path) ? "版本 JSON 可以读取。" : "缺少实例版本 JSON。",
            detail: fileManager.fileExists(atPath: manifestURL.path) ? nil : "运行资源补全或重新安装该实例。",
            severity: fileManager.fileExists(atPath: manifestURL.path) ? .healthy : .critical,
            action: fileManager.fileExists(atPath: manifestURL.path) ? nil : .openInstanceFolder
        ))
        result.append(.init(
            id: "client",
            title: "游戏客户端",
            summary: fileManager.fileExists(atPath: clientURL.path) ? "客户端 JAR 已就绪。" : "缺少客户端 JAR。",
            detail: fileManager.fileExists(atPath: clientURL.path) ? nil : "下次启动时不要跳过资源完整性检查。",
            severity: fileManager.fileExists(atPath: clientURL.path) ? .healthy : .critical,
            action: fileManager.fileExists(atPath: clientURL.path) ? nil : .openInstanceFolder
        ))
        return result
    }

    private static func checkJava(_ instance: MinecraftInstance) -> InstanceDiagnosticItem {
        guard let javaURL = instance.config?.javaURL else {
            return .init(
                id: "java",
                title: "Java 运行时",
                summary: "实例尚未选择 Java。",
                detail: "Minecraft \(instance.version?.displayName ?? "") 至少需要 Java \(instance.requiredJavaVersion)。",
                severity: .critical,
                action: .installJava
            )
        }
        guard FileManager.default.isExecutableFile(atPath: javaURL.path) else {
            return .init(
                id: "java",
                title: "Java 运行时",
                summary: "已保存的 Java 路径不存在或不可执行。",
                detail: "需要 Java \(instance.requiredJavaVersion) 或更高版本。",
                severity: .critical,
                action: .installJava
            )
        }

        let java = JavaVirtualMachine.of(javaURL)
        if java.isError || java.version < instance.requiredJavaVersion {
            return .init(
                id: "java",
                title: "Java 运行时",
                summary: "当前 Java 不满足实例要求。",
                detail: "检测到 \(java.displayVersion)，实例至少需要 Java \(instance.requiredJavaVersion)。",
                severity: .critical,
                action: .installJava
            )
        }
        let javaArchitecture = Architecture.getArchOfFile(javaURL)
        let compatible = javaArchitecture.isCompatiableWithSystem()
        return .init(
            id: "java",
            title: "Java 运行时",
            summary: "Java \(java.displayVersion)，\(javaArchitecture) 架构。",
            detail: compatible ? nil : "将通过 Rosetta 运行，性能和兼容性可能下降。",
            severity: compatible ? .healthy : .warning,
            action: compatible ? nil : .installJava
        )
    }

    private static func checkMemory(_ instance: MinecraftInstance) -> InstanceDiagnosticItem {
        let configured = Int(instance.config?.maxMemory ?? 0)
        let physical = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        let tooHigh = configured > Int(Double(physical) * 0.8)
        let invalid = configured <= 0
        return .init(
            id: "memory",
            title: "内存配置",
            summary: invalid ? "内存配置无效。" : "已分配 \(configured) MB，系统共有约 \(physical) MB。",
            detail: tooHigh ? "建议不要超过系统物理内存的 80%，为 macOS 和其他应用保留空间。" : nil,
            severity: invalid ? .critical : (tooHigh ? .warning : .healthy),
            action: nil
        )
    }

    private static func checkAccount() -> InstanceDiagnosticItem {
        guard let account = AccountManager.shared.getAccount() else {
            return .init(
                id: "account",
                title: "启动账号",
                summary: "没有可用的启动账号。",
                detail: nil,
                severity: .critical,
                action: .manageAccounts
            )
        }
        let secured = account.credentialsAreSecure
        return .init(
            id: "account",
            title: "启动账号",
            // 导出诊断报告时不包含账号名；界面只需要说明凭据状态。
            summary: secured ? "已选择启动账号，凭据由 Keychain 保护。" : "账号凭据需要重新登录。",
            detail: nil,
            severity: secured ? .healthy : .critical,
            action: secured ? nil : .manageAccounts
        )
    }

    private static func checkDiskSpace(_ instance: MinecraftInstance) -> InstanceDiagnosticItem {
        let values = try? instance.runningDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else {
            return .init(
                id: "disk",
                title: "磁盘空间",
                summary: "无法读取实例所在磁盘的可用空间。",
                detail: nil,
                severity: .information,
                action: .openInstanceFolder
            )
        }
        let gib = Double(bytes) / 1_073_741_824
        let severity: InstanceDiagnosticSeverity = gib < 2 ? .critical : (gib < 8 ? .warning : .healthy)
        return .init(
            id: "disk",
            title: "磁盘空间",
            summary: String(format: "实例所在磁盘可用 %.1f GB。", gib),
            detail: severity >= .warning ? "整合包更新和实例快照需要额外空间。" : nil,
            severity: severity,
            action: severity >= .warning ? .openInstanceFolder : nil
        )
    }

    private static func checkMods(_ instance: MinecraftInstance) -> [InstanceDiagnosticItem] {
        let modsURL = instance.runningDirectory.appending(path: "mods")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [.init(
                id: "mods",
                title: "Mod",
                summary: "当前实例没有 Mod 目录。",
                detail: nil,
                severity: .healthy,
                action: nil
            )]
        }
        let jars = files.filter { $0.pathExtension.lowercased() == "jar" }
        let unreadable = jars.filter { Mod.loadMod(url: $0) == nil }
        let disabled = files.filter { $0.lastPathComponent.hasSuffix(".jar.disabled") }
        var items: [InstanceDiagnosticItem] = [.init(
            id: "mods",
            title: "Mod",
            summary: "检测到 \(jars.count) 个启用的 Mod，\(disabled.count) 个已隔离。",
            detail: unreadable.isEmpty ? nil : "\(unreadable.count) 个 JAR 缺少可识别的 Fabric/Forge/NeoForge 元数据。",
            severity: unreadable.isEmpty ? .healthy : .warning,
            action: unreadable.isEmpty ? nil : .manageMods
        )]
        if !disabled.isEmpty {
            items.append(.init(
                id: "disabled-mods",
                title: "已隔离的 Mod",
                summary: "有 \(disabled.count) 个 Mod 当前不会加载。",
                detail: "可在 Mod 页面查看兼容性证据并选择恢复。",
                severity: .information,
                action: .manageMods
            ))
        }
        return items
    }

    private static func checkNativeCompatibility(_ report: NativeCompatibilityReport) -> InstanceDiagnosticItem {
        let count = report.unresolvedCount
        return .init(
            id: "native-compatibility",
            title: "macOS 原生兼容性",
            summary: count == 0 ? "上次扫描没有未解决的原生兼容问题。" : "上次扫描仍有 \(count) 项需要处理。",
            detail: report.disabledCount > 0 ? "已可逆隔离 \(report.disabledCount) 个确认不兼容的 Mod。" : nil,
            severity: count == 0 ? .healthy : .warning,
            action: count == 0 ? nil : .manageMods
        )
    }

    private static func checkLatestCrash(_ instance: MinecraftInstance) -> InstanceDiagnosticItem? {
        let report = MinecraftCrashHandler.analyze(instance: instance)
        guard !report.logFiles.isEmpty else { return nil }
        let reasons = report.primaryReasons.filter { $0 != .unknown }
        return .init(
            id: "latest-crash",
            title: "最近一次崩溃",
            summary: reasons.isEmpty ? "发现崩溃日志，但未匹配到已知原因。" : reasons.map(\.rawValue).joined(separator: "、"),
            detail: reasons.first?.solution,
            severity: reasons.isEmpty ? .information : .warning,
            action: reasons.contains(.windowsNativeLibrary) || reasons.contains(.nativeArchitectureMismatch) ? .manageMods : nil
        )
    }
}
