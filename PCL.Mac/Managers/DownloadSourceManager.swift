//
//  DownloadSourceManager.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/20.
//

import Foundation

public class DownloadSourceManager: DownloadSource {
    public static let shared: DownloadSourceManager = .init()
    
    private let official: OfficialDownloadSource = .init()
    private let bmclapi: BMCLAPIDownloadSource = .init()
    
    private var lastTestDate: Date = .init(timeIntervalSince1970: 0)
    private var fileDownloadSource: DownloadSource
    private var versionManifestSource: DownloadSource

    public var recommendedConcurrency: Int {
        switch AppSettings.shared.fileDownloadSource {
        case .official:
            return 48
        case .mirror:
            return 16
        case .both:
            return fileDownloadSource is BMCLAPIDownloadSource ? 16 : 48
        }
    }
    
    public func getDownloadSource() -> DownloadSource {
        if AppSettings.shared.fileDownloadSource == .both {
            if Date().timeIntervalSince(lastTestDate) > 1 * 60 {
                lastTestDate = Date()
                Task {
                    log("正在进行官方源测速")
                    await testSpeed("https://libraries.minecraft.net/net/java/dev/jna/jna/5.15.0/jna-5.15.0.jar", &fileDownloadSource)
                }
            }
            return fileDownloadSource
        } else {
            return AppSettings.shared.fileDownloadSource == .mirror ? bmclapi : fileDownloadSource
        }
    }
    
    public func getVersionManifestURL() -> URL {
        versionManifestSource.getVersionManifestURL()
    }
    
    public func getClientManifestURL(_ version: MinecraftVersion) -> URL? {
        getDownloadSource().getClientManifestURL(version)
    }
    
    public func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        getDownloadSource().getAssetIndexURL(version, manifest)
    }
    
    public func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        getDownloadSource().getClientJARURL(version, manifest)
    }
    
    public func getLibraryURL(_ library: ClientManifest.Library) -> URL? {
        getDownloadSource().getLibraryURL(library)
    }

    public func candidateURLs(for url: URL) -> [URL] {
        let official = [url]
        let mirror = mirrorURL(for: url).map { [$0] } ?? []
        let preferMirror = AppSettings.shared.fileDownloadSource == .mirror ||
            (AppSettings.shared.fileDownloadSource == .both && fileDownloadSource is BMCLAPIDownloadSource)
        let merged = preferMirror ? (mirror + official) : (official + mirror)
        var seen = Set<URL>()
        return merged.filter { seen.insert($0).inserted }
    }
    
    private func testSpeed(_ url: URLConvertible, _ source: inout DownloadSource) async {
        source = official
        let before = Date()
        
        let data: Data
        do {
            try await SingleFileDownloader.download(url: url.url, destination: URL(fileURLWithPath: "/tmp/testspeed"), replaceMethod: .replace)
            data = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/tmp/testspeed")).readToEnd().unwrap()
        } catch {
            return
        }
        
        let timeUsed: Double = Date().timeIntervalSince(before)
        let speed = Double(data.count) / timeUsed / 1024 / 1024
        debug(String(format: "\(url.url.lastPathComponent) 下载耗时 %.2fs (%.2f MB/s)", timeUsed, speed))
        if speed < 1 { // 1 MB
            source = bmclapi
            debug("已切换至镜像源")
        }
    }
    
    private init() {
        self.fileDownloadSource = official
        self.versionManifestSource = AppSettings.shared.versionManifestSource == .mirror ? bmclapi : official
    }

    private func mirrorURL(for url: URL) -> URL? {
        guard let host = url.host else { return nil }
        let bmclapiBaseURL = URL(string: "https://bmclapi2.bangbang93.com")!
        let mcimBaseURL = URL(string: "https://mod.mcimirror.top")!

        if ["piston-meta.mojang.com", "piston-data.mojang.com", "launchermeta.mojang.com", "launcher.mojang.com"].contains(host) {
            return bmclapiBaseURL.appending(path: url.path)
        }

        if host == "resources.download.minecraft.net" {
            return bmclapiBaseURL.appending(path: "assets").appending(path: url.path)
        }

        if host == "libraries.minecraft.net" || host == "maven.fabricmc.net" ||
            url.absoluteString.contains("files.minecraftforge.net/maven") ||
            url.absoluteString.contains("maven.neoforged.net/releases") {
            return bmclapiBaseURL.appending(path: "maven").appending(path: resolveMavenPath(url.path))
        }

        if host == "meta.fabricmc.net" {
            return bmclapiBaseURL.appending(path: "fabric-meta").appending(path: url.path)
        }

        if host == "cdn.modrinth.com" || host == "edge.forgecdn.net" {
            return mcimBaseURL.appending(path: url.path)
        }

        return nil
    }

    private func resolveMavenPath(_ path: String) -> String {
        if path.hasPrefix("/maven/") {
            return String(path.dropFirst("/maven/".count))
        }
        if path.hasPrefix("/releases/") {
            return String(path.dropFirst("/releases/".count))
        }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
