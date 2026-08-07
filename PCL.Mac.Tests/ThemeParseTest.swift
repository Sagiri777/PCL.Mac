//
//  ThemeParseTest.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 8/5/25.
//

import Foundation
import AppKit
import Testing
import SwiftyJSON
@testable import PCL_Mac
import PCL_Mac_Core

struct ThemeParseTest {
    @Test func testGradientParsing() throws {
        let url = SharedConstants.shared.applicationResourcesURL.appending(path: "pcl.json")
        let data = try Data(contentsOf: url)
        let json = try JSON(data: data)
        
        #expect(ThemeParser.shared.parseGradient(json["mainStyle"]) != nil)
        #expect(ThemeParser.shared.parseGradient(json["backgroundStyle"]) != nil)
    }

    @Test func malformedGradientDoesNotCrashOrProduceAStyle() {
        let missingPoint = JSON(parseJSON: """
        {"type":"linearGradient","startPoint":[0],"endPoint":[1,1],"colors":["#ffffff"]}
        """)
        let malformedStop = JSON(parseJSON: """
        {"type":"linearGradient","startPoint":[0,0],"endPoint":[1,1],"colors":[{"color":"#ffffff"}]}
        """)

        #expect(ThemeParser.shared.parseGradient(missingPoint) == nil)
        #expect(ThemeParser.shared.parseGradient(malformedStop) == nil)
    }

    @Test func malformedModrinthProjectIsRejected() {
        let malformed = JSON(parseJSON: """
        {"project_type":"mod","slug":"example","date_modified":"not-a-date"}
        """)

        #expect(ProjectSummary(json: malformed) == nil)
    }

    @Test func glassAppearanceSnapshotClampsUnsafeValues() {
        let state = GlassAppearanceState(
            backgroundBlurStrength: 2,
            panelBlurStrength: -1,
            frameWidth: -10,
            surfaceOpacity: 4,
            cornerRadius: -3
        )

        #expect(state.backgroundBlurStrength == 1)
        #expect(state.panelBlurStrength == 0)
        #expect(state.frameWidth == 0)
        #expect(state.surfaceOpacity == 1)
        #expect(state.cornerRadius == 0)
    }

    @Test func nativeGlassOpacityDoesNotChangeWithBlurStrength() {
        let surfaceOpacity = 0.70
        let nativeOpacity = GlassRenderingMetrics.nativeSurfaceOpacity(
            surfaceOpacityMultiplier: surfaceOpacity
        )
        let lowBlurFallbackOpacity = GlassRenderingMetrics.fallbackSurfaceOpacity(
            effectiveStrength: 0.15,
            surfaceOpacityMultiplier: surfaceOpacity
        )

        #expect(nativeOpacity == surfaceOpacity)
        #expect(lowBlurFallbackOpacity < nativeOpacity)
    }

    @Test @MainActor func glassAppearanceRefreshesAfterSchemeAndSliderChanges() {
        let settings = AppSettings.shared
        let glass = GlassSettings.shared
        let previousScheme = settings.colorScheme
        let previousOpacity = settings.glassSurfaceOpacity
        let previousFrameWidth = settings.glassFrameWidth
        defer {
            settings.colorScheme = previousScheme
            settings.glassSurfaceOpacity = previousOpacity
            settings.glassFrameWidth = previousFrameWidth
            settings.updateColorScheme()
        }

        settings.colorScheme = .dark
        settings.updateColorScheme()
        #expect(ColorConstants.isLight == false)

        settings.glassSurfaceOpacity = 0.37
        settings.glassFrameWidth = 18
        settings.refreshVisuals()
        #expect(glass.appearance.surfaceOpacity == 0.37)
        #expect(glass.appearance.frameWidth == 18)

        settings.colorScheme = .light
        settings.updateColorScheme()
        #expect(ColorConstants.isLight)
        #expect(glass.appearance.surfaceOpacity == 0.37)
    }

    @Test func malformedCacheIndexFallsBackToAnEmptyCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-cache-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appending(path: "index.json"))

        let cache = CacheStorage(rootURL: root)
        #expect(!cache.copy(name: "missing", to: root.appending(path: "missing.jar")))
    }

    @Test func malformedMavenCoordinatesFailWithoutCrashing() {
        #expect(Util.toPath(mavenCoordinate: "not-a-maven-coordinate").isEmpty)
    }

    @Test func malformedAssetIndexIsRejectedWithoutPathTraversal() throws {
        let malformed = Data("""
        {"objects":{"escape":{"hash":"../outside","size":1}}}
        """.utf8)

        #expect(throws: Error.self) {
            try AssetIndex.parse(malformed)
        }
    }

    @Test func existingInstanceConfigIsNotOverwrittenDuringSetup() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-instance-config-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = MinecraftDirectory(rootURL: root, name: "test")
        let instanceURL = directory.versionsURL.appending(path: "preserved")
        try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
        try Data("""
        {"id":"1.20.1","type":"release","mainClass":"example.Main","libraries":[]}
        """.utf8).write(to: instanceURL.appending(path: "preserved.json"))

        var saved = MinecraftConfig(version: MinecraftVersion(displayName: "1.20.1", type: .release))
        saved.minecraftVersion = "1.20.1"
        saved.maxMemory = 6144
        saved.skipResourcesCheck = true
        saved.qualityOfService = .userInitiated
        saved.javaURL = root.appending(path: "fake-java")
        try JSONEncoder().encode(saved).write(to: instanceURL.appending(path: ".PCL_Mac.json"))

        let instance = try #require(MinecraftInstance.create(directory, instanceURL))
        #expect(instance.config.maxMemory == 6144)
        #expect(instance.config.skipResourcesCheck)
        #expect(instance.config.qualityOfService == .userInitiated)
        #expect(instance.config.javaURL == root.appending(path: "fake-java"))
    }

    @Test @MainActor func glassWindowFrameAdjustmentReturnsToItsOriginalSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()
        let original = window.frame

        coordinator.enterGlassMode(window: window, frameWidth: 14)
        coordinator.enterGlassMode(window: window, frameWidth: 20)
        #expect(window.frame.size.width == original.size.width + 12)
        #expect(window.frame.size.height == original.size.height + 12)

        coordinator.leaveGlassMode(window: window)
        #expect(abs(window.frame.size.width - original.size.width) < 0.01)
        #expect(abs(window.frame.size.height - original.size.height) < 0.01)
        #expect(abs(window.frame.origin.x - original.origin.x) < 0.01)
        #expect(abs(window.frame.origin.y - original.origin.y) < 0.01)
    }
}
