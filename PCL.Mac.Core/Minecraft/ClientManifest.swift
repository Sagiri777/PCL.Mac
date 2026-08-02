//
//  ClientManifest.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation
import SwiftyJSON

public class ClientManifest {
    public let id: String
    public var mainClass: String
    public let type: String
    public let assetIndex: AssetIndex?
    public let assets: String
    public var libraries: [Library]
    public let arguments: Arguments?
    public var minecraftArguments: String?
    public let javaVersion: Int?
    public let clientDownload: DownloadInfo?
    public let clientMappingsDownload: DownloadInfo?

    private init?(json: JSON) {
        self.id = json["id"].stringValue
        self.mainClass = json["mainClass"].stringValue
        self.type = json["type"].stringValue
        self.assets = json["assets"].stringValue
        self.assetIndex = json["assetIndex"].exists() ? AssetIndex(json: json["assetIndex"]) : nil
        // A Mojang library entry may contain both a normal classpath artifact
        // and an OS native classifier. Keep both roles: collapsing the entry to
        // one artifact drops java-objc-bridge classes on Minecraft 1.12.2.
        self.libraries = json["libraries"].arrayValue.flatMap { Library.parse(json: $0) }
        self.arguments = json["arguments"].exists() ? Arguments(json: json["arguments"]) : nil
        self.minecraftArguments = json["minecraftArguments"].string
        self.javaVersion = json["javaVersion"]["majorVersion"].int
        self.clientDownload = json["downloads"]["client"].exists() ? .init(json: json["downloads"]["client"]) : nil
        self.clientMappingsDownload = json["downloads"]["client_mappings"].exists() ? .init(json: json["downloads"]["client_mappings"]) : nil
    }

    public class AssetIndex {
        public let id: String
        public let sha1: String
        public let size: Int
        public let totalSize: Int
        public let url: String
        public init(json: JSON) {
            id = json["id"].stringValue
            sha1 = json["sha1"].stringValue
            size = json["size"].intValue
            totalSize = json["totalSize"].intValue
            url = json["url"].stringValue
        }
    }

    public class DownloadInfo {
        public var path: String
        public let sha1: String?
        public let size: Int?
        public var url: String
        
        public init(json: JSON) {
            path = json["path"].stringValue
            sha1 = json["sha1"].string
            size = json["size"].int
            url = json["url"].stringValue
        }
        
        init(path: String, sha1: String? = nil, size: Int? = nil, url: String) {
            self.path = path
            self.sha1 = sha1
            self.size = size
            self.url = url
        }
    }

    public enum LibraryRole: String, Codable, Sendable {
        case classpath
        case native
    }

    public class Library: Hashable {
        public var name: String {
            didSet {
                split = name.split(separator: ":").map(String.init)
            }
        }
        private var split: [String]
        public var groupId: String { split[0] }
        public var artifactId: String { split[1] }
        public var version: String { split[2] }
        public var classifier: String? { split.count >= 4 ? split[3] : nil }
        public let rules: [Rule]
        public let natives: [String: String]
        public let artifact: DownloadInfo?
        public let role: LibraryRole
        public var isNativeLibrary: Bool { role == .native }

        private init?(name: String, rules: [Rule], natives: [String: String], artifact: DownloadInfo?, role: LibraryRole) {
            let split = name.split(separator: ":").map(String.init)
            guard split.count >= 3 else { return nil }
            self.name = name
            self.split = split
            self.rules = rules
            self.natives = natives
            self.artifact = artifact
            self.role = role
        }

        public static func parse(json: JSON) -> [Library] {
            let name = json["name"].stringValue
            let split = name.split(separator: ":").map(String.init)
            guard split.count >= 3 else { return [] }

            let rules = json["rules"].arrayValue.map { Rule(json: $0) }
            let natives = json["natives"].dictionaryObject as? [String: String] ?? [:]

            if !json["downloads"].exists() {
                let path = Util.toPath(mavenCoordinate: name)
                let baseURL = URL(string: json["url"].stringValue)
                    ?? URL(string: "https://bmclapi2.bangbang93.com/maven")!
                return [Library(
                    name: name,
                    rules: rules,
                    natives: natives,
                    artifact: DownloadInfo(path: path, url: baseURL.appending(path: path).absoluteString),
                    role: .classpath
                )].compactMap { $0 }
            }

            if split[1] == "launchwrapper" {
                let path = Util.toPath(mavenCoordinate: name)
                return [Library(
                    name: name,
                    rules: rules,
                    natives: natives,
                    artifact: DownloadInfo(path: path, url: URL(string: "https://libraries.minecraft.net")!.appending(path: path).absoluteString),
                    role: .classpath
                )].compactMap { $0 }
            }

            var result: [Library] = []
            if json["downloads"]["artifact"].exists(),
               let library = Library(
                name: name,
                rules: rules,
                natives: natives,
                artifact: DownloadInfo(json: json["downloads"]["artifact"]),
                role: .classpath
               ) {
                result.append(library)
            }

            if let classifiers = json["downloads"]["classifiers"].dictionary,
               let classifierKey = natives["osx"]?.replacingOccurrences(of: "${arch}", with: "64"),
               let classifierJSON = classifiers[classifierKey],
               let library = Library(
                name: name,
                rules: rules,
                natives: natives,
                artifact: DownloadInfo(json: classifierJSON),
                role: .native
               ) {
                result.append(library)
            }
            return result
        }
        
        public static func == (lhs: Library, rhs: Library) -> Bool {
            lhs.name == rhs.name && lhs.role == rhs.role && lhs.artifact?.path == rhs.artifact?.path
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(role)
            hasher.combine(artifact?.path)
        }
    }

    public class Arguments {
        public var game: [GameArgument]
        public var jvm: [JvmArgument]

        public init(json: JSON) {
            game = json["game"].arrayValue.map { GameArgument(json: $0) }
            jvm = json["jvm"].arrayValue.map { JvmArgument(json: $0) }
        }
        
        init(game: [GameArgument], jvm: [JvmArgument]) {
            self.game = game
            self.jvm = jvm
        }
        
        public func getAllowedGameArguments(targetArchitecture: Architecture = .system) -> [String] {
            let filtered = game.filter { $0.match(targetArchitecture: targetArchitecture) }
            var arguments: [String] = []
            for arg in filtered {
                arguments.append(contentsOf: arg.values(targetArchitecture: targetArchitecture))
            }
            return arguments
        }
        public func getAllowedJVMArguments(targetArchitecture: Architecture = .system) -> [String] {
            let filtered = jvm.filter { $0.match(targetArchitecture: targetArchitecture) }
            var arguments: [String] = []
            for arg in filtered { arguments.append(contentsOf: arg.values(targetArchitecture: targetArchitecture)) }
            return arguments
        }

        public class GameArgument {
            public let string: String?
            public let rules: RuleTag?

            public init(json: JSON) {
                if let str = json.string { string = str; rules = nil }
                else { string = nil; rules = RuleTag(json: json) }
            }
            public func match(targetArchitecture: Architecture = .system) -> Bool {
                rules?.match(targetArchitecture: targetArchitecture) ?? true
            }
            public func values(targetArchitecture: Architecture = .system) -> [String] {
                if let string { return [string] }
                if let rules, rules.match(targetArchitecture: targetArchitecture) { return rules.value }
                return []
            }
        }
        
        public class JvmArgument {
            public let string: String?
            public let rules: RuleTag?

            public init(json: JSON) {
                if let str = json.string { string = str; rules = nil }
                else { string = nil; rules = RuleTag(json: json) }
            }
            public func match(targetArchitecture: Architecture = .system) -> Bool {
                rules?.match(targetArchitecture: targetArchitecture) ?? true
            }
            public func values(targetArchitecture: Architecture = .system) -> [String] {
                if let string { return [string] }
                if let rules, rules.match(targetArchitecture: targetArchitecture) { return rules.value }
                return []
            }
        }
        
        public class RuleTag {
            public let rules: [Rule]
            public let value: [String]
            public init(json: JSON) {
                rules = json["rules"].arrayValue.map { Rule(json: $0) }
                if let str = json["value"].string {
                    value = [str]
                } else if let arr = json["value"].array {
                    value = arr.compactMap { $0.string }
                } else {
                    value = []
                }
            }
            public func match(targetArchitecture: Architecture = .system) -> Bool {
                Rule.evaluate(rules, targetArchitecture: targetArchitecture)
            }
        }
    }

    public class Rule {
        public let action: String
        public let os: OSRule?
        public let features: Features?
        public init(json: JSON) {
            action = json["action"].stringValue
            os = json["os"].exists() ? OSRule(json: json["os"]) : nil
            features = json["features"].exists() ? Features(json: json["features"]) : nil
        }
        public func conditionsMatch(targetArchitecture: Architecture = .system) -> Bool {
            (os?.match(targetArchitecture: targetArchitecture) ?? true) && (features?.match() ?? true)
        }

        /// Mojang rules are ordered. Matching rules update the current state;
        /// a later disallow must be able to override an earlier allow.
        public static func evaluate(_ rules: [Rule], targetArchitecture: Architecture = .system) -> Bool {
            guard !rules.isEmpty else { return true }
            var allowed = false
            for rule in rules where rule.conditionsMatch(targetArchitecture: targetArchitecture) {
                allowed = rule.action == "allow"
            }
            return allowed
        }

        public func match(targetArchitecture: Architecture = .system) -> Bool {
            conditionsMatch(targetArchitecture: targetArchitecture) && action == "allow"
        }
        public class OSRule {
            public let name: String?
            public let arch: String?
            public init(json: JSON) {
                name = json["name"].string
                arch = json["arch"].string
            }
            public func match(targetArchitecture: Architecture = .system) -> Bool {
                if let name, name != "osx" { return false }
                if let arch {
                    let candidates: [String]
                    switch targetArchitecture {
                    case .arm64: candidates = ["arm64", "aarch64"]
                    case .x64: candidates = ["x86_64", "amd64", "x64", "x86"]
                    case .fatFile: candidates = ["arm64", "aarch64", "x86_64", "amd64", "x64", "x86"]
                    case .unknown: candidates = []
                    }
                    guard candidates.contains(where: { candidate in
                        candidate.range(of: arch, options: .regularExpression) != nil
                    }) else { return false }
                }
                return true
            }
        }
        
        public class Features {
            public let isDemoUser: Bool?
            public let hasCustomResolution: Bool?
            public let hasQuickPlaysSupport: Bool?
            public let isQuickPlaySingleplayer: Bool?
            public let isQuickPlayMultiplayer: Bool?
            public let isQuickPlayRealms: Bool?
            public init(json: JSON) {
                isDemoUser = json["is_demo_user"].bool
                hasCustomResolution = json["has_custom_resolution"].bool
                hasQuickPlaysSupport = json["has_quick_plays_support"].bool
                isQuickPlaySingleplayer = json["is_quick_play_singleplayer"].bool
                isQuickPlayMultiplayer = json["is_quick_play_multiplayer"].bool
                isQuickPlayRealms = json["is_quick_play_realms"].bool
            }
            public func match() -> Bool {
                if isDemoUser == true { return false }
                if hasCustomResolution == true { return false }
                if hasQuickPlaysSupport == true { return false }
                if isQuickPlaySingleplayer == true { return false }
                if isQuickPlayMultiplayer == true { return false }
                if isQuickPlayRealms == true { return false }
                return true
            }
        }
    }
    
    /// 尝试解析与自动合并客户端清单，不会对实例进行操作
    /// - Parameter url: 清单路径
    /// - Parameter minecraftDirectory: 若需自动合并，该参数的值为实例所在的 minecraft 目录，否则为空
    public static func parse(url: URL, minecraftDirectory: MinecraftDirectory? = nil) throws -> ClientManifest? {
        let data = try FileHandle(forReadingFrom: url).readToEnd() ?? Data()
        let json = try JSON(data: data)
        
        if json["loader"].exists() && json["intermediary"].exists() && !json["id"].exists() { // 旧版 PCL.Mac Fabric 安装逻辑
            warn("无法解析旧版 PCL.Mac 安装的 Fabric 版本: \(url.lastPathComponent)")
            return nil
        }
        
    checkParent:
        if let inheritsFrom = json["inheritsFrom"].string,
           let minecraftDirectory = minecraftDirectory {
            let parentURL = minecraftDirectory.versionsURL.appending(path: inheritsFrom).appending(path: "\(inheritsFrom).json")
            
            guard FileManager.default.fileExists(atPath: parentURL.path) else {
                err("\(url.path) 中有 inheritsFrom 字段，但其对应的 JSON 不存在")
                return nil
            }
            
            let parent: ClientManifest
            guard let manifest = ClientManifest(json: json) else { return nil }
            do {
                guard let manifest = try ClientManifest.parse(url: parentURL, minecraftDirectory: minecraftDirectory) else { return nil }
                parent = manifest
            } catch {
                err("无法解析 inheritsFrom: \(error.localizedDescription)")
                break checkParent
            }
            
            return merge(parent: parent, manifest: manifest)
        }
        return ClientManifest(json: json)
    }
    
    public static func deduplicateLibraries(_ manifest: ClientManifest) {
        var librarySet: Set<HashableLibrary> = .init()
        manifest.libraries = manifest.libraries.filter { librarySet.insert(.init($0)).inserted }
    }
    
    private static func merge(parent: ClientManifest, manifest: ClientManifest) -> ClientManifest {
        parent.libraries.insert(contentsOf: manifest.libraries, at: 0)
        deduplicateLibraries(parent)
        
        parent.arguments?.game.append(contentsOf: manifest.arguments?.game ?? [])
        parent.arguments?.jvm.append(contentsOf: manifest.arguments?.jvm ?? [])
        parent.minecraftArguments = manifest.minecraftArguments
        parent.mainClass = manifest.mainClass
        
        return parent
    }

    public func getNeededLibraries(for targetArchitecture: Architecture = .system) -> [Library] {
        getAllowedLibraries(for: targetArchitecture).filter { $0.role == .classpath }
    }
    
    public func getAllowedLibraries(for targetArchitecture: Architecture = .system) -> [Library] {
        libraries.filter { Rule.evaluate($0.rules, targetArchitecture: targetArchitecture) }
    }
    
    public func getNeededNatives(for targetArchitecture: Architecture = .system) -> [(Library, DownloadInfo)] {
        getAllowedLibraries(for: targetArchitecture).compactMap { library in
            guard library.role == .native, let artifact = library.artifact else { return nil }
            return (library, artifact)
        }
    }
    
    public func getArguments() -> Arguments {
        if let arguments = self.arguments {
            return arguments
        } else if let minecraftArguments = self.minecraftArguments {
            let gameArgs = minecraftArguments.split(separator: " ").map { Arguments.GameArgument(json: JSON(stringLiteral: String($0))) }
            let jvmArgs: [Arguments.JvmArgument] = [
                "-XX:+UnlockExperimentalVMOptions", "-XX:+UseG1GC", "-XX:-UseAdaptiveSizePolicy", "-XX:-OmitStackTraceInFastThrow",
                "-Djava.library.path=${natives_directory}",
                "-Dorg.lwjgl.system.SharedLibraryExtractPath=${natives_directory}",
                "-Dio.netty.native.workdir=${natives_directory}",
                "-Djna.tmpdir=${natives_directory}",
                "-cp", "${classpath}"
            ].map { Arguments.JvmArgument(json: JSON(stringLiteral: $0)) }
            return Arguments(game: gameArgs, jvm: jvmArgs)
        } else {
            return Arguments(game: [], jvm: [])
        }
    }
    
    private class HashableLibrary: Hashable {
        private let library: Library
        
        init(_ library: Library) {
            self.library = library
        }
        
        static func == (lhs: HashableLibrary, rhs: HashableLibrary) -> Bool {
            lhs.library.groupId == rhs.library.groupId
            && lhs.library.artifactId == rhs.library.artifactId
            && lhs.library.classifier == rhs.library.classifier
            && lhs.library.role == rhs.library.role
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(library.groupId)
            hasher.combine(library.artifactId)
            hasher.combine(library.classifier)
            hasher.combine(library.role)
        }
    }
}
